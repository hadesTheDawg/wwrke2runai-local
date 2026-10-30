#!/bin/bash
# Populate the "rke2" site overlay from ../overlay/rke2 and create the
# agent-only join token it references.
set -euo pipefail
. "$(dirname "$0")/env.sh"
SRC="$(cd "$(dirname "$0")/../overlay/$WW_OVERLAY" && pwd)"

# Agent-only bootstrap token (cannot join servers), never expires.
TOKFILE=/etc/rancher/rke2/ww-agent-token
if [ ! -s "$TOKFILE" ]; then
  rke2 token create --ttl 0 --description "warewulf rke2 overlay agents" > "$TOKFILE"
fi
chmod 600 "$TOKFILE"

wwctl overlay list "$WW_OVERLAY" >/dev/null 2>&1 || wwctl overlay create "$WW_OVERLAY"
OVLDIR="$(awk '/wwoverlaydir:/{print $2}' /etc/warewulf/warewulf.conf)"
DEST="${OVLDIR:-/var/lib/warewulf/overlays}/$WW_OVERLAY"

mkdir -p "$DEST/rootfs"
cp -a --no-preserve=ownership "$SRC/rootfs/." "$DEST/rootfs/"
chown -R root:root "$DEST/rootfs"
# secrets end up in these files: keep them root-only on the node
chmod 0600 "$DEST/rootfs/etc/rancher/rke2/config.yaml.ww" \
           "$DEST/rootfs/etc/rancher/rke2/registries.yaml.ww" \
           "$DEST/rootfs/etc/rancher/node/password.ww"
chmod 0700 "$DEST/rootfs/etc/rancher/node"

wwctl overlay list -a "$WW_OVERLAY"
