#!/bin/bash
# Install rke2-agent (pinned to the server's version) into the compute image.
# The unit is left disabled in the image; the rke2 overlay enables it, so the
# image stays usable for nodes that are not part of the cluster.
set -euo pipefail
. "$(dirname "$0")/env.sh"

PKGVER="${RKE2_VERSION#v}"; PKGVER="${PKGVER/+/\~}"     # v1.36.5+rke2r1 -> 1.36.5~rke2r1
ROOTFS="$(wwctl image show "$WW_IMAGE")"

install -m 0644 /etc/yum.repos.d/rancher-rke2.repo "$ROOTFS/etc/yum.repos.d/rancher-rke2.repo"

wwctl image exec "$WW_IMAGE" -- /bin/bash -euc "
  dnf -y install rke2-agent-${PKGVER} rke2-common-${PKGVER}
  systemctl disable rke2-agent.service 2>/dev/null || true
  dnf clean all
"
chroot "$ROOTFS" rpm -q rke2-agent rke2-common
