#!/bin/bash
# GPU layer, chosen by GPU_MODE:
#   fake    Run:ai fake-gpu-operator: simulated GPUs on nodes with the
#           run.ai/simulated-gpu-node-pool label (Warewulf tag
#           runai_fake_gpu_pool). Lets Run:ai be exercised without hardware.
#   nvidia  NVIDIA GPU Operator (driver baked into the node image, see
#           values/gpu-operator.yaml).
#   none    skip (GPU operator managed elsewhere).
# Both install into "gpu-operator", where Run:ai looks for the DCGM exporter.
set -euo pipefail
. "$(dirname "$0")/env.sh"

case "$GPU_MODE" in
  fake)
    $HELM upgrade --install fake-gpu-operator "$CHART_REPO/fake-gpu-operator" --version "$FAKE_GPU_VERSION" \
      -n gpu-operator --create-namespace $(values fake-gpu-operator) --wait --timeout 10m
    echo "waiting for every pool-labelled node to advertise simulated GPUs"
    sel=run.ai/simulated-gpu-node-pool
    for i in $(seq 1 60); do
      want=$($KUBECTL get nodes -l "$sel" -o name | wc -l)
      have=$($KUBECTL get nodes -l "$sel" -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' | grep -c '[1-9]' || true)
      [ "$want" -gt 0 ] && [ "$have" -eq "$want" ] && break; sleep 5
    done ;;
  nvidia)
    $HELM upgrade --install gpu-operator "$CHART_REPO/gpu-operator" --version "$GPU_OPERATOR_VERSION" \
      -n gpu-operator --create-namespace $(values gpu-operator) --wait --timeout 20m ;;
  none) echo "GPU_MODE=none: skipping" ;;
  *) echo "unknown GPU_MODE=$GPU_MODE" >&2; exit 1 ;;
esac

$KUBECTL get nodes -o custom-columns='NODE:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product,POOL:.metadata.labels.run\.ai/simulated-gpu-node-pool'
