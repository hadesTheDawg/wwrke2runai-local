#!/bin/bash
# Local image store -> TARGET_REGISTRY[/TARGET_REGISTRY_PREFIX]/<upstream path>,
# all architectures, digests preserved. The path keeps the upstream layout
# (docker.io/library/ubuntu -> library/ubuntu, nvcr.io/nvidia/x -> nvidia/x),
# which is what the RKE2 registries.yaml mirror (12-registries.sh, Warewulf
# rke2/runai overlays) requests. Images whose digest already matches are
# skipped. PUSH_INCLUDE / PUSH_EXCLUDE: extended regexes on the path.
. "$(dirname "$0")/../lib/common.sh"
need TARGET_REGISTRY
[ -n "$SKOPEO" ] || die "skopeo not found"
: "${PUSH_INCLUDE:=.}"
: "${PUSH_EXCLUDE:=}"

mkpriv "$SECRETS"
AUTH="$SECRETS/target-auth.json"
if [ -n "$TARGET_REGISTRY_USER" ]; then
  authfile "$AUTH" "$TARGET_REGISTRY" "$TARGET_REGISTRY_USER" "$TARGET_REGISTRY_PASSWORD_FILE"
else
  echo '{}' > "$AUTH"
fi
DEST_TLS="--dest-tls-verify=true"; REG="$PY $LIB/registry.py --authfile $AUTH"
if [ -n "$TARGET_REGISTRY_CA" ]; then
  mkdir -p "$SECRETS/target-certs"; cp "$TARGET_REGISTRY_CA" "$SECRETS/target-certs/ca.crt"
  DEST_TLS="--dest-cert-dir $SECRETS/target-certs"; REG="$REG --ca $TARGET_REGISTRY_CA"
fi
is_yes "$TARGET_REGISTRY_TLS_VERIFY" || { DEST_TLS="--dest-tls-verify=false"; REG="$REG --insecure"; }

REFS=$(mktemp); trap 'rm -f "$REFS"' EXIT
$PY "$LIB/registry.py" store-refs "$IMAGES" | grep -E "$PUSH_INCLUDE" \
  | { if [ -n "$PUSH_EXCLUDE" ]; then grep -Ev "$PUSH_EXCLUDE"; else cat; fi; } > "$REFS" || true
say "pushing $(wc -l < "$REFS" | tr -d ' ') images -> $(target_ref '')"

fail=0; pushed=0; have=0
while IFS="$(printf '\t')" read -r ref digest; do
  dest=$(target_ref "$ref"); path=${dest#*/}
  if [ "$($REG digest "$TARGET_REGISTRY" "${path%:*}" "${path##*:}" 2>/dev/null)" = "$digest" ]; then
    have=$((have+1)); continue
  fi
  if $SKOPEO copy -q --retry-times 3 --multi-arch all --preserve-digests \
       --dest-authfile "$AUTH" $DEST_TLS "dir:$IMAGES/${ref%:*}@${ref##*:}" "docker://$dest"; then
    say "  pushed $ref"; pushed=$((pushed+1))
  else
    warn "FAILED $ref"; fail=1
  fi
done < "$REFS"
say "pushed $pushed, unchanged $have"
exit $fail
