"""Step 2+3: Gemini plans global + masked layers for a goal; render before/after through the masks.

usage: plan_edits.py img-1016.jpg "make it golden hour" [models=hydrogen,neon] [masks_from=hydrogen] [v=1]
Needs out/cache/masks_<stem>_<masks_from>.npz from seg_compare.py.
"""
from __future__ import annotations

import asyncio
import json
import re
import sys
import textwrap

import numpy as np
from PIL import Image, ImageDraw

from common import CACHE, OUT, _font, ask, depth_http, labeled, load_jpeg, work_image
import local_edits as le
from render import render


def load_masks(stem: str, src: str):
    z = np.load(CACHE / f"masks_{stem}_{src}.npz")
    meta = json.loads((CACHE / f"masks_{stem}_{src}.json").read_text())
    return {k: z[k] for k in z.files}, meta


async def plan(name: str, goal: str, model: str, meta: dict, version: str):
    jpg = load_jpeg(name, 1024)
    text = (f"Goal: {goal}\nCurrent global values: {{}}\n"
            f"Masks you can use:\n{le._mask_list(meta)}\nPlan the edit.")
    r = await ask(f"gemini-4-{model}", [jpg, text], schema=le.PLAN_SCHEMA, system=le.PLAN_SYSTEM,
                  thinking="low", media="medium", tag=f"plan{version}")
    if r.get("data") is None:
        return None, r
    return le.normalize_plan(r["data"], meta), r


def text_panel(p: dict, width: int, title: str) -> Image.Image:
    lines = [title, p.get("summary", ""), f"GLOBAL {json.dumps(p['values'])}", f"  why: {p.get('global_why', '')}"]
    for l in p["layers"]:
        m = l["mask"]
        msk = m["source"] + (" (inverted)" if m["invert"] else "") + \
            (f" - {','.join(m['subtract'])}" if m["subtract"] else "") + f" feather {m['feather']:.0f} {m['edge']}"
        lines.append(f"{l['id']} [{l['target']}] mask={msk}  {json.dumps(l['values'])}")
        lines.append(f"  why: {l['why']}")
    f = _font(15)
    wrapped = []
    for ln in lines:
        wrapped += textwrap.wrap(ln, width=int(width / 8.2)) or [""]
    im = Image.new("RGB", (width, 22 * len(wrapped) + 12), (20, 20, 20))
    d = ImageDraw.Draw(im)
    for i, ln in enumerate(wrapped):
        d.text((8, 6 + 22 * i), ln, fill="white" if not ln.startswith("  why") else (190, 220, 255), font=f)
    return im


async def run(name, goal, models, masks_from, version):
    stem = name.rsplit(".", 1)[0]
    masks, meta = load_masks(stem, masks_from)
    jpg = load_jpeg(name)
    img = work_image(jpg)
    h, w = img.shape[:2]
    L = le.depth_to_log(depth_http(jpg), (h, w))
    Ln = (L - L.min()) / max(1e-6, float(L.max() - L.min()))
    res = await asyncio.gather(*[plan(name, goal, m, meta, version) for m in models])
    slug = re.sub(r"[^a-z]+", "-", goal.lower()).strip("-")[:24]
    for m, (p, r) in zip(models, res):
        if p is None:
            print(m, "FAILED", r.get("error"))
            continue
        after = render(img, p, masks, Ln)
        before_im, after_im = labeled(img, f"before  {name}"), labeled(after, f"after: {goal} ({m}, {r['ms']} ms)")
        W = before_im.width * 2
        tp = text_panel(p, W, f"{m}  plan v{version}  ({r['ms']} ms{', cached' if r['cached'] else ''})")
        sheet = Image.new("RGB", (W, before_im.height + tp.height), (0, 0, 0))
        sheet.paste(before_im, (0, 0))
        sheet.paste(after_im, (before_im.width, 0))
        sheet.paste(tp, (0, before_im.height))
        path = OUT / f"edit_{stem}_{slug}_{m}_v{version}.jpg"
        sheet.save(path, quality=85)
        (CACHE / f"plan_{stem}_{slug}_{m}_v{version}.json").write_text(json.dumps(p, indent=1))
        print(path, r["ms"], "cached" if r["cached"] else "")


if __name__ == "__main__":
    a = sys.argv
    asyncio.run(run(a[1], a[2], (a[3] if len(a) > 3 else "hydrogen,neon").split(","),
                    a[4] if len(a) > 4 else "hydrogen", a[5] if len(a) > 5 else "1"))
