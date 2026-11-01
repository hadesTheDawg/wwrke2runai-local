#!/bin/bash
# Install a pinned helm on ww1 and log it in to the local registry, which
# serves every chart this layer installs (oci://<ww1>:5000/charts).
set -euo pipefail
. "$(dirname "$0")/env.sh"

if ! helm version --short 2>/dev/null | grep -q "^${HELM_VERSION}+"; then
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  TGZ="helm-${HELM_VERSION}-linux-${RUNAI_ARCH}.tar.gz"
  curl -fsSLo "$TMP/$TGZ" "https://get.helm.sh/$TGZ"
  (cd "$TMP" && echo "$(curl -fsSL "https://get.helm.sh/$TGZ.sha256sum" | awk '{print $1}')  $TGZ" | sha256sum -c -)
  tar -xzf "$TMP/$TGZ" -C "$TMP"
  install -m 0755 "$TMP/linux-${RUNAI_ARCH}/helm" /usr/local/bin/helm
fi
helm version --short

# CA is already in the system trust store (02-registry.sh)
helm registry login "$REGISTRY" -u "$(cat "$REG_DIR/username")" --password-stdin < "$REG_DIR/password"
