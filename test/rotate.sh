#!/usr/bin/env bash
#
# Regression test for rotate().
#
# The bug this guards against: rotate() listed both the .gz and the .archive
# pattern in one `ls`. A run writes one or the other, never both, so `ls` always
# exited non-zero (2 on GNU coreutils, 1 on BSD) and `set -euo pipefail` killed
# the script right there — after dump, restore and verify had already succeeded.
# Every good run was recorded as a failure, and no archive was ever rotated away.
#
# Each case runs in its own bash process with `set -euo pipefail` on, because the
# abort *is* `set -e`: a harness that turns it off cannot see the bug at all.
#
# Usage: test/rotate.sh [path-to-script]
#
set -uo pipefail

SCRIPT="${1:-$(dirname "$0")/../dr-mirror-mongo.sh}"
[[ -f "$SCRIPT" ]] || { echo "script not found: $SCRIPT" >&2; exit 1; }

FUNCS=$(sed -n '/^list_archives() {/,/^}/p;/^rotate() {/,/^}/p' "$SCRIPT")
FAILED=0

run() { # run <description> <archives> <keep> <expected remaining>
  local desc="$1" count="$2" keep="$3" expected="$4"
  local dir; dir=$(mktemp -d)
  # Not `seq 1 $count`: BSD seq counts *down* when the end is lower than the
  # start, so `seq 1 0` yields "1 0" and the empty case is not empty at all.
  local i=1; while (( i <= count )); do : > "$dir/mongo-testdb-$i.gz"; ((i++)); done

  local out rc
  out=$(bash -c '
    set -euo pipefail
    WORKDIR="'"$dir"'"; DB_NAME=testdb; KEEP_ARCHIVES='"$keep"'
    info() { :; }
    '"$FUNCS"'
    rotate
    echo SURVIVED
  ' 2>&1); rc=$?

  local left; left=$(ls -1 "$dir" | wc -l | tr -d ' ')
  if [[ $rc -eq 0 ]] && grep -q SURVIVED <<< "$out" && [[ "$left" == "$expected" ]]; then
    printf 'PASS  %-32s exit=%s remaining=%s\n' "$desc" "$rc" "$left"
  else
    printf 'FAIL  %-32s exit=%s remaining=%s expected=%s\n' "$desc" "$rc" "$left" "$expected"
    FAILED=1
  fi
  rm -rf "$dir"
}

run "below retention"      3  7 3
run "above retention"     10  7 7
run "empty directory"      0  7 0
run "exactly at retention" 7  7 7

# Interrupted dumps must not enter the retention count or be removed by rotate.
partial_dir=$(mktemp -d)
touch "$partial_dir/mongo-testdb-old.gz.partial"
WORKDIR="$partial_dir" DB_NAME=testdb KEEP_ARCHIVES=1
info() { :; }
eval "$FUNCS"
rotate
if [[ -f "$partial_dir/mongo-testdb-old.gz.partial" ]]; then
  printf 'PASS  %-32s partial preserved\n' "partial archive ignored"
else
  printf 'FAIL  %-32s partial was removed\n' "partial archive ignored"
  FAILED=1
fi
rm -rf "$partial_dir"

exit "$FAILED"
