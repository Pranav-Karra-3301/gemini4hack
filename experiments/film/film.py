"""Per-photo film emulation designed by Gemini 4.

Approach A (recommended): Gemini returns a structured film recipe (LOOK_SCHEMA); `compile_lut`
turns it into an N^3 3D LUT (sRGB in -> sRGB out) and `effects_of` into a small effects dict
(grain, halation, bloom, vignette). `render` applies both with numpy. The LUT maps 1:1 to
CIColorCubeWithColorSpace and to a WebGL2 3D texture; every effect has a Core Image twin.

Approach B (experimental): Gemini writes a GLSL ES 3.0 fragment shader (`design_shader`),
validated in headless Chrome by shader_harness.js.

Public API:
    async def design_look(image_bytes, variant, model=NEON) -> dict
    def compile_lut(spec, size=33) -> np.ndarray      # (size, size, size, 3) indexed [r, g, b]
    def effects_of(spec) -> dict
    def render(image, lut, effects, strength=1.0) -> PIL.Image
    def write_cube(lut, path, title)
"""
from __future__ import annotations

import base64
import io
import json
import math
import os
import time
from pathlib import Path

import httpx
import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
API = "https://generativelanguage.googleapis.com/v1beta"
NEON = "gemini-4-neon"
HYDROGEN = "gemini-4-hydrogen"


def _key() -> str:
    k = os.environ.get("GEMINI_API_KEY")
    if k:
        return k
    for line in (ROOT / ".env").read_text().splitlines():
        if line.startswith("GEMINI_API_KEY="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise RuntimeError("GEMINI_API_KEY missing")


def prepare_jpeg(data: bytes, long_side: int = 1024, quality: int = 85) -> bytes:
    im = Image.open(io.BytesIO(data)).convert("RGB")
    im.thumbnail((long_side, long_side), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=quality)
    return buf.getvalue()


async def gemini(model: str, parts: list, *, schema: dict | None = None, system: str | None = None,
                 thinking: str = "low", temperature: float | None = None, timeout: float = 90.0) -> dict:
    """One generateContent call. Returns {text, data, ms, usage, model}."""
    gen: dict = {"thinkingConfig": {"thinkingLevel": thinking}}
    if temperature is not None:
        gen["temperature"] = temperature
    if schema is not None:
        gen["responseMimeType"] = "application/json"
        gen["responseSchema"] = schema
    body: dict = {"contents": [{"role": "user", "parts": parts}], "generationConfig": gen}
    if system:
        body["systemInstruction"] = {"parts": [{"text": system}]}
    t0 = time.perf_counter()
    last = None
    async with httpx.AsyncClient(timeout=timeout) as c:
        for attempt in range(3):
            r = await c.post(f"{API}/models/{model}:generateContent", json=body,
                             headers={"x-goog-api-key": _key()})
            if r.status_code == 200:
                break
            last = f"HTTP {r.status_code}: {r.text[:300]}"
            if r.status_code not in (429, 500, 502, 503, 504):
                raise RuntimeError(last)
            import asyncio
            await asyncio.sleep(2 * (attempt + 1))
        else:
            raise RuntimeError(last)
    ms = round((time.perf_counter() - t0) * 1000)
    resp = r.json()
    cand = (resp.get("candidates") or [{}])[0]
    text = "".join(p.get("text", "") for p in (cand.get("content") or {}).get("parts", [])
                   if not p.get("thought")).strip()
    data = json.loads(text) if schema is not None else None
    u = resp.get("usageMetadata", {})
    return {"text": text, "data": data, "ms": ms, "model": model,
            "usage": {"in": u.get("promptTokenCount"), "out": u.get("candidatesTokenCount"),
                      "thought": u.get("thoughtsTokenCount")}}


def _img_part(jpeg: bytes) -> dict:
    return {"inlineData": {"mimeType": "image/jpeg", "data": base64.b64encode(jpeg).decode()}}


# ---------------------------------------------------------------------------------------------
# A. Look spec

CURVE_X = [0.0, 0.12, 0.25, 0.5, 0.75, 0.88, 1.0]
BANDS = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
BAND_HUES = [0, 30, 60, 120, 180, 225, 270, 315]

N, S, O, A = "NUMBER", "STRING", "OBJECT", "ARRAY"


def _num(desc: str, lo: float, hi: float) -> dict:
    return {"type": N, "description": desc, "minimum": lo, "maximum": hi}


def _obj(props: dict, desc: str = "") -> dict:
    d = {"type": O, "properties": props, "required": list(props), "propertyOrdering": list(props)}
    if desc:
        d["description"] = desc
    return d


_curve = {"type": A, "minItems": 7, "maxItems": 7, "items": {"type": N},
          "description": "output values 0..1 at the fixed inputs x = 0, .12, .25, .5, .75, .88, 1"}
_bands = lambda d, lo, hi: {"type": A, "minItems": 8, "maxItems": 8, "description": d,
                             "items": {"type": N, "minimum": lo, "maximum": hi}}

# v2 schema: HSL as three 8-value arrays (bands red, orange, yellow, green, aqua, blue, purple,
# magenta) instead of 8 nested objects: ~40% fewer output tokens than v1, same information.
LOOK_SCHEMA = _obj({
    "read": _obj({"light": {"type": S, "description": "quality, direction, color temperature (<=12 words)"},
                  "palette": {"type": S, "description": "dominant colors and how much skin (<=12 words)"},
                  "needs": {"type": S, "description": "what the photo needs from a grade (<=12 words)"},
                  "considered": {"type": S, "description": "2-3 stocks weighed and why the chosen one wins (<=25 words)"}},
                 "fill this first: your reading of the photo, which drives every number below"),
    "name": {"type": S, "description": "short evocative look name, 1-3 words"},
    "rationale": {"type": S, "description": "one line: what in this photo drove the choice"},
    "evokes": {"type": S, "description": "the stock / process and its signature, e.g. "
                                          "'Fuji Pro 400H: mint shadows, pastel skin, soft contrast'"},
    "curves": _obj({"master": _curve, "r": _curve, "g": _curve, "b": _curve}),
    "fade": _obj({"black_lift": _num("0..0.08", 0, 0.12), "white_point": _num("0.9..1", 0.85, 1)}),
    "mixer": {"type": A, "minItems": 9, "maxItems": 9, "items": {"type": N},
              "description": "3x3 row-major [Rr,Rg,Rb, Gr,Gg,Gb, Br,Bg,Bb]; identity = [1,0,0,0,1,0,0,0,1]"},
    "split_tone": _obj({"shadow_hue": _num("deg", 0, 360), "shadow_strength": _num("0..1", 0, 1),
                        "highlight_hue": _num("deg", 0, 360), "highlight_strength": _num("0..1", 0, 1),
                        "balance": _num("-1 shadows .. 1 highlights", -1, 1)}),
    "hsl": _obj({"hue": _bands("hue shift deg per band [red, orange, yellow, green, aqua, blue, purple, magenta]", -20, 20),
                 "sat": _bands("saturation change -1..1 per band, same order", -1, 1),
                 "lum": _bands("luminance change -1..1 per band, same order", -1, 1)}),
    "color": _obj({"saturation": _num("-1..1", -1, 1), "vibrance": _num("-1..1", -1, 1)}),
    "grain": _obj({"amount": _num("0..1", 0, 1), "size": _num("px at 2048 px, 0.5..3", 0.5, 3),
                   "roughness": _num("0..1", 0, 1)}),
    "halation": _obj({"amount": _num("0..1", 0, 1), "threshold": _num("0.6..1 luminance", 0.5, 1),
                      "radius": _num("fraction of long side, 0.002..0.03", 0.002, 0.03),
                      "hue": _num("tint hue deg, classic red-orange 10-25", 0, 360)}),
    "bloom": _obj({"amount": _num("0..1", 0, 1), "threshold": _num("0.6..1", 0.5, 1),
                   "radius": _num("fraction of long side, 0.005..0.06", 0.005, 0.06)}),
    "vignette": _obj({"amount": _num("0..1 corner darkening", 0, 1),
                      "midpoint": _num("0.3..1 falloff start, fraction of half-diagonal", 0.3, 1)}),
})

SYSTEM = """You are a senior colorist who designs film emulation looks (Dehancer / FilmConvert / RNI
grade) for one specific photo. You return a numeric recipe; a compiler turns it into a 3D LUT plus
grain, halation, bloom and vignette, and guards skin hue and neutral casts.

Pipeline order: channel mixer (linear light; rows are renormalized to sum 1, so it only changes
color crosstalk, never neutrals) -> per-band HSL -> saturation/vibrance -> master curve -> R/G/B
curves -> fade (black lift, white point) -> split toning -> halation, bloom, vignette, grain.

1. Read the photo first (fill `read`): light quality and direction (hard sun, open shade, overcast, golden hour,
   backlight, mixed), white balance, dominant palette, the subject (are there faces? how much of
   the frame?), and the mood. Note what the photo needs (flat overcast wants density; harsh midday
   wants a softer shoulder; golden backlight wants its glow protected; busy greens may want
   calming).
2. Pick a stock whose signature serves THAT. The list below is unordered; there is no house look.
   Portra is for skin in soft light; Gold is for sunny warm snapshots and golden hour; other light
   usually wants another stock. Signatures:
   - Kodak Portra 400/160: low contrast, warm-neutral natural skin, pastel greens, creamy shoulder.
   - Kodak Gold 200 / UltraMax: warm yellow-gold cast, saturated warm tones, nostalgic snapshot.
   - Kodak Ektar 100: punchy saturation, deep blues, vivid reds, crisp contrast, fine grain.
   - Fuji Pro 400H / Superia: cool mint-green shadows, cyan skies, pastel airy skin, soft contrast.
   - Fuji Velvia 50 / Provia: dense slide contrast, deep saturated blues and greens, dark toe.
   - Kodak Ektachrome E100: clean cool slide, crisp neutral-cool blues, moderate contrast.
   - Kodachrome 64: rich reds, warm yellows, dense shadows, slightly cyan-teal blues.
   - CineStill 800T / Vision3 500T: tungsten-balanced cool cast, teal shadows, strong red halation
     around highlights.
   - Fuji Eterna / cinema print: low saturation, flat midtones, teal shadows, gentle warm skin.
   - Bleach bypass / ENR: desaturated, hard contrast, silvery highlights, dense blacks.
   - Expired / faded stock: lifted blacks, warm or magenta fade, softened contrast, heavy grain.
3. Make the look clearly visible at a glance on a phone (someone flipping between original and look
   sees the difference immediately) but never garish. Typical magnitudes:
   - master curve: knots 0.02-0.07 off identity to shape toe/shoulder (S for density, a softer
     shoulder for harsh sun); first value near 0 (fade goes in fade.black_lift, 0-0.06).
   - R/G/B curves: 0.02-0.05 off identity at the toe or shoulder where the stock tints (e.g. b up
     and r down in the shadows for teal shadows; r up and b down at the top for warm highlights).
   - split toning strength 0.25-0.6; HSL hue shifts of 5-15 deg on greens/aquas/blues and sat
     changes of 0.1-0.4 are what make stocks distinct (olive vs teal greens, cyan vs navy skies).
   - mixer off-diagonals 0-0.08.
4. Skin stays natural and believable: red/orange bands only small changes (hue +/-5, sat
   -0.3..+0.1), no green/grey/magenta skin, don't crush faces into shadow.
5. Grain 0.15-0.45 (more for faster or expired stocks); halation only where there are bright
   highlights against darker areas (stronger for CineStill); bloom 0-0.3; vignette 0-0.3.
6. Split toning and channel curves come from the stock and the photo's own palette, not a habit:
   teal shadows + amber highlights is ONE option (CineStill, cinema), not the default. Echo or
   complement what is there: e.g. amber highlights that extend a sunset, sage/olive shadows for
   overcast greens, neutral or warm shadows when the frame is already mostly blue, magenta-warm
   fade for expired stock, near-zero split toning for clean slide film.
Say in `rationale` what in the image drove the choice."""

VARIANTS = {
    "fit": "Design the film look that best fits this photo: the stock and grade that best serve its "
           "light, palette, subject and mood, as a great photographer would have chosen. Return the recipe.",
    "bold": "Design a bold alternative: a different stock family than the obvious best fit, with more "
            "character (e.g. CineStill tungsten, bleach bypass, expired film, slide film, cinema print), "
            "still tasteful, grounded in what this image's light and palette can carry, skin believable. "
            "Return the recipe.",
    "generic": "Apply a Kodak Portra 400 look. Return the recipe.",
}


async def design_look(image_bytes: bytes, variant: str, model: str = NEON) -> dict:
    """Ask Gemini for a film look recipe. variant: 'fit' | 'bold' | 'generic' (or free text)."""
    jpeg = prepare_jpeg(image_bytes, 1024)
    instr = VARIANTS.get(variant, variant)
    parts = [_img_part(jpeg), {"text": instr}]
    r = await gemini(model, parts, schema=LOOK_SCHEMA, system=SYSTEM)
    spec = r["data"]
    spec["_meta"] = {"model": r["model"], "ms": r["ms"], "usage": r["usage"], "variant": variant}
    return spec


# ---------------------------------------------------------------------------------------------
# Compiler: spec -> sanitized spec -> LUT

def _clamp(v, lo, hi, default=0.0):
    try:
        v = float(v)
    except (TypeError, ValueError):
        return default
    if not math.isfinite(v):
        return default
    return min(hi, max(lo, v))


def sanitize(spec: dict) -> dict:
    """Clamp every field into a tasteful range and enforce structure (monotonic curves,
    near-identity channel curves, neutral-preserving mixer). Returns a new dict."""
    out: dict = {k: spec.get(k, "") for k in ("name", "rationale", "evokes")}
    cv = spec.get("curves") or {}
    curves = {}
    for ch in ("master", "r", "g", "b"):
        ys = list(cv.get(ch) or CURVE_X)
        if len(ys) != 7:
            ys = list(np.interp(CURVE_X, np.linspace(0, 1, len(ys)), ys)) if len(ys) >= 2 else list(CURVE_X)
        ys = [_clamp(y, 0, 1, x) for y, x in zip(ys, CURVE_X)]
        dev = 0.10 if ch == "master" else 0.06      # max deviation from identity per knot
        ys = [min(x + dev, max(x - dev, y)) for y, x in zip(ys, CURVE_X)]
        if ch == "master":
            ys[0] = min(ys[0], 0.04)
            ys[-1] = max(ys[-1], 0.94)
        ys = list(np.maximum.accumulate(ys))      # non-decreasing
        curves[ch] = ys
    out["curves"] = curves
    fd = spec.get("fade") or {}
    out["fade"] = {"black_lift": _clamp(fd.get("black_lift"), 0, 0.08),
                   "white_point": _clamp(fd.get("white_point", 1), 0.9, 1, 1)}
    m = spec.get("mixer") or [1, 0, 0, 0, 1, 0, 0, 0, 1]
    m = (list(m) + [0] * 9)[:9]
    M = np.array([_clamp(v, -0.25, 1.5) for v in m]).reshape(3, 3)
    for i in range(3):
        M[i, i] = max(M[i, i], 0.7)
        M[i] /= M[i].sum()                         # rows sum to 1: neutrals stay neutral
    # Limit total crosstalk strength: blend toward identity if far away.
    d = np.abs(M - np.eye(3)).max()
    if d > 0.25:
        M = np.eye(3) + (M - np.eye(3)) * (0.25 / d)
    out["mixer"] = M.round(4).tolist()
    st = spec.get("split_tone") or {}
    out["split_tone"] = {"shadow_hue": _clamp(st.get("shadow_hue"), 0, 360) % 360,
                         "shadow_strength": _clamp(st.get("shadow_strength"), 0, 0.6),
                         "highlight_hue": _clamp(st.get("highlight_hue"), 0, 360) % 360,
                         "highlight_strength": _clamp(st.get("highlight_strength"), 0, 0.6),
                         "balance": _clamp(st.get("balance"), -1, 1)}
    hsl = spec.get("hsl") or {}
    if isinstance(hsl.get("hue"), list):           # v2 arrays -> per-band dict
        hsl = {b: {k: (list(hsl.get(k) or []) + [0] * 8)[i] for k in ("hue", "sat", "lum")}
               for i, b in enumerate(BANDS)}
    out["hsl"] = {}
    for b in BANDS:
        e = hsl.get(b) or {}
        skin = b in ("red", "orange")
        hcap = 6 if skin else (10 if b in ("aqua", "blue") else 15)   # skies: no teal/cyan overshoot
        out["hsl"][b] = {"hue": _clamp(e.get("hue"), -hcap, hcap),
                         "sat": _clamp(e.get("sat"), -0.35 if skin else -0.6, 0.15 if skin else 0.4),
                         "lum": _clamp(e.get("lum"), -0.2 if skin else -0.4, 0.2 if skin else 0.3)}
    c = spec.get("color") or {}
    out["color"] = {"saturation": _clamp(c.get("saturation"), -0.6, 0.3),
                    "vibrance": _clamp(c.get("vibrance"), -0.5, 0.4)}
    g = spec.get("grain") or {}
    out["grain"] = {"amount": _clamp(g.get("amount"), 0, 0.6), "size": _clamp(g.get("size", 1), 0.5, 3, 1),
                    "roughness": _clamp(g.get("roughness", 0.5), 0, 1, 0.5)}
    h = spec.get("halation") or {}
    out["halation"] = {"amount": _clamp(h.get("amount"), 0, 0.6), "threshold": _clamp(h.get("threshold", .8), .6, 1, .8),
                       "radius": _clamp(h.get("radius", .008), .002, .03, .008),
                       "hue": _clamp(h.get("hue", 15), 0, 360, 15) % 360}
    bl = spec.get("bloom") or {}
    out["bloom"] = {"amount": _clamp(bl.get("amount"), 0, 0.5), "threshold": _clamp(bl.get("threshold", .8), .6, 1, .8),
                    "radius": _clamp(bl.get("radius", .02), .005, .06, .02)}
    v = spec.get("vignette") or {}
    out["vignette"] = {"amount": _clamp(v.get("amount"), 0, 0.45), "midpoint": _clamp(v.get("midpoint", .6), .3, 1, .6)}
    return out


def srgb_to_lin(x):
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


def lin_to_srgb(x):
    x = np.clip(x, 0, None)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.power(x, 1 / 2.4) - 0.055)


LUMA = np.array([0.2126, 0.7152, 0.0722])


def _luma(rgb):
    return rgb @ LUMA


def rgb_to_hsv(rgb):
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx, mn = rgb.max(-1), rgb.min(-1)
    c = mx - mn
    h = np.zeros_like(mx)
    safe = np.where(c > 1e-8, c, 1)
    h = np.where(mx == r, ((g - b) / safe) % 6, h)
    h = np.where(mx == g, (b - r) / safe + 2, h)
    h = np.where(mx == b, (r - g) / safe + 4, h)
    h = np.where(c > 1e-8, h * 60.0, 0.0) % 360
    s = np.where(mx > 1e-8, c / np.where(mx > 1e-8, mx, 1), 0)
    return h, s, mx


def hsv_to_rgb(h, s, v):
    h = (h % 360) / 60.0
    i = np.floor(h).astype(int) % 6
    f = h - np.floor(h)
    p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    choices = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)]
    out = np.zeros(h.shape + (3,))
    for k, (a, b_, c) in enumerate(choices):
        m = i == k
        out[m, 0], out[m, 1], out[m, 2] = a[m], b_[m], c[m]
    return out


def _monotone_curve(xs, ys):
    """Fritsch-Carlson monotone cubic; returns f(x) vectorized."""
    xs, ys = np.asarray(xs, float), np.asarray(ys, float)
    d = np.diff(ys) / np.diff(xs)
    m = np.zeros_like(ys)
    m[1:-1] = (d[:-1] + d[1:]) / 2
    m[0], m[-1] = d[0], d[-1]
    for k in range(len(d)):
        if d[k] == 0:
            m[k] = m[k + 1] = 0
        else:
            a, b = m[k] / d[k], m[k + 1] / d[k]
            s = a * a + b * b
            if s > 9:
                t = 3 / math.sqrt(s)
                m[k], m[k + 1] = t * a * d[k], t * b * d[k]

    def f(x):
        x = np.clip(x, 0, 1)
        k = np.clip(np.searchsorted(xs, x, side="right") - 1, 0, len(xs) - 2)
        h = xs[k + 1] - xs[k]
        t = (x - xs[k]) / h
        h00, h10 = 2 * t**3 - 3 * t**2 + 1, t**3 - 2 * t**2 + t
        h01, h11 = -2 * t**3 + 3 * t**2, t**3 - t**2
        return h00 * ys[k] + h10 * h * m[k] + h01 * ys[k + 1] + h11 * h * m[k + 1]
    return f


def _band_weights(h):
    """Partition-of-unity weights (..., 8) for hue h (degrees), smooth between band centers."""
    hues = BAND_HUES + [360]
    w = np.zeros(h.shape + (8,))
    for k in range(8):
        a, b = hues[k], hues[k + 1]
        inside = (h >= a) & (h < b)
        t = np.where(inside, (h - a) / (b - a), 0)
        t = t * t * (3 - 2 * t)
        w[..., k] += np.where(inside, 1 - t, 0)
        w[..., (k + 1) % 8] += np.where(inside, t, 0)
    return w


def _hue_rgb(hue_deg):
    """Unit chroma direction for a hue, zero luma (an additive tint vector)."""
    c = hsv_to_rgb(np.array([hue_deg], float), np.array([1.0]), np.array([1.0]))[0]
    return c - _luma(c)


def _smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def _hue_dist(a, b):
    return (a - b + 180) % 360 - 180


def apply_look(rgb: np.ndarray, sp: dict, protect_skin: bool = True) -> np.ndarray:
    """Apply a sanitized look to sRGB values (..., 3) in [0,1]. Used to bake the LUT."""
    x0 = np.clip(rgb.astype(np.float64), 0, 1)
    h0, s0, v0 = rgb_to_hsv(x0)
    # 1. Channel mixer in linear light.
    lin = srgb_to_lin(x0) @ np.array(sp["mixer"]).T
    x = np.clip(lin_to_srgb(lin), 0, 1)
    # 2. HSL per band (weighted by chroma so neutrals are untouched).
    h, s, v = rgb_to_hsv(x)
    w = _band_weights(h)
    bands = sp["hsl"]
    dh = w @ np.array([bands[b]["hue"] for b in BANDS])
    ds = w @ np.array([bands[b]["sat"] for b in BANDS])
    dl = w @ np.array([bands[b]["lum"] for b in BANDS])
    chroma_w = _smooth(0.02, 0.25, s)
    h = h + dh * chroma_w
    s = np.clip(s * (1 + ds), 0, 1)
    x = hsv_to_rgb(h, s, v)
    x = x * (1 + 0.35 * dl * chroma_w)[..., None]
    x = np.clip(x, 0, 1)
    # 3. Saturation / vibrance around luma.
    L = _luma(x)[..., None]
    sat = sp["color"]["saturation"]
    vib = sp["color"]["vibrance"]
    _, s_now, _ = rgb_to_hsv(x)
    k = 1 + sat + vib * (1 - s_now)[..., None] ** 2
    x = np.clip(L + (x - L) * k, 0, 1)
    # 4. Curves: master on all channels, then per channel.
    fm = _monotone_curve(CURVE_X, sp["curves"]["master"])
    x = fm(x)
    for i, ch in enumerate("rgb"):
        x[..., i] = _monotone_curve(CURVE_X, sp["curves"][ch])(x[..., i])
    # 5. Fade.
    bl, wp = sp["fade"]["black_lift"], sp["fade"]["white_point"]
    x = bl + x * (wp - bl)
    # 6. Split toning (luma-preserving additive tint).
    st = sp["split_tone"]
    L = _luma(x)[..., None]
    bal = st["balance"]
    ws = np.clip(1 - L, 0, 1) ** 2 * (1 - 0.5 * max(bal, 0))
    wh = np.clip(L, 0, 1) ** 2 * (1 + 0.5 * min(bal, 0))
    x = x + 0.30 * (st["shadow_strength"] * ws * _hue_rgb(st["shadow_hue"])
                    + st["highlight_strength"] * wh * _hue_rgb(st["highlight_hue"]))
    x = np.clip(x, 0, 1)
    # 7. Chroma ceiling (no neon): saturation may not grow beyond s0*1.35+0.12, soft-knee near 1.
    h1, s1, v1 = rgb_to_hsv(x)
    cap = np.maximum(s0, np.minimum(s0 * 1.35 + 0.12, 0.92))
    s1 = np.where(s1 > cap, cap + (s1 - cap) * 0.25, s1)
    # 8. Skin protection: inputs that look like skin keep a skin hue and a sane saturation.
    if protect_skin:
        skin = (_smooth(-12, 2, _hue_dist(h0, 0)) * (1 - _smooth(48, 60, h0 % 360 * (h0 < 200)))
                * _smooth(0.08, 0.18, s0) * (1 - _smooth(0.65, 0.8, s0)) * _smooth(0.12, 0.3, v0))
        # Output hue may move at most 10 deg, and never further outside [8, 42] deg than it was.
        d = _hue_dist(h1, h0)
        dmin = np.maximum(np.minimum(_hue_dist(8.0, h0), 0), -10)
        dmax = np.minimum(np.maximum(_hue_dist(42.0, h0), 0), 10)
        h1 = h1 + (np.clip(d, dmin, dmax) - d) * skin
        s_lo, s_hi = s0 * 0.75, s0 * 1.25 + 0.03
        s1 = s1 + (np.clip(s1, s_lo, s_hi) - s1) * skin
    x = hsv_to_rgb(h1, np.clip(s1, 0, 1), v1)
    return np.clip(x, 0, 1)


def _limit_neutral_cast(lut: np.ndarray, grid: np.ndarray, mid: float = 0.035, ends: float = 0.06) -> np.ndarray:
    """Bound the color cast the look puts on neutral grays, per tone level. The gray axis
    (lattice diagonal) defines a per-level offset; the excess beyond the allowed cast is removed
    from every lattice point at that input luma."""
    n = lut.shape[0]
    diag = lut[np.arange(n), np.arange(n), np.arange(n)]            # (n, 3)
    dev = diag - diag.mean(-1, keepdims=True)
    lv = np.linspace(0, 1, n)
    allowed = mid + (ends - mid) * np.abs(lv - 0.5) * 2
    mag = np.abs(dev).max(-1)
    scale = np.where(mag > allowed, allowed / np.maximum(mag, 1e-9), 1.0)
    corr = dev * (1 - scale)[:, None]                                 # (n, 3) per gray level
    Lin = _luma(grid)
    corr_at = np.stack([np.interp(Lin, lv, corr[:, c]) for c in range(3)], -1)
    return np.clip(lut - corr_at, 0, 1)


def compile_lut(spec: dict, size: int = 33, protect_skin: bool = True) -> np.ndarray:
    """Spec (raw or sanitized) -> (size, size, size, 3) float32 LUT, indexed [r, g, b]."""
    sp = spec if spec.get("_sanitized") else {**sanitize(spec), "_sanitized": True}
    t = np.linspace(0, 1, size)
    grid = np.stack(np.meshgrid(t, t, t, indexing="ij"), -1)        # [r, g, b, 3]
    lut = apply_look(grid.reshape(-1, 3), sp, protect_skin).reshape(grid.shape)
    lut = _limit_neutral_cast(lut, grid)
    return lut.astype(np.float32)


def effects_of(spec: dict) -> dict:
    sp = spec if spec.get("_sanitized") else sanitize(spec)
    return {k: sp[k] for k in ("grain", "halation", "bloom", "vignette")}


def write_cube(lut: np.ndarray, path, title: str = "look") -> None:
    """.cube (Adobe/Resolve): red varies fastest. Same order as CIColorCube data and a WebGL
    texImage3D(width=r, height=g, depth=b)."""
    n = lut.shape[0]
    lines = [f'TITLE "{title}"', f"LUT_3D_SIZE {n}", "DOMAIN_MIN 0 0 0", "DOMAIN_MAX 1 1 1"]
    data = lut.transpose(2, 1, 0, 3).reshape(-1, 3)                  # b outer, g, r inner
    lines += [f"{r:.6f} {g:.6f} {b:.6f}" for r, g, b in data]
    Path(path).write_text("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------------------------
# Renderer

def apply_lut(x: np.ndarray, lut: np.ndarray) -> np.ndarray:
    """Trilinear 3D LUT lookup; x (H, W, 3) in [0,1]."""
    n = lut.shape[0]
    p = np.clip(x, 0, 1) * (n - 1)
    i0 = np.minimum(np.floor(p).astype(np.int32), n - 2)
    f = p - i0
    r0, g0, b0 = i0[..., 0], i0[..., 1], i0[..., 2]
    fr, fg, fb = f[..., 0:1], f[..., 1:2], f[..., 2:3]
    c = lambda dr, dg, db: lut[r0 + dr, g0 + dg, b0 + db]
    c00 = c(0, 0, 0) * (1 - fr) + c(1, 0, 0) * fr
    c10 = c(0, 1, 0) * (1 - fr) + c(1, 1, 0) * fr
    c01 = c(0, 0, 1) * (1 - fr) + c(1, 0, 1) * fr
    c11 = c(0, 1, 1) * (1 - fr) + c(1, 1, 1) * fr
    c0 = c00 * (1 - fg) + c10 * fg
    c1 = c01 * (1 - fg) + c11 * fg
    return c0 * (1 - fb) + c1 * fb


def _blur(a: np.ndarray, radius_px: float) -> np.ndarray:
    """Gaussian blur of a float (H, W, 3) array via a downscaled PIL blur (fast, smooth)."""
    h, w = a.shape[:2]
    k = max(1, int(radius_px / 6))
    small = Image.fromarray(np.clip(a * 255, 0, 255).astype(np.uint8)).resize(
        (max(1, w // k), max(1, h // k)), Image.BILINEAR)
    small = small.filter(ImageFilter.GaussianBlur(radius_px / k))
    return np.asarray(small.resize((w, h), Image.BILINEAR), np.float32) / 255


def render(image: Image.Image, lut: np.ndarray, effects: dict, strength: float = 1.0,
           seed: int = 7) -> Image.Image:
    x0 = np.asarray(image.convert("RGB"), np.float32) / 255
    h, w = x0.shape[:2]
    long = max(h, w)
    x = apply_lut(x0, lut)
    x = x0 + (x - x0) * strength
    lin = srgb_to_lin(x)
    L = _luma(x)
    # Halation: bright areas bleed a red-orange glow (light scattering back through the base).
    ha = effects["halation"]
    if ha["amount"] > 0.01:
        mask = _smooth(ha["threshold"], min(1.0, ha["threshold"] + 0.15), L)[..., None]
        src = (lin * mask).max(-1, keepdims=True).repeat(3, -1)
        glow = _blur(np.clip(src, 0, 1), ha["radius"] * long)
        tint = hsv_to_rgb(np.array([ha["hue"]]), np.array([0.85]), np.array([1.0]))[0]
        lin = lin + ha["amount"] * strength * 0.9 * glow * tint * (1 - mask * 0.6)
    # Bloom: soft neutral diffusion of highlights.
    bl = effects["bloom"]
    if bl["amount"] > 0.01:
        mask = _smooth(bl["threshold"], 1.0, L)[..., None]
        glow = _blur(np.clip(lin * mask, 0, 1), bl["radius"] * long)
        lin = 1 - (1 - lin) * (1 - bl["amount"] * strength * 0.6 * glow)   # screen
    x = lin_to_srgb(lin)
    # Vignette.
    vg = effects["vignette"]
    if vg["amount"] > 0.01:
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        r = np.hypot((xx - w / 2) / (long / 2), (yy - h / 2) / (long / 2))
        r = r / r.max()
        fall = _smooth(vg["midpoint"], 1.15, r)
        x = x * (1 - vg["amount"] * strength * 0.7 * fall)[..., None]
    # Grain: luminance-dependent, mostly monochrome, size in px at 2048 long side.
    gr = effects["grain"]
    if gr["amount"] > 0.01:
        rng = np.random.default_rng(seed)
        s = max(1.0, gr["size"] * long / 2048)

        def octave(scale):
            gh, gw = max(2, int(h / scale)), max(2, int(w / scale))
            n = rng.standard_normal((gh, gw, 3)).astype(np.float32)
            if scale > 1:
                n = np.stack([np.asarray(Image.fromarray(n[..., c]).resize((w, h), Image.BICUBIC))
                              for c in range(3)], -1)
                n /= max(n.std(), 1e-6)
            return n
        n = octave(s) + gr["roughness"] * 0.6 * octave(s * 2.2)
        n /= n.std()
        mono = n.mean(-1, keepdims=True)
        n = mono * (1 - 0.35 * gr["roughness"]) + (n - mono) * 0.35 * gr["roughness"]
        Lx = _luma(np.clip(x, 0, 1))[..., None]
        resp = 0.35 + 2.6 * Lx * (1 - Lx)                     # strongest in the midtones
        x = x + n * gr["amount"] * strength * 0.055 * resp
    return Image.fromarray((np.clip(x, 0, 1) * 255 + 0.5).astype(np.uint8))


# ---------------------------------------------------------------------------------------------
# B. Shader

SHADER_SCHEMA = _obj({"name": {"type": S}, "rationale": {"type": S, "description": "one line"},
                      "glsl": {"type": S, "description": "complete GLSL ES 3.0 fragment shader source"}})

SHADER_PROMPT = """You are a senior colorist and graphics engineer. Write a WebGL2 fragment shader
(GLSL ES 3.0) that applies a custom film emulation look tailored to THIS photo: its light, palette,
subject and mood (tone curve, film color response, split toning, subtle grain, optional halation,
vignette). Tasteful and photographic; skin must stay natural. Pick a specific stock whose
signature serves this light (don't default to Portra). Keep it visible at a glance but don't wash
the photo out: black lift at most 0.05, keep midtone contrast, no haze over the whole frame.

Hard contract (the harness only provides this):
#version 300 es
precision highp float;
uniform sampler2D u_image;   // the photo, upright, sRGB-encoded
uniform vec2 u_res;          // output size in px
uniform float u_time;        // seconds (seed grain with it; may be 0)
uniform float u_strength;    // 0..1, mix between original (0) and the full look (1)
in vec2 v_uv;                // 0..1, (0,0) = bottom-left
out vec4 outColor;
- The source must start with `#version 300 es` on its first line and declare exactly these.
- Single pass. Neighborhood sampling for halation/bloom is fine but at most 48 texture taps.
- No extensions, no other uniforms or textures, no arrays of uniforms.
- Write alpha = 1.0."""


async def design_shader(image_bytes: bytes, model: str = NEON, history: list | None = None) -> dict:
    """history: [(glsl, error_log), ...] from failed attempts, fed back for repair."""
    jpeg = prepare_jpeg(image_bytes, 1024)
    parts = [_img_part(jpeg), {"text": "Write the shader for this photo."}]
    for glsl, err in history or []:
        parts.append({"text": f"Your previous shader failed to compile/link in Chrome WebGL2:\n"
                              f"```\n{err[:1500]}\n```\nPrevious source:\n```glsl\n{glsl}\n```\n"
                              "Fix it and return the full corrected shader."})
    r = await gemini(model, parts, schema=SHADER_SCHEMA, system=SHADER_PROMPT)
    out = r["data"]
    out["_meta"] = {"model": r["model"], "ms": r["ms"], "usage": r["usage"]}
    return out
