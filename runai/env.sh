# Shared settings for the Run:ai layer. Sourced by every runai/ step, on top
# of the rke2 settings in ../scripts/env.sh. Override anything in the
# environment before running a step.
RUNAI_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$RUNAI_SRC/../scripts/env.sh"

# --- versions (everything is pinned; bump here, re-run 11-mirror.sh) -------
: "${RUNAI_VERSION:=3.0.20}"                 # NVIDIA Run:ai self-hosted (runai-oss)
: "${HELM_VERSION:=v3.22.1}"
: "${KPS_VERSION:=92.16.1}"                  # prometheus-community/kube-prometheus-stack
: "${CSI_NFS_VERSION:=4.13.6}"               # kubernetes-csi/csi-driver-nfs
: "${FAKE_GPU_VERSION:=0.2.1}"               # run-ai/fake-gpu-operator
: "${GPU_OPERATOR_VERSION:=v26.7.2}"         # nvidia/gpu-operator

# --- deployment shape -------------------------------------------------------
: "${RUNAI_SIZING:=lab}"            # adds values/<chart>-<sizing>.yaml when present; "prod" = none
: "${GPU_MODE:=fake}"               # fake (simulated GPUs) | nvidia (GPU operator) | none
: "${RUNAI_DOMAIN:=runai.htd.local}"
: "${RUNAI_ADMIN_USER:=admin@htd.local}"
: "${RUNAI_CLUSTER_NAME:=htd}"
: "${RUNAI_INGRESS_CLASS:=traefik}" # RKE2's bundled ingress controller

# --- storage: NFS export on ww1 -> default StorageClass ---------------------
: "${RUNAI_NFS_SERVER:=$WW_INTERNAL_IP}"
: "${RUNAI_NFS_DIR:=/var/lib/runai-nfs}"
: "${RUNAI_STORAGECLASS:=runai-nfs}"

# --- Warewulf ---------------------------------------------------------------
: "${RUNAI_WW_OVERLAY:=runai}"
: "${RUNAI_WW_PROFILE:=runai}"
: "${RUNAI_DISK:=/dev/vda}"                  # local disk on every compute node
: "${RUNAI_DISK_RKE2_MIB:=40960}"           # /var/lib/rancher (images); rest -> /var/lib/kubelet
: "${FAKE_GPU_POOL:=default}"               # topology pool in values/fake-gpu-operator.yaml

# --- workload registry: pull-only view of the local registry -----------------
# What Run:ai users/workloads see (environments, queries). Production: your
# Harbor/Quay/Artifactory project + a pull-only robot account.
: "${WL_REG_PORT:=5001}"
: "${WL_REG_USER:=runai-pull}"
: "${WL_REG_PREFIX:=workloads}"             # curated images live under <registry>/workloads/
WL_REGISTRY="${WW_INTERNAL_IP}:${WL_REG_PORT}"

# --- local state on ww1 -----------------------------------------------------
: "${RUNAI_DIR:=/etc/runai}"                # admin password, TLS key/cert (secrets)
: "${RUNAI_WORK:=/var/lib/runai-deploy}"    # artifact lock, chart tarballs, image list
RUNAI_RELEASES=https://github.com/dsx-ai-factory/run-ai/releases/download
RUNAI_ARCH=$(uname -m); case "$RUNAI_ARCH" in aarch64) RUNAI_ARCH=arm64;; x86_64) RUNAI_ARCH=amd64;; esac
REGISTRY="${WW_INTERNAL_IP}:${REG_PORT}"
CHART_REPO="oci://${REGISTRY}/charts"       # every chart is installed from here

export RUNAI_SRC RUNAI_VERSION HELM_VERSION KPS_VERSION CSI_NFS_VERSION FAKE_GPU_VERSION GPU_OPERATOR_VERSION \
       RUNAI_SIZING GPU_MODE RUNAI_DOMAIN RUNAI_ADMIN_USER RUNAI_CLUSTER_NAME RUNAI_INGRESS_CLASS \
       RUNAI_NFS_SERVER RUNAI_NFS_DIR RUNAI_STORAGECLASS RUNAI_WW_OVERLAY RUNAI_WW_PROFILE \
       RUNAI_DISK RUNAI_DISK_RKE2_MIB FAKE_GPU_POOL RUNAI_DIR RUNAI_WORK \
       WL_REG_PORT WL_REG_USER WL_REG_PREFIX WL_REGISTRY

HELM="helm --kubeconfig /etc/rancher/rke2/rke2.yaml"

# "-f values/<name>.yaml [-f values/<name>-<sizing>.yaml]"
values() {
  local f="$RUNAI_SRC/values/$1"
  printf -- '-f %s.yaml' "$f"
  [ -f "$f-$RUNAI_SIZING.yaml" ] && printf -- ' -f %s-%s.yaml' "$f" "$RUNAI_SIZING"
  echo
}

# Create-or-update from stdin, namespace created on demand.
ensure_ns() { $KUBECTL create ns "$1" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null; }
