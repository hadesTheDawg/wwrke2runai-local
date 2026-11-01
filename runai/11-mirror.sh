#!/bin/bash
# Put everything Run:ai needs into the local registry on ww1:
#   charts  -> oci://<ww1>:5000/charts/<name>:<version>
#   images  -> <ww1>:5000/<upstream path>   (the registries.yaml mirror path)
#
# Run:ai's charts and images come from NVIDIA's ArtifactLock for this exact
# version and architecture (the same file `runai-installer airgap pack` uses):
# charts are checked against the locked sha256, images are copied by their
# locked index digest. Add-on images are found by rendering the add-on charts
# with our values. Idempotent; re-run after bumping versions in env.sh.
#
# Air-gapped production: run this on a connected host with REGISTRY pointed
# at a transfer registry, or use `runai-installer airgap pack/load`.
set -euo pipefail
. "$(dirname "$0")/env.sh"
LIB="$RUNAI_SRC/lib"
CREDS="$(cat "$REG_DIR/username"):$(cat "$REG_DIR/password")"

mkdir -p "$RUNAI_WORK/charts"
cd "$RUNAI_WORK"

# --- Run:ai artifact lock -------------------------------------------------
LOCK="runai-${RUNAI_VERSION}-standard-linux-${RUNAI_ARCH}.yaml"
[ -s "$LOCK" ] || curl -fsSLo "$LOCK" "$RUNAI_RELEASES/$RUNAI_VERSION/$LOCK"
echo "artifact lock: $RUNAI_WORK/$LOCK"

# --- charts ---------------------------------------------------------------
push_chart() {   # <tgz>
  local name ver
  read -r name ver < <(helm show chart "$1" | awk '/^name:/{n=$2} /^version:/{v=$2} END{gsub(/"/,"",v); print n, v}')
  if $HELM show chart "$CHART_REPO/$name" --version "$ver" >/dev/null 2>&1; then
    echo "  have   chart $name $ver"
  else
    helm push "$1" "$CHART_REPO" >/dev/null && echo "  pushed chart $name $ver"
  fi
}

while read -r name ver url digest; do
  tgz="charts/$name-$ver.tgz"
  [ -s "$tgz" ] || curl -fsSLo "$tgz" "$url"
  echo "${digest#sha256:}  $tgz" | sha256sum -c --quiet - || { echo "digest mismatch: $tgz" >&2; exit 1; }
  push_chart "$tgz"
done < <(python3 "$LIB/lock-images.py" "$LOCK" charts)

pull_chart() {   # <name> <version> <helm pull source args...>
  local name=$1 ver=$2; shift 2
  [ -s "charts/$name-$ver.tgz" ] || helm pull "$@" --version "$ver" -d charts >/dev/null
  push_chart "charts/$name-$ver.tgz"
}
pull_chart kube-prometheus-stack "$KPS_VERSION" kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts
pull_chart csi-driver-nfs "$CSI_NFS_VERSION" csi-driver-nfs --repo https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
pull_chart fake-gpu-operator "$FAKE_GPU_VERSION" oci://ghcr.io/run-ai/fake-gpu-operator/fake-gpu-operator
pull_chart gpu-operator "$GPU_OPERATOR_VERSION" gpu-operator --repo https://helm.ngc.nvidia.com/nvidia

# --- Run:ai images, pinned by digest ---------------------------------------
echo "Run:ai $RUNAI_VERSION images ($RUNAI_ARCH lock) -> $REGISTRY"
fail=0
while read -r src digest; do
  repo="${src%:*}"; path="${src#*/}"         # drop upstream registry host
  # docker.io/<name> is requested from mirrors as library/<name>
  case "$src" in docker.io/*/*) ;; docker.io/*) path="library/$path" ;; esac
  have=$(skopeo inspect --raw --creds "$CREDS" "docker://$REGISTRY/$path" 2>/dev/null | sha256sum | awk '{print $1}') || true
  if [ "sha256:$have" = "$digest" ]; then echo "  have   $path"; continue; fi
  if skopeo copy -q --multi-arch all --preserve-digests --dest-creds "$CREDS" \
       "docker://$repo@$digest" "docker://$REGISTRY/$path"; then
    echo "  copied $path"
  else
    echo "  FAILED $src@$digest" >&2; fail=1
  fi
done < <(python3 "$LIB/lock-images.py" "$LOCK" images)

# --- add-on images: render the charts with our values ----------------------
ADDONS=$(mktemp); trap 'rm -f "$ADDONS"' EXIT
render() {   # <release> <chart> <version> <values...>
  local rel=$1 chart=$2 ver=$3; shift 3
  $HELM template "$rel" "charts/$chart-$ver.tgz" "$@" | python3 "$LIB/chart-images.py" >> "$ADDONS"
}
render kube-prometheus-stack kube-prometheus-stack "$KPS_VERSION" $(values kube-prometheus-stack)
render csi-driver-nfs csi-driver-nfs "$CSI_NFS_VERSION" $(values csi-driver-nfs)
case "$GPU_MODE" in
  fake)
    render fake-gpu-operator fake-gpu-operator "$FAKE_GPU_VERSION" $(values fake-gpu-operator)
    # started at runtime by status-updater, not visible in the manifests
    $HELM show values "charts/fake-gpu-operator-$FAKE_GPU_VERSION.tgz" | python3 -c '
import sys, yaml; m = yaml.safe_load(sys.stdin)["nvmlMock"]["image"]; print(m["repository"] + ":" + m["tag"])' >> "$ADDONS" ;;
  nvidia)
    render gpu-operator gpu-operator "$GPU_OPERATOR_VERSION" $(values gpu-operator) ;;
esac
# Not in NVIDIA's lock: with gpuSharingMode NvFractions (Run:ai default)
# KAI's binder creates the GPU reservation pods of fractional workloads from
# a bare "ubuntu" image (sleep infinity) -> docker.io/library/ubuntu:latest.
echo "docker.io/library/ubuntu:latest" >> "$ADDONS"
# image the smoke test (30-smoke-test.sh) runs
echo "docker.io/library/ubuntu:24.04" >> "$ADDONS"

sort -u "$ADDONS" -o "$ADDONS"
cp "$ADDONS" "$RUNAI_WORK/addon-images.txt"
echo "add-on images ($(wc -l < "$ADDONS")) via scripts/03-mirror-images.sh"
EXTRA_IMAGES="$(cat "$ADDONS")" "$RUNAI_SRC/../scripts/03-mirror-images.sh" | grep -v '^  have' || fail=1

exit $fail
