#!/bin/bash
# Create the "rke2" profile. Any node that carries this profile becomes an
# RKE2 agent on boot:   wwctl node set <node> --profile default,rke2
set -euo pipefail
. "$(dirname "$0")/env.sh"

wwctl profile list "$WW_PROFILE" 2>/dev/null | grep -qw "^$WW_PROFILE" || wwctl profile add "$WW_PROFILE"

# - image with rke2-agent installed
# - rke2 overlay (merged with the default profile's system overlays)
# - tmpfs root: runc cannot pivot_root out of an initramfs/rootfs root
# - default route via the Warewulf server: kubelet, flannel and service
#   (ClusterIP) traffic need one. ww1 does not NAT, so no internet leaks.
wwctl profile set -y "$WW_PROFILE" \
  --comment "RKE2 agent nodes (overlay: $WW_OVERLAY)" \
  --image "$WW_IMAGE" \
  --system-overlays "$WW_OVERLAY" \
  --root tmpfs \
  --netname default --gateway "$WW_INTERNAL_IP"

for n in ${NODES:-}; do
  wwctl node set -y "$n" --profile default,"$WW_PROFILE"
done

wwctl overlay build
wwctl profile list -a "$WW_PROFILE"
