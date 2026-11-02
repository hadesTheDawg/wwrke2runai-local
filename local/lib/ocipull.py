#!/usr/bin/env python3
"""Pull images (and OCI Helm charts) into an OCI image layout, stdlib only.

No container runtime, skopeo or helm: just the registry HTTP API.

  ocipull.py [--arch all|amd64|arm64] [--authfile F] [--insecure|--ca F] <layout dir> <ref>...
  ocipull.py ... <layout dir> -f <list file>       (one ref per line, # comments)

  ref: [registry/]repo[:tag][@sha256:...]   (docker.io and library/ implied)

The layout (oci-layout, index.json, blobs/sha256/*) is what `skopeo copy
oci:<dir>:<ref name> docker://...` and `tar` understand; every blob is
checked against its digest. --arch all (default) keeps the multi-arch index
byte-for-byte, so digests match the upstream/lock exactly; a single arch
records only that platform's manifest (also digest-exact). OCI Helm charts
are artifacts like any image: their chart .tgz is a blob of the layout.

Credentials come from a containers/docker auth.json (--authfile, default
$REGISTRY_AUTH_FILE), never from the command line.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

INDEX = {"application/vnd.oci.image.index.v1+json",
         "application/vnd.docker.distribution.manifest.list.v2+json"}
ACCEPT = ", ".join(sorted(INDEX) + [
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def parse_ref(ref):
    """-> (host, repo, tag or None, digest or None, normalized name)"""
    name, _, digest = ref.partition("@")
    first, _, rest = name.partition("/")
    if not rest or ("." not in first and ":" not in first and first != "localhost"):
        first, rest = "docker.io", name
    tag = None
    if ":" in rest.rsplit("/", 1)[-1]:
        rest, tag = rest.rsplit(":", 1)
    if first == "docker.io" and "/" not in rest:
        rest = "library/" + rest
    if not tag and not digest:
        tag = "latest"
    norm = f"{first}/{rest}" + (f":{tag}" if tag else "") + (f"@{digest}" if digest else "")
    host = "registry-1.docker.io" if first == "docker.io" else first
    return host, rest, tag, digest or None, norm


class Repo:
    def __init__(self, host, repo, auths, ctx):
        self.host, self.repo, self.ctx, self.auth = host, repo, ctx, None
        a = auths.get(host) or (auths.get("docker.io") or auths.get("https://index.docker.io/v1/")
                                if host == "registry-1.docker.io" else None)
        self.basic = a.get("auth") if a else None

    def get(self, path, accept=None):
        for attempt in (1, 2):
            req = urllib.request.Request(f"https://{self.host}/v2/{self.repo}/{path}")
            if accept:
                req.add_header("Accept", accept)
            if self.auth:
                # not forwarded on redirects (blob CDNs reject a second auth scheme)
                req.add_unredirected_header("Authorization", self.auth)
            try:
                return urllib.request.urlopen(req, context=self.ctx, timeout=120)
            except urllib.error.HTTPError as e:
                if e.code != 401 or attempt == 2:
                    raise
                self.login(e.headers.get("WWW-Authenticate", ""))

    def login(self, challenge):
        scheme, _, params = challenge.partition(" ")
        if scheme.lower() == "basic":
            if not self.basic:
                sys.exit(f"{self.host}: needs credentials (--authfile)")
            self.auth = "Basic " + self.basic
            return
        p = dict(re.findall(r'(\w+)="([^"]*)"', params))
        q = {k: p[k] for k in ("service", "scope") if k in p}
        q.setdefault("scope", f"repository:{self.repo}:pull")
        req = urllib.request.Request(p["realm"] + "?" + urllib.parse.urlencode(q))
        if self.basic:
            req.add_header("Authorization", "Basic " + self.basic)
        with urllib.request.urlopen(req, context=self.ctx, timeout=60) as r:
            j = json.load(r)
        self.auth = "Bearer " + (j.get("token") or j["access_token"])


class Layout:
    def __init__(self, root):
        self.root = root
        os.makedirs(os.path.join(root, "blobs", "sha256"), exist_ok=True)
        with open(os.path.join(root, "oci-layout"), "w") as f:
            json.dump({"imageLayoutVersion": "1.0.0"}, f)
        p = os.path.join(root, "index.json")
        self.index = json.load(open(p)) if os.path.exists(p) else {"schemaVersion": 2, "manifests": []}

    def path(self, digest):
        algo, _, hexd = digest.partition(":")
        return os.path.join(self.root, "blobs", algo, hexd)

    def has(self, digest):
        return os.path.exists(self.path(digest))

    def write(self, digest, data):
        if hashlib.sha256(data).hexdigest() != digest.split(":", 1)[1]:
            sys.exit(f"digest mismatch: {digest}")
        with open(self.path(digest), "wb") as f:
            f.write(data)

    def blob(self, repo, desc):
        digest = desc["digest"]
        if self.has(digest):
            return 0
        tmp, h = self.path(digest) + ".part", hashlib.sha256()
        with repo.get("blobs/" + digest) as r, open(tmp, "wb") as f:
            for chunk in iter(lambda: r.read(1 << 20), b""):
                h.update(chunk)
                f.write(chunk)
        if "sha256:" + h.hexdigest() != digest:
            os.remove(tmp)
            sys.exit(f"digest mismatch: {repo.repo}@{digest}")
        os.replace(tmp, self.path(digest))
        return desc.get("size", 0)

    def tag(self, name, desc):
        self.index["manifests"] = [m for m in self.index["manifests"]
                                   if m.get("annotations", {}).get("org.opencontainers.image.ref.name") != name]
        self.index["manifests"].append(dict(desc, annotations={"org.opencontainers.image.ref.name": name}))
        with open(os.path.join(self.root, "index.json"), "w") as f:
            json.dump(self.index, f, indent=1)


def manifest(repo, layout, ref):
    """fetch + store one manifest -> (descriptor, parsed json)"""
    with repo.get("manifests/" + ref, ACCEPT) as r:
        data = r.read()
        ctype = r.headers.get("Content-Type", "").split(";")[0]
    digest = "sha256:" + hashlib.sha256(data).hexdigest()
    if ref.startswith("sha256:") and ref != digest:
        sys.exit(f"{repo.repo}@{ref}: registry returned {digest}")
    layout.write(digest, data)
    m = json.loads(data)
    return {"mediaType": m.get("mediaType") or ctype, "digest": digest, "size": len(data)}, m


def pull_image(repo, layout, desc, m):
    n = 0
    for d in [m["config"]] + m.get("layers", []):
        n += layout.blob(repo, d)
    return n


def pull(ref, layout, arch, auths, ctx):
    host, path, tag, digest, name = parse_ref(ref)
    repo = Repo(host, path, auths, ctx)
    desc, m = manifest(repo, layout, digest or tag)
    n = 0
    if desc["mediaType"] in INDEX:
        children = m["manifests"]
        if arch != "all":
            pick = [c for c in children if c.get("platform", {}).get("architecture") == arch
                    and c.get("platform", {}).get("os", "linux") == "linux"]
            if not pick:
                sys.exit(f"{name}: no linux/{arch} image")
            children = pick[:1]
            desc = None
        for c in children:
            cdesc, cm = manifest(repo, layout, c["digest"])
            if cm.get("mediaType", cdesc["mediaType"]) in INDEX:
                continue                        # nested index: rare, not followed
            n += pull_image(repo, layout, cdesc, cm)
            desc = desc or dict(cdesc, mediaType=c.get("mediaType", cdesc["mediaType"]))
    else:
        n += pull_image(repo, layout, desc, m)
    layout.tag(name, desc)
    print(f"  {name}  {desc['digest']}  +{n / 1048576:.1f} MiB", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--arch", default="all")
    ap.add_argument("--authfile", default=os.environ.get("REGISTRY_AUTH_FILE"))
    ap.add_argument("--insecure", action="store_true")
    ap.add_argument("--ca")
    ap.add_argument("-f", dest="listfile")
    ap.add_argument("layout")
    ap.add_argument("refs", nargs="*")
    a = ap.parse_args()
    refs = list(a.refs)
    if a.listfile:
        refs += [l.split("#")[0].strip() for l in open(a.listfile) if l.split("#")[0].strip()]
    auths = json.load(open(a.authfile)).get("auths", {}) if a.authfile else {}
    ctx = ssl.create_default_context(cafile=a.ca)
    if a.insecure:
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
    layout, fail = Layout(a.layout), 0
    for ref in refs:
        try:
            pull(ref, layout, a.arch, auths, ctx)
        except (urllib.error.URLError, KeyError, ValueError) as e:
            print(f"  FAILED {ref}: {e}", file=sys.stderr)
            fail = 1
    sys.exit(fail)


if __name__ == "__main__":
    main()
