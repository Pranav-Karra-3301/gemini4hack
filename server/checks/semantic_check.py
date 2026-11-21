"""Semantic masks + local edit plans (docs/CORE_API.md §7) against a running private Core.

Usage:
  cd server && COACH_WARMUP=0 COACH_LIBRARY=/tmp/lc_sem_lib \
      uv run --no-sync uvicorn app:app --host 127.0.0.1 --port 8799
  cd server && uv run --no-sync python checks/semantic_check.py [--base http://127.0.0.1:8799]
      [--images img-2178.jpg img-1408.jpg] [--goals "make them pop" "golden hour"]

Per sample: reuse the shot an earlier run uploaded (meta.check == "semantic_check") or POST
/api/shots; POST /api/shots/{id}/semantic (cold), again (cached), POST /api/semantic-masks with the
shot's image.jpg (targets cache hit: no Gemini call); POST /api/shots/{id}/edit/local per goal;
validates the shapes and ranges, saves /tmp/lc_qa/sem_<sample>_masks.jpg (overlays) and
sem_<sample>_<goal>.jpg (before | after | layer masks; experiments/masks/render.py's numpy render,
which only approximates Core Image) and prints timings and Core's Gemini call counts.
Gemini calls: a new shot's own pipeline (score, regions, suggest, ...) + 1 targets + 1 per goal.
"""

import argparse
import io
import json
import sys
import time
from pathlib import Path

import httpx
import numpy as np
from PIL import Image

SERVER = Path(__file__).resolve().parent.parent
ROOT = SERVER.parent
SAMPLES = ROOT / "web" / "public" / "samples"
EXP = ROOT / "experiments" / "masks"
OUT = Path("/tmp/lc_qa")
sys.path.insert(0, str(SERVER))
sys.path.insert(0, str(EXP))

import edit  # noqa: E402  (slider ranges)
from common import grid, labeled, overlay  # noqa: E402
from render import layer_alpha, render  # noqa: E402

fails: list[str] = []


def check(ok: bool, msg: str) -> None:
    if not ok:
        fails.append(msg)
        print("  FAIL", msg)


def png_array(data: bytes) -> np.ndarray:
    return np.asarray(Image.open(io.BytesIO(data)).convert("L"), np.float32) / 255.0


def find_or_upload(c: httpx.Client, name: str) -> tuple[str, int]:
    for s in c.get("/api/shots", params={"limit": 200}).json()["shots"]:
        m = s.get("meta") or {}
        if m.get("check") == "semantic_check" and m.get("sample") == name:
            return s["id"], 0
    t = time.perf_counter()
    r = c.post("/api/shots", files={"image": (name, (SAMPLES / name).read_bytes(), "image/jpeg")},
               data={"meta": json.dumps({"source": "check", "check": "semantic_check", "sample": name})})
    r.raise_for_status()
    return r.json()["id"], int((time.perf_counter() - t) * 1000)


def validate_semantic(c: httpx.Client, sid: str, sem: dict) -> dict[str, np.ndarray]:
    masks = sem["masks"]
    check(bool(masks), f"{sid}: no semantic masks")
    ids = {t["id"] for t in sem["targets"]}
    check(set(sem["subject"]) <= ids, f"{sid}: subject ids {sem['subject']} not in targets")
    arrs = {}
    for name, m in masks.items():
        r = c.get(m["url"])
        check(r.status_code == 200, f"{sid}: GET {m['url']} -> {r.status_code}")
        if r.status_code != 200:
            continue
        a = png_array(r.content)
        check(a.shape == (m["height"], m["width"]), f"{sid}: {name} png {a.shape} != {m['height']}x{m['width']}")
        check(abs(float(a.mean()) - m["area"]) < 0.01, f"{sid}: {name} area {m['area']} != {a.mean():.4f}")
        arrs[name] = a
    rec = c.get(f"/api/shots/{sid}").json()
    a = rec["assets"].get("semantic") or {}
    check(a.get("status") == "done", f"{sid}: assets.semantic {a.get('status')}")
    check(set(a.get("urls") or {}) == set(masks), f"{sid}: assets.semantic.urls != semantic.json masks")
    return arrs


def validate_plan(sid: str, goal: str, plan: dict, names: set, current: dict) -> None:
    layers = plan.get("layers") or []
    check(1 <= len(layers) <= 5, f"{sid} {goal!r}: {len(layers)} layers")
    check(len({l["id"] for l in layers}) == len(layers), f"{sid} {goal!r}: duplicate layer ids")
    for l in layers:
        mk = l["mask"]
        check(mk["source"] in names, f"{sid} {goal!r}: layer source {mk['source']} not a mask")
        check(all(s in names for s in mk["subtract"]), f"{sid} {goal!r}: bad subtract {mk['subtract']}")
        check(0 <= mk["feather"] <= 100 and mk["edge"] in ("image", "depth", "none"),
              f"{sid} {goal!r}: feather/edge {mk}")
        check(bool(l["values"]), f"{sid} {goal!r}: empty layer {l['id']}")
        for k, v in l["values"].items():
            lo, hi = edit.SLIDERS[k][:2]
            check(k != "vignette" and lo <= v <= hi, f"{sid} {goal!r}: layer value {k}={v}")
    for k, v in (plan.get("values") or {}).items():
        lo, hi = edit.SLIDERS[k][:2]
        check(lo <= v <= hi, f"{sid} {goal!r}: global {k}={v}")
    gone = [k for k in current if k not in plan["values"]]  # Gemini may set a slider back to 0
    if gone:
        print(f"  note: {goal!r} reset current {gone} to 0")


def depth_log(c: httpx.Client, sid: str, size) -> np.ndarray | None:
    r = c.get(f"/api/shots/{sid}/depth.png")
    if r.status_code != 200:
        return None
    mm = np.asarray(Image.open(io.BytesIO(r.content)), np.float32)
    L = np.log(np.clip(np.where(mm <= 0, 65535, mm) / 1000.0, 0.05, 100.0)).astype(np.float32)
    L = np.asarray(Image.fromarray(L).resize(size, Image.BILINEAR), np.float32)
    return (L - L.min()) / max(1e-6, float(L.max() - L.min()))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8799")
    ap.add_argument("--images", nargs="+", default=["img-2178.jpg", "img-1408.jpg"])
    ap.add_argument("--goals", nargs="*", default=["make them pop", "golden hour"])
    ap.add_argument("--force", action="store_true", help="recompute the shots' semantic masks")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    c = httpx.Client(base_url=args.base, timeout=240)
    before = c.get("/api/stats").json()["totals"]["calls"]
    timings = []

    # input errors (no Gemini calls)
    check(c.post("/api/semantic-masks", files={"image": ("x.jpg", b"", "image/jpeg")}).status_code == 400,
          "empty image not 400")
    check(c.post("/api/semantic-masks", files={"image": ("x.jpg", b"xx", "image/jpeg")},
                 data={"labels": "{bad"}).status_code == 400, "bad labels not 400")
    check(c.post("/api/shots/20990101-000000-0000/semantic").status_code == 404, "unknown shot not 404")

    for name in args.images:
        stem = Path(name).stem
        print(f"== {name}")
        sid, up_ms = find_or_upload(c, name)
        print(f"  shot {sid} (upload {up_ms} ms)" if up_ms else f"  shot {sid} (reused)")
        t = time.perf_counter()
        r = c.post(f"/api/shots/{sid}/semantic", json={"force": args.force})
        cold_ms = int((time.perf_counter() - t) * 1000)
        check(r.status_code == 200, f"{sid}: semantic -> {r.status_code} {r.text[:200]}")
        if r.status_code != 200:
            continue
        sem = r.json()
        print(f"  semantic {cold_ms} ms (cached={sem['cached']}) timing {sem['timing']}")
        print("  targets:", ", ".join(f"{t['id']}={t['kind']}:{t['label']}" for t in sem["targets"]),
              "| subject", sem["subject"])
        print("  masks:", ", ".join(f"{n}({m['source']},{m['area']:.3f})" for n, m in sem["masks"].items()))
        arrs = validate_semantic(c, sid, sem)

        t = time.perf_counter()
        r2 = c.post(f"/api/shots/{sid}/semantic").json()
        warm_ms = int((time.perf_counter() - t) * 1000)
        check(r2.get("cached") is True and warm_ms < 1500, f"{sid}: second semantic not cached ({warm_ms} ms)")

        img_bytes = c.get(f"/api/shots/{sid}/image.jpg").content
        t = time.perf_counter()
        r3 = c.post("/api/semantic-masks", files={"image": ("image.jpg", img_bytes, "image/jpeg")})
        sl_ms = int((time.perf_counter() - t) * 1000)
        check(r3.status_code == 200, f"/api/semantic-masks -> {r3.status_code} {r3.text[:200]}")
        if r3.status_code == 200:
            s3 = r3.json()
            check(s3["cached"] is True, "stateless call missed the targets cache")
            check(set(s3["masks"]) == set(sem["masks"]), "stateless mask names differ from the shot's")
            check(all(m["png"].startswith("data:image/png;base64,") for m in s3["masks"].values()),
                  "stateless png not a data URL")
            print(f"  /api/semantic-masks {sl_ms} ms (targets cached) timing {s3['timing']}")

        im = Image.open(io.BytesIO(img_bytes)).convert("RGB")
        some = next(iter(arrs.values()))
        size = (some.shape[1], some.shape[0])
        img = np.asarray(im.resize(size, Image.LANCZOS), np.float32) / 255.0
        unions = {n: a for n, a in arrs.items() if sem["masks"][n]["source"] == "union" and n != "subject"}
        inst = {f"{n} {sem['masks'][n]['label']}"[:28]: a for n, a in arrs.items() if n[0] == "t" and n[1:].isdigit()}
        panels = [labeled(img, f"{name} {sid}"), overlay(img, unions, "unions")]
        if "subject" in arrs:
            panels.append(overlay(img, {"subject": arrs["subject"]}, "subject"))
            panels.append(labeled(np.repeat(arrs["background"][..., None], 3, -1), "background (mask)"))
        panels.append(overlay(img, inst, "instances"))
        p = grid(panels, 3, OUT / f"sem_{stem}_masks.jpg")
        print("  saved", p)

        Ln = depth_log(c, sid, size)
        plan_ms = []
        for i, goal in enumerate(args.goals):
            current = {} if i == 0 else {"exposure": 0.1, "contrast": 8}
            t = time.perf_counter()
            r = c.post(f"/api/shots/{sid}/edit/local", json={"goal": goal, "values": current})
            ms = int((time.perf_counter() - t) * 1000)
            check(r.status_code == 200, f"{sid} {goal!r}: edit/local -> {r.status_code} {r.text[:200]}")
            if r.status_code != 200:
                continue
            plan = r.json()
            plan_ms.append(ms)
            validate_plan(sid, goal, plan, set(arrs), current)
            print(f"  [{goal}] {ms} ms (gemini {plan['ms']} ms, cached={plan['cached']}): {plan['summary']}"
                  f" | subject {plan['subject']}")
            print(f"    global {plan['values']}  why: {plan.get('why')}")
            for l in plan["layers"]:
                mk = l["mask"]
                print(f"    {l['id']} {l['target']!r} src={mk['source']} inv={mk['invert']} sub={mk['subtract']}"
                      f" f={mk['feather']} e={mk['edge']} {l['values']}  ({l['why']})")
            after = render(img, plan, arrs, Ln)
            alphas = {f"{l['id']} {l['target']}"[:26]: layer_alpha(l["mask"], arrs, img, Ln) for l in plan["layers"]}
            gslug = goal.replace(" ", "-")
            p = grid([labeled(img, "before"), labeled(after, f"after: {goal}"), overlay(img, alphas, "layers")],
                     3, OUT / f"sem_{stem}_{gslug}.jpg", width=2700)
            print("  saved", p)
        timings.append({"sample": name, "upload_ms": up_ms, "semantic_ms": cold_ms,
                        "semantic_cached_ms": warm_ms, "stateless_ms": sl_ms, "server": sem["timing"],
                        "plans_ms": plan_ms})

    stats = c.get("/api/stats").json()
    rows = {f"{r['tag']}/{r['model']}": r["calls"] for r in stats["calls"]}
    print("\nGemini calls by Core since start:", rows)
    print(f"calls during this run: {stats['totals']['calls'] - before}")
    print("timings:", json.dumps(timings))
    print("FAILURES:" if fails else "ALL OK", *fails, sep="\n  ")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
