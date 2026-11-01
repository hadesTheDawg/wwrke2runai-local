#!/bin/bash
# kube-prometheus-stack, a Run:ai cluster prerequisite (Prometheus Operator
# CRDs). INSTALL_PROMETHEUS=auto installs it only when the CRDs are missing,
# so a site monitoring stack that already provides them is left alone.
. "$(dirname "$0")/../lib/common.sh"

case "$INSTALL_PROMETHEUS" in
  no) say "INSTALL_PROMETHEUS=no: skipping"; exit 0 ;;
  auto)
    if $KUBECTL get crd prometheuses.monitoring.coreos.com >/dev/null 2>&1 \
       && ! $HELM -n monitoring status kube-prometheus-stack >/dev/null 2>&1; then
      say "Prometheus Operator CRDs present (site monitoring): skipping"; exit 0
    fi ;;
esac

$HELM upgrade --install kube-prometheus-stack "$(chart_tgz kube-prometheus-stack)" \
  -n monitoring --create-namespace $(values kube-prometheus-stack) --wait --timeout 15m
$KUBECTL -n monitoring get pods -o wide
