"""Shared helpers for the masks experiment: images, cached Gemini calls, Core HTTP, overlays.

Imports server/gemini.py read-only. Every real Gemini call is appended to out/calls.jsonl and
cached in out/cache/ (keyed by model + prompt + image), so re-runs cost nothing.
"""
from __future__ import annotations

import base64
import hashlib
import io
import json
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "server"))
sys.path.insert(0, str(HERE))

from dotenv import load_dotenv  # noqa: E402

load_dotenv(ROOT / ".env")

import gemini  # noqa: E402
import httpx  # noqa: E402

OUT = HERE / "out"
CACHE = OUT / "cache"
OUT.mkdir(exist_ok=True)
CACHE.mkdir(exist_ok=True)
SAMPLES = ROOT / "web" / "public" / "samples"
CORE = "http://127.0.0.1:8787"
MASK_LONG = 1024

PALETTE = [(255, 64, 64), (64, 160, 255), (64, 220, 96), (255, 200, 0), (220, 64, 255),
           (0, 230, 230), (255, 128, 0), (160, 255, 64), (255, 96, 180), (128, 128, 255)]


# ---------------------------------------------------------------- images

def load_jpeg(name: str, long_side: int = 1536) -> bytes:
    """Normalize like the browser: EXIF-rotated, long side <= 1536, JPEG."""
    p = SAMPLES / name if not str(name).startswith("/") else Path(name)
    im = ImageOps.exif_transpose(Image.open(p)).convert("RGB")
    s = min(1.0, long_side / max(im.size))
    if s < 1:
        im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=90)
    return buf.getvalue()


def to_pil(jpeg: bytes) -> Image.Image:
    return Image.open(io.BytesIO(jpeg)).convert("RGB")


def mask_size(w: int, h: int, long_side: int = MASK_LONG) -> tuple[int, int]:
    s = min(1.0, long_side / max(w, h))
    return round(w * s), round(h * s)


def work_image(jpeg: bytes) -> np.ndarray:
    """RGB float32 0..1 at mask size (long side 1024)."""
    im = to_pil(jpeg)
    mw, mh = mask_size(*im.size)
    return np.asarray(im.resize((mw, mh), Image.LANCZOS), np.float32) / 255.0


# ---------------------------------------------------------------- Gemini (cached)

def _key(*parts) -> str:
    h = hashlib.sha1()
    for p in parts:
        h.update(p if isinstance(p, bytes) else json.dumps(p, sort_keys=True, default=str).encode())
    return h.hexdigest()[:16]


async def ask(model: str, parts: list, *, schema=None, thinking="low", media="high", tag="exp",
              timeout=150.0, cache=True, gen_extra: dict | None = None, system: str | None = None) -> dict:
    """Returns {text, data, ms, usage, cached}. parts: str or bytes (JPEG)."""
    k = _key(model, [p if isinstance(p, str) else hashlib.sha1(p).hexdigest() for p in parts],
             schema, thinking, media, gen_extra, system)
    f = CACHE / f"{tag}-{model}-{k}.json"
    if cache and f.exists():
        d = json.loads(f.read_text())
        d["cached"] = True
        return d
    t0 = time.perf_counter()
    err = None
    try:
        r = await gemini.generate(model, [gemini.image_part(p) if isinstance(p, bytes) else p for p in parts],
                                  schema=schema, thinking=thinking, media_resolution=media, tag=tag,
                                  timeout=timeout, generation_config=gen_extra, system=system)
        d = {"text": r.text, "data": r.data, "ms": r.ms, "usage": r.usage, "finish": r.finish}
    except Exception as exc:  # keep going: record the failure
        err = f"{type(exc).__name__}: {exc}"[:400]
        d = {"text": "", "data": None, "ms": int((time.perf_counter() - t0) * 1000), "error": err}
    with open(OUT / "calls.jsonl", "a") as fh:
        fh.write(json.dumps({"t": time.time(), "model": model, "tag": tag, "ms": d["ms"],
                             "usage": d.get("usage"), "error": err}) + "\n")
    if not err:
        f.write_text(json.dumps(d))
    d["cached"] = False
    return d


def calls_used() -> int:
    p = OUT / "calls.jsonl"
    return sum(1 for _ in open(p)) if p.exists() else 0


def parse_json_loose(text: str):
    t = text.strip()
    if t.startswith("```"):
        t = t.split("\n", 1)[1].rsplit("```", 1)[0]
    return json.loads(t)


# ---------------------------------------------------------------- Core over HTTP

def depth_http(jpeg: bytes) -> np.ndarray:
    """Depth Pro metric depth (m) via the running Core, cached on disk."""
    f = CACHE / f"depth-{hashlib.sha1(jpeg).hexdigest()[:16]}.npy"
    if f.exists():
        return np.load(f)
    r = httpx.post(f"{CORE}/api/depth", files={"image": ("i.jpg", jpeg, "image/jpeg")}, timeout=120)
    r.raise_for_status()
    w, h = int(r.headers["X-Depth-Width"]), int(r.headers["X-Depth-Height"])
    d = np.frombuffer(r.content, "<f4").reshape(h, w).copy()
    np.save(f, d)
    return d


def masks_http(jpeg: bytes, regions: list[dict]) -> tuple[dict, dict]:
    """Core /api/masks (SAM 2.1 box prompts + depth refinement). -> ({id: float mask}, meta)."""
    t0 = time.perf_counter()
    r = httpx.post(f"{CORE}/api/masks", files={"image": ("i.jpg", jpeg, "image/jpeg")},
                   data={"regions": json.dumps(regions)}, timeout=180)
    r.raise_for_status()
    j = r.json()
    out = {rid: decode_png(m["png"]) for rid, m in j["masks"].items()}
    return out, {"ms": int((time.perf_counter() - t0) * 1000), "server_ms": j.get("ms"),
                 "sources": {k: v["source"] for k, v in j["masks"].items()}}


def decode_png(data: str, size: tuple[int, int] | None = None) -> np.ndarray:
    if "," in data[:64]:
        data = data.split(",", 1)[1]
    im = Image.open(io.BytesIO(base64.b64decode(data))).convert("L")
    if size and im.size != size:
        im = im.resize(size, Image.BILINEAR)
    return np.asarray(im, np.float32) / 255.0


def resize_mask(m: np.ndarray, size: tuple[int, int]) -> np.ndarray:
    if (m.shape[1], m.shape[0]) == size:
        return m
    return np.asarray(Image.fromarray((np.clip(m, 0, 1) * 255).astype(np.uint8)).resize(size, Image.BILINEAR),
                      np.float32) / 255.0


# ---------------------------------------------------------------- drawing

def _font(sz=16):
    for p in ("/System/Library/Fonts/Supplemental/Arial.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(p, sz)
        except OSError:
            pass
    return ImageFont.load_default()


def overlay(img: np.ndarray, masks: dict[str, np.ndarray], title: str = "", alpha=0.45) -> Image.Image:
    """Colored fill + outline + label per mask over an RGB float image."""
    base = img.copy()
    h, w = base.shape[:2]
    outline = np.zeros((h, w, 3), np.float32)
    edge_any = np.zeros((h, w), bool)
    for i, (lab, m) in enumerate(masks.items()):
        m = resize_mask(m, (w, h))
        c = np.array(PALETTE[i % len(PALETTE)], np.float32) / 255
        base = base * (1 - alpha * m[..., None]) + c * alpha * m[..., None]
        b = m > 0.5
        e = b ^ np.pad(b, 1, mode="edge")[2:, 1:-1] | b ^ np.pad(b, 1, mode="edge")[1:-1, 2:]
        outline[e] = c
        edge_any |= e
    base[edge_any] = outline[edge_any]
    im = Image.fromarray((np.clip(base, 0, 1) * 255).astype(np.uint8))
    d = ImageDraw.Draw(im)
    f = _font(15)
    y = 4
    if title:
        d.rectangle([0, 0, w, 22], fill=(0, 0, 0))
        d.text((6, 3), title, fill="white", font=f)
        y = 26
    for i, lab in enumerate(masks):
        m = resize_mask(masks[lab], (w, h))
        ys, xs = np.nonzero(m > 0.5)
        c = PALETTE[i % len(PALETTE)]
        if len(xs):
            x0, y0 = int(np.median(xs)), int(np.median(ys))
            d.rectangle([x0 - 2, y0 - 2, x0 + 8 * len(lab) + 4, y0 + 18], fill=(0, 0, 0))
            d.text((x0 + 2, y0), lab, fill=c, font=f)
        else:
            d.text((6, y), f"{lab}: EMPTY", fill=c, font=f)
            y += 18
    return im


def grid(ims: list[Image.Image], cols: int, path: Path, width: int = 2400, quality=82) -> Path:
    cw = width // cols
    ims = [im.resize((cw, round(im.height * cw / im.width))) for im in ims]
    rows = [ims[i:i + cols] for i in range(0, len(ims), cols)]
    H = sum(max(im.height for im in r) for r in rows)
    sheet = Image.new("RGB", (cw * cols, H), (30, 30, 30))
    y = 0
    for r in rows:
        for j, im in enumerate(r):
            sheet.paste(im, (j * cw, y))
        y += max(im.height for im in r)
    sheet.save(path, quality=quality)
    return path


def labeled(img: np.ndarray | Image.Image, text: str) -> Image.Image:
    im = img if isinstance(img, Image.Image) else Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8))
    im = im.copy()
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, im.width, 24], fill=(0, 0, 0))
    d.text((6, 3), text, fill="white", font=_font(16))
    return im
