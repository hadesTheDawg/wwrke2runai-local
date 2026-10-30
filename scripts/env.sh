# Shared settings for the rke2-on-warewulf scripts. Sourced by every step.
# Override any of these in the environment before running a step.

# Internal (cluster/provisioning) side of ww1
: "${WW_INTERNAL_IP:=10.10.172.1}"
: "${WW_EXTERNAL_IP:=192.168.65.2}"
: "${WW_FQDN:=ww1.htd.local}"

# Local registry
: "${REG_PORT:=5000}"
: "${REG_DIR:=/etc/rke2-registry}"          # certs, htpasswd, credentials
: "${REG_DATA:=/var/lib/rke2-registry}"     # blob storage
: "${REG_USER:=rke2}"
: "${REG_IMAGE:=docker.io/library/registry:2}"

# Warewulf objects
: "${WW_IMAGE:=rocky-9}"
: "${WW_OVERLAY:=rke2}"
: "${WW_PROFILE:=rke2}"

# RKE2 version is pinned to whatever the server is running
RKE2_VERSION="$(rke2 --version | awk 'NR==1{print $3}')"   # e.g. v1.36.5+rke2r1
export WW_INTERNAL_IP WW_EXTERNAL_IP WW_FQDN REG_PORT REG_DIR REG_DATA REG_USER REG_IMAGE WW_IMAGE WW_OVERLAY WW_PROFILE RKE2_VERSION

KUBECTL="/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
