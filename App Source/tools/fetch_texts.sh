#!/bin/zsh
# Downloads CBETA's XML for the canons you name into the "Source texts" folder.
# Usage: tools/fetch_texts.sh [canon …]        (default: T X — Taishō and Xuzangjing)
# Canon folders are listed at https://github.com/cbeta-org/xml-p5
set -e
cd "$(dirname "$0")"
OUT="../../Source texts"
[ $# -eq 0 ] && set -- T X
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Fetching $* from cbeta-org/xml-p5 (this can take several minutes)…"
git clone -q --depth 1 --filter=blob:none --sparse https://github.com/cbeta-org/xml-p5.git "$TMP/xml-p5"
git -C "$TMP/xml-p5" sparse-checkout set "$@"
mkdir -p "$OUT"
for canon in "$@"; do
  rm -rf "$OUT/$canon"
  mv "$TMP/xml-p5/$canon" "$OUT/$canon"
done
echo "Source: https://github.com/cbeta-org/xml-p5\nCommit: $(git -C "$TMP/xml-p5" log -1 --format='%H (%cs)')\nFolders: $*" > "$OUT/SOURCE.txt"
echo "Done. Open DCBT Reader and choose Library ▸ Rebuild Search Index."
