"""Object masks for the coaching regions: SAM 2.1 box prompts + conservative depth refinement.

See ../CONTRACT.md (`/api/masks`). Public API used by app.py:
  warmup()                               load the segmenter once and run a dummy pass
  segment_regions(image_bytes, regions)  -> {"masks": {id: {...}}, "model": str, "ms": int}

Pipeline per request:
  1. One SAM 2.1 image embedding; all boxes decoded together (3 multimask outputs + the
     single-mask output per box). Candidates are scored by quality (SAM's predicted IoU and its
     stability score) plus fit to the box (bbox IoU + fill), minus penalties for spilling out of
     the box or fragmenting. SAM's IoU alone prefers crisp parts (hair over the whole head).
     Near-tied clean candidates are unioned (SAM splits "walker and dog" across outputs).
  2. Clean-up: crop to the box plus a margin, drop specks, fill enclosed holes at the mask's depth.
  3. Group boxes ("four friends"): if the mask explains its box poorly, same-depth blobs it misses
     get their own sub-box prompts against the same embedding; clean results are added.
  4. Depth refinement (depth.infer_depth, LRU-cached in depth.py so /api/depth's map is reused):
     parts whose log-depth is far from the mask's median AND that meet the rest across a depth
     discontinuity are cut. Smoothly receding surfaces (paths, tunnels, coastlines) have no
     discontinuity and are kept. For object masks only broad leaks are cut (thin parts such as
     legs are where 512-px depth bleeds across edges); in sky masks any finite-depth part goes.
  5. Fallback when SAM is unavailable or errors: box intersected with the dominant depth cluster
     inside the box (`box+depth`), or the plain box (`box`) if depth failed too.

`source` per mask: `sam2.1+depth` (depth changed it), `sam2.1`, `box+depth`, `box`, or `empty`
(invalid box). Model: facebook/sam2.1-hiera-large under fp16 autocast on MPS (~0.22 s for the
embedding + 3 boxes at 1536 px; fp32 ~0.46 s; small/base-plus are faster, large is the best).
Override with SEGMENT_MODEL, SEGMENT_PRECISION=fp16|bf16|fp32 and SEGMENT_DEVICE=mps|cpu.
"""

from __future__ import annotations

import base64
import io
import logging
import os
import threading
import time

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")  # must precede the torch import

import numpy as np  # noqa: E402
import torch  # noqa: E402
import torch.nn.functional as F  # noqa: E402
from PIL import Image, ImageOps, UnidentifiedImageError  # noqa: E402
from scipy import ndimage as ndi  # noqa: E402

log = logging.getLogger("segment")

MODEL_ID = os.environ.get("SEGMENT_MODEL", "facebook/sam2.1-hiera-large")
MODEL_TAG = "sam2.1"
MASK_LONG_SIDE = 1024
SAM_SIDE = 1024  # SAM 2.1 input resolution (the processor stretches to 1024 x 1024)
DTYPES = {"fp16": torch.float16, "bf16": torch.bfloat16, "fp32": torch.float32}
RELOAD_AFTER_S = 300.0  # after a failed load, retry at most this often

# Candidate choice and clean-up
BOX_MARGIN = 0.12  # crop masks to the box grown by this fraction of its size (+ a few px)
SPECK_FRAC = 0.03  # drop components smaller than this fraction of the largest one
HOLE_FRAC = 0.1  # fill enclosed holes smaller than this fraction of the mask
TIE_MARGIN = 0.04  # union clean candidates scoring within this of the best (split groups)

# Group boxes: expand a mask that explains its box poorly with SAM masks of same-depth blobs
GROUP_FILL = 0.6  # expand only if the mask fills less than this share of the box...
GROUP_BIOU = 0.8  # ...and its extent matches the box worse than this
GROUP_DEV = 0.7  # blobs within this log-depth of the mask's median (x2 in distance)
GROUP_MIN = 0.03  # blobs of at least this share of the box
GROUP_MAX = 4  # blobs per round
GROUP_ROUNDS = 3
GROUP_EDGE = 0.3  # an added member must stand out in depth on >= this share of its outline

# Scattered masks: merge in the box's dominant depth layer when SAM returns fragments
SCATTER_PARTS = 4  # at least this many sizable pieces inside the box...
SCATTER_FILL = 0.35  # ...together covering less than this share of it
SCATTER_PART_MIN = 0.005  # a piece counts if it is at least this share of the box

# Depth refinement (log-depth units; 0.4 ~ a factor of 1.5 in distance)
SKY_CAP_M = 1e4  # sky comes back as 1e6-6e7 m: cap so it is just "very far"
DEV_MIN = 0.4  # a pixel is a leak candidate if |log d - median| > max(DEV_MIN, DEV_MAD * MAD)
DEV_MAD = 4.0
EDGE_GRAD = 0.12  # |grad log d| per depth pixel (long side 512) that counts as a discontinuity
EDGE_FRAC = 0.6  # a leak must meet the rest of the mask across an edge on >= this share of contact
LEAK_MIN_FRAC = 0.004  # ignore leak components smaller than this fraction of the mask
LEAK_MAX_FRAC = 0.4  # never cut more than this fraction of the mask in total
CORE_DEPTH_PX = 3  # a leak must survive erosion by this many depth pixels...
CORE_FRAC = 0.25  # ...keeping at least this share of its area

_load_lock = threading.Lock()
_infer_lock = threading.Lock()
_model = None
_processor = None
_device: torch.device | None = None
_precision: str | None = None
_load_error: tuple[float, str] | None = None  # (time, message) of the last failed load

class SegmenterUnavailable(RuntimeError):
    """The model failed to load recently; requests use the box+depth fallback until a retry."""


last_debug: dict = {}  # per-region candidate metrics and stage timings of the last call (checks)


# ---------------------------------------------------------------- model


def _pick_device() -> torch.device:
    want = os.environ.get("SEGMENT_DEVICE", "").strip().lower()
    if want:
        return torch.device(want)
    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def _autocast(precision: str):
    enabled = precision != "fp32" and _device.type != "cpu"
    return torch.autocast(_device.type, dtype=DTYPES[precision], enabled=enabled)


class _SamSession:
    """One image embedding, decoded against any number of prompts. Holds the inference lock."""

    def __init__(self, pil: Image.Image, out_hw: tuple[int, int], precision: str | None = None):
        self.pil, self.out_hw = pil, out_hw
        self.W, self.H = pil.size
        self.precision = precision or _precision
        self.emb = None

    def __enter__(self):
        _infer_lock.acquire()
        try:
            self.pv = _processor(images=self.pil, return_tensors="pt")["pixel_values"].to(_device)
            self.emb = self._embed(self.precision)
        except BaseException:
            _infer_lock.release()
            raise
        return self

    def __exit__(self, *exc):
        self.emb = self.pv = None
        _infer_lock.release()

    def _embed(self, precision: str):
        with torch.inference_mode(), _autocast(precision):
            return _model.get_image_embeddings(self.pv)

    def _decode(self, boxes, points, precision: str):
        sx, sy = SAM_SIDE / self.W, SAM_SIDE / self.H
        kw = {"input_boxes": (torch.tensor(boxes, dtype=torch.float32)
                              * torch.tensor([sx, sy, sx, sy]))[None].to(_device)}
        if points is not None:
            pts = torch.tensor(points, dtype=torch.float32)  # N x P x (x, y, label)
            kw["input_points"] = (pts[..., :2] * torch.tensor([sx, sy]))[None].to(_device)
            kw["input_labels"] = pts[..., 2].to(torch.int32)[None].to(_device)
        with torch.inference_mode(), _autocast(precision):
            multi = _model(image_embeddings=self.emb, multimask_output=True, **kw)
            single = _model(image_embeddings=self.emb, multimask_output=False, **kw)
        logits = torch.cat([multi.pred_masks, single.pred_masks], dim=2)[0].float()
        iou = torch.cat([multi.iou_scores, single.iou_scores], dim=2)[0].float()
        return logits, iou

    def decode(self, boxes, points=None) -> tuple[np.ndarray, np.ndarray]:
        """boxes: N x [x0, y0, x1, y1] image px; points: N x P x (x, y, label) or None.

        Returns logits N x K x mh x mw at mask size and predicted IoU N x K (K = 3 multimask
        outputs + the single-mask output)."""
        logits, iou = self._decode(boxes, points, self.precision)
        if self.precision != "fp32" and not bool(torch.isfinite(logits).all()):
            log.warning("segment %s produced non-finite logits, rerunning in fp32", self.precision)
            self.precision = "fp32"
            self.emb = self._embed("fp32")
            logits, iou = self._decode(boxes, points, "fp32")
        logits = F.interpolate(logits, size=self.out_hw, mode="bilinear", align_corners=False)
        return logits.cpu().numpy(), iou.cpu().numpy()


def _dummy_image(h: int = 768, w: int = 1024) -> Image.Image:
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    img = np.stack([200 - 120 * yy / h, 180 - 60 * xx / w, 160 + 40 * np.sin(xx / 23)], -1)
    img[h // 4 : h // 2, w // 3 : w // 2] = (30, 40, 200)  # a block to segment
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))


def _load() -> None:
    global _model, _processor, _device, _precision, _load_error
    with _load_lock:
        if _model is not None:
            return
        if _load_error and time.time() - _load_error[0] < RELOAD_AFTER_S:
            raise SegmenterUnavailable(f"segmenter unavailable: {_load_error[1]}")
        try:
            from transformers import Sam2Model, Sam2Processor
            from transformers.utils import logging as hf_logging

            hf_logging.set_verbosity_error()  # "sam2_video checkpoint into Sam2Model" is expected
            t0 = time.perf_counter()
            device = _pick_device()
            try:  # use the HF cache without network round-trips; download on first run only
                processor = Sam2Processor.from_pretrained(MODEL_ID, local_files_only=True)
                model = Sam2Model.from_pretrained(MODEL_ID, local_files_only=True)
            except Exception:
                processor = Sam2Processor.from_pretrained(MODEL_ID)
                model = Sam2Model.from_pretrained(MODEL_ID)
            model = model.to(device).eval()
            _model, _processor, _device = model, processor, device

            forced = os.environ.get("SEGMENT_PRECISION", "").strip().lower()
            order = [forced] if forced else (["fp32"] if device.type == "cpu" else ["fp16", "fp32"])
            dummy, box = _dummy_image(), [[1024 / 3 - 8, 768 / 4 - 8, 1024 / 2 + 8, 768 / 2 + 8]]
            for name in order:  # precision probe; also compiles the MPS kernels
                try:
                    with _SamSession(dummy, (96, 128), name) as sam:
                        logits, _ = sam._decode(box, None, name)
                    if bool(torch.isfinite(logits).all()):
                        _precision = name
                        break
                    log.warning("segment precision %s produced NaNs, trying next", name)
                except Exception:
                    log.exception("segment precision %s failed, trying next", name)
            else:
                raise RuntimeError(f"{MODEL_ID} failed at every precision on {device}")
            _load_error = None
            log.info("segment model %s ready on %s/%s in %.1fs", MODEL_ID, device.type,
                     _precision, time.perf_counter() - t0)
        except Exception as exc:
            _model = _processor = None
            _load_error = (time.time(), f"{type(exc).__name__}: {exc}")
            raise


def warmup() -> None:
    """Load the model (once); _load runs the dummy pass (precision probe + MPS kernel compile)."""
    _load()


# ---------------------------------------------------------------- geometry helpers


def _decode_image(image_bytes: bytes) -> Image.Image:
    try:
        img = Image.open(io.BytesIO(image_bytes))
        img = ImageOps.exif_transpose(img)  # browser already did this; matches depth.load_rgb
        return img.convert("RGB")
    except (UnidentifiedImageError, OSError) as exc:
        raise ValueError(f"could not decode image: {exc}") from exc


def _mask_size(w: int, h: int) -> tuple[int, int]:
    s = min(1.0, MASK_LONG_SIDE / max(w, h))
    return max(1, round(w * s)), max(1, round(h * s))


def _parse_regions(regions) -> list[dict]:
    if not isinstance(regions, list):
        raise ValueError("regions must be a list of {id, box, tag, note}")
    out = []
    for i, r in enumerate(regions):
        rid = str(r.get("id") or f"r{i + 1}") if isinstance(r, dict) else f"r{i + 1}"
        box = None
        try:
            b = r["box"]
            x0, y0 = float(b["x"]), float(b["y"])
            x1, y1 = x0 + float(b["w"]), y0 + float(b["h"])
            x0, x1 = sorted((min(max(x0, 0.0), 1.0), min(max(x1, 0.0), 1.0)))
            y0, y1 = sorted((min(max(y0, 0.0), 1.0), min(max(y1, 0.0), 1.0)))
            if x1 - x0 > 1e-3 and y1 - y0 > 1e-3:
                box = (x0, y0, x1, y1)
        except (KeyError, TypeError, ValueError, AttributeError):
            pass
        out.append({"id": rid, "box": box, "tag": (r.get("tag") if isinstance(r, dict) else None)})
    return out


def _box_px(box, w: int, h: int) -> tuple[int, int, int, int]:
    """Normalized (x0,y0,x1,y1) -> integer pixel bounds [x0, x1) x [y0, y1), at least 1 px."""
    x0, y0, x1, y1 = box
    px0, py0 = min(int(np.floor(x0 * w)), w - 1), min(int(np.floor(y0 * h)), h - 1)
    px1, py1 = max(int(np.ceil(x1 * w)), px0 + 1), max(int(np.ceil(y1 * h)), py0 + 1)
    return px0, py0, min(px1, w), min(py1, h)


def _rect(shape, x0, y0, x1, y1) -> np.ndarray:
    m = np.zeros(shape, bool)
    m[max(0, y0) : max(0, y1), max(0, x0) : max(0, x1)] = True
    return m


def _grown(b, w: int, h: int, frac: float, pad: int = 4) -> tuple[int, int, int, int]:
    x0, y0, x1, y1 = b
    mx, my = int(frac * (x1 - x0)) + pad, int(frac * (y1 - y0)) + pad
    return max(0, x0 - mx), max(0, y0 - my), min(w, x1 + mx), min(h, y1 + my)


def _keep_major(mask: np.ndarray, frac: float = SPECK_FRAC) -> np.ndarray:
    lab, n = ndi.label(mask)
    if n <= 1:
        return mask
    sizes = np.bincount(lab.ravel())[1:]
    keep = np.flatnonzero(sizes >= frac * sizes.max()) + 1
    return np.isin(lab, keep)


def _fill_small_holes(mask: np.ndarray, frac: float = HOLE_FRAC,
                      L: np.ndarray | None = None) -> np.ndarray:
    """Fill enclosed holes smaller than frac of the mask; with depth, only those at its depth
    (a gap between arms showing the far background stays open)."""
    holes = ndi.binary_fill_holes(mask) & ~mask
    if not holes.any():
        return mask
    lab, n = ndi.label(holes)
    sizes = np.bincount(lab.ravel())[1:]
    small = np.flatnonzero(sizes < max(16, frac * mask.sum())) + 1
    if L is not None and small.size:
        med = float(np.median(L[mask]))
        hole_med = ndi.median(L, lab, small)
        small = small[np.abs(np.asarray(hole_med) - med) < DEV_MIN]
    return mask | np.isin(lab, small)


def _bbox_iou(mask: np.ndarray, b) -> float:
    ys, xs = np.nonzero(mask)
    if xs.size == 0:
        return 0.0
    mx0, mx1 = np.percentile(xs, [1, 99])
    my0, my1 = np.percentile(ys, [1, 99])
    x0, y0, x1, y1 = b
    iw = max(0.0, min(mx1 + 1, x1) - max(mx0, x0))
    ih = max(0.0, min(my1 + 1, y1) - max(my0, y0))
    inter = iw * ih
    union = (mx1 + 1 - mx0) * (my1 + 1 - my0) + (x1 - x0) * (y1 - y0) - inter
    return float(inter / union) if union > 0 else 0.0


# ---------------------------------------------------------------- mask choice


def _choose(logits: np.ndarray, ious: np.ndarray, b, crop) -> tuple[np.ndarray, list[dict], int]:
    """Pick the candidate that best is 'the thing in the box'. logits: K x H x W at mask size."""
    h, w = logits.shape[1:]
    boxm = _rect((h, w), *b)
    cropm = _rect((h, w), *crop)
    box_area = max(1, int(boxm.sum()))
    best, best_score, metrics, best_mask = -1, -np.inf, [], None
    masks_k: list[np.ndarray] = []
    for k in range(logits.shape[0]):
        lk = logits[k][crop[1] : crop[3], crop[0] : crop[2]]
        raw_in = int((lk > 0).sum())
        m = _keep_major((logits[k] > 0) & cropm)
        area = int(m.sum())
        if area == 0:
            metrics.append({"k": k, "iou": round(float(ious[k]), 3), "score": None})
            masks_k.append(m)
            continue
        stab = float((lk > 1.0).sum()) / max(1, int((lk > -1.0).sum()))  # SAM stability score
        frag = 1.0 - area / max(1, raw_in)  # share lost to specks: garbage masks are fragmented
        inside = float((m & boxm).sum()) / area  # share of the mask inside the box
        fill = float((m & boxm).sum()) / box_area  # share of the box the mask covers
        biou = _bbox_iou(m, b)  # the object's extent vs the box (Gemini boxes are tight)
        raw = float(((logits[k] > 0) & ~cropm).sum()) / max(1, area)  # leak beyond the crop
        # quality (SAM's own IoU guess + stability) plus fit to the box. SAM's IoU alone prefers
        # crisp parts (hair over a whole head); garbage masks show up as unstable/fragmented.
        score = (0.5 * float(ious[k]) + 0.5 * stab + 0.6 * (biou + fill)
                 - 1.0 * max(0.0, 0.6 - stab) - 0.8 * max(0.0, 0.85 - inside)
                 - 0.5 * min(1.0, raw) - 0.5 * frag)
        metrics.append({"k": k, "iou": round(float(ious[k]), 3), "stab": round(stab, 3),
                        "frag": round(frag, 3), "fill": round(fill, 3),
                        "inside": round(inside, 3), "biou": round(biou, 3),
                        "leak": round(raw, 3), "score": round(score, 3)})
        if score > best_score:
            best, best_score, best_mask = k, score, m
        masks_k.append(m)
    if best_mask is None:
        return np.zeros((h, w), bool), metrics, best
    # SAM often splits a box holding two things (walker + dog) across near-tied candidates
    for c, m in zip(metrics, masks_k):
        if (c["k"] != best and c.get("score") is not None
                and c["score"] >= best_score - TIE_MARGIN
                and c["stab"] >= 0.6 and c["inside"] >= 0.9):
            best_mask = best_mask | m
            c["merged"] = True
    return best_mask, metrics, best


def _to_img(b, sam) -> list[float]:
    """Mask-pixel box -> image-pixel box for SAM."""
    sx, sy = sam.W / sam.out_hw[1], sam.H / sam.out_hw[0]
    return [b[0] * sx, b[1] * sy, b[2] * sx, b[3] * sy]


def _expand_group(sam, mask: np.ndarray, b, L: np.ndarray, G: np.ndarray):
    """A box around several things ("four friends", "walker and dog") gets one of them from SAM.

    If the mask explains the box poorly, find blobs inside the box at roughly the mask's depth
    that the mask misses, prompt SAM with a sub-box around each, and add the clean results that
    sit at that depth inside the box. Repeats a few rounds (each addition can reveal the next)."""
    h, w = mask.shape
    boxm = _rect(mask.shape, *b)
    box_area = max(1, int(boxm.sum()))
    fill0 = float((mask & boxm).sum()) / box_area
    biou0 = _bbox_iou(mask, b)
    info = {"fill": round(fill0, 3), "biou": round(biou0, 3), "added": 0, "subs": []}
    if fill0 >= GROUP_FILL or biou0 >= GROUP_BIOU:
        return mask, info
    med = float(np.median(L[mask]))
    cropm = _rect(mask.shape, *_grown(b, w, h, BOX_MARGIN))
    near_depth = boxm & (np.abs(L - med) < GROUP_DEV)
    out, tried = mask.copy(), np.zeros_like(mask)
    for _round in range(GROUP_ROUNDS):
        seed = near_depth & ~ndi.binary_dilation(out | tried, iterations=4)
        seed = ndi.binary_opening(seed, np.ones((5, 5), bool), iterations=2)
        lab, n = ndi.label(seed)
        sizes = np.bincount(lab.ravel(), minlength=n + 1)
        comps = sorted((i for i in range(1, n + 1) if sizes[i] >= GROUP_MIN * box_area),
                       key=lambda i: -sizes[i])[:GROUP_MAX]
        if not comps:
            break
        subs = []
        for i in comps:
            ys, xs = np.nonzero(lab == i)
            subs.append((int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1))
        logits, iou = sam.decode([_to_img(sb, sam) for sb in subs])
        added = 0
        for j, (sb, i) in enumerate(zip(subs, comps)):
            blob = lab == i
            m2, cands, k = _choose(logits[j], iou[j], sb, _grown(sb, w, h, 0.05))
            m2 &= cropm & ~out
            if k < 0 or m2.sum() < GROUP_MIN * box_area * 0.5:
                tried |= blob
                continue
            c = cands[k]
            inside = float((m2 & boxm).sum()) / max(1, int(m2.sum()))
            dev = abs(float(np.median(L[m2])) - med)
            on_blob = float((m2 & blob).sum()) / max(1, int(m2.sum()))
            rim = m2 & ~ndi.binary_erosion(m2, iterations=2) & ~ndi.binary_dilation(out, iterations=3)
            rim[[0, -1], :] = rim[:, [0, -1]] = False
            edge = float((G[rim] > 0.5 * EDGE_GRAD).mean()) if rim.any() else 0.0
            clean = ((c["iou"] >= 0.75 and c["stab"] >= 0.75)
                     or (c["iou"] >= 0.5 and c["stab"] >= 0.9))
            ok = (clean and inside >= 0.85
                  and dev < GROUP_DEV and on_blob >= 0.5 and edge >= GROUP_EDGE)
            info["subs"].append({"iou": c["iou"], "stab": c["stab"], "inside": round(inside, 2),
                                 "dev": round(dev, 2), "on_blob": round(on_blob, 2),
                                 "edge": round(edge, 2), "frac": round(m2.sum() / box_area, 3),
                                 "ok": ok})
            if ok:  # the rest of the blob may hold another member: seed it next round
                out |= m2
                added += 1
            else:
                tried |= blob
        info["added"] += added
        if not added or float((out & boxm).sum()) / box_area >= GROUP_FILL:
            break
    return (_fill_small_holes(out, L=L) if info["added"] else mask), info


# ---------------------------------------------------------------- depth


def _log_depth(depth_m: np.ndarray, w: int, h: int) -> tuple[np.ndarray, np.ndarray]:
    """Capped log-depth resized to the mask size, and its gradient magnitude (per depth pixel)."""
    L = np.log(np.clip(depth_m, 0.05, SKY_CAP_M)).astype(np.float32)
    gy, gx = np.gradient(L)
    g = np.hypot(gx, gy)
    g = ndi.maximum_filter(g, size=3)  # an edge counts for the pixels on both sides of it
    t = torch.from_numpy(np.stack([L, g]))[None]
    t = F.interpolate(t, size=(h, w), mode="bilinear", align_corners=False)[0].numpy()
    return t[0], t[1]


def _refine_with_depth(mask: np.ndarray, L: np.ndarray, G: np.ndarray) -> tuple[np.ndarray, dict]:
    """Cut parts of the mask at a clearly different depth that meet it across a depth edge."""
    area = int(mask.sum())
    info = {"applied": False}
    if area < 64:
        return mask, info
    vals = L[mask]
    med = float(np.median(vals))
    mad = float(np.median(np.abs(vals - med))) * 1.4826
    thr = max(DEV_MIN, DEV_MAD * mad)
    info.update(med_m=round(float(np.exp(med)), 2), mad=round(mad, 3), thr=round(thr, 3))
    cand = mask & (np.abs(L - med) > thr)
    if cand.sum() < LEAK_MIN_FRAC * area:
        return mask, info
    lab, n = ndi.label(cand)
    sizes = np.bincount(lab.ravel(), minlength=n + 1)
    cut = np.zeros_like(mask)
    leaks = []
    ring = np.ones((3, 3), bool)
    core_px = max(1, round(CORE_DEPTH_PX * max(mask.shape) / 512))  # ~3 depth pixels
    sky = med >= np.log(SKY_CAP_M) - 0.01  # the mask is (mostly) sky
    pad = core_px + 3
    for i, sl in enumerate(ndi.find_objects(lab), 1):
        if sl is None or sizes[i] < LEAK_MIN_FRAC * area:
            continue
        ys = slice(max(0, sl[0].start - pad), sl[0].stop + pad)
        xs = slice(max(0, sl[1].start - pad), sl[1].stop + pad)
        comp = lab[ys, xs] == i
        # Thin parts (legs, a hand, a strip along an occluder) are where coarse depth bleeds
        # across edges; a real leak is a broad patch that keeps a core after erosion.
        core = int(ndi.binary_erosion(comp, iterations=core_px).sum())
        rest = mask[ys, xs] & ~comp
        contact = comp & ndi.binary_dilation(rest, ring, iterations=2)
        if not contact.any():  # detached island at another depth (already dropped if tiny)
            continue
        edge = float((G[ys, xs][contact] > EDGE_GRAD).mean())
        leak = {"frac": round(float(sizes[i] / area), 3), "edge": round(edge, 2),
                "core": round(core / sizes[i], 2),
                "dev": round(float(np.median(L[ys, xs][comp]) - med), 2)}
        # In a sky mask anything with a finite depth is clearly not sky (Depth Pro's sky is
        # reliable), so thin trees/wires on the horizon go too; objects need a broad leak.
        leak["cut"] = edge >= EDGE_FRAC and (sky or core >= max(30, CORE_FRAC * sizes[i]))
        leaks.append(leak)
        if leak["cut"]:
            cut[ys, xs] |= comp
    info["leaks"] = leaks
    if not cut.any() or cut.sum() > LEAK_MAX_FRAC * area:
        info["skipped"] = bool(cut.any())
        return mask, info
    # widen the cut by a pixel into the blurred depth edge, then drop slivers left along it
    cut |= ndi.binary_dilation(cut, ring, iterations=2) & (np.abs(L - med) > 0.6 * thr)
    out = mask & ~cut
    near = ndi.binary_dilation(cut, ring, iterations=3)
    out &= ~(near & ~ndi.binary_opening(out, ring, iterations=2))
    out = _keep_major(out)
    info["applied"] = True
    info["cut_frac"] = round(1.0 - out.sum() / area, 3)
    return out, info


def _scatter(mask: np.ndarray, b) -> dict:
    """How fragmented the mask is inside its box. SAM picks one object per box, so a box around
    an overlapping group comes back as a few heads and arms; those get the box's depth layer."""
    x0, y0, x1, y1 = b
    sub = mask[y0:y1, x0:x1]
    area = max(1, sub.size)
    lab, n = ndi.label(sub)
    sizes = np.bincount(lab.ravel())[1:] if n else np.zeros(0, int)
    parts = int((sizes >= SCATTER_PART_MIN * area).sum())
    fill = float(sub.sum()) / area
    return {"parts": parts, "fill": round(fill, 3),
            "is": parts >= SCATTER_PARTS and fill < SCATTER_FILL}


def _box_depth_mask(b, L: np.ndarray | None, shape, near: bool = False) -> tuple[np.ndarray, str]:
    """Fallback: box intersected with the dominant depth cluster inside it. near=True also keeps
    everything in front of that cluster (a group: the closest person stands before the rest)."""
    h, w = shape
    boxm = _rect(shape, *b)
    if L is None:
        return boxm, "box"
    x0, y0, x1, y1 = b
    vals = L[y0:y1, x0:x1]
    # weight pixels toward the box center: the dominant cluster is usually the boxed thing
    yy, xx = np.mgrid[0 : y1 - y0, 0 : x1 - x0].astype(np.float32)
    cy, cx = (y1 - y0 - 1) / 2, (x1 - x0 - 1) / 2
    wgt = np.exp(-(((yy - cy) / max(1.0, 0.5 * (y1 - y0))) ** 2
                   + ((xx - cx) / max(1.0, 0.5 * (x1 - x0))) ** 2))
    lo_v, hi_v = float(vals.min()), float(vals.max())
    if hi_v - lo_v < 1e-3:
        return boxm, "box+depth"
    nb = max(8, int((hi_v - lo_v) / 0.05))
    hist, edges = np.histogram(vals, bins=nb, range=(lo_v, hi_v), weights=wgt)
    hist = ndi.gaussian_filter1d(hist.astype(np.float64), 1.5)
    p = int(hist.argmax())
    lo, hi = p, p
    while lo > 0 and hist[lo - 1] > 0.1 * hist[p]:
        lo -= 1
    while hi < nb - 1 and hist[hi + 1] > 0.1 * hist[p]:
        hi += 1
    inband = (vals <= edges[hi + 1]) if near else (vals >= edges[lo]) & (vals <= edges[hi + 1])
    m = np.zeros(shape, bool)
    m[y0:y1, x0:x1] = inband
    m = ndi.binary_opening(m, np.ones((3, 3), bool))
    m = _fill_small_holes(_keep_major(m, 0.1), 0.02)
    if m.sum() < 0.05 * boxm.sum():  # depth gave nothing sensible: use the box
        return boxm, "box"
    return m, "box+depth"


# ---------------------------------------------------------------- output


def _encode(mask: np.ndarray) -> tuple[str, float]:
    soft = ndi.gaussian_filter(mask.astype(np.float32), sigma=0.8)  # ~1-2 px feathered edge
    u8 = np.clip(np.rint(soft * 255.0), 0, 255).astype(np.uint8)
    buf = io.BytesIO()
    Image.fromarray(u8).save(buf, format="PNG")
    url = "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode("ascii")
    return url, float(u8.mean() / 255.0)


def segment_regions(image_bytes: bytes, regions) -> dict:
    """One full-image soft mask per region (see CONTRACT.md `/api/masks`)."""
    t0 = time.perf_counter()
    regs = _parse_regions(regions)
    pil = _decode_image(image_bytes)
    W, H = pil.size
    mw, mh = _mask_size(W, H)
    timing: dict[str, int] = {}
    dbg: dict = {"regions": {}, "timing": timing}

    # depth (cached by depth.py when /api/depth already ran on these bytes)
    L = G = None
    t = time.perf_counter()
    try:
        import depth

        dmap, _meta = depth.infer_depth(image_bytes)
        L, G = _log_depth(dmap, mw, mh)
    except Exception:
        log.exception("depth unavailable for segment refinement")
    timing["depth"] = int((time.perf_counter() - t) * 1000)

    boxes = {r["id"]: _box_px(r["box"], mw, mh) for r in regs if r["box"] is not None}
    sam_masks: dict[str, np.ndarray] = {}
    sam_error = None
    if boxes:
        t = time.perf_counter()
        try:
            _load()
            with _SamSession(pil, (mh, mw)) as sam:
                ids = list(boxes)
                logits, iou = sam.decode([_to_img(boxes[i], sam) for i in ids])
                for j, rid in enumerate(ids):
                    d = dbg["regions"].setdefault(rid, {})
                    b = boxes[rid]
                    m, d["cands"], d["chosen"] = _choose(logits[j], iou[j], b,
                                                         _grown(b, mw, mh, BOX_MARGIN))
                    m = _fill_small_holes(m, L=L)
                    if L is not None and m.any():
                        m, d["group"] = _expand_group(sam, m, b, L, G)
                    sam_masks[rid] = m
        except Exception as exc:
            sam_masks = {}
            sam_error = f"{type(exc).__name__}: {exc}"
            if isinstance(exc, SegmenterUnavailable):  # already logged with traceback at load
                log.warning("%s; falling back to box+depth", exc)
            else:
                log.exception("segmenter failed; falling back to box+depth")
        timing["sam"] = int((time.perf_counter() - t) * 1000)

    t = time.perf_counter()
    masks = {}
    for r in regs:
        rid = r["id"]
        d = dbg["regions"].setdefault(rid, {})
        if r["box"] is None:
            mask, source = np.zeros((mh, mw), bool), "empty"
        elif rid in sam_masks and sam_masks[rid].any():
            mask, source = sam_masks[rid], MODEL_TAG
            if L is not None:
                mask, d["depth"] = _refine_with_depth(mask, L, G)
                if d["depth"].get("applied"):
                    source = f"{MODEL_TAG}+depth"
                d["scatter"] = _scatter(mask, boxes[rid])
                if d["scatter"]["is"]:
                    layer, how = _box_depth_mask(boxes[rid], L, (mh, mw), near=True)
                    if how == "box+depth":
                        mask = _fill_small_holes(mask | layer, L=L)
                        source = f"{MODEL_TAG}+layer"
        else:  # segmenter unavailable, or it found nothing in the box
            mask, source = _box_depth_mask(boxes[rid], L, (mh, mw))
        png, area = _encode(mask)
        masks[rid] = {"png": png, "width": mw, "height": mh, "area": round(area, 4),
                      "source": source}
    timing["post"] = int((time.perf_counter() - t) * 1000)

    last_debug.clear()
    last_debug.update(dbg, sam_error=sam_error)
    model = "box+depth" if sam_error else MODEL_ID
    return {"masks": masks, "model": model, "ms": int((time.perf_counter() - t0) * 1000)}
