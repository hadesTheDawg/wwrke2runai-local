#!/usr/bin/env python3
"""sshare/sreport-style view of Run:ai quotas, from the live API.

Per partition (node pool): guaranteed quota, limit and over-quota weight of
every department and group (project), next to the GPUs Run:ai has allocated
and the GPUs requested (allocated + pending). Then GPU use per user.
"""
import collections
import os
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runai import RunAI  # noqa: E402

org = yaml.safe_load(open(sys.argv[1]))
parts = list(org["partitions"])
api = RunAI()
cid = api.cluster


def num(x):
    return "-" if x in (None, -1) else (f"{x:g}" if isinstance(x, (int, float)) else str(x))


def quota(unit):
    return {r["nodePool"]["name"]: r["gpu"] for r in unit.get("resources", [])}


def usage(unit):
    out = {}
    for s in (unit.get("status") or {}).get("nodePoolQuotaStatuses", []):
        out[s["nodePoolName"]] = ((s.get("allocated") or {}).get("gpu", 0), (s.get("requested") or {}).get("gpu", 0))
    return out


depts = {d["name"]: d for d in api.get(f"/api/v1/org-unit/departments?filterBy=clusterId=={cid}")["departments"]}
projects = {p["name"]: p for p in api.get(f"/api/v1/org-unit/projects?filterBy=clusterId=={cid}")["projects"]}

cap = {p: len(d["nodes"]) * d["gpu"]["count"] for p, d in org["partitions"].items()}
print("PARTITIONS  " + "   ".join(f"{p}: {cap[p]} GPUs ({', '.join(d['nodes'])})" for p, d in org["partitions"].items()))
print()
cols = "".join(f" | {p + ' quota/limit/w':>18} {'alloc/req':>10}" for p in parts)
print(f"{'ACCOUNT':18}{cols}")
print("-" * (18 + len(cols)))
totals = collections.defaultdict(lambda: [0.0, 0.0])
for dname, dspec in org["departments"].items():
    rows = []
    dsum = collections.defaultdict(lambda: [0.0, 0.0])
    for gname in dspec["groups"]:
        p = projects.get(gname)
        if not p:
            continue
        q, u = quota(p), usage(p)
        cells = ""
        for part in parts:
            g = q.get(part, {})
            a, r = u.get(part, (0, 0))
            dsum[part][0] += a
            dsum[part][1] += r
            over = "+" if a > (g.get("deserved") or 0) else " "
            cells += (f" | {num(g.get('deserved')):>5}/{num(g.get('limit')):>4}/{num(g.get('overQuotaWeight')):>4}    "
                      f"{num(a):>4}/{num(r):<4}{over}")
        rows.append(f"  {gname:16}{cells}")
    q = quota(depts.get(dname, {}))
    cells = ""
    for part in parts:
        g = q.get(part, {})
        a, r = dsum[part]
        totals[part][0] += a
        totals[part][1] += r
        over = "+" if a > (g.get("deserved") or 0) else " "
        cells += (f" | {num(g.get('deserved')):>5}/{num(g.get('limit')):>4}/{num(g.get('overQuotaWeight')):>4}    "
                  f"{num(a):>4}/{num(r):<4}{over}")
    print(f"{dname:18}{cells}")
    print("\n".join(rows))
cells = "".join(f" | {'cap ' + str(cap[part]):>18} {num(totals[part][0]):>4}/{num(totals[part][1]):<5}" for part in parts)
print("-" * (18 + len(cols)))
print(f"{'TOTAL':18}{cells}")
print("  + = allocated above guaranteed quota (over-quota, preemptible); alloc/req: req includes pending")

# --- per user ------------------------------------------------------------------------------
print()
per_user = collections.defaultdict(lambda: collections.defaultdict(float))
info = {}
pending = collections.Counter()
for w in api.get(f"/api/v1/workloads?filterBy=clusterId=={cid}&limit=500")["workloads"]:
    user = w.get("submittedBy") or "?"
    info[user] = (w.get("projectName"), w.get("departmentName"))
    if w.get("phase") != "Running":
        if w.get("phase") in ("Pending", "Creating", "Initializing"):
            pending[user] += 1
        continue
    gpus = (w.get("allocatedResources") or {}).get("gpu") or 0
    if not gpus:
        continue
    pods = api.get(f"/api/v1/workloads/{w['id']}/pods")["pods"]
    pool = (pods[0].get("currentNodePool") if pods else None) or "?"
    per_user[user][pool] += gpus
users = sorted(set(per_user) | set(pending))
print(f"{'USER':28} {'GROUP':15} {'DEPARTMENT':11}" + "".join(f" {p + ' GPUs':>10}" for p in parts) + f" {'pending':>8}")
for user in users:
    proj, dept = info.get(user, ("?", "?"))
    print(f"{user:28} {proj or '?':15} {dept or '?':11}" + "".join(f" {num(per_user[user].get(p, 0)):>10}" for p in parts)
          + f" {pending[user]:>8}")
if not users:
    print("  (no GPU workloads)")
