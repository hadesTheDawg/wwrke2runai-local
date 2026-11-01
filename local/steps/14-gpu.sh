#!/bin/bash
# GPU layer. The target is expected to have working GPU nodes already, so the
# default is to leave it alone.
#   GPU_OPERATOR=skip     (default) GPUs managed by the site
#   GPU_OPERATOR=install  NVIDIA GPU Operator from the bundle (values/gpu-operator.yaml:
#                         driver preinstalled in the node image, RKE2 containerd socket)
#   GPU_OPERATOR=fake     Run:ai fake-gpu-operator (staging clusters without GPUs)
. "$(dirname "$0")/../lib/common.sh"

case "$GPU_OPERATOR" in
  skip) say "GPU_OPERATOR=skip" ;;
  install)
    $HELM upgrade --install gpu-operator "$(chart_tgz gpu-operator)" \
      -n gpu-operator --create-namespace $(values gpu-operator) --wait --timeout 20m ;;
  fake)
    $HELM upgrade --install fake-gpu-operator "$(chart_tgz fake-gpu-operator)" \
      -n gpu-operator --create-namespace $(values fake-gpu-operator) --wait --timeout 10m ;;
  *) die "unknown GPU_OPERATOR=$GPU_OPERATOR" ;;
esac

# Run:ai reads GPU metrics from the DCGM exporter in gpu-operator
$KUBECTL get pods -A -l app=nvidia-dcgm-exporter -o wide 2>/dev/null | sed -n '1,5p' || true
$KUBECTL get nodes -o custom-columns='NODE:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product'
