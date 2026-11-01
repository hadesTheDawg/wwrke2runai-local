# Local deployment kit: capture the stack, deploy it into an existing RKE2 GPU cluster

`make` + `.env` on any workstation (macOS or Linux). Two halves:

- **fetch** copies everything the lab runs from the remote system into a local
  artifact repository (`RUNAI_REPO`): every container image (byte-exact,
  all architectures), the Helm charts, the Run:ai ArtifactLock, RKE2 RPMs,
  the Warewulf overlays, and a snapshot of this repo. Optionally it packs
  them into one checksummed, signed or encrypted file.
- **deploy** installs that content into an **existing** RKE2 cluster with GPU
  nodes, storage, ingress and DNS: images into the site registry, then
  Prometheus (if missing), Run:ai control plane + cluster, the workload
  catalog, and optionally Weka/CephFS CSI with per-project volumes
  ([STORAGE.md](STORAGE.md)).

It does not set up infrastructure: no Warewulf server, node images,
profiles, networks, DNS, RKE2 servers or registries. Those exist at the
site; the kit points at them through `.env`.

```
 remote system (lab ww1)               this machine                             target site
 ───────────────────────               ────────────                             ───────────
 registry :5000 ──ssh tunnel──▶ make fetch ─▶ RUNAI_REPO/                 ┌─▶ TARGET_REGISTRY (images, same paths)
 /var/lib/runai-deploy ─rsync─▶               images/<repo>@<tag>/  ──push┘
 dnf (rancher repo) ────rsync─▶               charts/ runai/ rke2/      ──helm──▶ existing RKE2 GPU cluster (KUBECONFIG)
 kubectl (pod images) ────────▶               warewulf/overlays/        ──ssh───▶ site Warewulf server (overlays only)
                                              source/ state/ SHA256SUMS
                                     make bundle ─▶ runai-bundle-<ver>-<date>.tar[.sha256|.asc|.gpg] ─▶ make unbundle
```

## Quick start

```sh
make env               # .env from .env.example (0600); edit it
make doctor            # tools, ssh to the remote, cluster access
make fetch             # remote -> RUNAI_REPO           (~30 GB first time, minutes after)
make bundle            # optional: one file to carry across an air gap
# on the deploy host (same repo checkout, its own .env):
make unbundle BUNDLE=/media/usb/runai-bundle-3.0.20-20261031.tar
make deploy            # preflight, push, prometheus, gpu, storage, control-plane,
                       # cluster, catalog, project-volumes, verify-target
```

Point the kit at other locations without editing `.env`:

```sh
make fetch RKE2_DEPLOY_REPO=/srv/git/rke2_deploy_ww RUNAI_REPO=/data/runai-repo
```

| variable | meaning |
|---|---|
| `RKE2_DEPLOY_REPO` | this repo or your site fork: `overlay/`, `runai/values/`, `runai/catalog/`, `runai/lib/` are read from here |
| `RUNAI_REPO` | the local Run:ai/RKE2 artifact repository (layout below) |

Every setting is in [`../.env.example`](../.env.example), grouped as
*where things live*, *source*, *target*, *Run:ai*, *components*, *Weka*,
*CephFS*, *Warewulf*, *scheduling*. Precedence: command line / environment,
then `.env` (or `ENV_FILE=...`), then defaults. Relative paths are relative
to the repo root. Secrets are never values in `.env`, only paths to 0600 files.

## Targets

| target | step | does |
|---|---|---|
| `facts` | `01-facts.sh` | remote RKE2/Warewulf/Run:ai versions, the images every remote pod uses, read access to the remote registry (→ `secrets/`) |
| `artifacts` | `02-artifacts.sh` | Run:ai lock + add-on list, chart tarballs, RKE2 RPMs for `TARGET_ARCH` (downloaded on the remote, signatures checked there against Rancher's key) |
| `images` | `03-images.sh` | every repository/tag in the remote registry's catalog → `images/`; skips unchanged digests; then checks that every remote pod image is covered |
| `features` | `04-features.sh` | Weka/CephFS CSI charts + images (only when enabled) |
| `overlays` | `06-overlays.sh` | Warewulf overlays `rke2`, `runai`, `csi-storage` + source snapshot |
| `verify` | `05-verify.sh` | re-hash every blob/manifest, inventory digests, `SHA256SUMS` over everything else |
| `bundle` / `unbundle` | `07` / `08` | tar without `secrets/` + `.sha256`, optional GPG signature/encryption; unpack + full verify |
| `preflight` | `10-preflight.sh` | target checks: API, RKE2 nodes, allocatable GPUs, default StorageClass, IngressClass, Prometheus CRDs, registry login, certificate SANs/expiry, DNS |
| `push` | `11-push.sh` | `images/` → `TARGET_REGISTRY[/PREFIX]/<upstream path>`, digests preserved, unchanged skipped |
| `registries` | `12-registries.sh` | `registries.yaml` for nodes not provisioned by Warewulf (→ `secrets/registries.yaml`) |
| `prometheus` | `13-prometheus.sh` | kube-prometheus-stack, only if the Prometheus Operator CRDs are missing (`INSTALL_PROMETHEUS=auto`) |
| `gpu` | `14-gpu.sh` | `GPU_OPERATOR=skip` (default) / `install` / `fake` |
| `storage` | `15-storage.sh` | Weka / CephFS CSI driver, Secret, StorageClass, self-test |
| `control-plane` | `16-control-plane.sh` | Run:ai control plane from the bundled chart, TLS/CA/admin secrets from `.env` files |
| `cluster` | `17-cluster.sh` | registers the cluster via the API, installs `runai-cluster`, waits for *Connected* |
| `catalog` | `18-catalog.sh` | Run:ai environments from `runai/catalog/environments.yaml` → `TARGET_WORKLOAD_REGISTRY/workloads/...`, pull credential, `workload-registry` data source, prune unusable environments |
| `project-volumes` | `19-project-volumes.sh` | Weka/CephFS/any-class PVCs + project-scoped Run:ai data sources ([STORAGE.md](STORAGE.md) §4) |
| `verify-target` | `20-verify.sh` | every pod image of the target resolves in `TARGET_REGISTRY`; Run:ai cluster state |
| `ww-overlays` | `30-ww-overlays.sh` | installs the bundled overlays on the site's Warewulf server `WW_HOST` (only the overlays) |
| `fetch` / `deploy` / `all` | `run.sh` | the step lists `FETCH_STEPS` / `DEPLOY_STEPS` from `.env` |
| `sync`, `schedule`, `unschedule`, `schedule-show` | `40` / `41` | unattended runs (below) |

Every step is idempotent; re-run any of them alone.

## Scheduling

`.env` decides what runs and when:

```sh
FETCH_STEPS="facts artifacts images features overlays verify"
DEPLOY_STEPS="preflight push prometheus gpu storage control-plane cluster catalog project-volumes verify-target"
SYNC_SCHEDULE="30 2 * * *"         # cron expression
SYNC_TARGETS="fetch bundle"        # make targets the schedule runs
```

`make schedule` adds one crontab line for this checkout (tagged with its
path; other entries are kept), `make schedule-show` prints it,
`make unschedule` removes it. Each run takes a lock (no overlap), appends to
`RUNAI_REPO/state/sync.log` and exits non-zero on failure. A nightly
`fetch bundle` keeps a current, verified copy of the lab; `fetch push`
also keeps a staging registry in step, and `SYNC_TARGETS=all` redeploys.
Fetches are incremental (unchanged image digests are skipped: ~20 s for a
no-change run against the lab).

## The local repository (`RUNAI_REPO`)

```
images/<repo>@<tag>/       one skopeo dir: copy per image: manifest.json (the
                           registry's bytes, so its sha256 is the image digest),
                           per-platform manifests, layers
images/.blobs/<sha256>     every layer once; the image dirs hardlink to it
charts/*.tgz               control-plane, runai-cluster, kube-prometheus-stack,
                           gpu-operator, fake-gpu-operator, csi-driver-nfs, [csi-wekafsplugin, ceph-csi-cephfs]
runai/                     runai-<ver>-standard-linux-<arch>.yaml (ArtifactLock), addon-images.txt
rke2/                      rke2-{common,agent,server,selinux} RPMs for TARGET_ARCH + rpm -K output
warewulf/overlays/         rke2, runai, csi-storage
source/                    snapshot of RKE2_DEPLOY_REPO (+ REVISION)
state/                     remote facts, pod images, images.tsv (ref -> digest), coverage, sync.log
SHA256SUMS                 everything except images/ (which is content-addressed)
secrets/          (0700)   remote registry account, generated admin password,
                           auth files, registries.yaml - never bundled
```

Why `dir:` and not an OCI layout: an OCI layout cannot store Docker-format
manifest lists without converting them, which changes their digests. 22 of
the lab's images (Prometheus, Bitnami, sig-storage, UBI, ...) are in that
format. `dir:` keeps every manifest byte-exact; the hardlinked blob pool
keeps the store at registry size (lab: 129 images, 2,737 blobs, 24 GB).

## Protecting the copy

- **Integrity**: `make verify` re-hashes every layer and manifest (each is
  named by its sha256), checks every image's digest against
  `state/images.tsv`, and checks `SHA256SUMS` for the rest. `unbundle`
  checks the bundle's `.sha256` (and `.asc`) before unpacking, then runs the
  same verification.
- **Authenticity / confidentiality**: `BUNDLE_GPG_KEY` signs the bundle,
  `BUNDLE_GPG_RECIPIENT` encrypts it (the plain tar is removed).
- **Credentials**: kept in `RUNAI_REPO/secrets/` (0700, files 0600), excluded
  from bundles. Registry passwords reach skopeo and Python through auth
  files, Kubernetes secrets come from `--from-file`, the Run:ai bootstrap
  token goes through a 0600 values file: none of them appear on a command
  line (`ps`).
- **The tunnel**: the lab registry's certificate names the remote's IPs, so
  over the SSH tunnel (`127.0.0.1:15000`) TLS verification is off for that
  hop; SSH authenticates the host and encrypts the traffic, and every image
  is then verified by digest. `REMOTE_TUNNEL=no` talks to `REMOTE_REGISTRY`
  directly with the remote CA verified.
- **Upstream provenance**: Run:ai images were pinned by digest from NVIDIA's
  ArtifactLock when the remote mirrored them (`runai/11-mirror.sh`); digests
  are preserved end to end, so `runai/<lock>.yaml` still verifies them.

## What the target must already have

| | checked by `preflight` |
|---|---|
| RKE2 cluster reachable with `KUBECONFIG` (cluster-admin) | API, node kubelet versions |
| GPU nodes advertising `nvidia.com/gpu` (or `GPU_OPERATOR=install`) | allocatable GPUs |
| A default StorageClass (control-plane PostgreSQL, Thanos, NATS) | annotation |
| An IngressClass (`RUNAI_INGRESS_CLASS`) and DNS for `RUNAI_DOMAIN` (+ `*.RUNAI_DOMAIN`) | IngressClass, DNS lookup |
| A certificate for the domain (+ wildcard) and its CA | SANs, > 30 days validity |
| A registry the nodes pull from, nodes mirroring through it | login (`/v2/`) |
| `node-role.kubernetes.io/runai-system=true` on the nodes for Run:ai services (recommended) | noted if absent |

**Node pulls**: images keep their upstream paths in `TARGET_REGISTRY`, so
the charts need no image overrides as long as the nodes' `registries.yaml`
mirrors `"*"` and `docker.io` to it. Warewulf nodes get that from the
`rke2`/`runai` overlays (tags below); other nodes: `make registries` and
copy `secrets/registries.yaml` to `/etc/rancher/rke2/registries.yaml`,
then restart `rke2-agent`/`rke2-server`. `TARGET_REGISTRY_PREFIX=runai`
(a Harbor project, say) pushes to `<registry>/runai/<path>` and adds the
matching containerd `rewrite`.

**Architecture**: images carry every platform the remote mirrored (the lab
mirrors with `--multi-arch all`): all 129 lab images include amd64, so an
arm64 lab feeds amd64 GPU nodes.
The ArtifactLock is the remote's (`linux-arm64` for the lab); Run:ai locks
pin multi-arch index digests, so the same images serve amd64 GPU nodes.
`TARGET_ARCH` selects the RPM architecture.

## Warewulf overlays

`make ww-overlays WW_HOST=root@warewulf.example.com` copies `rke2`, `runai`
and `csi-storage` into the site's overlay directory (same permissions as
`scripts/05-overlay.sh` / `runai/15-overlay.sh`). With
`WW_INSTALL_SECRETS=yes` it also writes the files the overlays read at
build time from `.env` (`/etc/rke2-registry/*`, the agent join token from
`RKE2_AGENT_TOKEN_FILE`). It then prints the profile tags; it does not
change profiles, images or nodes:

| tag | overlay | default (lab behaviour) |
|---|---|---|
| `rke2_server` | rke2 `config.yaml` | `https://<Warewulf IP>:9345` |
| `rke2_registry` | rke2/runai `registries.yaml` | `<Warewulf IP>:5000` |
| `rke2_registry_prefix` | rke2/runai `registries.yaml` | none (containerd `rewrite` when set) |
| `rke2_workload_registry` | runai `registries.yaml` | `<Warewulf IP>:5001`; equal to `rke2_registry` → no separate entry |
| `csi_cephfs`, `weka_hugepages`, `weka_reserved_cpus`, `weka_reserved_memory` | csi-storage | not rendered ([STORAGE.md](STORAGE.md) §7) |

Without tags the overlays render byte-identically to before (checked for
`config.yaml` and both `registries.yaml`), so the lab is unaffected.

## Tested

Against the lab (ww1, Run:ai 3.0.20, RKE2 v1.36.5) from macOS (bash 3.2,
BSD tools, Homebrew skopeo 1.24):

- `make fetch`: 129 images, 0 of the 87 remote pod images missing, 2,737
  blobs/manifests verified, 24 GB, 2 min 19 s; re-run: 0 copied, 20 s.
- `make bundle` / `make unbundle` into a second repository: checksum and
  full re-verification pass, no `secrets/` in the tar.
- `preflight`, `push`, `registries`, `verify-target` and the Run:ai API
  client against the lab cluster itself as a stand-in target (push: 129
  unchanged; 87 in-use images served; cluster *Connected*).
- `features` with both drivers: csi-wekafsplugin 2.9.7, ceph-csi-cephfs
  3.18.1, 11 images; the values keys exist in those charts.

Not exercised (no separate GPU cluster, Weka or Ceph available): the
installing steps `control-plane`, `cluster`, `catalog`, `storage`,
`project-volumes` and `ww-overlays` against a real target. They follow
`runai/22`–`24` and `47`, which run on the lab.

## Troubleshooting

| symptom | cause / fix |
|---|---|
| `images` reports `MISSING ...` in coverage | the remote runs an image its registry does not hold (ww1 fell back to the internet). On the remote: `EXTRA_IMAGES=<image> scripts/03-mirror-images.sh`, then `make images` |
| `the tunnel needs a native skopeo` | `brew install skopeo` (the podman fallback cannot reach the Mac's `127.0.0.1`), or `REMOTE_TUNNEL=no` |
| `verify` lists files not covered by `SHA256SUMS` | content changed outside a fetch; inspect, then `make verify VERIFY_WRITE=yes` |
| `verify-target` `MISSING` | a target node pulls past the mirror: check its `registries.yaml`, re-run `push` |
| Run:ai API errors on a fresh domain | `RUNAI_RESOLVE_IP` until DNS exists; `RUNAI_CA_CERT` must sign the ingress certificate |
| cron runs fail on macOS | Full Disk Access for `cron` if `RUNAI_REPO` is under Documents/Desktop; see `state/sync.log` |
