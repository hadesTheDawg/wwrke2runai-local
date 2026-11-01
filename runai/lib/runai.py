"""Small Run:ai + Keycloak REST client for the org scripts (stdlib only).

Environment (exported by env.sh / the calling script):
  RUNAI_DOMAIN, RUNAI_DIR, RUNAI_ADMIN_USER, RUNAI_CLUSTER_NAME
  KEYCLOAK_ADMIN_PASSWORD (Keycloak "admin" in the master realm)
"""
import json
import os
import ssl
import urllib.error
import urllib.parse
import urllib.request

DOMAIN = os.environ["RUNAI_DOMAIN"]
BASE = f"https://{DOMAIN}"
CTX = ssl.create_default_context(cafile=os.path.join(os.environ["RUNAI_DIR"], "ca.crt"))


class ApiError(RuntimeError):
    pass


def _request(method, url, token=None, body=None, form=None):
    headers = {}
    data = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raise ApiError(f"{method} {url.replace(BASE, '')} -> {e.code}: {e.read().decode()[:300]}") from None


def _token(url, form):
    return _request("POST", url, form=form)["access_token"]


class RunAI:
    """Run:ai REST API as the admin user."""

    def __init__(self):
        with open(os.path.join(os.environ["RUNAI_DIR"], "admin-password")) as f:
            password = f.read().strip()
        self.token = _token(f"{BASE}/api/v2/token", {
            "grant_type": "password", "client_id": "cli",
            "username": os.environ["RUNAI_ADMIN_USER"], "password": password})
        self.cluster = next(c["uuid"] for c in self.get("/api/v1/clusters")
                            if c["name"] == os.environ["RUNAI_CLUSTER_NAME"])

    def get(self, path):
        return _request("GET", BASE + path, self.token)

    def post(self, path, body):
        return _request("POST", BASE + path, self.token, body)

    def put(self, path, body):
        return _request("PUT", BASE + path, self.token, body)

    def delete(self, path):
        return _request("DELETE", BASE + path, self.token)

    def node_pools(self):
        return {p["name"]: p for p in self.get(f"/api/v1/node-pools?filterBy=clusterId=={self.cluster}")["nodepools"]}


class Keycloak:
    """Keycloak admin API for Run:ai's realm (local-user attributes, passwords)."""

    def __init__(self, realm="runai"):
        self.token = _token(f"{BASE}/auth/realms/master/protocol/openid-connect/token", {
            "grant_type": "password", "client_id": "admin-cli",
            "username": "admin", "password": os.environ["KEYCLOAK_ADMIN_PASSWORD"]})
        self.base = f"{BASE}/auth/admin/realms/{realm}"

    def user(self, user_id):
        return _request("GET", f"{self.base}/users/{user_id}", self.token)

    def update_user(self, user_id, rep):
        _request("PUT", f"{self.base}/users/{user_id}", self.token, rep)

    def set_password(self, user_id, password):
        _request("PUT", f"{self.base}/users/{user_id}/reset-password", self.token,
                 {"type": "password", "value": password, "temporary": False})


def user_token(username, password):
    """Log in as a regular user (what a researcher's UI/CLI session gets)."""
    return _token(f"{BASE}/api/v2/token", {
        "grant_type": "password", "client_id": "cli", "username": username, "password": password})
