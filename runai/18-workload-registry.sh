#!/bin/bash
# Pull-only "workload registry" for Run:ai users: a second registry:2 process
# serving the SAME storage read-only on ${WL_REGISTRY}, with its own
# htpasswd holding only the pull account ${WL_REG_USER}. Workloads can list
# (/v2/_catalog, tags) and pull, but never push or delete. The push account
# in ${REG_DIR}/password stays on ww1.
#
# Production equivalent: a Harbor/Quay/Artifactory project and a pull-only
# robot account; nothing else in the runai layer changes.
set -euo pipefail
. "$(dirname "$0")/env.sh"
cd "$REG_DIR"

[ -s pull-password ] || ( umask 077; openssl rand -hex 24 > pull-password )
printf '%s' "$WL_REG_USER" > pull-username
htpasswd -Bbc htpasswd-pull "$WL_REG_USER" "$(cat pull-password)" 2>/dev/null
chmod 600 htpasswd-pull

# Explicit config: the nested storage.maintenance map cannot be expressed
# through REGISTRY_* environment variables.
cat > config-ro.yml <<EOF
version: 0.1
log:
  fields:
    service: workload-registry
storage:
  filesystem:
    rootdirectory: /var/lib/registry
  maintenance:
    readonly:
      enabled: true          # every write (push, delete) is refused
    uploadpurging:
      enabled: false
http:
  addr: :5000
  tls:
    certificate: /certs/registry.crt
    key: /certs/registry.key
auth:
  htpasswd:
    realm: workload-registry
    path: /auth/htpasswd
EOF

# No volume relabelling (:Z) here: rke2-registry owns the private SELinux
# labels of these paths, and relabelling would lock it out. This container
# runs without label separation and mounts everything read-only instead.
cat > /etc/containers/systemd/rke2-registry-ro.container <<EOF
[Unit]
Description=Pull-only view of the local registry for Run:ai workloads
After=network-online.target rke2-registry.service
Wants=network-online.target

[Container]
ContainerName=rke2-registry-ro
Image=${REG_IMAGE}
PublishPort=${WW_INTERNAL_IP}:${WL_REG_PORT}:5000
SecurityLabelDisable=true
Volume=${REG_DATA}:/var/lib/registry:ro
Volume=${REG_DIR}/registry.crt:/certs/registry.crt:ro
Volume=${REG_DIR}/registry.key:/certs/registry.key:ro
Volume=${REG_DIR}/htpasswd-pull:/auth/htpasswd:ro
Volume=${REG_DIR}/config-ro.yml:/etc/docker/registry/config.yml:ro

[Service]
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl restart rke2-registry-ro.service

# --- verify: pull account can read, cannot write ------------------------------
PULL="$WL_REG_USER:$(cat pull-password)"
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$PULL" "https://${WL_REGISTRY}/v2/_catalog") || true
  [ "$code" = 200 ] && break; sleep 2
done
echo "catalog as $WL_REG_USER -> HTTP $code"
push=$(curl -s -o /dev/null -w '%{http_code}' -u "$PULL" -X POST "https://${WL_REGISTRY}/v2/${WL_REG_PREFIX}/probe/blobs/uploads/")
echo "push attempt as $WL_REG_USER -> HTTP $push (must be refused)"
anon=$(curl -s -o /dev/null -w '%{http_code}' "https://${WL_REGISTRY}/v2/_catalog")
echo "anonymous catalog -> HTTP $anon (must be 401)"
[ "$code" = 200 ] && [ "$push" != 202 ] && [ "$anon" = 401 ]

# --- containerd everywhere pulls ${WL_REGISTRY} directly, as ${WL_REG_USER} -------
# nodes: runai overlay registries.yaml (takes effect at the next node boot)
# ww1:   12-server-mirror.sh (restarts rke2-server only if the file changed)
wwctl overlay build >/dev/null
"$RUNAI_SRC/12-server-mirror.sh"
echo "compute nodes pick up the new registries.yaml at their next boot"
