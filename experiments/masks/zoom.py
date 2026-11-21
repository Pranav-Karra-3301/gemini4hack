"""Halo check: re-render a saved plan and show 2x crops (before | after | |after-before| x4).

usage: zoom.py img-2178.jpg plan_json_name x0,y0,x1,y1 [masks_from=hydrogen]
"""
from __future__ import annotations

import json
import sys

import numpy as np
from PIL import Image

from common import CACHE, OUT, depth_http, grid, labeled, load_jpeg, work_image
import local_edits as le
from plan_edits import load_masks
from render import render

name, plan_name, box = sys.argv[1], sys.argv[2], [float(v) for v in sys.argv[3].split(",")]
src = sys.argv[4] if len(sys.argv) > 4 else "hydrogen"
stem = name.rsplit(".", 1)[0]
masks, _ = load_masks(stem, src)
plan = json.loads((CACHE / plan_name).read_text())
jpg = load_jpeg(name)
img = work_image(jpg)
h, w = img.shape[:2]
L = le.depth_to_log(depth_http(jpg), (h, w))
Ln = (L - L.min()) / max(1e-6, float(L.max() - L.min()))
after = render(img, plan, masks, Ln)
x0, y0, x1, y1 = int(box[0] * w), int(box[1] * h), int(box[2] * w), int(box[3] * h)
crops = [img[y0:y1, x0:x1], after[y0:y1, x0:x1],
         np.clip(np.abs(after - img)[y0:y1, x0:x1] * 4, 0, 1)]
ims = [labeled(Image.fromarray((c * 255).astype(np.uint8)).resize(((x1 - x0) * 2, (y1 - y0) * 2), Image.LANCZOS), t)
       for c, t in zip(crops, ["before", "after", "|diff| x4"])]
p = grid(ims, 3, OUT / f"zoom_{stem}_{plan_name.rsplit('.', 1)[0][5:]}.jpg", width=2100)
print(p)
