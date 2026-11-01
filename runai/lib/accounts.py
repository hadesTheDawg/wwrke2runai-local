#!/usr/bin/env python3
"""Apply org/cluster.yaml accounts to Linux (ww1) and Run:ai. Idempotent.

  accounts.py <cluster.yaml> <users.csv>

users.csv (root-only) keeps every generated password; each run re-applies
it to Linux and verifies it in Run:ai (setting it where login fails).
RESET_PASSWORDS=1 issues new ones.
"""
import csv
import grp
import os
import pwd
import secrets
import string
import subprocess
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from runai import ApiError, Keycloak, RunAI, user_token  # noqa: E402

ROLE_AI_PRACTITIONER = 20      # GET /api/v2/authorization/roles
ROLE_PROJECT_ADMIN = 22

org_file, csv_file = sys.argv[1:3]
org = yaml.safe_load(open(org_file))
domain = org["email_domain"]
partitions = list(org["partitions"])


def password():
    """16 chars incl. upper, lower, digit and special (Keycloak/Linux policy)."""
    pools = [string.ascii_uppercase, string.ascii_lowercase, string.digits, "!#%+=-_"]
    chars = [secrets.choice(p) for p in pools]
    chars += [secrets.choice(string.ascii_letters + string.digits) for _ in range(12)]
    secrets.SystemRandom().shuffle(chars)
    return "".join(chars)


# --- flatten the account tree --------------------------------------------------
users = []          # dicts: user, name, email, uid, gid, group, department, pi
groups = {}         # group -> (gid, department, spec)
for dept, dspec in org["departments"].items():
    for gname, g in dspec["groups"].items():
        groups[gname] = (g["gid"], dept, g)
        for i, (user, name) in enumerate(g["users"].items(), start=1):
            users.append(dict(user=user, name=name, email=f"{user}@{domain}", uid=g["gid"] + i,
                              gid=g["gid"], group=gname, department=dept, pi=(user == g.get("pi"))))

known = {}
if os.path.exists(csv_file):
    with open(csv_file) as f:
        known = {r["user"]: r["password"] for r in csv.DictReader(f)}
reset = os.environ.get("RESET_PASSWORDS") == "1"
for u in users:
    u["password"] = password() if reset or u["user"] not in known else known[u["user"]]

# Written first: the file is the source of truth, every run (re)applies it to
# Linux and Keycloak, so a failed run never leaves the two out of sync.
old_umask = os.umask(0o077)
with open(csv_file, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["user", "name", "email", "uid", "gid", "group", "department", "role", "password"])
    for u in users:
        w.writerow([u["user"], u["name"], u["email"], u["uid"], u["gid"], u["group"], u["department"],
                    "pi" if u["pi"] else "member", u["password"]])
os.umask(old_umask)
os.chmod(csv_file, 0o600)


def run(*cmd, stdin=None):
    subprocess.run(cmd, input=stdin, text=True, check=True, stdout=subprocess.DEVNULL)


# --- Linux on ww1 (nodes get them via Warewulf syncuser) ----------------------------
print("Linux groups/users on ww1:")
for gname, (gid, _, _) in groups.items():
    try:
        existing = grp.getgrnam(gname).gr_gid
        if existing != gid:
            sys.exit(f"group {gname} exists with gid {existing}, cluster.yaml says {gid}")
    except KeyError:
        run("groupadd", "-g", str(gid), gname)
created = 0
for u in users:
    try:
        pw = pwd.getpwnam(u["user"])
        if (pw.pw_uid, pw.pw_gid) != (u["uid"], u["gid"]):
            sys.exit(f"user {u['user']} exists as {pw.pw_uid}:{pw.pw_gid}, cluster.yaml says {u['uid']}:{u['gid']}")
    except KeyError:
        run("useradd", "-u", str(u["uid"]), "-g", str(u["gid"]), "-m", "-d", f"/home/{u['user']}",
            "-s", "/bin/bash", "-c", u["name"], u["user"])
        created += 1
run("chpasswd", stdin="".join(f"{u['user']}:{u['password']}\n" for u in users))
print(f"  {len(groups)} groups, {len(users)} users ({created} created), homes in /home (NFS)")

# --- Run:ai org units with quotas ---------------------------------------------------
api = RunAI()
pools = api.node_pools()
missing = [p for p in partitions if p not in pools]
if missing:
    sys.exit(f"node pools missing in Run:ai: {missing} (run 40-partitions.sh)")


def resources(gpus, limit=None, weight=1):
    """One entry per node pool; pools without a quota get 0 guaranteed."""
    out = []
    for name, pool in pools.items():
        out.append({"nodePool": {"id": pool["id"], "name": name},
                    "gpu": {"deserved": (gpus or {}).get(name, 0),
                            "limit": (limit or {}).get(name, -1) if limit else -1,
                            "overQuotaWeight": weight}})
    return out


def upsert(kind, name, body, res, default_pools=None):
    """Create, or update quota + default node pools (PUT needs both together)."""
    path = f"/api/v1/org-unit/{kind}"
    have = {x["name"]: x for x in api.get(f"{path}?filterBy=clusterId=={api.cluster}")[kind]}
    spec = {"resources": res}
    if default_pools:
        spec["defaultNodePools"] = default_pools
    if name in have:
        api.put(f"{path}/{have[name]['id']}", spec)
        return have[name]["id"], "updated"
    return api.post(path, {**body, **spec})["id"], "created"


site_default = org.get("default_partitions")

# Run:ai's built-in department "default" (parent of ad-hoc projects such as
# "smoke" or projects created in the UI) must also default to the partitions:
# after partitioning, node pool "default" holds only the management node.
if site_default:
    builtin = next((d for d in api.get(f"/api/v1/org-unit/departments?filterBy=clusterId=={api.cluster}")["departments"]
                    if d["name"] == "default"), None)
    if builtin:
        api.put(f"/api/v1/org-unit/departments/{builtin['id']}", {
            "resources": [{"nodePool": r["nodePool"], "gpu": r["gpu"]} for r in builtin["resources"]],
            "defaultNodePools": site_default})
print(f"Run:ai departments/projects (GPU quota per partition, default partitions {site_default}):")
dept_ids = {}
for dept, dspec in org["departments"].items():
    dept_ids[dept], how = upsert("departments", dept, {"name": dept, "clusterId": api.cluster},
                                 resources(dspec.get("gpus"), dspec.get("limit"), dspec.get("weight", 1)),
                                 dspec.get("default_partitions", site_default))
    print(f"  {how:7} department {dept:10} {dspec.get('gpus')}")
project_ids = {}
for gname, (gid, dept, g) in groups.items():
    project_ids[gname], how = upsert("projects", gname,
                                     {"name": gname, "clusterId": api.cluster, "parentId": dept_ids[dept]},
                                     resources(g.get("gpus"), g.get("limit"), g.get("weight", 1)),
                                     g.get("default_partitions"))
    print(f"  {how:7} project    {gname:15} gid {gid}  {g.get('gpus')} limit {g.get('limit')} weight {g.get('weight', 1)}")

# --- Run:ai users: password + directory attributes (UID/GID/groups claims) ------------
kc = Keycloak()
runai_users = {u["username"]: u["id"] for u in api.get("/api/v1/users")}
new = reset_count = 0
for u in users:
    uid = runai_users.get(u["email"])
    if not uid:
        uid = api.post("/api/v1/users", {"email": u["email"]})["id"]
        new += 1
    rep = kc.user(uid)
    first, _, last = u["name"].partition(" ")
    rep.update(firstName=first, lastName=last, requiredActions=[])
    rep.setdefault("attributes", {}).update({
        "UID": [str(u["uid"])], "GID": [str(u["gid"])],
        "GROUPS": [u["group"]], "SUPPLEMENTARYGROUPS": [str(u["gid"])]})
    kc.update_user(uid, rep)
    # Keycloak keeps a 10-password history, so re-setting the same password
    # fails: only set it when logging in with the stored one does not work.
    try:
        user_token(u["email"], u["password"])
    except ApiError:
        kc.set_password(uid, u["password"])
        user_token(u["email"], u["password"])
        reset_count += 1
print(f"Run:ai users: {len(users)} ({new} created, {reset_count} passwords set, all {len(users)} logins verified);"
      " claims uid/gid/groups set")

# --- access: group -> AI practitioner on its project, PI -> Project administrator ------
rules, offset = [], 0
while True:                                    # paged, max 500 per call
    page = api.get(f"/api/v1/authorization/access-rules?limit=500&offset={offset}")["accessRules"]
    rules += page
    if len(page) < 500:
        break
    offset += 500
have = {(r["subjectType"], r["subjectId"], r["roleId"], str(r["scopeId"])) for r in rules}
added = 0
wanted = [("group", g, ROLE_AI_PRACTITIONER, project_ids[g]) for g in groups]
wanted += [("user", u["email"], ROLE_PROJECT_ADMIN, project_ids[u["group"]]) for u in users if u["pi"]]
for stype, sid, role, scope in wanted:
    if (stype, sid, role, str(scope)) in have:
        continue
    api.post("/api/v1/authorization/access-rules", {
        "subjectType": stype, "subjectId": sid, "roleId": role,
        "scopeType": "project", "scopeId": str(scope), "clusterId": api.cluster})
    added += 1
print(f"access rules: {len(wanted)} wanted, {added} added (groups -> AI practitioner, PIs -> Project administrator)")
print(f"credentials: {csv_file} (root only)")
