#!/bin/bash
# Every image in the remote registry -> the local image store
# ($RUNAI_REPO/images/<repo>@<tag>, skopeo dir: format), all architectures,
# manifests byte-for-byte (digests preserved, Docker manifest lists
# included), layers hardlinked so each is stored once.
# The registry's own catalog is the source of truth: the RKE2 core/canal
# images, Run:ai (lock-pinned), add-ons, the workload catalog (workloads/*)
# and anything mirrored by hand. Charts stored as OCI artifacts (charts/*)
# are checked against charts/ instead (02-artifacts.sh).
#
# Incremental: an image whose local digest equals the remote one is skipped.
# FETCH_INCLUDE / FETCH_EXCLUDE: extended regexes on the repository path.
#
# The registry is reached through an SSH tunnel to the remote host
# (REMOTE_TUNNEL=yes, default). Its certificate names the remote's IPs, not
# 127.0.0.1, so TLS verification is off on the tunnel; SSH authenticates and
# encrypts the hop. REMOTE_TUNNEL=no connects to REMOTE_REGISTRY directly and
# verifies it against the remote CA.
. "$(dirname "$0")/../lib/common.sh"
need REMOTE_SSH
[ -n "$SKOPEO" ] || die "skopeo not found (brew install skopeo / dnf install skopeo)"
[ -s "$SECRETS/remote-password" ] || "$LOCAL_SRC/steps/01-facts.sh" >/dev/null
mkdir -p "$IMAGES" "$STATE"

AUTH="$SECRETS/remote-auth.json"
if is_yes "$REMOTE_TUNNEL"; then
  case "$SKOPEO" in skopeo) ;; *) die "the tunnel needs a native skopeo (a container cannot reach 127.0.0.1 here)";; esac
  SRC="127.0.0.1:$REMOTE_TUNNEL_PORT"
  SOCK="$SECRETS/tunnel.sock"
  ssh -o BatchMode=yes -o ExitOnForwardFailure=yes $REMOTE_SSH_OPTS -f -N -M -S "$SOCK" \
      -L "$SRC:$REMOTE_REGISTRY" "$REMOTE_SSH"
  trap 'ssh -S "$SOCK" -O exit "$REMOTE_SSH" 2>/dev/null' EXIT
  SRC_TLS="--src-tls-verify=false"; REG="$PY $LIB/registry.py --authfile $AUTH --insecure"
else
  SRC="$REMOTE_REGISTRY"
  mkdir -p "$SECRETS/remote-certs"; cp "$SECRETS/remote-ca.crt" "$SECRETS/remote-certs/ca.crt"
  SRC_TLS="--src-cert-dir $SECRETS/remote-certs"; REG="$PY $LIB/registry.py --authfile $AUTH --ca $SECRETS/remote-ca.crt"
fi
authfile "$AUTH" "$SRC" "$(cat "$SECRETS/remote-username")" "$SECRETS/remote-password"

REPOS=$(mktemp); trap 'rm -f "$REPOS"; rm -rf "$IMAGES/.tmp"; [ -n "${SOCK:-}" ] && ssh -S "$SOCK" -O exit "$REMOTE_SSH" 2>/dev/null; true' EXIT
$REG catalog "$SRC" | grep -E "${FETCH_INCLUDE:-.}" | { if [ -n "$FETCH_EXCLUDE" ]; then grep -Ev "$FETCH_EXCLUDE"; else cat; fi; } > "$REPOS" || true
say "remote registry $REMOTE_REGISTRY: $(wc -l < "$REPOS" | tr -d ' ') repositories -> $IMAGES"

INV="$STATE/images.tsv.new"; : > "$INV"
fail=0; copied=0; have=0
while read -r repo; do
  for tag in $($REG tags "$SRC" "$repo"); do
    digest=$($REG digest "$SRC" "$repo" "$tag") || { warn "no manifest for $repo:$tag"; continue; }
    dir="$IMAGES/$repo@$tag"
    if [ -f "$dir/manifest.json" ] && [ "sha256:$($SHA256 < "$dir/manifest.json" | cut -c1-64)" = "$digest" ]; then
      have=$((have+1))
    elif store_copy "docker://$SRC/$repo:$tag" "$dir" --src-authfile "$AUTH" $SRC_TLS; then
      say "  copied $repo:$tag"; copied=$((copied+1))
    else
      warn "FAILED $repo:$tag"; fail=1; continue
    fi
    printf '%s\t%s\n' "$repo:$tag" "$digest" >> "$INV"
  done
done < "$REPOS"
sort -o "$STATE/images.tsv" "$INV"; rm -f "$INV"
say "images: $copied copied, $have unchanged, $(wc -l < "$STATE/images.tsv" | tr -d ' ') in the inventory"

# --- charts held in the registry, but missing as tarballs -------------------------
if $REG catalog "$SRC" | grep -q '^charts/'; then
  HELMREG="$SECRETS/helm-registry.json"
  for repo in $($REG catalog "$SRC" | grep '^charts/'); do
    name=${repo#charts/}
    for ver in $($REG tags "$SRC" "$repo"); do
      [ -s "$CHARTS/$name-$ver.tgz" ] && continue
      [ -s "$HELMREG" ] || helm registry login "$SRC" --insecure --registry-config "$HELMREG" \
          -u "$(cat "$SECRETS/remote-username")" --password-stdin < "$SECRETS/remote-password" >/dev/null
      helm pull "oci://$SRC/$repo" --version "$ver" -d "$CHARTS" --registry-config "$HELMREG" \
          --insecure-skip-tls-verify >/dev/null && say "  pulled chart $name $ver"
    done
  done
fi

# --- does the bundle cover what the remote cluster actually runs? -----------------
$PY - "$STATE/remote-pod-images.txt" "$STATE/images.tsv" > "$STATE/coverage.txt" <<'EOF' || fail=1
import sys
inv = dict(l.rstrip("\n").split("\t") for l in open(sys.argv[2]) if l.strip())
digests = set(inv.values())
missing = 0
for img in (l.strip() for l in open(sys.argv[1])):
    if not img:
        continue
    name, _, digest = img.partition("@")
    ref = name.removeprefix("index.docker.io/").removeprefix("docker.io/")
    first = ref.split("/")[0]
    if "/" in ref and ("." in first or ":" in first or first == "localhost"):
        ref = ref.split("/", 1)[1]                      # registry host present
    elif "/" not in ref:
        ref = "library/" + ref                          # docker hub official image
    if ":" not in ref.rsplit("/", 1)[-1]:
        ref += ":latest"
    if ref in inv or (digest and digest in digests):
        continue
    missing += 1
    print(f"MISSING {img}")
print(f"{missing} of the remote cluster's pod images are not in the bundle")
sys.exit(1 if missing else 0)
EOF
cat "$STATE/coverage.txt"
exit $fail
