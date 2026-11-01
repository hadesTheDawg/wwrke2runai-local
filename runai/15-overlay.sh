#!/bin/bash
# Install the "runai" site overlay from ../overlay/runai.
set -euo pipefail
. "$(dirname "$0")/env.sh"
SRC="$(cd "$RUNAI_SRC/../overlay/$RUNAI_WW_OVERLAY" && pwd)"

wwctl overlay list "$RUNAI_WW_OVERLAY" >/dev/null 2>&1 || wwctl overlay create "$RUNAI_WW_OVERLAY"
OVLDIR="$(awk '/wwoverlaydir:/{print $2}' /etc/warewulf/warewulf.conf)"
DEST="${OVLDIR:-/var/lib/warewulf/overlays}/$RUNAI_WW_OVERLAY"

mkdir -p "$DEST/rootfs"
cp -a --no-preserve=ownership "$SRC/rootfs/." "$DEST/rootfs/"
chown -R root:root "$DEST/rootfs"
chmod 0755 "$DEST"/rootfs/warewulf/wwinit.d/*.ww "$DEST/rootfs/usr/bin/nvidia-container-runtime.ww"
# registry credentials end up in this file: root-only on the node
chmod 0600 "$DEST/rootfs/etc/rancher/rke2/registries.yaml.ww"

wwctl overlay list -a "$RUNAI_WW_OVERLAY"
