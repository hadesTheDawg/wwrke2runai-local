#!/bin/bash
# Accounts from org/cluster.yaml (see lib/accounts.py):
#   Linux    groups (gid per group) + users (uid inside the group's block)
#            on ww1, homes /home/<user> on the NFS export; compute nodes get
#            them through Warewulf's syncuser runtime overlay (runai profile)
#   Run:ai   departments/projects with GPU quotas per partition, users with
#            passwords and UID/GID/groups attributes (token claims), access
#            rules: group -> AI practitioner, PI -> Project administrator
#   assets   data source "home" (/home); OS environments run as the user
#
# Passwords: ${RUNAI_DIR}/users.csv (root only). RESET_PASSWORDS=1 renews all.
# Production: users/groups/attributes come from LDAP/AD via SSO + SSSD; the
# Run:ai side (departments, projects, quotas, group access rules) is the same.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$RUNAI_SRC/lib/api.sh"

# Over-quota weights (Slurm fairshare) are off by default in Run:ai
runai_login
runai_api PUT /v1/k8s/setting '{"key": "project.quota.manual_over_quota", "value": true}' >/dev/null

KEYCLOAK_ADMIN_PASSWORD=$($KUBECTL -n runai-backend get secret runai-backend-gen-keycloakx \
  -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)
export KEYCLOAK_ADMIN_PASSWORD
python3 "$RUNAI_SRC/lib/accounts.py" "$RUNAI_SRC/org/cluster.yaml" "$RUNAI_DIR/users.csv"

# --- workloads: home directories ------------------------------------------------------
if [ "$(runai_api GET /api/v1/asset/datasource | json_get "any(x['meta']['name']=='home' for x in d['entries'])")" != True ]; then
  runai_api POST /api/v1/asset/datasource/host-path '{"meta": {"name": "home", "scope": "tenant",
    "description": "User home directories (NFS /home from the Warewulf server)"},
    "spec": {"path": "/home", "mountPath": "/home", "readOnly": false}}' >/dev/null
  echo "created data source home (/home -> /home)"
fi

# --- compute nodes: passwd/group via Warewulf syncuser (runtime overlay) -----------------
first=$(python3 -c 'import sys,yaml
d = yaml.safe_load(open(sys.argv[1]))
g = next(iter(next(iter(d["departments"].values()))["groups"].values()))
print(next(iter(g["users"])))' "$RUNAI_SRC/org/cluster.yaml")
node=$(python3 -c 'import sys,yaml; print(next(iter(yaml.safe_load(open(sys.argv[1]))["partitions"].values()))["nodes"][0])' "$RUNAI_SRC/org/cluster.yaml")
wwctl overlay build >/dev/null
echo "waiting for $first to appear on $node (wwclient refreshes runtime overlays every minute)"
for i in $(seq 1 30); do
  ssh -o BatchMode=yes "$node" "id $first" 2>/dev/null && break; sleep 10
done
ssh -o BatchMode=yes "$node" "id $first && ls -ld /home/$first"
