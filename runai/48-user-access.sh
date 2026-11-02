#!/bin/bash
# Command-line access for researchers on the login node (ww1):
#   - runai CLI, downloaded from the control plane (cli-exposer serves the
#     binaries offline) into /usr/local/bin, plus a profile.d hook that points
#     every user's CLI at https://$RUNAI_DOMAIN on first use
#   - kubectl (RKE2's binary) into /usr/local/bin
#   - kube-apiserver accepts Run:ai (Keycloak) tokens: OIDC flags in an RKE2
#     config drop-in. Run:ai already binds each project's access-rule groups
#     to ClusterRole runai-ai-practitioner-ns in the project namespace (jobs,
#     deployments, services, pods/exec, pods/portforward, ...); this makes
#     those RoleBindings usable. Users get a skeleton ~/.kube/config on
#     first login; `runai kubeconfig set` adds their token.
#     Restarts rke2-server (API down ~1 min; running pods are not affected).
#   - the guide's example manifests in /usr/local/share/runai/examples
#   - htd-runai (researcher TUI over the CLI, htd-runai-howto.md) in /usr/local/bin
# Self-test: a site user logs in with the CLI and checks namespace access.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$RUNAI_SRC/lib/api.sh"

ARCH=$(uname -m); case "$ARCH" in aarch64) ARCH=arm64 ;; x86_64) ARCH=amd64 ;; esac

# --- runai CLI --------------------------------------------------------------
runai_login
_curl -o /tmp/runai.$$ -H "Authorization: Bearer $RUNAI_TOKEN" \
  "$RUNAI_URL/api/v1/cli-exposer/dist/linux/$ARCH/runai"
install -m 755 /tmp/runai.$$ /usr/local/bin/runai && rm -f /tmp/runai.$$
echo "runai CLI: $(runai version | head -1)"

# Skeleton kubeconfig: cluster + context, no credentials (`runai kubeconfig
# set --bypass-validation` adds the user's token; validation expects the API
# server behind the Run:ai domain). The address must be in RKE2's tls-san.
SHARE=/usr/local/share/runai
mkdir -p "$SHARE"
install -m 644 /var/lib/rancher/rke2/server/tls/server-ca.crt "$SHARE/k8s-ca.crt"
cat > "$SHARE/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: $RUNAI_CLUSTER_NAME
    cluster:
      server: https://$WW_INTERNAL_IP:6443
      certificate-authority: $SHARE/k8s-ca.crt
contexts:
  - name: $RUNAI_CLUSTER_NAME
    context: {cluster: $RUNAI_CLUSTER_NAME, user: runai-cli}
current-context: $RUNAI_CLUSTER_NAME
users:
  - name: runai-cli
    user: {}
EOF
chmod 644 "$SHARE/kubeconfig"
# Example manifests of the user guide (cli-howto.md)
rm -rf "$SHARE/examples" && cp -r "$RUNAI_SRC/examples" "$SHARE/examples" && chmod -R a+rX "$SHARE/examples"

# First login of a site user (UID >= 5000): CLI config + skeleton kubeconfig
cat > /etc/profile.d/runai-cli.sh <<EOF
# rke2_deploy_ww/runai/48-user-access.sh: point the Run:ai CLI and kubectl at this site
if [ -n "\$HOME" ] && [ "\$(id -u)" -ge 5000 ]; then
  [ -f "\$HOME/.runai/config.json" ] || runai config set --cp-url=https://$RUNAI_DOMAIN --auto-update=disabled -q 2>/dev/null || true
  [ -f "\$HOME/.kube/config" ] || { mkdir -p "\$HOME/.kube" && cp $SHARE/kubeconfig "\$HOME/.kube/config" && chmod 600 "\$HOME/.kube/config"; }
fi
EOF

# --- kubectl ----------------------------------------------------------------
install -m 755 /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
echo "kubectl: $(/usr/local/bin/kubectl version --client | head -1)"

# --- htd-runai: researcher TUI (login, quota, submit, follow, shell, save YAML) ---
install -m 755 "$RUNAI_SRC/htd-runai.py" /usr/local/bin/htd-runai
echo "htd-runai: /usr/local/bin/htd-runai"

# --- kube-apiserver OIDC (Keycloak realm "runai") ----------------------------
# Token claims (lib/accounts.py): email (verified), groups = access-rule groups.
# Usernames are the e-mail without issuer prefix ("-"), groups unprefixed so
# they match the RoleBinding subjects Run:ai creates (Group phys-astro, ...).
# The CA file must be inside a directory the apiserver static pod mounts.
OIDC_CA=/var/lib/rancher/rke2/server/runai-oidc-ca.crt
DROPIN=/etc/rancher/rke2/config.yaml.d/60-runai-oidc.yaml
install -m 644 "$RUNAI_DIR/ca.crt" "$OIDC_CA"
NEW=$(cat <<EOF
# Managed by rke2_deploy_ww/runai/48-user-access.sh
kube-apiserver-arg+:
  - oidc-issuer-url=https://$RUNAI_DOMAIN/auth/realms/runai
  - oidc-client-id=runai
  - oidc-username-claim=email
  - oidc-username-prefix=-
  - oidc-groups-claim=groups
  - oidc-ca-file=$OIDC_CA
EOF
)
if [ "$(cat "$DROPIN" 2>/dev/null)" != "$NEW" ]; then
  echo "$NEW" > "$DROPIN"
  echo "restarting rke2-server for the OIDC flags ..."
  systemctl restart rke2-server
  for i in $(seq 1 60); do
    $KUBECTL get --raw /readyz >/dev/null 2>&1 && break; sleep 5
  done
fi
$KUBECTL get --raw /readyz >/dev/null && echo "kube-apiserver ready (OIDC: $DROPIN)"

# --- self-test as the first site user ----------------------------------------
# users.csv is written by Python's csv module: CRLF line endings
IFS=, read -r TUSER _ TEMAIL _ _ TGROUP _ _ TPASS < <(sed -n 2p "$RUNAI_DIR/users.csv" | tr -d '\r')
OTHER=$(tr -d '\r' < "$RUNAI_DIR/users.csv" | cut -d, -f6 | sed 1d | grep -vx "$TGROUP" | head -1)
rm -f "$(getent passwd "$TUSER" | cut -d: -f6)/.kube/config"   # exercise the first-login path
PWFILE=$(mktemp); printf %s "$TPASS" > "$PWFILE"; chown "$TUSER" "$PWFILE"
su - "$TUSER" -c "
  set -e
  runai login user -u '$TEMAIL' -p \"\$(cat $PWFILE)\" >/dev/null
  runai kubeconfig set --bypass-validation >/dev/null
  echo \"  whoami:   \$(kubectl auth whoami -o jsonpath='{.status.userInfo.username} {.status.userInfo.groups}')\"
  echo \"  own ns:   create services in runai-$TGROUP: \$(kubectl auth can-i create services -n runai-$TGROUP)\"
  echo \"  other ns: get pods in runai-$OTHER: \$(kubectl auth can-i get pods -n runai-$OTHER || true)\"
  runai logout >/dev/null
" ; rc=$?
rm -f "$PWFILE"
[ $rc -eq 0 ] && echo "self-test OK ($TUSER)" || { echo "SELF-TEST FAILED"; exit 1; }
