#!/bin/bash
# The target runs only what the bundle provides: every image of every pod
# resolves in TARGET_REGISTRY under the mirror path (a gap means a node
# pulled from the internet, or will fail to once it cannot), and the Run:ai
# cluster is Connected.
. "$(dirname "$0")/../lib/common.sh"
need TARGET_REGISTRY
AUTH="$SECRETS/target-auth.json"; [ -s "$AUTH" ] || die "run make push first (target credentials)"
REG="$PY $LIB/registry.py --authfile $AUTH"
[ -n "$TARGET_REGISTRY_CA" ] && REG="$REG --ca $TARGET_REGISTRY_CA"
is_yes "$TARGET_REGISTRY_TLS_VERIFY" || REG="$REG --insecure"

missing=0; n=0
for img in $($KUBECTL get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' | sort -u); do
  n=$((n+1))
  ref="${img%@*}"; ref="${ref#index.docker.io/}"; ref="${ref#docker.io/}"
  case "$ref" in
    "$TARGET_REGISTRY"/*|"$TARGET_WORKLOAD_REGISTRY"/*) path="${ref#*/}" ;;   # already local
    */*/*|*.*/*|*:*/*) path="${TARGET_REGISTRY_PREFIX:+$TARGET_REGISTRY_PREFIX/}${ref#*/}" ;;
    */*) path="${TARGET_REGISTRY_PREFIX:+$TARGET_REGISTRY_PREFIX/}$ref" ;;
    *)   path="${TARGET_REGISTRY_PREFIX:+$TARGET_REGISTRY_PREFIX/}library/$ref" ;;
  esac
  case "${path##*/}" in *:*) ;; *) path="$path:latest" ;; esac
  $REG digest "$TARGET_REGISTRY" "${path%:*}" "${path##*:}" >/dev/null 2>&1 \
    || { say "MISSING $img  ($TARGET_REGISTRY/$path)"; missing=1; }
done
[ $missing = 0 ] && say "all $n images in use are served by $TARGET_REGISTRY"

UUID=$($PY "$LIB/runai_api.py" cluster 2>/dev/null) && say "Run:ai cluster $RUNAI_CLUSTER_NAME: $($PY "$LIB/runai_api.py" cluster-state "$UUID")"
exit $missing
