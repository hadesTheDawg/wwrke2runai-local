#!/bin/bash
# Time sync is a Run:ai prerequisite (OIDC tokens, cluster<->control-plane
# auth). Compute nodes are offline, so ww1 serves NTP on the internal network
# and keeps serving its own clock if it loses upstream (local stratum 10).
#   ww1:    chronyd, allow ${WW_INTERNAL_IP%.*}.0/24
#   image:  chrony installed, left disabled (the runai overlay enables it)
#   nodes:  Warewulf's stock "chrony" overlay (server = Warewulf IP, always
#           step), added to the runai profile by 16-profile.sh
set -euo pipefail
. "$(dirname "$0")/env.sh"

CONF=/etc/chrony.conf
MARK="# rke2_deploy_ww/runai: serve the compute network"
if ! grep -qF "$MARK" "$CONF"; then
  printf '\n%s\nallow %s.0/24\nlocal stratum 10\n' "$MARK" "${WW_INTERNAL_IP%.*}" >> "$CONF"
  systemctl restart chronyd
fi
# Step the clock whenever it is >1 s off, not only in the first 3 updates
# (EL default "makestep 1.0 3"). A suspended/paused VM resumes hours behind
# and would otherwise slew at <=0.5 ms/s for weeks; Keycloak on this host then
# issues tokens that cluster-api on the (correct) nodes rejects as expired:
# the UI terminal fails with 401. The nodes already use "makestep 1.0 -1"
# (Warewulf chrony overlay).
if ! grep -qE '^makestep 1(\.0)? -1$' "$CONF"; then
  sed -i -E 's/^makestep .*/makestep 1.0 -1/' "$CONF"
  grep -qE '^makestep ' "$CONF" || echo "makestep 1.0 -1" >> "$CONF"
  systemctl restart chronyd
fi
# Wait until an upstream source is selected: right after a restart chronyd may
# be "synchronised" to its own local clock (local stratum 10, refid 7F7F0101),
# and stepping to that changes nothing.
chronyc -a 'burst 4/4' >/dev/null
for i in $(seq 1 24); do
  chronyc tracking | grep -q 'Reference ID *: 7F7F0101' || break; sleep 5
done
chronyc -a makestep >/dev/null          # step now instead of slewing for hours
chronyc tracking | grep -E '^(Reference|System time|Leap)'

ROOTFS="$(wwctl image show "$WW_IMAGE")"
if ! chroot "$ROOTFS" rpm -q chrony >/dev/null 2>&1; then
  wwctl image exec "$WW_IMAGE" -- /bin/bash -euc "
    dnf -y install chrony
    systemctl disable chronyd.service 2>/dev/null || true
    dnf clean all
  "
fi
chroot "$ROOTFS" rpm -q chrony
