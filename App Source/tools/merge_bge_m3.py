"""Joins the three fixed-shape BGE-M3 Core ML models (one per passage size)
into a single multifunction package that stores the weights once.

    FIXED=16x160 OUT_NAME=large  python convert_bge_m3.py <bge-m3 folder> <out>
    FIXED=32x96  OUT_NAME=medium python convert_bge_m3.py <bge-m3 folder> <out>
    FIXED=64x48  OUT_NAME=small  python convert_bge_m3.py <bge-m3 folder> <out>
    python merge_bge_m3.py <out>
    compile_model <out>/bge-m3.mlpackage <out>/bge-m3.mlmodelc
"""
import sys, os
import coremltools as ct
out = sys.argv[1]
desc = ct.utils.MultiFunctionDescriptor()
for name in ("large", "medium", "small"):
    desc.add_function(os.path.join(out, name + ".mlpackage"), src_function_name="main", target_function_name=name)
desc.default_function_name = "large"
ct.utils.save_multifunction(desc, os.path.join(out, "bge-m3.mlpackage"))
print("merged")
