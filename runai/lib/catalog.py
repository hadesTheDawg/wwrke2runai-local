#!/usr/bin/env python3
"""Turn catalog/environments.yaml into copy jobs and Run:ai payloads.

  catalog.py <file> images  <registry/prefix>  -> "<source> <destination>"
  catalog.py <file> payloads <registry/prefix> -> "<name>\t<environment JSON>"
  catalog.py <file> names                      -> one catalog name per line
  catalog.py <file> builds                     -> "<name>\t<build dir>\t<image>"

Entries have either `source` (copied from upstream by 24-workload-catalog.sh)
or `build` (a directory with a Dockerfile, relative to the catalog file's
parent; built on ww1 by 26-build-image.sh).

Entries with keepSpec: true re-point an existing environment (e.g. one of
Run:ai's built-ins) at the local image and keep the rest of its spec; their
payload is {"keepSpec": true, "image": ...}.
"""
import json
import sys

import yaml

path, mode = sys.argv[1:3]
repo = sys.argv[3] if len(sys.argv) > 3 else ""
entries = yaml.safe_load(open(path))["environments"]

for e in entries:
    if ("source" in e) == ("build" in e):
        sys.exit(f"catalog entry {e['name']}: needs exactly one of source / build")
    if mode == "names":
        print(e["name"])
        continue
    if mode == "builds":
        if "build" in e:
            print(e["name"], e["build"], e["image"], sep="\t")
        continue
    image = f"{repo}/{e['image']}"
    if mode == "images":
        if "source" in e:          # built images are pushed by 26-build-image.sh
            print(e["source"], image)
        continue
    if e.get("keepSpec"):
        print(e["name"], json.dumps({"keepSpec": True, "image": image}), sep="\t")
        continue
    spec = {
        "image": image,
        "imagePullPolicy": "IfNotPresent",
        "uidGidSource": e.get("uidGidSource", "fromTheImage"),
        "environmentVariables": [{"name": k, "value": str(v)} for k, v in (e.get("env") or {}).items()],
        "connections": e.get("connections") or [],
    }
    for key in ("command", "args", "routingMethod"):
        if e.get(key) is not None:
            spec[key] = str(e[key])
    meta = {
        "name": e["name"],
        "scope": "tenant",
        "description": e.get("description"),
        "workloadSupportedTypes": {
            "workspace": e.get("workspace", True),
            "training": e.get("training", True),
            "inference": False,
            "distributed": False,
        },
    }
    print(e["name"], json.dumps({"meta": meta, "spec": spec}), sep="\t")
