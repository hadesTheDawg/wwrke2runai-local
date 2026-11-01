#!/bin/bash
# Schedule `make sync` from .env: SYNC_SCHEDULE (cron expression) runs
# SYNC_TARGETS. One crontab line per checkout, tagged with this checkout's
# path, so install/remove never touch other entries.
#   41-schedule.sh install | remove | show
. "$(dirname "$0")/../lib/common.sh"
: "${SYNC_SCHEDULE:=}"
: "${SYNC_TARGETS:=fetch}"
TAG="# rke2_deploy_ww sync $ROOT"

current() { crontab -l 2>/dev/null | grep -vF "$TAG" || true; }

case "${1:-show}" in
  install)
    need SYNC_SCHEDULE
    # cron starts with a bare PATH: keep the one that finds helm/skopeo now
    line="$SYNC_SCHEDULE PATH=$PATH HOME=$HOME ENV_FILE=$ENV_FILE SYNC_TARGETS='$SYNC_TARGETS' /bin/bash $LOCAL_SRC/steps/40-sync.sh $TAG"
    keep=$(current)
    { [ -n "$keep" ] && echo "$keep"; echo "$line"; } | crontab -
    say "scheduled: $SYNC_SCHEDULE -> make $SYNC_TARGETS (log: $STATE/sync.log)"
    case "$(uname)" in Darwin) say "macOS: cron needs Full Disk Access if RUNAI_REPO is in a protected folder (System Settings > Privacy)";; esac ;;
  remove)
    keep=$(current)
    if [ -n "$keep" ]; then echo "$keep" | crontab -; else crontab -r 2>/dev/null || true; fi
    say "removed the sync schedule for $ROOT" ;;
  show)
    crontab -l 2>/dev/null | grep -F "$TAG" || say "no sync scheduled for $ROOT" ;;
  *) die "usage: $0 install|remove|show" ;;
esac
