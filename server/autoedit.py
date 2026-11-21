"""Edit for Me: an agent loop that edits a shot with Gemini (plan -> render -> critique -> refine).

  POST /api/shots/{id}/autoedit   {"goal": optional string} -> text/event-stream
  GET  /api/shots/{id}/autoedit/{name}.jpg   the loop's previews (orig, r1, r2, r3, final)

Events (the phone animates each one):
  stage  {"stage": "depth"|"masks"|"plan"|"render"|"critique", "say": "<=8 words"}
  step   {"round": n, "values": {...}, "layers": [{id, target, mask_url, values}], "say", "subject"}
  done   {"values", "layers", "say", "rounds", "ms", "model", "subject", "timing"}
  error  {"error": "..."}

The loop:
  1. Wait (up to WAIT_S) for the shot's `depth` and `masks` stages (shots.py's pipeline).
  2. Plan: Gemini (AUTOEDIT_MODEL, default gemini-4-neon) gets the photo, a colourised depth map and
     the mask list (region masks, plus the semantic masks when that stage is already done) and
     returns a recipe: global slider values (edit.SLIDERS), up to MAX_LAYERS masked layers
     (live_setup.LAYER_SLIDERS) and a short `say` line.
  3. Render: a numpy approximation of the slider renderer on a PREVIEW_SIDE preview (there is no
     Python slider renderer elsewhere; looks.py renders LUT looks), good enough for Gemini to judge.
  4. Critique: Gemini compares the original with the render and returns a refined recipe or
     done=true. At most MAX_REFINES refine rounds.
"""

from __future__ import annotations

import asyncio
import io
import json
import logging
import os
import time

import numpy as np
from fastapi import APIRouter, Request
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from PIL import Image
from scipy import ndimage as ndi

import edit
import gemini
import shots

try:
    import live_setup

    LAYER_SLIDERS = list(getattr(live_setup, "LAYER_SLIDERS", None) or [])
except Exception:  # noqa: BLE001 - live_setup is optional here; fall back to semantic's list
    LAYER_SLIDERS = []
if not LAYER_SLIDERS:
    import semantic

    LAYER_SLIDERS = list(semantic.LAYER_SLIDERS)

log = logging.getLogger("autoedit")

router = APIRouter()

MODEL = os.environ.get("AUTOEDIT_MODEL", "gemini-4-neon")
# The critique only compares two images: the fast model keeps the loop near 20 s instead of ~60 s.
CRITIQUE_MODEL = os.environ.get("AUTOEDIT_CRITIQUE_MODEL", "gemini-4-hydrogen")
WAIT_S = 25.0
POLL_S = 0.25
PREVIEW_SIDE = 768
MAX_LAYERS = 3
MAX_REFINES = int(os.environ.get("AUTOEDIT_REFINES", "1"))
TIMEOUT_S = 60.0
NEEDED = ("depth", "masks")
GLOBAL_KEYS = [k for k in edit.ORDER if k in edit.SLIDERS and k != "focus_depth"]
PREVIEWS = ("orig", "r1", "r2", "r3", "final")


def _ms(t0: float) -> int:
    return int((time.perf_counter() - t0) * 1000)


def _sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n"


def _words(text, n: int) -> str:
    return " ".join(str(text or "").split()[:n])


# ------------------------------------------------------------------------------------------------
# shot assets


def _mask_catalog(sid: str, rec: dict) -> dict[str, dict]:
    """Every mask the recipe may target: the pipeline's region masks (masks/<rid>.png, labelled
    with the region's tag and note), plus the semantic masks if that stage is already done."""
    d = shots._dir(sid)
    regs = shots._read_json(sid, "regions.json") or {}
    notes = {r.get("id"): r for r in regs.get("regions") or [] if isinstance(r, dict)}
    m = rec["assets"].get("masks") or {}
    cat: dict[str, dict] = {}
    for rid, url in (m.get("urls") or {}).items():
        meta = (m.get("meta") or {}).get(rid) or {}
        r = notes.get(rid) or {}
        if not (meta.get("area") or 0) or not (d / "masks" / f"{rid}.png").is_file():
            continue
        cat[rid] = {"kind": f"region ({r.get('tag') or 'focus'})", "label": r.get("note") or rid,
                    "area": meta.get("area") or 0.0, "depth_m": meta.get("depth_m"), "url": url,
                    "path": d / "masks" / f"{rid}.png"}
    if shots._status(rec, "semantic") == "done":
        sem = shots._read_json(sid, "semantic/semantic.json") or {}
        for name, sm in (sem.get("masks") or {}).items():
            if name in cat or not isinstance(sm, dict):
                continue
            if name.startswith("t") and name[1:].isdigit() and sm.get("kind") in ("sky", "water", "foliage", "ground", "building"):
                continue  # stuff instances are covered by their union (semantic._mask_list does this too)
            path = d / "semantic" / f"{name}.png"
            if (sm.get("area") or 0) < 0.001 or not path.is_file():
                continue
            cat[name] = {"kind": sm.get("kind") or "semantic", "label": sm.get("label") or name,
                         "area": sm.get("area") or 0.0, "depth_m": None,
                         "url": sm.get("url") or shots._url(sid, f"semantic/{name}.png"), "path": path}
    return cat


def _default_subject(sid: str, rec: dict, cat: dict) -> str | None:
    try:
        sub = shots._notes(sid)[2]
    except Exception:  # noqa: BLE001
        sub = None
    if sub in cat:
        return sub
    if "subject" in cat:
        return "subject"
    return next(iter(cat), None)


def _mask_text(cat: dict) -> str:
    rows = []
    for mid, m in cat.items():
        dep = f", median depth {m['depth_m']} m" if m.get("depth_m") else ""
        rows.append(f"- {mid}: {m['kind']}, {round(100 * m['area'], 1)}% of the image{dep}: {_words(m['label'], 20)}")
    return "\n".join(rows) or "(no masks)"


# ------------------------------------------------------------------------------------------------
# preview renderer (numpy approximation of the app's slider renderer)


def _srgb_to_lin(x):
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


def _lin_to_srgb(x):
    x = np.clip(x, 0, None)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.power(x, 1 / 2.4) - 0.055)


LUMA = np.array([0.2126, 0.7152, 0.0722], np.float32)


def _smooth(e0: float, e1: float, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def _blur2(a: np.ndarray, sigma: float) -> np.ndarray:
    return ndi.gaussian_filter(a, sigma) if sigma > 0.3 else a


def _blur3(a: np.ndarray, sigma: float) -> np.ndarray:
    return ndi.gaussian_filter(a, (sigma, sigma, 0)) if sigma > 0.3 else a


def _tone(x: np.ndarray, v: dict) -> np.ndarray:
    """The tone and colour sliders (shared by the global edit and the layers), in sRGB 0..1."""
    g = lambda k: float(v.get(k) or 0) / 100.0  # noqa: E731
    ev = float(v.get("exposure") or 0)
    w, t = g("warmth"), g("tint")
    if ev or w or t:
        gains = np.array([1 + 0.22 * w + 0.06 * t, 1 - 0.12 * t, 1 - 0.22 * w + 0.06 * t], np.float32)
        x = _lin_to_srgb(_srgb_to_lin(x) * gains * (2.0 ** ev))
    c = g("contrast")
    if c:
        s = x * x * (3 - 2 * x)  # S-curve
        x = x + (s - x) * 1.2 * c if c > 0 else 0.5 + (x - 0.5) * (1 + 0.6 * c)
    h, sh, wh, bl = g("highlights"), g("shadows"), g("whites"), g("blacks")
    if h or sh or wh or bl:
        L = np.clip(x @ LUMA, 0, 1)
        d = (0.35 * h * _smooth(0.45, 1.0, L) + 0.35 * sh * (1 - _smooth(0.0, 0.55, L))
             + 0.2 * wh * _smooth(0.65, 1.0, L) + 0.15 * bl * (1 - _smooth(0.0, 0.35, L)))
        x = x + d[..., None]
    cl = g("clarity")
    if cl:
        L = np.clip(x @ LUMA, 0, 1)
        detail = L - _blur2(L, max(x.shape[:2]) * 0.015)
        x = x + (1.2 * cl * detail * 4 * L * (1 - L))[..., None]
    sat, vib = g("saturation"), g("vibrance")
    if sat or vib:
        x = np.clip(x, 0, 1)
        L = (x @ LUMA)[..., None]
        chroma = x.max(-1, keepdims=True) - x.min(-1, keepdims=True)
        f = 1 + sat + vib * (1 - np.clip(chroma * 2.2, 0, 1))
        x = L + (x - L) * np.clip(f, 0, None)
    return np.clip(x, 0, 1).astype(np.float32)


def _load_mask(path, hw: tuple[int, int], feather: float = 2.0) -> np.ndarray:
    m = Image.open(path).convert("L").resize((hw[1], hw[0]), Image.BILINEAR)
    return _blur2(np.asarray(m, np.float32) / 255.0, feather)


def _load_assets(sid: str, rec: dict) -> dict:
    """The preview image (sRGB float), its depth in metres (NaN = unknown, inf = sky) and size."""
    d = shots._dir(sid)
    im = Image.open(d / "image.jpg").convert("RGB")
    im.thumbnail((PREVIEW_SIDE, PREVIEW_SIDE), Image.LANCZOS)
    rgb = np.asarray(im, np.float32) / 255.0
    hw = rgb.shape[:2]
    mm = np.asarray(Image.open(d / "depth.png"), np.float32)
    mm = np.asarray(Image.fromarray(mm, "F").resize((hw[1], hw[0]), Image.NEAREST), np.float32)
    dm = mm / 1000.0
    dm[mm <= 0] = np.nan
    dm[mm >= 65535] = np.inf
    return {"rgb": rgb, "depth": dm, "hw": hw}


def depth_vis(dm: np.ndarray) -> np.ndarray:
    """Colourised depth: near = bright yellow, mid = magenta, far = dark blue, sky/unknown = black."""
    ok = np.isfinite(dm) & (dm > 0)
    out = np.zeros(dm.shape + (3,), np.float32)
    if not ok.any():
        return out
    L = np.log(np.where(ok, dm, 1.0))
    lo, hi = np.percentile(L[ok], [2, 98])
    t = 1 - np.clip((L - lo) / max(hi - lo, 1e-3), 0, 1)  # 1 = near
    stops = np.array([[0.05, 0.05, 0.35], [0.35, 0.1, 0.65], [0.85, 0.2, 0.5], [1.0, 0.6, 0.15], [1.0, 0.95, 0.4]], np.float32)
    pos = t * (len(stops) - 1)
    i = np.clip(pos.astype(int), 0, len(stops) - 2)
    f = (pos - i)[..., None]
    out = stops[i] * (1 - f) + stops[i + 1] * f
    out[~ok] = 0
    return out


def render(assets: dict, recipe: dict, cat: dict) -> np.ndarray:
    """Apply a recipe {values, layers, subject} to the preview. Order follows edit.ORDER: tone and
    colour, subject/background light, layers, depth blur, vignette."""
    x, dm, hw = assets["rgb"], assets["depth"], assets["hw"]
    v = recipe.get("values") or {}
    x = _tone(x, v)
    sub_id = recipe.get("subject")
    sm = _load_mask(cat[sub_id]["path"], hw, 3.0) if sub_id in cat else None
    sl, bgl = float(v.get("subject_light") or 0) / 100, float(v.get("background_light") or 0) / 100
    if (sl or bgl) and sm is not None:
        ev = 0.8 * (sl * sm + bgl * (1 - sm))
        x = np.clip(_lin_to_srgb(_srgb_to_lin(x) * (2.0 ** ev)[..., None]), 0, 1).astype(np.float32)
    for layer in recipe.get("layers") or []:
        m = cat.get(layer.get("target"))
        if not m or not layer.get("values"):
            continue
        a = _load_mask(m["path"], hw, 2.5)[..., None]
        x = x * (1 - a) + _tone(x, layer["values"]) * a
    db = float(v.get("depth_blur") or 0) / 100
    if db > 0:
        ok = np.isfinite(dm) & (dm > 0)
        focus = v.get("focus_depth")
        if not focus and sub_id in cat:
            focus = cat[sub_id].get("depth_m")
        if not focus and sm is not None:
            inside = (sm > 0.5) & ok
            focus = float(np.median(dm[inside])) if inside.any() else None
        if not focus:
            focus = float(np.median(dm[ok])) if ok.any() else 1.0
        ld = np.where(ok, np.log(np.where(ok, dm, 1.0)), np.log(focus) + 3.0)
        ld[np.isinf(dm)] = np.log(focus) + 3.0
        wgt = np.clip(np.abs(ld - np.log(focus)) / 0.7, 0, 1) ** 1.2
        if sm is not None:
            wgt = wgt * (1 - np.clip(sm * 1.5, 0, 1))  # keep the subject sharp
        wgt = _blur2(wgt, 2.0)[..., None]
        r = max(hw) * 0.014 * db
        b1, b2 = _blur3(x, r * 0.45), _blur3(x, r)
        x = np.where(wgt < 0.5, x * (1 - 2 * wgt) + b1 * 2 * wgt, b1 * (2 - 2 * wgt) + b2 * (2 * wgt - 1))
    vg = float(v.get("vignette") or 0) / 100
    if vg:
        yy, xx = np.mgrid[0:hw[0], 0:hw[1]].astype(np.float32)
        r = np.sqrt(((xx / hw[1]) - 0.5) ** 2 + ((yy / hw[0]) - 0.5) ** 2) / 0.7071
        k = (np.clip((r - 0.35) / 0.65, 0, 1) ** 2)[..., None]
        x = _lin_to_srgb(_srgb_to_lin(x) * (1 + 0.7 * vg * k))
    return np.clip(x, 0, 1).astype(np.float32)


def _jpeg(rgb: np.ndarray, quality: int = 88) -> bytes:
    buf = io.BytesIO()
    Image.fromarray(np.clip(rgb * 255 + 0.5, 0, 255).astype(np.uint8)).save(buf, "JPEG", quality=quality)
    return buf.getvalue()


def _save_preview(sid: str, name: str, jpg: bytes) -> None:
    d = shots._dir(sid)
    if not d.is_dir():
        return
    (d / "autoedit").mkdir(exist_ok=True)
    (d / "autoedit" / f"{name}.jpg").write_bytes(jpg)


# ------------------------------------------------------------------------------------------------
# Gemini: plan and critique

SYSTEM = f"""You are a professional photo retoucher doing an automatic "Edit for me" on a phone photo,
the way a pro uses Lightroom: a light global base, then a few masked layers, each with one clear
purpose. The aim: the subject clearly stands out and the surroundings (clutter, distractions,
busy background) get calmer, while the photo stays believable.

Global sliders (absolute values; list only the ones you change; omit focus_depth):
{edit.slider_table()}
subject_light/background_light use the `subject` mask you pick; depth_blur blurs pixels whose
depth differs from the subject's depth (a fake shallow depth of field), so it calms a cluttered
background without touching the subject. You get a colourised depth map: near = bright yellow,
mid = magenta, far = dark blue, black = sky or unknown.

Layers: up to {MAX_LAYERS}, each {{target: one listed mask id, values: adjustments inside the mask
(0 = no change)}}. Layer sliders: {", ".join(LAYER_SLIDERS)} (exposure in EV -3..3, the rest -100..100).

Rules:
- The goal must be obvious at a glance on a phone, yet believable. Typical sizes: global exposure
  within +-0.4, warmth within +-25; layer exposure 0.2-0.6 EV, warmth 10-30, vibrance/saturation
  10-30, clarity 10-30; background_light -15..-40 to calm a busy background; depth_blur 25-60 when
  the subject is separated in depth from the clutter. Pull back anything that would look fake
  (glowing edges, halos, neon colour, crushed blacks).
- A distraction is calmed by lowering its exposure, saturation and clarity, not erased.
- Faces/skin: exposure +0.1..+0.35 if underlit, warmth <= 12, saturation and clarity within +-8.
- Every value must serve the goal; only target masks from the list.
- say: one short, friendly line (<= 12 words) telling the user what you did."""

_GLOBAL_PROPS = {k: {"type": "number"} for k in GLOBAL_KEYS}
_LAYER_PROPS = {k: {"type": "number"} for k in LAYER_SLIDERS}
_LAYERS = {"type": "array", "items": {"type": "object", "properties": {
    "target": {"type": "string"},
    "values": {"type": "object", "properties": _LAYER_PROPS},
    "why": {"type": "string"},
}, "required": ["target", "values"]}}

PLAN_SCHEMA = {
    "type": "object",
    "properties": {
        "subject": {"type": "string"},
        "values": {"type": "object", "properties": _GLOBAL_PROPS},
        "layers": _LAYERS,
        "say": {"type": "string"},
    },
    "required": ["subject", "values", "layers", "say"],
}

CRITIQUE_SCHEMA = {
    "type": "object",
    "properties": {
        "improved": {"type": "boolean"},
        "problems": {"type": "string"},
        "done": {"type": "boolean"},
        "subject": {"type": "string"},
        "values": {"type": "object", "properties": _GLOBAL_PROPS},
        "layers": _LAYERS,
        "say": {"type": "string"},
    },
    "required": ["improved", "problems", "done", "subject", "values", "layers", "say"],
}


def clean_recipe(p, cat: dict, default_subject: str | None) -> dict:
    """Validate Gemini's recipe: global values clamped with edit.clamp, at most MAX_LAYERS layers on
    known masks with LAYER_SLIDERS only (zero values dropped), a <=12-word say line."""
    p = p if isinstance(p, dict) else {}
    raw = p.get("values") if isinstance(p.get("values"), dict) else {}
    vals = {}
    for k in GLOBAL_KEYS:
        if k in raw:
            try:
                vals[k] = edit.clamp(k, raw[k])
            except ValueError:
                pass
    vals = edit.clamp_values(vals)  # drops defaults
    by_label = {str(m["label"]).lower(): mid for mid, m in cat.items()}
    layers = []
    for l in p.get("layers") or []:
        if not isinstance(l, dict) or len(layers) >= MAX_LAYERS:
            continue
        tgt = str(l.get("target") or "").strip()
        tgt = tgt if tgt in cat else by_label.get(tgt.lower())
        if tgt is None or not isinstance(l.get("values"), dict):
            continue
        lv = {}
        for k in LAYER_SLIDERS:
            if k in l["values"]:
                try:
                    c = edit.clamp(k, l["values"][k])
                except ValueError:
                    continue
                if c:
                    lv[k] = c
        if lv:
            layers.append({"id": f"l{len(layers) + 1}", "target": tgt, "mask_url": cat[tgt]["url"], "values": lv})
    subject = p.get("subject") if p.get("subject") in cat else default_subject
    return {"values": vals, "layers": layers, "say": _words(p.get("say"), 12) or "Edited for you.",
            "subject": subject}


def _recipe_json(r: dict) -> str:
    return json.dumps({"subject": r.get("subject"), "values": r["values"],
                       "layers": [{"target": l["target"], "values": l["values"]} for l in r["layers"]]})


async def plan(photo: bytes, depth_jpg: bytes, cat: dict, default_subject: str | None, goal: str | None) -> tuple[dict, int]:
    text = (f"Goal: {goal or 'make the subject stand out and calm the clutter, clean and natural'}\n"
            f"Default subject mask: {default_subject}\n"
            f"Masks you can use (id: kind, area, depth, what it is):\n{_mask_text(cat)}\n"
            "Plan the edit: subject mask id, global values, up to 3 layers, and say.")
    reply = await gemini.generate(MODEL, ["The photo:", gemini.image_part(photo), "Its depth map:",
                                          gemini.image_part(depth_jpg), text],
                                  schema=PLAN_SCHEMA, system=SYSTEM, thinking="low",
                                  media_resolution="medium", tag="autoedit_plan", timeout=TIMEOUT_S)
    return clean_recipe(reply.data, cat, default_subject), reply.ms


async def critique(photo: bytes, rendered: bytes, recipe: dict, cat: dict, default_subject: str | None,
                   goal: str | None, rnd: int) -> tuple[dict, bool, str, int]:
    text = (f"Goal: {goal or 'make the subject stand out and calm the clutter, clean and natural'}\n"
            f"Masks you can use:\n{_mask_text(cat)}\n"
            f"The recipe that produced the second image (round {rnd}): {_recipe_json(recipe)}\n"
            "Compare the edit with the original. Did it improve the photo toward the goal? Name the "
            "biggest remaining problem (too strong, too weak, fake-looking, wrong mask, subject not "
            "separated, clutter still loud). Then return the full corrected recipe (all values you "
            "want, not a diff). Set done=true only if the edit already looks finished and another "
            "round would not visibly help; then return the same recipe.")
    reply = await gemini.generate(CRITIQUE_MODEL, ["Original:", gemini.image_part(photo),
                                          "Edited preview (an approximate renderer):", gemini.image_part(rendered), text],
                                  schema=CRITIQUE_SCHEMA, system=SYSTEM, thinking="low",
                                  media_resolution="medium", tag="autoedit_critique", timeout=TIMEOUT_S)
    d = reply.data if isinstance(reply.data, dict) else {}
    return clean_recipe(d, cat, recipe.get("subject") or default_subject), bool(d.get("done")), \
        _words(d.get("problems"), 30), reply.ms


# ------------------------------------------------------------------------------------------------
# the loop


async def _wait_stages(sid: str):
    """Yields ("stage", name) when a needed stage starts being waited on, and finally ("ok", ms) or
    ("error", message)."""
    t0 = time.perf_counter()
    for name in NEEDED:
        yield ("stage", name)
        while True:
            rec = shots.get_record(sid)
            if rec is None:
                yield ("error", f"shot {sid} was deleted while waiting for {name}")
                return
            st = shots._status(rec, name)
            if st == "done":
                break
            if st == "error":
                err = (rec["assets"].get(name) or {}).get("error") or "unknown error"
                yield ("error", f"{name} stage failed for shot {sid}: {err}")
                return
            if st == "none":
                yield ("error", f"shot {sid} has no {name} stage")
                return
            if time.perf_counter() - t0 > WAIT_S:
                owner = "" if shots._owner else " (this Core does not own the library, so it does not process shots)"
                yield ("error", f"{name} still {st} after {WAIT_S:.0f} s for shot {sid}{owner}")
                return
            await asyncio.sleep(POLL_S)
    yield ("ok", _ms(t0))


async def _run(sid: str, goal: str | None):
    t0 = time.perf_counter()
    timing: dict = {}
    say_wait = {"depth": "Reading the depth", "masks": "Finding what matters"}
    async for kind, val in _wait_stages(sid):
        if kind == "stage":
            yield _sse("stage", {"stage": val, "say": say_wait[val]})
        elif kind == "error":
            yield _sse("error", {"error": val})
            return
        else:
            timing["wait_ms"] = val
    rec = shots.get_record(sid)
    try:
        cat = await asyncio.to_thread(_mask_catalog, sid, rec)
        if not cat:
            yield _sse("error", {"error": f"shot {sid} has no usable masks to edit with"})
            return
        default_subject = _default_subject(sid, rec, cat)
        assets = await asyncio.to_thread(_load_assets, sid, rec)
        photo = await asyncio.to_thread(_jpeg, assets["rgb"])
        depth_jpg = await asyncio.to_thread(_jpeg, depth_vis(assets["depth"]))
        await asyncio.to_thread(_save_preview, sid, "orig", photo)
    except Exception as exc:  # noqa: BLE001
        log.exception("autoedit %s: loading assets failed", sid)
        yield _sse("error", {"error": f"loading shot {sid} assets failed: {type(exc).__name__}: {exc}"})
        return

    yield _sse("stage", {"stage": "plan", "say": "Planning your edit"})
    try:
        recipe, ms = await plan(photo, depth_jpg, cat, default_subject, goal)
    except Exception as exc:  # noqa: BLE001
        log.error("autoedit %s: plan failed: %s: %s", sid, type(exc).__name__, exc)
        yield _sse("error", {"error": f"plan ({MODEL}) failed: {type(exc).__name__}: {exc}"})
        return
    timing["plan_ms"] = ms
    rnd = 1
    yield _sse("step", {"round": rnd, **recipe})
    rendered_round = 0
    rendered = b""
    while rnd <= MAX_REFINES:
        yield _sse("stage", {"stage": "render", "say": "Rendering a preview"})
        tr = time.perf_counter()
        rendered = await asyncio.to_thread(lambda: _jpeg(render(assets, recipe, cat)))
        rendered_round = rnd
        await asyncio.to_thread(_save_preview, sid, f"r{rnd}", rendered)
        timing[f"render{rnd}_ms"] = _ms(tr)
        yield _sse("stage", {"stage": "critique", "say": "Checking how it looks"})
        try:
            refined, done, problems, ms = await critique(photo, rendered, recipe, cat, default_subject, goal, rnd)
        except Exception as exc:  # noqa: BLE001
            log.error("autoedit %s: critique failed: %s: %s", sid, type(exc).__name__, exc)
            yield _sse("error", {"error": f"critique round {rnd} ({CRITIQUE_MODEL}) failed: {type(exc).__name__}: {exc}"})
            return
        timing[f"critique{rnd}_ms"] = ms
        log.info("autoedit %s round %d critique (%d ms, done=%s): %s", sid, rnd, ms, done, problems)
        if done:
            break
        recipe = refined
        rnd += 1
        yield _sse("step", {"round": rnd, **recipe, "critique": problems})
    if rendered_round != rnd:
        rendered = await asyncio.to_thread(lambda: _jpeg(render(assets, recipe, cat)))
        await asyncio.to_thread(_save_preview, sid, f"r{rnd}", rendered)
    await asyncio.to_thread(_save_preview, sid, "final", rendered)
    timing["total_ms"] = _ms(t0)
    log.info("autoedit %s done: %d rounds, %s", sid, rnd, timing)
    yield _sse("done", {**recipe, "rounds": rnd, "ms": timing["total_ms"], "model": MODEL,
                        "timing": timing, "preview_url": shots._url(sid, "autoedit/final.jpg")})


@router.post("/api/shots/{sid}/autoedit")
async def post_autoedit(sid: str, request: Request):
    rec = shots._shot_or_404(sid)
    if isinstance(rec, JSONResponse):
        return rec
    raw = await request.body()
    try:
        body = json.loads(raw) if raw.strip() else {}
    except ValueError:
        return JSONResponse({"error": "body must be JSON"}, status_code=400)
    if not isinstance(body, dict):
        return JSONResponse({"error": "body must be a JSON object"}, status_code=400)
    goal = " ".join(str(body.get("goal") or "").split())[: edit.GOAL_CHARS] or None
    if not gemini.has_key():
        return JSONResponse({"error": "GEMINI_API_KEY is not set"}, status_code=503)
    return StreamingResponse(_run(sid, goal), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


@router.get("/api/shots/{sid}/autoedit/{name}.jpg")
async def get_autoedit_preview(sid: str, name: str):
    if not shots.ID_RE.match(sid) or name not in PREVIEWS:
        return JSONResponse({"error": "not found"}, status_code=404)
    path = shots._dir(sid) / "autoedit" / f"{name}.jpg"
    if not path.is_file():
        return JSONResponse({"error": f"no autoedit/{name}.jpg for shot {sid}"}, status_code=404)
    return FileResponse(path, media_type="image/jpeg", headers={"Cache-Control": "no-cache"})
