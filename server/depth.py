"""Monocular metric depth with Apple Depth Pro 2 S (local, MPS when available).

See ../CONTRACT.md (`/api/depth`). Public API used by app.py:
  warmup()                      load the model once and run a dummy inference
  infer_depth(image_bytes)  ->  (float32 HxW depth in meters, long side <= 512, meta dict)

Precision: on MPS the model runs under autocast. Measured on an M5 Pro at 1536x2048, fp16 and
bf16 are equally fast (~0.3 s vs ~0.9 s for fp32) and fp16 is ~10x closer to fp32 (median rel.
err 0.04% vs 0.4%), so the order tried is fp16 -> bf16 -> fp32. Override with
DEPTH_PRECISION=fp16|bf16|fp32 and DEPTH_DEVICE=mps|cpu.
"""

from __future__ import annotations

import hashlib
import io
import logging
import os
import threading
import time
from collections import OrderedDict

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")  # must precede the torch import

import numpy as np  # noqa: E402
import torch  # noqa: E402
import torch.nn.functional as F  # noqa: E402
from PIL import Image, UnidentifiedImageError  # noqa: E402

log = logging.getLogger("depth")

MODEL_ID = "apple/DepthPro2-S"
FOCAL_ID = "apple/DepthPro2-focal"
OUT_LONG_SIDE = 512
MAX_INFER_SIDE = 2048  # browser sends <= 1536 (raw samples are 2048); guard against huge uploads
DTYPES = {"fp16": torch.float16, "bf16": torch.bfloat16, "fp32": torch.float32}

_load_lock = threading.Lock()
_infer_lock = threading.Lock()
_model = None
_device: torch.device | None = None
_precision: str | None = None


def _pick_device() -> torch.device:
    want = os.environ.get("DEPTH_DEVICE", "").strip().lower()
    if want:
        return torch.device(want)
    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def _set_precision(model, name: str) -> None:
    # DepthPro2/FOVEstimator keep fp32 weights; `precision` is only the autocast dtype.
    model.precision = DTYPES[name]
    if model.fov is not None:
        model.fov.precision = DTYPES[name]


def _dummy_image(h: int = 384, w: int = 512) -> np.ndarray:
    """A smooth synthetic scene (bright top, dark textured floor) for warmup and precision probes."""
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    rng = np.random.default_rng(0)
    base = np.stack([200 - 120 * yy / h, 180 - 60 * xx / w, 160 + 40 * np.sin(xx / 23)], -1)
    base += rng.normal(0, 6, base.shape)
    return np.clip(base, 0, 255).astype(np.uint8)


def _run(image: np.ndarray, f_px: float | None) -> tuple[torch.Tensor, torch.Tensor, float]:
    """Raw model output: (depth HxW fp32 on device, inverse depth, focal px). Caller holds the lock."""
    from depth_pro_2.model import to_normalized_tensor

    x = to_normalized_tensor(image, _device)
    out = _model.infer(x, f_px=f_px)
    if out["depth"] is None:
        raise RuntimeError("Depth Pro 2 returned no metric depth (no focal length available)")
    return out["depth"].float(), out["inverse_depth"].float(), float(out["focallength_px"])


def _usable(inv: torch.Tensor, depth: torch.Tensor) -> bool:
    """Half-precision overflow shows up as NaN inverse depth; +inf depth (sky) is legitimate."""
    return not bool(torch.isnan(inv).any()) and bool(torch.isfinite(depth).any())


def _load() -> None:
    global _model, _device, _precision
    with _load_lock:
        if _model is not None:
            return
        from depth_pro_2 import DepthPro2
        from depth_pro_2.network.fov import FOVEstimator
        from huggingface_hub import hf_hub_download
        from safetensors.torch import load_file

        t0 = time.perf_counter()
        device = _pick_device()
        try:  # use the HF cache without network round-trips; download on first run only
            model = DepthPro2.from_pretrained(MODEL_ID, precision=torch.float32,
                                              local_files_only=True)
            focal = hf_hub_download(FOCAL_ID, "model.safetensors", local_files_only=True)
        except Exception:
            model = DepthPro2.from_pretrained(MODEL_ID, precision=torch.float32)
            focal = hf_hub_download(FOCAL_ID, "model.safetensors")
        model.fov = FOVEstimator(torch.float32)
        model.fov.load_state_dict(load_file(focal))
        model = model.to(device).eval()

        forced = os.environ.get("DEPTH_PRECISION", "").strip().lower()
        if forced:
            order = [forced]
        elif device.type == "cpu":
            order = ["fp32"]
        else:
            order = ["fp16", "bf16", "fp32"]

        _model, _device = model, device
        dummy = _dummy_image()
        with _infer_lock:
            for name in order:
                _set_precision(model, name)
                try:
                    depth, inv, _ = _run(dummy, None)
                    if _usable(inv, depth):
                        _precision = name
                        break
                    log.warning("depth precision %s produced NaNs, trying next", name)
                except Exception:
                    log.exception("depth precision %s failed, trying next", name)
            else:
                _model = None
                raise RuntimeError(f"Depth Pro 2 failed at every precision on {device}")
        log.info("depth model ready on %s/%s in %.1fs", device.type, _precision,
                 time.perf_counter() - t0)


WARM_SHAPES = ((1536, 1152), (1152, 1536))  # (H, W): browser-normalized 4:3 portrait/landscape


def warmup() -> None:
    """Load the model (once), then pre-compile the common input shapes.

    The small dummy inference runs inside _load (precision probe). MPS also compiles kernels per
    input shape (~1-3 s on the first call at a new size), so the browser's usual 4:3 sizes at
    1536 px are run once here too; other sizes pay that cost on their first request only.
    """
    _load()
    if _device.type != "mps":
        return
    t0 = time.perf_counter()
    with _infer_lock:
        for h, w in WARM_SHAPES:
            _run(_dummy_image(h, w), None)
    log.info("depth warmup shapes %s in %.1fs", WARM_SHAPES, time.perf_counter() - t0)


def _decode(image_bytes: bytes) -> tuple[np.ndarray, float | None]:
    """JPEG bytes -> upright RGB uint8 (H, W, 3) and EXIF focal length in px (or None)."""
    from depth_pro_2 import load_rgb  # PIL open + EXIF 35mm focal + exif_transpose + RGB

    try:
        image, f_px = load_rgb(io.BytesIO(image_bytes))
    except (UnidentifiedImageError, OSError) as exc:
        raise ValueError(f"could not decode image: {exc}") from exc
    h, w = image.shape[:2]
    if max(h, w) > MAX_INFER_SIDE:
        s = MAX_INFER_SIDE / max(h, w)
        size = (max(1, round(w * s)), max(1, round(h * s)))
        image = np.array(Image.fromarray(image).resize(size, Image.Resampling.LANCZOS))
        f_px = None if f_px is None else f_px * size[0] / w
    return image, f_px


def _out_size(h: int, w: int) -> tuple[int, int]:
    s = min(1.0, OUT_LONG_SIDE / max(h, w))
    return max(1, round(h * s)), max(1, round(w * s))


CACHE_SIZE = 4  # recent results keyed by sha1(bytes): /api/masks reuses /api/depth's map
_cache: OrderedDict[str, tuple[np.ndarray, dict]] = OrderedDict()
_cache_lock = threading.Lock()
_inflight: dict[str, threading.Lock] = {}  # per-key: concurrent callers share one inference


def _cached(key: str) -> tuple[np.ndarray, dict] | None:
    with _cache_lock:
        hit = _cache.get(key)
        if hit is not None:
            _cache.move_to_end(key)
    return None if hit is None else (hit[0].copy(), dict(hit[1]))


def infer_depth(image_bytes: bytes) -> tuple[np.ndarray, dict]:
    """Depth in meters, float32 (H, W) with long side <= 512, row-major, top-left origin.

    The last CACHE_SIZE results are kept (LRU, keyed by sha1 of the bytes); a hit returns copies.
    Concurrent calls on the same bytes run Depth Pro once: later callers wait for the first and
    take its cached result (if it failed, the next one tries again).
    """
    key = hashlib.sha1(image_bytes).hexdigest()
    hit = _cached(key)
    if hit is not None:
        return hit
    with _cache_lock:
        lock = _inflight.setdefault(key, threading.Lock())
    try:
        with lock:
            hit = _cached(key)
            if hit is not None:
                return hit
            arr, meta = _infer_depth_uncached(image_bytes)
            with _cache_lock:
                _cache[key] = (arr.copy(), dict(meta))
                _cache.move_to_end(key)
                while len(_cache) > CACHE_SIZE:
                    _cache.popitem(last=False)
            return arr, meta
    finally:
        with _cache_lock:
            if _inflight.get(key) is lock:
                del _inflight[key]


def _infer_depth_uncached(image_bytes: bytes) -> tuple[np.ndarray, dict]:
    _load()
    image, exif_f_px = _decode(image_bytes)
    h, w = image.shape[:2]
    oh, ow = _out_size(h, w)

    with _infer_lock:
        precision = _precision
        t0 = time.perf_counter()
        depth, inv, f_px = _run(image, exif_f_px)
        if not _usable(inv, depth) and precision != "fp32":
            log.warning("depth %s output unusable for this image, rerunning in fp32", precision)
            _set_precision(_model, "fp32")
            try:
                depth, inv, f_px = _run(image, exif_f_px)
            finally:
                _set_precision(_model, _precision)
            precision = "fp32"

        finite = torch.isfinite(depth)
        fill = depth[finite].max() if bool(finite.any()) else depth.new_tensor(0.0)
        depth = torch.where(finite, depth, fill)
        solid = finite.float()  # 1 where the model gave a finite depth (not sky / infinitely far)
        if (oh, ow) != (h, w):
            both = torch.stack([depth, solid])[None]
            if h % oh or w % ow:  # MPS adaptive pooling needs integer factors
                both = both.cpu()
            both = F.interpolate(both, size=(oh, ow), mode="area")[0]
            depth, solid = both[0], both[1]
        arr = np.ascontiguousarray(depth.cpu().numpy(), dtype=np.float32)
        solid_mask = solid.cpu().numpy() >= 0.999
        infer_ms = (time.perf_counter() - t0) * 1000.0

    # Sky is +inf (filled with the max finite value, often 1e6-1e7 m) and covers >2% of most
    # outdoor photos, so whole-map percentiles would put p98 on the sky. Take p02/p98 over the
    # output pixels that contain no sky; sky then sits beyond p98 and clamps to "far".
    ref = arr[solid_mask] if solid_mask.any() else arr.ravel()
    p02, p98 = np.percentile(ref, [2, 98])
    meta = {
        "width": int(arr.shape[1]),
        "height": int(arr.shape[0]),
        "min": float(arr.min()),
        "max": float(arr.max()),
        "p02": float(p02),
        "p98": float(p98),
        "focal_px": float(f_px) if f_px is not None else None,
        "focal_source": "exif" if exif_f_px is not None else "fov_estimator",
        "infer_ms": float(infer_ms),
        "device": f"{_device.type}/{precision}",
    }
    return arr, meta
