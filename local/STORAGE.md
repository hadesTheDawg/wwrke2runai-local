# Weka and CephFS volumes for Run:ai projects

How this toolkit gives Run:ai projects persistent, shared storage on WekaFS
(csi-wekafs) and CephFS (ceph-csi), and how researchers use it. Both
drivers are optional features of the local deployment (`WEKA_CSI=yes`,
`CEPHFS_CSI=yes` in `.env`); the cluster's existing default StorageClass
stays as it is unless you choose otherwise.

```
.env ──▶ make storage ─────────▶ CSI driver + Secret + StorageClass (weka-projects / cephfs-projects)
                                    │ self-test: 1 GiB PVC provisioned, mounted, written, deleted
project-volumes.yaml ──▶ make project-volumes
                                    ├─ PVC in runai-<project>     (new: from the StorageClass,
                                    │                              existing: static PV → Weka dir / CephFS path)
                                    └─ Run:ai data source (PVC, project scope) → mountPath
researcher ──▶ UI: Data sources ▸ pick "work"   |   CLI: --existing-pvc   |   YAML: persistentVolumeClaim
```

## Contents

1. [Three ways a project gets storage](#1-three-ways-a-project-gets-storage)
2. [Weka](#2-weka)
3. [CephFS](#3-cephfs)
4. [Project volumes (`project-volumes.yaml`)](#4-project-volumes-project-volumesyaml)
5. [Using the volumes in workloads](#5-using-the-volumes-in-workloads)
6. [Permissions, quotas, lifecycle](#6-permissions-quotas-lifecycle)
7. [Warewulf nodes](#7-warewulf-nodes)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Three ways a project gets storage

| Way | Who creates it | Lifetime | Use for |
|---|---|---|---|
| **Project volume**: PVC + project-scoped Run:ai data source (`make project-volumes`) | admin, declaratively | permanent, survives workloads | a project's shared working area (`/work`), group directories |
| **Existing data**: static PV bound to a Weka directory or CephFS path, then a project volume | admin | permanent, data predates Kubernetes | datasets, models, read-only shares across projects |
| **Per-workload PVC** from a StorageClass (UI: *New data source ▸ PVC ▸ storage class*; CLI `--new-pvc`) | researcher | the workload's, or until deleted | checkpoints of one experiment |

All three end up as an ordinary PVC in the project's namespace
(`runai-<project>`). Run:ai only decides which projects see which data
source; access to the bytes is the file system's (§6).

## 2. Weka

### 2.1 Prerequisites (site side, not done by this toolkit)

- **A Weka client on every GPU node** that mounts volumes. On stateless
  (Warewulf) nodes use Weka *stateless clients*: `mount -t wekafs` downloads
  the client from the backend at first mount, so the node image stays small.
  csi-wekafs mounts through that client.
- **DPDK clients**: frontend cores busy-poll and need hugepages. Keep the
  kubelet off those cores and that memory (`csi-storage` overlay tags in §7).
- **An API user** in the Weka organization that owns the filesystem, used by
  the CSI controller to create directories and quotas (Weka offers a
  dedicated CSI role on recent releases; otherwise an org admin), with its
  password in a 0600 file.
- **A filesystem** for project volumes, e.g. `projects`. Directory-backed
  volumes (`dir/v1`) put every PVC in a directory of it with its own quota,
  so thousands of volumes cost nothing on the Weka side.
- **Network**: nodes → Weka backends (client traffic), CSI controller →
  management API (`:14000`).

### 2.2 Settings and install

```sh
# .env
WEKA_CSI=yes
WEKA_CSI_VERSION=                 # empty = newest at fetch time (recorded in charts/)
WEKA_API_ENDPOINTS=weka01:14000,weka02:14000,weka03:14000
WEKA_API_USER=csi
WEKA_API_PASSWORD_FILE=~/.secrets/weka-csi-password
WEKA_API_CA_FILE=~/.secrets/weka-ca.crt   # API certificate CA (TLS stays verified)
WEKA_ORG=Root
WEKA_FILESYSTEM=projects
WEKA_STORAGECLASS=weka-projects
WEKA_RECLAIM_POLICY=Retain        # deleting a PVC keeps the directory
WEKA_DEFAULT_CLASS=false          # true: also the cluster default (control plane DBs on Weka)
```

```sh
make features          # (fetch side) chart + images into the local repo
make push storage      # (deploy side) images to the registry, driver, Secret, StorageClass, self-test
```

What `make storage` creates:

| Object | Content |
|---|---|
| Secret `csi-wekafs/csi-wekafs-api-secret` | `username`, `password` (from the file), `organization`, `endpoints`, `scheme`, `caCertificate` |
| Helm release `csi-wekafs` | chart `csi-wekafsplugin`, `local/features/weka/values.yaml` (+ `$SITE_VALUES_DIR/csi-wekafs.yaml`) |
| StorageClass `weka-projects` | `local/features/weka/storageclass.yaml`: `volumeType: dir/v1`, `filesystemName`, `capacityEnforcement: HARD`, `permissions: "0775"`, the Secret for every CSI operation |

`dir/v1` is the type csi-wekafs documents for API-managed directory
volumes; the chart calls it "legacy" with regard to snapshots (a snapshot of
a `dir/v1` volume is a whole-filesystem snapshot). If you need efficient
per-volume snapshots, use the newer volume type from csi-wekafs's
documentation for your driver version in `local/features/weka/storageclass.yaml`.

Nodes **without** a Weka client can mount through Weka's NFS protocol
gateway instead (chart ≥ 2.5, `pluginConfig.mountProtocol` in the values
file). That is slower and has no GPUDirect Storage; the native client is the
default.

### 2.3 Existing Weka directories

A static volume maps an existing directory into a project without copying
it. In `project-volumes.yaml`:

```yaml
  - name: imagenet
    projects: [vision, theory]
    existing: {driver: weka, filesystem: datasets, path: /imagenet}
    size: 10Ti            # informational for static volumes
    readOnly: true
    mountPath: /datasets/imagenet
```

becomes a PV with `volumeHandle: dir/v1/datasets/imagenet` and the API
Secret as publish/stage secret, bound to a PVC `imagenet` in each project's
namespace. The handle format is csi-wekafs's; check it against the driver
version you bundle (`helm show readme` of the chart).

### 2.4 GPUDirect Storage

GDS needs the native Weka client with GDS enabled and the NVIDIA GDS
packages in the node image; it is a node-image matter, not a CSI setting.
Workloads read with `cuFile` from the mounted path as usual.

## 3. CephFS

### 3.1 Prerequisites (site side)

- **Kernel client** on every GPU node: `ceph.ko` is part of the EL9 kernel.
  Warewulf nodes load it with tag `csi_cephfs=yes` (`csi-storage` overlay).
- **Network**: nodes → MONs (`3300`/`6789`), OSDs and MDS.
- **A subvolume group** for dynamic volumes:
  `ceph fs subvolumegroup create cephfs csi`
- **A client key** for the CSI driver, capabilities as in the ceph-csi
  capabilities document, for example:

  ```sh
  ceph auth get-or-create client.k8s-cephfs \
    mon 'allow r' mgr 'allow rw' mds 'allow rw fsname=cephfs' \
    osd 'allow rw tag cephfs metadata=cephfs, allow rw tag cephfs data=cephfs'
  ceph auth print-key client.k8s-cephfs > ~/.secrets/ceph-k8s-cephfs.key   # chmod 600
  ```

- **Cluster identity**: `ceph fsid` → `CEPH_CLUSTER_ID`,
  `ceph mon dump` → `CEPH_MONITORS`.

### 3.2 Settings and install

```sh
# .env
CEPHFS_CSI=yes
CEPH_CSI_VERSION=
CEPH_CLUSTER_ID=5b7c6c8e-...           # ceph fsid
CEPH_MONITORS=10.0.0.1:6789,10.0.0.2:6789,10.0.0.3:6789
CEPH_FS_NAME=cephfs
CEPH_ADMIN_ID=k8s-cephfs               # without the "client." prefix
CEPH_ADMIN_KEY_FILE=~/.secrets/ceph-k8s-cephfs.key
# CEPH_USER_ID / CEPH_USER_KEY_FILE: separate, narrower key for static volumes (default: the same)
CEPHFS_SUBVOLUMEGROUP=csi
CEPHFS_STORAGECLASS=cephfs-projects
CEPHFS_RECLAIM_POLICY=Retain
```

```sh
make features          # fetch side
make push storage      # deploy side
```

| Object | Content |
|---|---|
| Secret `ceph-csi-cephfs/csi-cephfs-secret` | `adminID`/`adminKey` (provisioning), `userID`/`userKey` (static volumes) |
| Helm release `ceph-csi-cephfs` | `local/features/cephfs/values.yaml` + generated `csiConfig` (fsid, monitors, subvolume group) |
| StorageClass `cephfs-projects` | `local/features/cephfs/storageclass.yaml`: `clusterID`, `fsName`, `mounter: kernel`, the Secret |

Each dynamic PVC becomes a CephFS **subvolume** under
`/volumes/csi/csi-vol-<uuid>` with a quota of its requested size.

### 3.3 Existing CephFS paths

```yaml
  - name: group-share
    project: cosmology
    existing: {driver: cephfs, path: /volumes/groups/cosmology}
    size: 5Ti
    mountPath: /group
```

becomes a PV with `staticVolume: "true"`, `rootPath`, `clusterID`, `fsName`
and the Secret as node-stage secret. The `userID` key needs `mds 'allow rw
path=/volumes/groups'` (or read-only) for that path.

## 4. Project volumes (`project-volumes.yaml`)

`PROJECT_VOLUMES` (default `local/storage/project-volumes.yaml`) is
declarative and idempotent; `make project-volumes` applies it:

```yaml
volumes:
  - name: work                   # data source name users see; also the PVC name
    project: theory              # or projects: [a, b] - one PVC per project
    storageClass: weka-projects  # new volume ...
    size: 2Ti
    accessMode: ReadWriteMany    # default
    mountPath: /work
  - name: imagenet
    projects: [theory, vision]
    existing: {driver: weka, filesystem: datasets, path: /imagenet}   # ... or existing data
    readOnly: true
    mountPath: /datasets/imagenet
```

Per volume and project the step:

1. finds the project's namespace (Run:ai project status, else the namespace
   labelled `runai/queue=<project>`);
2. applies the PVC (and, for `existing`, the static PV `<name>-<namespace>`);
3. creates a Run:ai **PVC data source** with `scope: project`,
   `existingPvc: true`, `claimName`, `path: mountPath` — once; later runs
   report `have`.

Projects must already exist (`runai/41-accounts.sh` from `org/cluster.yaml`,
or the UI). A volume listed for a missing project is reported and skipped.
Resizing: raise `size` and re-run (`allowVolumeExpansion: true` on both classes).

## 5. Using the volumes in workloads

**UI** — *New workload ▸ Data sources*: project volumes appear under their
names for members of the project; `mountPath` is preset.

**CLI** (`runai` 2.x syntax):

```sh
runai workspace submit nb -p theory -i <registry>/workloads/jupyter-scipy:2026-10-28 \
  --existing-pvc claimname=work,path=/work
# one-off volume for this workload only, from a storage class:
runai training submit ckpt -p theory -i ... \
  --new-pvc claimname=ckpt,storageclass=weka-projects,size=200Gi,path=/ckpt,accessmode-rwm
```

**YAML** (Kubernetes-native submission, `cli-howto.md` §7):

```yaml
          volumeMounts:
            - {name: work, mountPath: /work}
            - {name: imagenet, mountPath: /datasets/imagenet, readOnly: true}
      volumes:
        - name: work
          persistentVolumeClaim: {claimName: work}
        - name: imagenet
          persistentVolumeClaim: {claimName: imagenet, readOnly: true}
```

`runai pvc list` (or `kubectl get pvc` in the project namespace) shows what
the project can mount. Per-workload scratch on Weka/CephFS without a data
source: an `ephemeral` volume with `storageClassName: weka-projects`
(`cli-howto.md` §7 shows the pattern).

## 6. Permissions, quotas, lifecycle

- **Run as the user.** Environments with `uidGidSource: fromIdpToken` (the
  OS images in `catalog/environments.yaml`) run with the user's UID/GID from
  the identity provider, so files on Weka/CephFS carry real owners and the
  file system enforces access. Root-in-container on a shared volume is the
  thing to avoid.
- **Group-owned project directories.** New Weka volumes get mode
  `WEKA_VOLUME_PERMISSIONS` (default `0775`); set the group once per volume
  (`chgrp <project gid>` + `chmod g+s` from an admin pod or a Weka/Ceph
  client) so members share files. For existing paths, set ownership on the
  file system as for any HPC share.
- **Quotas.** Weka `dir/v1` volumes get a hard directory quota of the PVC
  size (`capacityEnforcement: HARD`); CephFS subvolumes get
  `ceph.quota.max_bytes`. Run:ai's GPU quotas are separate; storage quota
  per project = the sum of its PVC sizes.
- **Reclaim policy `Retain`** (both classes by default): deleting a PVC, a
  data source or a whole project keeps the data; the PV goes `Released`.
  Clean up deliberately (`kubectl delete pv`, then the directory/subvolume).
- **Read-only shares**: `readOnly: true` makes the data source, the PVC
  mount and (static volumes) the CSI volume read-only.

## 7. Warewulf nodes

The `csi-storage` overlay (installed by `make ww-overlays`) renders only
what the tags ask for:

| Tag (profile or node) | File | Effect |
|---|---|---|
| `csi_cephfs=yes` | `/etc/modules-load.d/ceph-csi.conf` | loads `ceph.ko` at boot |
| `weka_hugepages=<2 MiB pages>` | `/etc/sysctl.d/91-weka-hugepages.conf` | `vm.nr_hugepages` for DPDK clients |
| `weka_reserved_cpus=<list>` | `/etc/rancher/rke2/config.yaml.d/60-csi-storage.yaml` | kubelet `--reserved-cpus` (Weka frontend cores) |
| `weka_reserved_memory=<qty>` | same file | kubelet `--system-reserved=memory=` |

```sh
wwctl profile set -y gpu --tagadd "csi_cephfs=yes,weka_hugepages=2048,weka_reserved_cpus=0-1,weka_reserved_memory=6Gi"
```

The Weka stateless-client mount itself (systemd unit ordered before
`rke2-agent`) belongs to the site image/overlay; see `deployment.md` §6.1.

## 8. Troubleshooting

| Symptom | Look at |
|---|---|
| PVC `Pending` | `kubectl describe pvc`; controller logs: `kubectl -n csi-wekafs logs deploy/csi-wekafs-controller --all-containers` / `kubectl -n ceph-csi-cephfs logs deploy/ceph-csi-cephfs-provisioner -c csi-cephfsplugin` |
| Pod `ContainerCreating`, `MountVolume` errors | node plugin logs on that node (DaemonSet pods), `dmesg` on the node (`ceph:` / `wekafs`) |
| Weka API `401`/TLS errors | Secret values (`endpoints` host:port list, `organization`), `WEKA_API_CA_FILE` |
| CephFS `permission denied` at mount | key capabilities (§3.1), `userID` for static paths |
| Data source not offered in the UI | project scope: `make project-volumes` output, Run:ai *Data sources* filtered by project |
| `self-test ... failed` in `make storage` | printed pod/PVC events; `STORAGE_SELFTEST=no` to skip while debugging |
