#!/usr/bin/env python3
"""List images and charts from a Run:ai ArtifactLock.

  lock-images.py <lock.yaml> images   ->  "<source repo:tag> <index digest>"
  lock-images.py <lock.yaml> charts   ->  "<name> <version> <url> <digest>"
"""
import sys

import yaml

lock = yaml.safe_load(open(sys.argv[1]))["spec"]
if sys.argv[2] == "images":
    for group in lock["imageLocks"]:
        for img in group["images"]:
            print(img["source"], img["indexDigest"])
elif sys.argv[2] == "charts":
    for chart in lock["charts"]:
        print(chart["name"], chart["version"], chart["source"], chart["digest"])
