#!/bin/bash
# Stand up a TLS + htpasswd protected registry:2 on the internal network,
# managed by systemd via a podman quadlet.
set -euo pipefail
. "$(dirname "$0")/env.sh"

dnf -y -q install skopeo httpd-tools podman jq >/dev/null

mkdir -p "$REG_DIR" "$REG_DATA"
chmod 700 "$REG_DIR"
cd "$REG_DIR"

# --- CA + server certificate (kept if already present) --------------------
if [ ! -f ca.crt ]; then
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout ca.key -out ca.crt -subj "/CN=rke2-registry-ca"
fi
if [ ! -f registry.crt ]; then
  cat > registry.ext <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=IP:${WW_INTERNAL_IP},IP:${WW_EXTERNAL_IP},DNS:${WW_FQDN},DNS:${WW_FQDN%%.*},DNS:warewulf
EOF
  openssl req -newkey rsa:4096 -nodes -keyout registry.key -out registry.csr \
    -subj "/CN=${WW_FQDN}"
  openssl x509 -req -in registry.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out registry.crt -days 3650 -sha256 -extfile registry.ext
fi
chmod 600 ca.key registry.key

# --- credentials ----------------------------------------------------------
if [ ! -f password ]; then
  openssl rand -hex 24 > password
  chmod 600 password
fi
htpasswd -Bbc htpasswd "$REG_USER" "$(cat password)" 2>/dev/null
printf '%s' "$REG_USER" > username

# Secret used to derive stable per-node rke2 node passwords (stateless nodes)
[ -f node-password-seed ] || { openssl rand -hex 32 > node-password-seed; chmod 600 node-password-seed; }

# Trust the CA on ww1 itself (for skopeo/podman pushes)
cp ca.crt /etc/pki/ca-trust/source/anchors/rke2-registry-ca.crt
update-ca-trust

# --- quadlet --------------------------------------------------------------
cat > /etc/containers/systemd/rke2-registry.container <<EOF
[Unit]
Description=Local OCI registry for RKE2 compute nodes
After=network-online.target
Wants=network-online.target

[Container]
ContainerName=rke2-registry
Image=${REG_IMAGE}
PublishPort=${WW_INTERNAL_IP}:${REG_PORT}:5000
Volume=${REG_DATA}:/var/lib/registry:Z
Volume=${REG_DIR}/registry.crt:/certs/registry.crt:ro,Z
Volume=${REG_DIR}/registry.key:/certs/registry.key:ro,Z
Volume=${REG_DIR}/htpasswd:/auth/htpasswd:ro,Z
Environment=REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt
Environment=REGISTRY_HTTP_TLS_KEY=/certs/registry.key
Environment=REGISTRY_AUTH=htpasswd
Environment=REGISTRY_AUTH_HTPASSWD_REALM=rke2-registry
Environment=REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd
Environment=REGISTRY_STORAGE_DELETE_ENABLED=true

[Service]
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl restart rke2-registry.service

for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$REG_USER:$(cat password)" \
    "https://${WW_INTERNAL_IP}:${REG_PORT}/v2/") || true
  [ "$code" = 200 ] && break; sleep 2
done
echo "registry /v2/ -> $code"
[ "$code" = 200 ]
