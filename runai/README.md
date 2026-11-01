# NVIDIA Run:ai on the RKE2/Warewulf cluster

Self-hosted NVIDIA Run:ai (control plane + cluster) on top of the RKE2 layer
in `../scripts`. Everything is installed from the local registry on ww1, and
everything node-side lives in the `runai` Warewulf overlay and profile.

```
                 https://runai.htd.local          (UI, REST API, Keycloak /auth, CLI)
                 https://<project>-<workload>.runai.htd.local   (tools: RStudio, ...)
client ── 192.168.65.2:443/80 ──┐   DNS for both: runai-dns on 192.168.65.2:53
                                ▼
ww1 ┬─ rke2-traefik (hostPort 80/443) ──▶ runai-backend-traefik ──▶ control plane
    ├─ rke2-registry    :5000  read/write ── charts/ (OCI) + every image, digest-pinned
    ├─ rke2-registry-ro :5001  pull-only "workload registry" (same storage) ── workloads/*
    ├─ NFS /var/lib/runai-nfs ──▶ StorageClass runai-nfs (default)
    └─ chronyd (time for the offline nodes)
htdcn0N  (profile default,rke2,runai)
    ├─ /dev/vda1 → /var/lib/rancher, /dev/vda2 → /var/lib/kubelet
    ├─ label run.ai/simulated-gpu-node-pool=<partition> → 2× simulated GPUs
    │  of the partition's type (40-partitions.sh: a100, h100)
    └─ runai-cluster components, workloads
```

## Steps (run on ww1, from the repo root, after `scripts/01..06`)

| step | what it does |
|---|---|
| `runai/09-time.sh` | ww1 serves NTP to the internal network (Run:ai requires synced clocks; nodes are offline). chrony into the image. |
| `runai/10-helm.sh` | Pinned helm, logged in to the local registry. |
| `runai/11-mirror.sh` | Charts → `oci://10.10.172.1:5000/charts`; Run:ai images by digest from NVIDIA's ArtifactLock for `RUNAI_VERSION`/arch; add-on images found by rendering the add-on charts. Idempotent. |
| `runai/12-server-mirror.sh` | ww1's own containerd also pulls via the local registry; kubelet pull QPS raised. Restarts rke2-server. |
| `runai/13-storage.sh` | NFS export on ww1 (`/etc/exports.d`, Warewulf owns `/etc/exports`) + csi-driver-nfs, default StorageClass `runai-nfs`. Self-test from a compute node. |
| `runai/14-expose.sh` | TLS cert for `RUNAI_DOMAIN` + `*.RUNAI_DOMAIN` from the site CA, Traefik hostPorts 80/443 pinned on every node incl. ww1, CoreDNS rewrite of the domain to the ingress, `runai-dns.service` (domain + wildcard for clients), `runai-system` role on ww1. |
| `runai/15-overlay.sh` | Installs the `runai` overlay. |
| `runai/16-profile.sh` | Profile `runai`: local disk, `chrony,sfdisk,runai` overlays, fake-GPU tag. `NODES="a b"` assigns `default,rke2,runai`. **Reboot the nodes.** |
| `runai/18-workload-registry.sh` | Pull-only workload registry on `:5001` (account `runai-pull`); verifies read OK, push refused, anonymous refused. |
| `runai/20-prometheus.sh` | kube-prometheus-stack (Run:ai prerequisite). |
| `runai/21-gpu.sh` | `GPU_MODE=fake` fake-gpu-operator, `nvidia` GPU operator, `none`. |
| `runai/22-control-plane.sh` | Control plane (`runai-backend`). Admin password generated into `/etc/runai/admin-password`. |
| `runai/23-cluster.sh` | Registers the cluster through the API and installs `runai-cluster` (host-based tool URLs on: wildcard cert + Ingress). |
| `runai/24-workload-catalog.sh` | `catalog/environments.yaml` → images under `workloads/`, Run:ai Environments, registry Credentials and the `workload-registry` data source. Then **removes every environment whose image is not in the workload registry** (Run:ai's internet-only built-ins, or ones created in the UI pointing upstream) so the UI only offers what the offline nodes can run; `KEEP_UNUSABLE=1` only reports. |
| `runai/25-mirror-image.sh <image> [name:tag]` | Pull any image into the workload registry by hand (all architectures, digests kept); prints the image reference and a ready catalog entry. |
| `runai/26-build-image.sh [name...]` | Build catalog entries that have `build: images/<dir>` (a Dockerfile `FROM ${WL}/<catalog image>`) with podman on ww1, push them to `workloads/` and run `24-workload-catalog.sh` so they show up as Run:ai environments. Existing tags are kept (`FORCE=1` rebuilds). |
| `runai/htd-images.py [Dockerfile...]` | **Root-only TUI** on ww1 for the workload registry: browse/filter repositories and tags (platforms, size, labels, env, history), see which tags are Run:ai environments (`●`) or catalog-only (`○`), build a Dockerfile (writes its catalog entry, then `26-build-image.sh`), import an image (`25-mirror-image.sh`, or a catalog entry + `24-workload-catalog.sh`), sync, edit the catalog. Dockerfiles given as arguments open the build dialog. Scriptable: `ls`, `inspect`, `build`, `import`, `sync`. Guide: [`../htd-images-howto.md`](../htd-images-howto.md). |
| `runai/30-smoke-test.sh` | Project `smoke` + a 1-GPU and a 0.5-GPU training through the API; both must reach Running. `KEEP=1` leaves them. |
| `runai/31-verify-local.sh` | Every image used by any pod resolves in the local registry. ww1 has internet and containerd silently falls back upstream, so run this after installs; re-run `11-mirror.sh` if it reports gaps (its last pass also mirrors images of running pods, e.g. the Prometheus that Run:ai's operator starts). |
| `runai/32-catalog-test.sh` | As a user, via the API: every OS environment runs, a workload lists the workload registry through the data source, an RStudio workspace URL answers with the Run:ai SSO redirect. `KEEP=1` leaves them. |
| `runai/40-partitions.sh` | Partitions from `org/cluster.yaml` → Warewulf node tags + live node labels, one (simulated) GPU type and one Run:ai node pool per partition. |
| `runai/41-accounts.sh` | Accounts → Unix groups/users (homes on NFS `/home`) and Run:ai departments/projects with per-partition GPU quotas, login passwords (`users.csv`, root-only), group access rules, `home` data source. `RESET_PASSWORDS=1` renews all passwords. |
| `runai/42-org-test.sh` | One member per group logs in with their own password: sees only their project, submitting to another group's is refused, a training runs on a partition node as their UID/GID, writes to their home, cannot read another user's home. |
| `runai/45-quota-report.sh` | `sshare`-style report: per department/group and partition — guaranteed GPUs / limit / weight, allocated / requested — plus GPUs per user. `WATCH=10` refreshes every 10 s. |
| `runai/46-quota-demo.sh` | Six users submit GPU jobs as themselves to show enforcement: within quota, GPU fraction, over-quota on idle GPUs, limit-blocked (stays pending), and reclaim of an over-quota job. `KEEP=1` leaves the jobs running. |
| `runai/47-home-automount.sh` | Workload pods that **run as the submitting user** (`runAsUser` ≥ 5000, i.e. environments with `uidGidSource: fromIdpToken`) get the NFS `/home` mounted automatically (MutatingAdmissionPolicy on project namespaces; no data source needed). Image-user environments (Jupyter, code-server, RStudio, Kali) keep the image's own `/home` — mounting over it broke Jupyter (`mkdir /home/jovyan: permission denied`). Opt out per workload with annotation `home.htd.local/skip: "true"`. |
| `runai/48-user-access.sh` | Command-line access on the login node: `runai` CLI (served offline by the control plane) and `kubectl` in `/usr/local/bin`, first-login hook (CLI URL + skeleton `~/.kube/config`), kube-apiserver OIDC against Keycloak so `runai kubeconfig set` gives users `kubectl` in their project namespaces (Run:ai's own RoleBindings), example manifests in `/usr/local/share/runai/examples`. Restarts rke2-server once. User guide: [`../cli-howto.md`](../cli-howto.md). |

Copy to ww1 (no macOS xattrs):

```sh
COPYFILE_DISABLE=1 tar --no-xattrs -cf - scripts overlay runai | ssh root@192.168.65.2 'mkdir -p rke2_deploy_ww && tar -mxf - -C rke2_deploy_ww'
```

## Using the dashboard

Clients resolve the domain **and its subdomains** (one per tool session)
through ww1, and trust the site CA. On macOS, a per-domain resolver leaves
all other DNS untouched:

```sh
sudo mkdir -p /etc/resolver
echo "nameserver 192.168.65.2" | sudo tee /etc/resolver/runai.htd.local
scp root@192.168.65.2:/etc/runai/ca.crt .      # import into the OS/browser trust store
ssh root@192.168.65.2 cat /etc/runai/admin-password
open https://runai.htd.local                    # user admin@htd.local
```

Only 443 (and 80, redirected) is needed: UI, REST API, Keycloak, tool
sessions and the cluster→control-plane connection all share it.

## Workload catalog

`catalog/environments.yaml` is the list of images users can pick. Each entry
becomes a Run:ai **Environment** (tenant-wide) whose image lives in the
**workload registry** `10.10.172.1:5001/workloads/...`:

| environment | image | notes |
|---|---|---|
| `ubuntu` | `workloads/ubuntu:24.04` | `sleep infinity`, override command for trainings |
| `ubi9` | `workloads/ubi9:9.8` | |
| `rocky9` | `workloads/rocky:9.8` | |
| `alma9` | `workloads/alma:9.8` | |
| `rstudio` | `workloads/rstudio:4.6.2` | workspace only; tool opens at `https://<project>-<workload>.runai.htd.local` behind Run:ai SSO |

| `kali` | `workloads/kali-rolling:2026-10-31` | base image only (no tool metapackages; build a derived image for tools) |
| `jupyter-scipy`, `vscode`, `openwebui`, `huggingface-chat-ui` | `workloads/jupyter-scipy:2026-10-28`, `code-server:4.99.4`, `open-webui:v0.6.42`, `chat-ui-db:0.20` | Run:ai built-ins re-pointed with `keepSpec: true` (only the image changes) |

Run:ai's other built-ins (`llm-server`, `gpt2`, `tensorboard-tensorflow`,
`jupyter-tensorboard`) are removed by the catalog step: their images are
x86-only, need Knative (inference) or don't fit this lab registry. Note that
`docker.io/jupyter/*`, which the built-in `jupyter-scipy` referenced, is no
longer published (`quay.io/jupyter/*` is).

Add an image: append an entry (pin the tag), run `24-workload-catalog.sh`.
Build your own: add a Dockerfile under `runai/images/<dir>/` starting
`ARG WL` / `FROM ${WL}/ubuntu:24.04` (any catalog image), a catalog entry with
`build: images/<dir>`, then run `26-build-image.sh <name>` (example: `ubuntu-dev`).
Just copy an image into the local repo (no UI entry):
`runai/25-mirror-image.sh quay.io/jupyter/minimal-notebook:2026-10-28`.
After a Run:ai upgrade, re-run `24-workload-catalog.sh`: upgrades may re-seed
built-ins that point at the internet.

### Image TUI (`htd-images`)

Full admin guide: [`../htd-images-howto.md`](../htd-images-howto.md).

Root on ww1, from the repo copy (it reads the push/pull credentials in
`/etc/rke2-registry` and the Run:ai admin password, so it is not a user tool):

```sh
ln -sf ~/rke2_deploy_ww/runai/htd-images.py /usr/local/sbin/htd-images
htd-images                                        # browse
htd-images ~/rke2_deploy_ww/runai/images/mlflow/Dockerfile   # build dialog
htd-images build runai/images/mlflow/Dockerfile -y            # same, no TUI
htd-images import quay.io/jupyter/minimal-notebook:2026-10-28 --env minimal
```

A Dockerfile can carry its catalog entry in `#catalog` comment lines (YAML:
description, `uidGidSource`, `connections`, ...); name defaults to the
directory (or `foo.Dockerfile` → `foo`), tag to today's date. Builds and
imports **edit `catalog/environments.yaml` on ww1**: copy it back into git
(`scp root@192.168.65.2:rke2_deploy_ww/runai/catalog/environments.yaml runai/catalog/`)
before the next tar-over-ssh overwrites it. Every action's output is
appended to `/var/log/htd-images.log` (`L` in the TUI).

Example: `images/mlflow` – *HTD Researcher · MLflow*: MLflow tracking server
as a Run:ai tool (host-based URL), running as the submitting user with runs
in `~/mlflow`; branded shell (banner, prompt, `htd-info`, `htd-demo`,
`htd-help`) for login and Run:ai UI terminals.

**Querying the registry from a workload** – select data source
`workload-registry`; it mounts `url`, `username`, `password`, `ca.crt` at
`/etc/workload-registry`:

```sh
R=/etc/workload-registry; URL=$(cat $R/url); AUTH="$(cat $R/username):$(cat $R/password)"
curl --cacert $R/ca.crt -u "$AUTH" "$URL/v2/_catalog?n=1000"
curl --cacert $R/ca.crt -u "$AUTH" "$URL/v2/workloads/rstudio/tags/list"
skopeo list-tags --cert-dir $R --creds "$AUTH" "docker://${URL#https://}/workloads/rstudio"   # if the image has skopeo
```

The account is pull-only: the workload registry is a second registry process
over the same storage in read-only mode. Credential `workload-registry-pull`
(Docker registry type) is the pull secret Run:ai attaches to workloads.

Production mapping: workload registry → a Harbor/Quay/Artifactory project;
`runai-pull` → a pull-only robot account; `runai-dns` → a `*.runai` record
in your DNS. Run:ai assets stay the same.

## Org: partitions, accounts, quotas

`org/cluster.yaml` describes the site in Slurm terms — the header maps every
field (`PartitionName` → `partitions`, parent account → `departments`, leaf
account → `groups` = project + Unix group, `GrpTRES` → `gpus`, `MaxTRES` →
`limit`, `Fairshare` → `weight`, coordinator → `pi`).

- **Partitions** (`40-partitions.sh`) — node lists + one (simulated) GPU type
  each; become Run:ai node pools via the label `runai/node-pool=<name>`.
  `default_partitions` is the Slurm `Default=YES` equivalent: workloads that
  name no pool land there, keeping research pods off ww1 (pool `default`).
- **Accounts** (`41-accounts.sh`) — departments and projects with per-partition
  GPU quota: `gpus` = guaranteed (deserved), `limit` = ceiling including
  over-quota, `weight` = share of idle GPUs when over quota. Over-quota weights
  are off in Run:ai by default; the script enables
  `project.quota.manual_over_quota`. The same run creates the Unix side
  (groups, users, NFS homes wired into Warewulf's syncuser) and the Run:ai
  users with UID/GID token claims, so workloads run as the submitting user.
- **Quota semantics**, shown by `46-quota-demo.sh`: within quota = guaranteed;
  over quota = runs on idle GPUs but is preemptible; above `limit` = stays
  pending; a job within its guarantee reclaims GPUs from over-quota jobs.
  `45-quota-report.sh` is the monitoring view (the numbers are Run:ai's own
  accounting, same as the UI's Departments/Projects).
- **Home directories** (`47-home-automount.sh`) — every workload that runs
  as the submitting user mounts the NFS `/home` with no user action
  (HPC-style; permissions are enforced by the NFS server). Workloads running
  as an image user keep the image's `/home`. The `home` data source still
  works for explicit selection and wins over the default.

User passwords live in `/etc/runai/users.csv` on ww1 (root-only). Production:
users/groups come from LDAP/AD via SSO + SSSD; the Run:ai side (departments,
projects, quotas, group access rules) stays as generated here.

## Overlay `runai` (rendered per node)

| file | purpose |
|---|---|
| `/warewulf/wwinit.d/05-runai-disk-drivers.sh` | wwinit runs before udev: loads `virtio_blk nvme ahci sd_mod` (tag `runai_disk_modules`) so the stock `sfdisk` overlay can see the disk |
| `/warewulf/wwinit.d/20-runai-mkfs.sh` | formats the profile's file systems **once** (stock `mkfs` overlay in 4.7.1 never formats a blank disk without `--fswipe`, which then reformats every boot). Each file system is marked with its node id (`/.warewulf-node`); a disk marked for another node (cloned VM, moved disk) is reformatted, unmarked ones are adopted |
| `/etc/systemd/system/rke2-agent.service.d/10-runai-local-disk.conf` | agent requires the disk mounts; never fills the tmpfs root instead |
| `/etc/rancher/rke2/config.yaml.d/50-runai.yaml` | kubelet pull QPS, labels from tags `runai_fake_gpu_pool`, `runai_node_labels` (`;`-separated) |
| `/usr/bin/nvidia-container-runtime` | **fake-GPU nodes only** (tag `runai_fake_gpu_pool`): `exec runc`. Run:ai gives fractional-GPU pods `runtimeClassName: nvidia`; RKE2 only creates that containerd handler when it finds this binary. Not rendered on real GPU nodes. |
| `/etc/sysctl.d/90-runai.conf` | inotify limits |
| `/etc/chrony.d/`, `chronyd.service` enabled | time from ww1 (stock `chrony` overlay writes `chrony.conf`) |

wwinit output is kept in `/var/log/warewulf-runai-wwinit.log` on the node.

Disk layout (profile, override per node with `wwctl node set`):
`RUNAI_DISK` GPT, part `rke2` (`RUNAI_DISK_RKE2_MIB`) → `/var/lib/rancher`,
part `kubelet` (rest) → `/var/lib/kubelet`. The partition table is rewritten
each boot with the same layout, data is kept. Fresh start for one node
(e.g. a VM cloned before the node markers existed):

```sh
ssh <node> 'systemctl stop rke2-agent; rke2-killall.sh; umount -R /var/lib/kubelet /var/lib/rancher;
            wipefs -a /dev/disk/by-partlabel/rke2 /dev/disk/by-partlabel/kubelet; systemctl reboot'
```

## Why the non-obvious bits

- **Node SELinux must not be enforcing** – overlay files land as `default_t`
  and `wwclient` cannot execute (`Permission denied`). The `rocky-9` image
  runs permissive.
- **Time** – nodes have no internet; without `09-time.sh` they boot with
  clocks an hour off and OIDC tokens between cluster and control plane fail.
  ww1 must use `makestep 1.0 -1` (step whenever >1 s off), not EL's default
  `makestep 1.0 3`: after the host sleeps, the ww1 VM resumes hours behind
  and only slews. Keycloak (on ww1) then issues tokens that `cluster-api` (on
  a correct node) rejects as expired — symptom: **the UI terminal fails**
  (`token has invalid claims: token is expired` in `runai/cluster-api` logs)
  while the rest of the UI works.
- **UI terminal** – needs nothing extra on this layout: the control plane's
  gateway routes `/cluster-api` to `cluster-api.runai` (WebSocket exec, token
  in the subprotocol). The UI always runs **`/bin/bash`**, so images without
  bash (alpine, distroless) get no terminal. A shell running as a site UID
  shows `I have no name!` because the image's `/etc/passwd` lacks the user;
  harmless (`id` is correct; `cd /home/<user>`).
- **`ubuntu:latest` is mirrored** – not in NVIDIA's lock, but KAI (NvFractions
  mode) builds the GPU reservation pods of fractional workloads from a bare
  `ubuntu` image.
- **Fake GPUs and the `nvidia` RuntimeClass** – RKE2 ships RuntimeClass
  `nvidia`; fake-gpu-operator's own copy is disabled (ownership clash) and
  the overlay shim provides the handler instead.
- **CoreDNS rewrite** – compute nodes have no upstream DNS; pods reach
  `RUNAI_DOMAIN` via the in-cluster Traefik Service, clients via ww1.
- **`runai-dns`, never `dnsmasq.service`** – `/etc/dnsmasq.d` holds
  Warewulf's generated DHCP/TFTP config; starting the stock service runs a
  second DHCP server on the provisioning network. `runai-dns` runs dnsmasq
  with only `/etc/runai/dnsmasq.conf` (DNS, external IP, one domain).
- **Workload registry without `:Z`** – rke2-registry owns private SELinux
  labels on the storage; relabelling for a second container would lock it
  out. The read-only instance runs unlabelled with read-only mounts.

## Lab vs production

Values are split per component in `values/`:

| file | role |
|---|---|
| `<chart>.yaml` | production-shaped settings (ingress, TLS/CA, storage, secrets) |
| `<chart>-lab.yaml` | lab sizing only, picked up when `RUNAI_SIZING=lab` (default) |

Moving to production:

1. `RUNAI_SIZING=prod` (drops the `*-lab.yaml` files; control plane wants ~10 cores).
2. `GPU_MODE=nvidia`; bake the NVIDIA driver into the Warewulf image; review
   `values/gpu-operator.yaml`. Re-run `16-profile.sh` (drops the
   `runai_fake_gpu_pool` tag, and with it the fake runtime shim) and
   `helm -n gpu-operator uninstall fake-gpu-operator`.
3. `RUNAI_DOMAIN` → real DNS name; replace `/etc/runai/{fullchain.crt,tls.key,ca.crt}`
   with your PKI's and re-run `22-control-plane.sh`.
4. Storage: point `values/csi-driver-nfs.yaml` at a real NAS, or swap in your
   vendor's CSI driver and set `RUNAI_STORAGECLASS`.
5. Ingress: Traefik works; NVIDIA recommends HAProxy (`RUNAI_INGRESS_CLASS`,
   `values/*` ingress class).
6. `RUNAI_DISK` / `RUNAI_DISK_RKE2_MIB` for your nodes' local NVMe.

Air-gapped sites: run `11-mirror.sh` on a connected host against a transfer
registry, or use NVIDIA's `runai-installer airgap pack/load`; the lock file
in `/var/lib/runai-deploy/` is the same one that tool uses.

## Upgrading Run:ai

Bump `RUNAI_VERSION` in `env.sh`, re-run `11-mirror.sh` (new lock, new
digests), then `22-control-plane.sh` and `23-cluster.sh`.
