#!/usr/bin/env bash
# Integration regression test for atomic archive publication.
set -u

SCRIPT="${1:-$(dirname "$0")/../dr-mirror-mongo.sh}"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/work"

cat > "$ROOT/bin/mongodump" <<'MOCK'
#!/usr/bin/env bash
for arg; do [[ "$arg" == --archive=* ]] && archive=${arg#--archive=}; done
if [[ "${BAD_DUMP:-0}" == 1 ]]; then
  printf 'not a gzip stream' > "$archive"
else
  printf 'valid archive' | gzip -c > "$archive"
fi
MOCK
cat > "$ROOT/bin/mongorestore" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$ROOT/bin/mongosh" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == *serverBuildInfo* ]] && printf '8.0.0\n'
MOCK
chmod +x "$ROOT/bin/"*

run_mirror() {
  PATH="$ROOT/bin:$PATH" MONGO_SOURCE_URI=mongodb://source MONGO_DB_NAME=testdb \
    MONGO_MIRROR_WORKDIR="$ROOT/work" BAD_DUMP="${1:-0}" \
    bash "$SCRIPT" --no-restore >/dev/null 2>&1
}

touch "$ROOT/work/mongo-testdb-stale.gz.partial"
if run_mirror 0 &&
   ! find "$ROOT/work" -name '*.partial' -print -quit | grep -q . &&
   find "$ROOT/work" -name 'mongo-testdb-*.gz' -print -quit | grep -q .; then
  echo "PASS  verified dump published atomically and stale partial removed"
else
  echo "FAIL  successful atomic publication"
  exit 1
fi

rm -f "$ROOT/work"/mongo-testdb-*.gz
if run_mirror 1; then
  echo "FAIL  corrupt dump unexpectedly succeeded"
  exit 1
fi
if find "$ROOT/work" -name 'mongo-testdb-*.gz' -print -quit | grep -q .; then
  echo "FAIL  corrupt dump was published under its final name"
  exit 1
fi
if ! find "$ROOT/work" -name '*.gz.partial' -print -quit | grep -q .; then
  echo "FAIL  failed dump did not remain clearly marked partial"
  exit 1
fi
echo "PASS  corrupt dump remains partial and is never published"
