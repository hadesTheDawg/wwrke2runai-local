#!/bin/bash
# Check the target before touching it: an existing RKE2 cluster with GPU
# nodes, a default StorageClass, an ingress class, a registry to push to, a
# certificate for the Run:ai domain, and a complete local repository.
. "$(dirname "$0")/../lib/common.sh"
fail=0
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; fail=1; }
note(){ printf '  note  %s\n' "$*"; }

say "local repository $RUNAI_REPO"
n=$($PY "$LIB/registry.py" store-refs "$IMAGES" 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -gt 0 ] && ok "images: $n" || bad "no images (make fetch)"
for c in control-plane runai-cluster; do (chart_tgz $c >/dev/null) && ok "chart $(basename "$(chart_tgz $c)")" || bad "chart $c"; done
[ -n "$SKOPEO" ] && ok "skopeo: ${SKOPEO%% *}" || bad "skopeo not found"

say "cluster ($KUBECONFIG)"
if ! $KUBECTL get --raw /readyz >/dev/null 2>&1; then
  bad "API server not reachable with $KUBECONFIG"; exit 1
fi
ok "server $($KUBECTL version -o json | $PY -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')"
$KUBECTL get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' | grep -q rke2 \
  && ok "RKE2 nodes" || note "nodes do not report an RKE2 kubelet (other distributions work if they mirror images the same way)"
gpus=$($KUBECTL get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' | awk '{s+=$1} END{print s+0}')
if [ "$gpus" -gt 0 ]; then ok "$gpus allocatable nvidia.com/gpu"
elif [ "$GPU_OPERATOR" = skip ]; then bad "no allocatable nvidia.com/gpu (GPU_OPERATOR=install or fake?)"
else note "no GPUs advertised yet; GPU_OPERATOR=$GPU_OPERATOR will install"; fi
[ "$($KUBECTL get nodes -l node-role.kubernetes.io/runai-system -o name | wc -l | tr -d ' ')" -gt 0 ] \
  && ok "node role runai-system set" || note "no node labelled node-role.kubernetes.io/runai-system=true (control plane schedules anywhere)"

sc=$($KUBECTL get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}')
[ -n "$sc" ] && ok "default StorageClass: $sc" || {
  is_yes "$WEKA_CSI" || is_yes "$CEPHFS_CSI" && note "no default StorageClass yet (set WEKA_DEFAULT_CLASS/CEPHFS_DEFAULT_CLASS=yes)" \
    || bad "no default StorageClass (control-plane PostgreSQL, Thanos, NATS need one)"; }
$KUBECTL get ingressclass "$RUNAI_INGRESS_CLASS" >/dev/null 2>&1 && ok "IngressClass $RUNAI_INGRESS_CLASS" || bad "IngressClass $RUNAI_INGRESS_CLASS missing"
if $KUBECTL get crd prometheuses.monitoring.coreos.com >/dev/null 2>&1; then ok "Prometheus Operator CRDs"
elif [ "$INSTALL_PROMETHEUS" = no ]; then bad "Prometheus Operator CRDs missing and INSTALL_PROMETHEUS=no"
else note "Prometheus Operator CRDs missing: kube-prometheus-stack will be installed"; fi

say "registry $TARGET_REGISTRY"
if [ -n "$TARGET_REGISTRY" ]; then
  AUTH=$(mktemp); trap 'rm -f "$AUTH"' EXIT
  [ -n "$TARGET_REGISTRY_USER" ] && authfile "$AUTH" "$TARGET_REGISTRY" "$TARGET_REGISTRY_USER" "$TARGET_REGISTRY_PASSWORD_FILE" || echo '{}' > "$AUTH"
  opt="--authfile $AUTH"; [ -n "$TARGET_REGISTRY_CA" ] && opt="$opt --ca $TARGET_REGISTRY_CA"; is_yes "$TARGET_REGISTRY_TLS_VERIFY" || opt="$opt --insecure"
  if out=$($PY "$LIB/registry.py" $opt ping "$TARGET_REGISTRY" 2>&1); then ok "reachable, credentials accepted"
  else bad "https://$TARGET_REGISTRY/v2/: $out"; fi
else
  bad "TARGET_REGISTRY not set"
fi

say "Run:ai"
need RUNAI_DOMAIN RUNAI_ADMIN_USER
for f in RUNAI_TLS_CERT RUNAI_TLS_KEY RUNAI_CA_CERT; do eval "p=\${$f:-}"; [ -s "$p" ] && ok "$f $p" || bad "$f missing"; done
if [ -s "$RUNAI_TLS_CERT" ]; then
  for h in "$RUNAI_DOMAIN" $(is_yes "$RUNAI_SUBDOMAINS" && echo "probe.$RUNAI_DOMAIN"); do
    $PY -c 'import ssl,sys,fnmatch
san = [v for k, v in ssl._ssl._test_decode_cert(sys.argv[1]).get("subjectAltName", ()) if k == "DNS"]
h = sys.argv[2]
sys.exit(0 if any(n == h or (n.startswith("*.") and h.split(".", 1)[1] == n[2:]) for n in san) else 1)' \
      "$RUNAI_TLS_CERT" "$h" && ok "certificate covers $h" || bad "certificate does not cover $h"
  done
  openssl x509 -in "$RUNAI_TLS_CERT" -noout -checkend 2592000 >/dev/null && ok "certificate valid > 30 days" || bad "certificate expires within 30 days"
fi
ip=${RUNAI_RESOLVE_IP:-$($PY -c 'import socket,sys; print(socket.gethostbyname(sys.argv[1]))' "$RUNAI_DOMAIN" 2>/dev/null || true)}
[ -n "$ip" ] && ok "$RUNAI_DOMAIN -> $ip" || bad "$RUNAI_DOMAIN does not resolve (DNS, or RUNAI_RESOLVE_IP)"

exit $fail
