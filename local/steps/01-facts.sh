#!/bin/bash
# Record what the remote system runs and get read access to its registry.
#   state/remote-facts.env      versions, architecture (part of the bundle)
#   state/remote-pod-images.txt every image a pod on the remote cluster uses
#   secrets/remote-*            registry account + CA (fetch only, never bundled)
. "$(dirname "$0")/../lib/common.sh"
need REMOTE_SSH
mkdir -p "$STATE"; mkpriv "$SECRETS"

rsh "cat $REMOTE_REG_DIR/username" > "$SECRETS/remote-username"
( umask 077; rsh "cat $REMOTE_REG_DIR/password" > "$SECRETS/remote-password" )
rsh "cat $REMOTE_REG_DIR/ca.crt" > "$SECRETS/remote-ca.crt"
[ -s "$SECRETS/remote-password" ] || die "no registry password at $REMOTE_SSH:$REMOTE_REG_DIR/password"

rsh "set -e
  echo REMOTE_HOST=\$(hostname)
  echo REMOTE_ARCH=\$(uname -m)
  echo RKE2_VERSION=\$(rke2 --version | awk 'NR==1{print \$3}')
  echo WAREWULF_VERSION=\$(wwctl version 2>/dev/null | awk '{print \$NF}')
  echo RUNAI_LOCK=\$(cd $REMOTE_RUNAI_WORK 2>/dev/null && ls runai-*-standard-linux-*.yaml 2>/dev/null | head -1)
  echo FETCHED_AT=\$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE/remote-facts.env"

rsh "$REMOTE_KUBECTL get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{\"\n\"}{end}{range .spec.initContainers[*]}{.image}{\"\n\"}{end}{end}'" \
  | sort -u > "$STATE/remote-pod-images.txt"
rsh "$REMOTE_KUBECTL get nodes -o wide" > "$STATE/remote-nodes.txt"
rsh "helm --kubeconfig /etc/rancher/rke2/rke2.yaml list -A -o json" > "$STATE/remote-helm-releases.json" 2>/dev/null \
  || warn "helm not available on $REMOTE_SSH; release list skipped"

cat "$STATE/remote-facts.env"
say "pods on the remote cluster use $(wc -l < "$STATE/remote-pod-images.txt" | tr -d ' ') distinct images"
