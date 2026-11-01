#!/bin/bash
# One file to carry: tar of the local repository without secrets/.
#   <BUNDLE_DIR>/runai-bundle-<runai version>-<date>.tar
#   ... .tar.sha256            always
#   ... .tar.asc               BUNDLE_GPG_KEY=<key id>: detached signature
#   ... .tar.gpg               BUNDLE_GPG_RECIPIENT=<key id>: encrypted copy
#                              (the plain .tar is then removed)
# Unpack on the deploy host with `make unbundle BUNDLE=<file>`.
. "$(dirname "$0")/../lib/common.sh"
: "${BUNDLE_DIR:=$(dirname "$RUNAI_REPO")}"
: "${BUNDLE_GPG_KEY:=}"
: "${BUNDLE_GPG_RECIPIENT:=}"

"$LOCAL_SRC/steps/05-verify.sh"
NAME="runai-bundle-$(runai_version)-$(date -u +%Y%m%d)"
OUT="$BUNDLE_DIR/$NAME.tar"
mkdir -p "$BUNDLE_DIR"

COPYFILE_DISABLE=1 tar -C "$(dirname "$RUNAI_REPO")" --exclude "$(basename "$RUNAI_REPO")/secrets" \
  -cf "$OUT" "$(basename "$RUNAI_REPO")"
(cd "$BUNDLE_DIR" && $SHA256 "$NAME.tar" > "$NAME.tar.sha256")
[ -n "$BUNDLE_GPG_KEY" ] && gpg --batch --yes -u "$BUNDLE_GPG_KEY" --detach-sign --armor -o "$OUT.asc" "$OUT"
if [ -n "$BUNDLE_GPG_RECIPIENT" ]; then
  gpg --batch --yes -r "$BUNDLE_GPG_RECIPIENT" --compress-algo none -o "$OUT.gpg" --encrypt "$OUT"
  rm -f "$OUT"; OUT="$OUT.gpg"
fi
ls -lh "$BUNDLE_DIR/$NAME".tar*
