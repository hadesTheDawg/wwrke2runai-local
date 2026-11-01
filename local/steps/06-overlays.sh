#!/bin/bash
# Package the Warewulf overlays (rke2, runai, csi-storage) and a snapshot of
# the deployment sources (values, catalog, org, scripts, this toolkit) into
# the local repository, so a bundle is self-contained. Profiles, images,
# node definitions and the Warewulf server itself are site infrastructure
# and are not part of it.
. "$(dirname "$0")/../lib/common.sh"
: "${WW_OVERLAYS:=rke2 runai csi-storage}"
mkdir -p "$RUNAI_REPO/warewulf/overlays" "$RUNAI_REPO/source"

for o in $WW_OVERLAYS; do
  [ -d "$RKE2_DEPLOY_REPO/overlay/$o" ] || die "no overlay $o in $RKE2_DEPLOY_REPO/overlay"
  rsync -a --delete "$RKE2_DEPLOY_REPO/overlay/$o/" "$RUNAI_REPO/warewulf/overlays/$o/"
  say "overlay $o: $(find "$RUNAI_REPO/warewulf/overlays/$o" -type f -o -type l | wc -l | tr -d ' ') files"
done

rsync -a --delete --exclude .git --exclude .env --exclude '_runai-repo*' --exclude '*.tar' \
  --include '/overlay/***' --include '/scripts/***' --include '/local/***' \
  --include '/runai/***' --include '/*.md' --include '/Makefile' --include '/.env.example' \
  --exclude '*' "$RKE2_DEPLOY_REPO/" "$RUNAI_REPO/source/"
rev=$(git -C "$RKE2_DEPLOY_REPO" describe --always --dirty 2>/dev/null || echo unknown)
echo "$rev" > "$RUNAI_REPO/source/REVISION"
say "source snapshot of $RKE2_DEPLOY_REPO ($rev) in $RUNAI_REPO/source"
