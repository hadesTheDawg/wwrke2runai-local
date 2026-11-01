#!/bin/bash
# Register this Kubernetes cluster with the control plane and install the
# Run:ai cluster (release runai-cluster, namespace runai) from the local
# registry. Automates the UI wizard:
#   POST /api/v1/clusters {name}                       -> cluster uuid
#   GET  /api/v1/clusters/<uuid>/cluster-install-info  -> bootstrap token (2h)
# A fresh bootstrap token is fetched on every run, so re-running is safe.
# It is passed in a 0600 values file, never on the command line.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$RUNAI_SRC/lib/api.sh"
NS=runai

runai_login
UUID=$(runai_api GET /api/v1/clusters | json_get \
  "next((c['uuid'] for c in d if c['name']=='$RUNAI_CLUSTER_NAME'), '')")
if [ -z "$UUID" ]; then
  UUID=$(runai_api POST /api/v1/clusters "{\"name\":\"$RUNAI_CLUSTER_NAME\"}" | json_get "d['uuid']")
  echo "created cluster $RUNAI_CLUSTER_NAME ($UUID)"
else
  echo "cluster $RUNAI_CLUSTER_NAME exists ($UUID)"
fi

SECRET_VALUES=$(mktemp); chmod 600 "$SECRET_VALUES"; trap 'rm -f "$SECRET_VALUES"' EXIT
runai_api GET "/api/v1/clusters/$UUID/cluster-install-info?version=$RUNAI_VERSION" \
  | json_get "'controlPlane:\n  bootstrapToken: ' + d['bootstrapToken']" > "$SECRET_VALUES"

# Secrets the cluster components consume (site CA, domain certificate)
ensure_ns "$NS"
$KUBECTL -n "$NS" create secret generic runai-ca-cert \
  --from-file=runai-ca.pem="$RUNAI_DIR/ca.crt" --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL -n "$NS" label secret runai-ca-cert run.ai/cluster-wide=true run.ai/name=runai-ca-cert --overwrite
$KUBECTL -n "$NS" create secret tls runai-cluster-domain-tls-secret \
  --cert "$RUNAI_DIR/fullchain.crt" --key "$RUNAI_DIR/tls.key" --dry-run=client -o yaml | $KUBECTL apply -f -
# Host-based routing of workload tools (RStudio, ...): the certificate from
# 14-expose.sh already covers *.${RUNAI_DOMAIN}
$KUBECTL -n "$NS" create secret tls runai-cluster-domain-star-tls-secret \
  --cert "$RUNAI_DIR/fullchain.crt" --key "$RUNAI_DIR/tls.key" --dry-run=client -o yaml | $KUBECTL apply -f -
cat <<EOF | $KUBECTL apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: runai-cluster-domain-star-ingress
  namespace: $NS
spec:
  ingressClassName: $RUNAI_INGRESS_CLASS
  rules:
    - host: '*.${RUNAI_DOMAIN}'
  tls:
    - hosts: ['*.${RUNAI_DOMAIN}']
      secretName: runai-cluster-domain-star-tls-secret
EOF

# Same Kubernetes cluster as the control plane: cluster URL = control-plane domain
$HELM upgrade --install runai-cluster "$CHART_REPO/runai-cluster" --version "$RUNAI_VERSION" \
  -n "$NS" $(values runai-cluster) -f "$SECRET_VALUES" \
  --set controlPlane.url="$RUNAI_DOMAIN" \
  --set cluster.uid="$UUID" \
  --set cluster.url="$RUNAI_DOMAIN" \
  --set clusterConfig.global.ingress.ingressClass="$RUNAI_INGRESS_CLASS" \
  --wait --timeout 20m

echo "waiting for the cluster to report Connected"
for i in $(seq 1 90); do
  state=$(runai_api GET "/api/v1/clusters/$UUID" | json_get "d['status']['state']") || true
  [ "$state" = Connected ] && break
  [ $((i % 6)) = 0 ] && { echo "  state: $state"; runai_login; }
  sleep 10
done
echo "cluster $RUNAI_CLUSTER_NAME: $state"
runai_api GET "/api/v1/clusters/$UUID" | json_get "json.dumps(d['status'], indent=1)"
$KUBECTL -n "$NS" get pods -o wide
[ "$state" = Connected ]
