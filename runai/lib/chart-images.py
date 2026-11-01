#!/usr/bin/env python3
"""Print every container image referenced by rendered manifests on stdin.

Handles plain `image: repo:tag` fields, the split form used by the NVIDIA
GPU operator's ClusterPolicy (`repository` + `image` + `version`), skipping
components that are `enabled: false`, and operator flags that carry an image
(e.g. prometheus-operator's `--prometheus-config-reloader=<image>`).
"""
import re
import sys

import yaml

images = set()
IMAGE_FLAG = re.compile(r"^--[\w.-]*(image|reloader)[\w.-]*=([\w.-]+(:\d+)?/[\w./-]+[:@][\w.:-]+)$")


def walk(node):
    if isinstance(node, dict):
        if node.get("enabled") is False:
            return
        img = node.get("image")
        if isinstance(img, str) and img:
            if "repository" in node and "version" in node and "/" not in img:
                if node["repository"] and node["version"]:
                    images.add(f'{node["repository"]}/{img}:{node["version"]}')
            else:
                images.add(img)
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
    elif isinstance(node, str):
        m = IMAGE_FLAG.match(node)
        if m:
            images.add(m.group(2))


for doc in yaml.safe_load_all(sys.stdin):
    walk(doc)
print("\n".join(sorted(images)))
