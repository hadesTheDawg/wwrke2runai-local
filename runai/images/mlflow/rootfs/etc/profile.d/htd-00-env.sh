# HTD Researcher: who/where am I. Sourced by login shells, by
# /etc/bash.bashrc (Run:ai UI terminals are non-login) and by htd-start.
# Safe under `set -u`.
[ -n "${HTD_ENV_LOADED:-}" ] && return 0
HTD_ENV_LOADED=1

# Site users (uidGidSource: fromIdpToken) have no passwd entry in the image
# and HOME=/; their NFS home is mounted at /home/<name> and owned by them.
htd_find_home() {
  if [ -n "${HOME:-}" ] && [ "$HOME" != / ] && [ -w "$HOME" ]; then echo "$HOME"; return; fi
  for d in /home/*/; do
    [ -O "$d" ] && { echo "${d%/}"; return; }
  done
  echo "/tmp/htd-$(id -u)"
}
HTD_HOME=$(htd_find_home)
mkdir -p "$HTD_HOME" 2>/dev/null
export HOME="$HTD_HOME" HTD_HOME
export HTD_USER="${USER:-$(id -un 2>/dev/null || basename "$HTD_HOME")}"
[ "$HTD_USER" = "$(id -u)" ] && HTD_USER=$(basename "$HTD_HOME")
export USER="$HTD_USER"

ns_file=/var/run/secrets/kubernetes.io/serviceaccount/namespace
ns=$( [ -r "$ns_file" ] && cat "$ns_file" || true)
export HTD_PROJECT="${RUNAI_PROJECT:-${ns#runai-}}"
export HTD_WORKLOAD="${RUNAI_JOB_NAME:-${HOSTNAME%-0-0}}"
unset ns ns_file

export HTD_MLFLOW_DIR="${HTD_MLFLOW_DIR:-$HTD_HOME/mlflow}"
export MLFLOW_TRACKING_URI="${MLFLOW_TRACKING_URI:-http://127.0.0.1:${MLFLOW_PORT:-5000}}"
if [ -n "$HTD_PROJECT" ] && [ -n "${RUNAI_JOB_NAME:-}" ]; then
  export HTD_MLFLOW_URL="https://${HTD_PROJECT}-${RUNAI_JOB_NAME}.${HTD_RUNAI_DOMAIN:-runai.htd.local}"
fi
