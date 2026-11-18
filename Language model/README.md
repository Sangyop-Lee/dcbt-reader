# Language model

Used by DCBT Reader for "By meaning" (semantic) search. If this folder is
missing, the app falls back to the Mac's built-in language model.

- `bge-m3.mlmodelc` — BAAI/bge-m3 (https://huggingface.co/BAAI/bge-m3, MIT licence),
  converted to Core ML in 16-bit precision, three fixed input shapes in one package (functions large 16x160, medium 32x96, small 64x48 tokens).
- `vocab.txt` — its SentencePiece vocabulary (line number = token id).

To rebuild: see `App Source/tools/convert_bge_m3.py`, `merge_bge_m3.py` and `compile_model.swift`.
