#!/bin/bash
# Every image referenced by any pod in the cluster must resolve in the local
# registry under the path the registries.yaml mirror requests. ww1 still has
# internet access and containerd silently falls back to the upstream registry,
# so a gap would otherwise only surface on the offline compute nodes.
# Exit 1 lists the missing images; fix with EXTRA_IMAGES=... 11-mirror.sh.
set -euo pipefail
. "$(dirname "$0")/env.sh"
CREDS="$(cat "$REG_DIR/username"):$(cat "$REG_DIR/password")"

missing=0; n=0
while read -r img; do
  img="${img%@*}"                                   # tag is what is mirrored
  ref="${img#index.docker.io/}"; ref="${ref#docker.io/}"
  case "$ref" in
    */*/*|*.*/*) path="${ref#*/}" ;;                # registry host present
    */*)         path="$ref" ;;                     # docker hub user/repo
    *)           path="library/$ref" ;;             # docker hub official
  esac
  case "$path" in *:*) ;; *) path="$path:latest" ;; esac
  n=$((n+1))
  skopeo inspect --raw --creds "$CREDS" "docker://$REGISTRY/$path" >/dev/null 2>&1 \
    || { echo "MISSING $img  ($REGISTRY/$path)"; missing=1; }
done < <($KUBECTL get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' | sort -u)

[ $missing = 0 ] && echo "all $n images in use are served by $REGISTRY"
exit $missing
