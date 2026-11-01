#!/bin/bash
# Run:ai control plane (release runai-backend) from the bundled chart, same
# values as the remote (runai/values/control-plane*.yaml, $SITE_VALUES_DIR on
# top). Secrets from the files named in .env:
#   runai-backend-tls  RUNAI_TLS_CERT + RUNAI_TLS_KEY
#   runai-ca-cert      RUNAI_CA_CERT
#   runai-admin        RUNAI_ADMIN_PASSWORD_FILE (generated if missing)
. "$(dirname "$0")/../lib/common.sh"
need RUNAI_DOMAIN RUNAI_ADMIN_USER RUNAI_TLS_CERT RUNAI_TLS_KEY RUNAI_CA_CERT
NS=runai-backend

if [ ! -s "$RUNAI_ADMIN_PASSWORD_FILE" ]; then
  mkpriv "$(dirname "$RUNAI_ADMIN_PASSWORD_FILE")"
  # >= 8 chars with upper, lower, digit and special character
  ( umask 077; printf '%sAa1!' "$(openssl rand -base64 18 | tr -d '/+=')" > "$RUNAI_ADMIN_PASSWORD_FILE" )
  say "generated admin password in $RUNAI_ADMIN_PASSWORD_FILE"
fi

ensure_ns "$NS"
$KUBECTL -n "$NS" create secret tls runai-backend-tls \
  --cert "$RUNAI_TLS_CERT" --key "$RUNAI_TLS_KEY" --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL -n "$NS" create secret generic runai-ca-cert \
  --from-file=runai-ca.pem="$RUNAI_CA_CERT" --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL -n "$NS" create secret generic runai-admin \
  --from-file=ADMIN_PASSWORD="$RUNAI_ADMIN_PASSWORD_FILE" --dry-run=client -o yaml | $KUBECTL apply -f -

# values/control-plane.yaml references this Traefik middleware (http -> https);
# other ingress controllers ignore the annotation
if [ "$RUNAI_INGRESS_CLASS" = traefik ]; then
  cat <<EOF | $KUBECTL apply -f -
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: https-redirect, namespace: $NS}
spec: {redirectScheme: {scheme: https, permanent: true}}
EOF
fi

$HELM upgrade --install runai-backend "$(chart_tgz control-plane)" \
  -n "$NS" $(values control-plane) \
  --set global.domain="$RUNAI_DOMAIN" \
  --set global.ingress.ingressClass="$RUNAI_INGRESS_CLASS" \
  --set tenantsManager.config.adminUsername="$RUNAI_ADMIN_USER" \
  --wait --timeout 30m

$PY "$LIB/runai_api.py" wait-ready
$KUBECTL -n "$NS" get pods -o wide
say "admin: $RUNAI_ADMIN_USER / password in $RUNAI_ADMIN_PASSWORD_FILE"
