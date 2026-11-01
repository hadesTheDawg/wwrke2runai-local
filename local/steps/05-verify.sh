#!/bin/bash
# Integrity of the local repository.
#   images/   every blob and manifest re-hashed against its content address
#             (once per hardlinked file), every image's digest equal to the
#             inventory state/images.tsv (VERIFY_BLOBS=no skips this)
#   the rest  SHA256SUMS over charts, lock, RPMs, overlays, source snapshot:
#             written on first run (or VERIFY_WRITE=yes after a fetch), checked after
. "$(dirname "$0")/../lib/common.sh"
: "${VERIFY_BLOBS:=yes}"
: "${VERIFY_WRITE:=no}"
cd "$RUNAI_REPO" || die "no local repository at $RUNAI_REPO"

fail=0
if [ -d images ]; then
  if is_yes "$VERIFY_BLOBS"; then $PY "$LIB/registry.py" store-verify images state/images.tsv || fail=1
  else say "images: $($PY "$LIB/registry.py" store-refs images | wc -l | tr -d ' ') (not re-hashed)"; fi
else
  warn "no images in $RUNAI_REPO/images"
fi

files() { find charts runai rke2 warewulf source state/images.tsv state/feature-images.txt state/remote-facts.env -type f 2>/dev/null | LC_ALL=C sort; }
if is_yes "$VERIFY_WRITE" || [ ! -f SHA256SUMS ]; then
  files | while read -r f; do $SHA256 "$f"; done > SHA256SUMS
  say "wrote SHA256SUMS ($(wc -l < SHA256SUMS | tr -d ' ') files)"
else
  $SHA256 -c --quiet SHA256SUMS || fail=1
  extra=$(files | LC_ALL=C comm -23 - <(awk '{print $2}' SHA256SUMS | LC_ALL=C sort))
  [ -z "$extra" ] || { warn "files not covered by SHA256SUMS (VERIFY_WRITE=yes to accept):"; echo "$extra" >&2; fail=1; }
  [ $fail = 0 ] && say "SHA256SUMS: $(wc -l < SHA256SUMS | tr -d ' ') files OK"
fi
exit $fail
