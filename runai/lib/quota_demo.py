#!/usr/bin/env python3
"""Quota demo jobs, submitted by real users (see 46-quota-demo.sh).

  quota_demo.py <users.csv> run|cleanup
"""
import csv
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runai import BASE, RunAI, _request, user_token  # noqa: E402

rows = {r["user"]: r for r in csv.DictReader(open(sys.argv[1]))}
mode = sys.argv[2]
admin = RunAI()
IMAGE = f"{os.environ['WL_REGISTRY']}/{os.environ['WL_REG_PREFIX']}/ubuntu:24.04"
NAME = "quota-demo"


def whole(n):
    return {"gpuDevicesRequest": n}


def frac(f):
    return {"gpuRequestType": "portion", "gpuPortionRequest": f}


FIRST = [("rbianchi", "a100", whole(1)), ("lperez", "a100", frac(0.5)), ("bharrington", "a100", whole(2)),
         ("odiallo", "a100", whole(2)), ("skumar", "h100", whole(2))]
LAST = [("hkim", "h100", frac(0.5))]


def session(user):
    r = rows[user]
    tok = user_token(r["email"], r["password"])
    return tok, next(p["id"] for p in _request("GET", BASE + "/api/v1/org-unit/projects", tok)["projects"])


def phases():
    return {w["submittedBy"].split("@")[0]: w["phase"]
            for w in admin.get(f"/api/v1/workloads?filterBy=name=={NAME}")["workloads"]}


def cleanup():
    for user, _, _ in FIRST + LAST:
        tok, _ = session(user)
        for w in _request("GET", BASE + f"/api/v1/workloads?filterBy=name=={NAME}", tok)["workloads"]:
            _request("DELETE", BASE + f"/api/v1/workloads/trainings/{w['id']}", tok)
    for w in admin.get("/api/v1/workloads?filterBy=name==probe-gpu")["workloads"]:
        admin.delete(f"/api/v1/workloads/trainings/{w['id']}")
    for _ in range(40):
        if not admin.get(f"/api/v1/workloads?filterBy=name=={NAME}")["workloads"]:
            return
        time.sleep(3)


def submit(batch):
    for user, pool, compute in batch:
        tok, proj = session(user)
        _request("POST", BASE + "/api/v1/workloads/trainings", tok, {
            "name": NAME, "projectId": proj, "clusterId": admin.cluster,
            "spec": {"image": IMAGE, "command": "sleep", "args": "3600", "compute": compute, "nodePools": [pool]}})
        print(f"  {user:12} -> {pool} {compute}")


if mode == "cleanup":
    cleanup()
    print("demo jobs removed")
    sys.exit()

cleanup()
print("submitting as users:")
submit(FIRST)
for _ in range(40):
    p = phases()
    if p.get("skumar") == "Running" and len(p) == len(FIRST):
        break
    time.sleep(5)
print("  phases:", phases())
print("reclaim: bio-imaging submits within its guaranteed H100 share")
submit(LAST)
for _ in range(36):
    if phases().get("hkim") == "Running":
        break
    time.sleep(5)
time.sleep(20)          # let the org-unit accounting catch up
print("  phases:", phases())
