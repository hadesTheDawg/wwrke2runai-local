#!/bin/bash
# Mirror every image an RKE2 agent needs into the local registry.
# Sources: the official per-release image lists for this exact RKE2 version,
# plus every image currently referenced by pods in the cluster (catches
# DaemonSets/addons). Re-run any time; already-present images are skipped.
set -euo pipefail
. "$(dirname "$0")/env.sh"

ARCH=$(uname -m); case "$ARCH" in aarch64) ARCH=arm64;; x86_64) ARCH=amd64;; esac
REL="https://github.com/rancher/rke2/releases/download/${RKE2_VERSION/+/%2B}"
DEST="${WW_INTERNAL_IP}:${REG_PORT}"
CREDS="$(cat "$REG_DIR/username"):$(cat "$REG_DIR/password")"

LIST=$(mktemp)
for f in rke2-images-core rke2-images-canal ${EXTRA_IMAGE_LISTS:-}; do
  curl -fsSL "$REL/$f.linux-$ARCH.txt" >> "$LIST" || echo "WARN: no $f list for $RKE2_VERSION" >&2
done
$KUBECTL get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' >> "$LIST"
[ -n "${EXTRA_IMAGES:-}" ] && printf '%s\n' $EXTRA_IMAGES >> "$LIST"

# normalise to fully-qualified names
sort -u "$LIST" | sed '/^$/d' | while read -r img; do
  img="${img#index.docker.io/}"; img="${img#docker.io/}"
  case "$img" in
    */*/*|*.*/*) echo "$img" ;;   # already has a registry host
    */*) echo "docker.io/$img" ;;
    *)   echo "docker.io/library/$img" ;;
  esac
done | sort -u > "$LIST.fq"

echo "mirroring $(wc -l < "$LIST.fq") images -> $DEST"
fail=0
while read -r src; do
  path="${src#*/}"                        # strip upstream registry host
  if skopeo inspect --raw --creds "$CREDS" "docker://$DEST/$path" >/dev/null 2>&1; then
    echo "  have  $path"; continue
  fi
  if skopeo copy -q --multi-arch all --dest-creds "$CREDS" "docker://$src" "docker://$DEST/$path"; then
    echo "  copied $path"
  else
    echo "  FAILED $src" >&2; fail=1
  fi
done < "$LIST.fq"
rm -f "$LIST" "$LIST.fq"
exit $fail
