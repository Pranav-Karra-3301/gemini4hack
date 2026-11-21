"""End-to-end check of the shot library (docs/CORE_API.md §3, §4) on a private Core instance.

Usage: cd server && uv run --no-sync python checks/shots_check.py [--port 8794] [--fake] [--splat]
       [--images a.jpg b.jpg ...] [--keep]

Spawns its own Core (COACH_WARMUP=0, COACH_LIBRARY=<fresh temp dir>) so it never touches the
lead's server or server/library, then:
  1. subscribes to GET /api/events and uploads the images (default: 3 samples) with iPhone meta;
  2. once the second-newest shot is mid-pipeline, SIGTERMs the server (with the SSE stream open:
     shutdown must be quick), checks shot.json on disk, restarts it and waits for every stage;
  3. checks that SSE delivered running/done for every stage of every shot, fetches every asset,
     compares depth.png with /api/depth, runs edit/suggest (cached auto, with a goal, with
     values), PUT edit (clamping + 400), optionally POST splat, and DELETE;
  4. prints per-stage timings (from the records' `ms`) and a JSON summary.
--fake swaps score, regions and suggest for canned answers (no Gemini calls; depth and SAM still
run for real). Gemini calls in a real run: about 4 per shot (decisions, labels, regions,
suggest) + 2 on-demand suggests + reruns of the stages interrupted by the restart.
"""

import argparse
import asyncio
import io
import json
import os
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SERVER = Path(__file__).resolve().parent.parent
ROOT = SERVER.parent
SAMPLES = ROOT / "web" / "public" / "samples"
DEFAULT_IMAGES = ["img-1216.jpg", "img-1427.jpg", "img-1931.jpg"]
STAGES = ("depth", "score", "regions", "masks", "suggest")


# ------------------------------------------------------------------------------------------------
# --serve: the spawned server (optionally with fake Gemini stages)


def serve(port: int, fake: bool) -> None:
    sys.path.insert(0, str(SERVER))
    os.chdir(SERVER)
    import uvicorn

    import app  # noqa: F401  (loads ../.env, includes the shots router)

    if fake:
        import decide
        import edit
        import regions

        async def fake_score(data, mime):
            await asyncio.sleep(0.4)
            mk = lambda s, l: {"score": s, "scale": [1, 5], "confidence": 0.6, "label": l}  # noqa: E731
            return {"provider": "fake", "scores": {"lighting": mk(3.1, "flat midday light"),
                                                   "composition": mk(3.8, "subject centered")}, "ms": 400}

        async def fake_regions(data, mime, depth_m=None):
            await asyncio.sleep(0.6)
            return {"regions": [
                {"id": "r1", "box": {"x": 0.3, "y": 0.25, "w": 0.4, "h": 0.6}, "tag": "focus", "note": "Subject"},
                {"id": "r2", "box": {"x": 0.0, "y": 0.0, "w": 0.25, "h": 0.2}, "tag": "remove", "note": "Bright corner"},
                {"id": "r3", "box": {"x": 0.7, "y": 0.6, "w": 0.28, "h": 0.38}, "tag": "remove", "note": "Clutter"},
            ], "model": "fake", "ms": 600}

        async def fake_suggest(image, notes, values=None, goal=None, region_ids=None,
                               default_subject=None, model=None):
            await asyncio.sleep(0.5)
            raw = {"subject": "r1", "summary": "fake plan", "steps": [
                {"slider": "vignette", "value": -20, "why": "frame it", "region": None},
                {"slider": "exposure", "value": 9, "why": "brighter (clamped to 3)", "region": None},
                {"slider": "subject_light", "value": 15, "why": "lift subject", "region": "r1"},
                {"slider": "bogus", "value": 1, "why": "dropped", "region": None},
            ]}
            res = edit._validate(raw, edit.clamp_values(values), list(region_ids or []))
            res.update(model="fake", ms=500, goal=goal, usage={})
            return res

        decide.score_photo, regions.find_regions, edit.suggest = fake_score, fake_regions, fake_suggest
    uvicorn.run(app.app, host="127.0.0.1", port=port, log_level="warning")


# ------------------------------------------------------------------------------------------------
# client side


class Events:
    """Collects SSE events from /api/events in the background; reconnect() after a restart."""

    def __init__(self, base: str):
        self.base, self.items, self.pings, self.hellos = base, [], 0, 0
        self.task: asyncio.Task | None = None

    async def _run(self):
        import httpx

        async with httpx.AsyncClient(timeout=httpx.Timeout(5.0, read=None)) as c:
            async with c.stream("GET", f"{self.base}/api/events") as r:
                assert r.status_code == 200, r.status_code
                ev, data = None, []
                async for line in r.aiter_lines():
                    if line.startswith(":"):
                        self.pings += 1
                    elif line.startswith("event:"):
                        ev = line[6:].strip()
                    elif line.startswith("data:"):
                        data.append(line[5:].strip())
                    elif line == "" and ev:
                        payload = json.loads("\n".join(data)) if data else None
                        if ev == "hello":
                            self.hellos += 1
                        self.items.append((time.time(), ev, payload))
                        ev, data = None, []

    def connect(self):
        self.task = asyncio.create_task(self._run())

    async def wait_closed(self, timeout=10.0):
        try:
            await asyncio.wait_for(self.task, timeout)
        except Exception:
            pass

    def seen(self, sid: str) -> dict[str, set]:
        out: dict[str, set] = {}
        for _, ev, d in self.items:
            if ev == "shot" and d and d["id"] == sid:
                for name, a in d["assets"].items():
                    out.setdefault(name, set()).add(a["status"])
        return out


def spawn(port: int, fake: bool, lib: Path) -> subprocess.Popen:
    env = dict(os.environ, COACH_WARMUP="0", COACH_LIBRARY=str(lib), PYTHONUNBUFFERED="1")
    cmd = [sys.executable, str(Path(__file__).resolve()), "--serve", str(port)] + (["--fake"] if fake else [])
    return subprocess.Popen(cmd, cwd=SERVER, env=env)


async def wait_health(c, base: str, timeout=60.0) -> float:
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if (await c.get(f"{base}/api/health")).status_code == 200:
                return time.time() - t0
        except Exception:
            pass
        await asyncio.sleep(0.2)
    raise RuntimeError("server did not come up")


async def wait_for(pred, timeout: float, step=0.25):
    t0 = time.time()
    while time.time() - t0 < timeout:
        r = await pred()
        if r:
            return r
        await asyncio.sleep(step)
    raise TimeoutError("condition not met")


def check(cond, msg, failures):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        failures.append(msg)


async def run(args) -> int:
    import httpx
    import numpy as np
    from PIL import Image

    base = f"http://127.0.0.1:{args.port}"
    lib = Path(tempfile.mkdtemp(prefix="shots_check_"))
    failures: list[str] = []
    report: dict = {"fake": args.fake, "library": str(lib)}
    proc = spawn(args.port, args.fake, lib)
    async with httpx.AsyncClient(timeout=httpx.Timeout(120.0, connect=5.0)) as c:
        try:
            report["startup_s"] = round(await wait_health(c, base), 2)
            sse = Events(base)
            sse.connect()
            await asyncio.sleep(0.3)

            # 1. upload
            metas = [
                {"source": "iphone", "device": "iPhone 17 Pro", "iso": 64, "shutter": 0.004, "ev": 0.0,
                 "wb_kelvin": 5200, "tint": 0, "lens": "wide", "zoom": 1.0, "mode": "portrait",
                 "focus": 0.42, "facing": "back", "intent": "portrait", "subject": "friend by the window",
                 "keep": ["friend"], "coach": ["Turn her toward the window"]},
                {"source": "iphone", "device": "iPhone 17 Pro", "iso": 125, "shutter": 0.01, "ev": -0.3,
                 "wb_kelvin": 4300, "lens": "ultrawide", "zoom": 0.5, "mode": "photo", "facing": "back",
                 "intent": "landscape", "subject": "the street", "coach": ["Step left to show the arch"]},
                {"source": "iphone", "device": "iPhone 17 Pro", "iso": 400, "shutter": 0.033, "ev": 0.3,
                 "wb_kelvin": 3400, "lens": "tele", "zoom": 4.0, "mode": "photo", "facing": "back",
                 "intent": "object", "subject": "the table"},
            ]
            ids, up_ms, t_up = [], [], {}
            for i, name in enumerate(args.images):
                path = Path(name) if "/" in name else SAMPLES / name
                t0 = time.perf_counter()
                r = await c.post(f"{base}/api/shots", files={"image": (path.name, path.read_bytes(), "image/jpeg")},
                                 data={"meta": json.dumps(dict(metas[i % len(metas)], taken_at="2026-11-21T12:00:00Z"))})
                up_ms.append(round((time.perf_counter() - t0) * 1000))
                check(r.status_code == 201, f"upload {path.name} -> {r.status_code}", failures)
                rec = r.json()
                ids.append(rec["id"])
                t_up[rec["id"]] = time.time()
            report["upload_ms"] = up_ms
            r = await c.post(f"{base}/api/shots", files={"image": ("x.jpg", b"nope", "image/jpeg")})
            check(r.status_code == 400 and "error" in r.json(), "upload of a non-image -> 400 {error}", failures)
            lst = (await c.get(f"{base}/api/shots")).json()["shots"]
            check([s["id"] for s in lst] == sorted(ids, reverse=True), "GET /api/shots newest first", failures)
            page = (await c.get(f"{base}/api/shots", params={"limit": 1, "before": max(ids)})).json()["shots"]
            check(len(page) == 1 and page[0]["id"] == sorted(ids)[-2], "limit/before paging", failures)

            async def rec_of(sid):
                return (await c.get(f"{base}/api/shots/{sid}")).json()

            # 2. restart mid-pipeline: newest shot goes first; kill once the 2nd newest has started
            newest, second = sorted(ids)[-1], sorted(ids)[-2]

            async def second_started():
                r2 = await rec_of(second)
                st = {k: r2["assets"][k]["status"] for k in STAGES}
                return st if any(v in ("running", "done") for v in st.values()) and st["suggest"] != "done" else None

            at_kill = await wait_for(second_started, 240)
            t_done_newest = max(t for t, ev, d in sse.items if ev == "shot" and d["id"] == newest
                                and d["assets"]["suggest"]["status"] in ("done", "error"))
            report["e2e_newest_s"] = round(t_done_newest - t_up[newest], 2)
            t0 = time.time()
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(30)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
                failures.append("server did not stop within 30 s of SIGTERM")
            report["shutdown_s"] = round(time.time() - t0, 2)
            check(report["shutdown_s"] < 10, f"SIGTERM with SSE open: exited in {report['shutdown_s']} s", failures)
            await sse.wait_closed()
            disk = json.loads((lib / second / "shot.json").read_text())
            disk_st = {k: disk["assets"][k]["status"] for k in STAGES}
            report["killed_at"] = {"sse_view": at_kill, "on_disk": disk_st}
            check(any(v in ("pending", "running") for v in disk_st.values()),
                  f"shot.json on disk has unfinished stages at kill: {disk_st}", failures)
            proc = spawn(args.port, args.fake, lib)
            report["restart_s"] = round(await wait_health(c, base), 2)
            sse.connect()

            async def all_done():
                recs = [await rec_of(s) for s in ids]
                return recs if all(r["assets"][k]["status"] in ("done", "error") for r in recs for k in STAGES) else None

            t0 = time.time()
            recs = await wait_for(all_done, 300, 0.5)
            report["resume_to_all_done_s"] = round(time.time() - t0, 2)
            await asyncio.sleep(0.3)
            check(sse.hellos == 2, f"hello once per connection ({sse.hellos} for 2 connections)", failures)

            # 3a. SSE + statuses
            timings = {}
            for r in recs:
                sid = r["id"]
                seen = sse.seen(sid)
                for k in STAGES:
                    a = r["assets"][k]
                    check(a["status"] == "done", f"{sid} {k}: {a['status']} {a.get('error', '')}", failures)
                    check({"running", "done"} <= seen.get(k, set()), f"{sid} {k}: SSE saw {sorted(seen.get(k, []))}", failures)
                timings[sid] = {k: r["assets"][k].get("ms") for k in STAGES}
            report["stage_ms"] = timings

            # 3b. every asset
            sid0 = newest
            for r in recs:
                sid = r["id"]
                for name in ("image", "original", "thumb"):
                    g = await c.get(base + r["assets"][name]["url"])
                    im = Image.open(io.BytesIO(g.content))
                    check(g.status_code == 200 and im.format == "JPEG", f"{sid} {name}.jpg {im.size}", failures)
                    if name == "image":
                        check(max(im.size) == 1536, f"{sid} image long side {max(im.size)}", failures)
                    if name == "thumb":
                        check(max(im.size) == 400, f"{sid} thumb long side {max(im.size)}", failures)
                g = await c.get(base + r["assets"]["depth"]["url"])
                dimg = Image.open(io.BytesIO(g.content))
                dm = np.asarray(dimg)
                meta = r["assets"]["depth"]["meta"]
                check(dimg.format == "PNG" and dm.dtype == np.uint16 and max(dm.shape) <= 512
                      and (dm.shape[1], dm.shape[0]) == (meta["width"], meta["height"]),
                      f"{sid} depth.png {dimg.mode} {dm.dtype} {dm.shape} meta {meta['width']}x{meta['height']}", failures)
                for name in ("regions", "score", "suggest"):
                    g = await c.get(base + r["assets"][name]["url"])
                    check(g.status_code == 200 and isinstance(g.json(), dict), f"{sid} {name}.json", failures)
                regs = (await c.get(base + r["assets"]["regions"]["url"])).json()["regions"]
                urls = r["assets"]["masks"]["urls"]
                check(set(urls) == {x["id"] for x in regs}, f"{sid} one mask per region {sorted(urls)}", failures)
                for rid, u in urls.items():
                    g = await c.get(base + u)
                    check(g.status_code == 200 and g.content[:4] == b"\x89PNG", f"{sid} mask {rid} png", failures)
                sug = (await c.get(base + r["assets"]["suggest"]["url"])).json()
                check(3 <= len(sug["steps"]) <= 8 or args.fake, f"{sid} auto suggest {len(sug['steps'])} steps: {sug['summary']}", failures)
            g = await c.get(f"{base}/api/shots/{sid0}/masks/../shot.json")
            check(g.status_code == 404, "path traversal -> 404", failures)

            # 3c. depth.png vs /api/depth on the same image.jpg bytes
            dev = []
            for r in recs:
                img = (await c.get(base + r["assets"]["image"]["url"])).content
                g = await c.post(f"{base}/api/depth", files={"image": ("i.jpg", img, "image/jpeg")})
                w, h = int(g.headers["x-depth-width"]), int(g.headers["x-depth-height"])
                ref = np.frombuffer(g.content, "<f4").reshape(h, w) * 1000.0
                dm = np.asarray(Image.open(io.BytesIO((await c.get(base + r["assets"]["depth"]["url"])).content))).astype(np.float64)
                ok = (dm > 0) & (dm < 65535) & (ref < 65535)
                rel = np.abs(dm[ok] - ref[ok]) / ref[ok]
                dev.append({"shot": r["id"], "valid_frac": round(float(ok.mean()), 3),
                            "median_rel": float(f"{np.median(rel):.2e}"), "max_abs_mm": round(float(np.abs(dm[ok] - ref[ok]).max()), 2),
                            "far_px_match": bool(((dm == 65535) == (ref >= 65534.5)).all())})
                check(np.abs(dm[ok] - ref[ok]).max() <= 0.51 and dev[-1]["far_px_match"],
                      f"{r['id']} depth.png == round(/api/depth * 1000) ({dev[-1]})", failures)
            report["depth_vs_api"] = dev

            # 3d. suggest
            sres = {}
            t0 = time.perf_counter()
            g = await c.post(f"{base}/api/shots/{sid0}/edit/suggest", json={})
            sres["auto_cached_ms"] = round((time.perf_counter() - t0) * 1000)
            check(g.status_code == 200 and g.json().get("cached") is True, "suggest without goal/values -> cached auto", failures)
            for label, body in (("goal", {"values": {}, "goal": "make it moodier"}),
                                ("values", {"values": {"exposure": 0.5, "warmth": 10}})):
                t0 = time.perf_counter()
                g = await c.post(f"{base}/api/shots/{sid0}/edit/suggest", json=body)
                wall = round((time.perf_counter() - t0) * 1000)
                js = g.json()
                ok = g.status_code == 200 and 1 <= len(js.get("steps", [])) <= 8
                sres[label] = {"wall_ms": wall, "ms": js.get("ms"), "summary": js.get("summary"),
                               "steps": [(s["slider"], s["value"]) for s in js.get("steps", [])],
                               "usage": js.get("usage"), "subject": js.get("subject")}
                check(ok, f"suggest {label}: {g.status_code} {len(js.get('steps', []))} steps '{js.get('summary')}'", failures)
                import edit as E  # ranges/order from the server's own table
                for s in js.get("steps", []):
                    lo, hi = E.SLIDERS[s["slider"]][:2]
                    check(lo <= s["value"] <= hi, f"  {s['slider']}={s['value']} in [{lo},{hi}] why='{s['why']}'", failures)
                ranks = [E.ORDER.index(s["slider"]) for s in js.get("steps", [])]
                check(ranks == sorted(ranks), "  steps in editing order", failures)
            g = await c.post(f"{base}/api/shots/{sid0}/edit/suggest", json={"values": {"nope": 1}})
            check(g.status_code == 400, "suggest with an unknown slider -> 400", failures)
            report["suggest"] = sres

            # 3e. PUT edit
            n0 = len(sse.items)
            recipe = {"version": 1, "values": {"exposure": 5, "warmth": 12, "depth_blur": 35, "contrast": 0},
                      "subject": "r1", "crop": {"x": 0.1, "y": 0, "w": 0.95, "h": 1, "angle": 2}}
            g = await c.put(f"{base}/api/shots/{sid0}/edit", json=recipe)
            e = g.json().get("edit") or {}
            check(g.status_code == 200 and e.get("values") == {"exposure": 3.0, "warmth": 12, "depth_blur": 35}
                  and abs(e["crop"]["w"] - 0.9) < 1e-6, f"PUT edit clamps: {e.get('values')} crop {e.get('crop')}", failures)
            await asyncio.sleep(0.3)
            check(any(ev == "shot" and d["id"] == sid0 and d.get("edit") for _, ev, d in sse.items[n0:]),
                  "SSE shot event for the saved edit", failures)
            g = await c.put(f"{base}/api/shots/{sid0}/edit", json={"values": {"sharpen": 3}})
            check(g.status_code == 400 and "error" in g.json(), "PUT edit unknown slider -> 400", failures)
            check((await rec_of(sid0))["edit"]["values"]["warmth"] == 12, "GET record carries the edit", failures)

            # 3f. splat (optional: ~7 s, ~9 GB)
            if args.splat:
                t0 = time.time()
                g = await c.post(f"{base}/api/shots/{sid0}/splat")
                check(g.status_code == 202, f"POST splat -> {g.status_code}", failures)

                async def splat_done():
                    a = (await rec_of(sid0))["assets"]["splat"]
                    return a if a["status"] in ("done", "error") else None

                a = await wait_for(splat_done, 240, 0.5)
                report["splat"] = {"wall_s": round(time.time() - t0, 2), **a}
                spz = (await c.get(f"{base}/api/shots/{sid0}/splat.spz")).content
                check(a["status"] == "done" and spz[:2] == b"\x1f\x8b", f"splat {a.get('status')} {len(spz)} bytes", failures)
                check({"pending", "running", "done"} <= sse.seen(sid0).get("splat", set()), "SSE splat transitions", failures)

            # 3g. delete
            victim = sorted(ids)[0]
            n0 = len(sse.items)
            g = await c.delete(f"{base}/api/shots/{victim}")
            check(g.status_code == 204, f"DELETE -> {g.status_code}", failures)
            check((await c.get(f"{base}/api/shots/{victim}")).status_code == 404, "GET deleted -> 404", failures)
            check(not (lib / victim).exists(), "library dir removed", failures)
            await asyncio.sleep(0.3)
            check(any(ev == "shot_deleted" and d == {"id": victim} for _, ev, d in sse.items[n0:]), "SSE shot_deleted", failures)
            check((await c.delete(f"{base}/api/shots/{victim}")).status_code == 404, "DELETE again -> 404", failures)
            report["sse_events"] = len(sse.items)
        finally:
            if proc.poll() is None:
                proc.send_signal(signal.SIGTERM)
                try:
                    proc.wait(20)
                except subprocess.TimeoutExpired:
                    proc.kill()
            if not args.keep:
                shutil.rmtree(lib, ignore_errors=True)
    for k, v in report.items():
        print(f"{k}: {json.dumps(v)}")
    print(f"{len(failures)} failures" + (": " + "; ".join(failures[:8]) if failures else ""))
    return 1 if failures else 0


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8794)
    ap.add_argument("--serve", type=int, help=argparse.SUPPRESS)
    ap.add_argument("--fake", action="store_true", help="canned score/regions/suggest (no Gemini)")
    ap.add_argument("--splat", action="store_true", help="also run SHARP once (~7 s, ~9 GB)")
    ap.add_argument("--keep", action="store_true", help="keep the temp library")
    ap.add_argument("--images", nargs="+", default=DEFAULT_IMAGES)
    args = ap.parse_args()
    if args.serve:
        serve(args.serve, args.fake)
        return
    sys.path.insert(0, str(SERVER))
    sys.exit(asyncio.run(run(args)))


if __name__ == "__main__":
    main()
