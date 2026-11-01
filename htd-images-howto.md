# htd-images: managing workload images and Run:ai environments

A how-to for **administrators** of the lab cluster. `htd-images` is a
terminal UI (plus a small command-line mode) on the Warewulf management node
for the images researchers can run: browse and inspect what is in the
workload registry, build images from Dockerfiles, import images from the
internet, and offer them in Run:ai as environments.

It is **root-only** and runs **only on ww1**: it reads the registry's push and
pull credentials and the Run:ai admin password. Researchers never use it.
They pick the resulting environments in the Run:ai UI or CLI
([`cli-howto.md`](cli-howto.md)).

**Site values used below:**

| What | Value here |
|---|---|
| Management node | `ww1`: `ssh root@192.168.65.2` |
| Repo copy on ww1 | `/root/rke2_deploy_ww` (pushed with tar-over-ssh, see [`runai/README.md`](runai/README.md)) |
| Tool | `/usr/local/sbin/htd-images` → `/root/rke2_deploy_ww/runai/htd-images.py` |
| Workload registry (pull-only, what Run:ai uses) | `10.10.172.1:5001/workloads/<name>:<tag>` |
| Read-write registry (pushes) | `10.10.172.1:5000`, same storage |
| Catalog | `/root/rke2_deploy_ww/runai/catalog/environments.yaml` |
| Log of every action | `/var/log/htd-images.log` |
| Run:ai UI | `https://runai.htd.local` |

---

## Contents

1. [How it fits together](#1-how-it-fits-together)
2. [One-time setup](#2-one-time-setup)
3. [Starting the TUI](#3-starting-the-tui)
4. [The screen](#4-the-screen)
5. [Keys](#5-keys)
6. [Browsing, searching and inspecting](#6-browsing-searching-and-inspecting)
7. [Building an image from a Dockerfile](#7-building-an-image-from-a-dockerfile)
8. [Importing an image](#8-importing-an-image)
9. [Syncing Run:ai and editing the catalog](#9-syncing-runai-and-editing-the-catalog)
10. [Command-line mode](#10-command-line-mode)
11. [Walkthrough: the HTD Researcher MLflow image](#11-walkthrough-the-htd-researcher-mlflow-image)
12. [Keeping git in step](#12-keeping-git-in-step)
13. [Removing an image or environment](#13-removing-an-image-or-environment)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. How it fits together

```
          htd-images (root on ww1)
   read ──────────┘   └────────── write: only through the existing steps
     │                              │
     ▼                              ├─ build  → catalog entry (build:)  → runai/26-build-image.sh
 :5001 workload registry            ├─ import → runai/25-mirror-image.sh               (registry only)
 (pull-only, /v2 API)               │         → catalog entry (source:) → runai/24-workload-catalog.sh
 Run:ai API (environments)          └─ sync   → runai/24-workload-catalog.sh
```

- **Reading** uses the pull-only registry on `:5001` (the same storage as
  `:5000`) and the Run:ai API, to show which tags are offered as
  environments.
- **Writing** never goes around the deployment scripts. Every change is
  either a catalog entry followed by a numbered step, or a direct step call.
  So `htd-images` and running the steps by hand always agree.
- **The catalog decides what Run:ai offers.** One entry in
  `catalog/environments.yaml` = one Run:ai environment (tenant-wide, every
  project sees it). `24-workload-catalog.sh` applies the catalog. It also
  deletes environments whose image is **not** in the workload registry: the
  nodes are offline, so those could never start.

## 2. One-time setup

As root on ww1, after the repo has been pushed there:

```sh
ln -sf ~/rke2_deploy_ww/runai/htd-images.py /usr/local/sbin/htd-images
htd-images ls | head        # quick check: registry and Run:ai reachable
```

What it needs (all present once the `runai/` steps up to `24` have run):

- the workload registry (`18-workload-registry.sh`): pull account in
  `/etc/rke2-registry/pull-*`, CA in `/etc/rke2-registry/ca.crt`;
- the Run:ai control plane (`22-control-plane.sh`), admin password in
  `/etc/runai/admin-password`. Without it the TUI still browses, just
  without environment marks;
- `podman` and `skopeo` on ww1 (builds and copies), and internet on ww1
  (`RUN apt-get`/`pip` in builds; imports from upstream).

Python 3.9 + PyYAML from Rocky 9 are enough; nothing to install.

## 3. Starting the TUI

```sh
htd-images                                   # browse
htd-images path/to/Dockerfile                # open the build dialog for it first
htd-images a/Dockerfile b/Dockerfile         # one build dialog after the other
```

Use a terminal of at least **70 × 12** with 256 colours (any modern
terminal over ssh is fine). Settings come from `runai/env.sh`, the same as
the steps, so environment overrides (`WL_REG_PREFIX=…`) apply here too.

## 4. The screen

```
 ▲ HTD Researcher · image registry   10.10.172.1:5001/workloads        Run:ai ● 12 environments
┌ Repositories 11 ─────────┐┌ Tags 1 ─────────┐┌ Details ─────────────────────────────────────┐
│● alma                    ││● 4.6.2          ││10.10.172.1:5001/workloads/rstudio:4.6.2      │
│● chat-ui-db              ││                 ││sha256:d80f68cb07d3…                          │
│● code-server             ││                 ││                                              │
│○ mlflow                  ││                 ││Run:ai   ● environment rstudio                │
│● rstudio                 ││                 ││catalog  rstudio: source docker.io/rocker/…   │
│  minimal-notebook        ││                 ││platforms linux/amd64, linux/arm64 (showing…) │
│                          ││                 ││size      1006.6 MB compressed, 19 layers     │
└──────────────────────────┘└─────────────────┘└──────────────────────────────────────────────┘
 status / messages
 / filter  b build  i import  s sync Run:ai  y copy ref  e catalog  a all  r refresh  ? help  q quit
```

| Part | Shows |
|---|---|
| Header | registry and prefix being browsed; Run:ai status (`●` + number of environments, or `✖` + error) |
| **Repositories** | repositories under `workloads/` (press `a` for all, including the cluster's own mirrored images and `charts/`) |
| **Tags** | tags of the selected repository: `latest` first, then newest-looking |
| **Details** | everything about the selected tag (section 6) |
| Status line | results, errors, prompts |
| Key bar | the most-used keys |

**Marks** (repositories and tags):

| Mark | Meaning |
|---|---|
| `●` green | offered in Run:ai: an environment points at this image |
| `○` yellow | in the catalog, but no environment yet: press `s` to sync |
| (none) | only in the registry: usable as an image reference in a manifest, not offered in the UI |

The focused pane has an orange border.

## 5. Keys

| Key | Action |
|---|---|
| `↑` `↓` / `j` `k` | move in the focused list; scroll the details when the details pane is focused |
| `Tab` `→` `l` `Enter` | next pane |
| `Shift-Tab` `←` `h` | previous pane |
| `PgUp` `PgDn` | scroll the details |
| `/` | filter repositories (empty filter = show all again) |
| `a` | toggle: `workloads/` only ↔ every repository |
| `b` | build a Dockerfile |
| `i` | import an image |
| `s` | sync the catalog to the registry and Run:ai |
| `e` | edit the catalog in `$EDITOR` (default `vi`) |
| `y` | copy the selected image reference to your clipboard |
| `r` | reload registry, catalog and Run:ai |
| `L` | show the action log |
| `?` | help |
| `q` / `Esc` | quit (in a dialog: cancel) |

In text prompts: `Backspace`, `Ctrl-U` (clear the line), `Tab` (complete
file names in the Dockerfile prompt), `Enter` (accept), `Esc` (cancel).

## 6. Browsing, searching and inspecting

**Filter** (`/`): matches anywhere in the repository name, the catalog name
or a Run:ai environment name, case-insensitive. `/jupyter` finds
`jupyter-scipy`; `/vscode` finds `code-server` (its environment name).

**Details** of a tag, top to bottom:

| Field | Meaning |
|---|---|
| reference + digest | what to put in a workload (`y` copies the reference) |
| Run:ai | environment(s) using exactly this tag, or what to do to offer it |
| catalog | the catalog entry and where the image comes from (`source` upstream, or `build` directory) |
| platforms | architectures in the image; details are for ww1's architecture (`arm64` in the lab, same as the nodes). An image without `linux/arm64` cannot run here. |
| size, layers | compressed size of that architecture |
| created, user, workdir, entry, cmd, ports | image configuration. `user` matters: environments with `uidGidSource: fromIdpToken` override it with the researcher's UID |
| labels, env, history | OCI labels, default environment variables, and the build steps (`RUN …`) |

**Copy a reference** (`y`): uses the terminal's OSC 52 clipboard, which works
over ssh in iTerm2, WezTerm, kitty, Windows Terminal, recent GNOME Terminal
and tmux with `set -g set-clipboard on`. If it doesn't, the reference is
also shown on the status line.

## 7. Building an image from a Dockerfile

### 7.1 Writing the Dockerfile

Builds run with podman **on ww1**, and may only start `FROM` images that are
already in the workload registry. The build passes the registry prefix as
argument `WL`:

```dockerfile
ARG WL
FROM ${WL}/ubuntu:24.04            # any catalog image: ubuntu, rocky, alma, ubi9, jupyter-scipy, ...

RUN apt-get update && apt-get install -y --no-install-recommends htop && rm -rf /var/lib/apt/lists/*
```

- `RUN` steps have internet (they run on ww1), so `apt-get`, `dnf`, `pip` and
  `curl` work. The nodes don't have internet, so put everything the workload
  needs into the image.
- The build context is the Dockerfile's directory: `COPY rootfs/ /` copies
  `<dir>/rootfs/` into the image.
- A base from anywhere else (`FROM python:3.12`) is flagged in the build plan
  and fails: the build only has credentials for the workload registry.
  Import the base first (section 8).
- The image is built for ww1's architecture only (arm64 here, same as the
  nodes).

Put Dockerfiles under `runai/images/<name>/Dockerfile` to keep them in git.
Any path on ww1 works, though (e.g. `/root/scratch/foo.Dockerfile`); the
catalog then stores the absolute path.

### 7.2 Catalog settings inside the Dockerfile (`#catalog`)

Lines starting with `#catalog` are joined into one YAML mapping and merged
into the image's catalog entry, so the Dockerfile carries its own Run:ai
settings:

```dockerfile
#catalog description: Ubuntu + htop for quick debugging
#catalog uidGidSource: fromIdpToken
#catalog command: sleep
#catalog args: infinity
```

| Key | Effect in Run:ai | Default |
|---|---|---|
| `name` | environment and image name | directory name (`images/foo/Dockerfile` → `foo`), or `foo` for `foo.Dockerfile` / `Dockerfile.foo` |
| `description` | shown in the environment list | `org.opencontainers.image.description` / `.title` label, else "Built from …" |
| `uidGidSource` | `fromIdpToken`: runs as the researcher (their UID/GID, NFS `/home` mounted automatically); `fromTheImage`: the image's user | `fromTheImage` |
| `command`, `args` | container command (strings). OS images need something long-running, e.g. `sleep` / `infinity`, to stay up as workspaces | image `ENTRYPOINT`/`CMD` |
| `env` | environment variables (map) | none |
| `connections` | tools Run:ai opens in the browser (Jupyter, MLflow, RStudio, …), see section 11 | none |
| `routingMethod` | `host-base`: tool at `https://<project>-<workload>.runai.htd.local` | Run:ai default |
| `workspace`, `training` | which workload types may use it (`true`/`false`) | both `true` |

The tag is **not** set here; it is chosen in the dialog (default: today's
date).

### 7.3 Running the build

Press `b` (or start with `htd-images <Dockerfile>`), then:

1. **Dockerfile:** path (`Tab` completes).
2. **Name**, **tag**, **description:** pre-filled; `Enter` keeps the value.
   Pin a real tag. The date default (`2026-11-01`) is good practice: a new
   date = a new image, old workloads keep theirs.
3. If that tag already exists you're asked whether to rebuild it
   (`FORCE=1`). An existing tag is never overwritten silently.
4. **Build plan:** full image reference, the steps that will run, the
   catalog entry that will be written, and **warnings** (base image missing
   from the registry, non-`${WL}` base, bad name). Read it, press `q`.
5. **Confirm.** The TUI steps aside and you watch the build live:
   - the catalog entry is added (or updated in place, comments kept);
   - `26-build-image.sh <name>` checks free space (≥ 5 GB in
     `/var/lib/containers`), builds, pushes to `workloads/<name>:<tag>`, and
     deletes the local image and bases again (ww1's disk is small);
   - `24-workload-catalog.sh` creates or updates the Run:ai environment.
6. `Enter` brings you back; the image now shows `●`. Researchers see the
   environment at once (Run:ai → Workloads → New → Environment).

The status line shows `done` or `FAILED (exit N)`; the output is in
`/var/log/htd-images.log` (`L`).

## 8. Importing an image

`i` copies an image from any registry into the workload registry (all
architectures, digests unchanged):

1. **Source image:** e.g. `quay.io/jupyter/minimal-notebook:2026-10-28`.
   Always use a pinned tag, not `latest`.
2. **As `<name>:<tag>`:** the name under `workloads/` (default: last path
   part and tag of the source).
3. **Run:ai environment name:**
   - **empty** → registry only (`25-mirror-image.sh`). Good for base images
     you want to build `FROM`, or for researchers who reference the image in
     their own manifests. No catalog change.
   - **a name** → you're also asked:
     - *run as the submitting user?* `y` = `uidGidSource: fromIdpToken`
       (researcher's UID, `/home` mounted). Say **no** for images with their
       own user and home (Jupyter's `jovyan`, code-server, RStudio): mounting
       `/home` over theirs breaks them.
     - *keep it running with `sleep infinity`?* `y` for plain OS images,
       which otherwise exit immediately.

     Then a catalog entry (`source:`) is written and
     `24-workload-catalog.sh` copies the image and creates the environment.

Tool connections (a browser UI) can't be set in the import dialog: add them
with `e` (section 9), then `s`.

**Check the platforms afterwards:** an image without `linux/arm64` imports
fine but cannot start on the lab nodes. The details pane shows the
architectures.

## 9. Syncing Run:ai and editing the catalog

- `s` runs `24-workload-catalog.sh`: copies missing `source:` images, creates
  or updates every environment, ensures the `workload-registry-pull`
  credential and the `workload-registry` data source, and **removes
  environments whose image isn't in the workload registry** (including
  Run:ai built-ins re-seeded by an upgrade). Run it after editing the catalog
  and after Run:ai upgrades.
- `e` opens the catalog in `$EDITOR`. The format is documented at the top
  of the file. A YAML error there breaks the next sync. The TUI never writes
  invalid YAML, but your editor can.

## 10. Command-line mode

The same operations, for scripts and quick checks:

```sh
htd-images ls                         # every workloads/ image; ● + environment names
htd-images ls jupyter                 # filter
htd-images ls -a                      # every repository
htd-images inspect rstudio:4.6.2      # JSON: platforms, size, config, labels, history
htd-images inspect charts/<chart>:<version>        # outside workloads/: full repository path

htd-images build runai/images/mlflow/Dockerfile                 # shows the entry, asks
htd-images build runai/images/mlflow/Dockerfile -y --tag 2026-11-02
htd-images build runai/images/mlflow/Dockerfile -y --force      # rebuild an existing tag

htd-images import quay.io/jupyter/minimal-notebook:2026-10-28                    # registry only
htd-images import docker.io/library/debian:13 debian:13 --env debian --as-user --keep-alive

htd-images sync
```

Exit codes are those of the underlying step; output also goes to the log.

## 11. Walkthrough: the HTD Researcher MLflow image

[`runai/images/mlflow`](runai/images/mlflow) is a complete example: an MLflow
tracking server that researchers open as a tool in Run:ai, with a branded
shell.

**Build it** (≈ 1 GB of Python packages, a few minutes):

```sh
htd-images ~/rke2_deploy_ww/runai/images/mlflow/Dockerfile
```

Accept the defaults (name `mlflow`, today's tag), read the plan, confirm.
The `#catalog` block at the top of its Dockerfile sets:

```yaml
uidGidSource: fromIdpToken          # runs as the researcher; data in their home
training: false                     # workspace only
routingMethod: host-base
connections:
  - name: MLflow
    internalToolInfo:
      toolType: mlflow
      connectionType: ExternalUrl
      containerPort: 5000
      externalUrlInfo: {}
```

**What researchers get:** Run:ai → *New workspace* → environment **mlflow**
→ *MLflow* button → `https://<project>-<workspace>.runai.htd.local`, behind
Run:ai login.

- Runs and artifacts persist in `~/mlflow` (SQLite + files on their NFS
  home), so a new workspace sees earlier experiments.
  `MLFLOW_BACKEND_STORE_URI` / `MLFLOW_ARTIFACTS_DESTINATION` in the
  environment's variables point it elsewhere (e.g. a shared Postgres + S3).
- The **terminal** (Run:ai UI or `kubectl exec`) shows the HTD Researcher
  banner, an `HTD ⚗ user@project ~/dir (branch)` prompt, and these
  commands:

| Command | Does |
|---|---|
| `htd-help` | list of the commands below |
| `htd-info` | identity, project/workload, CPU/memory limits, GPUs, home space, MLflow health |
| `htd-demo` | trains three random forests, logs params/metrics/plots/models to experiment `htd-demo`, registers the best as model `htd-diabetes-rf` |
| `mlflow-ui`, `mlflow-logs` | MLflow URLs; follow the server log |
| `gpu` | `nvidia-smi`, or which GPUs the pod got |

`MLFLOW_TRACKING_URI` is preset, so `import mlflow` in any script in the
workspace logs to its server.

**Customise it** the same way for other images: shell branding is plain
files under `rootfs/` (`/etc/profile.d/htd-*.sh` for login shells, appended
to `/etc/bash.bashrc` for Run:ai terminals). Change them, then build with a
new tag. Pin `MLFLOW_VERSION` in the Dockerfile to move MLflow.

## 12. Keeping git in step

The repo on ww1 is a **copy**: pushing from the Mac with tar-over-ssh
overwrites it. Builds and imports change
`runai/catalog/environments.yaml` **on ww1**. Bring it back before the next
push, or the next sync will no longer know about those entries:

```sh
# on the Mac, in the repo
scp root@192.168.65.2:rke2_deploy_ww/runai/catalog/environments.yaml runai/catalog/
git diff runai/catalog/environments.yaml && git commit -am "catalog: <what you added>"
```

Dockerfiles you created on ww1 outside the repo copy should be moved into
`runai/images/` (and the entry's `build:` path adjusted) to keep them.

## 13. Removing an image or environment

`htd-images` doesn't delete. The registry it reads is read-only, and
removing images is rare and disruptive (running workloads may use them).

- **Stop offering an environment:** delete its entry from the catalog (`e`)
  **and** the environment in the Run:ai UI (Environments → delete). Removing
  only the catalog entry leaves the environment in Run:ai: the sync updates
  and creates, it removes only environments whose image is gone.
- **Replace a version:** build or import a new tag and point the entry at it.
  The sync updates the environment; the old tag stays available for
  workloads that pin it.
- **Free registry space:** a registry operation outside this tool (delete
  the manifests on `:5000`, then garbage-collect the registry). ww1's disk
  is small, so check `df -h /var/lib/rke2-registry` before large builds and
  imports.

## 14. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `htd-images is root-only` | run it as root on ww1 |
| Header shows `Run:ai ✖ … token is expired` / `401` | ww1's clock drifted (the VM paused): `date`, `chronyc makestep`. Browsing works; environment marks and syncs need Run:ai |
| Header shows `Run:ai ✖` with a connection error | control plane down: `kubectl -n runai-backend get pods` |
| Repository list empty, error on the left | workload registry down: `systemctl status rke2-registry-ro` |
| Plan warns *base … is not in the workload registry* | import the base first (`i`, registry only), then build |
| Build fails pulling `docker.io/...` / `401` | a `FROM` not using `${WL}/` |
| `only NG free for podman storage` | ww1's disk: `podman system prune -a`, or `MIN_FREE_GB=3 htd-images …` if you're sure |
| `… already exists (--force rebuilds)` | tags are immutable by default; use a new tag or confirm the rebuild |
| Environment created but workloads stay `ImagePullBackOff` | image lacks `linux/arm64` (see platforms) or the tag was removed from the registry |
| MLflow tool page shows `Invalid Host header` | MLflow's host check; `htd-start` passes `--allowed-hosts '*'` when the installed MLflow supports it. Set `MLFLOW_ALLOWED_HOSTS` in the environment to narrow it |
| `y` copies nothing | the terminal doesn't allow OSC 52; take the reference from the status line |
| `terminal too small` | resize to at least 70 × 12 |
| Where's the output of an earlier build? | `L` in the TUI, or `/var/log/htd-images.log` |
