#!/bin/bash
# Storage features for Run:ai project volumes, on top of the cluster's
# existing storage:
#   WEKA_CSI=yes    csi-wekafs + API Secret + StorageClass $WEKA_STORAGECLASS
#   CEPHFS_CSI=yes  ceph-csi-cephfs + key Secret + StorageClass $CEPHFS_STORAGECLASS
# Secrets are read from files named in .env and never put on a command line.
# A self-test provisions, mounts, writes and deletes a 1 GiB volume per class.
. "$(dirname "$0")/../lib/common.sh"
FEAT="$LOCAL_SRC/features"
: "${WEKA_STORAGECLASS:=weka-projects}" "${WEKA_FILESYSTEM:=default}" "${WEKA_ORG:=Root}" "${WEKA_SCHEME:=https}"
: "${WEKA_DEFAULT_CLASS:=false}" "${WEKA_RECLAIM_POLICY:=Retain}" "${WEKA_VOLUME_PERMISSIONS:=0775}"
: "${WEKA_API_ENDPOINTS:=}" "${WEKA_API_USER:=}" "${WEKA_API_PASSWORD_FILE:=}" "${WEKA_API_CA_FILE:=}"
: "${CEPHFS_STORAGECLASS:=cephfs-projects}" "${CEPHFS_SUBVOLUMEGROUP:=csi}" "${CEPH_FS_NAME:=cephfs}"
: "${CEPHFS_DEFAULT_CLASS:=false}" "${CEPHFS_RECLAIM_POLICY:=Retain}"
: "${CEPH_CLUSTER_ID:=}" "${CEPH_MONITORS:=}" "${CEPH_ADMIN_ID:=}" "${CEPH_ADMIN_KEY_FILE:=}"
: "${CEPH_USER_ID:=}" "${CEPH_USER_KEY_FILE:=}"
: "${STORAGE_SELFTEST:=yes}"
export WEKA_STORAGECLASS WEKA_FILESYSTEM WEKA_DEFAULT_CLASS WEKA_RECLAIM_POLICY WEKA_VOLUME_PERMISSIONS \
       CEPHFS_STORAGECLASS CEPHFS_SUBVOLUMEGROUP CEPH_FS_NAME CEPHFS_DEFAULT_CLASS CEPHFS_RECLAIM_POLICY CEPH_CLUSTER_ID

render() { $PY -c 'import os,string,sys; print(string.Template(open(sys.argv[1]).read()).substitute(os.environ))' "$1"; }

selftest() {   # <storage class>
  is_yes "$STORAGE_SELFTEST" || return 0
  local n="storage-selftest-$1"
  cat <<EOF | $KUBECTL apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: $n, namespace: default}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: $1
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: $n, namespace: default}
spec:
  restartPolicy: Never
  containers:
    - name: check
      image: docker.io/library/ubuntu:24.04
      command: [sh, -c, "echo ok > /data/check && cat /data/check && df -h /data | tail -1"]
      volumeMounts: [{name: data, mountPath: /data}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: $n}}]
EOF
  if $KUBECTL -n default wait pod/$n --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s >/dev/null; then
    say "  self-test $1 on $($KUBECTL -n default get pod $n -o jsonpath='{.spec.nodeName}'): $($KUBECTL -n default logs $n | tr '\n' ' ')"
  else
    warn "self-test $1 failed:"; $KUBECTL -n default describe pod/$n | tail -15 >&2
    $KUBECTL -n default describe pvc/$n | tail -8 >&2
  fi
  $KUBECTL -n default delete pod/$n pvc/$n --wait=false >/dev/null
}

if is_yes "$WEKA_CSI"; then
  need WEKA_API_ENDPOINTS WEKA_API_USER WEKA_API_PASSWORD_FILE
  ensure_ns csi-wekafs
  # Weka's documented Secret format: endpoints = comma-separated host:port
  # of the cluster's management API (14000), organization, scheme
  $KUBECTL -n csi-wekafs create secret generic csi-wekafs-api-secret \
    --from-literal=username="$WEKA_API_USER" --from-file=password="$WEKA_API_PASSWORD_FILE" \
    --from-literal=organization="$WEKA_ORG" --from-literal=endpoints="$WEKA_API_ENDPOINTS" \
    --from-literal=scheme="$WEKA_SCHEME" \
    $([ -n "$WEKA_API_CA_FILE" ] && echo "--from-file=caCertificate=$WEKA_API_CA_FILE") \
    --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
  $HELM upgrade --install csi-wekafs "$(chart_tgz csi-wekafsplugin)" -n csi-wekafs \
    -f "$FEAT/weka/values.yaml" ${SITE_VALUES_DIR:+$( [ -f "$SITE_VALUES_DIR/csi-wekafs.yaml" ] && echo "-f $SITE_VALUES_DIR/csi-wekafs.yaml")} \
    --wait --timeout 10m
  render "$FEAT/weka/storageclass.yaml" | $KUBECTL apply -f -
  selftest "$WEKA_STORAGECLASS"
fi

if is_yes "$CEPHFS_CSI"; then
  need CEPH_CLUSTER_ID CEPH_MONITORS CEPH_ADMIN_ID CEPH_ADMIN_KEY_FILE
  ensure_ns ceph-csi-cephfs
  # adminID/adminKey: provisioning (subvolumes); userID/userKey: static volumes
  $KUBECTL -n ceph-csi-cephfs create secret generic csi-cephfs-secret \
    --from-literal=adminID="$CEPH_ADMIN_ID" --from-file=adminKey="$CEPH_ADMIN_KEY_FILE" \
    --from-literal=userID="${CEPH_USER_ID:-$CEPH_ADMIN_ID}" --from-file=userKey="${CEPH_USER_KEY_FILE:-$CEPH_ADMIN_KEY_FILE}" \
    --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
  CLUSTER_VALUES=$(mktemp); trap 'rm -f "$CLUSTER_VALUES"' EXIT
  $PY -c 'import sys,yaml; print(yaml.safe_dump({"csiConfig": [{"clusterID": sys.argv[1],
      "monitors": [m.strip() for m in sys.argv[2].split(",") if m.strip()], "cephFS": {"subvolumeGroup": sys.argv[3]}}]}))' \
    "$CEPH_CLUSTER_ID" "$CEPH_MONITORS" "$CEPHFS_SUBVOLUMEGROUP" > "$CLUSTER_VALUES"
  $HELM upgrade --install ceph-csi-cephfs "$(chart_tgz ceph-csi-cephfs)" -n ceph-csi-cephfs \
    -f "$FEAT/cephfs/values.yaml" -f "$CLUSTER_VALUES" \
    ${SITE_VALUES_DIR:+$( [ -f "$SITE_VALUES_DIR/ceph-csi-cephfs.yaml" ] && echo "-f $SITE_VALUES_DIR/ceph-csi-cephfs.yaml")} \
    --wait --timeout 10m
  render "$FEAT/cephfs/storageclass.yaml" | $KUBECTL apply -f -
  selftest "$CEPHFS_STORAGECLASS"
fi

is_yes "$WEKA_CSI" || is_yes "$CEPHFS_CSI" || say "no storage features enabled (WEKA_CSI / CEPHFS_CSI); using the cluster's storage"
$KUBECTL get storageclass
