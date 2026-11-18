#!/bin/zsh
# Downloads CBETA's supplementary font and glyph images and packs them into the
# "Gaiji" folder that DCBT Reader reads (CBETASupplement.ttf, glyphs.bin, glyphs.idx).
# Usage: tools/fetch_gaiji.sh [output folder]      (default: ../Gaiji beside the app)
set -e
cd "$(dirname "$0")"
OUT="${1:-../../Gaiji}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"
for repo in cbeta-fonts gaiji-CB sd-gif rj-gif; do
  echo "Fetching $repo…"
  git clone -q --depth 1 "https://github.com/cbeta-org/$repo.git" "$TMP/$repo"
done
cp "$TMP/cbeta-fonts/CBETASupplement.ttf" "$OUT/"
# one file of concatenated GIFs plus an index: "id <tab> offset <tab> length"
python3 - "$TMP" "$OUT" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
off = n = 0
with open(os.path.join(dst, "glyphs.bin"), "wb") as b, open(os.path.join(dst, "glyphs.idx"), "w") as ix:
    for repo in ("gaiji-CB", "sd-gif", "rj-gif"):
        for d, dirs, files in sorted(os.walk(os.path.join(src, repo))):
            dirs[:] = sorted(x for x in dirs if x != ".git")
            for f in sorted(files):
                if not f.endswith(".gif"): continue
                data = open(os.path.join(d, f), "rb").read()
                b.write(data); ix.write(f"{f[:-4]}\t{off}\t{len(data)}\n"); off += len(data); n += 1
print(f"Packed {n} glyph images ({off} bytes) into {dst}")
PY
