#!/usr/bin/env python3
"""Registry v2 and OCI-layout helpers (stdlib only).

Credentials come from a containers auth.json (--authfile), never from the
command line, so they do not show up in `ps`.

  registry.py [--authfile F] [--insecure|--ca F] catalog <registry>
        -> one repository per line (follows pagination)
  registry.py [...] ping <registry>              -> 200 when reachable and authorised
  registry.py [...] tags <registry> <repo>        -> one tag per line
  registry.py [...] digest <registry> <repo> <tag|digest>
        -> manifest digest ("" + exit 1 when absent)
  registry.py store-refs <store>                  -> "<repo:tag>\t<digest>" per image
  registry.py store-dedupe <store> <image dir>    -> hardlink its blobs to <store>/.blobs
  registry.py store-verify <store> [inventory]    -> re-hash blobs/manifests, check digests
"""
import hashlib
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


class Registry:
    def __init__(self, host, authfile=None, insecure=False, ca=None):
        self.base = f"https://{host}"
        self.headers = {}
        if authfile:
            auths = json.load(open(authfile)).get("auths", {})
            if host in auths:
                self.headers["Authorization"] = "Basic " + auths[host]["auth"]
        self.ctx = ssl.create_default_context(cafile=ca) if ca else ssl.create_default_context()
        if insecure:
            self.ctx.check_hostname = False
            self.ctx.verify_mode = ssl.CERT_NONE

    def request(self, path, method="GET", accept=None):
        headers = dict(self.headers)
        if accept:
            headers["Accept"] = accept
        req = urllib.request.Request(self.base + path, method=method, headers=headers)
        return urllib.request.urlopen(req, context=self.ctx, timeout=60)

    def paged(self, path, key):
        while path:
            with self.request(path) as r:
                yield from json.load(r).get(key) or []
                link = r.headers.get("Link", "")
            # Link: </v2/_catalog?last=x&n=100>; rel="next"
            path = link[link.find("<") + 1:link.find(">")] if 'rel="next"' in link else None

    def ping(self):
        with self.request("/v2/") as r:
            return r.status

    def catalog(self):
        return self.paged("/v2/_catalog?n=1000", "repositories")

    def tags(self, repo):
        return self.paged(f"/v2/{repo}/tags/list?n=1000", "tags")

    def digest(self, repo, ref):
        try:
            with self.request(f"/v2/{repo}/manifests/{ref}", method="HEAD", accept=ACCEPT) as r:
                return r.headers.get("Docker-Content-Digest", "")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return ""
            raise


# --- local image store ----------------------------------------------------------------
# One skopeo "dir:" copy per image at <store>/<repo>@<tag> (neither repository
# paths nor tags can contain "@"). dir: keeps manifests byte-for-byte, Docker
# manifest lists included (an OCI layout cannot hold those with digests
# preserved), so <dir>/manifest.json hashes to the registry digest. Blobs are
# hardlinked to <store>/.blobs/<hex>: every layer is stored once.
HEX = set("0123456789abcdef")


def is_hex(name):
    return len(name) == 64 and set(name) <= HEX


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def store_images(store):
    """(ref, image dir) for every complete image in the store."""
    for root, dirs, files in os.walk(store):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        name = os.path.basename(root)
        if "@" in name and "manifest.json" in files and "version" in files:
            rel = os.path.relpath(root, store)
            repo, tag = rel.rsplit("@", 1)
            yield f"{repo}:{tag}", root
            dirs[:] = []


def store_refs(store):
    for ref, path in store_images(store):
        yield ref, "sha256:" + sha256_file(os.path.join(path, "manifest.json"))


def store_dedupe(store, image_dir):
    """Hardlink the blobs of one image dir to the shared pool."""
    pool = os.path.join(store, ".blobs")
    os.makedirs(pool, exist_ok=True)
    saved = 0
    for name in os.listdir(image_dir):
        if not is_hex(name):
            continue
        src, shared = os.path.join(image_dir, name), os.path.join(pool, name)
        if not os.path.exists(shared):
            os.link(src, shared)
        elif not os.path.samefile(src, shared):
            saved += os.path.getsize(src)
            tmp = src + ".lnk"
            os.link(shared, tmp)
            os.replace(tmp, src)
    return saved


def store_verify(store, inventory=None):
    """Re-hash every blob and manifest once (by inode); check the inventory."""
    bad = n = 0
    seen = set()
    refs = {}
    for ref, path in store_images(store):
        for name in os.listdir(path):
            want = name[:-len(".manifest.json")] if name.endswith(".manifest.json") else name
            if not is_hex(want):
                continue
            full = os.path.join(path, name)
            st = os.stat(full)
            if (st.st_dev, st.st_ino) in seen:
                continue
            seen.add((st.st_dev, st.st_ino))
            n += 1
            if sha256_file(full) != want:
                bad += 1
                print(f"CORRUPT {ref}: {name}", file=sys.stderr)
        refs[ref] = "sha256:" + sha256_file(os.path.join(path, "manifest.json"))
    if inventory and os.path.exists(inventory):
        for line in open(inventory):
            if not line.strip():
                continue
            ref, digest = line.split()
            if refs.get(ref) != digest:
                bad += 1
                print(f"MISMATCH {ref}: inventory {digest}, store {refs.get(ref, 'absent')}", file=sys.stderr)
    print(f"{len(refs)} images, {n} blobs/manifests checked, {bad} problems")
    return bad == 0


def main(argv):
    opts = {}
    while argv and argv[0].startswith("--"):
        flag = argv.pop(0)
        if flag == "--insecure":
            opts["insecure"] = True
        elif flag in ("--authfile", "--ca"):
            opts[flag[2:]] = argv.pop(0)
        else:
            sys.exit(f"unknown option {flag}")
    cmd, args = argv[0], argv[1:]
    if cmd == "store-refs":
        for ref, digest in store_refs(args[0]):
            print(f"{ref}\t{digest}")
        return 0
    if cmd == "store-dedupe":
        print(f"{store_dedupe(args[0], args[1]) >> 20} MiB deduplicated")
        return 0
    if cmd == "store-verify":
        return 0 if store_verify(args[0], args[1] if len(args) > 1 else None) else 1
    reg = Registry(args[0], **opts)
    if cmd == "ping":
        print(reg.ping())
    elif cmd == "catalog":
        print("\n".join(reg.catalog()))
    elif cmd == "tags":
        print("\n".join(sorted(reg.tags(args[1]))))
    elif cmd == "digest":
        d = reg.digest(args[1], args[2])
        print(d)
        return 0 if d else 1
    else:
        sys.exit(__doc__)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError) as e:      # HTTP errors, TLS, connection refused
        print(f"registry.py: {e}", file=sys.stderr)
        sys.exit(2)
