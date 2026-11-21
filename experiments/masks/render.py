"""Approximate numpy version of the CORE_API §4 slider math, plus masked layers.

Not Core Image: just close enough to judge whether a plan looks intentional. Images are sRGB float
HxWx3 in 0..1; masks are float HxW in 0..1 at the same size.
"""
from __future__ import annotations

import numpy as np
from scipy import ndimage as ndi

from local_edits import guided_filter

LUMA = np.array([0.2126, 0.7152, 0.0722], np.float32)


def to_lin(x):
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4).astype(np.float32)


def to_srgb(x):
    x = np.clip(x, 0, None)
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.power(x, 1 / 2.4) - 0.055).astype(np.float32)


def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def adjust(img: np.ndarray, v: dict, mask_alpha: np.ndarray | None = None) -> np.ndarray:
    """Apply slider values to the whole image (the caller blends through the layer mask)."""
    v = {k: float(x) for k, x in (v or {}).items() if x}
    if not v:
        return img
    h, w = img.shape[:2]
    long_side = max(h, w)
    lin = to_lin(np.clip(img, 0, 1))
    # white balance and exposure in linear light
    wm, tn = v.get("warmth", 0) / 100, v.get("tint", 0) / 100
    if wm or tn:
        gain = np.array([1 + 0.40 * wm + 0.06 * tn, 1 + 0.06 * wm - 0.18 * tn, 1 - 0.50 * wm + 0.06 * tn],
                        np.float32).clip(0.3, None)  # warmth 25 ~ a +800 K shift
        gain /= float(gain @ LUMA)  # white balance should not change brightness
        lin = lin * gain
    if v.get("exposure"):
        lin = lin * 2.0 ** v["exposure"]
    x = to_srgb(lin)
    # tone in perceptual space, through luminance (ratio keeps hue)
    L = np.clip(x @ LUMA, 0, None)
    L0 = L.copy()
    Lc = np.clip(L, 0, 1)
    base = ndi.gaussian_filter(Lc, 0.006 * long_side)  # local mean: highlights/shadows act on regions
    if v.get("shadows"):
        s = v["shadows"] / 100
        ws = (1 - smooth(0.05, 0.55, base)) ** 1.5
        L = np.clip(L, 1e-4, None) ** (2.0 ** (-s * 1.1 * ws))
    if v.get("highlights"):
        hl = v["highlights"] / 100
        wh = smooth(0.45, 0.95, base)
        L = np.clip(L, 1e-4, None) ** (2.0 ** (-hl * 0.9 * wh))
    if v.get("whites") or v.get("blacks"):
        b0 = -v.get("blacks", 0) / 100 * 0.06
        w1 = 1 - v.get("whites", 0) / 100 * 0.10
        L = (L - b0) / max(1e-3, w1 - b0)
    if v.get("contrast"):
        k = v["contrast"] / 100
        Lq = np.clip(L, 0, 1)
        L = L + k * 0.55 * (Lq - 0.5) * 4 * Lq * (1 - Lq)
    if v.get("clarity"):
        c = v["clarity"] / 100
        Lq = np.clip(L, 0, 1)
        blur = ndi.gaussian_filter(Lq, 0.015 * long_side)
        L = L + c * 0.9 * (Lq - blur) * 4 * Lq * (1 - Lq)
    eps = 0.03
    x = x * ((np.clip(L, 0, None) + eps) / (L0 + eps))[..., None]
    # color
    sat, vib = v.get("saturation", 0) / 100, v.get("vibrance", 0) / 100
    if sat or vib:
        Y = (x @ LUMA)[..., None]
        chroma = x.max(-1, keepdims=True) - x.min(-1, keepdims=True)
        f = 1 + sat + vib * (1 - smooth(0.05, 0.6, chroma)) * 1.0
        x = Y + (x - Y) * f
    if v.get("vignette"):
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        r = np.hypot((xx - w / 2) / (w / 2), (yy - h / 2) / (h / 2)) / np.sqrt(2)
        x = to_srgb(to_lin(np.clip(x, 0, 1)) * (2.0 ** (v["vignette"] / 100 * 1.2 * smooth(0.45, 1.0, r)))[..., None])
    return np.clip(x, 0, 1).astype(np.float32)


def layer_alpha(spec: dict, masks: dict, img: np.ndarray, Ln: np.ndarray | None) -> np.ndarray:
    """Mask spec {source, invert, subtract, feather, edge} -> alpha 0..1."""
    h, w = img.shape[:2]
    src = spec["source"]
    m = masks[src].copy() if src in masks else np.zeros((h, w), np.float32)
    if spec.get("invert"):
        m = 1 - m
    for s in spec.get("subtract") or []:
        if s in masks:
            m = m * (1 - masks[s])
    f = float(spec.get("feather") or 0)
    if f > 0:
        r = max(1, int(f / 100 * 0.04 * max(h, w)))  # feather 100 = 4% of the long side
        edge = spec.get("edge", "image")
        if edge == "none" or (edge == "depth" and Ln is None):
            m = ndi.gaussian_filter(m, r / 2)
        else:  # edge-aware feather: soft where the mask edge crosses smooth image, crisp at real edges
            guide = img if edge == "image" else Ln
            soft = ndi.gaussian_filter(m, r / 2)
            snapped = guided_filter(guide, m, 3, 1e-3)
            g = guide.mean(-1) if guide.ndim == 3 else guide
            grad = np.hypot(*np.gradient(ndi.gaussian_filter(g, 1.0)))
            near_edge = ndi.maximum_filter(smooth(0.01, 0.04, grad), size=2 * r + 1)
            near_edge = ndi.gaussian_filter(near_edge, r / 3)
            m = near_edge * snapped + (1 - near_edge) * soft
    return np.clip(m, 0, 1).astype(np.float32)


def render(img: np.ndarray, plan: dict, masks: dict, Ln: np.ndarray | None = None,
           subject: str | None = "subject") -> np.ndarray:
    """Global values first, then each layer blended through its mask, in order."""
    g = dict(plan.get("values") or {})
    sl, bl = g.pop("subject_light", 0), g.pop("background_light", 0)
    out = adjust(img, g)
    if (sl or bl) and subject in masks:
        s = masks[subject]
        out = to_srgb(to_lin(out) * (2.0 ** ((sl * s + bl * (1 - s)) / 100 * 0.75))[..., None])
    for layer in plan.get("layers") or []:
        a = layer_alpha(layer["mask"], masks, img, Ln)[..., None]
        out = out * (1 - a) + adjust(out, layer["values"]) * a
    return np.clip(out, 0, 1)
