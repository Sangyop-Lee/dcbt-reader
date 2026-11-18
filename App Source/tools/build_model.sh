#!/bin/zsh
# Builds the "Language model" folder for search by meaning: downloads BAAI/bge-m3
# (about 2.3 GB) from Hugging Face, converts it to Core ML for the three passage
# sizes, merges them into one package and compiles it (result: about 1.1 GB).
# Needs about 12 GB of free disk space while it runs, and several minutes.
# Made with torch 2.8.0, transformers 4.57.6 and coremltools 9.0 on Python 3.9.
# Usage: tools/build_model.sh [work folder]      (default: a temporary folder)
set -e
cd "$(dirname "$0")"
TOOLS="$PWD"
OUT="$TOOLS/../../Language model"
WORK="${1:-$(mktemp -d)}"
mkdir -p "$WORK" "$OUT"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" -q install --upgrade pip
"$WORK/venv/bin/pip" -q install torch transformers coremltools huggingface_hub numpy
PY="$WORK/venv/bin/python"
"$PY" - "$WORK/bge-m3" <<'PYEOF'
import sys
from huggingface_hub import snapshot_download
snapshot_download("BAAI/bge-m3", local_dir=sys.argv[1],
                  allow_patterns=["pytorch_model.bin", "config.json", "tokenizer.json", "tokenizer_config.json",
                                  "special_tokens_map.json", "sentencepiece.bpe.model"])
PYEOF
for spec in "16x160 large" "32x96 medium" "64x48 small"; do
  set -- ${=spec}
  echo "Converting the $2 model ($1)…"
  FIXED=$1 OUT_NAME=$2 "$PY" "$TOOLS/convert_bge_m3.py" "$WORK/bge-m3" "$WORK/out"
done
"$PY" "$TOOLS/merge_bge_m3.py" "$WORK/out"
swiftc -O "$TOOLS/compile_model.swift" -o "$WORK/compile_model"
"$WORK/compile_model" "$WORK/out/bge-m3.mlpackage" "$OUT/bge-m3.mlmodelc"
cp "$WORK/out/vocab.txt" "$OUT/vocab.txt"
echo "Done: $OUT. The work folder $WORK can be deleted."
