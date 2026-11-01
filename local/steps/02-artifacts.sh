#!/bin/bash
# Non-image artifacts from the remote system:
#   runai/   Run:ai ArtifactLock + add-on image list (runai/11-mirror.sh's work dir)
#   charts/  every chart tarball the remote installed from (digest-checked there)
#   rke2/    RKE2 RPMs for $TARGET_ARCH, same version as the remote server, for
#            the Warewulf node image (scripts/04-image.sh); signatures are
#            checked on the remote against Rancher's imported key
. "$(dirname "$0")/../lib/common.sh"
need REMOTE_SSH
RSYNC_SSH="ssh -o BatchMode=yes $REMOTE_SSH_OPTS"
mkdir -p "$RUNAI_REPO/runai" "$CHARTS" "$RUNAI_REPO/rke2"

rsync -rt -e "$RSYNC_SSH" --exclude charts/ "$REMOTE_SSH:$REMOTE_RUNAI_WORK/" "$RUNAI_REPO/runai/"
rsync -rt -e "$RSYNC_SSH" "$REMOTE_SSH:$REMOTE_RUNAI_WORK/charts/" "$CHARTS/"
say "Run:ai $(runai_version) lock + $(ls "$CHARTS" | wc -l | tr -d ' ') charts in $RUNAI_REPO"

if ! is_yes "$FETCH_RKE2_RPMS"; then exit 0; fi

# Rancher's repo files hard-code the architecture in baseurl: point a temporary
# repo at the target architecture's path of the same channel.
TMP=$(rsh "set -euo pipefail
  V=\$(rke2 --version | awk 'NR==1{print \$3}'); P=\${V#v}; P=\${P/+/\~}; M=\$(echo \$P | cut -d. -f1,2)
  URL=\$(awk -v r=\"[rancher-rke2-\$M-stable]\" '\$0==r{f=1;next} /^\\[/{f=0} f && /^baseurl=/{sub(/^baseurl=/,\"\");print}' /etc/yum.repos.d/rancher-rke2.repo)
  [ -n \"\$URL\" ] || { echo 'no rancher-rke2-'\$M'-stable repo on the remote' >&2; exit 1; }
  URL=\${URL%/*}/$RPM_ARCH
  T=\$(mktemp -d /var/tmp/rke2-rpms.XXXXXX)
  dnf -q download --destdir \$T --forcearch $RPM_ARCH \
    --repofrompath rke2-target,\$URL --repo rke2-target --repo rancher-rke2-common-stable \
    rke2-common-\$P rke2-agent-\$P rke2-server-\$P rke2-selinux >&2
  rpm -K \$T/*.rpm > \$T/rpm-K.txt
  echo \$T")
trap 'rsh "rm -rf $TMP"' EXIT
rsync -rt -e "$RSYNC_SSH" --delete "$REMOTE_SSH:$TMP/" "$RUNAI_REPO/rke2/"
cat "$RUNAI_REPO/rke2/rpm-K.txt"
grep -q -v 'digests signatures OK' "$RUNAI_REPO/rke2/rpm-K.txt" && die "RPM signature check failed (see above)"
say "RKE2 RPMs ($RPM_ARCH) in $RUNAI_REPO/rke2"
