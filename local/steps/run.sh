#!/bin/bash
# run.sh <phase|step>...   (called by the Makefile)
# Phases expand to step lists from .env: fetch -> FETCH_STEPS,
# deploy -> DEPLOY_STEPS. Steps run in the order given; the first failure stops.
. "$(dirname "$0")/../lib/common.sh"
: "${FETCH_STEPS:=facts artifacts images features overlays verify}"
: "${DEPLOY_STEPS:=preflight push prometheus gpu storage control-plane cluster catalog project-volumes verify-target}"

script() {
  case "$1" in
    facts) echo 01-facts.sh ;;          artifacts) echo 02-artifacts.sh ;;
    images) echo 03-images.sh ;;        features) echo 04-features.sh ;;
    verify) echo 05-verify.sh ;;        overlays) echo 06-overlays.sh ;;
    bundle) echo 07-bundle.sh ;;        unbundle) echo 08-unbundle.sh ;;
    preflight) echo 10-preflight.sh ;;  push) echo 11-push.sh ;;
    registries) echo 12-registries.sh ;; prometheus) echo 13-prometheus.sh ;;
    gpu) echo 14-gpu.sh ;;              storage) echo 15-storage.sh ;;
    control-plane) echo 16-control-plane.sh ;; cluster) echo 17-cluster.sh ;;
    catalog) echo 18-catalog.sh ;;      project-volumes) echo 19-project-volumes.sh ;;
    verify-target) echo 20-verify.sh ;; ww-overlays) echo 30-ww-overlays.sh ;;
    *) return 1 ;;
  esac
}

steps=""
for a; do
  case "$a" in
    fetch)  steps="$steps $FETCH_STEPS" ;;
    deploy) steps="$steps $DEPLOY_STEPS" ;;
    *)      steps="$steps $a" ;;
  esac
done

for s in $steps; do script "$s" >/dev/null || die "unknown step '$s'"; done
for s in $steps; do
  say ""; say "=== $s ($(script "$s"))"
  # a fetch writes new content: refresh the checksums it is verified against
  if [ "$s" = verify ] && case " $* " in *" fetch "*) true ;; *) false ;; esac; then
    VERIFY_WRITE=yes "$LOCAL_SRC/steps/$(script "$s")"
  else
    "$LOCAL_SRC/steps/$(script "$s")"
  fi
done
