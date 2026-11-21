"""Three coaching regions from Gemini 4 Argon. See ../CONTRACT.md `/api/regions`.

Gemini API first (through gemini.py: pooled connection, retries, stats) when GEMINI_API_KEY is
set; OpenRouter is the fallback (and the only path without it).

The model answers in Gemini's native detection format (`box_2d: [ymin, xmin, ymax, xmax]`,
0..1000), which we convert to normalized top-left `{x, y, w, h}`.
"""

from __future__ import annotations

import asyncio
import base64
import json
import os
import re
import time

import httpx
import numpy as np

import gemini

MODEL = "google/gemini-4-argon"
URL = "https://openrouter.ai/api/v1/chat/completions"
GEMINI_MODEL = os.environ.get("REGIONS_MODEL", "gemini-4-argon")
TIMEOUT_S = 60.0
# Detection needs detail: Gemini 4's default image budget is already 1120 tokens (= "high", the
# docs' recommendation for image analysis); set it explicitly so a model or default change can't
# silently shrink it. Pixels beyond the budget only cost upload bytes, hence MAX_SIDE.
MEDIA_RESOLUTION = os.environ.get("REGIONS_MEDIA_RESOLUTION", "high")
# Reasoning effort sent to OpenRouter; "" means provider default. Overridable for experiments.
EFFORT = os.environ.get("REGIONS_EFFORT", "low")
MAX_SIDE = 1024  # downscale before upload: boxes are normalized, so this only saves bytes/latency
NOTE_MAX = 90

PROMPT = """You are a photo-editing coach. This photo is already taken: the user can't move the \
camera, move or pose people, change the light or wait for the scene to change. They will edit it \
in Coach, a Mac editor where the photo is a 3D scene: every pixel has a measured distance from the \
camera, so edits can follow depth. Pick exactly 3 regions to coach on.

Tag each region:
- "focus": the subject, or the light worth building the edit around (a pool of window light, \
rim light on hair, a lit face, a bright highlight that carries the image).
- "remove": a distraction that pulls the eye away: a blown hot spot, a bright edge or corner, \
clutter, an intruding object, a stray line. Something to crop out or tone down.
Use at least one "focus" and at least one "remove".

For each region return:
- label: 1-4 words naming exactly what the box contains, e.g. "man's face", "lamp at left edge".
- box_2d: [ymin, xmin, ymax, xmax] as integers 0-1000 relative to the full image, tightly \
enclosing only that thing.
- tag: "focus" or "remove".
- note: ONE line, at most 12 words (under 90 characters): one edit for that region that the \
editor can make, e.g. "Crop the bright sign at right; it outshines her face." No praise, no \
generic tips.

The editor can: crop and straighten; exposure, contrast, highlights, shadows, whites, blacks; \
warmth and tint; vibrance, saturation, clarity; brighten or darken the subject alone, or \
everything but the subject; blur by depth (a lens blur that keeps one distance sharp); vignette. \
It can't add, move or erase objects. Never tell the user to move, turn, pose, step, pan, tilt or \
angle anything, to use a flash or reflector, to wait, or to reshoot.

The 3 regions must be different things and should not overlap much. Avoid boxes that cover \
most of the frame."""

# How long callers wait for this image's depth before asking without it (env REGIONS_DEPTH_WAIT_S):
# warm Depth Pro takes 0.3-0.6 s, a new image shape up to ~4 s.
DEPTH_WAIT_S = float(os.environ.get("REGIONS_DEPTH_WAIT_S", "4"))
# depth.png stores millimetres in uint16, so everything past ~65 m reads as "far".
FAR_M = 65.0
DEPTH_HINT = ("Use the depth when it helps: blur by depth what sits well behind the subject, or \
brighten or darken a whole near or far plane. Give a distance only in those depth edits.")

SCHEMA = {
    "type": "object",
    "properties": {
        "regions": {
            "type": "array",
            "minItems": 3,
            "maxItems": 3,
            "items": {
                "type": "object",
                "properties": {
                    "label": {"type": "string"},
                    "box_2d": {
                        "type": "array",
                        "items": {"type": "integer"},
                        "minItems": 4,
                        "maxItems": 4,
                    },
                    "tag": {"type": "string", "enum": ["focus", "remove"]},
                    "note": {"type": "string"},
                },
                "required": ["label", "box_2d", "tag", "note"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["regions"],
    "additionalProperties": False,
}

# Filled after each call (usage/cost/raw regions) for check scripts; not part of the contract.
last_debug: dict = {}


def _prepare(image_bytes: bytes, mime: str) -> tuple[str, str]:
    """EXIF-upright, downscale to MAX_SIDE, JPEG; fall back to the raw bytes on any error."""
    try:
        return gemini.b64(gemini.prepare_jpeg(image_bytes, MAX_SIDE)), "image/jpeg"
    except Exception:
        return base64.b64encode(image_bytes).decode(), mime or "image/jpeg"


def _dist(m: float) -> str:
    return "far" if m >= FAR_M else f"{m:.1f} m" if m < 9.95 else f"{m:.0f} m"


def depth_notes(depth_m) -> str | None:
    """Prompt text for a metric depth map (metres, top-left origin; inf or >= FAR_M is far, 0 or
    NaN unknown): near/far range, the share that is far, and the median distance in each ninth
    of the frame, so the model knows which parts of the photo are close and which are deep.
    None when there's nothing usable."""
    d = np.asarray(depth_m, dtype=np.float32)
    if d.ndim != 2 or min(d.shape) < 3:
        return None
    far = np.isposinf(d) | (np.isfinite(d) & (d >= FAR_M))
    near = np.isfinite(d) & (d > 0) & ~far
    if not near.any():
        return None
    p02, p98 = np.percentile(d[near], [2, 98])
    dist = np.where(far, np.inf, d)
    known = far | near
    h, w = d.shape
    rows = []
    for i, name in enumerate(("top", "middle", "bottom")):
        cells = []
        for j in range(3):
            ys, xs = slice(i * h // 3, (i + 1) * h // 3), slice(j * w // 3, (j + 1) * w // 3)
            vals = dist[ys, xs][known[ys, xs]]
            cells.append(_dist(float(np.median(vals))) if vals.size else "unknown")
        rows.append(f"{name}: " + " | ".join(cells))
    share = float(far.sum()) / float(known.sum())
    return (f"Depth from the camera (measured, metres): nearest {_dist(float(p02))}, farthest "
            f"{_dist(float(p98))}; about {share:.0%} of the frame is sky or beyond {FAR_M:.0f} m. "
            "Median distance in each ninth of the frame (rows top to bottom, columns left to right):\n"
            + "\n".join(rows) + "\n" + DEPTH_HINT)


def _parse_json(text: str) -> dict:
    text = text.strip()
    m = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    if m:
        text = m.group(1).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        obj, arr = text.find("{"), text.find("[")
        if arr >= 0 and (obj < 0 or arr < obj):  # bare array of regions
            end = text.rfind("]")
            if end > arr:
                return {"regions": json.loads(text[arr : end + 1])}
        end = text.rfind("}")
        if obj >= 0 and end > obj:
            return json.loads(text[obj : end + 1])
        raise


def _to_box(box_2d) -> dict | None:
    """[ymin, xmin, ymax, xmax] on 0..1000 -> normalized {x, y, w, h}; None if unusable."""
    try:
        ymin, xmin, ymax, xmax = (float(v) for v in box_2d[:4])
    except (TypeError, ValueError):
        return None
    clamp = lambda v: min(1.0, max(0.0, v / 1000.0))  # noqa: E731
    y0, y1 = sorted((clamp(ymin), clamp(ymax)))
    x0, x1 = sorted((clamp(xmin), clamp(xmax)))
    if x1 - x0 < 0.005 or y1 - y0 < 0.005:
        return None
    return {"x": round(x0, 4), "y": round(y0, 4), "w": round(x1 - x0, 4), "h": round(y1 - y0, 4)}


def _short(note: str) -> str:
    note = " ".join(str(note).split())
    if len(note) <= NOTE_MAX:
        return note
    cut = note[: NOTE_MAX - 1].rsplit(" ", 1)[0].rstrip(",;:-")
    return cut + "…"


def _normalize(data: dict) -> list[dict]:
    items = data.get("regions", data) if isinstance(data, dict) else data
    out = []
    for item in items if isinstance(items, list) else []:
        if not isinstance(item, dict):
            continue
        box = _to_box(item.get("box_2d") or item.get("box"))
        tag = str(item.get("tag", "")).strip().lower()
        note = _short(item.get("note", ""))
        if box is None or tag not in ("focus", "remove") or not note:
            continue
        out.append({"box": box, "tag": tag, "note": note, "label": str(item.get("label", ""))})
    return out


async def _ask(client: httpx.AsyncClient, key: str, b64: str, mime: str, prompt: str) -> tuple[list[dict], dict]:
    t0 = time.perf_counter()
    body = {
        "model": MODEL,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}},
                    {"type": "text", "text": prompt},
                ],
            }
        ],
        "response_format": {
            "type": "json_schema",
            "json_schema": {"name": "coaching_regions", "strict": True, "schema": SCHEMA},
        },
        "max_tokens": 4096,
        "usage": {"include": True},
    }
    if EFFORT:
        body["reasoning"] = {"effort": EFFORT}
    try:
        r = await client.post(URL, json=body, headers={"Authorization": f"Bearer {key}"})
        if r.status_code != 200:
            raise RuntimeError(f"OpenRouter HTTP {r.status_code}: {r.text[:300]}")
        resp = r.json()
        if "error" in resp:
            raise RuntimeError(f"OpenRouter error: {str(resp['error'])[:300]}")
    except Exception as exc:
        gemini.record(f"openrouter:{MODEL}", "regions", (time.perf_counter() - t0) * 1000, ok=False, error=str(exc))
        raise
    usage = resp.get("usage") or {}
    gemini.record(f"openrouter:{MODEL}", "regions", (time.perf_counter() - t0) * 1000, usage={
        "input": usage.get("prompt_tokens"), "output": usage.get("completion_tokens")})
    content = resp["choices"][0]["message"].get("content") or ""
    if isinstance(content, list):  # some providers return content parts
        content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
    return _normalize(_parse_json(content)), usage


async def _ask_gemini(_client, _key: str, b64: str, mime: str, prompt: str) -> tuple[list[dict], dict]:
    """Same prompt and schema, straight to the Gemini API via gemini.py (pooled, retried, logged)."""
    reply = await gemini.generate(
        GEMINI_MODEL, [gemini.image_part(b64, mime), prompt], schema=SCHEMA,
        thinking=EFFORT or "low", media_resolution=MEDIA_RESOLUTION, tag="regions", timeout=TIMEOUT_S,
    )
    return _normalize(reply.data), {**(reply.raw.get("usageMetadata") or {}), "ms": reply.ms,
                                    "retries": reply.retries}


async def find_regions(image_bytes: bytes, mime: str, depth_m=None) -> dict:
    """depth_m: optional metric depth map for this image (metres, any size); its summary goes
    into the prompt (see depth_notes)."""
    gkey, okey = os.environ.get("GEMINI_API_KEY"), os.environ.get("OPENROUTER_API_KEY")
    if not (gkey or okey):
        raise RuntimeError("neither GEMINI_API_KEY nor OPENROUTER_API_KEY is set")
    # Gemini API first when its key is set; OpenRouter is the fallback (and the only path without it).
    routes = ([("gemini", gkey, _ask_gemini)] if gkey else []) + ([("openrouter", okey, _ask)] if okey else [])
    t0 = time.perf_counter()
    b64, send_mime = await asyncio.to_thread(_prepare, image_bytes, mime)  # off the event loop
    notes = await asyncio.to_thread(depth_notes, depth_m) if depth_m is not None else None
    prompt = f"{PROMPT}\n\n{notes}" if notes else PROMPT
    regions: list[dict] = []
    usages, last_exc, provider = [], None, routes[0][0]
    client: httpx.AsyncClient | None = None  # OpenRouter only; Gemini uses gemini.py's pool
    try:
        # One more attempt on bad JSON, a failed call or fewer than 3 usable regions (gemini.py
        # already retried transient HTTP errors with backoff): OpenRouter if it has a key.
        for attempt in range(2):
            provider, key, ask = routes[min(attempt, len(routes) - 1)]
            if provider == "openrouter" and client is None:
                client = httpx.AsyncClient(timeout=TIMEOUT_S)
            try:
                regions, usage = await ask(client, key, b64, send_mime, prompt)
                usages.append(usage)
            except (ValueError, KeyError, IndexError, TypeError, RuntimeError, httpx.HTTPError) as exc:
                last_exc = exc
                continue
            if len(regions) >= 3:
                break
    finally:
        if client is not None:
            await client.aclose()
    if len(regions) < 3:
        detail = f" (last error: {last_exc})" if last_exc else ""
        raise RuntimeError(f"model returned {len(regions)} usable regions, expected 3{detail}")
    regions = regions[:3]
    last_debug.clear()
    last_debug.update(
        attempts=len(usages), usage=usages, labels=[r.pop("label") for r in regions], effort=EFFORT,
        provider=provider, last_error=str(last_exc) if last_exc else None, depth_notes=notes,
    )
    return {
        "regions": [{"id": f"r{i}", **r} for i, r in enumerate(regions, 1)],
        "model": GEMINI_MODEL if provider == "gemini" else MODEL,
        "ms": int((time.perf_counter() - t0) * 1000),
    }
