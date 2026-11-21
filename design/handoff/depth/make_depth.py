"""Full-res Depth Pro maps for design demos (does not modify server code).
Usage: cd server && uv run --no-sync python /tmp/coachdepth/hires.py OUT_DIR IMG...
Writes <stem>_depth16.png (16-bit gray, near=white), <stem>_depth_packed.png (R + G/255, near=bright),
<stem>_depth_preview.jpg."""
import sys, pathlib, numpy as np
from PIL import Image
sys.path.insert(0, str(pathlib.Path.cwd()))
import depth as D
D.OUT_LONG_SIDE = 100000  # keep inference resolution
out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
for p in sys.argv[2:]:
    p = pathlib.Path(p)
    arr, meta = D._infer_depth_uncached(p.read_bytes())
    ld = np.log(np.maximum(arr, 1e-3))
    solid = arr < 5e3                                   # sky is ~1e6-1e8 m
    near, far = np.percentile(ld[solid], [0.5, 99.5])
    v = np.clip((far - ld) / (far - near), 0, 1)       # log depth, near = 1
    g16 = (v * 65535).astype(np.uint16)
    Image.fromarray(g16).save(out / f"{p.stem}_depth16.png")
    hi8 = np.floor(v * 255).astype(np.uint8)
    lo8 = np.round((v * 255 - hi8) * 255).astype(np.uint8)
    packed = np.dstack([hi8, lo8, np.zeros_like(hi8)])
    Image.fromarray(packed, "RGB").save(out / f"{p.stem}_depth_packed.png", optimize=True)
    Image.fromarray((v * 255).astype(np.uint8)).save(out / f"{p.stem}_depth_preview.jpg", quality=90)
    print(p.stem, arr.shape, {k: meta[k] for k in list(meta)[:4]})
