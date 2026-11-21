"""(a) Gemini native segmentation: box_2d + mask, in the PNG (2.5-style) and polygon (Gemini 4 docs) formats.

usage: seg_native.py img-1016.jpg [models=argon,neon,hydrogen] [fmts=png,poly]
"""
from __future__ import annotations

import asyncio
import json
import sys

import numpy as np
from PIL import Image, ImageDraw

from common import OUT, ask, decode_png, grid, load_jpeg, mask_size, overlay, parse_json_loose, to_pil, work_image

TARGETS = ("each person (one entry per person), each visible face, the sky, water (sea, lake), "
           "foliage (trees, bushes, grass), the ground (road, pavement, sand, dirt), and the single "
           "most distracting object or area")

PROMPT_PNG = f"""Give the segmentation masks for: {TARGETS}.
Output a JSON list of segmentation masks where each entry contains the 2D bounding box in the key
"box_2d", the segmentation mask in key "mask", and the text label in the key "label".
Use descriptive labels. Skip targets that are not in the image."""

PROMPT_POLY = f"""Give the segmentation masks for: {TARGETS}.
Output a JSON list of segmentation masks where each entry contains the 2D bounding box in the key
"box_2d" as [ymin, xmin, ymax, xmax] normalized to 0-1000, the segmentation mask in key "mask" as a
polygon of [x, y] points normalized to 0-1000, and the text label in the key "label".
Use descriptive labels. Skip targets that are not in the image."""

SCHEMA_POLY = {
    "type": "array",
    "items": {
        "type": "object",
        "properties": {
            "label": {"type": "string"},
            "box_2d": {"type": "array", "items": {"type": "integer"}},
            "mask": {"type": "array", "items": {"type": "array", "items": {"type": "integer"}}},
        },
        "required": ["label", "box_2d", "mask"],
    },
}


def box_px(b, w, h):
    y0, x0, y1, x1 = [float(v) / 1000 for v in b[:4]]
    return (int(round(x0 * w)), int(round(y0 * h)), max(int(round(x1 * w)), int(round(x0 * w)) + 1),
            max(int(round(y1 * h)), int(round(y0 * h)) + 1))


def raster_png(item, w, h) -> np.ndarray:
    m = np.zeros((h, w), np.float32)
    x0, y0, x1, y1 = box_px(item["box_2d"], w, h)
    x0, y0, x1, y1 = max(0, x0), max(0, y0), min(w, x1), min(h, y1)
    if x1 <= x0 or y1 <= y0:
        return m
    pm = decode_png(item["mask"], (x1 - x0, y1 - y0))
    m[y0:y1, x0:x1] = (pm > 0.5).astype(np.float32)
    return m


SWAP = False


def raster_poly(item, w, h) -> np.ndarray:
    pts = item.get("mask") or []
    im = Image.new("L", (w, h), 0)
    # polygons may come as one ring [[x,y],...] or several rings
    rings = [pts] if pts and isinstance(pts[0], (list, tuple)) and len(pts[0]) == 2 and \
        not isinstance(pts[0][0], (list, tuple)) else pts
    for ring in rings:
        if SWAP:
            xy = [(float(p[1]) / 1000 * w, float(p[0]) / 1000 * h) for p in ring if len(p) >= 2]
        else:
            xy = [(float(p[0]) / 1000 * w, float(p[1]) / 1000 * h) for p in ring if len(p) >= 2]
        if len(xy) >= 3:
            ImageDraw.Draw(im).polygon(xy, fill=255)
    return np.asarray(im, np.float32) / 255


async def run(name: str, models: list[str], fmts: list[str]):
    jpg = load_jpeg(name, 1024)
    img = work_image(load_jpeg(name))
    h, w = img.shape[:2]
    jobs = []
    for m in models:
        for f in fmts:
            if f == "png":
                jobs.append((m, f, ask(f"gemini-4-{m}", [jpg, PROMPT_PNG], tag="segnative-png",
                                       gen_extra={"responseMimeType": "application/json"})))
            else:
                jobs.append((m, f, ask(f"gemini-4-{m}", [jpg, PROMPT_POLY], schema=SCHEMA_POLY,
                                       tag="segnative-poly")))
    res = await asyncio.gather(*[j[2] for j in jobs])
    panels, summary = [], []
    for (m, f, _), r in zip(jobs, res):
        row = {"image": name, "model": m, "fmt": f, "ms": r["ms"], "cached": r["cached"],
               "error": r.get("error"), "usage": r.get("usage")}
        masks = {}
        try:
            items = r["data"] if r.get("data") is not None else parse_json_loose(r["text"])
            if isinstance(items, dict):
                items = next((v for v in items.values() if isinstance(v, list)), [])
            for it in items:
                lab = str(it.get("label", "?"))[:28]
                mk = raster_png(it, w, h) if f == "png" else raster_poly(it, w, h)
                k = lab
                i = 2
                while k in masks:
                    k, i = f"{lab} {i}", i + 1
                masks[k] = mk
            row["n"] = len(items)
            row["mask_kinds"] = sorted({type(it.get("mask")).__name__ for it in items})
            row["nonempty"] = sum(1 for v in masks.values() if v.sum() > 50)
        except Exception as exc:
            row["parse_error"] = f"{type(exc).__name__}: {exc}"[:200]
            row["text_head"] = (r.get("text") or "")[:200]
        summary.append(row)
        panels.append(overlay(img, masks, f"{m} {f} {r['ms']}ms n={len(masks)}"))
    stem = name.rsplit(".", 1)[0]
    p = grid(panels, len(fmts), OUT / f"a_native_{stem}{'_swap' if SWAP else ''}.jpg", width=1800)
    with open(OUT / "a_native.jsonl", "a") as fh:
        for row in summary:
            fh.write(json.dumps(row) + "\n")
    for row in summary:
        print({k: v for k, v in row.items() if k != "usage"}, (row.get("usage") or {}))
    print(p)


if __name__ == "__main__":
    name = sys.argv[1]
    models = (sys.argv[2] if len(sys.argv) > 2 else "argon,neon,hydrogen").split(",")
    fmts = (sys.argv[3] if len(sys.argv) > 3 else "png,poly").split(",")
    SWAP = len(sys.argv) > 4 and sys.argv[4] == "swap"
    asyncio.run(run(name, models, fmts))
