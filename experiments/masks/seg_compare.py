"""(b) Gemini boxes -> Core /api/masks (SAM 2.1 box prompts + depth) vs (c) Gemini points -> SAM point
prompts vs box+points, all with depth sky + guided-filter edges. One target call per model per image.

usage: seg_compare.py img-1016.jpg [model=argon]
"""
from __future__ import annotations

import asyncio
import json
import sys
import time

import numpy as np
from PIL import ImageDraw

from common import OUT, ask, depth_http, grid, labeled, load_jpeg, masks_http, overlay, to_pil, work_image
import local_edits as le


async def targets_for(name: str, model: str) -> dict:
    jpg = load_jpeg(name, 1024)
    r = await ask(f"gemini-4-{model}", [jpg, le.TARGETS_PROMPT.format(labels=", ".join(le.DEFAULT_LABELS))],
                  schema=le.TARGETS_SCHEMA, thinking="low", media="high", tag="targets")
    d = r["data"] or {"targets": [], "subject": []}
    remap = {}
    for i, t in enumerate(d["targets"]):  # ids from the model are free-form; renumber
        remap[str(t.get("id"))] = t["id"] = f"t{i + 1}"
    d["subject"] = [remap[str(i)] for i in d.get("subject") or [] if str(i) in remap]
    return d | {"ms": r["ms"], "cached": r["cached"], "usage": r.get("usage")}


def draw_targets(img, targets):
    im = labeled(img, "Gemini boxes + points")
    d = ImageDraw.Draw(im)
    W, H = im.size
    for i, t in enumerate(targets):
        c = tuple(int(x) for x in (np.array([255, 64, 64, 64, 160, 255, 64, 220, 96, 255, 200, 0]
                                            ).reshape(4, 3)[i % 4]))
        x0, y0, x1, y1 = le._box_norm(t)
        d.rectangle([x0 * W, y0 * H, x1 * W, y1 * H], outline=c, width=2)
        d.text((x0 * W + 3, y0 * H + 2), f"{t['kind']}:{t['label'][:18]}", fill=c)
        for p in t.get("points") or []:
            x, y = p[1] / 1000 * W, p[0] / 1000 * H
            d.ellipse([x - 5, y - 5, x + 5, y + 5], fill=c, outline="white")
        for p in t.get("neg_points") or []:
            x, y = p[1] / 1000 * W, p[0] / 1000 * H
            d.rectangle([x - 5, y - 5, x + 5, y + 5], fill="black", outline=c)
    return im


def panels(img, res, title):
    a = {}
    b = {}
    for name, r in res.items():
        if name.startswith("t") and name[1:].isdigit():
            if r["kind"] == "face" or r["kind"] == "distraction":
                b[f"{name}:{r['label'][:14]}"] = r["mask"]
            else:
                a[f"{name}:{r['kind'][:4]}:{r['label'][:12]}"] = r["mask"]
    if "subject" in res:
        b["subject"] = res["subject"]["mask"] * 0.6
    return [overlay(img, a, title + " | instances"), overlay(img, b, title + " | faces, distraction, subject")]


async def run(name: str, model: str):
    jpg = load_jpeg(name)
    pil = to_pil(jpg)
    img = work_image(jpg)
    h, w = img.shape[:2]
    found = await targets_for(name, model)
    targets = found["targets"]
    L = le.depth_to_log(depth_http(jpg), (h, w))
    stats = {"image": name, "model": model, "gemini_ms": found["ms"], "cached": found["cached"],
             "n_targets": len(targets), "kinds": [t["kind"] for t in targets]}
    rows = [draw_targets(img, targets)]
    variants = {}
    # (b) production path over HTTP
    regions = [{"id": t["id"], "box": dict(zip("xy", le._box_norm(t)[:2]),
                                            w=le._box_norm(t)[2] - le._box_norm(t)[0],
                                            h=le._box_norm(t)[3] - le._box_norm(t)[1]),
                "tag": "focus", "note": t["label"]} for t in targets]
    soft, meta = masks_http(jpg, regions)
    inst = {k: v > 0.5 for k, v in soft.items()}
    stats["b_sam_ms"] = meta["ms"]
    variants["b box (/api/masks)"] = inst
    import segment  # noqa: F401  (loads SAM in this process for the point variants)
    for mode in ("points", "box+points"):
        inst, ms = le.sam_targets(pil, targets, mode, (h, w))
        stats[f"{mode}_sam_ms"] = ms
        variants[mode] = inst
    out_res = {}
    for vname, inst in variants.items():
        t0 = time.perf_counter()
        res = le.compose(img, targets, found.get("subject") or [], inst, L)
        stats[f"{vname[:6]}_refine_ms"] = int((time.perf_counter() - t0) * 1000)
        rows += panels(img, res, vname)
        out_res[vname] = res
    Ln = (L - L.min()) / max(1e-6, float(L.max() - L.min()))
    rows.insert(1, labeled(np.repeat(Ln[..., None], 3, -1), "Depth Pro log depth"))
    stem = name.rsplit(".", 1)[0]
    p = grid(rows, 2, OUT / f"b_compare_{stem}_{model}.jpg", width=2000)
    with open(OUT / "b_compare.jsonl", "a") as fh:
        fh.write(json.dumps(stats) + "\n")
    print(json.dumps(stats))
    print(p)
    np.savez_compressed(OUT / "cache" / f"masks_{stem}_{model}.npz",
                        **{n: r["mask"] for n, r in out_res["box+points"].items()})
    (OUT / "cache" / f"masks_{stem}_{model}.json").write_text(json.dumps(
        {n: {k: v for k, v in r.items() if k != "mask"} | {"area": float(r["mask"].mean())}
         for n, r in out_res["box+points"].items()}))


if __name__ == "__main__":
    asyncio.run(run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "argon"))
