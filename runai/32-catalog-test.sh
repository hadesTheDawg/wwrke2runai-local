#!/bin/bash
# Exercise the workload catalog the way a user does, through the Run:ai API
# (asset-based submission = what the UI wizard sends), in project "smoke"
# (created by 30-smoke-test.sh):
#   training  "catalog-query"  environment rocky9 + data source
#             workload-registry -> lists the workload registry from inside
#   workspace "catalog-rstudio" environment rstudio -> its host-based URL
#             must answer through ww1 with Run:ai's SSO redirect
#   trainings "catalog-os-<env>" every other catalog environment must pull
#             (offline node) and run, printing its OS release
# KEEP=1 leaves both workloads running.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$RUNAI_SRC/lib/api.sh"

runai_login
CLUSTER=$(runai_api GET /api/v1/clusters | json_get "next(c['uuid'] for c in d if c['name']=='$RUNAI_CLUSTER_NAME')")
PROJECT=$(runai_api GET "/api/v1/org-unit/projects?filterBy=clusterId==$CLUSTER" | json_get \
  "next(p['id'] for p in d['projects'] if p['name']=='smoke')")
NS=$($KUBECTL get ns -l runai/queue=smoke -o jsonpath='{.items[0].metadata.name}')
env_id() { runai_api GET /api/v1/asset/environment | json_get "next(e['meta']['id'] for e in d['entries'] if e['meta']['name']=='$1')"; }
DS=$(runai_api GET /api/v1/asset/datasource | json_get "next(x['meta']['id'] for x in d['entries'] if x['meta']['name']=='workload-registry')")

OS_ENVS=$(python3 -c 'import sys,yaml; print(" ".join(e["name"] for e in yaml.safe_load(open(sys.argv[1]))["environments"] if not e.get("connections")))' \
  "$RUNAI_SRC/catalog/environments.yaml")

cleanup() {   # delete through the type-specific endpoint (generic one is 403)
  for w in catalog-query:trainings catalog-rstudio:workspaces $(printf 'catalog-os-%s:trainings ' $OS_ENVS); do
    id=$(runai_api GET "/api/v1/workloads?filterBy=name==${w%:*}" | json_get "d['workloads'][0]['id'] if d['workloads'] else ''")
    if [ -n "$id" ]; then runai_api DELETE "/api/v1/workloads/${w#*:}/$id" >/dev/null || true; fi
  done
  for i in $(seq 1 30); do
    [ -z "$($KUBECTL -n "$NS" get pods -l 'workloadName' -o name | grep catalog-)" ] && break; sleep 2
  done
}
cleanup

# --- query the registry from a workload ----------------------------------------
# Run:ai splits `args` shell-style: keep the script free of double quotes.
# n=1000: the catalog is paged (100 by default) and workloads/* sort last.
QUERY='R=/etc/workload-registry; A=$(cat $R/username):$(cat $R/password); U=$(cat $R/url);
curl -sf --cacert $R/ca.crt -u $A --get -d n=1000 $U/v2/_catalog | grep -o workloads/[a-z0-9._-]*;
curl -sf --cacert $R/ca.crt -u $A $U/v2/workloads/rstudio/tags/list'
runai_api POST /api/v2/training "$(python3 -c '
import json,sys; print(json.dumps({"meta": {"name": "catalog-query", "projectId": sys.argv[1], "clusterId": sys.argv[2]},
  "assets": {"environment": sys.argv[3], "compute": None, "datasources": [{"id": sys.argv[4], "kind": "secret-volume"}]},
  "specificRunParams": {"command": "sh", "args": "-c \x27" + sys.argv[5].replace("\n", " ") + "\x27"}}))' \
  "$PROJECT" "$CLUSTER" "$(env_id rocky9)" "$DS" "$QUERY")" >/dev/null

# --- RStudio workspace -----------------------------------------------------------
runai_api POST /api/v2/workspace "$(python3 -c '
import json,sys; print(json.dumps({"meta": {"name": "catalog-rstudio", "projectId": sys.argv[1], "clusterId": sys.argv[2]},
  "assets": {"environment": sys.argv[3], "compute": None, "datasources": []}, "specificRunParams": {}}))' \
  "$PROJECT" "$CLUSTER" "$(env_id rstudio)")" >/dev/null

# --- every OS image: pull + run ------------------------------------------------
for e in $OS_ENVS; do
  runai_api POST /api/v2/training "$(python3 -c '
import json,sys; print(json.dumps({"meta": {"name": "catalog-os-" + sys.argv[4], "projectId": sys.argv[1], "clusterId": sys.argv[2]},
  "assets": {"environment": sys.argv[3], "compute": None, "datasources": []},
  "specificRunParams": {"command": "sh", "args": "-c \x27. /etc/os-release; echo $PRETTY_NAME on $(uname -m)\x27"}}))' \
    "$PROJECT" "$CLUSTER" "$(env_id "$e")" "$e")" >/dev/null
done

phase() { $KUBECTL -n "$NS" get pods -l "workloadName=$1" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true; }
for i in $(seq 1 90); do
  q=$(phase catalog-query); r=$(phase catalog-rstudio); pending=0
  for e in $OS_ENVS; do case "$(phase "catalog-os-$e")" in Succeeded|Failed) ;; *) pending=1 ;; esac; done
  case "$q" in Succeeded|Failed) ;; *) pending=1 ;; esac
  [ "$r" = Running ] || pending=1
  [ $pending = 0 ] && break
  sleep 5
done

os_ok=true
echo "== catalog OS images:"
for e in $OS_ENVS; do
  p=$(phase "catalog-os-$e"); [ "$p" = Succeeded ] || os_ok=false
  printf '  %-8s %-10s %s\n' "$e" "$p" "$($KUBECTL -n "$NS" logs -l "workloadName=catalog-os-$e" --tail=1 2>/dev/null)"
done

echo "== catalog-query ($q), output:"
$KUBECTL -n "$NS" logs -l workloadName=catalog-query --tail=-1 | sed 's/^/  /'

WID=$(runai_api GET "/api/v1/workloads?filterBy=name==catalog-rstudio" | json_get "d['workloads'][0]['id']")
URL=$(runai_api GET "/api/v1/workloads/$WID" | json_get "(d.get('urls') or [''])[0]")
HOST=${URL#https://}; HOST=${HOST%/}
code=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --cacert "$RUNAI_DIR/ca.crt" \
  --resolve "$HOST:443:$WW_EXTERNAL_IP" "$URL" || true)
echo "== catalog-rstudio ($r): $URL -> ${code%% *} -> $(echo "${code#* }" | cut -d'?' -f1)"

[ -n "${KEEP:-}" ] || cleanup
$os_ok && [ "$q" = Succeeded ] && [ "$r" = Running ] && [ "${code%% *}" = 302 ] \
  && echo "${code#* }" | grep -q "/auth/realms/"
