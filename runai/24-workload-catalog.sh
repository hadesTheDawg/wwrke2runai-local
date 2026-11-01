#!/bin/bash
# Run:ai workload catalog, the way Run:ai is meant to be fed in production:
#
#   images        catalog/environments.yaml -> ${WL_REGISTRY}/${WL_REG_PREFIX}/...
#   Environments  one per catalog entry (what users pick in the UI/CLI)
#   Credentials   "workload-registry-pull" (Docker registry: image pulls)
#                 "workload-registry"      (Generic secret: URL, user,
#                                           password, CA for queries)
#   Data source   "workload-registry" (Secret) -> /etc/workload-registry in
#                 any workload that selects it:
#     curl --cacert /etc/workload-registry/ca.crt \
#          -u "$(cat /etc/workload-registry/username):$(cat /etc/workload-registry/password)" \
#          "$(cat /etc/workload-registry/url)/v2/_catalog"
#
#   Clean-up      environments whose image is not in the workload registry
#                 (e.g. Run:ai's internet-only built-ins) are deleted, so the
#                 UI only offers what the offline nodes can run
#                 (KEEP_UNUSABLE=1: report only)
#
# Environments and the pull credential are tenant-scoped; the generic secret
# and its data source are cluster-scoped (Run:ai's limit). All projects see
# them. Idempotent: environments are
# updated in place; credentials are created once (rotate: delete them in the
# UI, re-run 18-workload-registry.sh and this script).
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$RUNAI_SRC/lib/api.sh"
CATALOG="$RUNAI_SRC/catalog/environments.yaml"
REPO="$WL_REGISTRY/$WL_REG_PREFIX"
PUSH="$(cat "$REG_DIR/username"):$(cat "$REG_DIR/password")"

# --- images -------------------------------------------------------------------
# pushed through the read-write registry; ${WL_REGISTRY} serves the same storage
echo "catalog images -> $REPO"
while read -r src dest; do
  rw="$REGISTRY/${dest#*/}"
  if skopeo inspect --raw --creds "$PUSH" "docker://$rw" >/dev/null 2>&1; then
    echo "  have   ${dest#*/}"
  else
    skopeo copy -q --multi-arch all --preserve-digests --dest-creds "$PUSH" "docker://$src" "docker://$rw"
    echo "  copied ${dest#*/}  <- $src"
  fi
done < <(python3 "$RUNAI_SRC/lib/catalog.py" "$CATALOG" images "$REPO")

# built entries (26-build-image.sh) only get an environment once pushed
unbuilt=" "
while IFS=$'\t' read -r name _ image; do
  if skopeo inspect --raw --creds "$PUSH" "docker://$REGISTRY/$WL_REG_PREFIX/$image" >/dev/null 2>&1; then
    echo "  built  $WL_REG_PREFIX/$image"
  else
    echo "  NOT BUILT $WL_REG_PREFIX/$image (run 26-build-image.sh $name)"; unbuilt+="$name "
  fi
done < <(python3 "$RUNAI_SRC/lib/catalog.py" "$CATALOG" builds)

runai_login

# --- environments (create or update by name) ------------------------------------
existing=$(runai_api GET /api/v1/asset/environment)
while IFS=$'\t' read -r name body; do
  case "$unbuilt" in *" $name "*) continue ;; esac
  id=$(echo "$existing" | json_get "next((e['meta']['id'] for e in d['entries'] if e['meta']['name']=='$name' and e['meta']['scope']=='tenant'), '')")
  if [ "$(echo "$body" | json_get "d.get('keepSpec', False)")" = True ]; then
    # re-point an existing (built-in) environment, keep its tool/command spec
    if [ -z "$id" ]; then echo "  skip    environment $name (keepSpec, but it does not exist)"; continue; fi
    image=$(echo "$body" | json_get "d['image']")
    body=$(runai_api GET "/api/v1/asset/environment/$id" | json_get \
      "json.dumps({'meta': {'name': d['meta']['name'], 'description': d['meta'].get('description')}, 'spec': {**d['spec'], 'image': '$image'}})")
    runai_api PUT "/api/v1/asset/environment/$id" "$body" >/dev/null && echo "  updated environment $name (image only)"
  elif [ -n "$id" ]; then
    # update accepts only the mutable meta fields (not scope or supported types)
    body=$(echo "$body" | json_get "json.dumps({**d, 'meta': {k: d['meta'][k] for k in ('name', 'description')}})")
    runai_api PUT "/api/v1/asset/environment/$id" "$body" >/dev/null && echo "  updated environment $name"
  else
    runai_api POST /api/v1/asset/environment "$body" >/dev/null && echo "  created environment $name"
  fi
done < <(python3 "$RUNAI_SRC/lib/catalog.py" "$CATALOG" payloads "$REPO")

# --- credentials --------------------------------------------------------------
cred_id() {   # <kind: dockerRegistry|genericSecret> <name>
  runai_api GET "/api/v1/asset/credentials" | json_get \
    "next((c['meta']['id'] for c in d['entries'] if c['meta']['name']=='$2' and c['meta']['kind']=='$1'), '')"
}
PULL_USER=$(cat "$REG_DIR/pull-username"); PULL_PASS=$(cat "$REG_DIR/pull-password")
# Generic secrets (and data sources built on them) are materialised as
# Kubernetes secrets, so Run:ai only allows them at cluster scope or below.
CLUSTER=$(runai_api GET /api/v1/clusters | json_get \
  "next(c['uuid'] for c in d if c['name']=='$RUNAI_CLUSTER_NAME')")

if [ -z "$(cred_id dockerRegistry workload-registry-pull)" ]; then
  runai_api POST /api/v1/asset/credentials/docker-registry "$(python3 -c '
import json,sys; print(json.dumps({"meta": {"name": "workload-registry-pull", "scope": "tenant",
  "description": "Pull-only account for the workload registry"},
  "spec": {"url": sys.argv[1], "user": sys.argv[2], "password": sys.argv[3]}}))' \
    "https://$WL_REGISTRY" "$PULL_USER" "$PULL_PASS")" >/dev/null
  echo "  created credential workload-registry-pull (docker registry)"
fi

if [ -z "$(cred_id genericSecret workload-registry)" ]; then
  runai_api POST /api/v1/asset/credentials/generic-secret "$(python3 -c '
import json,sys; print(json.dumps({"meta": {"name": "workload-registry", "scope": "cluster", "clusterId": sys.argv[5],
  "description": "Query access to the workload registry (url, username, password, ca.crt)"},
  "spec": {"keyValuePairs": [{"key": k, "value": v} for k, v in
    (("url", sys.argv[1]), ("username", sys.argv[2]), ("password", sys.argv[3]),
     ("ca.crt", open(sys.argv[4]).read()))]}}))' \
    "https://$WL_REGISTRY" "$PULL_USER" "$PULL_PASS" "$REG_DIR/ca.crt" "$CLUSTER")" >/dev/null
  echo "  created credential workload-registry (generic secret)"
fi

# --- data source: mount the generic secret into workloads ----------------------
have_ds=$(runai_api GET /api/v1/asset/datasource | json_get \
  "any(x['meta']['name']=='workload-registry' for x in d['entries'])")
if [ "$have_ds" != True ]; then
  runai_api POST /api/v1/asset/datasource/secrets "$(cat <<EOF
{"meta": {"name": "workload-registry", "scope": "cluster", "clusterId": "$CLUSTER",
          "description": "Workload registry URL, pull credentials and CA at /etc/workload-registry"},
 "spec": {"credentialAssetId": "$(cred_id genericSecret workload-registry)",
          "mountPath": "/etc/workload-registry"}}
EOF
)" >/dev/null
  echo "  created data source workload-registry -> /etc/workload-registry"
fi

# --- only usable environments in the UI ------------------------------------------
# Usable = its image is in the workload registry (the nodes are offline).
# Anything else - Run:ai's built-ins for images not in the catalog, or an
# environment someone created pointing at the internet - fails at pull time,
# so it is removed. KEEP_UNUSABLE=1 only reports. Run:ai upgrades may
# re-seed built-ins: re-run this script afterwards.
PULL="$(cat "$REG_DIR/pull-username"):$(cat "$REG_DIR/pull-password")"
echo
echo "environments (usable = image served by $WL_REGISTRY):"
while IFS=$'\t' read -r id name image; do
  ref="${image#$WL_REGISTRY/}"
  if [ "$ref" != "$image" ] && skopeo inspect --raw --creds "$PULL" "docker://$WL_REGISTRY/$ref" >/dev/null 2>&1; then
    printf '  ok      %-24s %s\n' "$name" "$image"
  elif [ -n "${KEEP_UNUSABLE:-}" ]; then
    printf '  UNUSABLE %-23s %s (kept: KEEP_UNUSABLE)\n' "$name" "$image"
  else
    runai_api DELETE "/api/v1/asset/environment/$id" >/dev/null \
      && printf '  removed %-24s %s (not in the workload registry)\n' "$name" "$image" \
      || printf '  UNUSABLE %-23s %s (delete refused, in use?)\n' "$name" "$image"
  fi
done < <(runai_api GET /api/v1/asset/environment | json_get \
  "'\n'.join(e['meta']['id'] + '\t' + e['meta']['name'] + '\t' + e['spec']['image'] for e in sorted(d['entries'], key=lambda e: e['meta']['name']))")
