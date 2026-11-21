"""Edit suggestions: one Gemini call that plans a short, teachable slider edit for a shot.

Used by shots.py (`POST /api/shots/{id}/edit/suggest` and the automatic `suggest` stage) and
reusable by the live edit mode (`SLIDERS`, `slider_table()`, `shot_context()`, `fmt_values()`).
See docs/CORE_API.md §4.

Gemini best practices applied here:
  - Static instructions (role, slider table, rules) live in `systemInstruction` and are byte-
    identical on every call, and the request is ordered image -> shot notes -> current values and
    goal. Gemini's implicit cache matches on prefixes, so repeated calls for the same shot (a new
    goal, new slider values) reuse system + image + notes; `usage.cached` reports the hit.
  - Structured output: `responseMimeType: application/json` + `responseJsonSchema` with an enum of
    slider names; the result is still validated, clamped to slider ranges and deduplicated, and a
    call whose JSON is invalid (or has < 3 usable steps) is retried once.
  - `mediaResolution: MEDIA_RESOLUTION_MEDIUM` and a 1024 px JPEG: enough to judge exposure and
    color, half the image tokens of HIGH.
  - `thinkingLevel: low` (the 4-series rejects "minimal"); temperature left at the default.
  - Calls go through gemini.py (pooled keep-alive client, 429/5xx retries with backoff, one log
    line per call and /api/stats accounting under tag "suggest").

Model: env SUGGEST_MODEL, default gemini-4-hydrogen (~3.7 s with an image).
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import math
import os
import time
from collections import OrderedDict

import gemini

log = logging.getLogger("edit")

MODEL = os.environ.get("SUGGEST_MODEL", "gemini-4-hydrogen")
IMAGE_SIDE = 1024
TIMEOUT_S = 45.0
WHY_WORDS = 12
SUMMARY_WORDS = 10
GOAL_CHARS = 200

# name: (min, max, default, decimals, meaning). Same table as CORE_API.md §4 and CoachEdit.
SLIDERS: dict[str, tuple[float, float, float | None, int, str]] = {
    "exposure": (-3.0, 3.0, 0.0, 2, "overall brightness in EV"),
    "contrast": (-100, 100, 0, 0, "global contrast"),
    "highlights": (-100, 100, 0, 0, "bright tones (negative recovers blown areas)"),
    "shadows": (-100, 100, 0, 0, "dark tones (positive lifts them)"),
    "whites": (-100, 100, 0, 0, "white point"),
    "blacks": (-100, 100, 0, 0, "black point (negative deepens)"),
    "warmth": (-100, 100, 0, 0, "white balance, cooler (-) to warmer (+)"),
    "tint": (-100, 100, 0, 0, "green (-) to magenta (+)"),
    "vibrance": (-100, 100, 0, 0, "saturation of muted colors only, protects skin"),
    "saturation": (-100, 100, 0, 0, "saturation of all colors"),
    "clarity": (-100, 100, 0, 0, "local midtone contrast (texture, detail)"),
    "vignette": (-100, 100, 0, 0, "negative darkens the edges, positive lightens them"),
    "subject_light": (-100, 100, 0, 0, "brightness inside the subject mask"),
    "background_light": (-100, 100, 0, 0, "brightness outside the subject mask"),
    "depth_blur": (0, 100, 0, 0, "lens blur from the depth map, sharp at focus_depth"),
    "focus_depth": (0.1, 100.0, None, 2, "meters in focus for depth_blur; null = the subject's median depth"),
}

# Editing order (CORE_API.md §2 edit-mode prompt): white balance and exposure, tone, color,
# detail, local, then blur and vignette. Steps are stable-sorted by this.
ORDER = ["warmth", "tint", "exposure", "contrast", "highlights", "shadows", "whites", "blacks",
         "vibrance", "saturation", "clarity", "subject_light", "background_light",
         "focus_depth", "depth_blur", "vignette"]
_RANK = {name: i for i, name in enumerate(ORDER)}


def _fmt_num(v: float, decimals: int) -> str:
    return f"{v:.{decimals}f}" if decimals else str(int(round(v)))


def slider_table() -> str:
    """One line per slider, `name: min..max, default d: meaning` (deterministic)."""
    lines = []
    for name, (lo, hi, default, dec, meaning) in SLIDERS.items():
        d = "null" if default is None else _fmt_num(default, dec)
        lines.append(f"- {name}: {_fmt_num(lo, dec)}..{_fmt_num(hi, dec)}, default {d}: {meaning}")
    return "\n".join(lines)


SYSTEM = f"""You are a photo editor and a patient teacher. You get one photo and notes about it \
(how it was shot, quality scores, regions with masks, depth), the current slider values and \
sometimes the user's goal. Plan a short edit with the sliders below and explain every move in \
one plain line so the user learns why it helps this photo.

Sliders (name: range, default: what it does):
{slider_table()}

Rules:
1. Return 3 to 8 steps in editing order: white balance and exposure (warmth, tint, exposure), \
then tone (contrast, highlights, shadows, whites, blacks), then color (vibrance, saturation), \
then detail (clarity), then local light (subject_light, background_light), then depth_blur, \
then vignette.
2. Each step sets ONE slider to an absolute target value inside its range (not a change from \
the current value). Use each slider at most once and only when it should differ from its \
current value.
3. Be natural by default: most tone and color moves fall within 10 to 40, exposure within 1 EV \
unless the photo is badly exposed. Go further only when the user's goal asks for a strong look.
4. Fix what this photo actually needs (blown highlights, murky shadows, a color cast, flat \
light, a subject that does not stand out). Leave alone what already works.
5. "why": one line, at most 12 words, about this photo, e.g. "Pull back the blown window so \
her face leads" rather than "Adjust highlights".
6. "subject": the id of the main subject region (a focus region with a mask) or null if the \
notes list none. subject_light, background_light and depth_blur need a subject.
7. "region": for subject_light and background_light the subject id; for a step aimed at one \
listed region, that id; otherwise null. Only use ids from the notes.
8. depth_blur only when the depth notes show the background well behind the subject (about \
twice as far or more), usually 15 to 45. Leave focus_depth alone unless focusing somewhere other \
than the subject.
9. With a user goal, serve the goal first (for "moodier": lower exposure or deeper blacks, \
cooler or muted color, a darker background, a vignette) while still fixing obvious problems.
10. Without a goal, make the best natural version of the photo for its intent.
11. "summary": at most 8 words naming the look, e.g. "Warm it up and let the subject glow"."""

SCHEMA = {
    "type": "object",
    "properties": {
        "subject": {"type": ["string", "null"]},
        "steps": {
            "type": "array",
            "minItems": 3,
            "maxItems": 8,
            "items": {
                "type": "object",
                "properties": {
                    "slider": {"type": "string", "enum": list(SLIDERS)},
                    "value": {"type": "number"},
                    "why": {"type": "string"},
                    "region": {"type": ["string", "null"]},
                },
                "required": ["slider", "value", "why", "region"],
            },
        },
        "summary": {"type": "string"},
    },
    "required": ["subject", "steps", "summary"],
}

# Filled after each call for check scripts; not part of the contract.
last_debug: dict = {}


# ------------------------------------------------------------------------------------------------
# values and recipes


def clamp(name: str, value) -> float | None:
    """Clamp one slider value to its range and rounding; ValueError on unknown/non-numeric."""
    if name not in SLIDERS:
        raise ValueError(f"unknown slider {name!r} (valid: {', '.join(SLIDERS)})")
    lo, hi, default, dec, _ = SLIDERS[name]
    if value is None:
        if default is None:
            return None
        raise ValueError(f"{name} must be a number")
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{name} must be a finite number")
    v = min(max(float(value), lo), hi)
    return round(v, dec) if dec else int(round(v))


def clamp_values(values: dict | None) -> dict:
    """Validated, clamped copy of a {slider: value} dict; defaults are dropped."""
    if values is None:
        return {}
    if not isinstance(values, dict):
        raise ValueError("values must be an object of {slider: number}")
    out = {}
    for name, value in values.items():
        v = clamp(name, value)
        if v != SLIDERS[name][2]:
            out[name] = v
    return out


def fmt_values(values: dict) -> str:
    vals = {k: v for k, v in (values or {}).items() if k in SLIDERS and v != SLIDERS[k][2]}
    if not vals:
        return "all sliders at their defaults (unedited)"
    parts = []
    for name in ORDER:
        if name in vals:
            dec = SLIDERS[name][3]
            v = vals[name]
            parts.append(f"{name} {v:+.{dec}f}" if dec else f"{name} {int(v):+d}")
    return ", ".join(parts)


# ------------------------------------------------------------------------------------------------
# shot notes (the per-shot context, also reusable for the live edit-mode prompt)


def _shutter(s) -> str | None:
    try:
        s = float(s)
    except (TypeError, ValueError):
        return None
    if s <= 0:
        return None
    return f"1/{round(1 / s)} s" if s < 0.5 else f"{s:g} s"


def shot_context(rec: dict, score: dict | None, regions: dict | None,
                 box_depth: dict | None = None) -> str:
    """Compact notes about a shot from its record, score.json and regions.json. `box_depth`
    (region id -> median depth in m inside its box) fills in for masks that aren't done yet."""
    lines = []
    w, h = rec.get("width"), rec.get("height")
    if w and h:
        orient = "portrait" if h > w else "landscape" if w > h else "square"
        lines.append(f"Photo: {w}x{h} ({orient}).")
    meta = rec.get("meta") or {}
    cam = []
    if meta.get("device"):
        cam.append(str(meta["device"])[:40])
    for key, label in (("iso", "ISO"),):
        if isinstance(meta.get(key), (int, float)):
            cam.append(f"{label} {meta[key]:g}")
    if _shutter(meta.get("shutter")):
        cam.append(_shutter(meta.get("shutter")))
    if isinstance(meta.get("ev"), (int, float)) and meta["ev"]:
        cam.append(f"EV {meta['ev']:+.1f}")
    if isinstance(meta.get("wb_kelvin"), (int, float)):
        cam.append(f"WB {meta['wb_kelvin']:g} K")
    for key in ("lens", "mode", "facing"):
        if meta.get(key):
            cam.append(f"{key} {str(meta[key])[:20]}")
    if cam:
        lines.append("Shot with: " + ", ".join(cam) + ".")
    intent = [f"intent {meta['intent']}" if meta.get("intent") else "",
              f"subject \"{str(meta['subject'])[:60]}\"" if meta.get("subject") else "",
              f"keep {', '.join(str(k)[:30] for k in meta['keep'][:4])}"
              if isinstance(meta.get("keep"), list) and meta["keep"] else "",
              f"scene \"{str(meta['scene'])[:80]}\"" if meta.get("scene") else ""]
    if any(intent):
        lines.append("Photographer: " + "; ".join(x for x in intent if x) + ".")

    if score and isinstance(score.get("scores"), dict):
        parts = []
        for name, s in score["scores"].items():
            if isinstance(s, dict) and isinstance(s.get("score"), (int, float)):
                label = f' ("{s["label"]}")' if s.get("label") else ""
                parts.append(f"{name} {s['score']:.1f}/5{label}")
        if parts:
            lines.append("Scores: " + "; ".join(parts) + ".")

    assets = rec.get("assets") or {}
    dmeta = (assets.get("depth") or {}).get("meta") or {}
    mmeta = (assets.get("masks") or {}).get("meta") or {}
    if regions and isinstance(regions.get("regions"), list):
        lines.append("Regions (box as fractions of the frame):")
        for r in regions["regions"]:
            b = r.get("box") or {}
            try:
                box = (f"x {b['x']:.2f}-{b['x'] + b['w']:.2f}, y {b['y']:.2f}-{b['y'] + b['h']:.2f}")
            except (KeyError, TypeError):
                box = "box unknown"
            extra = []
            m = mmeta.get(r.get("id")) or {}
            if isinstance(m.get("area"), (int, float)):
                extra.append(f"mask {m['area'] * 100:.0f}% of frame")
            if isinstance(m.get("depth_m"), (int, float)):
                extra.append(f"median depth {m['depth_m']:.1f} m")
            elif isinstance((box_depth or {}).get(r.get("id")), (int, float)):
                extra.append(f"median depth in box {box_depth[r['id']]:.1f} m")
            extra_s = (", " + ", ".join(extra)) if extra else ""
            lines.append(f"- {r.get('id')} [{r.get('tag')}] {box}{extra_s}: {str(r.get('note') or '')[:120]}")
    if dmeta.get("p02") is not None and dmeta.get("p98") is not None:
        d = f"Depth: near {dmeta['p02']:.1f} m, far {dmeta['p98']:.1f} m"
        if isinstance(dmeta.get("median"), (int, float)):
            d += f", median {dmeta['median']:.1f} m"
        if isinstance(dmeta.get("far_frac"), (int, float)) and dmeta["far_frac"] >= 0.01:
            d += f", {dmeta['far_frac'] * 100:.0f}% sky or beyond 65 m"
        lines.append(d + ".")
    return "\n".join(lines)


# ------------------------------------------------------------------------------------------------
# Gemini call

_img_cache: OrderedDict[str, str] = OrderedDict()


def _image_b64(image: bytes) -> str:
    """1024 px JPEG, base64; the last few are cached so repeat calls send identical bytes."""
    key = hashlib.sha1(image).hexdigest()
    if key in _img_cache:
        _img_cache.move_to_end(key)
        return _img_cache[key]
    b64 = gemini.b64(gemini.prepare_jpeg(image, IMAGE_SIDE))
    _img_cache[key] = b64
    while len(_img_cache) > 8:
        _img_cache.popitem(last=False)
    return b64


def _request_text(values: dict, goal: str | None) -> str:
    goal_s = (f'User goal: "{goal}". Serve this goal.' if goal
              else "No goal given: make the best natural version of this photo.")
    return f"Current slider values: {fmt_values(values)}.\n{goal_s}\nReturn 3 to 8 steps."


def _words(text, n: int) -> str:
    w = str(text or "").replace("\n", " ").split()
    return " ".join(w[:n])


def _validate(out, values: dict, region_ids: list[str]) -> dict:
    """Normalize a model answer; ValueError when it is unusable."""
    if not isinstance(out, dict) or not isinstance(out.get("steps"), list):
        raise ValueError("answer has no steps list")
    ids = set(region_ids)
    steps, seen = [], set()
    for s in out["steps"]:
        if not isinstance(s, dict) or s.get("slider") not in SLIDERS or s["slider"] in seen:
            continue
        try:
            v = clamp(s["slider"], s.get("value"))
        except ValueError:
            continue
        if v is None or v == values.get(s["slider"], SLIDERS[s["slider"]][2]):
            continue  # a no-op step teaches nothing
        seen.add(s["slider"])
        region = s.get("region") if s.get("region") in ids else None
        steps.append({"slider": s["slider"], "value": v, "why": _words(s.get("why"), WHY_WORDS),
                      "region": region})
    if not steps:
        raise ValueError("no usable steps")
    steps.sort(key=lambda s: _RANK[s["slider"]])  # stable: the model's order within a group
    steps = steps[:8]
    subject = out.get("subject") if out.get("subject") in ids else None
    final = dict(values)
    for s in steps:
        final[s["slider"]] = s["value"]
    final = {k: final[k] for k in ORDER if k in final and final[k] != SLIDERS[k][2]}
    return {"summary": _words(out.get("summary"), SUMMARY_WORDS), "steps": steps, "values": final,
            "subject": subject}


async def suggest(image: bytes, notes: str, values: dict | None = None, goal: str | None = None,
                  region_ids: list[str] | None = None, default_subject: str | None = None,
                  model: str | None = None) -> dict:
    """Plan a guided edit. `image` is the shot's JPEG, `notes` from shot_context(), `values` the
    current slider values (validated with clamp_values). Returns the §4 suggest shape."""
    if not gemini.has_key():
        raise RuntimeError("GEMINI_API_KEY is not set")
    model = model or MODEL
    values = clamp_values(values)
    goal = " ".join(str(goal or "").split())[:GOAL_CHARS] or None
    region_ids = list(region_ids or [])
    t0 = time.perf_counter()
    b64 = await asyncio.to_thread(_image_b64, image)
    # Stable prefix first (system, image, per-shot notes), the per-call request last.
    parts = [gemini.image_part(b64), "Notes about this photo:\n" + (notes or "(none)"),
             _request_text(values, goal)]
    res, reply, last_exc, attempts = None, None, None, 0
    for attempt in range(2):  # gemini.post already retries 429/5xx; this retries bad answers once
        attempts = attempt + 1
        try:
            r = await gemini.generate(model, parts, schema=SCHEMA, system=SYSTEM, thinking="low",
                                      media_resolution="medium", tag="suggest", timeout=TIMEOUT_S)
            cand = _validate(r.data, values, region_ids)
        except gemini.GeminiError as exc:
            last_exc = exc
            if exc.status != 200:  # an HTTP/network failure that survived gemini.py's retries
                break
            log.warning("suggest attempt %d: invalid answer: %s", attempts, exc)
            continue
        except (ValueError, KeyError, TypeError) as exc:
            last_exc = exc
            log.warning("suggest attempt %d: unusable answer: %s", attempts, exc)
            continue
        if res is None or len(cand["steps"]) > len(res["steps"]):
            res, reply = cand, r
        if len(res["steps"]) >= 3:
            break
        last_exc = ValueError(f"only {len(cand['steps'])} usable steps")
    if res is None:
        raise RuntimeError(f"suggest failed after {attempts} attempt(s): {last_exc}")
    if res["subject"] is None and default_subject in region_ids:
        res["subject"] = default_subject
    usage = reply.usage or {}
    res.update(model=model, ms=int((time.perf_counter() - t0) * 1000), goal=goal, usage={
        "prompt": usage.get("input"), "cached": usage.get("cached", 0),
        "output": usage.get("output"), "thoughts": usage.get("thought"),
    })
    last_debug.clear()
    last_debug.update(attempts=attempts, retries=reply.retries, usage=usage,
                      last_error=str(last_exc) if last_exc else None)
    return res
