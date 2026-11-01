#!/bin/bash
# Optional storage features: charts and images for the Weka and CephFS CSI
# drivers (WEKA_CSI=yes / CEPHFS_CSI=yes). Images are found by rendering the
# charts with local/features/<driver>/values.yaml.
#
# These are not on the remote system unless you put them there. Two ways:
#   FEATURE_SOURCE=upstream  (default) copy from the public registries
#   FEATURE_SOURCE=remote    only print the image list; mirror it onto the
#                            remote first, then `make images` takes them
#                            like everything else:
#     EXTRA_IMAGES="$(cat state/feature-images.txt)" scripts/03-mirror-images.sh
. "$(dirname "$0")/../lib/common.sh"
: "${FEATURE_SOURCE:=upstream}"
: "${WEKA_CSI_VERSION:=}"
: "${CEPH_CSI_VERSION:=}"
mkdir -p "$CHARTS" "$STATE"

pull() {   # <name> <repo url> <version or "">
  local have
  have=$(ls "$CHARTS"/"$1"-[0-9v]*.tgz 2>/dev/null | head -1 || true)
  if [ -n "$3" ] && [ -s "$CHARTS/$1-$3.tgz" ]; then echo "$CHARTS/$1-$3.tgz"; return; fi
  if [ -z "$3" ] && [ -n "$have" ]; then echo "$have"; return; fi
  helm pull "$1" --repo "$2" ${3:+--version "$3"} -d "$CHARTS" >/dev/null
  ls -t "$CHARTS"/"$1"-[0-9v]*.tgz | head -1
}

LIST="$STATE/feature-images.txt"; : > "$LIST"
if is_yes "$WEKA_CSI"; then
  tgz=$(pull csi-wekafsplugin https://weka.github.io/csi-wekafs "$WEKA_CSI_VERSION")
  say "weka:   $(basename "$tgz")"
  helm template csi-wekafs "$tgz" -n csi-wekafs -f "$LOCAL_SRC/features/weka/values.yaml" \
    | $PY "$RKE2_DEPLOY_REPO/runai/lib/chart-images.py" >> "$LIST"
fi
if is_yes "$CEPHFS_CSI"; then
  tgz=$(pull ceph-csi-cephfs https://ceph.github.io/csi-charts "$CEPH_CSI_VERSION")
  say "cephfs: $(basename "$tgz")"
  helm template ceph-csi-cephfs "$tgz" -n ceph-csi-cephfs -f "$LOCAL_SRC/features/cephfs/values.yaml" \
    | $PY "$RKE2_DEPLOY_REPO/runai/lib/chart-images.py" >> "$LIST"
fi
sort -u -o "$LIST" "$LIST"
[ -s "$LIST" ] || { say "no storage features enabled (WEKA_CSI/CEPHFS_CSI)"; exit 0; }
say "feature images ($(wc -l < "$LIST" | tr -d ' ')): $LIST"

if [ "$FEATURE_SOURCE" = remote ]; then
  say "FEATURE_SOURCE=remote: mirror them onto the remote, then run make images:"
  say "  EXTRA_IMAGES=\"$(tr '\n' ' ' < "$LIST")\" scripts/03-mirror-images.sh"
  exit 0
fi

[ -n "$SKOPEO" ] || die "skopeo not found"
fail=0
while read -r src; do
  ref="${src#docker.io/}"
  case "$ref" in
    */*/*|*.*/*) path="${ref#*/}" ;;
    */*) path="$ref" ;;
    *) path="library/$ref" ;;
  esac
  path="${path%@*}"
  case "${path##*/}" in *:*) ;; *) path="$path:latest" ;; esac
  if [ -f "$IMAGES/${path%:*}@${path##*:}/manifest.json" ]; then
    say "  have   $path"
  elif store_copy "docker://$src" "$IMAGES/${path%:*}@${path##*:}"; then
    say "  copied $path  <- $src"
  else
    warn "FAILED $src"; fail=1
  fi
done < "$LIST"
exit $fail
