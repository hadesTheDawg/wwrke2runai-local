#!/bin/bash
# Create the "runai" profile, layered on top of "rke2":
#     wwctl node set <node> --profile default,rke2,runai
#
# - local disk: GPT on $RUNAI_DISK rewritten at every boot with the same
#   layout by the stock "sfdisk" overlay (data is kept), file systems
#   formatted once by the runai overlay, mounted by the default profile's
#   "ignition" overlay units:
#       part 1 "rke2"    -> /var/lib/rancher  (containerd images, rke2 agent)
#       part 2 "kubelet" -> /var/lib/kubelet  (emptyDir, pod volumes)
#   so images no longer live in the tmpfs root (RAM).
# - chrony: Warewulf's stock overlay, time from ww1 (09-time.sh); the runai
#   overlay enables chronyd.
# - syncuser (runtime overlay, refreshed by wwclient every minute, no
#   reboot): /etc/passwd + /etc/group = image + ww1's accounts, so users
#   created on ww1 (41-accounts.sh) exist on the nodes; homes are the NFS
#   /home mounted by the default profile.
# - tag runai_fake_gpu_pool (GPU_MODE=fake): nodes advertise simulated GPUs.
#
# Changing disks requires a reboot of the nodes. To start a node from clean
# file systems: wwctl node set <node> --fsname rke2 --fswipe (and kubelet),
# reboot, then unset it again.
set -euo pipefail
. "$(dirname "$0")/env.sh"
P="$RUNAI_WW_PROFILE"

wwctl profile list "$P" 2>/dev/null | grep -qw "^$P" || wwctl profile add "$P"

wwctl profile set -y "$P" \
  --comment "Run:ai worker nodes (overlay: $RUNAI_WW_OVERLAY, local disk $RUNAI_DISK)" \
  --system-overlays chrony,sfdisk,"$RUNAI_WW_OVERLAY" \
  --runtime-overlays syncuser

wwctl profile set -y "$P" --diskname "$RUNAI_DISK" --diskwipe \
  --partname rke2 --partnumber 1 --partsize "$RUNAI_DISK_RKE2_MIB" --partcreate \
  --fsname rke2 --fsformat ext4 --fspath /var/lib/rancher
wwctl profile set -y "$P" --diskname "$RUNAI_DISK" \
  --partname kubelet --partnumber 2 --partcreate \
  --fsname kubelet --fsformat ext4 --fspath /var/lib/kubelet

if [ "$GPU_MODE" = fake ]; then
  wwctl profile set -y "$P" --tagadd "runai_fake_gpu_pool=$FAKE_GPU_POOL"
else
  wwctl profile set -y "$P" --tagdel runai_fake_gpu_pool 2>/dev/null || true
fi

for n in ${NODES:-}; do
  wwctl node set -y "$n" --profile default,"$WW_PROFILE","$P"
done

wwctl overlay build
wwctl profile list -a "$P"
