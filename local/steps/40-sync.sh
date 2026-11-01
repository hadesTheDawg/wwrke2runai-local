#!/bin/bash
# Unattended run of the make targets in SYNC_TARGETS (default "fetch"), as
# scheduled by 41-schedule.sh. One run at a time (lock directory), output
# appended with timestamps to state/sync.log, non-zero exit on failure.
. "$(dirname "$0")/../lib/common.sh"
: "${SYNC_TARGETS:=fetch}"
mkdir -p "$STATE"
LOCK="$STATE/sync.lock"
LOG="$STATE/sync.log"

if ! mkdir "$LOCK" 2>/dev/null; then
  pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "$(date -u +%FT%TZ) sync already running (pid $pid), skipped" >> "$LOG"; exit 0
  fi
  rm -rf "$LOCK"; mkdir "$LOCK"           # stale lock from a killed run
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

{
  echo "=== $(date -u +%FT%TZ) sync: make $SYNC_TARGETS"
  rc=0
  make -C "$ROOT" $SYNC_TARGETS ENV_FILE="$ENV_FILE" || rc=$?
  echo "=== $(date -u +%FT%TZ) sync finished: rc=$rc"
} >> "$LOG" 2>&1
exit $rc
