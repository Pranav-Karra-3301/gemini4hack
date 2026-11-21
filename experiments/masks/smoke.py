"""End-to-end smoke test of the public API in local_edits.py (2 Gemini calls).

usage: smoke.py img-1931.jpg "warm the faces, cool the sky, darken the distracting sign"
Depth comes from the running Core (/api/depth) so this process only loads SAM.
"""
from __future__ import annotations

import asyncio
import json
import sys
import time

import numpy as np
from PIL import Image

from common import OUT, decode_png, depth_http, grid, labeled, load_jpeg, overlay, work_image
import local_edits as le
from render import render

name, goal = sys.argv[1], sys.argv[2]
jpg = load_jpeg(name)
t0 = time.perf_counter()
res = le.get_semantic_masks(jpg, ["people", "faces", "sky", "water", "ground", "distraction"],
                            depth_m=depth_http(jpg))
print("get_semantic_masks", res["ms"], "ms", res["timing"], sorted(res["masks"]))
plan = asyncio.run(le.plan_local_edits(jpg, res, goal))
print("plan_local_edits", plan["ms"], "ms")
print(json.dumps({k: v for k, v in plan.items() if k != "layers"}, indent=None))
for l in plan["layers"]:
    print(" ", l["id"], l["mask"]["source"], l["values"], "|", l["why"])
img = work_image(jpg)
h, w = img.shape[:2]
masks = {k: decode_png(v["png"], (w, h)) for k, v in res["masks"].items()}
L = le.depth_to_log(depth_http(jpg), (h, w))
after = render(img, plan, masks, (L - L.min()) / (L.max() - L.min()))
show = {k: masks[k] for k in ("faces", "sky", "ground", "distraction", "people") if k in masks}
stem = name.rsplit(".", 1)[0]
p = grid([overlay(img, show, "get_semantic_masks"), labeled(after, f"after: {goal[:60]}")], 2,
         OUT / f"smoke_{stem}.jpg", width=2000)
(OUT / "cache" / f"smoke_{stem}.json").write_text(json.dumps(
    {"plan": plan, "masks": {k: {kk: vv for kk, vv in v.items() if kk != "png"} for k, v in res["masks"].items()}},
    indent=1))
print(p, f"total {int((time.perf_counter() - t0) * 1000)} ms")
