#!/bin/bash
# Unpack a bundle from 07-bundle.sh into RUNAI_REPO on the deploy host:
# checksum (and signature, when a .asc lies next to it) first, decrypt .gpg,
# extract, then re-verify every blob and file (05-verify.sh).
#   make unbundle BUNDLE=/media/usb/runai-bundle-3.0.20-20261031.tar[.gpg]
. "$(dirname "$0")/../lib/common.sh"
need BUNDLE
[ -f "$BUNDLE" ] || die "no such file: $BUNDLE"
TAR="${BUNDLE%.gpg}"
DIR=$(cd "$(dirname "$BUNDLE")" && pwd)

if [ "$TAR" != "$BUNDLE" ]; then
  gpg --batch --yes -o "$TAR" --decrypt "$BUNDLE"
fi
if [ -f "$TAR.sha256" ]; then
  (cd "$DIR" && $SHA256 -c "$(basename "$TAR").sha256")
else
  warn "no $TAR.sha256 next to the bundle: checksum not verified"
fi
if [ -f "$TAR.asc" ]; then gpg --batch --verify "$TAR.asc" "$TAR"; fi

mkdir -p "$RUNAI_REPO"
tar -xf "$TAR" --strip-components 1 -C "$RUNAI_REPO"
[ "$TAR" != "$BUNDLE" ] && rm -f "$TAR"
say "unpacked into $RUNAI_REPO"
"$LOCAL_SRC/steps/05-verify.sh"
