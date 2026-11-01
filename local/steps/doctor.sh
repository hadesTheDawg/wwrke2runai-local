#!/bin/bash
# Tools, settings and access this machine needs. Read-only.
. "$(dirname "$0")/../lib/common.sh"
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; fail=1; }
opt() { printf '  --    %s\n' "$*"; }
fail=0

say "settings"
[ -f "$ENV_FILE" ] && ok "$ENV_FILE" || bad "no $ENV_FILE (make env)"
[ -f "$ENV_FILE" ] && [ "$(ls -l "$ENV_FILE" | cut -c5-10)" != "------" ] && opt "$ENV_FILE is readable by others (chmod 600)"
ok "RKE2_DEPLOY_REPO=$RKE2_DEPLOY_REPO"; [ -d "$RKE2_DEPLOY_REPO/overlay" ] && [ -d "$RKE2_DEPLOY_REPO/runai/values" ] || bad "RKE2_DEPLOY_REPO has no overlay/ and runai/values/"
ok "RUNAI_REPO=$RUNAI_REPO ($(df -h "$(dirname "$RUNAI_REPO")" | awk 'NR==2{print $4}') free; a full fetch is ~30 GB)"

say "tools"
for t in bash python3 helm kubectl rsync ssh openssl tar; do command -v $t >/dev/null && ok "$t" || bad "$t missing"; done
python3 -c 'import yaml' 2>/dev/null && ok "python3 PyYAML" || bad "python3 PyYAML missing (pip3 install --user pyyaml)"
if command -v skopeo >/dev/null; then ok "skopeo $(skopeo --version | awk '{print $3}')"
elif [ -n "$SKOPEO" ]; then opt "skopeo via ${SKOPEO%% *} container: push works; fetch needs REMOTE_TUNNEL=no or a native skopeo (brew install skopeo)"
else bad "skopeo missing (brew install skopeo / dnf install skopeo)"; fi
command -v gpg >/dev/null && ok "gpg (bundle signing/encryption)" || opt "gpg not installed (only for BUNDLE_GPG_*)"

say "remote system"
if [ -n "$REMOTE_SSH" ]; then
  rsh true 2>/dev/null && ok "ssh $REMOTE_SSH" || bad "ssh $REMOTE_SSH (key-based login required)"
  rsh "test -r $REMOTE_REG_DIR/password && command -v rke2 >/dev/null" 2>/dev/null && ok "registry account and rke2 on the remote" \
    || bad "remote lacks $REMOTE_REG_DIR/password or rke2"
else
  opt "REMOTE_SSH not set (fetch disabled; deploy from an unpacked bundle)"
fi

say "target"
if [ -f "$KUBECONFIG" ] && $KUBECTL get --raw /readyz >/dev/null 2>&1; then ok "cluster via $KUBECONFIG"
else opt "cluster not reachable via $KUBECONFIG (needed for deploy only)"; fi
exit $fail
