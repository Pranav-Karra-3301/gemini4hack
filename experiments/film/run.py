"""Experiment runner. Every Gemini reply is cached in cache/ so re-renders cost nothing.

uv run --no-sync python ../experiments/film/run.py looks  --tag v1 [--variants fit,bold,generic] [--model neon]
uv run --no-sync python ../experiments/film/run.py render --tag v1
uv run --no-sync python ../experiments/film/run.py shader --tag v1
uv run --no-sync python ../experiments/film/run.py contact --tag v1
"""
from __future__ import annotations

import argparse
import asyncio
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import film  # noqa: E402

SAMPLES = ["img-1016", "img-1216", "img-1408", "img-1931", "img-2178"]
SRC = HERE.parents[1] / "web/public/samples"
OUT, CACHE, WORK, LUTS = HERE / "out", HERE / "cache", HERE / "out/work", HERE / "out/luts"
for d in (OUT, CACHE, WORK, LUTS):
    d.mkdir(parents=True, exist_ok=True)
MODELS = {"neon": film.NEON, "hydrogen": film.HYDROGEN}
CALLS = CACHE / "calls.jsonl"   # one line per real Gemini call (for the budget + latency stats)


def log_call(kind: str, sample: str, meta: dict, ok: bool = True, **kw) -> None:
    with CALLS.open("a") as f:
        f.write(json.dumps({"kind": kind, "sample": sample, "ok": ok, **meta, **kw}) + "\n")


def work_image(s: str) -> Path:
    p = WORK / f"{s}.jpg"
    if not p.exists():
        im = Image.open(SRC / f"{s}.jpg").convert("RGB")
        im.thumbnail((1024, 1024), Image.LANCZOS)
        im.save(p, quality=92)
    return p


async def looks(tag: str, variants: list[str], model: str, samples: list[str]) -> None:
    sem = asyncio.Semaphore(5)

    async def one(s, v):
        p = CACHE / f"{s}_{v}_{model}_{tag}.json"
        if p.exists():
            return
        async with sem:
            try:
                spec = await film.design_look((SRC / f"{s}.jpg").read_bytes(), v, MODELS[model])
            except Exception as e:  # noqa: BLE001
                log_call("look", s, {"model": model, "variant": v, "tag": tag}, ok=False, error=str(e)[:300])
                print("FAIL", s, v, e)
                return
        p.write_text(json.dumps(spec, indent=1))
        log_call("look", s, {**spec["_meta"], "tag": tag})
        print(f"{s} {v:8s} {spec['_meta']['ms']:6d} ms  {spec.get('name')} | {spec.get('evokes')}")
    await asyncio.gather(*(one(s, v) for s in samples for v in variants))


def render_all(tag: str, model: str, variants: list[str], samples: list[str]) -> None:
    for s in samples:
        im = Image.open(work_image(s))
        for v in variants:
            p = CACHE / f"{s}_{v}_{model}_{tag}.json"
            if not p.exists():
                continue
            spec = json.loads(p.read_text())
            sp = {**film.sanitize(spec), "_sanitized": True}
            lut = film.compile_lut(sp)
            name = f"{s}_{v}" + ("" if model == "neon" else f"_{model}") + f"_{tag}"
            film.render(im, lut, film.effects_of(sp)).save(OUT / f"{name}.jpg", quality=90)
            film.write_cube(lut, LUTS / f"{name}.cube", spec.get("name", v))
            (LUTS / f"{name}.effects.json").write_text(json.dumps(film.effects_of(sp), indent=1))
            print(name, "|", spec.get("name"), "|", spec.get("rationale"))


async def shader(tag: str, samples: list[str], model: str, rounds: int = 2) -> None:
    async def one(s):
        hist, attempts = [], []
        img = work_image(s)
        for k in range(rounds + 1):
            p = CACHE / f"{s}_shader_{model}_{tag}_a{k}.json"
            if p.exists():
                r = json.loads(p.read_text())
            else:
                try:
                    r = await film.design_shader((SRC / f"{s}.jpg").read_bytes(), MODELS[model], hist)
                except Exception as e:  # noqa: BLE001
                    log_call("shader", s, {"model": model, "tag": tag, "attempt": k}, ok=False, error=str(e)[:300])
                    attempts.append({"attempt": k, "ok": False, "stage": "api", "log": str(e)[:300]})
                    break
                p.write_text(json.dumps(r, indent=1))
                log_call("shader", s, {**r["_meta"], "tag": tag, "attempt": k})
            out = OUT / f"{s}_shader_{tag}.jpg"
            jobs = CACHE / f"jobs_{s}.json"
            res = CACHE / f"res_{s}.json"
            jobs.write_text(json.dumps([{"id": s, "image": str(img), "glsl": r["glsl"], "out": str(out)}]))
            await asyncio.to_thread(subprocess.run, ["/opt/homebrew/bin/node", str(HERE / "shader_harness.js"),
                                                     str(jobs), str(res)], check=True, timeout=120)
            rr = json.loads(res.read_text())[0]
            attempts.append({"attempt": k, "ok": rr["ok"], "stage": rr["stage"], "log": rr.get("log", ""),
                             "ms": r["_meta"]["ms"], "name": r.get("name"), "rationale": r.get("rationale"),
                             "gpu_ms": rr.get("ms")})
            print(s, "attempt", k, rr["ok"], rr["stage"], (rr.get("log") or "")[:160].replace("\n", " "))
            if rr["ok"]:
                break
            hist.append((r["glsl"], rr.get("log", "")))
        return s, attempts
    results = dict(await asyncio.gather(*(one(s) for s in samples)))
    (OUT / f"shader_results_{tag}.json").write_text(json.dumps(results, indent=1))


def contact(tag: str, cols: list[tuple[str, str]], name: str = "contact.jpg", cell: int = 420,
            heads: dict | None = None) -> None:
    rows = []
    for s in SAMPLES:
        row = []
        for label, pat in cols:
            p = WORK / f"{s}.jpg" if pat == "orig" else OUT / pat.format(s=s, tag=tag)
            row.append((label, Image.open(p) if p.exists() else None))
        rows.append((s, row))
    ims = [im for _, r in rows for _, im in r if im]
    hmax = max(int(cell * im.height / im.width) if im.width >= im.height else cell for im in ims)
    pad, head = 8, 22
    W = len(cols) * (cell + pad) + pad
    H = len(rows) * (hmax + head + pad) + pad
    sheet = Image.new("RGB", (W, H), (24, 24, 24))
    d = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 15)
    except OSError:
        font = ImageFont.load_default()
    for ri, (s, row) in enumerate(rows):
        y = pad + ri * (hmax + head + pad)
        for ci, (label, im) in enumerate(row):
            x = pad + ci * (cell + pad)
            d.text((x, y + 2), (heads or {}).get((s, label), f"{s} · {label}") if label != "original" else s,
                   fill=(220, 220, 220), font=font)
            if im is None:
                d.text((x + 10, y + head + 20), "(missing)", fill=(200, 80, 80), font=font)
                continue
            t = im.copy()
            t.thumbnail((cell, hmax), Image.LANCZOS)
            sheet.paste(t, (x + (cell - t.width) // 2, y + head))
    sheet.save(OUT / name, quality=88)
    print("wrote", OUT / name, sheet.size)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd")
    ap.add_argument("--tag", default="v1")
    ap.add_argument("--model", default="neon")
    ap.add_argument("--variants", default="generic,fit,bold")
    ap.add_argument("--samples", default=",".join(SAMPLES))
    a = ap.parse_args()
    vs, ss = a.variants.split(","), a.samples.split(",")
    if a.cmd == "looks":
        asyncio.run(looks(a.tag, vs, a.model, ss))
    elif a.cmd == "render":
        render_all(a.tag, a.model, vs, ss)
    elif a.cmd == "shader":
        asyncio.run(shader(a.tag, ss, a.model))
    elif a.cmd == "final":
        # Final picks: generic = v2 (fixed Portra prompt), fit/bold = v3 (Neon), shader = v2 batch.
        import shutil
        picks = {"generic": "v2", "fit": "v3", "bold": "v3"}
        heads = {}
        for s in SAMPLES:
            for v, t in picks.items():
                spec = json.loads((CACHE / f"{s}_{v}_neon_{t}.json").read_text())
                shutil.copy(OUT / f"{s}_{v}_{t}.jpg", OUT / f"{s}_{v}.jpg")
                shutil.copy(LUTS / f"{s}_{v}_{t}.cube", LUTS / f"{s}_{v}.cube")
                shutil.copy(LUTS / f"{s}_{v}_{t}.effects.json", LUTS / f"{s}_{v}.effects.json")
                (LUTS / f"{s}_{v}.spec.json").write_text(json.dumps(spec, indent=1))
                heads[(s, v)] = f"{v}: {spec.get('name')}"
            shutil.copy(OUT / f"{s}_shader_v2.jpg", OUT / f"{s}_shader.jpg")
            sr = json.loads((OUT / "shader_results_v2.json").read_text())[s][-1]
            heads[(s, "shader")] = f"shader: {sr.get('name')}"
        contact("final", [("original", "orig"), ("generic", "{s}_generic.jpg"), ("fit", "{s}_fit.jpg"),
                          ("bold", "{s}_bold.jpg"), ("shader", "{s}_shader.jpg")], name="contact.jpg", heads=heads)
    elif a.cmd == "contact":
        contact(a.tag, [("original", "orig"), ("generic", "{s}_generic_{tag}.jpg"), ("fit", "{s}_fit_{tag}.jpg"),
                        ("bold", "{s}_bold_{tag}.jpg"), ("shader", "{s}_shader_{tag}.jpg")],
                name=f"contact_{a.tag}.jpg")
