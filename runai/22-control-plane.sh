#!/bin/bash
# Run:ai control plane (release runai-backend) from the local registry.
# Secrets it consumes are created here from files on ww1:
#   runai-backend-tls  ${RUNAI_DIR}/fullchain.crt + tls.key   (14-expose.sh)
#   runai-ca-cert      site CA
#   runai-admin        ADMIN_PASSWORD from ${RUNAI_DIR}/admin-password
set -euo pipefail
. "$(dirname "$0")/env.sh"
NS=runai-backend

# Admin password: >=8 chars with upper, lower, digit and special character.
if [ ! -s "$RUNAI_DIR/admin-password" ]; then
  ( umask 077; printf '%sAa1!' "$(openssl rand -base64 18 | tr -d '/+=')" > "$RUNAI_DIR/admin-password" )
fi

ensure_ns "$NS"
$KUBECTL -n "$NS" create secret tls runai-backend-tls \
  --cert "$RUNAI_DIR/fullchain.crt" --key "$RUNAI_DIR/tls.key" --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL -n "$NS" create secret generic runai-ca-cert \
  --from-file=runai-ca.pem="$RUNAI_DIR/ca.crt" --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL -n "$NS" create secret generic runai-admin \
  --from-file=ADMIN_PASSWORD="$RUNAI_DIR/admin-password" --dry-run=client -o yaml | $KUBECTL apply -f -

# http -> https for the dashboard (referenced in values/control-plane.yaml)
cat <<EOF | $KUBECTL apply -f -
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: https-redirect
  namespace: $NS
spec:
  redirectScheme:
    scheme: https
    permanent: true
EOF

$HELM upgrade --install runai-backend "$CHART_REPO/control-plane" --version "$RUNAI_VERSION" \
  -n "$NS" $(values control-plane) \
  --set global.domain="$RUNAI_DOMAIN" \
  --set global.ingress.ingressClass="$RUNAI_INGRESS_CLASS" \
  --set tenantsManager.config.adminUsername="$RUNAI_ADMIN_USER" \
  --wait --timeout 30m

echo "waiting for https://$RUNAI_DOMAIN"
for i in $(seq 1 90); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$RUNAI_DIR/ca.crt" \
    --resolve "${RUNAI_DOMAIN}:443:${WW_INTERNAL_IP}" "https://${RUNAI_DOMAIN}/") || true
  [ "$code" = 200 ] && break; sleep 10
done
echo "https://${RUNAI_DOMAIN}/ -> HTTP $code"
$KUBECTL -n "$NS" get pods -o wide
echo "admin: $RUNAI_ADMIN_USER / password in $RUNAI_DIR/admin-password"
[ "$code" = 200 ]
