# RKE2 agents on Warewulf (air-gapped compute nodes)

Turns any Warewulf node into an RKE2 agent of the server running on `ww1`
by adding one profile. Compute nodes live on `10.10.172.0/24` with no
internet access; everything they need comes from `ww1`.

```
ww1 (192.168.65.2 external / 10.10.172.1 internal)
 ├─ rke2-server            node-ip/advertise 10.10.172.1
 ├─ rke2-registry          registry:2, https://10.10.172.1:5000 (TLS + htpasswd)
 └─ warewulfd              image rocky-9 (+ rke2-agent), overlay rke2, profile rke2
        │
        └── htdcn0N  ── boots, gets rke2 overlay ── rke2-agent joins, pulls via mirror
```

## Steps (run on ww1, from this directory)

| script | what it does |
|---|---|
| `scripts/01-server-config.sh` | Server `node-ip`/`advertise-address` → internal IP, `tls-san` for both IPs. **If the cluster already existed, follow with a `rke2 server --cluster-reset`** (etcd peer URL changes). |
| `scripts/02-registry.sh` | CA + cert, htpasswd user, quadlet `rke2-registry.service` on `10.10.172.1:5000`. Secrets in `/etc/rke2-registry/`. |
| `scripts/03-mirror-images.sh` | Mirrors the official image lists for the server's exact RKE2 version (`core`, `canal`) plus every image currently used by pods. Idempotent. `EXTRA_IMAGES="docker.io/foo/bar:1"` or `EXTRA_IMAGE_LISTS="rke2-images-multus"` to add more. |
| `scripts/04-image.sh` | Installs `rke2-agent` pinned to the server's version into the `rocky-9` image (left disabled there). |
| `scripts/05-overlay.sh` | Creates an agent-only bootstrap token (`/etc/rancher/rke2/ww-agent-token`) and installs the `rke2` overlay. |
| `scripts/06-profile.sh` | Creates profile `rke2`: image, `rke2` system overlay, `Root=tmpfs`, gateway `10.10.172.1`. `NODES="a b"` to assign nodes. |

Copy to ww1 with `tar` (scp would dereference the service symlink):

```sh
tar -cf - scripts overlay | ssh root@192.168.65.2 'mkdir -p rke2_deploy_ww && tar -xf - -C rke2_deploy_ww'
```

## Adding a node

```sh
wwctl node add htdcn05 --ipaddr 10.10.172.15 --hwaddr <mac> --profile default,rke2
wwctl overlay build -n htdcn05     # autobuild is on, but this is instant
# power on → node shows up in `kubectl get nodes`
```

Optional per-node labels (`;`-separated, because wwctl splits tags on commas):

```sh
wwctl node set htdcn05 --tagadd "rke2_node_labels=role=gpu;zone=a"
```

## Overlay `rke2` contents (all rendered per node)

| file | source |
|---|---|
| `/etc/rancher/rke2/config.yaml` | `server` = Warewulf IP, `token` = `Include /etc/rancher/rke2/ww-agent-token`, `node-name` = node id, `node-ip` = primary (or first) netdev IP |
| `/etc/rancher/rke2/registries.yaml` | `docker.io` and `*` mirrored to `https://<ww ip>:5000`, credentials from `/etc/rke2-registry/` |
| `/etc/rancher/rke2/registry-ca.crt` | `/etc/rke2-registry/ca.crt` |
| `/etc/rancher/node/password` | `sha256(node id + seed)` so stateless reboots are not rejected by the server |
| `/etc/NetworkManager/conf.d/rke2-canal.conf` | NM ignores `cali*`/`flannel*` |
| `multi-user.target.wants/rke2-agent.service` | enables the agent only on nodes with this overlay |

Secrets are read from ww1 at overlay build time, never stored in this repo.
Rotating them = change the file on ww1 and `wwctl overlay build`.

## Why the non-obvious bits

- **`Root=tmpfs`** – with the default initramfs root, runc cannot `pivot_root`
  and every container fails to start.
- **Gateway `10.10.172.1`** – kubelet/flannel need a default route and
  ClusterIP traffic (`10.43.0.0/16`) needs *some* route. ww1 does not NAT this
  subnet, so nodes remain offline.
- **Bootstrap token, not the server token** – the overlay is served over plain
  HTTP on the provisioning network; a `rke2 token create` token can only join
  agents, not servers. Revoke with `rke2 token delete <id>`.

## NVIDIA Run:ai

The Run:ai layer (control plane, cluster, simulated or real GPUs, local
disks on the nodes) builds on this one: see [`runai/README.md`](runai/README.md).
Users: [`cli-howto.md`](cli-howto.md) explains writing and submitting
workload YAML from the command line (GPUs, CPUs, home, projects, networking).

## Local deployment kit

`make` + `.env` on a workstation: copy the whole stack (every image,
chart, the Run:ai lock, RKE2 RPMs, these overlays) from ww1 into a local,
verifiable artifact repository, optionally as one signed/encrypted bundle,
and deploy it into an existing RKE2 GPU cluster, with Weka/CephFS CSI
project volumes as an option. Schedulable from `.env`. See
[`local/README.md`](local/README.md) and [`local/STORAGE.md`](local/STORAGE.md).

```sh
make env && $EDITOR .env
make fetch            # ww1 -> RUNAI_REPO
make deploy           # RUNAI_REPO -> KUBECONFIG's cluster
```

## Upgrading RKE2

Upgrade the server, then re-run `03-mirror-images.sh` and `04-image.sh`
(both pin to `rke2 --version`) and reboot the nodes.
