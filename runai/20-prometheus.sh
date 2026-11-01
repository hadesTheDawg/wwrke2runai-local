#!/bin/bash
# kube-prometheus-stack: required by the Run:ai cluster (Prometheus Operator
# CRDs; Run:ai creates its own Prometheus instance in "runai").
set -euo pipefail
. "$(dirname "$0")/env.sh"

$HELM upgrade --install kube-prometheus-stack "$CHART_REPO/kube-prometheus-stack" --version "$KPS_VERSION" \
  -n monitoring --create-namespace $(values kube-prometheus-stack) \
  --wait --timeout 15m
$KUBECTL -n monitoring get pods -o wide
