#!/usr/bin/env bash
#
# Standby mirror for a MongoDB database.
#
# It does two things, and the first matters more than the second:
#
#   1. it produces a compressed archive of the database. A database hosted on a
#      managed service has no copy under your control: if someone deletes data by
#      mistake, your only safety net is the provider's own backup — which shared
#      tiers do not have. This archive fills that gap, provided it ends up in an
#      offsite backup: on a local volume it is a copy on the very disk you are
#      trying to protect.
#
#   2. it restores that archive onto a standby mongod, which sits idle until
#      needed. If the source becomes unreachable you repoint the application's
#      connection string and carry on, with data at most one cycle old.
#
# Built to run as a scheduled task inside a `mongo:8` container, which already
# ships mongodump, mongorestore and mongosh. If those tools are not on PATH it
# falls back to `docker run`, so the same copy works from a workstation too.
#
# EXIT CODES — deliberately distinct, so an alert can say *where* to look
# instead of merely saying that something failed:
#   0  success
#   1  configuration error
#   2  usage error
#   3  dump failed        -> source unreachable or bad credentials
#   4  verification failed -> archive produced but counts differ; standby UNTOUCHED
#   5  restore failed      -> problem on the destination
#
# Documentation: README.md
#
set -euo pipefail

SOURCE_URI="${MONGO_SOURCE_URI:-}"
TARGET_URI="${MONGO_TARGET_URI:-}"
DB_NAME="${MONGO_DB_NAME:-}"
WORKDIR="${MONGO_MIRROR_WORKDIR:-/backup}"
IMAGE="${MONGO_TOOLS_IMAGE:-mongo:8}"
KEEP_ARCHIVES="${MONGO_KEEP_ARCHIVES:-7}"
# Compression is on by default: standalone, smaller files are simply better.
# Turn it OFF when the archives are picked up by a deduplicating backup such as
# restic or borg — see README, "Compression and deduplication".
COMPRESS="${MONGO_ARCHIVE_COMPRESS:-1}"
DO_RESTORE="yes"
STARTED_AT="$(date -u +%s)"
ARCHIVE=""
STATUS="preflight_failed"
DOCS=0
COLLS=0

usage() {
  cat <<'USAGE'
Usage:
  dr-mirror-mongo.sh [options]

Connection strings — from environment (recommended) or from a file:
  MONGO_SOURCE_URI / --source-uri-file FILE     source database (required)
  MONGO_TARGET_URI / --target-uri-file FILE     standby mongod (optional)

Other variables: MONGO_DB_NAME, MONGO_MIRROR_WORKDIR, MONGO_KEEP_ARCHIVES,
MONGO_TOOLS_IMAGE

Options:
  --db NAME | --workdir DIR | --keep N | --image IMG | --no-restore | -h
  --no-compress    write an uncompressed archive; use this when a deduplicating
                   backup (restic, borg) collects the archives — see README

Without a target it only produces the archive.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-uri-file) SOURCE_URI="$(cat "$2")"; shift 2 ;;
    --target-uri-file) TARGET_URI="$(cat "$2")"; shift 2 ;;
    --db) DB_NAME="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --keep) KEEP_ARCHIVES="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --no-restore) DO_RESTORE="no"; shift ;;
    --no-compress) COMPRESS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { STATUS="${2:-preflight_failed}"; printf '\nERROR: %s\n' "$1" >&2; exit "${3:-1}"; }

# The marker is written on EVERY run, failures included: it is the file an
# external monitor watches to notice the job has stopped working. A backup job
# that fails silently is the worst way this can break.
write_marker() {
  local code=$?
  local marker="$WORKDIR/last-run.json"
  mkdir -p "$WORKDIR" 2>/dev/null || return 0
  local bytes=0
  [[ -n "$ARCHIVE" && -f "$WORKDIR/$ARCHIVE" ]] && bytes=$(wc -c < "$WORKDIR/$ARCHIVE" | tr -d ' ')
  cat > "$marker" <<JSON
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "$([[ $code -eq 0 ]] && echo ok || echo "$STATUS")",
  "exit_code": $code,
  "database": "$DB_NAME",
  "archive": "${ARCHIVE:-null}",
  "archive_bytes": $bytes,
  "collections": $COLLS,
  "documents": $DOCS,
  "duration_seconds": $(( $(date -u +%s) - STARTED_AT ))
}
JSON
  info "marker: $marker"
}
trap write_marker EXIT

# --- tool execution: native if present, containerised otherwise ---------------
MODE=""
detect_mode() {
  if command -v mongodump >/dev/null && command -v mongorestore >/dev/null && command -v mongosh >/dev/null; then
    MODE="native"
  else
    MODE="docker"
  fi
}
# Native mode uses real paths; docker mode sees them under /work.
wpath() { [[ "$MODE" == "native" ]] && echo "$WORKDIR/$1" || echo "/work/$1"; }

m_sh() {   # m_sh <uri> <js>
  if [[ "$MODE" == "native" ]]; then
    mongosh "$1" --quiet --eval "$2"
  else
    docker run --rm -e MURI="$1" -v "$WORKDIR":/work "$IMAGE" \
      sh -c "mongosh \"\$MURI\" --quiet --eval '$(printf '%s' "$2" | sed "s/'/'\\\\''/g")'"
  fi
}
m_dump() { # m_dump <uri> <archive>
  local gz=""; [[ "$COMPRESS" == "1" ]] && gz="--gzip"
  if [[ "$MODE" == "native" ]]; then
    mongodump --uri="$1" --db="$DB_NAME" --archive="$(wpath "$2")" $gz --quiet
  else
    docker run --rm -e MURI="$1" -v "$WORKDIR":/work "$IMAGE" \
      sh -c "mongodump --uri=\"\$MURI\" --db=$DB_NAME --archive=$(wpath "$2") $gz --quiet"
  fi
}
m_restore() { # m_restore <uri> <archive> <nsFrom> <nsTo>
  # The flag must match how the archive was written, or mongorestore fails.
  local gz=""; [[ "$COMPRESS" == "1" ]] && gz="--gzip"
  if [[ "$MODE" == "native" ]]; then
    mongorestore --uri="$1" --archive="$(wpath "$2")" $gz --nsFrom="$3" --nsTo="$4" --quiet
  else
    docker run --rm -e MURI="$1" -v "$WORKDIR":/work "$IMAGE" \
      sh -c "mongorestore --uri=\"\$MURI\" --archive=$(wpath "$2") $gz --nsFrom='$3' --nsTo='$4' --quiet"
  fi
}

preflight() {
  log "Preflight"
  [[ -n "$SOURCE_URI" ]] || die "missing source connection string (MONGO_SOURCE_URI or --source-uri-file)" preflight_failed 1
  [[ -n "$DB_NAME" ]] || die "missing database name (MONGO_DB_NAME or --db)" preflight_failed 1
  detect_mode
  info "mongo tools: $MODE"
  info "compression: $([[ "$COMPRESS" == "1" ]] && echo on || echo off)"
  if [[ "$MODE" == "docker" ]]; then
    command -v docker >/dev/null || die "neither mongo tools on PATH nor docker available" preflight_failed 1
    docker info >/dev/null 2>&1 || die "Docker daemon unreachable" preflight_failed 1
    docker image inspect "$IMAGE" >/dev/null 2>&1 || { info "pulling $IMAGE..."; docker pull "$IMAGE" >/dev/null || die "failed to pull $IMAGE" preflight_failed 1; }
  fi
  [[ -n "$TARGET_URI" ]] || { DO_RESTORE="no"; info "no target given: archive only"; }
  mkdir -p "$WORKDIR" || die "cannot create $WORKDIR" preflight_failed 1
  info "archives in $WORKDIR"
}

versions() {
  log "Versions"
  local sv tv
  # `|| true` is not laziness: without it, under `set -e` and `pipefail` a failed
  # assignment would kill the script BEFORE reaching die() — no message, and a
  # marker carrying the wrong diagnosis. For an unattended job that is the worst
  # possible way to break.
  sv=$(m_sh "$SOURCE_URI" 'print(db.serverBuildInfo().version)' 2>/dev/null | tail -1 || true)
  [[ -n "$sv" ]] || die "source unreachable or invalid credentials" dump_failed 3
  info "source:      $sv"
  if [[ "$DO_RESTORE" == "yes" ]]; then
    tv=$(m_sh "$TARGET_URI" 'print(db.serverBuildInfo().version)' 2>/dev/null | tail -1 || true)
    [[ -n "$tv" ]] || die "target unreachable or not ready yet" restore_failed 5
    info "destination: $tv"
    if [[ "${tv%%.*}" -lt "${sv%%.*}" ]]; then
      die "destination ($tv) is an older major than the source ($sv): restore would fail. Needs mongod ${sv%%.*}.x" restore_failed 5
    fi
  fi
}

counts() { # counts <uri> <db>
  m_sh "$1" "const d=db.getSiblingDB(\"$2\"); d.getCollectionNames().sort().forEach(c=>print(c+\" \"+d.getCollection(c).countDocuments()));" 2>/dev/null | grep -E "^[a-zA-Z]" || true
}

dump() {
  log "Dumping source"
  local ext="archive"; [[ "$COMPRESS" == "1" ]] && ext="gz"
  ARCHIVE="mongo-${DB_NAME}-$(date -u +%Y%m%d-%H%M%S).${ext}"
  m_dump "$SOURCE_URI" "$ARCHIVE" || die "mongodump failed" dump_failed 3
  [[ -s "$WORKDIR/$ARCHIVE" ]] || die "empty archive" dump_failed 3
  info "$ARCHIVE ($(du -h "$WORKDIR/$ARCHIVE" | cut -f1))"
}

restore_and_verify() {
  STAGING="${DB_NAME}_staging"
  log "Restoring into $STAGING"
  m_sh "$TARGET_URI" "db.getSiblingDB(\"$STAGING\").dropDatabase()" >/dev/null 2>&1 || true
  m_restore "$TARGET_URI" "$ARCHIVE" "$DB_NAME.*" "$STAGING.*" || die "mongorestore failed" restore_failed 5

  log "Verifying document counts"
  local src dst diff=0
  src=$(counts "$SOURCE_URI" "$DB_NAME")
  dst=$(counts "$TARGET_URI" "$STAGING")
  while read -r c n; do
    [[ -z "$c" ]] && continue
    COLLS=$((COLLS+1)); DOCS=$((DOCS+n))
    local m; m=$(echo "$dst" | awk -v k="$c" '$1==k{print $2}')
    if [[ "$m" != "$n" ]]; then
      printf '    %-28s source=%s copy=%s  <-- MISMATCH\n' "$c" "$n" "${m:-missing}"; diff=1
    else
      printf '    %-28s %s\n' "$c" "$n"
    fi
  done <<< "$src"
  # Dedicated exit code 4: the archive exists but cannot be trusted. The standby
  # keeps the previous cycle's data — a suspect copy never replaces a sound one.
  [[ "$diff" -eq 0 ]] || die "document counts differ: standby was NOT replaced" verify_failed 4
  info "all collections match"
}

swap() {
  log "Swapping staging into standby"
  # MongoDB cannot rename a database, so collections move one by one.
  m_sh "$TARGET_URI" "
    const src=\"$STAGING\", dst=\"$DB_NAME\";
    const s=db.getSiblingDB(src);
    db.getSiblingDB(dst).dropDatabase();
    s.getCollectionNames().forEach(c=>db.adminCommand({renameCollection:src+\".\"+c,to:dst+\".\"+c,dropTarget:true}));
    s.dropDatabase();
    print(\"collections moved: \"+db.getSiblingDB(dst).getCollectionNames().length);
  " 2>/dev/null | grep -E "collections moved" | sed 's/^/    /' || die "swap failed" restore_failed 5
}

rotate() {
  local n; n=$(ls -1t "$WORKDIR"/mongo-"$DB_NAME"-*.gz "$WORKDIR"/mongo-"$DB_NAME"-*.archive 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$n" -gt "$KEEP_ARCHIVES" ]]; then
    ls -1t "$WORKDIR"/mongo-"$DB_NAME"-*.gz "$WORKDIR"/mongo-"$DB_NAME"-*.archive | tail -n +$((KEEP_ARCHIVES+1)) | xargs rm -f
    info "archives kept: $KEEP_ARCHIVES"
  fi
}

main() {
  preflight
  versions
  dump
  if [[ "$DO_RESTORE" == "yes" ]]; then
    restore_and_verify
    swap
  else
    COLLS=$(counts "$SOURCE_URI" "$DB_NAME" | wc -l | tr -d ' ')
  fi
  rotate
  STATUS="ok"
  log "Done in $(( $(date -u +%s) - STARTED_AT ))s"
}

main "$@"
