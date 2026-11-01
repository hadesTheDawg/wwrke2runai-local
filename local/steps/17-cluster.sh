#!/bin/bash
# Register the cluster with the control plane and install runai-cluster from
# the bundle (same flow as runai/23-cluster.sh). The 2-hour bootstrap token
# goes into a 0600 values file, never onto the command line.
. "$(dirname "$0")/../lib/common.sh"
need RUNAI_DOMAIN RUNAI_TLS_CERT RUNAI_TLS_KEY RUNAI_CA_CERT
NS=runai
VERSION=$(runai_version)

UUID=$($PY "$LIB/runai_api.py" cluster)
say "cluster $RUNAI_CLUSTER_NAME: $UUID"
SECRET_VALUES=$(mktemp); chmod 600 "$SECRET_VALUES"; trap 'rm -f "$SECRET_VALUES"' EXIT
$PY "$LIB/runai_api.py" install-values "$UUID" "$VERSION" > "$SECRET_VALUES"

ensure_ns "$NS"
$KUBECTL -n "$NS" create secret generic runai-ca-cert \
  --from-file=runai-ca.pem="$RUNAI_CA_CERT" --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL -n "$NS" label secret runai-ca-cert run.ai/cluster-wide=true run.ai/name=runai-ca-cert --overwrite
$KUBECTL -n "$NS" create secret tls runai-cluster-domain-tls-secret \
  --cert "$RUNAI_TLS_CERT" --key "$RUNAI_TLS_KEY" --dry-run=client -o yaml | $KUBECTL apply -f -

SUB=false
if is_yes "$RUNAI_SUBDOMAINS"; then
  # host-based tool URLs (https://<project>-<workload>.<domain>): wildcard
  # DNS and a certificate covering *.<domain> (10-preflight.sh checks it)
  SUB=true
  $KUBECTL -n "$NS" create secret tls runai-cluster-domain-star-tls-secret \
    --cert "$RUNAI_TLS_CERT" --key "$RUNAI_TLS_KEY" --dry-run=client -o yaml | $KUBECTL apply -f -
  cat <<EOF | $KUBECTL apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: runai-cluster-domain-star-ingress, namespace: $NS}
spec:
  ingressClassName: $RUNAI_INGRESS_CLASS
  rules: [{host: '*.${RUNAI_DOMAIN}'}]
  tls: [{hosts: ['*.${RUNAI_DOMAIN}'], secretName: runai-cluster-domain-star-tls-secret}]
EOF
fi

$HELM upgrade --install runai-cluster "$(chart_tgz runai-cluster)" \
  -n "$NS" $(values runai-cluster) -f "$SECRET_VALUES" \
  --set controlPlane.url="$RUNAI_DOMAIN" \
  --set cluster.uid="$UUID" \
  --set cluster.url="$RUNAI_DOMAIN" \
  --set clusterConfig.global.ingress.ingressClass="$RUNAI_INGRESS_CLASS" \
  --set clusterConfig.global.subdomainSupport=$SUB \
  --wait --timeout 20m

say "waiting for the cluster to report Connected"
state=unknown
for i in $(seq 1 90); do
  state=$($PY "$LIB/runai_api.py" cluster-state "$UUID" 2>/dev/null) || true
  [ "$state" = Connected ] && break
  [ $((i % 6)) = 0 ] && say "  state: $state"
  sleep 10
done
say "cluster $RUNAI_CLUSTER_NAME: $state"
$KUBECTL -n "$NS" get pods -o wide
[ "$state" = Connected ]
