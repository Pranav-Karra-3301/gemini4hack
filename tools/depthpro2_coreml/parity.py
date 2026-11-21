"""Check Apple's Core ML Depth Pro 2 S against the PyTorch model on one photo.

The two halves need different environments, so run it twice:

  # 1. PyTorch reference (torch + depth_pro_2)
  uv run --python 3.12 --with torch --with numpy --with pillow \
    --with "depth-pro-2 @ git+https://github.com/apple-aiml-research/ml-depth-pro-2" \
    python -I tools/depthpro2_coreml/parity.py torch PHOTO.jpg /tmp/dp2-ref.npz
  # 2. Core ML (any venv with coremltools + pillow + numpy) and the comparison
  python -I tools/depthpro2_coreml/parity.py coreml /tmp/dp2-ref.npz DepthPro2S.mlpackage

The photo is fitted into the model's 854x480 frame the same way the app does it
(DepthPro2.swift): scale to fit, then replicate-pad right and bottom. PyTorch runs on the
unpadded, resized photo at its native size.
"""

from __future__ import annotations

import sys
import time

import numpy as np
from PIL import Image

FRAME_W, FRAME_H = 854, 480


def fit(path: str) -> tuple[np.ndarray, np.ndarray]:
    """(resized upright RGB uint8 h x w x 3, padded RGB float 1x3x480x854 in [0, 1])."""
    from PIL import ImageOps

    img = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    s = min(FRAME_W / img.width, FRAME_H / img.height)
    w, h = max(1, round(img.width * s)), max(1, round(img.height * s))
    small = np.asarray(img.resize((w, h), Image.Resampling.LANCZOS))
    padded = np.pad(small, ((0, FRAME_H - h), (0, FRAME_W - w), (0, 0)), mode="edge")
    return small, padded.transpose(2, 0, 1)[None].astype(np.float32) / 255.0


def run_torch(photo: str, out: str) -> None:
    import torch
    from depth_pro_2 import DepthPro2
    from depth_pro_2.model import to_normalized_tensor

    small, padded = fit(photo)
    model = DepthPro2.from_pretrained("apple/DepthPro2-S", precision=torch.float32).eval()
    x = to_normalized_tensor(small, torch.device("cpu"))
    inv = model.infer(x, f_px=1000.0)["inverse_depth"].float().numpy()
    np.savez(out, inverse_depth=inv, frame=padded)
    print(f"torch: {small.shape[1]}x{small.shape[0]} inverse depth -> {out}")


def run_coreml(ref: str, package: str) -> None:
    import coremltools as ct

    data = np.load(ref)
    want, frame = data["inverse_depth"], data["frame"]
    h, w = want.shape
    model = ct.models.MLModel(package, function_name="res_854x480",
                              compute_units=ct.ComputeUnit.ALL)
    state = model.make_state()
    t0 = time.perf_counter()
    got = model.predict({"frame": frame.astype(np.float16)}, state=state)["inverse_depth"]
    dt = time.perf_counter() - t0
    got = np.asarray(got, dtype=np.float32)[0, :h, :w]
    ok = np.isfinite(got) & np.isfinite(want) & (got > 0) & (want > 0)
    corr = np.corrcoef(got[ok], want[ok])[0, 1]
    log_corr = np.corrcoef(np.log(got[ok]), np.log(want[ok]))[0, 1]
    print(f"coreml: {w}x{h} valid, first predict {dt:.2f}s (includes load/compile)")
    print(f"inverse depth corr {corr:.4f}  log corr {log_corr:.4f}  "
          f"median ratio coreml/torch {np.median(got[ok] / want[ok]):.4f}  (w/854 = {w / FRAME_W:.4f})")
    # The model normalizes inverse depth by the width it sees (854), PyTorch by the unpadded w.
    depth_got, depth_want = 1.0 / (FRAME_W * got[ok]), 1.0 / (w * want[ok])
    rel = np.abs(depth_got - depth_want) / depth_want
    print(f"metric depth (same f_px): median rel err {np.median(rel):.4f}  p90 {np.percentile(rel, 90):.4f}")


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("torch", "coreml"):
        sys.exit(__doc__)
    (run_torch if sys.argv[1] == "torch" else run_coreml)(sys.argv[2], sys.argv[3])
