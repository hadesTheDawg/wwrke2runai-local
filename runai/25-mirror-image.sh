#!/bin/bash
# Copy any image into the workload registry by hand (all architectures,
# digests preserved), so workloads on the offline nodes can use it:
#
#   25-mirror-image.sh <source> [<name>:<tag>]
#
#   25-mirror-image.sh quay.io/jupyter/minimal-notebook:2026-10-28
#     -> 10.10.172.1:5001/workloads/minimal-notebook:2026-10-28
#   25-mirror-image.sh docker.io/kalilinux/kali-rolling:latest kali-rolling:2026-10-31
#
# Use the printed reference as the image of a workload, or make it a
# selectable Run:ai environment by adding it to catalog/environments.yaml and
# running 24-workload-catalog.sh. Pin real tags: an existing local tag is
# never overwritten (FORCE=1 re-copies).
set -euo pipefail
. "$(dirname "$0")/env.sh"
SRC=${1:?usage: $0 <source image> [<name>:<tag>]}

if [ -n "${2:-}" ]; then
  DEST=$2
else
  repo=${SRC%@*}; tag=latest
  case "${repo##*/}" in *:*) tag=${repo##*:}; repo=${repo%:*} ;; esac
  DEST="${repo##*/}:$tag"
fi
case "$DEST" in *:*) ;; *) DEST="$DEST:latest" ;; esac

PUSH="$(cat "$REG_DIR/username"):$(cat "$REG_DIR/password")"
RW="$REGISTRY/$WL_REG_PREFIX/$DEST"          # pushed via the read-write registry
REF="$WL_REGISTRY/$WL_REG_PREFIX/$DEST"      # what workloads reference (pull-only view)

if [ -z "${FORCE:-}" ] && skopeo inspect --raw --creds "$PUSH" "docker://$RW" >/dev/null 2>&1; then
  echo "already present: $REF"
else
  skopeo inspect --raw "docker://$SRC" >/dev/null || { echo "cannot read $SRC upstream" >&2; exit 1; }
  echo "copying $SRC (all architectures) ..."
  skopeo copy -q --multi-arch all --preserve-digests --dest-creds "$PUSH" "docker://$SRC" "docker://$RW"
fi
archs=$(skopeo inspect --raw --creds "$PUSH" "docker://$RW" | python3 -c 'import json,sys
d = json.load(sys.stdin)
print(",".join(sorted({m["platform"]["architecture"] for m in d.get("manifests", []) if m["platform"]["architecture"] != "unknown"})) or "single-arch")')
echo "image:  $REF   ($archs)"
cat <<EOF
catalog entry (catalog/environments.yaml, then 24-workload-catalog.sh):
  - name: ${DEST%%:*}
    description: ${DEST%%:*} (${SRC})
    source: $SRC
    image: $DEST
EOF
