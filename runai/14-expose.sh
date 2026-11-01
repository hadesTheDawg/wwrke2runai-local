#!/bin/bash
# Publish the Run:ai dashboard/API on ww1 and make its name work everywhere.
#
#   client ──https──▶ ww1 ${WW_EXTERNAL_IP}:443 ─hostPort─▶ rke2-traefik ─▶ runai-backend-traefik ─▶ services
#                     ww1 ${WW_EXTERNAL_IP}:80  ─hostPort─▶ rke2-traefik ─▶ 308 to https
#   pods ──▶ CoreDNS rewrites ${RUNAI_DOMAIN} to the rke2-traefik Service (same path, in-cluster)
#
# Ports 80/443 on ww1 are forwarded by the CNI portmap DNAT of Traefik's
# hostPorts (pinned below so an RKE2 default change cannot drop them).
# Run:ai needs nothing else exposed: UI, REST API, Keycloak (/auth), CLI
# downloads and the cluster->control-plane connection all share 443.
set -euo pipefail
. "$(dirname "$0")/env.sh"
MANIFESTS=/var/lib/rancher/rke2/server/manifests

# --- TLS certificate for the domain, signed by the site CA -----------------
mkdir -p "$RUNAI_DIR"; chmod 700 "$RUNAI_DIR"
if [ ! -s "$RUNAI_DIR/tls.crt" ] || ! openssl x509 -in "$RUNAI_DIR/tls.crt" -noout -checkhost "$RUNAI_DOMAIN" | grep -q 'does match'; then
  openssl req -newkey rsa:4096 -nodes -keyout "$RUNAI_DIR/tls.key" -out "$RUNAI_DIR/tls.csr" -subj "/CN=${RUNAI_DOMAIN}" 2>/dev/null
  cat > "$RUNAI_DIR/tls.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${RUNAI_DOMAIN},DNS:*.${RUNAI_DOMAIN},IP:${WW_EXTERNAL_IP},IP:${WW_INTERNAL_IP}
EOF
  openssl x509 -req -in "$RUNAI_DIR/tls.csr" -CA "$REG_DIR/ca.crt" -CAkey "$REG_DIR/ca.key" -CAcreateserial \
    -out "$RUNAI_DIR/tls.crt" -days 825 -sha256 -extfile "$RUNAI_DIR/tls.ext" 2>/dev/null
  cat "$RUNAI_DIR/tls.crt" "$REG_DIR/ca.crt" > "$RUNAI_DIR/fullchain.crt"
  chmod 600 "$RUNAI_DIR/tls.key"
fi
cp "$REG_DIR/ca.crt" "$RUNAI_DIR/ca.crt"

# --- ingress: pin Traefik's hostPorts on every node, incl. ww1 --------------
cat > "$MANIFESTS/rke2-traefik-config.yaml" <<EOF
# Managed by rke2_deploy_ww/runai/14-expose.sh
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      web:
        hostPort: 80
      websecure:
        hostPort: 443
EOF

# --- in-cluster DNS: ${RUNAI_DOMAIN} -> rke2-traefik Service ----------------
# Compute nodes have no upstream DNS; pods (Run:ai services, the cluster
# agent, Keycloak clients) must reach the domain through the ingress too.
# Full server block = rke2-coredns default + the rewrite.
cat > "$MANIFESTS/rke2-coredns-config.yaml" <<EOF
# Managed by rke2_deploy_ww/runai/14-expose.sh
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-coredns
  namespace: kube-system
spec:
  valuesContent: |-
    servers:
      - zones:
          - zone: .
            use_tcp: true
        port: 53
        plugins:
          - name: errors
          - name: health
            configBlock: lameduck 10s
          - name: ready
          - name: rewrite
            parameters: stop
            configBlock: |-
              name exact ${RUNAI_DOMAIN} rke2-traefik.kube-system.svc.cluster.local
              answer auto
          - name: kubernetes
            parameters: cluster.local in-addr.arpa ip6.arpa
            configBlock: |-
              pods insecure
              fallthrough in-addr.arpa ip6.arpa
              ttl 30
          - name: prometheus
            parameters: 0.0.0.0:9153
          - name: forward
            parameters: . /etc/resolv.conf
          - name: cache
            parameters: 30
          - name: loop
          - name: reload
          - name: loadbalance
EOF

# --- ww1 itself: reach the API on the internal IP (scripts in lib/runai.py) ---
grep -qE "^${WW_INTERNAL_IP//./\\.}[[:space:]].*\b${RUNAI_DOMAIN//./\\.}\b" /etc/hosts \
  || echo "${WW_INTERNAL_IP} ${RUNAI_DOMAIN}   # rke2_deploy_ww/runai" >> /etc/hosts

# --- client DNS: ${RUNAI_DOMAIN} and *.${RUNAI_DOMAIN} -> ww1 ------------------
# Workload tools (RStudio, ...) get their own host name, which /etc/hosts
# cannot express. Production: one wildcard record in your DNS. Lab: dnsmasq
# on the external IP answering only for this domain; clients forward just
# this domain to it (macOS: /etc/resolver/${RUNAI_DOMAIN}).
#
# NOT the stock dnsmasq.service: /etc/dnsmasq.d holds Warewulf's generated
# DHCP/TFTP config (its optional dnsmasq backend) and would start a second
# DHCP server on the provisioning network next to dhcpd. runai-dns runs the
# binary with only its own file: DNS only, external IP only, this domain only.
dnf -y -q install dnsmasq >/dev/null
systemctl disable -q --now dnsmasq 2>/dev/null || true
cat > "$RUNAI_DIR/dnsmasq.conf" <<EOF
# Managed by rke2_deploy_ww/runai/14-expose.sh (runai-dns.service)
listen-address=${WW_EXTERNAL_IP}
bind-interfaces
no-resolv
no-hosts
address=/${RUNAI_DOMAIN}/${WW_EXTERNAL_IP}
EOF
cat > /etc/systemd/system/runai-dns.service <<EOF
[Unit]
Description=Run:ai domain DNS for clients (${RUNAI_DOMAIN}, *.${RUNAI_DOMAIN} -> ${WW_EXTERNAL_IP})
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=${RUNAI_DIR}/dnsmasq.conf --pid-file=/run/runai-dns.pid
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q runai-dns
systemctl restart runai-dns

# --- host firewall (only if firewalld is in use) ---------------------------
if systemctl is-active -q firewalld; then
  firewall-cmd -q --permanent --add-service=http --add-service=https --add-service=dns
  firewall-cmd -q --reload
fi

# --- Run:ai node roles: system services prefer ww1 (persistent, has disk) ---
# kubelet cannot self-assign node-role.kubernetes.io/* labels, so this is
# done here rather than in the Warewulf overlay.
$KUBECTL label node "$($KUBECTL get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')" \
  node-role.kubernetes.io/runai-system=true --overwrite

# --- verify ----------------------------------------------------------------
echo "waiting for CoreDNS rewrite"
for i in $(seq 1 40); do
  $KUBECTL -n kube-system get cm rke2-coredns-rke2-coredns -o jsonpath='{.data.Corefile}' | grep -q "$RUNAI_DOMAIN" && break; sleep 3
done
$KUBECTL -n kube-system rollout status ds/rke2-coredns-rke2-coredns --timeout=180s 2>/dev/null \
  || $KUBECTL -n kube-system rollout status deploy/rke2-coredns-rke2-coredns --timeout=180s
$KUBECTL run runai-dns-check --rm -i --restart=Never -q --image=docker.io/library/ubuntu:24.04 -- \
  getent hosts "$RUNAI_DOMAIN"
for ip in "$WW_EXTERNAL_IP" "$WW_INTERNAL_IP"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$RUNAI_DIR/ca.crt" \
    --resolve "${RUNAI_DOMAIN}:443:${ip}" "https://${RUNAI_DOMAIN}/") || true
  echo "https://${RUNAI_DOMAIN} via ${ip}:443 -> HTTP ${code} (404 until the control plane is installed)"
done
for name in "$RUNAI_DOMAIN" "probe.$RUNAI_DOMAIN"; do
  echo "dns @${WW_EXTERNAL_IP} $name -> $(dig +short @"$WW_EXTERNAL_IP" "$name" 2>/dev/null || getent hosts "$name")"
done
cat <<EOF

Clients: resolve ${RUNAI_DOMAIN} and *.${RUNAI_DOMAIN} via ${WW_EXTERNAL_IP}
  macOS: sudo mkdir -p /etc/resolver && echo "nameserver ${WW_EXTERNAL_IP}" | sudo tee /etc/resolver/${RUNAI_DOMAIN}
and trust the site CA: ${RUNAI_DIR}/ca.crt
EOF
