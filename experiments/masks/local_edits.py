"""Local (masked) edits for Coach: Gemini names the edit targets, SAM 2.1 cuts them, Gemini plans
per-mask adjustment layers. Experimental; meant to be wired into Core later (see REPORT.md).

    masks = get_semantic_masks(jpeg, ["people", "faces", "sky", "background", "distraction"])
    plan  = await plan_local_edits(jpeg, masks, "make it golden hour")

get_semantic_masks is sync (SAM + numpy; call it via run_in_threadpool like segment_regions). It makes
one Gemini call (TARGETS_MODEL) unless `labels` already holds targets ({label, kind, box_2d, points}).
Depth comes from server/depth.py (cached by content hash, so /api/depth's map is reused).

Masks: {name: {"png": data URL (8-bit, whole image, long side <= 1024), "width", "height", "area",
"kind", "source", "ids"}}. Names are semantic unions (people, faces, sky, water, foliage, ground,
subject, background, distraction) plus one entry per instance (t1, t2, ...).
"""
from __future__ import annotations

import asyncio
import base64
import io
import json
import os
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps
from scipy import ndimage as ndi

_SERVER = Path(__file__).resolve().parents[2] / "server"
if str(_SERVER) not in sys.path:
    sys.path.insert(0, str(_SERVER))

import gemini  # noqa: E402

TARGETS_MODEL = os.environ.get("LOCAL_TARGETS_MODEL", "gemini-4-hydrogen")
PLAN_MODEL = os.environ.get("LOCAL_PLAN_MODEL", "gemini-4-hydrogen")
MASK_LONG = 1024
SKY_FAR_M = 3e3  # Depth Pro returns sky as a constant 1e6-6e7 m; real terrain stays below this
STUFF = {"sky", "water", "foliage", "ground", "building"}
UNION = {"person": "people", "face": "faces", "sky": "sky", "water": "water", "foliage": "foliage",
         "ground": "ground", "building": "buildings", "distraction": "distraction", "object": "objects"}
DEFAULT_LABELS = ["people", "faces", "sky", "water", "foliage", "ground", "distraction"]

# ------------------------------------------------------------------------------------------ targets

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
            "kind": {"type": "string", "enum": ["person", "face", "sky", "water", "foliage", "ground",
                                               "building", "object", "distraction"]},
            "box_2d": {"type": "array", "items": {"type": "integer"}},
            "points": {"type": "array", "items": {"type": "array", "items": {"type": "integer"}}},
            "neg_points": {"type": "array", "items": {"type": "array", "items": {"type": "integer"}}},
        }, "required": ["id", "label", "kind", "box_2d", "points"]}},
        "subject": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["targets", "subject"],
}


def _jpeg(image_bytes: bytes, long_side: int) -> tuple[bytes, Image.Image]:
    im = ImageOps.exif_transpose(Image.open(io.BytesIO(image_bytes))).convert("RGB")
    s = min(1.0, long_side / max(im.size))
    small = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS) if s < 1 else im
    buf = io.BytesIO()
    small.save(buf, "JPEG", quality=88)
    return buf.getvalue(), im


async def find_targets(image_bytes: bytes, labels=None, model: str = TARGETS_MODEL) -> dict:
    """One Gemini call: [{id, label, kind, box_2d, points, neg_points}] + subject ids."""
    labels = labels or DEFAULT_LABELS
    jpg, _ = await asyncio.to_thread(_jpeg, image_bytes, 1024)
    want = ", ".join(labels)
    reply = await gemini.generate(model, [gemini.image_part(jpg), TARGETS_PROMPT.format(labels=want)],
                                  schema=TARGETS_SCHEMA, thinking="low", media_resolution="high",
                                  tag="local_targets", timeout=60)
    out = reply.data
    out["model"], out["ms"] = model, reply.ms
    return out


# ------------------------------------------------------------------------------------------ SAM

def _sam_decode(sam, boxes, points):
    """Like segment._SamSession.decode, but boxes may be None (point-only prompts)."""
    import torch
    import torch.nn.functional as F
    import segment

    sx, sy = segment.SAM_SIDE / sam.W, segment.SAM_SIDE / sam.H
    kw = {}
    if boxes is not None:
        kw["input_boxes"] = (torch.tensor(boxes, dtype=torch.float32)
                             * torch.tensor([sx, sy, sx, sy]))[None].to(segment._device)
    if points is not None:
        pts = torch.tensor(points, dtype=torch.float32)
        kw["input_points"] = (pts[..., :2] * torch.tensor([sx, sy]))[None].to(segment._device)
        kw["input_labels"] = pts[..., 2].to(torch.int32)[None].to(segment._device)
    with torch.inference_mode(), segment._autocast(sam.precision):
        multi = segment._model(image_embeddings=sam.emb, multimask_output=True, **kw)
        single = segment._model(image_embeddings=sam.emb, multimask_output=False, **kw)
    logits = torch.cat([multi.pred_masks, single.pred_masks], dim=2)[0].float()
    iou = torch.cat([multi.iou_scores, single.iou_scores], dim=2)[0].float()
    logits = F.interpolate(logits, size=sam.out_hw, mode="bilinear", align_corners=False)
    return logits.cpu().numpy(), iou.cpu().numpy()


def _pts_px(t, W, H, with_neg=True):
    pos = [(p[1] / 1000 * W, p[0] / 1000 * H, 1) for p in (t.get("points") or []) if len(p) >= 2]
    neg = [(p[1] / 1000 * W, p[0] / 1000 * H, 0) for p in (t.get("neg_points") or []) if len(p) >= 2] \
        if with_neg else []
    return pos + neg


def _box_norm(t):
    y0, x0, y1, x1 = [max(0.0, min(1.0, float(v) / 1000)) for v in t["box_2d"][:4]]
    return min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)


def sam_targets(pil: Image.Image, targets: list[dict], mode: str = "box+points",
                out_hw: tuple[int, int] | None = None) -> tuple[dict, int]:
    """Binary mask per target id at out_hw. mode: box | points | box+points. Returns (masks, ms)."""
    import segment

    t0 = time.perf_counter()
    W, H = pil.size
    if out_hw is None:
        s = min(1.0, MASK_LONG / max(W, H))
        out_hw = (round(H * s), round(W * s))
    mh, mw = out_hw
    segment._load()
    usable = [t for t in targets if t.get("box_2d") and len(t["box_2d"]) >= 4]
    out = {}
    with segment._SamSession(pil, out_hw) as sam:
        for t in usable:  # one target per decode keeps point counts simple (decoder is ~10 ms)
            x0, y0, x1, y1 = _box_norm(t)
            b = (int(x0 * mw), int(y0 * mh), max(int(np.ceil(x1 * mw)), int(x0 * mw) + 1),
                 max(int(np.ceil(y1 * mh)), int(y0 * mh) + 1))
            pts = _pts_px(t, W, H)
            if mode == "points" and not pts:
                continue
            boxes = [[x0 * W, y0 * H, x1 * W, y1 * H]] if mode != "points" else None
            points = [pts] if (mode != "box" and pts) else None
            logits, iou = _sam_decode(sam, boxes, points)
            lg, io_ = logits[0], iou[0]
            if mode == "points":
                areas = [(lg[k] > 0).sum() for k in range(lg.shape[0])]
                ok = [k for k in range(lg.shape[0]) if io_[k] >= io_.max() - 0.06]
                k = max(ok, key=lambda k: areas[k]) if t["kind"] in STUFF else int(io_.argmax())
                m = segment._keep_major(lg[k] > 0, 0.05 if t["kind"] in STUFF else 0.1)
            else:
                crop = segment._grown(b, mw, mh, segment.BOX_MARGIN)
                m, _, _ = segment._choose(lg, io_, b, crop)
            out[t["id"]] = segment._fill_small_holes(m)
    return out, int((time.perf_counter() - t0) * 1000)


# ------------------------------------------------------------------------------------------ refine

def _box(x, r):
    return ndi.uniform_filter(x, size=2 * r + 1, mode="reflect")


def guided_filter(I: np.ndarray, p: np.ndarray, r: int, eps: float) -> np.ndarray:
    """Color (HxWx3) or gray (HxW) guided filter (He et al.): edges of p snap to edges of I."""
    p = p.astype(np.float32)
    if I.ndim == 2:
        mI, mp = _box(I, r), _box(p, r)
        a = (_box(I * p, r) - mI * mp) / (_box(I * I, r) - mI * mI + eps)
        b = mp - a * mI
        return _box(a, r) * I + _box(b, r)
    mI = np.stack([_box(I[..., c], r) for c in range(3)], -1)
    mp = _box(p, r)
    cov = np.stack([_box(I[..., c] * p, r) for c in range(3)], -1) - mI * mp[..., None]
    var = np.empty(I.shape[:2] + (3, 3), np.float32)
    for i in range(3):
        for j in range(i, 3):
            v = _box(I[..., i] * I[..., j], r) - mI[..., i] * mI[..., j]
            var[..., i, j] = var[..., j, i] = v
    var += eps * np.eye(3, dtype=np.float32)
    a = np.linalg.solve(var, cov[..., None])[..., 0]
    b = mp - (a * mI).sum(-1)
    ma = np.stack([_box(a[..., c], r) for c in range(3)], -1)
    return (ma * I).sum(-1) + _box(b, r)


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


def _depth_logs(image_bytes: bytes, hw) -> np.ndarray | None:
    try:
        import depth

        d, _ = depth.infer_depth(image_bytes)
    except Exception:
        return None
    return depth_to_log(d, hw)


def depth_to_log(d: np.ndarray, hw) -> np.ndarray:
    import torch
    import torch.nn.functional as F

    L = np.log(np.clip(d, 0.05, 1e5)).astype(np.float32)
    t = F.interpolate(torch.from_numpy(L)[None, None], size=hw, mode="bilinear", align_corners=False)
    return t[0, 0].numpy()


def sky_from_depth(sam_sky: np.ndarray | None, boxes: list, L: np.ndarray) -> tuple[np.ndarray, str]:
    """Sky = 'infinitely far' pixels in/near Gemini's sky box(es) or the SAM sky mask, connected to it."""
    far = L > np.log(SKY_FAR_M)
    h, w = L.shape
    where = np.zeros((h, w), bool)
    for x0, y0, x1, y1 in boxes:
        where[int(y0 * h):int(np.ceil(y1 * h)) + 4, max(0, int(x0 * w) - 4):int(np.ceil(x1 * w)) + 4] = True
    if sam_sky is not None:
        where |= ndi.binary_dilation(sam_sky, iterations=8)
    cand = far & where
    if cand.sum() < 0.002 * h * w:  # depth says no sky here: keep SAM's answer
        return (sam_sky if sam_sky is not None else np.zeros((h, w), bool)), "sam"
    lab, n = ndi.label(cand)
    sizes = np.bincount(lab.ravel())[1:]
    keep = np.flatnonzero(sizes >= 0.02 * sizes.max()) + 1
    return np.isin(lab, keep), "depth+box" if sam_sky is None else "sam+depth"


# ------------------------------------------------------------------------------------------ compose

def compose(img: np.ndarray, targets: list[dict], subject_ids: list[str], inst: dict,
            L: np.ndarray | None) -> dict[str, dict]:
    """Instance masks -> refined soft masks per instance + semantic unions + subject/background."""
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
        m = inst.get(tid)
        if k == "sky" and L is not None:
            m, how = sky_from_depth(m, [_box_norm(t)], L)
            src[tid] = how
        elif m is None:
            continue
        else:
            src[tid] = "sam"
        if k in STUFF:
            # people stand in front of sea, grass, road. Grow the stuff mask a few px first so it meets
            # the people matte (depth is 512 px, so its far/near step leaves a 1-2 px gap = a halo),
            # then make it the exact complement of the people matte there.
            m = ndi.binary_dilation(m, iterations=3) & ~people
        elif k == "distraction":
            m = m & ~people
        if not m.any():
            continue
        sm = refine_edges(m, img, r=8 if k in STUFF else 4, eps=1e-3 if k == "sky" else 2e-3)
        soft[tid] = sm * (1.0 - people_soft) if k in STUFF else sm
    res: dict[str, dict] = {}
    for tid, m in soft.items():
        t = next(t for t in targets if t["id"] == tid)
        res[tid] = {"mask": m, "kind": t["kind"], "label": t["label"], "source": src[tid], "ids": [tid]}
    groups: dict[str, list[str]] = {}
    for t in targets:
        if t["id"] in soft:
            groups.setdefault(UNION[t["kind"]], []).append(t["id"])
    for name, ids in groups.items():
        res[name] = {"mask": np.maximum.reduce([soft[i] for i in ids]), "kind": name, "label": name,
                     "source": "union", "ids": ids}
    subj = [i for i in subject_ids if i in soft] or groups.get("people", [])
    if subj:
        s = np.maximum.reduce([soft[i] for i in subj])
        res["subject"] = {"mask": s, "kind": "subject", "label": "subject", "source": "union", "ids": subj}
        bg = 1.0 - s
        if L is not None:  # depth-aware background: soft edge follows the depth step, not a blur
            Ln = (L - L.min()) / max(1e-6, float(L.max() - L.min()))
            bg = np.clip(guided_filter(Ln, bg, 6, 1e-3), 0, 1) * 0.5 + bg * 0.5
        res["background"] = {"mask": bg.astype(np.float32), "kind": "background", "label": "background",
                             "source": "1-subject" + ("+depth" if L is not None else ""), "ids": subj}
    return res


def encode_png(m: np.ndarray) -> str:
    buf = io.BytesIO()
    Image.fromarray(np.clip(np.rint(m * 255), 0, 255).astype(np.uint8)).save(buf, "PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode("ascii")


def get_semantic_masks(image_bytes: bytes, labels=None, *, depth_m: np.ndarray | None = None,
                       mode: str = "box+points", as_arrays: bool = False) -> dict:
    """Semantic edit masks. `labels`: list of target words (one Gemini call locates them), or a
    find_targets() result / list of target dicts (no Gemini call). Sync: run it in a thread."""
    t0 = time.perf_counter()
    timing = {}
    if isinstance(labels, dict) and "targets" in labels:
        found = labels
    elif labels and isinstance(labels[0], dict):
        found = {"targets": labels, "subject": []}
    else:
        found = asyncio.run(find_targets(image_bytes, labels))
        timing["gemini"] = found.get("ms")
    targets = [dict(t) for t in found["targets"]]
    remap = {}
    for i, t in enumerate(targets):  # model ids are free-form ("sky" would clash with the union)
        remap[str(t.get("id"))] = t["id"] = f"t{i + 1}"
    subject = [remap[str(i)] for i in found.get("subject") or [] if str(i) in remap]
    _, pil = _jpeg(image_bytes, 1536)
    W, H = pil.size
    s = min(1.0, MASK_LONG / max(W, H))
    hw = (round(H * s), round(W * s))
    img = np.asarray(pil.resize((hw[1], hw[0]), Image.LANCZOS), np.float32) / 255
    t = time.perf_counter()
    L = depth_to_log(depth_m, hw) if depth_m is not None else _depth_logs(image_bytes, hw)
    timing["depth"] = int((time.perf_counter() - t) * 1000)
    inst, timing["sam"] = sam_targets(pil, targets, mode, hw)
    t = time.perf_counter()
    res = compose(img, targets, subject, inst, L)
    timing["refine"] = int((time.perf_counter() - t) * 1000)
    out = {}
    for name, r in res.items():
        e = {k: v for k, v in r.items() if k != "mask"}
        e.update(width=hw[1], height=hw[0], area=round(float(r["mask"].mean()), 4))
        e["mask" if as_arrays else "png"] = r["mask"] if as_arrays else encode_png(r["mask"])
        out[name] = e
    return {"masks": out, "targets": targets, "subject": subject,
            "timing": timing, "ms": int((time.perf_counter() - t0) * 1000)}


# ------------------------------------------------------------------------------------------ planning

LAYER_SLIDERS = ["exposure", "contrast", "highlights", "shadows", "whites", "blacks", "warmth", "tint",
                 "vibrance", "saturation", "clarity"]
GLOBAL_SLIDERS = LAYER_SLIDERS + ["vignette"]

PLAN_SYSTEM = """You are a professional photo retoucher planning local adjustments, the way a pro uses
Lightroom masks: a light global base, then a few masked layers, each with one clear purpose.
Sliders (all optional, 0 = no change): exposure in EV (-3..3), and contrast, highlights, shadows,
whites, blacks, warmth (cool<->warm), tint (green<->magenta), vibrance, saturation, clarity
(midtone local contrast), vignette (global only; negative darkens edges), each -100..100.

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
                "edge": {"type": "string", "enum": ["image", "depth", "none"]},
            }, "required": ["source"]},
            "values": {"type": "object", "properties": {k: {"type": "number"} for k in LAYER_SLIDERS}},
            "why": {"type": "string"},
        }, "required": ["id", "target", "mask", "values", "why"]}},
    },
    "required": ["summary", "global", "layers"],
}


def _mask_list(masks: dict) -> str:
    rows = []
    for name, m in masks.items():
        if name.startswith("t") and name[1:].isdigit() and m.get("kind") in STUFF:
            continue  # stuff instances are covered by their union (sky, water, foliage, ground)
        lab = m.get("label") or name
        extra = f" ({lab})" if lab != name else ""
        rows.append(f"- {name}{extra}: kind {m.get('kind')}, {round(100 * m.get('area', 0), 1)}% of the image")
    return "\n".join(rows)


def _clip_values(v: dict, names) -> dict:
    out = {}
    for k, x in (v or {}).items():
        if k in names and isinstance(x, (int, float)) and x:
            lo, hi = (-3, 3) if k == "exposure" else (-100, 100)
            out[k] = round(max(lo, min(hi, float(x))), 2)
    return out


async def plan_local_edits(image_bytes: bytes, masks: dict, goal: str, *, model: str = PLAN_MODEL,
                           current: dict | None = None) -> dict:
    """Gemini plans global values + 2-5 mask layers for `goal`. `masks` = get_semantic_masks()
    output (or its ["masks"]). Returns the recipe additions: {summary, values, layers, model, ms}."""
    masks = masks.get("masks", masks)
    jpg, _ = await asyncio.to_thread(_jpeg, image_bytes, 1024)
    text = (f"Goal: {goal or 'make it look its best, clean and natural'}\n"
            f"Current global values: {json.dumps(current or {})}\n"
            f"Masks you can use:\n{_mask_list(masks)}\n"
            "Plan the edit.")
    reply = await gemini.generate(model, [gemini.image_part(jpg), text], schema=PLAN_SCHEMA,
                                  system=PLAN_SYSTEM, thinking="low", media_resolution="medium",
                                  tag="local_plan", timeout=60)
    return normalize_plan(reply.data, masks) | {"model": model, "ms": reply.ms}


def normalize_plan(p: dict, masks: dict) -> dict:
    layers = []
    for i, l in enumerate(p.get("layers") or []):
        mk = l.get("mask") or {}
        if mk.get("source") not in masks:
            continue
        layers.append({
            "id": l.get("id") or f"l{i + 1}", "target": l.get("target") or mk["source"],
            "mask": {"source": mk["source"], "invert": bool(mk.get("invert")),
                     "subtract": [s for s in mk.get("subtract") or [] if s in masks],
                     "feather": max(0.0, min(100.0, float(mk.get("feather") or 0))),
                     "edge": mk.get("edge") if mk.get("edge") in ("image", "depth", "none") else "image"},
            "values": _clip_values(l.get("values"), LAYER_SLIDERS), "why": l.get("why", ""),
        })
    g = p.get("global") or {}
    return {"summary": p.get("summary", ""), "values": _clip_values(g.get("values"), GLOBAL_SLIDERS),
            "global_why": g.get("why", ""), "layers": layers[:5]}
