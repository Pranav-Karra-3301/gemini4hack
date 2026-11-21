"""Semantic edit masks and local edit layers: docs/CORE_API.md §7.

  POST /api/semantic-masks              multipart image (+ labels JSON list) -> masks (stateless)
  POST /api/shots/{id}/semantic         compute + store library/<id>/semantic/ (assets.semantic)
  GET  /api/shots/{id}/semantic/{name}  semantic.json or <mask>.png
  POST /api/shots/{id}/edit/local       {goal, values} -> {summary, values, layers, subject, ...}

For other modules: `await ensure_semantic(shot_id)` (the pipeline runs it after `masks`) and
`clean_layers(layers)` (validates a recipe's `layers`).

How the masks are made (experiments/masks/REPORT.md):
  1. Gemini (TARGETS_MODEL, ~14 s: the bottleneck) lists the edit targets: per item a kind, a
     label, a tight box, 2-3 points on it and 0-2 negative points, plus the subject ids. Cached by
     sha1(image) + labels in memory and in cache/semantic/; identical concurrent requests share one
     call.
  2. Under shots._gpu (the one lock Depth Pro, SAM and SHARP share): depth.infer_depth (LRU-cached
     by content, so the pipeline's depth map is reused) and SAM 2.1 (segment.py's model, one
     embedding, one box+points decode per target).
  3. CPU, outside the lock: segment.py's depth leak cut on every item (plus a tighter one for
     water and ground, which span 3 m to the horizon); sky = Depth Pro's "infinitely far" pixels
     in Gemini's sky box; stuff
     masks (sky, water, foliage, ground, buildings) grow 3 px and become the exact complement of
     the people matte; a guided filter snaps every edge to the photo; then unions per kind,
     `subject` (Gemini's subject ids, else the people) and `background` (1 - subject, its edge
     following the depth step).
If SAM is unavailable each target falls back to segment.py's box+depth mask.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import io
import json
import logging
import os
import re
import secrets
import time
from collections import OrderedDict
from pathlib import Path

import numpy as np
from fastapi import APIRouter, File, Form, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from PIL import Image, ImageOps, UnidentifiedImageError
from scipy import ndimage as ndi

import depth
import edit
import gemini
import segment
import shots

log = logging.getLogger("semantic")
router = APIRouter()

SERVER = Path(__file__).resolve().parent
CACHE = SERVER / "cache" / "semantic"
TARGETS_MODEL = os.environ.get("SEMANTIC_TARGETS_MODEL", "gemini-4-hydrogen")
PLAN_MODEL = os.environ.get("SEMANTIC_PLAN_MODEL", "gemini-4-hydrogen")
PROMPT_V = 1  # bump when TARGETS_PROMPT changes: invalidates the targets cache
IMAGE_SIDE = 1536  # SAM's input (shots' image.jpg is already this size)
GEMINI_SIDE = 1024
MASK_LONG = 1024
MAX_UPLOAD = 60 * 1024 * 1024
MAX_LABELS, LABEL_CHARS = 12, 40
MAX_TARGETS = 24
MAX_LAYERS = 5
MAX_SUBTRACT = 4
MEM_CACHE = 64
SURFACE_DEV = 1.0  # water/ground: parts this far from the median log depth (x2.7) may be leaks
SKY_FAR_M = 3e3  # Depth Pro returns sky as a constant 1e6-6e7 m; real terrain stays below this
KINDS = ["person", "face", "sky", "water", "foliage", "ground", "building", "object", "distraction"]
STUFF = {"sky", "water", "foliage", "ground", "building"}
UNION = {"person": "people", "face": "faces", "sky": "sky", "water": "water", "foliage": "foliage",
         "ground": "ground", "building": "buildings", "object": "objects", "distraction": "distraction"}
DEFAULT_LABELS = ["people", "faces", "sky", "water", "foliage", "ground", "distraction"]
NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
LAYER_SLIDERS = ["exposure", "contrast", "highlights", "shadows", "whites", "blacks", "warmth", "tint",
                 "vibrance", "saturation", "clarity"]
GLOBAL_SLIDERS = LAYER_SLIDERS + ["vignette"]
EDGES = ("image", "depth", "none")

_targets_mem: OrderedDict[str, dict] = OrderedDict()
_targets_inflight: dict[str, asyncio.Task] = {}
_shot_inflight: dict[str, asyncio.Task] = {}
_plan_cache: OrderedDict[tuple, dict] = OrderedDict()
_plan_inflight: dict[tuple, asyncio.Task] = {}


def _err(status: int, msg) -> JSONResponse:
    return JSONResponse({"error": str(msg)[:400]}, status_code=status)


def _ms(t0: float) -> int:
    return int((time.perf_counter() - t0) * 1000)


# ------------------------------------------------------------------------------------------------
# 1. targets (Gemini)

TARGETS_PROMPT = """You are preparing local-adjustment masks for a photo editor (like Lightroom masks).
Find these edit targets in the photo: {labels}.

Rules:
- One entry per separate instance: each person, each face, each separate patch of foliage or ground
  (at most 3 per kind; merge tiny patches). Skip kinds that are not in the photo.
- kind: one of person, face, sky, water, foliage, ground, building, object, distraction.
  "distraction" = the single element that most pulls the eye away from the subject (a bright
  sign, a car, a stranger, a trash can, a busy patch of pavement), only if there is one.
- box_2d: tight [ymin, xmin, ymax, xmax], normalized 0-1000, around the visible pixels.
- points: 2-3 [y, x] points (0-1000) that lie ON the target's own pixels, spread across it and away
  from its edges (face: cheeks and forehead; person: chest and head; sky: open sky away from trees).
- neg_points: 0-2 [y, x] points inside the box that belong to something else (an overlapping
  person, a tree in front of the sky). Empty if none.
- label: short and descriptive ("man in red shirt", "sea", "parked car").
- subject: ids of the targets that are the photo's subject (usually the people)."""

TARGETS_SCHEMA = {
    "type": "object",
    "properties": {
        "targets": {"type": "array", "items": {"type": "object", "properties": {
            "id": {"type": "string"},
            "label": {"type": "string"},
            "kind": {"type": "string", "enum": KINDS},
            "box_2d": {"type": "array", "items": {"type": "integer"}},
            "points": {"type": "array", "items": {"type": "array", "items": {"type": "integer"}}},
            "neg_points": {"type": "array", "items": {"type": "array", "items": {"type": "integer"}}},
        }, "required": ["id", "label", "kind", "box_2d", "points"]}},
        "subject": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["targets", "subject"],
}


def _clean_labels(labels) -> list[str]:
    if labels is None:
        return list(DEFAULT_LABELS)
    if not isinstance(labels, list) or not all(isinstance(x, str) for x in labels):
        raise ValueError("labels must be a JSON list of strings")
    out = []
    for x in labels:
        x = " ".join(x.split())[:LABEL_CHARS]
        if x and x not in out:
            out.append(x)
    if len(out) > MAX_LABELS:
        raise ValueError(f"at most {MAX_LABELS} labels")
    return out or list(DEFAULT_LABELS)


def _num(v, lo: float, hi: float) -> float | None:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return min(max(f, lo), hi) if np.isfinite(f) else None


def _yx_points(pts, n: int) -> list[list[int]]:
    out = []
    for p in pts if isinstance(pts, list) else []:
        if isinstance(p, list) and len(p) >= 2:
            y, x = _num(p[0], 0, 1000), _num(p[1], 0, 1000)
            if y is not None and x is not None:
                out.append([int(round(y)), int(round(x))])
    return out[:n]


def _clean_targets(data: dict) -> dict:
    """Gemini's reply -> {targets: [{id t1.., label, kind, box {x,y,w,h} 0..1, box_2d, points,
    neg_points}], subject: [ids]}. Model ids are free-form ("sky" would clash with a union)."""
    targets, remap = [], {}
    for t in (data.get("targets") or [])[:MAX_TARGETS] if isinstance(data, dict) else []:
        if not isinstance(t, dict) or t.get("kind") not in KINDS:
            continue
        b = t.get("box_2d")
        vals = [_num(v, 0, 1000) for v in b[:4]] if isinstance(b, list) and len(b) >= 4 else [None]
        if None in vals:
            continue
        y0, x0, y1, x1 = vals
        x0, x1, y0, y1 = min(x0, x1) / 1000, max(x0, x1) / 1000, min(y0, y1) / 1000, max(y0, y1) / 1000
        if x1 - x0 < 0.003 or y1 - y0 < 0.003:
            continue
        tid = f"t{len(targets) + 1}"
        remap.setdefault(str(t.get("id")), tid)
        targets.append({
            "id": tid, "label": " ".join(str(t.get("label") or t["kind"]).split())[:60], "kind": t["kind"],
            "box": {"x": round(x0, 4), "y": round(y0, 4), "w": round(x1 - x0, 4), "h": round(y1 - y0, 4)},
            "box_2d": [int(round(v)) for v in vals], "points": _yx_points(t.get("points"), 3),
            "neg_points": _yx_points(t.get("neg_points"), 2),
        })
    subject = []
    for i in data.get("subject") or [] if isinstance(data, dict) else []:
        tid = remap.get(str(i))
        if tid and tid not in subject:
            subject.append(tid)
    return {"targets": targets, "subject": subject}


def _targets_key(image: bytes, labels: list[str]) -> str:
    tag = hashlib.sha1(json.dumps([labels, TARGETS_MODEL, PROMPT_V]).encode()).hexdigest()[:10]
    return f"{hashlib.sha1(image).hexdigest()}-{tag}"


def _remember(key: str, found: dict) -> None:
    _targets_mem[key] = found
    _targets_mem.move_to_end(key)
    while len(_targets_mem) > MEM_CACHE:
        _targets_mem.popitem(last=False)


def _disk_read(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def _disk_write(path: Path, data: dict) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f".{path.name}.{secrets.token_hex(3)}")
        tmp.write_text(json.dumps(data, separators=(",", ":")))
        os.replace(tmp, path)
    except OSError:
        log.warning("could not write %s", path)


async def _call_targets(image: bytes, labels: list[str], key: str) -> dict:
    jpg = await asyncio.to_thread(gemini.prepare_jpeg, image, GEMINI_SIDE, 88)
    reply = await gemini.generate(
        TARGETS_MODEL, [gemini.image_part(jpg), TARGETS_PROMPT.format(labels=", ".join(labels))],
        schema=TARGETS_SCHEMA, thinking="low", media_resolution="high", tag="semantic_targets",
        timeout=75)
    found = _clean_targets(reply.data) | {"model": TARGETS_MODEL, "ms": reply.ms}
    _remember(key, found)
    await asyncio.to_thread(_disk_write, CACHE / f"targets-{key}.json", found)
    return found


async def find_targets(image: bytes, labels: list[str]) -> tuple[dict, bool]:
    """Gemini's edit targets for these image bytes: ({targets, subject, model, ms}, cached)."""
    key = _targets_key(image, labels)
    hit = _targets_mem.get(key)
    if hit is None:
        hit = await asyncio.to_thread(_disk_read, CACHE / f"targets-{key}.json")
        if hit is not None:
            _remember(key, hit)
    if hit is not None:
        _targets_mem.move_to_end(key)
        return hit, True
    task = _targets_inflight.get(key)
    if task is None:  # identical concurrent requests share one Gemini call
        task = asyncio.create_task(_call_targets(image, labels, key))
        _targets_inflight[key] = task
        task.add_done_callback(lambda _t: _targets_inflight.pop(key, None))
    return await asyncio.shield(task), False


# ------------------------------------------------------------------------------------------------
# 2. SAM 2.1 + depth (GPU, under shots._gpu)


def _work_image(image: bytes) -> tuple[Image.Image, np.ndarray, tuple[int, int]]:
    """Upright RGB at <= IMAGE_SIDE (SAM's input), the float image at mask size, and (h, w)."""
    try:
        im = Image.open(io.BytesIO(image))
        im.draft("RGB", (IMAGE_SIDE, IMAGE_SIDE))
        im = ImageOps.exif_transpose(im).convert("RGB")
    except (UnidentifiedImageError, OSError) as exc:
        raise ValueError(f"could not decode image: {exc}") from exc
    im.thumbnail((IMAGE_SIDE, IMAGE_SIDE), Image.LANCZOS)
    W, H = im.size
    s = min(1.0, MASK_LONG / max(W, H))
    hw = (max(1, round(H * s)), max(1, round(W * s)))
    img = np.asarray(im.resize((hw[1], hw[0]), Image.LANCZOS), np.float32) / 255.0
    return im, img, hw


def _xyxy(t: dict) -> tuple[float, float, float, float]:
    b = t["box"]
    return b["x"], b["y"], b["x"] + b["w"], b["y"] + b["h"]


def _sam_targets(pil: Image.Image, targets: list[dict], hw: tuple[int, int]) -> dict[str, np.ndarray]:
    """Binary mask per target from its box and points together (one decoder pass each, ~10 ms)."""
    mh, mw = hw
    W, H = pil.size
    segment._load()
    out = {}
    with segment._SamSession(pil, hw) as sam:  # holds segment's own inference lock too
        for t in targets:
            x0, y0, x1, y1 = _xyxy(t)
            pts = [(p[1] / 1000 * W, p[0] / 1000 * H, 1) for p in t["points"]]
            pts += [(p[1] / 1000 * W, p[0] / 1000 * H, 0) for p in t["neg_points"]]
            logits, iou = sam.decode([[x0 * W, y0 * H, x1 * W, y1 * H]], [pts] if pts else None)
            b = segment._box_px((x0, y0, x1, y1), mw, mh)
            m, _, _ = segment._choose(logits[0], iou[0], b, segment._grown(b, mw, mh, segment.BOX_MARGIN))
            out[t["id"]] = segment._fill_small_holes(m)
    return out


def _box_fallback(targets: list[dict], hw: tuple[int, int], dm: np.ndarray | None) -> dict[str, np.ndarray]:
    mh, mw = hw
    L = segment._log_depth(dm, mw, mh)[0] if dm is not None else None
    return {t["id"]: segment._box_depth_mask(segment._box_px(_xyxy(t), mw, mh), L, hw)[0] for t in targets}


def _gpu_pass(image: bytes, pil: Image.Image, targets: list[dict], hw) -> tuple:
    """Depth map + one binary mask per target. Runs in a thread while the caller holds shots._gpu."""
    timing = {}
    t = time.perf_counter()
    try:
        dm, _ = depth.infer_depth(image)
    except Exception:
        log.exception("depth unavailable for semantic masks")
        dm = None
    timing["depth"] = _ms(t)
    t = time.perf_counter()
    how = segment.MODEL_TAG
    try:
        inst = _sam_targets(pil, targets, hw) if targets else {}
    except Exception as exc:
        if isinstance(exc, segment.SegmenterUnavailable):
            log.warning("%s; semantic masks fall back to box+depth", exc)
        else:
            log.exception("SAM failed; semantic masks fall back to box+depth")
        inst, how = _box_fallback(targets, hw, dm), "box+depth"
    timing["sam"] = _ms(t)
    return dm, inst, how, timing


# ------------------------------------------------------------------------------------------------
# 3. refinement and unions (CPU)


def _boxf(x, r):
    return ndi.uniform_filter(x, size=2 * r + 1, mode="reflect")


def guided_filter(I: np.ndarray, p: np.ndarray, r: int, eps: float) -> np.ndarray:
    """Color (HxWx3) or gray (HxW) guided filter (He et al.): edges of p snap to edges of I."""
    p = p.astype(np.float32)
    if I.ndim == 2:
        mI, mp = _boxf(I, r), _boxf(p, r)
        a = (_boxf(I * p, r) - mI * mp) / (_boxf(I * I, r) - mI * mI + eps)
        return _boxf(a, r) * I + _boxf(mp - a * mI, r)
    mI = np.stack([_boxf(I[..., c], r) for c in range(3)], -1)
    mp = _boxf(p, r)
    cov = np.stack([_boxf(I[..., c] * p, r) for c in range(3)], -1) - mI * mp[..., None]
    var = np.empty(I.shape[:2] + (3, 3), np.float32)
    for i in range(3):
        for j in range(i, 3):
            var[..., i, j] = var[..., j, i] = _boxf(I[..., i] * I[..., j], r) - mI[..., i] * mI[..., j]
    var += eps * np.eye(3, dtype=np.float32)
    a = np.linalg.solve(var, cov[..., None])[..., 0]
    b = mp - (a * mI).sum(-1)
    return (np.stack([_boxf(a[..., c], r) for c in range(3)], -1) * I).sum(-1) + _boxf(b, r)


def refine_edges(mask: np.ndarray, img: np.ndarray, r: int = 6, eps: float = 2e-3) -> np.ndarray:
    """Binary -> soft matte that follows image edges (hair, branches), only near the boundary."""
    m = mask.astype(np.float32)
    if not mask.any() or mask.all():
        return m
    band = ndi.binary_dilation(mask, iterations=2 * r) & ~ndi.binary_erosion(mask, iterations=2 * r)
    ys, xs = np.nonzero(band)  # filter only the boundary's bounding box (8-20x faster on small masks)
    pad = 3 * r
    y0, y1 = max(0, ys.min() - pad), min(m.shape[0], ys.max() + pad + 1)
    x0, x1 = max(0, xs.min() - pad), min(m.shape[1], xs.max() + pad + 1)
    out = m.copy()
    soft = np.clip(guided_filter(img[y0:y1, x0:x1], m[y0:y1, x0:x1], r, eps), 0, 1)
    out[y0:y1, x0:x1] = np.where(band[y0:y1, x0:x1], soft, m[y0:y1, x0:x1])
    return out


def _log_depth(dm: np.ndarray, hw) -> np.ndarray:
    L = np.log(np.clip(dm, 0.05, 1e5)).astype(np.float32)
    return np.asarray(Image.fromarray(L).resize((hw[1], hw[0]), Image.BILINEAR), np.float32)


def _sky_from_depth(sam_sky, box, L: np.ndarray, how: str) -> tuple[np.ndarray | None, str]:
    """Sky = 'infinitely far' pixels in/near Gemini's sky box or SAM's sky mask, connected to it."""
    h, w = L.shape
    x0, y0, x1, y1 = box
    where = np.zeros((h, w), bool)
    where[int(y0 * h):int(np.ceil(y1 * h)) + 4, max(0, int(x0 * w) - 4):int(np.ceil(x1 * w)) + 4] = True
    if sam_sky is not None:
        where |= ndi.binary_dilation(sam_sky, iterations=8)
    cand = (L > np.log(SKY_FAR_M)) & where
    if cand.sum() < 0.002 * h * w:  # depth says no sky here: keep SAM's answer
        return sam_sky, how
    lab, _ = ndi.label(cand)
    sizes = np.bincount(lab.ravel())[1:]
    keep = np.flatnonzero(sizes >= 0.02 * sizes.max()) + 1
    return np.isin(lab, keep), "depth+box" if sam_sky is None else f"{how}+depth"


def _cut_surface_leaks(mask: np.ndarray, L: np.ndarray, G: np.ndarray, thr: float = SURFACE_DEV) -> np.ndarray:
    """Water and ground are one continuous surface, often spanning 3 m to the horizon, so
    segment._refine_with_depth's spread-based threshold never fires on them. Here any broad part
    more than `thr` (log depth) from the median that meets the rest across a depth edge (grass in
    front of the sea, a wall on the road) is cut; a smoothly receding surface has no such edge."""
    area = int(mask.sum())
    if area < 64:
        return mask
    med = float(np.median(L[mask]))
    lab, n = ndi.label(mask & (np.abs(L - med) > thr))
    if not n:
        return mask
    sizes = np.bincount(lab.ravel(), minlength=n + 1)
    core_px = max(1, round(segment.CORE_DEPTH_PX * max(mask.shape) / 512))
    ring = np.ones((3, 3), bool)
    cut = np.zeros_like(mask)
    for i, sl in enumerate(ndi.find_objects(lab), 1):
        if sl is None or sizes[i] < segment.LEAK_MIN_FRAC * area:
            continue
        pad = core_px + 3
        ys = slice(max(0, sl[0].start - pad), sl[0].stop + pad)
        xs = slice(max(0, sl[1].start - pad), sl[1].stop + pad)
        comp = lab[ys, xs] == i
        contact = comp & ndi.binary_dilation(mask[ys, xs] & ~comp, ring, iterations=2)
        if not contact.any():
            continue
        core = int(ndi.binary_erosion(comp, iterations=core_px).sum())
        if (G[ys, xs][contact] > segment.EDGE_GRAD).mean() >= segment.EDGE_FRAC \
                and core >= max(30, segment.CORE_FRAC * sizes[i]):
            cut[ys, xs] |= comp
    if not cut.any() or cut.sum() > segment.LEAK_MAX_FRAC * area:
        return mask
    cut |= ndi.binary_dilation(cut, ring, iterations=2) & (np.abs(L - med) > 0.6 * thr)
    return segment._keep_major(mask & ~cut)


def _compose(img, targets, subject_ids, inst, L, how, cut=frozenset()) -> dict[str, dict]:
    """Binary instance masks -> soft masks per instance + unions per kind + subject/background."""
    h, w = img.shape[:2]
    kinds = {t["id"]: t["kind"] for t in targets}
    people = np.zeros((h, w), bool)
    for tid, m in inst.items():
        if kinds.get(tid) in ("person", "face"):
            people |= m
    people_soft = refine_edges(people, img, r=4) if people.any() else people.astype(np.float32)
    soft: dict[str, np.ndarray] = {}
    src: dict[str, str] = {}
    for t in targets:
        tid, k = t["id"], t["kind"]
        m, s = inst.get(tid), f"{how}+depth" if tid in cut else how
        if k == "sky" and L is not None:
            m, s = _sky_from_depth(m, _xyxy(t), L, how)
        if m is None:
            continue
        if k in STUFF:
            # people stand in front of sea, grass, road: grow the stuff mask a few px so it meets the
            # people matte (512-px depth leaves a 1-2 px gap = a halo), then cut the people out exactly
            m = ndi.binary_dilation(m, iterations=3) & ~people
        elif k == "distraction":
            m = m & ~people
        if not m.any():
            continue
        sm = refine_edges(m, img, r=8 if k in STUFF else 4, eps=1e-3 if k == "sky" else 2e-3)
        soft[tid] = sm * (1.0 - people_soft) if k in STUFF else sm
        src[tid] = s
    groups: dict[str, list[str]] = {}
    for t in targets:
        if t["id"] in soft:
            groups.setdefault(UNION[t["kind"]], []).append(t["id"])
    res: dict[str, dict] = {}
    for name in dict.fromkeys(UNION.values()):  # unions first, in a stable order
        if name in groups:
            ids = groups[name]
            res[name] = {"mask": np.maximum.reduce([soft[i] for i in ids]), "kind": name, "label": name,
                         "source": "union", "ids": ids}
    subj = [i for i in subject_ids if i in soft] or groups.get("people", [])
    if subj:
        s = np.maximum.reduce([soft[i] for i in subj])
        res["subject"] = {"mask": s, "kind": "subject", "label": "subject", "source": "union", "ids": subj}
        bg = 1.0 - s
        if L is not None:  # depth-aware background: the soft edge follows the depth step, not a blur
            Ln = (L - L.min()) / max(1e-6, float(L.max() - L.min()))
            bg = np.clip(guided_filter(Ln, bg, 6, 1e-3), 0, 1) * 0.5 + bg * 0.5
        res["background"] = {"mask": bg.astype(np.float32), "kind": "background", "label": "background",
                             "source": "1-subject" + ("+depth" if L is not None else ""), "ids": subj}
    for t in targets:
        if t["id"] in soft:
            res[t["id"]] = {"mask": soft[t["id"]], "kind": t["kind"], "label": t["label"],
                            "source": src[t["id"]], "ids": [t["id"]]}
    return res


def _png(m: np.ndarray) -> bytes:
    buf = io.BytesIO()
    Image.fromarray(np.clip(np.rint(m * 255), 0, 255).astype(np.uint8)).save(buf, "PNG")
    return buf.getvalue()


def _compose_encode(img, targets, subject, inst, dm, how) -> tuple[dict, dict]:
    t = time.perf_counter()
    h, w = img.shape[:2]
    L, cut = None, set()
    if dm is not None:
        L = _log_depth(dm, (h, w))
        if how == segment.MODEL_TAG:  # segment.py's leak cut: a broad part across a depth step goes
            Ls, G = segment._log_depth(dm, w, h)
            for tg in targets:
                m0 = inst.get(tg["id"])
                if tg["kind"] == "sky" or m0 is None or not m0.any():
                    continue
                m, info = segment._refine_with_depth(m0, Ls, G)
                if tg["kind"] in ("water", "ground"):
                    m = _cut_surface_leaks(m, Ls, G)
                if m.sum() != m0.sum():
                    inst[tg["id"]] = m
                    cut.add(tg["id"])
    res = _compose(img, targets, subject, inst, L, how, cut)
    timing = {"refine": _ms(t)}
    t = time.perf_counter()
    out = {}
    for name, r in res.items():
        out[name] = {"png": _png(r["mask"]), "width": w, "height": h,
                     "area": round(float(r["mask"].mean()), 4), "source": r["source"],
                     "label": r["label"], "kind": r["kind"], "ids": r["ids"]}
    timing["encode"] = _ms(t)
    return out, timing


async def compute_masks(image: bytes, labels=None) -> dict:
    """Semantic masks for JPEG bytes: {masks: {name: {png (bytes), width, height, area, source,
    label, kind, ids}}, targets, subject, labels, model, segmenter, cached, timing, ms}."""
    t0 = time.perf_counter()
    labels = _clean_labels(labels)
    found, cached = await find_targets(image, labels)
    pil, img, hw = await asyncio.to_thread(_work_image, image)
    t = time.perf_counter()
    async with shots._gpu:  # Depth Pro, SAM and SHARP share the GPU: one at a time
        wait = _ms(t)
        dm, inst, how, timing = await asyncio.to_thread(_gpu_pass, image, pil, found["targets"], hw)
    masks, t2 = await asyncio.to_thread(_compose_encode, img, found["targets"], found["subject"], inst, dm, how)
    timing = {"gemini": 0 if cached else found.get("ms"), "gpu_wait": wait, **timing, **t2}
    return {"masks": masks, "targets": found["targets"], "subject": found["subject"], "labels": labels,
            "model": found.get("model", TARGETS_MODEL),
            "segmenter": segment.MODEL_ID if how == segment.MODEL_TAG else how,
            "cached": cached, "timing": timing, "ms": _ms(t0)}


# ------------------------------------------------------------------------------------------------
# shot library (library/<id>/semantic/: semantic.json + <name>.png; assets.semantic)


def _sem_dir(sid: str) -> Path:
    return shots._dir(sid) / "semantic"


def _read_semantic(sid: str) -> dict | None:
    return _disk_read(_sem_dir(sid) / "semantic.json")


def _write_semantic(sid: str, res: dict) -> dict:
    d = _sem_dir(sid)
    d.mkdir(exist_ok=True)  # no parents=True: never resurrect a deleted shot
    masks = {}
    for name, m in res["masks"].items():
        tmp = d / f".{name}.png.{secrets.token_hex(3)}"
        tmp.write_bytes(m["png"])
        os.replace(tmp, d / f"{name}.png")
        masks[name] = {"url": shots._url(sid, f"semantic/{name}.png"),
                       **{k: v for k, v in m.items() if k != "png"}}
    for old in d.glob("*.png"):  # masks of an earlier run that this one did not produce
        if old.stem not in masks:
            old.unlink(missing_ok=True)
    data = {"version": 1, "created": shots._now(), "masks": masks,
            **{k: res[k] for k in ("targets", "subject", "labels", "model", "segmenter", "timing")}}
    _disk_write(d / "semantic.json", data)
    if not (d / "semantic.json").is_file():
        raise OSError("could not write semantic.json")
    return data


def _asset(sid: str, data: dict, ms: int) -> dict:
    return {"status": "done", "url": shots._url(sid, "semantic/semantic.json"),
            "urls": {n: m["url"] for n, m in data["masks"].items()},
            "meta": {n: {"kind": m["kind"], "label": m["label"], "area": m["area"]}
                     for n, m in data["masks"].items()},
            "subject": data.get("subject") or [], "model": data.get("model"), "ms": ms}


async def _compute_shot(sid: str, labels) -> dict:
    t0 = time.perf_counter()
    shots.set_asset(sid, "semantic", {"status": "running"})
    try:
        image = await asyncio.to_thread((shots._dir(sid) / "image.jpg").read_bytes)
        res = await compute_masks(image, labels)
        data = await asyncio.to_thread(_write_semantic, sid, res)
    except Exception as exc:
        if shots.get_record(sid) is None:
            raise FileNotFoundError(f"shot {sid} was deleted") from exc
        log.exception("semantic masks failed for %s", sid)
        shots.set_asset(sid, "semantic", {"status": "error", "error": f"{type(exc).__name__}: {exc}"[:400]})
        raise
    ms = _ms(t0)
    log.info("shot %s semantic done in %d ms (%s)", sid, ms, res["timing"])
    shots.set_asset(sid, "semantic", _asset(sid, data, ms))
    return data


async def ensure_semantic(shot_id: str, *, force: bool = False, labels=None) -> dict:
    """The shot's semantic.json, computing and storing it first if missing (or `force`). Concurrent
    callers share one run. Raises KeyError (unknown shot), PermissionError (another Core owns the
    library), FileNotFoundError (deleted meanwhile) or the failure (the asset is marked error)."""
    rec = shots.get_record(shot_id)
    if rec is None:
        raise KeyError(f"no shot {shot_id}")
    task = _shot_inflight.get(shot_id)
    if task is None:
        if not force and shots._status(rec, "semantic") == "done":
            data = await asyncio.to_thread(_read_semantic, shot_id)
            if data:
                return data
        if not shots._owner:
            raise PermissionError("another Core process owns the shot library (read-only here)")
        task = asyncio.create_task(_compute_shot(shot_id, labels), name=f"semantic-{shot_id}")
        _shot_inflight[shot_id] = task
        task.add_done_callback(lambda _t: _shot_inflight.pop(shot_id, None))
    return await asyncio.shield(task)  # a client hanging up doesn't cancel the shared run


def _status_error(exc: Exception) -> JSONResponse:
    if isinstance(exc, (KeyError, FileNotFoundError)):
        return _err(404, exc.args[0] if exc.args else exc)
    if isinstance(exc, PermissionError):
        return _err(409, exc)
    if isinstance(exc, ValueError):
        return _err(400, exc)
    log.error("semantic request failed: %s: %s", type(exc).__name__, exc)
    return _err(502 if isinstance(exc, gemini.GeminiError) else 500, f"{type(exc).__name__}: {exc}")


async def _json_body(request: Request) -> dict:
    raw = await request.body()
    body = json.loads(raw) if raw.strip() else {}
    if not isinstance(body, dict):
        raise ValueError("body must be a JSON object")
    return body


# ------------------------------------------------------------------------------------------------
# local edit plans (Gemini) and recipe layers

PLAN_SYSTEM = """You are a professional photo retoucher planning local adjustments, the way a pro uses
Lightroom masks: a light global base, then a few masked layers, each with one clear purpose.
Sliders: exposure in EV (-3..3), and contrast, highlights, shadows, whites, blacks, warmth
(cool<->warm), tint (green<->magenta), vibrance, saturation, clarity (midtone local contrast),
vignette (global only; negative darkens edges), each -100..100. Global values are the photo's
absolute slider values: you get the current ones; list only the sliders you change (the rest keep
their current value). Layer values are adjustments inside the mask (0 = no change).

Rules:
- Order: global first, then 2-5 layers in the order you would apply them (big areas such as sky or
  background first, then subject, then faces, then the distraction).
- Layer values are applied on top of the global edit inside the mask only. The goal must be
  obvious at a glance on a phone, yet believable. Typical layer sizes: exposure 0.2-0.6 EV,
  warmth 10-30, vibrance/saturation 10-30, clarity 10-30, highlights/shadows 20-60; global
  exposure within +-0.4 and warmth within +-25. Push the one or two layers that carry the goal;
  keep the rest light. Pull back anything that would look fake (glowing edges, orange skin, grey
  or neon sky, crushed faces).
- Looks: golden hour = warm global base, warmer highlights and sky, a warm lift on the subject,
  slightly lower contrast. Moody = darker and cooler surroundings, lower saturation, deeper blacks,
  subject kept readable. Pop = subject brighter, crisper and more colorful than a slightly darker,
  calmer background. Clean and natural = neutral white balance, correct exposure, cut haze with
  contrast and blacks, calm distractions, true skin.
- Faces/skin: exposure +0.1..+0.35 if underlit, warmth <= 12, saturation and clarity within +-8.
- Sky: recover with negative highlights or exposure; small vibrance; mind the horizon. Warming a
  clear blue sky turns it grey: keep its warmth within +-8 (a sunset sky can take more).
- A distraction is calmed by lowering exposure, saturation and clarity, not erased. A big bright
  foreground (pavement, sand, a railing) that pulls the eye takes -0.2..-0.5 EV, softly feathered.
- Every value must serve the goal; do not add a layer whose mask is missing from the list.
- mask.source must be one of the listed mask names. invert=true selects everything outside it.
  subtract lists masks to cut out (e.g. background minus sky). feather 0..100 (0 = mask edge as
  cut; 20-40 for sky, ground and background; 0-10 for people and faces). edge: "image" for people,
  faces, sky and trees; "depth" for background/foreground splits.
- why: one plain sentence a beginner understands: what changes and why it serves the goal."""

_VALUES = {"type": "object", "properties": {k: {"type": "number"} for k in GLOBAL_SLIDERS}}
PLAN_SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "global": {"type": "object", "properties": {"values": _VALUES, "why": {"type": "string"}},
                   "required": ["values", "why"]},
        "layers": {"type": "array", "items": {"type": "object", "properties": {
            "id": {"type": "string"},
            "target": {"type": "string"},
            "mask": {"type": "object", "properties": {
                "source": {"type": "string"},
                "invert": {"type": "boolean"},
                "subtract": {"type": "array", "items": {"type": "string"}},
                "feather": {"type": "number"},
                "edge": {"type": "string", "enum": list(EDGES)},
            }, "required": ["source"]},
            "values": {"type": "object", "properties": {k: {"type": "number"} for k in LAYER_SLIDERS}},
            "why": {"type": "string"},
        }, "required": ["id", "target", "mask", "values", "why"]}},
    },
    "required": ["summary", "global", "layers"],
}


def _words(text, n: int) -> str:
    return " ".join(str(text or "").split()[:n])


def _clean_layer(l, names, n: int, strict: bool) -> dict | None:
    if not isinstance(l, dict) or not isinstance(l.get("mask"), dict):
        raise ValueError("each layer must be {id, target, mask: {source, ...}, values, why}")
    mk = l["mask"]
    src = mk.get("source")
    if not isinstance(src, str) or not NAME_RE.match(src) or (names is not None and src not in names):
        raise ValueError(f"layer mask.source {src!r} is not a mask name")
    sub = mk.get("subtract") or []
    if not isinstance(sub, list):
        raise ValueError("mask.subtract must be a list of mask names")
    sub = [s for s in dict.fromkeys(sub) if isinstance(s, str) and NAME_RE.match(s) and s != src
           and (names is None or s in names)][:MAX_SUBTRACT]
    feather = _num(mk.get("feather") or 0, 0, 100)
    if feather is None:
        raise ValueError("mask.feather must be a number 0..100")
    edge = mk.get("edge") or "image"
    if edge not in EDGES:
        if strict:
            raise ValueError(f"mask.edge must be one of {', '.join(EDGES)}")
        edge = "image"
    raw = l.get("values") or {}
    if not isinstance(raw, dict):
        raise ValueError("layer values must be an object of {slider: number}")
    values = {}
    for k in LAYER_SLIDERS:  # stable order; unknown or global-only sliders are dropped
        if k in raw:
            v = edit.clamp(k, raw[k])
            if v:
                values[k] = v
    if not values and not strict:
        return None  # a Gemini layer that does nothing
    lid = l.get("id")
    lid = lid if strict and isinstance(lid, str) and NAME_RE.match(lid) else f"l{n}"
    return {"id": lid, "target": " ".join(str(l.get("target") or src).split())[:60],
            "mask": {"source": src, "invert": bool(mk.get("invert")), "subtract": sub,
                     "feather": round(feather, 1), "edge": edge},
            "values": values, "why": _words(l.get("why"), 30)}


def clean_layers(layers, names=None, *, strict: bool = True) -> list[dict]:
    """Validated recipe `layers` (§7). `names`: allowed mask names (None = any well-formed name).
    strict (recipes): ValueError on a malformed layer or more than MAX_LAYERS; otherwise (Gemini
    output) bad or empty layers are dropped, ids renumbered l1.., and the list capped."""
    if layers is None:
        return []
    if not isinstance(layers, list):
        if strict:
            raise ValueError("layers must be a list")
        return []
    if strict and len(layers) > MAX_LAYERS:
        raise ValueError(f"at most {MAX_LAYERS} layers")
    out = []
    for l in layers:
        try:
            c = _clean_layer(l, names, len(out) + 1, strict)
        except ValueError:
            if strict:
                raise
            continue
        if c is not None:
            out.append(c)
    if strict and len({c["id"] for c in out}) != len(out):
        raise ValueError("layer ids must be unique")
    return out[:MAX_LAYERS]


def _mask_list(masks: dict) -> str:
    rows = []
    for name, m in masks.items():
        if name.startswith("t") and name[1:].isdigit() and m.get("kind") in STUFF:
            continue  # stuff instances are covered by their union (sky, water, foliage, ground)
        if (m.get("area") or 0) < 0.001:
            continue
        lab = m.get("label") or name
        extra = f" ({lab})" if lab != name else ""
        rows.append(f"- {name}{extra}: kind {m.get('kind')}, {round(100 * m.get('area', 0), 1)}% of the image")
    return "\n".join(rows)


async def plan_local(image: bytes, masks: dict, values: dict, goal: str | None) -> dict:
    """Gemini plans global values + up to 5 mask layers. Returns {summary, why, values (the full new
    global values: current merged with Gemini's changes), layers, model, ms}."""
    jpg = await asyncio.to_thread(gemini.prepare_jpeg, image, GEMINI_SIDE, 88)
    text = (f"Goal: {goal or 'make it look its best, clean and natural'}\n"
            f"Current global values: {json.dumps(values)}\n"
            f"Masks you can use:\n{_mask_list(masks)}\n"
            "Plan the edit.")
    reply = await gemini.generate(PLAN_MODEL, [gemini.image_part(jpg), text], schema=PLAN_SCHEMA,
                                  system=PLAN_SYSTEM, thinking="low", media_resolution="medium",
                                  tag="semantic_plan", timeout=60)
    p = reply.data if isinstance(reply.data, dict) else {}
    g = p.get("global") if isinstance(p.get("global"), dict) else {}
    merged = dict(values)
    for k, v in (g.get("values") or {}).items() if isinstance(g.get("values"), dict) else []:
        if k in GLOBAL_SLIDERS:
            try:
                merged[k] = edit.clamp(k, v)
            except ValueError:
                pass
    final = edit.clamp_values(merged)
    final = {k: final[k] for k in edit.ORDER if k in final} | {k: v for k, v in final.items() if k not in edit.ORDER}
    return {"summary": _words(p.get("summary"), 16), "why": _words(g.get("why"), 30), "values": final,
            "layers": clean_layers(p.get("layers"), set(masks), strict=False),
            "model": PLAN_MODEL, "ms": reply.ms}


def _recipe_subject(sid: str, rec: dict, wanted) -> str | None:
    """The recipe's `subject` region (drives subject_light etc.): the request's, the saved edit's,
    else the shot's default (first focus region with a mask)."""
    if isinstance(wanted, str) and shots.RID_RE.match(wanted):
        return wanted
    saved = (rec.get("edit") or {}).get("subject")
    if saved:
        return saved
    try:
        return shots._notes(sid)[2]
    except Exception:
        return None


async def _plan_call(sid: str, key: tuple, sem: dict, values: dict, goal: str | None) -> dict:
    image = await asyncio.to_thread((shots._dir(sid) / "image.jpg").read_bytes)
    res = await plan_local(image, sem["masks"], values, goal)
    if shots.get_record(sid) is not None:
        _plan_cache[key] = res
        while len(_plan_cache) > MEM_CACHE:
            _plan_cache.popitem(last=False)
    return res


# ------------------------------------------------------------------------------------------------
# routes


@router.post("/api/semantic-masks")
async def api_semantic_masks(image: UploadFile | None = File(None), labels: str | None = Form(None)):
    if image is None:
        return _err(400, "multipart field 'image' (JPEG) is required")
    data = await image.read(MAX_UPLOAD + 1)
    if len(data) > MAX_UPLOAD:
        return _err(413, f"image larger than {MAX_UPLOAD // 1048576} MB")
    if not data:
        return _err(400, "empty image")
    try:
        lab = _clean_labels(json.loads(labels) if labels and labels.strip() else None)
        res = await compute_masks(data, lab)
    except json.JSONDecodeError:
        return _err(400, "labels must be a JSON list of strings")
    except Exception as exc:
        return _status_error(exc)
    for m in res["masks"].values():
        m["png"] = "data:image/png;base64," + base64.b64encode(m["png"]).decode("ascii")
    return res


@router.post("/api/shots/{sid}/semantic")
async def post_semantic(sid: str, request: Request, wait: bool = True):
    rec = shots._shot_or_404(sid)
    if isinstance(rec, JSONResponse):
        return rec
    try:
        body = await _json_body(request)
        labels = _clean_labels(body.get("labels")) if body.get("labels") is not None else None
        force = bool(body.get("force"))
    except ValueError as exc:
        return _err(400, exc)
    cached = not force and shots._status(rec, "semantic") == "done" and sid not in _shot_inflight
    if not wait:
        if not shots._owner:
            return _err(409, "another Core process owns the shot library (read-only here)")
        if not cached:
            t = asyncio.create_task(ensure_semantic(sid, force=force, labels=labels))
            t.add_done_callback(lambda t: t.cancelled() or t.exception())  # logged in _compute_shot
        return JSONResponse(rec, status_code=200 if cached else 202)
    try:
        data = await ensure_semantic(sid, force=force, labels=labels)
    except Exception as exc:
        return _status_error(exc)
    return {**data, "cached": cached}


@router.get("/api/shots/{sid}/semantic/{name}")
async def get_semantic_file(sid: str, name: str):
    if not shots.ID_RE.match(sid):
        return _err(404, "not found")
    if name == "semantic.json":
        media = "application/json"
    elif name.endswith(".png") and NAME_RE.match(name[:-4]):
        media = "image/png"
    else:
        return _err(404, "not found")
    path = _sem_dir(sid) / name
    if not path.is_file():
        return _err(404, f"no semantic/{name} for shot {sid}")
    return FileResponse(path, media_type=media, headers={"Cache-Control": "no-cache"})


@router.post("/api/shots/{sid}/edit/local")
async def post_edit_local(sid: str, request: Request):
    rec = shots._shot_or_404(sid)
    if isinstance(rec, JSONResponse):
        return rec
    try:
        body = await _json_body(request)
        values = edit.clamp_values(body.get("values"))
        goal = " ".join(str(body.get("goal") or "").split())[: edit.GOAL_CHARS] or None
    except ValueError as exc:
        return _err(400, exc)
    t0 = time.perf_counter()
    try:
        sem = await ensure_semantic(sid)
    except Exception as exc:
        return _status_error(exc)
    sem_ms = _ms(t0)
    subject = await asyncio.to_thread(_recipe_subject, sid, rec, body.get("subject"))
    key = (sid, sem.get("created"), json.dumps(values, sort_keys=True), goal)
    if key in _plan_cache:
        _plan_cache.move_to_end(key)
        return {**_plan_cache[key], "subject": subject, "cached": True}
    task = _plan_inflight.get(key)
    if task is None:  # identical concurrent requests share one Gemini call
        task = asyncio.create_task(_plan_call(sid, key, sem, values, goal))
        _plan_inflight[key] = task
        task.add_done_callback(lambda _t: _plan_inflight.pop(key, None))
    try:
        res = await asyncio.shield(task)
    except Exception as exc:
        return _status_error(exc)
    return {**res, "subject": subject, "semantic_ms": sem_ms, "cached": False}
