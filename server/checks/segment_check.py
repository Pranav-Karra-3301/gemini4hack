"""Check segment.py on sample photos.

Usage (from server/):  uv run --no-sync python checks/segment_check.py <img>... [--no-depth-cache]

For each image: normalize like the browser (EXIF-rotate, long side 1536, JPEG) and save it to
../out/norm_<stem>.jpg; get regions from ../out/regions_<stem>.json or ONE Argon call (cached
there); run segment_regions twice (cold, warm); write ../out/mask_<stem>.jpg (everything outside
all masks at ~15%, each mask tinted by tag: focus amber, remove red, numbered by note) and print
per-region area/source plus timing.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import io
import json
import sys
import time
from pathlib import Path

import numpy as np
from dotenv import load_dotenv
from PIL import Image, ImageDraw, ImageFont, ImageOps
from scipy import ndimage as ndi

SERVER = Path(__file__).resolve().parent.parent
ROOT = SERVER.parent
sys.path.insert(0, str(SERVER))
load_dotenv(ROOT / ".env")

import segment  # noqa: E402

OUT = ROOT / "out"
BROWSER_LONG = 1536
TINT = {"focus": (255, 176, 0), "remove": (255, 50, 50)}
DARK = 0.15


def font(size: int):
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def normalize(path: Path) -> bytes:
    img = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    s = min(1.0, BROWSER_LONG / max(img.size))
    if s < 1.0:
        img = img.resize((round(img.width * s), round(img.height * s)), Image.Resampling.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=90)
    return buf.getvalue()


def get_regions(stem: str, jpeg: bytes) -> list[dict]:
    cache = OUT / f"regions_{stem}.json"
    if cache.exists():
        data = json.loads(cache.read_text())
        return data["regions"] if isinstance(data, dict) else data
    import regions

    t0 = time.perf_counter()
    data = asyncio.run(regions.find_regions(jpeg, "image/jpeg"))
    cost = sum(float(u.get("cost") or 0) for u in regions.last_debug.get("usage", []))
    print(f"   argon call: {time.perf_counter() - t0:.1f}s cost=${cost:.4f} "
          f"labels={regions.last_debug.get('labels')}")
    data["labels"] = regions.last_debug.get("labels")
    cache.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    return data["regions"]


def decode_mask(url: str) -> np.ndarray:
    raw = base64.b64decode(url.split(",", 1)[1])
    return np.asarray(Image.open(io.BytesIO(raw)), dtype=np.float32) / 255.0


def draw(stem: str, jpeg: bytes, regs: list[dict], result: dict) -> Path:
    first = next(iter(result["masks"].values()))
    w, h = first["width"], first["height"]
    img = np.asarray(Image.open(io.BytesIO(jpeg)).convert("RGB").resize((w, h)), np.float32)
    lit = np.zeros((h, w), np.float32)
    tint = np.zeros((h, w, 3), np.float32)
    outlines = []
    for i, r in enumerate(regs, 1):
        m = decode_mask(result["masks"][r["id"]]["png"])
        c = np.array(TINT.get(r.get("tag"), (80, 160, 255)), np.float32)
        tint += m[..., None] * c * (1.0 - lit[..., None])
        lit = np.maximum(lit, m)
        hard = m > 0.5
        edge = hard & ~ndi.binary_erosion(hard, iterations=2)
        outlines.append((i, r, edge, c, hard))
    base = img * (DARK + (1 - DARK) * lit[..., None])
    base = base * (1 - 0.35 * lit[..., None]) + 0.35 * tint
    for _i, _r, edge, c, _hard in outlines:
        base[edge] = c
    canvas = Image.fromarray(np.clip(base, 0, 255).astype(np.uint8))
    d = ImageDraw.Draw(canvas)
    f = font(22)
    for i, r, _edge, c, hard in outlines:
        b = r["box"]
        x0, y0, x1, y1 = b["x"] * w, b["y"] * h, (b["x"] + b["w"]) * w, (b["y"] + b["h"]) * h
        col = tuple(int(v) for v in c)
        for k in range(0, int(x1 - x0), 12):  # dashed prompt box
            d.line([x0 + k, y0, min(x1, x0 + k + 6), y0], fill=col, width=1)
            d.line([x0 + k, y1, min(x1, x0 + k + 6), y1], fill=col, width=1)
        for k in range(0, int(y1 - y0), 12):
            d.line([x0, y0 + k, x0, min(y1, y0 + k + 6)], fill=col, width=1)
            d.line([x1, y0 + k, x1, min(y1, y0 + k + 6)], fill=col, width=1)
        if hard.any():
            cy, cx = ndi.center_of_mass(hard)
        else:
            cy, cx = (y0 + y1) / 2, (x0 + x1) / 2
        d.ellipse([cx - 15, cy - 15, cx + 15, cy + 15], fill=(0, 0, 0), outline=col, width=2)
        d.text((cx, cy), str(i), fill=col, font=f, anchor="mm")
    foot = 26 * len(regs) + 10
    out = Image.new("RGB", (w, h + foot), (18, 18, 18))
    out.paste(canvas, (0, 0))
    d = ImageDraw.Draw(out)
    for i, r in enumerate(regs, 1):
        m = result["masks"][r["id"]]
        d.text((10, h + 6 + 26 * (i - 1)),
               f"{i} [{r.get('tag')}] {m['source']} area={m['area']:.3f}  {r.get('note', '')}",
               fill=TINT.get(r.get("tag"), (200, 200, 200)), font=font(18))
    path = OUT / f"mask_{stem}.jpg"
    out.save(path, quality=88)
    return path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("images", nargs="+", type=Path)
    ap.add_argument("-v", "--verbose", action="store_true", help="print candidate metrics")
    args = ap.parse_args()
    OUT.mkdir(exist_ok=True)
    t0 = time.perf_counter()
    segment.warmup()
    print(f"warmup {segment.MODEL_ID} on {segment._device}/{segment._precision}: "
          f"{time.perf_counter() - t0:.1f}s")
    for path in args.images:
        stem = path.stem
        jpeg = normalize(path)
        (OUT / f"norm_{stem}.jpg").write_bytes(jpeg)
        print(f"== {path.name}")
        regs = get_regions(stem, jpeg)
        cold = segment.segment_regions(jpeg, regs)
        tc = dict(segment.last_debug["timing"])
        warm = segment.segment_regions(jpeg, regs)  # depth now cached, SAM warm
        dbg = segment.last_debug
        print(f"   ms cold={cold['ms']} {tc}  warm={warm['ms']} {dbg['timing']}  "
              f"model={warm['model']}" + (f"  sam_error={dbg['sam_error']}" if dbg["sam_error"] else ""))
        for i, r in enumerate(regs, 1):
            m = warm["masks"][r["id"]]
            rd = dbg["regions"].get(r["id"], {})
            dep = rd.get("depth", {})
            dtxt = (f"depth cut {dep.get('cut_frac')}" if dep.get("applied")
                    else f"depth kept (leaks={len(dep.get('leaks', []))}"
                         f"{' skipped' if dep.get('skipped') else ''})" if dep else "")
            grp = rd.get("group") or {}
            gtxt = f" +{grp['added']} group" if grp.get("added") else ""
            print(f"   {i} {r['id']} {r.get('tag'):6s} area={m['area']:.4f} src={m['source']:13s} "
                  f"cand={rd.get('chosen')}{gtxt} {dtxt}  | {r.get('note', '')[:60]}")
            if args.verbose:
                for c in rd.get("cands", []):
                    print(f"        {c}")
                if dep:
                    print(f"        depth {dep}")
                if rd.get("group"):
                    print(f"        group {rd['group']}")
        print(f"   wrote {draw(stem, jpeg, regs, warm)}")


if __name__ == "__main__":
    main()
