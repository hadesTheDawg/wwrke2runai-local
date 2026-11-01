#!/bin/bash
# Make ww1 itself pull through the local registry, like the compute nodes
# (rke2 overlay). Run:ai control-plane pods scheduled on ww1 then run from the
# same mirrored, digest-pinned artifacts instead of the internet. containerd
# still falls back to the upstream registry for anything not mirrored.
# Also raises kubelet's image pull rate limit (see overlay/runai).
set -euo pipefail
. "$(dirname "$0")/env.sh"

CFG=/etc/rancher/rke2/registries.yaml
WANT=$(cat <<EOF
# Managed by rke2_deploy_ww/runai/12-server-mirror.sh
mirrors:
  docker.io:
    endpoint:
      - "https://${REGISTRY}"
  "*":
    endpoint:
      - "https://${REGISTRY}"
configs:
  "${REGISTRY}":
    auth:
      username: $(cat "$REG_DIR/username")
      password: $(cat "$REG_DIR/password")
    tls:
      ca_file: ${REG_DIR}/ca.crt
EOF
)
# Workload registry (18-workload-registry.sh): its own endpoint and pull-only
# account, or "*" would send its images to :5000 with the wrong credentials.
if [ -s "$REG_DIR/pull-password" ]; then
  WANT=$(python3 -c 'import sys,yaml
d = yaml.safe_load(sys.stdin.read())
reg = sys.argv[1]
d["mirrors"] = {k: v for k, v in d["mirrors"].items() if k != "*"}
d["mirrors"][reg] = {"endpoint": [f"https://{reg}"]}
d["mirrors"]["*"] = {"endpoint": [f"https://{sys.argv[2]}"]}
d["configs"][reg] = {"auth": {"username": sys.argv[3], "password": sys.argv[4]}, "tls": {"ca_file": sys.argv[5]}}
print("# Managed by rke2_deploy_ww/runai/12-server-mirror.sh")
print(yaml.safe_dump(d, sort_keys=False).rstrip())' \
    "$WL_REGISTRY" "$REGISTRY" "$(cat "$REG_DIR/pull-username")" "$(cat "$REG_DIR/pull-password")" "$REG_DIR/ca.crt" <<<"$WANT")
fi

# kubelet pull rate limit: same reasoning as the runai overlay on the agents
DROPIN=/etc/rancher/rke2/config.yaml.d/50-runai.yaml
WANT_DROPIN=$(cat <<EOF
# Managed by rke2_deploy_ww/runai/12-server-mirror.sh
kubelet-arg+:
  - registry-qps=50
  - registry-burst=100
EOF
)

if [ "$(cat "$CFG" 2>/dev/null)" = "$WANT" ] && [ "$(cat "$DROPIN" 2>/dev/null)" = "$WANT_DROPIN" ]; then
  echo "server registries.yaml and kubelet settings already in place"; exit 0
fi
[ -f "$CFG" ] && cp -a "$CFG" "$CFG.bak.$(date +%s)"
( umask 077; echo "$WANT" > "$CFG" )
mkdir -p "${DROPIN%/*}"; echo "$WANT_DROPIN" > "$DROPIN"

echo "restarting rke2-server to load $CFG and $DROPIN (running pods are not affected)"
systemctl restart rke2-server
for i in $(seq 1 60); do
  $KUBECTL get --raw /readyz >/dev/null 2>&1 && break; sleep 5
done
$KUBECTL get nodes
