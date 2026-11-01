#!/bin/bash
# Slurm-style partitions from org/cluster.yaml:
#   Warewulf  node tags runai_node_labels=runai/node-pool=<partition> (and,
#             GPU_MODE=fake, runai_fake_gpu_pool=<partition>) -> labels on
#             every boot via the runai overlay
#   now       the same labels applied live (no reboot needed)
#   GPUs      fake-gpu-operator topology: one simulated GPU type per partition
#   Run:ai    one node pool per partition (label runai/node-pool=<name>)
# runai/node-pool is the node-pool label key KAI is configured with.
set -euo pipefail
. "$(dirname "$0")/env.sh"
ORG="$RUNAI_SRC/org/cluster.yaml"
KEY=runai/node-pool

# --- nodes ---------------------------------------------------------------------
while read -r part node; do
  wwctl node set -y "$node" --tagadd "runai_node_labels=$KEY=$part" >/dev/null
  labels=("$KEY=$part")
  if [ "$GPU_MODE" = fake ]; then
    wwctl node set -y "$node" --tagadd "runai_fake_gpu_pool=$part" >/dev/null
    labels+=("run.ai/simulated-gpu-node-pool=$part")
  fi
  $KUBECTL label node "$node" "${labels[@]}" --overwrite >/dev/null
  echo "  $node -> partition $part"
done < <(python3 -c 'import sys,yaml
for p, d in yaml.safe_load(open(sys.argv[1]))["partitions"].items():
    for n in d["nodes"]: print(p, n)' "$ORG")
wwctl overlay build >/dev/null

# --- simulated GPU types per partition -------------------------------------------
if [ "$GPU_MODE" = fake ]; then
  TOPO=$(mktemp --suffix=.yaml); trap 'rm -f "$TOPO"' EXIT
  python3 -c 'import sys,yaml
parts = yaml.safe_load(open(sys.argv[1]))["partitions"]
pools = {p: {"gpuProduct": d["gpu"]["product"], "gpuCount": d["gpu"]["count"],
             "gpuMemory": d["gpu"]["memoryMiB"]} for p, d in parts.items()}
print(yaml.safe_dump({"topology": {"nodePools": pools}}))' "$ORG" > "$TOPO"
  $HELM upgrade fake-gpu-operator "$CHART_REPO/fake-gpu-operator" --version "$FAKE_GPU_VERSION" \
    -n gpu-operator $(values fake-gpu-operator) -f "$TOPO" --wait --timeout 10m >/dev/null
  # fake-gpu-operator caches each node's GPUs in ConfigMap topology-<node>,
  # generated once from the node's first pool. Nodes that changed partition
  # keep the old GPU type until it is regenerated.
  mismatched() {
    $KUBECTL get nodes -l run.ai/simulated-gpu-node-pool -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.labels.run\.ai/simulated-gpu-node-pool} {.metadata.labels.nvidia\.com/gpu\.product}{"\n"}{end}' \
      | python3 -c 'import sys,yaml
want = {p: d["gpu"]["product"] for p, d in yaml.safe_load(open(sys.argv[1]))["partitions"].items()}
for line in sys.stdin:
    node, pool, product = (line.split() + ["", "", ""])[:3]
    if pool in want and want[pool] != product: print(node)' "$ORG"
  }
  stale=$(mismatched)
  if [ -n "$stale" ]; then
    for n in $stale; do
      echo "  $n: regenerating simulated GPUs"
      $KUBECTL -n gpu-operator delete cm "topology-$n" --ignore-not-found >/dev/null
    done
    $KUBECTL -n gpu-operator rollout restart deploy/status-updater >/dev/null
    $KUBECTL -n gpu-operator rollout status deploy/status-updater --timeout=180s >/dev/null
    for n in $stale; do
      for i in $(seq 1 24); do $KUBECTL -n gpu-operator get cm "topology-$n" >/dev/null 2>&1 && break; sleep 5; done
      $KUBECTL -n gpu-operator delete pod -l app=device-plugin --field-selector "spec.nodeName=$n" >/dev/null
    done
    for i in $(seq 1 36); do [ -z "$(mismatched)" ] && break; sleep 5; done
    if [ -n "$(mismatched)" ]; then echo "simulated GPU type still wrong on: $(mismatched)" >&2; exit 1; fi
  fi
fi

# --- Run:ai node pools -------------------------------------------------------------
python3 - "$ORG" <<'EOF'
import sys, time, yaml
sys.path.insert(0, __import__("os").environ["RUNAI_SRC"] + "/lib")
from runai import RunAI
parts = yaml.safe_load(open(sys.argv[1]))["partitions"]
api = RunAI()
have = api.node_pools()
for p in parts:
    if p not in have:
        api.post("/api/v1/node-pools", {"name": p, "labelKey": "runai/node-pool", "labelValue": p,
                                       "clusterId": api.cluster})
        print(f"  created node pool {p}")
for _ in range(60):
    pools = api.node_pools()
    if all(pools[p].get("phase") == "Ready" for p in parts):
        break
    time.sleep(5)
EOF

$KUBECTL get nodes -o custom-columns='NODE:.metadata.name,PARTITION:.metadata.labels.runai/node-pool,GPU:.metadata.labels.nvidia\.com/gpu\.product,COUNT:.status.allocatable.nvidia\.com/gpu'
