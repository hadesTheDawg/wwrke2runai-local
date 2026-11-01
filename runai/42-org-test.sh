#!/bin/bash
# The org as its users see it. For one member of every group (logging in
# with the password from users.csv, i.e. the UI/CLI path):
#   - sees exactly its own project; submitting to another group's is refused
#   - a training from environment "ubuntu" + data source "home" runs on a
#     partition node (not ww1) as the user's UID/GID, writes
#     /home/<user>/runai-org-test.txt (checked on the NFS server) and cannot
#     read another user's home
set -euo pipefail
. "$(dirname "$0")/env.sh"

python3 - "$RUNAI_SRC/org/cluster.yaml" "$RUNAI_DIR/users.csv" <<'EOF'
import csv, os, pwd, subprocess, sys, time, yaml
sys.path.insert(0, os.path.join(os.environ["RUNAI_SRC"], "lib"))
from runai import ApiError, BASE, RunAI, _request, user_token

org = yaml.safe_load(open(sys.argv[1]))
rows = {r["user"]: r for r in csv.DictReader(open(sys.argv[2]))}
partition_nodes = {n for p in org["partitions"].values() for n in p["nodes"]}
admin = RunAI()
all_projects = {p["name"]: p["id"] for p in admin.get(f"/api/v1/org-unit/projects?filterBy=clusterId=={admin.cluster}")["projects"]}
groups = [(g, list(spec["users"])[1]) for d in org["departments"].values() for g, spec in d["groups"].items()]
kubectl = os.environ["KUBECTL"].split() if "KUBECTL" in os.environ else \
    ["/var/lib/rancher/rke2/bin/kubectl", "--kubeconfig", "/etc/rancher/rke2/rke2.yaml"]

ok = True
subs = []
for i, (group, user) in enumerate(groups):
    r = rows[user]
    tok = user_token(r["email"], r["password"])
    call = lambda m, p, b=None: _request(m, BASE + p, tok, b)
    seen = sorted(p["name"] for p in call("GET", "/api/v1/org-unit/projects")["projects"])
    env = next(e["meta"]["id"] for e in call("GET", "/api/v1/asset/environment")["entries"] if e["meta"]["name"] == "ubuntu")
    ds = next(d["meta"] for d in call("GET", "/api/v1/asset/datasource")["entries"] if d["meta"]["name"] == "home")
    for w in call("GET", "/api/v1/workloads?filterBy=name==org-test")["workloads"]:
        call("DELETE", f"/api/v1/workloads/trainings/{w['id']}")
    victim = groups[(i + 1) % len(groups)][1]
    script = (f"id; date > /home/{user}/runai-org-test.txt && echo HOME-WRITE-OK; "
              f"ls /home/{victim} >/dev/null 2>&1 && echo OTHER-HOME-READABLE || echo OTHER-HOME-DENIED")
    body = lambda proj: {"meta": {"name": "org-test", "projectId": proj, "clusterId": admin.cluster},
                         "assets": {"environment": env, "compute": None,
                                    "datasources": [{"id": ds["id"], "kind": ds["kind"]}]},
                         "specificRunParams": {"command": "sh", "args": f"-c '{script}'"}}
    other = groups[(i + 1) % len(groups)][0]
    try:
        call("POST", "/api/v2/training", body(all_projects[other]))
        denied = False
    except ApiError:
        denied = True
    time.sleep(1)
    call("POST", "/api/v2/training", body(all_projects[group]))
    subs.append((group, user, r, seen, denied, tok))

time.sleep(5)
print(f"{'group':15} {'user':12} {'uid:gid':10} {'node':8} {'own project only':17} {'other refused':14} {'home':6} {'other home'}")
for group, user, r, seen, denied, tok in subs:
    ns = f"runai-{group}"
    for _ in range(60):
        out = subprocess.run(kubectl + ["-n", ns, "get", "pods", "-l", "workloadName=org-test", "-o",
                                        "jsonpath={.items[0].status.phase} {.items[0].spec.nodeName}"],
                             capture_output=True, text=True).stdout.split()
        if out and out[0] in ("Succeeded", "Failed"):
            break
        time.sleep(3)
    phase, node = (out + ["?", "?"])[:2]
    log = subprocess.run(kubectl + ["-n", ns, "logs", "-l", "workloadName=org-test"], capture_output=True, text=True).stdout
    idline = log.splitlines()[0] if log else ""
    st = os.stat(f"/home/{user}/runai-org-test.txt") if os.path.exists(f"/home/{user}/runai-org-test.txt") else None
    owner = f"{st.st_uid}:{st.st_gid}" if st else "-"
    checks = dict(
        project=seen == [group], refused=denied, node=node in partition_nodes,
        ident=f"uid={r['uid']} gid={r['gid']}" in idline, write="HOME-WRITE-OK" in log and owner == f"{r['uid']}:{r['gid']}",
        isolation="OTHER-HOME-DENIED" in log)
    ok &= all(checks.values())
    mark = lambda b: "ok" if b else "FAIL"
    print(f"{group:15} {user:12} {owner:10} {node:8} {mark(checks['project']):17} {mark(checks['refused']):14} "
          f"{mark(checks['write'] and checks['ident']):6} {mark(checks['isolation'])}")
    for w in _request("GET", BASE + "/api/v1/workloads?filterBy=name==org-test", tok)["workloads"]:
        _request("DELETE", BASE + f"/api/v1/workloads/trainings/{w['id']}", tok)
sys.exit(0 if ok else 1)
EOF
