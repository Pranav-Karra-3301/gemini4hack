"""Long-lived Apple SHARP worker (MLX port from the wayback project). Spawned by splat.py.

Run with the wayback vendor venv, never the server venv:
    nice -n 10 /Users/pranav/developer/wayback/vendor/.venv/bin/python -I -B splat_worker.py

Protocol, JSON lines. stdout carries only protocol lines (library prints go to stderr):
    -> {"ready": true, "load_ms": 2100}                                       once, after weights load
    <- {"id": "1", "image": "/abs/in.jpg", "focal_px": 1180.5, "out": "/abs/out.spz"}
    -> {"id": "1", "ok": true, "n": 1179648, "w": 1152, "h": 1536, "ms": 6900, ...memory stats}
    -> {"id": "1", "ok": false, "error": "..."}
Exits when stdin closes (the API process went away).

Same caps as wayback/tools/sharp.py: MLX memory limit 12 GB, 4 CPU math threads. The image is
EXIF-rotated, given to SHARP at its own size (resized to 1536x1536 internally), and focal_px is
in that image's pixels. Output is the same PLY -> gzipped SPZ v3 conversion wayback uses.
"""

import os

os.environ.setdefault("VECLIB_MAXIMUM_THREADS", "4")
os.environ.setdefault("OMP_NUM_THREADS", "4")

import ctypes  # noqa: E402
import json  # noqa: E402
import resource  # noqa: E402
import sys  # noqa: E402
import time  # noqa: E402
import traceback  # noqa: E402
from pathlib import Path  # noqa: E402

WAYBACK = Path(os.environ.get("WAYBACK_DIR", "/Users/pranav/developer/wayback"))
SHARP = WAYBACK / "vendor" / "ml_sharp_mlx" / "python"
TOOLS = WAYBACK / "tools"
WEIGHTS = WAYBACK / "vendor" / "weights" / "sharp_fp16.safetensors"
MEMORY_LIMIT = 12 * 1024**3
INTERNAL = 1536

# Keep stdout for protocol lines only: anything the model code prints goes to stderr.
_proto = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1)
os.dup2(sys.stderr.fileno(), sys.stdout.fileno())

sys.path.insert(0, str(SHARP))
sys.path.insert(0, str(TOOLS))
import mlx.core as mx  # noqa: E402
import numpy as np  # noqa: E402
from PIL import Image, ImageOps  # noqa: E402

for _setter in (getattr(mx, "set_memory_limit", None), getattr(getattr(mx, "metal", None), "set_memory_limit", None)):
    if _setter:
        _setter(MEMORY_LIMIT)
        break

import mlx.nn as nn  # noqa: E402
from gaussian_utils import save_ply  # noqa: E402
from generate import create_predictor, generate, resize_image  # noqa: E402
from ply2spz import ply_to_spz  # noqa: E402
from weights import load_weights  # noqa: E402

# Memory: as wayback runs it, SHARP's active MLX memory peaks at ~12.9 GB (13.4 GB process
# footprint; wayback's "~3 GB" is RSS, which leaves out Metal buffers). The peak comes from the
# fp32 im2col buffers of the 768x768x256 decoder convs piling up inside one lazy graph. Evaluating
# right after each large conv frees them one at a time: peak ~7.5 GB, bit-identical output,
# ~+0.3 s. Capping MLX's buffer cache at 2 GB keeps the footprint near ~9.8 GB.
_conv_call = nn.Conv2d.__call__
_BIG_CONV = 512 * 512 * 128


def _conv_eager(self, x):
    y = _conv_call(self, x)
    if x.shape[1] * x.shape[2] * x.shape[3] >= _BIG_CONV:
        mx.eval(y)
    return y


nn.Conv2d.__call__ = _conv_eager
mx.set_cache_limit(2 * 1024**3)


class _RusageV4(ctypes.Structure):  # <sys/resource.h> rusage_info_v4: uuid + uint64 fields
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("v", ctypes.c_uint64 * 40)]


def footprint_mb() -> tuple[float, float]:
    """(current, lifetime peak) physical footprint in MB: what Activity Monitor calls Memory,
    including Metal buffers (RSS leaves those out)."""
    try:
        buf = _RusageV4()
        if ctypes.CDLL("/usr/lib/libSystem.B.dylib").proc_pid_rusage(os.getpid(), 4, ctypes.byref(buf)):
            return -1.0, -1.0
        return buf.v[7] / 2**20, buf.v[28] / 2**20  # ri_phys_footprint, ri_lifetime_max_phys_footprint
    except Exception:
        return -1.0, -1.0


def send(obj: dict) -> None:
    _proto.write(json.dumps(obj) + "\n")
    _proto.flush()


def run(model, req: dict) -> dict:
    img = ImageOps.exif_transpose(Image.open(req["image"])).convert("RGB")
    image = np.asarray(img, dtype=np.float32) / 255.0
    h, w = image.shape[:2]
    f_px = float(req["focal_px"])
    out = Path(req["out"])
    ply = out.with_name(out.stem + f".{os.getpid()}.ply")
    part = out.with_name(out.stem + f".{os.getpid()}.part")
    mx.reset_peak_memory()
    t = time.perf_counter()
    try:
        g = generate(resize_image(image, INTERNAL, use_torch=False), model, f_px, w, h, (INTERNAL, INTERNAL))
        n = int(g.mean_vectors.shape[1])
        infer_ms = (time.perf_counter() - t) * 1000.0
        save_ply(g, f_px, (INTERNAL, INTERNAL), ply)
        del g
        ply_to_spz(ply, part)
        os.replace(part, out)  # atomic: readers never see a half-written .spz
    finally:
        ply.unlink(missing_ok=True)
        part.unlink(missing_ok=True)
    ms = (time.perf_counter() - t) * 1000.0
    peak_mb = mx.get_peak_memory() / 2**20
    mx.clear_cache()  # idle worker keeps the weights, not the activations
    rss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**20  # bytes on macOS
    fp_now, fp_peak = footprint_mb()
    return {"ok": True, "n": n, "w": w, "h": h, "ms": round(ms), "infer_ms": round(infer_ms),
            "mlx_peak_mb": round(peak_mb), "maxrss_mb": round(rss_mb),
            "footprint_mb": round(fp_now), "footprint_peak_mb": round(fp_peak)}


def main() -> None:
    t = time.perf_counter()
    model = create_predictor()
    load_weights(model, WEIGHTS, verbose=False)
    send({"ready": True, "load_ms": round((time.perf_counter() - t) * 1000.0), "pid": os.getpid()})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        rid = None
        try:
            req = json.loads(line)
            rid = req.get("id")
            send({"id": rid, **run(model, req)})
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            send({"id": rid, "ok": False, "error": f"{type(exc).__name__}: {exc}"[:500]})


if __name__ == "__main__":
    main()
