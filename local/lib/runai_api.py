#!/usr/bin/env python3
"""Run:ai REST API client for the local toolkit (stdlib + PyYAML).

Environment: RUNAI_DOMAIN, RUNAI_CA_CERT, RUNAI_ADMIN_USER,
RUNAI_ADMIN_PASSWORD_FILE, RUNAI_CLUSTER_NAME, optional RUNAI_RESOLVE_IP
(connect there instead of resolving RUNAI_DOMAIN, like curl --resolve).

  runai_api.py wait-ready                        -> until /api/v2/token works
  runai_api.py cluster                           -> uuid (registered if missing)
  runai_api.py install-values <uuid> <version>   -> runai-cluster values with the bootstrap token
  runai_api.py cluster-state <uuid>              -> Connected / ...
  runai_api.py catalog <environments.yaml> <image prefix> <pull-user> <pull-password-file> <ca|-> [prune]
  runai_api.py project-volumes <volumes.yaml>    (see local/storage/project-volumes.yaml)
"""
import http.client
import json
import os
import socket
import ssl
import subprocess
import sys
import time
import urllib.parse

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import registry  # noqa: E402

DOMAIN = os.environ["RUNAI_DOMAIN"]
CTX = ssl.create_default_context(cafile=os.environ.get("RUNAI_CA_CERT") or None)
RESOLVE = os.environ.get("RUNAI_RESOLVE_IP")


class Conn(http.client.HTTPSConnection):
    """HTTPS to RUNAI_DOMAIN, optionally connecting to RUNAI_RESOLVE_IP."""

    def connect(self):
        sock = socket.create_connection((RESOLVE or DOMAIN, 443), timeout=60)
        self.sock = CTX.wrap_socket(sock, server_hostname=DOMAIN)


class ApiError(RuntimeError):
    pass


def request(method, path, token=None, body=None, form=None):
    headers = {"Host": DOMAIN}
    data = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if form is not None:
        data = urllib.parse.urlencode(form)
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body)
        headers["Content-Type"] = "application/json"
    c = Conn(DOMAIN, context=CTX)
    c.request(method, path, body=data, headers=headers)
    r = c.getresponse()
    raw = r.read()
    if r.status >= 400:
        raise ApiError(f"{method} {path} -> {r.status}: {raw.decode(errors='replace')[:300]}")
    return json.loads(raw) if raw else None


class RunAI:
    def __init__(self):
        password = open(os.environ["RUNAI_ADMIN_PASSWORD_FILE"]).read().strip()
        self.token = request("POST", "/api/v2/token", form={
            "grant_type": "password", "client_id": "cli",
            "username": os.environ["RUNAI_ADMIN_USER"], "password": password})["access_token"]
        self._cluster = None

    def get(self, p): return request("GET", p, self.token)
    def post(self, p, b): return request("POST", p, self.token, b)
    def put(self, p, b): return request("PUT", p, self.token, b)
    def delete(self, p): return request("DELETE", p, self.token)

    @property
    def cluster(self):
        if not self._cluster:
            name = os.environ["RUNAI_CLUSTER_NAME"]
            self._cluster = next((c["uuid"] for c in self.get("/api/v1/clusters") if c["name"] == name), None)
        return self._cluster


def entries(api, path):
    return api.get(path)["entries"]


# --- cluster ------------------------------------------------------------------------
def cmd_wait_ready():
    for _ in range(90):
        try:
            RunAI()
            print(f"https://{DOMAIN}: API ready")
            return 0
        except (ApiError, OSError) as e:
            last = e
            time.sleep(10)
    sys.exit(f"API not ready: {last}")


def cmd_cluster():
    api = RunAI()
    if not api.cluster:
        uuid = api.post("/api/v1/clusters", {"name": os.environ["RUNAI_CLUSTER_NAME"]})["uuid"]
        print(f"registered cluster {os.environ['RUNAI_CLUSTER_NAME']}", file=sys.stderr)
        api._cluster = uuid
    print(api.cluster)


def cmd_install_values(uuid, version):
    info = RunAI().get(f"/api/v1/clusters/{uuid}/cluster-install-info?version={version}")
    print(yaml.safe_dump({"controlPlane": {"bootstrapToken": info["bootstrapToken"]}}))


def cmd_cluster_state(uuid):
    print(RunAI().get(f"/api/v1/clusters/{uuid}")["status"]["state"])


# --- workload catalog -----------------------------------------------------------------
def cmd_catalog(catalog, prefix, pull_user, pull_password_file, ca, prune=""):
    """Same result as runai/24-workload-catalog.sh, images already pushed."""
    api = RunAI()
    out = subprocess.run([sys.executable, os.path.join(os.environ["RKE2_DEPLOY_REPO"], "runai/lib/catalog.py"),
                          catalog, "payloads", prefix], check=True, capture_output=True, text=True).stdout
    have = {e["meta"]["name"]: e for e in entries(api, "/api/v1/asset/environment") if e["meta"]["scope"] == "tenant"}
    for line in out.splitlines():
        name, body = line.split("\t", 1)
        body = json.loads(body)
        cur = have.get(name)
        if body.get("keepSpec"):
            if not cur:
                print(f"  skip    environment {name} (keepSpec, but it does not exist)")
                continue
            full = api.get(f"/api/v1/asset/environment/{cur['meta']['id']}")
            api.put(f"/api/v1/asset/environment/{cur['meta']['id']}", {
                "meta": {"name": name, "description": full["meta"].get("description")},
                "spec": {**full["spec"], "image": body["image"]}})
            print(f"  updated environment {name} (image only)")
        elif cur:
            body["meta"] = {k: body["meta"][k] for k in ("name", "description")}
            api.put(f"/api/v1/asset/environment/{cur['meta']['id']}", body)
            print(f"  updated environment {name}")
        else:
            api.post("/api/v1/asset/environment", body)
            print(f"  created environment {name}")

    wl_registry = prefix.split("/", 1)[0]
    password = open(pull_password_file).read().strip() if pull_password_file else ""
    creds = {(c["meta"]["kind"], c["meta"]["name"]): c["meta"]["id"] for c in entries(api, "/api/v1/asset/credentials")}
    if pull_user and ("dockerRegistry", "workload-registry-pull") not in creds:
        api.post("/api/v1/asset/credentials/docker-registry", {
            "meta": {"name": "workload-registry-pull", "scope": "tenant",
                     "description": "Pull account for the workload registry"},
            "spec": {"url": f"https://{wl_registry}", "user": pull_user, "password": password}})
        print("  created credential workload-registry-pull (docker registry)")
    if pull_user and ("genericSecret", "workload-registry") not in creds:
        pairs = [("url", f"https://{wl_registry}"), ("username", pull_user), ("password", password)]
        if ca != "-":
            pairs.append(("ca.crt", open(ca).read()))
        cred = api.post("/api/v1/asset/credentials/generic-secret", {
            "meta": {"name": "workload-registry", "scope": "cluster", "clusterId": api.cluster,
                     "description": "Query access to the workload registry (url, username, password, ca.crt)"},
            "spec": {"keyValuePairs": [{"key": k, "value": v} for k, v in pairs]}})
        api.post("/api/v1/asset/datasource/secrets", {
            "meta": {"name": "workload-registry", "scope": "cluster", "clusterId": api.cluster,
                     "description": "Workload registry URL, pull credentials and CA at /etc/workload-registry"},
            "spec": {"credentialAssetId": cred["meta"]["id"], "mountPath": "/etc/workload-registry"}})
        print("  created credential + data source workload-registry -> /etc/workload-registry")

    # usable = image served by the workload registry (the GPU nodes pull nothing else)
    authfile = None
    if pull_user:
        import base64
        import tempfile
        fd, authfile = tempfile.mkstemp()
        with os.fdopen(fd, "w") as f:
            json.dump({"auths": {wl_registry: {"auth": base64.b64encode(f"{pull_user}:{password}".encode()).decode()}}}, f)
    reg = registry.Registry(wl_registry, authfile=authfile, ca=None if ca == "-" else ca)
    print(f"\nenvironments (usable = image served by {wl_registry}):")
    try:
        for e in sorted(entries(api, "/api/v1/asset/environment"), key=lambda e: e["meta"]["name"]):
            image, name = e["spec"].get("image", ""), e["meta"]["name"]
            ok = False
            if image.startswith(wl_registry + "/"):
                repo, _, tag = image[len(wl_registry) + 1:].rpartition(":")
                try:
                    ok = bool(reg.digest(repo, tag))
                except Exception:
                    ok = False
            if ok:
                print(f"  ok       {name:24} {image}")
            elif prune:
                try:
                    api.delete(f"/api/v1/asset/environment/{e['meta']['id']}")
                    print(f"  removed  {name:24} {image} (not in the workload registry)")
                except ApiError:
                    print(f"  UNUSABLE {name:24} {image} (delete refused, in use?)")
            else:
                print(f"  UNUSABLE {name:24} {image}")
    finally:
        if authfile:
            os.unlink(authfile)


# --- project volumes (Weka / CephFS / any StorageClass) -------------------------------
def kubectl(*args, stdin=None):
    cmd = os.environ.get("KUBECTL", "kubectl").split() + list(args)
    return subprocess.run(cmd, input=stdin, check=True, capture_output=True, text=True).stdout


def project_namespace(p):
    ns = (p.get("status") or {}).get("namespace")
    if ns:
        return ns
    out = kubectl("get", "ns", "-l", f"runai/queue={p['name']}", "-o", "jsonpath={.items[0].metadata.name}")
    return out or f"runai-{p['name']}"


def static_pv(v, name, drivers):
    """PersistentVolume for an existing directory on Weka or CephFS."""
    ex, d = v["existing"], drivers[v["existing"]["driver"]]
    pv = {"apiVersion": "v1", "kind": "PersistentVolume",
          "metadata": {"name": name, "labels": {"runai-local/volume": v["name"]}},
          "spec": {"capacity": {"storage": v.get("size", "1Ti")},
                   "accessModes": [v.get("accessMode", "ReadWriteMany")],
                   "persistentVolumeReclaimPolicy": "Retain",
                   "storageClassName": "",
                   "mountOptions": v.get("mountOptions") or d.get("mountOptions") or [],
                   "csi": {"driver": d["driver"]}}}
    csi = pv["spec"]["csi"]
    secret = {"name": d["secret"], "namespace": d["secretNamespace"]}
    if ex["driver"] == "weka":
        # dir/v1/<filesystem>/<path inside the filesystem>
        csi["volumeHandle"] = f"dir/v1/{ex.get('filesystem', d['filesystem'])}/{ex['path'].strip('/')}"
        for ref in ("controllerPublishSecretRef", "nodePublishSecretRef", "nodeStageSecretRef"):
            csi[ref] = dict(secret)
    elif ex["driver"] == "cephfs":
        csi["volumeHandle"] = name
        csi["nodeStageSecretRef"] = secret
        csi["volumeAttributes"] = {"clusterID": d["clusterID"], "fsName": ex.get("filesystem", d["fsName"]),
                                   "staticVolume": "true", "rootPath": ex["path"]}
    else:
        sys.exit(f"volume {v['name']}: unknown driver {ex['driver']}")
    if v.get("readOnly"):
        csi["readOnly"] = True
    return pv


def cmd_project_volumes(path):
    spec = yaml.safe_load(open(path)) or {}
    drivers = spec.get("drivers", {})
    api = RunAI()
    projects = {p["name"]: p for p in api.get(f"/api/v1/org-unit/projects?filterBy=clusterId=={api.cluster}")["projects"]}
    have = {(d["meta"]["name"], str(d["meta"].get("projectId"))): d
            for d in entries(api, "/api/v1/asset/datasource") if d["meta"]["kind"] == "pvc"}
    for v in spec.get("volumes") or []:
        targets = v["projects"] if "projects" in v else [v["project"]]
        for pname in targets:
            p = projects.get(pname)
            if not p:
                print(f"  SKIP   {v['name']}: project {pname} does not exist in cluster {os.environ['RUNAI_CLUSTER_NAME']}")
                continue
            ns = project_namespace(p)
            claim = v.get("claimName", v["name"])
            docs = []
            pvc = {"apiVersion": "v1", "kind": "PersistentVolumeClaim",
                   "metadata": {"name": claim, "namespace": ns, "labels": {"runai-local/volume": v["name"]}},
                   "spec": {"accessModes": [v.get("accessMode", "ReadWriteMany")],
                            "resources": {"requests": {"storage": v.get("size", "100Gi")}}}}
            if "existing" in v:
                pv_name = f"{v['name']}-{ns}"[:63]
                docs.append(static_pv(v, pv_name, drivers))
                pvc["spec"].update({"storageClassName": "", "volumeName": pv_name})
            else:
                pvc["spec"]["storageClassName"] = v["storageClass"]
            docs.append(pvc)
            kubectl("apply", "-f", "-", stdin=yaml.safe_dump_all(docs))
            key = (v["name"], str(p["id"]))
            if key in have:
                print(f"  have   {v['name']} -> project {pname} ({ns}/{claim}, {v['mountPath']})")
                continue
            api.post("/api/v1/asset/datasource/pvc", {
                "meta": {"name": v["name"], "scope": "project", "projectId": p["id"], "clusterId": api.cluster,
                         "description": v.get("description", f"{v.get('storageClass') or v['existing']['driver']} volume {claim}")},
                "spec": {"existingPvc": True, "claimName": claim, "path": v["mountPath"],
                         "readOnly": bool(v.get("readOnly"))}})
            print(f"  created {v['name']} -> project {pname} ({ns}/{claim}, {v['mountPath']})")


def main(argv):
    cmds = {"wait-ready": cmd_wait_ready, "cluster": cmd_cluster, "install-values": cmd_install_values,
            "cluster-state": cmd_cluster_state, "catalog": cmd_catalog, "project-volumes": cmd_project_volumes}
    if not argv or argv[0] not in cmds:
        sys.exit(__doc__)
    try:
        return cmds[argv[0]](*argv[1:]) or 0
    except ApiError as e:
        sys.exit(str(e))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
