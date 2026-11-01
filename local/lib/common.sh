# Shared settings for the local toolkit (sourced by every local/steps/* script).
#
# Settings come from, in order of precedence:
#   1. the environment / `make VAR=value`
#   2. $ENV_FILE (default: <repo root>/.env, copy of .env.example)
#   3. the defaults below
# Runs on macOS (bash 3.2, BSD tools) and Linux.
set -euo pipefail

LOCAL_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$LOCAL_SRC/.." && pwd)"
: "${ENV_FILE:=$ROOT/.env}"

# KEY=VALUE lines; a key already set in the environment wins
load_env() {
  local line key
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    case "$key" in *[!A-Za-z0-9_]*|[0-9]*|'') continue ;; esac
    eval "[ -n \"\${$key+x}\" ]" && continue
    eval "export $line"
  done < "$1"
}
load_env "$ENV_FILE"

abspath() {   # relative paths are relative to the repo root
  local p="$1"; case "$p" in /*) ;; *) p="$ROOT/$p" ;; esac
  if [ -d "$p" ]; then (cd "$p" && pwd); else echo "$p" | sed -e 's#/\./#/#g' -e 's#/\.$##'; fi
}

# --- where things live --------------------------------------------------------
: "${RKE2_DEPLOY_REPO:=$ROOT}"                 # overlays, values, catalog, org
: "${RUNAI_REPO:=$ROOT/_runai-repo}"           # local artifact repository
RKE2_DEPLOY_REPO="$(abspath "$RKE2_DEPLOY_REPO")"
RUNAI_REPO="$(abspath "$RUNAI_REPO")"
IMAGES="$RUNAI_REPO/images"                    # <repo>@<tag>/ (skopeo dir:), blobs hardlinked
CHARTS="$RUNAI_REPO/charts"
SECRETS="$RUNAI_REPO/secrets"                  # 0700, never bundled
STATE="$RUNAI_REPO/state"                      # inventories, facts, logs

# --- source: the remote system everything is pulled from ---------------------
: "${REMOTE_SSH:=}"
: "${REMOTE_SSH_OPTS:=}"
: "${REMOTE_REGISTRY:=10.10.172.1:5000}"
: "${REMOTE_REG_DIR:=/etc/rke2-registry}"
: "${REMOTE_RUNAI_WORK:=/var/lib/runai-deploy}"
: "${REMOTE_KUBECTL:=/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml}"
: "${REMOTE_TUNNEL:=yes}"
: "${REMOTE_TUNNEL_PORT:=15000}"
: "${FETCH_INCLUDE:=}"
: "${FETCH_EXCLUDE:=^charts/}"
: "${FETCH_RKE2_RPMS:=yes}"
: "${TARGET_ARCH:=amd64}"

# --- target: the existing RKE2 GPU cluster ------------------------------------
: "${KUBECONFIG:=$HOME/.kube/config}"
: "${TARGET_REGISTRY:=}"
: "${TARGET_REGISTRY_PREFIX:=}"
: "${TARGET_REGISTRY_USER:=}"
: "${TARGET_REGISTRY_PASSWORD_FILE:=}"
: "${TARGET_REGISTRY_CA:=}"
: "${TARGET_REGISTRY_TLS_VERIFY:=true}"
: "${TARGET_WORKLOAD_REGISTRY:=$TARGET_REGISTRY}"
: "${TARGET_WORKLOAD_PULL_USER:=$TARGET_REGISTRY_USER}"
: "${TARGET_WORKLOAD_PULL_PASSWORD_FILE:=$TARGET_REGISTRY_PASSWORD_FILE}"

# --- Run:ai -------------------------------------------------------------------
: "${RUNAI_DOMAIN:=}"
: "${RUNAI_TLS_CERT:=}"
: "${RUNAI_TLS_KEY:=}"
: "${RUNAI_CA_CERT:=}"
: "${RUNAI_RESOLVE_IP:=}"
: "${RUNAI_ADMIN_USER:=}"
: "${RUNAI_ADMIN_PASSWORD_FILE:=$SECRETS/runai-admin-password}"
: "${RUNAI_CLUSTER_NAME:=gpu}"
: "${RUNAI_INGRESS_CLASS:=nginx}"
: "${RUNAI_SIZING:=prod}"
: "${RUNAI_SUBDOMAINS:=yes}"
: "${RUNAI_PRUNE_ENVIRONMENTS:=yes}"
: "${RUNAI_CATALOG:=$RKE2_DEPLOY_REPO/runai/catalog/environments.yaml}"
: "${SITE_VALUES_DIR:=}"
: "${WL_REG_PREFIX:=workloads}"

# --- components -----------------------------------------------------------------
: "${INSTALL_PROMETHEUS:=auto}"
: "${GPU_OPERATOR:=skip}"
: "${WEKA_CSI:=no}"
: "${CEPHFS_CSI:=no}"
: "${PROJECT_VOLUMES:=$LOCAL_SRC/storage/project-volumes.yaml}"

export RKE2_DEPLOY_REPO RUNAI_REPO KUBECONFIG RUNAI_DOMAIN RUNAI_CA_CERT RUNAI_RESOLVE_IP \
       RUNAI_ADMIN_USER RUNAI_ADMIN_PASSWORD_FILE RUNAI_CLUSTER_NAME

case "$TARGET_ARCH" in amd64|x86_64) RPM_ARCH=x86_64 ;; arm64|aarch64) RPM_ARCH=aarch64 ;; *) RPM_ARCH=$TARGET_ARCH ;; esac

# --- helpers ----------------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { local v; for v; do eval "[ -n \"\${$v:-}\" ]" || die "$v is not set (see .env.example)"; done; }
is_yes() { case "${1:-}" in y|yes|true|1|on) return 0 ;; *) return 1 ;; esac; }
mkpriv() { mkdir -p "$@"; chmod 700 "$@"; }

if command -v sha256sum >/dev/null 2>&1; then SHA256="sha256sum"; else SHA256="shasum -a 256"; fi

KUBECTL="kubectl --kubeconfig $KUBECONFIG"
HELM="helm --kubeconfig $KUBECONFIG"
PY="python3"
LIB="$LOCAL_SRC/lib"

# skopeo: native, or the upstream container through podman/docker. Every
# path handed to it lives under $RUNAI_REPO or the repo, both mounted 1:1.
if command -v skopeo >/dev/null 2>&1; then
  SKOPEO="skopeo"
else
  : "${SKOPEO_IMAGE:=quay.io/skopeo/stable:latest}"
  for _rt in podman docker; do
    if command -v $_rt >/dev/null 2>&1; then
      SKOPEO="$_rt run --rm -v $RUNAI_REPO:$RUNAI_REPO -v $ROOT:$ROOT $SKOPEO_IMAGE"; break
    fi
  done
  : "${SKOPEO:=}"
fi

# store_copy <source ref> <image dir> [skopeo options]: copy into a temp dir,
# move into place when complete, share its layers with the rest of the store
store_copy() {
  local src=$1 dir=$2 tmp; shift 2
  mkdir -p "$IMAGES/.tmp"
  tmp=$(mktemp -d "$IMAGES/.tmp/copy.XXXXXX")
  if ! $SKOPEO copy -q --retry-times 3 --multi-arch all --preserve-digests "$@" "$src" "dir:$tmp"; then
    rm -rf "$tmp"; return 1
  fi
  rm -rf "$dir"; mkdir -p "$(dirname "$dir")"; mv "$tmp" "$dir"
  $PY "$LIB/registry.py" store-dedupe "$IMAGES" "$dir" >/dev/null
}

# ssh to the remote system
rsh() { need REMOTE_SSH; ssh -o BatchMode=yes $REMOTE_SSH_OPTS "$REMOTE_SSH" "$@"; }

# authfile <file> <registry> <user> <password-file>: containers-auth.json, 0600
authfile() {
  ( umask 077; $PY -c 'import base64,json,sys
reg, user, pw = sys.argv[2], sys.argv[3], open(sys.argv[4]).read().strip()
json.dump({"auths": {reg: {"auth": base64.b64encode(f"{user}:{pw}".encode()).decode()}}}, open(sys.argv[1], "w"))' "$@" )
}

# target registry path for an image path: honours TARGET_REGISTRY_PREFIX
target_ref() { echo "$TARGET_REGISTRY/${TARGET_REGISTRY_PREFIX:+$TARGET_REGISTRY_PREFIX/}$1"; }

# chart_tgz <name>: the chart archive in the local repo (one version per chart;
# <NAME>_VERSION picks one when several are present)
chart_tgz() {
  local n=$1 var files
  var="$(echo "$n" | tr 'a-z-' 'A-Z_')_VERSION"
  eval "local want=\${$var:-}"
  if [ -n "$want" ]; then
    [ -s "$CHARTS/$n-$want.tgz" ] || die "chart $n $want not in $CHARTS"
    echo "$CHARTS/$n-$want.tgz"; return
  fi
  files=$(ls "$CHARTS"/"$n"-[0-9v]*.tgz 2>/dev/null || true)
  [ -n "$files" ] || die "chart $n not in $CHARTS (run make fetch)"
  [ "$(echo "$files" | wc -l | tr -d ' ')" = 1 ] || die "several $n charts in $CHARTS; set $var"
  echo "$files"
}

# "-f <repo values>/<name>.yaml [-f <name>-<sizing>.yaml] [-f <site>/<name>.yaml]"
values() {
  local f="$RKE2_DEPLOY_REPO/runai/values/$1" out=""
  [ -f "$f.yaml" ] && out="-f $f.yaml"
  [ -f "$f-$RUNAI_SIZING.yaml" ] && out="$out -f $f-$RUNAI_SIZING.yaml"
  [ -n "$SITE_VALUES_DIR" ] && [ -f "$SITE_VALUES_DIR/$1.yaml" ] && out="$out -f $SITE_VALUES_DIR/$1.yaml"
  echo "$out"
}

ensure_ns() { $KUBECTL create ns "$1" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null; }

# Run:ai version = the artifact lock that was fetched
runai_version() {
  local lock
  lock=$(ls "$RUNAI_REPO"/runai/runai-*-standard-linux-*.yaml 2>/dev/null | head -1)
  [ -n "$lock" ] || die "no Run:ai artifact lock in $RUNAI_REPO/runai (run make fetch)"
  lock=${lock##*/runai-}; echo "${lock%%-standard-*}"
}
