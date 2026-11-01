#!/usr/bin/env python3
"""htd-images: browse, build and import workload images (root on ww1 only).

A curses TUI over the pull-only workload registry (${WL_REGISTRY}) and the
Run:ai catalog. Every write goes through the existing steps, so the TUI adds
no second way of pushing images or creating environments:

  build   a Dockerfile -> catalog entry (`build:`) -> 26-build-image.sh
          (podman build on ww1, push, Run:ai environment via 24-...)
  import  an upstream image -> 25-mirror-image.sh (registry only), or a
          catalog entry (`source:`) -> 24-workload-catalog.sh (+ environment)
  sync    24-workload-catalog.sh (catalog -> registry + Run:ai environments)

Usage (as root, from the repo copy on ww1):

  htd-images.py                         TUI
  htd-images.py <Dockerfile>...         TUI, opening the build dialog for each
  htd-images.py ls [text]               repositories, tags, Run:ai environments
  htd-images.py inspect <repo>[:<tag>]  manifest, platforms, labels, config
  htd-images.py build <Dockerfile> [--name N] [--tag T] [--force] [-y]
  htd-images.py import <source> [<name>:<tag>] [--env NAME] [--as-user] [--keep-alive]
  htd-images.py sync

Catalog metadata can live in the Dockerfile itself: lines starting with
`#catalog` form a YAML mapping merged into the catalog entry, e.g.

  #catalog description: MLflow tracking server
  #catalog uidGidSource: fromIdpToken
  #catalog connections:
  #catalog   - name: MLflow
  #catalog     internalToolInfo: {toolType: mlflow, connectionType: ExternalUrl,
  #catalog                        containerPort: 5000, externalUrlInfo: {}}

The catalog file edited is the one in this checkout
(runai/catalog/environments.yaml); copy it back into git afterwards.
Output of every action is appended to /var/log/htd-images.log.
"""
import argparse
import base64
import curses
import datetime
import glob
import json
import os
import re
import ssl
import subprocess
import sys
import textwrap
import time
import urllib.error
import urllib.request

import yaml

HERE = os.path.dirname(os.path.realpath(__file__))          # runai/
CATALOG = os.path.join(HERE, "catalog", "environments.yaml")
LOG = "/var/log/htd-images.log"
BUILT_IN_MARKER = "  # --- Run:ai built-in environments"  # new entries go above it
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


# --- settings -----------------------------------------------------------------
def load_env():
    """runai/env.sh (and scripts/env.sh) exactly as the steps see them."""
    out = subprocess.run(["bash", "-c", '. "$1" >/dev/null 2>&1 && env -0', "_",
                          os.path.join(HERE, "env.sh")], capture_output=True, check=True).stdout
    env = dict(kv.split("=", 1) for kv in out.decode().split("\0") if "=" in kv)
    os.environ.update(env)
    return env


def read(path):
    with open(path) as f:
        return f.read().strip()


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def tag_key(t):
    """latest first, then newest-looking (natural sort, descending)."""
    return (t != "latest", [(-int(p), "") if p.isdigit() else (0, p) for p in re.split(r"(\d+)", t)])


# --- registry (read side: the pull-only workload registry) --------------------
class Registry:
    def __init__(self, host, user, password, ca):
        self.host = host
        self.base = f"https://{host}"
        self.auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()
        self.ctx = ssl.create_default_context(cafile=ca)

    def _get(self, path, accept=None, method="GET"):
        headers = {"Authorization": self.auth}
        if accept:
            headers["Accept"] = accept
        req = urllib.request.Request(self.base + path, headers=headers, method=method)
        with urllib.request.urlopen(req, context=self.ctx, timeout=20) as r:
            return r.read(), r.headers

    def repos(self):
        out, path = [], "/v2/_catalog?n=1000"
        while path:
            body, headers = self._get(path)
            out += json.loads(body).get("repositories") or []
            m = re.search(r"<([^>]+)>;\s*rel=\"next\"", headers.get("Link", ""))
            path = m.group(1) if m else None
        return sorted(out)

    def tags(self, repo):
        try:
            body, _ = self._get(f"/v2/{repo}/tags/list?n=1000")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return []
            raise
        return sorted(json.loads(body).get("tags") or [], key=tag_key)

    def exists(self, repo, ref):
        try:
            self._get(f"/v2/{repo}/manifests/{ref}", ACCEPT, method="HEAD")
            return True
        except urllib.error.HTTPError:
            return False

    def manifest(self, repo, ref):
        body, headers = self._get(f"/v2/{repo}/manifests/{ref}", ACCEPT)
        return json.loads(body), headers.get("Docker-Content-Digest", ""), len(body)

    def blob_json(self, repo, digest):
        body, _ = self._get(f"/v2/{repo}/blobs/{digest}")
        return json.loads(body)

    def inspect(self, repo, tag, arch):
        """Everything the details pane shows, for one tag."""
        top, digest, _ = self.manifest(repo, tag)
        info = {"repo": repo, "tag": tag, "digest": digest,
                "mediaType": top.get("mediaType", ""), "platforms": []}
        man = top
        if "manifests" in top:    # multi-arch index: pick the node architecture
            plats = [m for m in top["manifests"] if m.get("platform", {}).get("architecture") != "unknown"]
            info["platforms"] = [(f"{m['platform'].get('os')}/{m['platform'].get('architecture')}"
                                  + (f"/{m['platform']['variant']}" if m["platform"].get("variant") else ""),
                                  m["digest"]) for m in plats]
            pick = next((m for m in plats if m["platform"].get("architecture") == arch), plats[0] if plats else None)
            if pick is None:
                return info
            info["shown"] = pick["platform"].get("architecture")
            man, _, _ = self.manifest(repo, pick["digest"])
        layers = man.get("layers", [])
        info["layers"] = len(layers)
        info["size"] = sum(layer.get("size", 0) for layer in layers)
        cfg = self.blob_json(repo, man["config"]["digest"]) if "config" in man else {}
        if not info["platforms"]:
            info["platforms"] = [(f"{cfg.get('os', '?')}/{cfg.get('architecture', '?')}", digest)]
            info["shown"] = cfg.get("architecture")
        c = cfg.get("config") or {}
        info.update(created=cfg.get("created", ""), user=c.get("User") or "root (image default)",
                    workdir=c.get("WorkingDir", ""), entrypoint=c.get("Entrypoint"), cmd=c.get("Cmd"),
                    env=c.get("Env") or [], labels=c.get("Labels") or {},
                    ports=sorted((c.get("ExposedPorts") or {}).keys()),
                    history=[h.get("created_by", "") for h in cfg.get("history", []) if not h.get("empty_layer")])
        return info


# --- catalog (runai/catalog/environments.yaml) ---------------------------------
def catalog_entries():
    try:
        with open(CATALOG) as f:
            return yaml.safe_load(f).get("environments") or []
    except (OSError, yaml.YAMLError):
        return []


def render_entry(entry, comment):
    body = yaml.safe_dump(entry, sort_keys=False, default_flow_style=False, width=100, allow_unicode=True)
    lines = [f"  # {comment}"] if comment else []
    for i, line in enumerate(body.rstrip("\n").split("\n")):
        lines.append(("  - " if i == 0 else "    ") + line)
    return lines


def catalog_upsert(entry, comment=None):
    """Add or replace one entry by name. Edits the text, so every comment in
    the file survives; new entries go above the Run:ai built-ins section."""
    with open(CATALOG) as f:
        lines = f.read().split("\n")
    start = next((i for i, l in enumerate(lines) if re.match(rf"^  - name: ['\"]?{re.escape(entry['name'])}['\"]?\s*$", l)), None)
    if start is not None:
        end = start + 1
        while end < len(lines) and not re.match(r"^  [-#]|^\S", lines[end]):
            end += 1
        while end > start + 1 and not lines[end - 1].strip():
            end -= 1
        lines[start:end] = render_entry(entry, None)   # keep whatever comment it had
        action = "updated"
    else:
        at = next((i for i, l in enumerate(lines) if l.startswith(BUILT_IN_MARKER)), None)
        if at is None:
            while lines and not lines[-1].strip():
                lines.pop()
            lines += [""] + render_entry(entry, comment) + [""]
        else:
            lines[at:at] = render_entry(entry, comment) + [""]
        action = "added"
    text = "\n".join(lines)
    yaml.safe_load(text)                       # never write a broken catalog
    with open(CATALOG + ".tmp", "w") as f:
        f.write(text)
    os.replace(CATALOG + ".tmp", CATALOG)
    return action


# --- Dockerfile -> build plan -----------------------------------------------------
def dockerfile_meta(path):
    """(#catalog YAML mapping, base images, OCI labels) from a Dockerfile."""
    text = open(path).read()
    meta_lines = [re.sub(r"^#catalog ?", "", l) for l in text.split("\n") if l.startswith("#catalog")]
    meta = yaml.safe_load("\n".join(meta_lines)) if meta_lines else {}
    if meta is not None and not isinstance(meta, dict):
        raise ValueError("#catalog lines must form a YAML mapping")
    joined = re.sub(r"\\\n", " ", text)
    froms = re.findall(r"^\s*FROM\s+(?:--\S+\s+)*(\S+)", joined, re.M | re.I)
    labels = dict(re.findall(r"(org\.opencontainers\.image\.\w+)=\"([^\"]*)\"", joined))
    return meta or {}, froms, labels


def default_name(path):
    base = os.path.basename(path)
    if base in ("Dockerfile", "Containerfile"):
        name = os.path.basename(os.path.dirname(os.path.abspath(path)))
    elif base.lower().endswith((".dockerfile", ".containerfile")):
        name = base.rsplit(".", 1)[0]
    else:
        name = base.split(".", 1)[1] if "." in base else base
    return re.sub(r"[^a-z0-9._-]", "-", name.lower()).strip("-.") or "image"


class Plan:
    """What `build` will do; the TUI and the CLI both fill and apply one."""

    def __init__(self, ctx, path):
        self.path = os.path.abspath(path)
        if not os.path.isfile(self.path):
            raise ValueError(f"no such Dockerfile: {path}")
        self.meta, self.froms, labels = dockerfile_meta(self.path)
        self.name = str(self.meta.pop("name", "") or default_name(self.path))
        self.tag = datetime.date.today().isoformat()
        self.description = str(self.meta.pop("description", "") or labels.get("org.opencontainers.image.description")
                               or labels.get("org.opencontainers.image.title") or f"Built from {os.path.basename(self.path)}")
        self.ctx = ctx

    def warnings(self):
        out = []
        prefix = "${WL}/"
        for f in self.froms:
            if f.lower().startswith(("$wl/", prefix.lower())):
                repo, _, tag = f.split("/", 1)[1].partition(":")
                if not self.ctx.reg.exists(f"{self.ctx.prefix}/{repo}", tag or "latest"):
                    out.append(f"base {f} is not in the workload registry (import it first)")
            elif not re.match(r"^[a-z0-9_-]+$", f, re.I):   # not a build-stage alias
                out.append(f"FROM {f}: bases must be ${{WL}}/<image> (builds only pull from the workload registry)")
        if not NAME_RE.match(self.name):
            out.append(f"name '{self.name}' must match {NAME_RE.pattern}")
        return out

    def build_ref(self):
        rel = os.path.relpath(self.path, HERE)
        if rel.startswith(".."):
            return self.path
        # keep the short directory form (like images/ubuntu-dev) when it is a plain Dockerfile
        return os.path.dirname(rel) if os.path.basename(rel) == "Dockerfile" else rel

    def image(self):
        return f"{self.name}:{self.tag}"

    def exists(self):
        return self.ctx.reg.exists(f"{self.ctx.prefix}/{self.name}", self.tag)

    def entry(self):
        e = {"name": self.name, "description": self.description,
             "build": self.build_ref(), "image": self.image()}
        e.update({k: v for k, v in self.meta.items() if k not in e})
        return e

    def apply(self, force):
        action = catalog_upsert(self.entry(), f"Built from {self.build_ref()} (htd-images)")
        env = {"FORCE": "1"} if force else {}
        return action, [os.path.join(HERE, "26-build-image.sh"), self.name], env


def import_dest(src):
    repo, tag = src.split("@")[0], "latest"
    last = repo.rsplit("/", 1)[-1]
    if ":" in last:
        last, tag = last.split(":", 1)
    return f"{last}:{tag}"


def import_plan(src, dest, env_name, as_user, keep_alive):
    """-> (catalog entry or None, argv) for one import."""
    dest = dest or import_dest(src)
    if ":" not in dest:
        dest += ":latest"
    if not env_name:
        return None, [os.path.join(HERE, "25-mirror-image.sh"), src, dest]
    entry = {"name": env_name, "description": f"{env_name} ({src})", "source": src, "image": dest}
    if as_user:
        entry["uidGidSource"] = "fromIdpToken"
    if keep_alive:
        entry.update(command="sleep", args="infinity")
    return entry, [os.path.join(HERE, "24-workload-catalog.sh")]


# --- context: settings, registry, Run:ai -------------------------------------------
class Ctx:
    def __init__(self):
        self.env = load_env()
        reg_dir = self.env["REG_DIR"]
        self.reg = Registry(self.env["WL_REGISTRY"], read(f"{reg_dir}/pull-username"),
                            read(f"{reg_dir}/pull-password"), f"{reg_dir}/ca.crt")
        self.prefix = self.env.get("WL_REG_PREFIX", "workloads")
        self.arch = {"aarch64": "arm64", "x86_64": "amd64"}.get(os.uname().machine, os.uname().machine)
        self.runai_envs, self.runai_error = {}, ""

    def load_runai(self):
        """image reference -> [Run:ai environment names]"""
        self.runai_envs, self.runai_error = {}, ""
        try:
            sys.path.insert(0, os.path.join(HERE, "lib"))
            import runai  # noqa: E402 (needs env.sh's RUNAI_* settings)
            for e in runai.RunAI().get("/api/v1/asset/environment")["entries"]:
                self.runai_envs.setdefault(e["spec"].get("image", ""), []).append(e["meta"]["name"])
        except Exception as e:      # control plane down, clock skew, ...
            self.runai_error = str(e).split("\n")[0][:120]

    def ref(self, repo, tag):
        return f"{self.reg.host}/{repo}:{tag}"

    def envs_for(self, repo, tag=None):
        if tag:
            return self.runai_envs.get(self.ref(repo, tag), [])
        pre = f"{self.reg.host}/{repo}:"
        return sorted({n for img, names in self.runai_envs.items() if img.startswith(pre) for n in names})


def run_logged(argv, extra_env=None, title=""):
    """Run a step with its output on the terminal and in the log."""
    env = dict(os.environ, **(extra_env or {}))
    shown = " ".join(f"{k}={v}" for k, v in (extra_env or {}).items()) + (" " if extra_env else "") + " ".join(argv)
    print(f"\033[1;38;5;208m▶ {title or 'run'}\033[0m  \033[2m{shown}\033[0m\n", flush=True)
    try:
        log = open(LOG, "ab")
    except OSError:
        log = open(os.devnull, "wb")
    with log:
        log.write(f"\n=== {datetime.datetime.now():%F %T} {shown}\n".encode())
        p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        while True:
            chunk = os.read(p.stdout.fileno(), 4096)
            if not chunk:
                break
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            log.write(chunk)
        rc = p.wait()
        log.write(f"=== exit {rc}\n".encode())
    colour = "32" if rc == 0 else "31"
    print(f"\n\033[1;{colour}m■ exit {rc}\033[0m", flush=True)
    return rc


# --- TUI ------------------------------------------------------------------------
HELP = """\
 Keys
   ↑/↓ j/k     move              Tab / ←/→   switch pane
   PgUp/PgDn   scroll details    Enter       open repository / tag
   /           filter            a           all repositories / workloads only
   b           build Dockerfile  i           import image
   s           sync Run:ai       e           edit catalog ($EDITOR)
   y           copy pull ref     r           refresh
   L           show log          ?           this help
   q           quit

 Marks   ● offered as a Run:ai environment
         ○ in the catalog, no environment yet (s = sync)

 Builds run 26-build-image.sh (podman on ww1, bases FROM ${WL}/<image>);
 imports run 25-mirror-image.sh or 24-workload-catalog.sh. The read-only
 registry cannot delete; remove entries from the catalog instead."""


class Tui:
    def __init__(self, scr, ctx, queued):
        self.scr, self.ctx, self.queued = scr, ctx, list(queued)
        self.focus = 0                       # 0 repos, 1 tags, 2 details
        self.filter, self.show_all = "", False
        self.sel, self.top, self.dscroll = [0, 0], [0, 0], 0
        self.repos, self.all_repos = [], []
        self.tags, self.details = {}, {}
        self.catalog, self.reg_error, self.status = [], "", ""
        curses.curs_set(0)
        curses.use_default_colors()
        for i, (fg, bg) in enumerate([(curses.COLOR_WHITE, 17 if curses.COLORS >= 256 else curses.COLOR_BLUE),
                                      (curses.COLOR_GREEN, -1), (curses.COLOR_YELLOW, -1), (curses.COLOR_CYAN, -1),
                                      (curses.COLOR_RED, -1), (curses.COLOR_BLACK, curses.COLOR_CYAN),
                                      (208 if curses.COLORS >= 256 else curses.COLOR_YELLOW, -1),
                                      (curses.COLOR_MAGENTA, -1)], start=1):
            curses.init_pair(i, fg, bg)
        self.C = {k: curses.color_pair(i) for i, k in enumerate(
            ["head", "ok", "warn", "info", "err", "sel", "brand", "mag"], start=1)}
        self.refresh(runai=True)

    # data --------------------------------------------------------------------
    def refresh(self, runai=False):
        self.flash("loading ...")
        self.tags, self.details = {}, {}
        self.catalog = catalog_entries()
        try:
            self.all_repos = self.ctx.reg.repos()
            self.reg_error = ""
        except Exception as e:
            self.all_repos, self.reg_error = [], str(e)
        if runai:
            self.ctx.load_runai()
        self.apply_filter()
        self.status = self.reg_error or (f"Run:ai: {self.ctx.runai_error}" if self.ctx.runai_error else "")

    def apply_filter(self):
        f = self.filter.lower()
        pre = f"{self.ctx.prefix}/"
        cat_names = {e["image"].split(":")[0]: e["name"] for e in self.catalog}
        self.repos = [r for r in self.all_repos
                      if (self.show_all or r.startswith(pre))
                      and (not f or f in r.lower() or f in cat_names.get(r[len(pre):], "")
                           or any(f in n for n in self.ctx.envs_for(r)))]
        self.sel[0] = min(self.sel[0], max(0, len(self.repos) - 1))
        self.sel[1], self.top[1], self.dscroll = 0, 0, 0

    def repo(self):
        return self.repos[self.sel[0]] if self.repos else None

    def repo_tags(self, repo):
        if repo not in self.tags:
            try:
                self.tags[repo] = self.ctx.reg.tags(repo)
            except Exception as e:
                self.tags[repo] = []
                self.status = f"tags: {e}"
        return self.tags[repo]

    def tag(self):
        r = self.repo()
        t = self.repo_tags(r) if r else []
        return t[min(self.sel[1], len(t) - 1)] if t else None

    def catalog_entry(self, repo, tag):
        short = repo[len(self.ctx.prefix) + 1:] if repo.startswith(self.ctx.prefix + "/") else None
        return next((e for e in self.catalog if short and e.get("image") == f"{short}:{tag}"), None)

    def detail_lines(self):
        r, t = self.repo(), self.tag()
        if not r or not t:
            return [("no image selected", "warn")]
        key = (r, t)
        if key not in self.details:
            try:
                self.details[key] = self.ctx.reg.inspect(r, t, self.ctx.arch)
            except Exception as e:
                self.details[key] = {"error": str(e)}
        d = self.details[key]
        if "error" in d:
            return [(f"error: {d['error']}", "err")]
        L = [(self.ctx.ref(r, t), "brand"), (d["digest"], "mag"), ("", None)]
        envs = self.ctx.envs_for(r, t)
        cat = self.catalog_entry(r, t)
        if envs:
            L.append((f"Run:ai   ● environment {', '.join(envs)}", "ok"))
        elif cat:
            L.append((f"Run:ai   ○ catalog entry '{cat['name']}', no environment yet (s = sync)", "warn"))
        else:
            L.append(("Run:ai   not offered (i = import with environment)", None))
        if cat:
            how = f"build {cat['build']}" if "build" in cat else f"source {cat.get('source')}"
            L.append((f"catalog  {cat['name']}: {how}", "info"))
            if cat.get("description"):
                L.append((f"         {cat['description']}", None))
        L.append(("", None))
        plats = ", ".join(p for p, _ in d["platforms"]) or "?"
        L.append((f"platforms {plats}" + (f"   (showing {d.get('shown')})" if len(d["platforms"]) > 1 else ""), None))
        if "size" in d:
            L.append((f"size      {human(d['size'])} compressed, {d['layers']} layers", None))
        for label, k in (("created", "created"), ("user", "user"), ("workdir", "workdir")):
            if d.get(k):
                L.append((f"{label:<9} {d[k]}", None))
        if d.get("entrypoint"):
            L.append((f"entry     {json.dumps(d['entrypoint'])}", None))
        if d.get("cmd"):
            L.append((f"cmd       {json.dumps(d['cmd'])}", None))
        if d.get("ports"):
            L.append((f"ports     {' '.join(d['ports'])}", None))
        for title, items in (("labels", [f"{k}={v}" for k, v in sorted(d.get("labels", {}).items())]),
                             ("env", d.get("env", [])),
                             ("history", [h.replace("/bin/sh -c ", "").replace("#(nop) ", "").strip()
                                          for h in d.get("history", [])])):
            if items:
                L += [("", None), (title, "info")] + [(f"  {i}", None) for i in items]
        return L

    # drawing -------------------------------------------------------------------
    def put(self, y, x, text, attr=0, width=None):
        h, w = self.scr.getmaxyx()
        if y < 0 or y >= h or x >= w:
            return
        width = min(width if width is not None else w - x, w - x)
        try:
            self.scr.addnstr(y, x, text, width, attr)
        except curses.error:
            pass

    def box(self, y, x, h, w, title, focused):
        attr = self.C["brand"] | curses.A_BOLD if focused else curses.A_DIM
        try:
            self.scr.attron(attr)
            self.scr.addch(y, x, curses.ACS_ULCORNER)
            self.scr.hline(y, x + 1, curses.ACS_HLINE, w - 2)
            self.scr.addch(y, x + w - 1, curses.ACS_URCORNER)
            self.scr.vline(y + 1, x, curses.ACS_VLINE, h - 2)
            self.scr.vline(y + 1, x + w - 1, curses.ACS_VLINE, h - 2)
            self.scr.addch(y + h - 1, x, curses.ACS_LLCORNER)
            self.scr.hline(y + h - 1, x + 1, curses.ACS_HLINE, w - 2)
            self.scr.addch(y + h - 1, x + w - 1, curses.ACS_LRCORNER)
        except curses.error:
            pass
        finally:
            self.scr.attroff(attr)
        self.put(y, x + 2, f" {title} ", attr, w - 4)

    def draw_list(self, idx, y, x, h, w, items):
        rows = h - 2
        sel = self.sel[idx] = max(0, min(self.sel[idx], len(items) - 1))
        if sel < self.top[idx]:
            self.top[idx] = sel
        elif sel >= self.top[idx] + rows:
            self.top[idx] = sel - rows + 1
        for i, (mark, text, attr) in enumerate(items[self.top[idx]:self.top[idx] + rows]):
            row = self.top[idx] + i
            line = f"{mark} {text}".ljust(w - 2)
            if row == sel:
                self.put(y + 1 + i, x + 1, line, self.C["sel"] | (curses.A_BOLD if self.focus == idx else 0), w - 2)
            else:
                self.put(y + 1 + i, x + 1, mark, attr, 1)
                self.put(y + 1 + i, x + 3, text, 0, w - 4)
        if len(items) > rows:
            self.put(y + h - 1, x + w - 8, f" {sel + 1}/{len(items)} ", curses.A_DIM)

    def draw(self):
        self.scr.erase()
        h, w = self.scr.getmaxyx()
        if h < 12 or w < 70:
            self.put(0, 0, "terminal too small (need 70x12)", self.C["err"])
            self.scr.refresh()
            return
        runai = (f"Run:ai ✖ {self.ctx.runai_error[:40]}" if self.ctx.runai_error
                 else f"Run:ai ● {sum(len(v) for v in self.ctx.runai_envs.values())} environments")
        head = f" ▲ HTD Researcher · image registry   {self.ctx.reg.host}/{'*' if self.show_all else self.ctx.prefix}"
        self.put(0, 0, head.ljust(w), self.C["head"] | curses.A_BOLD)
        self.put(0, w - len(runai) - 2, runai, self.C["head"])

        ph = h - 3
        w1 = max(26, w * 30 // 100)
        w2 = max(18, w * 18 // 100)
        w3 = w - w1 - w2
        flt = f"  /{self.filter}" if self.filter else ""
        self.box(1, 0, ph, w1, f"Repositories {len(self.repos)}{flt}", self.focus == 0)
        pre = f"{self.ctx.prefix}/"
        items = []
        for r in self.repos:
            envs = self.ctx.envs_for(r)
            in_cat = any(e["image"].split(":")[0] == r[len(pre):] for e in self.catalog) if r.startswith(pre) else False
            mark, attr = ("●", self.C["ok"]) if envs else (("○", self.C["warn"]) if in_cat else (" ", 0))
            items.append((mark, r[len(pre):] if r.startswith(pre) and not self.show_all else r, attr))
        if items:
            self.draw_list(0, 1, 0, ph, w1, items)
        else:
            self.put(3, 2, self.reg_error[:w1 - 4] if self.reg_error else "nothing matches", self.C["warn"])

        r = self.repo()
        tags = self.repo_tags(r) if r else []
        self.box(1, w1, ph, w2, f"Tags {len(tags)}", self.focus == 1)
        titems = []
        for t in tags:
            envs = self.ctx.envs_for(r, t)
            cat = self.catalog_entry(r, t)
            titems.append(("●", t, self.C["ok"]) if envs else (("○", t, self.C["warn"]) if cat else (" ", t, 0)))
        if titems:
            self.draw_list(1, 1, w1, ph, w2, titems)

        self.box(1, w1 + w2, ph, w3, "Details", self.focus == 2)
        lines = []
        for text, style in self.detail_lines():
            wrapped = textwrap.wrap(text, w3 - 4, subsequent_indent="    ") or [""]
            lines += [(part, style) for part in wrapped]
        self.dscroll = max(0, min(self.dscroll, len(lines) - (ph - 2)))
        for i, (text, style) in enumerate(lines[self.dscroll:self.dscroll + ph - 2]):
            self.put(2 + i, w1 + w2 + 2, text, self.C[style] if style else 0, w3 - 4)

        self.put(h - 2, 0, self.status.ljust(w), self.C["warn"] if self.status else 0)
        keys = [("/", "filter"), ("b", "build"), ("i", "import"), ("s", "sync Run:ai"), ("y", "copy ref"),
                ("e", "catalog"), ("a", "all"), ("r", "refresh"), ("?", "help"), ("q", "quit")]
        x = 0
        for k, label in keys:
            self.put(h - 1, x, f" {k} ", self.C["sel"] | curses.A_BOLD)
            self.put(h - 1, x + len(k) + 2, f"{label} ", 0)
            x += len(k) + len(label) + 4
        self.scr.refresh()

    def flash(self, msg):
        self.status = msg
        self.draw()

    # input ---------------------------------------------------------------------
    def prompt(self, label, default="", complete_paths=False):
        """One-line editor on the status line. Esc cancels (None)."""
        buf = list(default)
        curses.curs_set(1)
        try:
            while True:
                h, w = self.scr.getmaxyx()
                text = "".join(buf)
                line = f"{label}: {text}"
                self.put(h - 2, 0, line[-(w - 1):].ljust(w - 1), self.C["info"] | curses.A_BOLD)
                self.scr.move(h - 2, min(len(line), w - 2))
                self.scr.refresh()
                ch = self.scr.get_wch()
                if ch in ("\n", "\r", curses.KEY_ENTER):
                    return "".join(buf).strip()
                if ch == "\x1b":
                    return None
                if ch in (curses.KEY_BACKSPACE, "\x7f", "\b"):
                    buf = buf[:-1]
                elif ch == "\x15":                     # Ctrl-U
                    buf = []
                elif ch == "\t" and complete_paths:
                    matches = glob.glob(os.path.expanduser(text) + "*")
                    if len(matches) == 1:
                        m = matches[0] + ("/" if os.path.isdir(matches[0]) else "")
                        buf = list(m)
                    elif matches:
                        buf = list(os.path.commonprefix(matches))
                        self.status = "  ".join(os.path.basename(m) for m in matches[:12])
                elif isinstance(ch, str) and ch.isprintable():
                    buf.append(ch)
        finally:
            curses.curs_set(0)
            self.status = ""

    def confirm(self, question, default=False):
        ans = self.prompt(f"{question} [{'Y/n' if default else 'y/N'}]")
        if ans is None:
            return None
        return default if not ans else ans.lower().startswith("y")

    def pager(self, title, text):
        lines = text.split("\n")
        top = 0
        while True:
            self.scr.erase()
            h, w = self.scr.getmaxyx()
            self.put(0, 0, f" {title}".ljust(w), self.C["head"] | curses.A_BOLD)
            for i, l in enumerate(lines[top:top + h - 2]):
                self.put(1 + i, 0, l, 0, w)
            self.put(h - 1, 0, " ↑/↓ PgUp/PgDn scroll · q/Esc back ", self.C["sel"])
            self.scr.refresh()
            k = self.scr.getch()
            if k in (ord("q"), 27, ord("\n")):
                return
            step = {curses.KEY_DOWN: 1, ord("j"): 1, curses.KEY_UP: -1, ord("k"): -1,
                    curses.KEY_NPAGE: h - 3, ord(" "): h - 3, curses.KEY_PPAGE: -(h - 3)}.get(k, 0)
            top = max(0, min(top + step, len(lines) - (h - 2)))

    def external(self, title, argv, extra_env=None):
        """Leave curses, run a step with live output, come back refreshed."""
        curses.def_prog_mode()
        curses.endwin()
        os.system("clear")
        rc = run_logged(argv, extra_env, title)
        try:
            input("\n[Enter] back to htd-images ")
        except EOFError:
            pass
        curses.reset_prog_mode()
        self.scr.clear()
        self.refresh(runai=True)
        self.status = f"{title}: {'done' if rc == 0 else f'FAILED (exit {rc}), see {LOG}'}"
        return rc

    # actions -----------------------------------------------------------------------
    def do_build(self, path=None):
        if path is None:
            path = self.prompt("Dockerfile (Tab completes)", os.getcwd() + "/", complete_paths=True)
            if not path:
                return
        try:
            plan = Plan(self.ctx, os.path.expanduser(path))
        except Exception as e:
            self.status = f"build: {e}"
            return
        for field, label in (("name", "environment / image name"), ("tag", "tag"), ("description", "description")):
            v = self.prompt(label, getattr(plan, field))
            if v is None:
                return
            setattr(plan, field, v or getattr(plan, field))
        force = False
        if plan.exists():
            force = self.confirm(f"{plan.image()} already exists - rebuild it (FORCE)?")
            if not force:
                self.status = "build cancelled (tags are never overwritten without FORCE)"
                return
        summary = yaml.safe_dump(plan.entry(), sort_keys=False, allow_unicode=True)
        warn = plan.warnings()
        text = (f"Dockerfile  {plan.path}\nimage       {self.ctx.reg.host}/{self.ctx.prefix}/{plan.image()}\n"
                f"steps       catalog entry -> 26-build-image.sh {plan.name}"
                f"{' (FORCE=1)' if force else ''} -> 24-workload-catalog.sh\n\ncatalog entry:\n{summary}")
        if warn:
            text += "\nWARNINGS:\n" + "\n".join(f"  ! {x}" for x in warn)
        self.pager("build plan - q to continue", text)
        if not self.confirm(f"build {plan.image()} now?", default=not warn):
            self.status = "build cancelled"
            return
        action, argv, env = plan.apply(force)
        self.external(f"build {plan.image()} (catalog entry {action})", argv, env)

    def do_import(self):
        src = self.prompt("source image (e.g. quay.io/jupyter/minimal-notebook:2026-10-28)")
        if not src:
            return
        dest = self.prompt("as <name>:<tag>", import_dest(src))
        if dest is None:
            return
        env_name = self.prompt("Run:ai environment name (empty = registry only)", "")
        if env_name is None:
            return
        as_user = keep = False
        if env_name:
            if not NAME_RE.match(env_name):
                self.status = f"bad environment name '{env_name}'"
                return
            as_user = self.confirm("run as the submitting user (uidGidSource fromIdpToken, /home mounted)?")
            keep = self.confirm("OS image: keep it running with 'sleep infinity'?")
            if as_user is None or keep is None:
                return
        entry, argv = import_plan(src, dest, env_name, as_user, keep)
        if entry:
            catalog_upsert(entry, f"Imported from {src} (htd-images)")
        self.external(f"import {src}", argv, {})

    def copy_ref(self):
        r, t = self.repo(), self.tag()
        if not r or not t:
            return
        ref = self.ctx.ref(r, t)
        # OSC 52: most terminals put this on the local clipboard, even over ssh
        sys.stdout.write(f"\033]52;c;{base64.b64encode(ref.encode()).decode()}\a")
        sys.stdout.flush()
        self.status = f"copied {ref}"

    def edit_catalog(self):
        editor = os.environ.get("EDITOR") or os.environ.get("VISUAL") or "vi"
        curses.def_prog_mode()
        curses.endwin()
        subprocess.call([*editor.split(), CATALOG])
        curses.reset_prog_mode()
        self.scr.clear()
        self.refresh()
        self.status = "catalog edited - s applies it to the registry and Run:ai"

    def show_log(self):
        try:
            with open(LOG, errors="replace") as f:
                text = "".join(f.readlines()[-2000:])
        except OSError:
            text = "(no log yet)"
        text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text).replace("\r", "\n")
        self.pager(LOG, text)

    def run(self):
        for path in self.queued:
            self.draw()
            self.do_build(path)
        while True:
            self.draw()
            k = self.scr.getch()
            panes = 3
            if k in (ord("q"), 27):
                return
            elif k in (curses.KEY_DOWN, ord("j")):
                if self.focus == 2:
                    self.dscroll += 1
                else:
                    self.sel[self.focus] += 1
                    if self.focus == 0:
                        self.sel[1] = self.top[1] = 0
                    self.dscroll = 0
            elif k in (curses.KEY_UP, ord("k")):
                if self.focus == 2:
                    self.dscroll = max(0, self.dscroll - 1)
                else:
                    self.sel[self.focus] = max(0, self.sel[self.focus] - 1)
                    if self.focus == 0:
                        self.sel[1] = self.top[1] = 0
                    self.dscroll = 0
            elif k == curses.KEY_NPAGE:
                self.dscroll += self.scr.getmaxyx()[0] - 6
            elif k == curses.KEY_PPAGE:
                self.dscroll = max(0, self.dscroll - (self.scr.getmaxyx()[0] - 6))
            elif k in (ord("\t"), curses.KEY_RIGHT, ord("l"), ord("\n")):
                self.focus = (self.focus + 1) % panes
            elif k in (curses.KEY_BTAB, curses.KEY_LEFT, ord("h")):
                self.focus = (self.focus - 1) % panes
            elif k == ord("/"):
                f = self.prompt("filter (name, catalog or environment)", self.filter)
                if f is not None:
                    self.filter = f
                    self.sel[0] = self.top[0] = 0
                    self.apply_filter()
                    self.focus = 0
            elif k == ord("a"):
                self.show_all = not self.show_all
                self.sel[0] = self.top[0] = 0
                self.apply_filter()
            elif k == ord("r"):
                self.refresh(runai=True)
            elif k == ord("b"):
                self.do_build()
            elif k == ord("i"):
                self.do_import()
            elif k == ord("s"):
                if self.confirm("sync catalog -> registry + Run:ai environments (24-workload-catalog.sh)?", True):
                    self.external("sync Run:ai", [os.path.join(HERE, "24-workload-catalog.sh")])
            elif k == ord("y"):
                self.copy_ref()
            elif k == ord("e"):
                self.edit_catalog()
            elif k == ord("L"):
                self.show_log()
            elif k == ord("?"):
                self.pager("htd-images help", HELP)
            elif k == curses.KEY_RESIZE:
                pass


# --- CLI ---------------------------------------------------------------------------
def cli_ls(ctx, args):
    ctx.load_runai()
    if ctx.runai_error:
        print(f"Run:ai unreachable: {ctx.runai_error}", file=sys.stderr)
    for repo in ctx.reg.repos():
        if not args.all and not repo.startswith(ctx.prefix + "/"):
            continue
        if args.text and args.text.lower() not in repo.lower():
            continue
        for t in ctx.reg.tags(repo):
            envs = ctx.envs_for(repo, t)
            print(f"{'●' if envs else ' '} {ctx.ref(repo, t):<64} {','.join(envs)}")


def cli_inspect(ctx, args):
    repo, _, tag = args.ref.partition(":")
    if "/" not in repo:
        repo = f"{ctx.prefix}/{repo}"
    try:
        print(json.dumps(ctx.reg.inspect(repo, tag or "latest", ctx.arch), indent=2))
    except urllib.error.HTTPError as e:
        sys.exit(f"{ctx.ref(repo, tag or 'latest')}: HTTP {e.code} {e.reason}")


def cli_build(ctx, args):
    plan = Plan(ctx, args.dockerfile)
    plan.name = args.name or plan.name
    plan.tag = args.tag or plan.tag
    for w in plan.warnings():
        print(f"warning: {w}", file=sys.stderr)
    if plan.exists() and not args.force:
        sys.exit(f"{plan.image()} already exists (--force rebuilds)")
    print(yaml.safe_dump(plan.entry(), sort_keys=False, allow_unicode=True))
    if not args.yes and input(f"build {plan.image()}? [y/N] ").lower()[:1] != "y":
        sys.exit("cancelled")
    action, argv, env = plan.apply(args.force)
    print(f"catalog entry {plan.name} {action}")
    sys.exit(run_logged(argv, env, f"build {plan.image()}"))


def cli_import(ctx, args):
    entry, argv = import_plan(args.source, args.dest, args.env, args.as_user, args.keep_alive)
    if entry:
        print(f"catalog entry {entry['name']} {catalog_upsert(entry, f'Imported from {args.source} (htd-images)')}")
    sys.exit(run_logged(argv, {}, f"import {args.source}"))


def main():
    if os.geteuid() != 0:
        sys.exit("htd-images is root-only: run it as root on the admin node (ww1)")
    commands = {"ls", "inspect", "build", "import", "sync"}
    if len(sys.argv) > 1 and sys.argv[1] in commands:
        p = argparse.ArgumentParser(prog="htd-images", description=__doc__.split("\n")[0])
        sub = p.add_subparsers(dest="cmd", required=True)
        s = sub.add_parser("ls", help="list images")
        s.add_argument("text", nargs="?")
        s.add_argument("-a", "--all", action="store_true", help="all repositories, not only workloads/")
        s = sub.add_parser("inspect", help="show one image")
        s.add_argument("ref", help="<repo>[:<tag>], repo relative to workloads/ unless it has a /")
        s = sub.add_parser("build", help="build a Dockerfile into the registry and Run:ai")
        s.add_argument("dockerfile")
        s.add_argument("--name")
        s.add_argument("--tag")
        s.add_argument("--force", action="store_true", help="rebuild an existing tag")
        s.add_argument("-y", "--yes", action="store_true")
        s = sub.add_parser("import", help="copy an upstream image in (optionally as an environment)")
        s.add_argument("source")
        s.add_argument("dest", nargs="?", help="<name>:<tag> under workloads/")
        s.add_argument("--env", help="also create Run:ai environment NAME (catalog entry)")
        s.add_argument("--as-user", action="store_true", help="uidGidSource: fromIdpToken")
        s.add_argument("--keep-alive", action="store_true", help="command: sleep infinity")
        sub.add_parser("sync", help="24-workload-catalog.sh")
        args = p.parse_args()
        ctx = Ctx()
        if args.cmd == "sync":
            sys.exit(run_logged([os.path.join(HERE, "24-workload-catalog.sh")], {}, "sync Run:ai"))
        {"ls": cli_ls, "inspect": cli_inspect, "build": cli_build, "import": cli_import}[args.cmd](ctx, args)
        return
    p = argparse.ArgumentParser(prog="htd-images", usage="%(prog)s [Dockerfile...] | {ls,inspect,build,import,sync} ...",
                                description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("dockerfiles", nargs="*", help="open the build dialog for each")
    args = p.parse_args()
    for d in args.dockerfiles:
        if not os.path.isfile(d):
            sys.exit(f"no such Dockerfile: {d}")
    ctx = Ctx()
    os.environ.setdefault("ESCDELAY", "25")
    curses.wrapper(lambda scr: Tui(scr, ctx, args.dockerfiles).run())


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
