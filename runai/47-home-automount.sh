#!/bin/bash
# Mount the NFS /home into the pods of Run:ai workloads that run as the
# submitting user (runAsUser >= 5000, environments with uidGidSource:
# fromIdpToken), without the user attaching the "home" data source: a
# MutatingAdmissionPolicy injects a hostPath volume + mount for each
# container in pods created in project namespaces (label runai/queue).
# Image-user environments (Jupyter, code-server, RStudio) are left alone. In-process admission - no webhook, no TLS,
# no image to mirror (needs K8s >= 1.34, RKE2 here is 1.36).
#   - a container that already mounts /home, or a pod with a volume named
#     "home", is left untouched (the "home" data source still works)
#   - opt out per workload: annotation home.htd.local/skip: "true"
# Self-test: a server dry-run pod (full admission, nothing persisted).
set -euo pipefail
. "$(dirname "$0")/env.sh"

$KUBECTL apply -f "$RUNAI_SRC/lib/home-automount.yaml" >/dev/null
echo "policy runai-home-automount applied"

NS=$($KUBECTL get ns -l runai/queue -o jsonpath='{.items[0].metadata.name}')
TEMP_NS=
if [ -z "$NS" ]; then   # no project yet: make a labeled throwaway namespace
  NS=runai-home-automount-test; TEMP_NS=1
  $KUBECTL create ns "$NS" >/dev/null 2>&1 || true
  $KUBECTL label ns "$NS" runai/queue=home-automount-test --overwrite >/dev/null
fi
probe() {   # <runAsUser or empty>: server dry-run (full admission, nothing persisted)
  local sec=""
  [ -n "$1" ] && sec="    securityContext: {runAsUser: $1, runAsGroup: $1}"
  $KUBECTL -n "$NS" create --dry-run=server -o json -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: home-automount-probe}
spec:
  containers:
  - name: c
    image: docker.io/library/ubuntu:24.04
$sec
EOF
}
USER_POD=$(probe 5101)     # runs as a site user (environment uidGidSource: fromIdpToken)
IMAGE_POD=$(probe "")      # runs as the image's user (e.g. Jupyter's jovyan)
[ -n "$TEMP_NS" ] && $KUBECTL delete ns "$NS" >/dev/null
echo "$USER_POD" | grep -q '"mountPath": *"/home"' && echo "$USER_POD" | grep -q '"path": *"/home"' \
  && echo "self-test OK: site-user pods in $NS get /home injected" \
  || { echo "SELF-TEST FAILED - site-user pod not mutated:"; echo "$USER_POD"; exit 1; }
echo "$IMAGE_POD" | grep -q '"mountPath": *"/home"' \
  && { echo "SELF-TEST FAILED - image-user pod got /home (would hide the image's own home)"; exit 1; } \
  || echo "self-test OK: image-user pods keep the image's /home"
