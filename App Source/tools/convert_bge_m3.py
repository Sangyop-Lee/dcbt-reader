"""Converts BAAI/bge-m3 (Hugging Face, PyTorch) into the Core ML model and
vocabulary file that DCBT Reader loads from the "Language model" folder.

The app expects a fixed input shape of 16 passages x 160 tokens, which runs
about 30 times faster on the GPU than a model with flexible shapes:
        FIXED=16x160 python convert_bge_m3.py ...

Usage:  python convert_bge_m3.py <folder with the downloaded bge-m3 files> <output folder>
Needs:  pip install torch transformers coremltools numpy
Afterwards compile the .mlpackage with tools/compile_model.swift.
"""
import sys, json, os
import numpy as np, torch, coremltools as ct
from transformers import AutoModel

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)

# vocabulary: line number = token id, "piece<TAB>score"
tj = json.load(open(os.path.join(src, "tokenizer.json"), encoding="utf-8"))
vocab = tj["model"]["vocab"]
with open(os.path.join(out, "vocab.txt"), "w", encoding="utf-8") as f:
    for piece, score in vocab:
        assert "\n" not in piece and "\t" not in piece
        f.write(f"{piece}\t{score}\n")
print("vocab", len(vocab), "unk", tj["model"].get("unk_id"))

model = AutoModel.from_pretrained(src, dtype=torch.float32, attn_implementation="eager").eval()

class Wrap(torch.nn.Module):
    """CLS embedding, L2-normalised. The padding mask is added as -1e4 rather than
    the float minimum, which overflows to NaN in 16-bit precision."""
    def __init__(self, m):
        super().__init__(); self.m = m
    def forward(self, input_ids, attention_mask):
        x = self.m.embeddings(input_ids=input_ids)
        ext = (1.0 - attention_mask[:, None, None, :].to(x.dtype)) * -1e4
        h = self.m.encoder(x, attention_mask=ext).last_hidden_state[:, 0]
        return torch.nn.functional.normalize(h, dim=-1)

BATCHES = [1, 16]
LENGTHS = [64, 128, 192, 256]
ids = torch.randint(5, 1000, (2, 128), dtype=torch.int32)
mask = torch.ones((2, 128), dtype=torch.int32)
with torch.no_grad():
    traced = torch.jit.trace(Wrap(model), (ids, mask), strict=False)
if os.environ.get("FIXED"):
    b, l = map(int, os.environ["FIXED"].split("x"))
    shapes = (b, l)
else:
    shapes = ct.EnumeratedShapes(shapes=[(b, l) for b in BATCHES for l in LENGTHS], default=(16, 128))
ml = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input_ids", shape=shapes, dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=shapes, dtype=np.int32)],
    outputs=[ct.TensorType(name="embedding")],
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS15,
)
ml.short_description = "BAAI/bge-m3 dense embedding (CLS, L2-normalised), float16"
ml.license = "MIT (BAAI/bge-m3)"
ml.save(os.path.join(out, os.environ.get("OUT_NAME", "bge-m3") + ".mlpackage"))
print("saved")
