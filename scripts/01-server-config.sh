#!/bin/bash
# Make the RKE2 server advertise itself on the internal network so agents on
# 10.10.172.0/24 can reach the supervisor, apiserver and flannel endpoints.
set -euo pipefail
. "$(dirname "$0")/env.sh"

CFG=/etc/rancher/rke2/config.yaml
WANT=$(cat <<EOF
node-ip: ${WW_INTERNAL_IP}
advertise-address: ${WW_INTERNAL_IP}
tls-san:
  - ${WW_INTERNAL_IP}
  - ${WW_EXTERNAL_IP}
  - ${WW_FQDN}
  - ${WW_FQDN%%.*}
  - warewulf
EOF
)

if [ -f "$CFG" ] && [ "$(cat "$CFG")" = "$WANT" ]; then
  echo "server config already in place"; exit 0
fi

echo "taking etcd snapshot before reconfiguring"
rke2 etcd-snapshot save --name pre-internal-ip >/dev/null

[ -f "$CFG" ] && cp -a "$CFG" "$CFG.bak.$(date +%s)"
echo "$WANT" > "$CFG"
chmod 600 "$CFG"

systemctl restart rke2-server
echo "waiting for apiserver"
for i in $(seq 1 60); do
  $KUBECTL get --raw /readyz >/dev/null 2>&1 && break; sleep 5
done
$KUBECTL get nodes -o wide
