#!/bin/bash
# Install the bundled Warewulf overlays (rke2, runai, csi-storage) on the
# target site's Warewulf server WW_HOST, so its GPU nodes render RKE2/Run:ai
# node configuration pointing at the site's registry and RKE2 server.
#
# Only the overlays. Images, profiles, nodes, networking and the Warewulf
# server are site infrastructure: this step prints the profile tags to set
# but does not set them.
#
# The overlays read these files on the Warewulf server at build time:
#   /etc/rke2-registry/{username,password,ca.crt}       TARGET_REGISTRY account + CA
#   /etc/rke2-registry/{pull-username,pull-password}    TARGET_WORKLOAD_PULL_* (if a separate workload registry)
#   /etc/rke2-registry/node-password-seed               random, generated here if missing
#   /etc/rancher/rke2/ww-agent-token                    RKE2_AGENT_TOKEN_FILE (`rke2 token create` on the server)
# WW_INSTALL_SECRETS=yes writes them from .env (over ssh stdin, mode 0600);
# otherwise they are only checked. WW_BUILD=yes runs `wwctl overlay build`.
. "$(dirname "$0")/../lib/common.sh"
need WW_HOST
: "${WW_SSH_OPTS:=}"
: "${WW_OVERLAYS:=rke2 runai csi-storage}"
: "${WW_INSTALL_SECRETS:=no}"
: "${WW_BUILD:=no}"
: "${RKE2_AGENT_TOKEN_FILE:=}"
: "${RKE2_SERVER_URL:=}"
SRC="$RUNAI_REPO/warewulf/overlays"
[ -d "$SRC" ] || "$LOCAL_SRC/steps/06-overlays.sh"
wsh() { ssh -o BatchMode=yes $WW_SSH_OPTS "$WW_HOST" "$@"; }
put() { wsh "umask 077; mkdir -p \$(dirname $1); cat > $1.new && mv $1.new $1"; }   # <remote path> < content

STAGE=$(wsh 'mktemp -d /var/tmp/ww-overlays.XXXXXX')
trap 'wsh "rm -rf $STAGE"' EXIT
COPYFILE_DISABLE=1 tar -C "$SRC" -cf - $WW_OVERLAYS | wsh "tar -mxf - -C $STAGE"

wsh "set -euo pipefail
  OVLDIR=\$(awk '/wwoverlaydir:/{print \$2}' /etc/warewulf/warewulf.conf); OVLDIR=\${OVLDIR:-/var/lib/warewulf/overlays}
  for o in $WW_OVERLAYS; do
    wwctl overlay list \$o >/dev/null 2>&1 || wwctl overlay create \$o
    mkdir -p \$OVLDIR/\$o/rootfs
    cp -a --no-preserve=ownership $STAGE/\$o/rootfs/. \$OVLDIR/\$o/rootfs/
    chown -R root:root \$OVLDIR/\$o/rootfs
  done
  # secrets end up in these files: root-only on the node (as scripts/05, runai/15)
  R=\$OVLDIR/rke2/rootfs; [ -d \$R ] && chmod 0600 \$R/etc/rancher/rke2/config.yaml.ww \$R/etc/rancher/rke2/registries.yaml.ww \$R/etc/rancher/node/password.ww && chmod 0700 \$R/etc/rancher/node
  R=\$OVLDIR/runai/rootfs; [ -d \$R ] && chmod 0755 \$R/warewulf/wwinit.d/*.ww \$R/usr/bin/nvidia-container-runtime.ww && chmod 0600 \$R/etc/rancher/rke2/registries.yaml.ww
  true"
say "overlays installed on $WW_HOST: $WW_OVERLAYS"

if is_yes "$WW_INSTALL_SECRETS"; then
  need TARGET_REGISTRY_USER TARGET_REGISTRY_PASSWORD_FILE RKE2_AGENT_TOKEN_FILE
  printf '%s' "$TARGET_REGISTRY_USER" | put /etc/rke2-registry/username
  put /etc/rke2-registry/password < "$TARGET_REGISTRY_PASSWORD_FILE"
  if [ -n "$TARGET_REGISTRY_CA" ]; then put /etc/rke2-registry/ca.crt < "$TARGET_REGISTRY_CA"; fi
  if [ "$TARGET_WORKLOAD_REGISTRY" != "$TARGET_REGISTRY" ]; then
    printf '%s' "$TARGET_WORKLOAD_PULL_USER" | put /etc/rke2-registry/pull-username
    put /etc/rke2-registry/pull-password < "$TARGET_WORKLOAD_PULL_PASSWORD_FILE"
  fi
  put /etc/rancher/rke2/ww-agent-token < "$RKE2_AGENT_TOKEN_FILE"
  wsh '[ -s /etc/rke2-registry/node-password-seed ] || (umask 077; openssl rand -hex 32 > /etc/rke2-registry/node-password-seed)'
  say "overlay inputs written on $WW_HOST"
fi

INPUTS="/etc/rke2-registry/username /etc/rke2-registry/password /etc/rke2-registry/ca.crt
        /etc/rke2-registry/node-password-seed /etc/rancher/rke2/ww-agent-token"
[ "$TARGET_WORKLOAD_REGISTRY" != "$TARGET_REGISTRY" ] && INPUTS="$INPUTS /etc/rke2-registry/pull-username /etc/rke2-registry/pull-password"
missing=$(wsh "for f in $(echo $INPUTS); do [ -s \$f ] || echo \$f; done")
[ -z "$missing" ] || warn "overlay inputs missing on $WW_HOST (WW_INSTALL_SECRETS=yes, or create them):
$missing"

is_yes "$WW_BUILD" && wsh 'wwctl overlay build' >/dev/null && say "overlays built"

PROFILE_TAGS="rke2_registry=$TARGET_REGISTRY"
[ -n "$TARGET_REGISTRY_PREFIX" ] && PROFILE_TAGS="$PROFILE_TAGS,rke2_registry_prefix=$TARGET_REGISTRY_PREFIX"
PROFILE_TAGS="$PROFILE_TAGS,rke2_workload_registry=$TARGET_WORKLOAD_REGISTRY"
[ -n "$RKE2_SERVER_URL" ] && PROFILE_TAGS="$PROFILE_TAGS,rke2_server=$RKE2_SERVER_URL"
cat <<EOF

Point the GPU node profile at the site (on $WW_HOST, profile of your choice):
  wwctl profile set -y <profile> --tagadd "$PROFILE_TAGS"
  # and add rke2,runai,csi-storage to that profile's --system-overlays list
Optional csi-storage tags: csi_cephfs=yes, weka_hugepages=<2MiB pages>,
  weka_reserved_cpus=<cpu list>, weka_reserved_memory=<e.g. 6Gi>
Then: wwctl overlay build, reboot the nodes.
EOF
