"""Check depth.infer_depth on sample images and save a grayscale preview.

Usage: cd server && uv run --no-sync python checks/depth_check.py IMG...
Writes ../out/depth_<stem>.png, normalized with p02..p98 (near = white, far = black) on an
inverse-depth scale: outdoor scenes span ~0.3 m to hundreds of meters, so a linear scale
would wash the whole foreground out to white.
"""

import json
import logging
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

SERVER = Path(__file__).resolve().parent.parent
ROOT = SERVER.parent
sys.path.insert(0, str(SERVER))

import depth  # noqa: E402

OUT = ROOT / "out"


def preview(arr: np.ndarray, p02: float, p98: float) -> Image.Image:
    inv, lo, hi = 1.0 / np.maximum(arr, 1e-6), 1.0 / p98, 1.0 / max(p02, 1e-6)
    v = (inv - lo) / max(hi - lo, 1e-12)
    return Image.fromarray((np.clip(v, 0.0, 1.0) * 255).round().astype(np.uint8), mode="L")


def main(paths: list[str]) -> int:
    if not paths:
        print(__doc__)
        return 2
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    OUT.mkdir(exist_ok=True)

    t = time.perf_counter()
    depth.warmup()
    print(f"warmup (cold load + dummy inference): {time.perf_counter() - t:.2f}s")

    for p in paths:
        path = Path(p)
        data = path.read_bytes()
        with Image.open(path) as im:
            in_size = im.size
        t = time.perf_counter()
        arr, meta = depth.infer_depth(data)
        wall = (time.perf_counter() - t) * 1000
        assert arr.dtype == np.float32 and arr.ndim == 2, (arr.dtype, arr.shape)
        assert arr.shape == (meta["height"], meta["width"]), (arr.shape, meta)
        assert max(arr.shape) <= 512 and np.isfinite(arr).all()
        aspect_in, aspect_out = in_size[0] / in_size[1], arr.shape[1] / arr.shape[0]
        out = OUT / f"depth_{path.stem}.png"
        preview(arr, meta["p02"], meta["p98"]).save(out)
        print(f"{path.name}: in {in_size[0]}x{in_size[1]} -> out {arr.shape[1]}x{arr.shape[0]} "
              f"(aspect {aspect_in:.4f} vs {aspect_out:.4f}), wall {wall:.0f}ms")
        print("  meta", json.dumps({k: (round(v, 4) if isinstance(v, float) else v)
                                    for k, v in meta.items()}))
        print(f"  wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
