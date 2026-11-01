#!/bin/bash
# End-to-end check through the Run:ai API, the way a user would use it:
#   project "smoke" (1 guaranteed GPU on node pool a100 once 40-partitions.sh
#                    has run, else the pre-partition "default" pool; default
#                    node pools = the GPU partitions)
#   training "smoke-gpu"   1 whole GPU
#   training "smoke-frac"  half a GPU (Run:ai GPU fractions)
# Both must reach Running on a GPU node. Re-runnable; KEEP=1 leaves them.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$RUNAI_SRC/lib/api.sh"
PROJECT=smoke

runai_login
CLUSTER=$(runai_api GET /api/v1/clusters | json_get \
  "next(c['uuid'] for c in d if c['name']=='$RUNAI_CLUSTER_NAME')")
POOL=$(runai_api GET "/api/v1/node-pools?filterBy=clusterId==$CLUSTER" | json_get \
  "next((p['name'] for p in d['nodepools'] if p['name']=='a100'), 'default')")
# Default node pools: the GPU partitions once 40-partitions.sh has run, else
# the original "default" pool. Pool "default" holds only ww1 (no GPUs) after
# partitioning; a project still defaulting to it cannot schedule GPU work.
DEFAULT_POOLS=$(runai_api GET "/api/v1/node-pools?filterBy=clusterId==$CLUSTER" | json_get \
  "json.dumps(sorted(p['name'] for p in d['nodepools'] if p['name'] != 'default') or ['default'])" \
  2>/dev/null || echo '["default"]')
DEPT=$(runai_api GET "/api/v1/org-unit/departments?filterBy=clusterId==$CLUSTER" | json_get \
  "next(x for x in d['departments'] if x['name']=='default')['id']")

# Quota: 1 guaranteed GPU on $POOL. Workspaces (interactive) are
# non-preemptible and only run within guaranteed quota; trainings may also
# borrow idle GPUs over quota. When the research groups' guarantees already
# fill the partition this oversubscribes it by one GPU.
RES=$(runai_api GET "/api/v1/node-pools?filterBy=clusterId==$CLUSTER" | json_get \
  "json.dumps([{'nodePool': {'id': p['id'], 'name': p['name']}, 'gpu': {'deserved': 1 if p['name']=='$POOL' else 0, 'limit': -1, 'overQuotaWeight': 1}} for p in d['nodepools']])")
PID=$(runai_api GET "/api/v1/org-unit/projects?filterBy=clusterId==$CLUSTER" | json_get \
  "next((p['id'] for p in d['projects'] if p['name']=='$PROJECT'), '')")
if [ -z "$PID" ]; then
  PID=$(runai_api POST /api/v1/org-unit/projects \
    "{\"name\": \"$PROJECT\", \"clusterId\": \"$CLUSTER\", \"parentId\": \"$DEPT\", \"resources\": $RES, \"defaultNodePools\": $DEFAULT_POOLS}" \
    | json_get "d['id']")
  echo "created project $PROJECT ($PID)"
else
  runai_api PUT "/api/v1/org-unit/projects/$PID" "{\"resources\": $RES, \"defaultNodePools\": $DEFAULT_POOLS}" >/dev/null
fi

submit() {   # <name> <compute json>
  local id
  id=$(runai_api GET "/api/v1/workloads?filterBy=projectId==$PID" | json_get \
    "next((w['id'] for w in d['workloads'] if w['name']=='$1'), '')")
  if [ -n "$id" ]; then runai_api DELETE "/api/v1/workloads/trainings/$id" >/dev/null; fi
  for i in $(seq 1 30); do   # wait for a previous run to be gone
    runai_api GET "/api/v1/workloads?filterBy=projectId==$PID" | json_get \
      "any(w['name']=='$1' for w in d['workloads'])" | grep -q False && break; sleep 2
  done
  runai_api POST /api/v1/workloads/trainings "$(cat <<EOF
{"name": "$1", "projectId": "$PID", "clusterId": "$CLUSTER",
 "spec": {"image": "docker.io/library/ubuntu:24.04",
          "command": "sh", "args": "-c 'env | grep -E \"NVIDIA|RUNAI\" | sort; sleep 300'",
          "compute": $2, "nodePools": ["$POOL"]}}
EOF
)" | json_get "d['workloadId'] if 'workloadId' in d else d['id']"
}
submit smoke-gpu  '{"gpuDevicesRequest": 1}' >/dev/null
submit smoke-frac '{"gpuRequestType": "portion", "gpuPortionRequest": 0.5}' >/dev/null

echo "waiting for both workloads to run"
for i in $(seq 1 60); do
  phases=$(runai_api GET "/api/v1/workloads?filterBy=projectId==$PID" | json_get \
    "' '.join(sorted(w['name']+'='+w['phase'] for w in d['workloads']))")
  echo "$phases" | grep -q 'smoke-frac=Running' && echo "$phases" | grep -q 'smoke-gpu=Running' && break
  sleep 5
done
echo "$phases"
NS=$($KUBECTL get ns -l "runai/queue=$PROJECT" -o jsonpath='{.items[0].metadata.name}')
$KUBECTL -n "$NS" get pods -o wide
for p in $($KUBECTL -n "$NS" get pods -o name); do
  echo "== $p"; $KUBECTL -n "$NS" logs "$p" | head -8
done

if [ -z "${KEEP:-}" ]; then
  for id in $(runai_api GET "/api/v1/workloads?filterBy=projectId==$PID" | json_get "' '.join(w['id'] for w in d['workloads'])"); do
    runai_api DELETE "/api/v1/workloads/trainings/$id" >/dev/null
  done
fi
echo "$phases" | grep -q 'smoke-frac=Running' && echo "$phases" | grep -q 'smoke-gpu=Running'
