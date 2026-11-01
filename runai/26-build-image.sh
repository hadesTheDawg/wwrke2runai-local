#!/bin/bash
# Build a workload image on ww1 and offer it in the Run:ai UI:
#
#   26-build-image.sh <catalog name>...      (no name: every `build:` entry)
#
# The catalog entry (catalog/environments.yaml) names a build directory with a
# Dockerfile instead of an upstream `source`:
#
#   - name: ubuntu-dev
#     description: Ubuntu 24.04 + compilers, git, Python venv
#     build: images/ubuntu-dev          # relative to runai/, or absolute;
#                                       # a directory or a Dockerfile path
#     image: ubuntu-dev:2026-11-01      # pin: an existing tag is never rebuilt
#     uidGidSource: fromIdpToken
#
# Base images are pulled from the pull-only workload registry, so a build can
# only start FROM what the catalog already offers. The Dockerfile gets it as
# build argument WL:
#
#   ARG WL
#   FROM ${WL}/ubuntu:24.04
#
# RUN steps execute on ww1, which has internet (apt/dnf/pip work there, unlike
# on the nodes). The image is pushed through the read-write registry (same
# storage, so it appears in the workload registry at once), the local copy and
# any base images this build pulled are removed again (ww1's / is small), then
# 24-workload-catalog.sh creates/updates the Run:ai environment.
#
# The image has ww1's architecture only (arm64 in the lab, same as the nodes).
# FORCE=1 rebuilds an existing tag; SKIP_CATALOG=1 only builds and pushes.
set -euo pipefail
. "$(dirname "$0")/env.sh"
CATALOG="$RUNAI_SRC/catalog/environments.yaml"
: "${MIN_FREE_GB:=5}"

PUSH="$(cat "$REG_DIR/username"):$(cat "$REG_DIR/password")"
PULL="$(cat "$REG_DIR/pull-username"):$(cat "$REG_DIR/pull-password")"

# podman --cert-dir pairs *.key with *.cert, so give it the CA alone
CERTS=$(mktemp -d); trap 'rm -rf "$CERTS"' EXIT
cp "$REG_DIR/ca.crt" "$CERTS/"

mapfile -t BUILDS < <(python3 "$RUNAI_SRC/lib/catalog.py" "$CATALOG" builds)
if [ $# -gt 0 ]; then
  wanted=" $* "; sel=()
  for b in "${BUILDS[@]}"; do case "$wanted" in *" ${b%%$'\t'*} "*) sel+=("$b") ;; esac; done
  [ ${#sel[@]} -eq $# ] || { echo "not a build entry in $CATALOG: $*" >&2; exit 1; }
  BUILDS=("${sel[@]}")
fi
[ ${#BUILDS[@]} -gt 0 ] || { echo "no build entries in $CATALOG"; exit 0; }

built=0
for b in "${BUILDS[@]}"; do
  IFS=$'\t' read -r name dir image <<<"$b"
  case "$dir" in /*) ctx=$dir ;; *) ctx="$RUNAI_SRC/$dir" ;; esac
  file=()     # build: names a Dockerfile -> its directory is the context
  if [ -f "$ctx" ]; then file=(-f "$ctx"); ctx=$(dirname "$ctx"); fi
  RW="$REGISTRY/$WL_REG_PREFIX/$image"
  REF="$WL_REGISTRY/$WL_REG_PREFIX/$image"
  [ ${#file[@]} -gt 0 ] || [ -f "$ctx/Dockerfile" ] || [ -f "$ctx/Containerfile" ] || { echo "$name: no Dockerfile in $ctx" >&2; exit 1; }

  if [ -z "${FORCE:-}" ] && skopeo inspect --raw --creds "$PUSH" "docker://$RW" >/dev/null 2>&1; then
    echo "  have   $image  (FORCE=1 rebuilds)"
    continue
  fi
  free=$(df -BG --output=avail /var/lib/containers 2>/dev/null | tail -1 | tr -dc 0-9)
  [ "${free:-0}" -ge "$MIN_FREE_GB" ] || { echo "only ${free}G free for podman storage, need ${MIN_FREE_GB}G" >&2; exit 1; }

  echo "  build  $name -> $REF"
  before=$(podman images -q --no-trunc | sort -u)
  podman build --pull=always --cert-dir "$CERTS" --creds "$PULL" \
    --build-arg "WL=$WL_REGISTRY/$WL_REG_PREFIX" \
    --label "org.opencontainers.image.title=$name" \
    --label "org.opencontainers.image.created=$(date -u +%FT%TZ)" \
    "${file[@]}" -t "$RW" "$ctx"
  podman push --cert-dir "$CERTS" --creds "$PUSH" "$RW"
  # drop what this build added locally (the image, its bases, dangling layers)
  podman rmi -f "$RW" >/dev/null
  comm -13 <(echo "$before") <(podman images -q --no-trunc | sort -u) | xargs -r podman rmi -f >/dev/null 2>&1 || true
  echo "  pushed $REF"
  built=$((built + 1))
done

if [ -z "${SKIP_CATALOG:-}" ]; then
  echo
  "$RUNAI_SRC/24-workload-catalog.sh"
fi
