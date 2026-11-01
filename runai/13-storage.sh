#!/bin/bash
# Default StorageClass for Run:ai: an NFS export on ww1 (persistent disk),
# provisioned by csi-driver-nfs so any node, stateless or not, can mount it.
# The export lives in /etc/exports.d because Warewulf owns /etc/exports.
set -euo pipefail
. "$(dirname "$0")/env.sh"

mkdir -p "$RUNAI_NFS_DIR"
# no_root_squash: the provisioner creates/chowns per-volume directories
EXPORT="$RUNAI_NFS_DIR ${WW_INTERNAL_IP%.*}.0/24(rw,sync,no_subtree_check,no_root_squash)"
if [ "$(cat /etc/exports.d/runai.exports 2>/dev/null)" != "$EXPORT" ]; then
  echo "$EXPORT" > /etc/exports.d/runai.exports
  exportfs -ra
fi
exportfs -v | grep -F "$RUNAI_NFS_DIR"

$HELM upgrade --install csi-driver-nfs "$CHART_REPO/csi-driver-nfs" --version "$CSI_NFS_VERSION" \
  -n kube-system $(values csi-driver-nfs) \
  --set storageClass.name="$RUNAI_STORAGECLASS" \
  --set storageClass.parameters.server="$RUNAI_NFS_SERVER" \
  --set storageClass.parameters.share="$RUNAI_NFS_DIR" \
  --wait --timeout 10m

# provision -> mount -> write -> delete, on a compute node if there is one
cat <<EOF | $KUBECTL apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: runai-storage-check, namespace: default}
spec:
  accessModes: [ReadWriteMany]
  resources: {requests: {storage: 1Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: runai-storage-check, namespace: default}
spec:
  restartPolicy: Never
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 1
          preference:
            matchExpressions: [{key: node-role.kubernetes.io/control-plane, operator: DoesNotExist}]
  containers:
    - name: check
      image: docker.io/library/ubuntu:24.04
      command: [sh, -c, "echo ok > /data/check && cat /data/check"]
      volumeMounts: [{name: data, mountPath: /data}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: runai-storage-check}}]
EOF
$KUBECTL -n default wait pod/runai-storage-check --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s
echo "storage check on $($KUBECTL -n default get pod runai-storage-check -o jsonpath='{.spec.nodeName}'): $($KUBECTL -n default logs runai-storage-check)"
$KUBECTL -n default delete pod/runai-storage-check pvc/runai-storage-check --wait=false >/dev/null
$KUBECTL get storageclass
