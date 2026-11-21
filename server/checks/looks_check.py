"""End-to-end check of per-photo film looks (docs/CORE_API.md §6) on a private Core instance.

Usage: cd server && uv run --no-sync python checks/looks_check.py [--port 8798] [--url URL]
       [--images a.jpg b.jpg] [--out DIR] [--keep]

Default: spawns its own Core on --port (COACH_WARMUP=0, COACH_LIBRARY=<fresh temp dir>, so it
never touches the lead's server or server/library) with the pipeline stages stubbed (no GPU, no
Gemini); the stubbed `suggest` calls looks.ensure_fit_look the way the real pipeline will. Gemini
calls: one fit (Hydrogen) + one bold (Neon) per image = 4 for the default 2 images.
--url uses an already running Core instead (its real pipeline runs too).

  0. offline: a neutral spec compiles to an identity LUT and the .cube text round-trips;
  1. uploads the images (POST /api/shots) with GET /api/events open;
  2. POST fit right away (it joins the pipeline's ensure_fit_look: one fit look per shot), then
     two identical bold POSTs at once (they must share one generation: same look id);
  3. GET list (must not be shadowed by shots' /api/shots/{id}/{name}) and the 400/404 paths;
  4. downloads every lut.cube: header, 33³ rows, values in [0,1], equal to compile_lut(spec);
  5. fetches the previews (JPEG, ≤1024 px), re-renders a deleted one, writes contact.jpg
     (original | fit | bold per row) to --out;
  6. SSE delivered assets.looks running -> done for every shot.
Prints timings and a JSON summary; exit code 1 on any failure.
"""

import argparse
import asyncio
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SERVER = Path(__file__).resolve().parents[1]
ROOT = SERVER.parent
SAMPLES = [ROOT / "web/public/samples/img-1408.jpg", ROOT / "web/public/samples/img-1931.jpg"]

# ------------------------------------------------------------------------------------------------
# --serve: the spawned server (pipeline stubbed; suggest -> looks.ensure_fit_look)


def serve(port: int) -> None:
    sys.path.insert(0, str(SERVER))
    os.chdir(SERVER)
    import uvicorn

    import app  # loads ../.env and includes the routers
    import looks
    import shots

    held: set = set()

    async def stub(sid, data):
        await asyncio.sleep(0.02)
        return {"stub": True}

    async def stub_suggest(sid, data):
        t = asyncio.create_task(looks.ensure_fit_look(sid))  # what the lead wires after suggest
        held.add(t)
        t.add_done_callback(held.discard)
        return {"stub": True}

    shots.STAGE_FN.update(depth=stub, score=stub, regions=stub, masks=stub, suggest=stub_suggest)
    uvicorn.run(app.app, host="127.0.0.1", port=port, log_level="warning")


# ------------------------------------------------------------------------------------------------
# client side


def check(ok: bool, msg: str, failures: list) -> bool:
    print(("  ok   " if ok else "  FAIL ") + msg)
    if not ok:
        failures.append(msg)
    return ok


def parse_cube(text: str):
    """-> (title, size, lut[r, g, b, 3]) or raises ValueError."""
    import numpy as np

    title, size, rows = None, None, []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key = line.split()[0]
        if key == "TITLE":
            title = line[5:].strip().strip('"')
        elif key == "LUT_3D_SIZE":
            size = int(line.split()[1])
        elif key in ("DOMAIN_MIN", "DOMAIN_MAX"):
            if [float(v) for v in line.split()[1:]] != ([0.0] * 3 if key == "DOMAIN_MIN" else [1.0] * 3):
                raise ValueError(f"unexpected {line}")
        else:
            rows.append([float(v) for v in line.split()])
    a = np.array(rows, dtype=np.float64)
    if size is None or a.shape != (size**3, 3):
        raise ValueError(f"size {size}, rows {a.shape}")
    return title, size, a.reshape(size, size, size, 3).transpose(2, 1, 0, 3)  # red fastest -> [r, g, b]


def offline(failures: list) -> None:
    import numpy as np

    import looks

    t = np.linspace(0, 1, 33)
    grid = np.stack(np.meshgrid(t, t, t, indexing="ij"), -1)
    neutral = {"curves": {c: looks.CURVE_X for c in ("master", "r", "g", "b")},
               "fade": {"black_lift": 0, "white_point": 1}, "mixer": [1, 0, 0, 0, 1, 0, 0, 0, 1],
               "split_tone": {"shadow_hue": 0, "shadow_strength": 0, "highlight_hue": 0,
                              "highlight_strength": 0, "balance": 0},
               "hsl": {"hue": [0] * 8, "sat": [0] * 8, "lum": [0] * 8}, "color": {"saturation": 0, "vibrance": 0}}
    lut = looks.compile_lut(neutral)
    check(float(np.abs(lut - grid).max()) < 1e-6, f"neutral spec -> identity LUT (max err {np.abs(lut - grid).max():.1e})", failures)
    _, size, back = parse_cube(looks.cube_text(lut, "neutral"))
    check(size == 33 and float(np.abs(back - grid).max()) < 1e-6, "identity .cube round-trips (red fastest)", failures)
    fx = looks.effects_of(looks.sanitize(neutral))
    check(fx["vignette"]["amount"] == 0 and fx["grain"]["amount"] == 0, "neutral spec has no effects", failures)


class Events:
    def __init__(self, base: str):
        self.base, self.items, self.task = base, [], None

    async def _run(self):
        import httpx

        async with httpx.AsyncClient(timeout=httpx.Timeout(5.0, read=None)) as c:
            async with c.stream("GET", f"{self.base}/api/events") as r:
                ev, data = None, []
                async for line in r.aiter_lines():
                    if line.startswith("event:"):
                        ev = line[6:].strip()
                    elif line.startswith("data:"):
                        data.append(line[5:].strip())
                    elif line == "" and ev:
                        self.items.append((ev, json.loads("\n".join(data)) if data else None))
                        ev, data = None, []

    def connect(self):
        self.task = asyncio.create_task(self._run())

    def looks_statuses(self, sid: str) -> list[str]:
        out = []
        for ev, d in self.items:
            if ev == "shot" and d and d.get("id") == sid:
                st = (d["assets"].get("looks") or {}).get("status")
                if st and (not out or out[-1] != st):
                    out.append(st)
        return out


async def run(base: str, images: list[Path], out: Path, lib: Path | None, failures: list) -> dict:
    import httpx
    import numpy as np
    from PIL import Image, ImageDraw

    import looks

    report: dict = {"shots": {}}
    ev = Events(base)
    ev.connect()
    await asyncio.sleep(0.3)
    async with httpx.AsyncClient(base_url=base, timeout=httpx.Timeout(10.0, read=150.0)) as c:

        async def post_look(sid: str, body: dict) -> tuple[int, dict, int]:
            t0 = time.perf_counter()
            r = await c.post(f"/api/shots/{sid}/looks", json=body)
            return r.status_code, r.json(), round((time.perf_counter() - t0) * 1000)

        async def one(img: Path) -> None:
            name = img.stem
            t0 = time.perf_counter()
            r = await c.post("/api/shots", files={"image": (img.name, img.read_bytes(), "image/jpeg")},
                             data={"meta": json.dumps({"source": "looks_check"})})
            assert r.status_code == 201, r.text
            sid = r.json()["id"]
            rep = report["shots"][name] = {"id": sid, "upload_ms": round((time.perf_counter() - t0) * 1000)}
            st, fit, wall = await post_look(sid, {"variant": "fit"})
            check(st in (200, 201) and fit.get("id", "").startswith("look-fit-"),
                  f"{name} fit {st} {fit.get('id')}: {fit.get('name')} | {fit.get('evokes')}", failures)
            rep["fit"] = {"id": fit.get("id"), "name": fit.get("name"), "evokes": fit.get("evokes"),
                          "rationale": fit.get("rationale"), "model": fit.get("model"), "post_ms": wall,
                          "ms": fit.get("ms"), "timing": fit.get("timing")}
            st2, again, _ = await post_look(sid, {"variant": "fit"})
            check(st2 == 200 and again.get("cached") and again.get("id") == fit.get("id"),
                  f"{name} second plain fit is cached ({st2})", failures)
            (s1, b1, wall), (s2, b2, _) = await asyncio.gather(post_look(sid, {"variant": "bold"}),
                                                               post_look(sid, {"variant": "bold"}))
            check(s1 == 201 and s2 == 201 and b1.get("id") == b2.get("id"),
                  f"{name} concurrent bold POSTs share one look ({b1.get('id')}, {b2.get('id')}): "
                  f"{b1.get('name')} | {b1.get('evokes')}", failures)
            rep["bold"] = {"id": b1.get("id"), "name": b1.get("name"), "evokes": b1.get("evokes"),
                           "rationale": b1.get("rationale"), "model": b1.get("model"), "post_ms": wall,
                           "ms": b1.get("ms"), "timing": b1.get("timing")}
            check(fit.get("model") == "gemini-4-hydrogen" and b1.get("model") == "gemini-4-neon",
                  f"{name} models fit={fit.get('model')} bold={b1.get('model')}", failures)
            check(isinstance(fit.get("read"), dict) and fit["read"].get("light"),
                  f"{name} fit read: {(fit.get('read') or {}).get('needs')}", failures)

            r = await c.get(f"/api/shots/{sid}/looks")
            ids = [x["id"] for x in r.json().get("looks", [])] if r.status_code == 200 else []
            check(r.status_code == 200 and ids == [fit.get("id"), b1.get("id")],
                  f"{name} GET looks {r.status_code} -> {ids}", failures)
            rec = (await c.get(f"/api/shots/{sid}")).json()
            al = rec["assets"].get("looks") or {}
            check(al.get("status") == "done" and al.get("ids") == ids, f"{name} assets.looks {al}", failures)

            orig = Image.open(io.BytesIO((await c.get(f"/api/shots/{sid}/image.jpg")).content)).convert("RGB")
            orig.thumbnail((1024, 1024), Image.LANCZOS)
            row = [(orig, "original")]
            for kind, look in (("fit", fit), ("bold", b1)):
                t0 = time.perf_counter()
                r = await c.get(look["lut"])
                cube_ms = round((time.perf_counter() - t0) * 1000)
                try:
                    title, size, lut = parse_cube(r.text)
                    ok = (size == 33 and float(lut.min()) >= 0 and float(lut.max()) <= 1)
                    ref = looks.compile_lut(look["spec"])
                    dev = float(np.abs(lut - ref).max())
                    t = np.linspace(0, 1, 33)
                    grid = np.stack(np.meshgrid(t, t, t, indexing="ij"), -1)
                    change = float(np.abs(lut - grid).mean() * 255)
                    check(ok and dev < 1e-5, f"{name} {kind} .cube '{title}' 33³ in [0,1], "
                          f"= compile_lut(spec) (max dev {dev:.1e}), mean LUT change {change:.1f}/255", failures)
                    rep[kind]["lut_change_255"] = round(change, 1)
                except ValueError as exc:
                    check(False, f"{name} {kind} .cube parse: {exc}", failures)
                t0 = time.perf_counter()
                r = await c.get(look["preview"])
                prev_ms = round((time.perf_counter() - t0) * 1000)
                im = Image.open(io.BytesIO(r.content)).convert("RGB")
                check(r.status_code == 200 and r.headers["content-type"] == "image/jpeg" and max(im.size) <= 1024
                      and im.size == orig.size, f"{name} {kind} preview {im.size} ({prev_ms} ms)", failures)
                diff = float(np.abs(np.asarray(im, float) - np.asarray(orig, float)).mean())
                rep[kind].update(cube_ms=cube_ms, preview_ms=prev_ms, preview_change_255=round(diff, 1))
                im.save(out / f"{name}_{kind}.jpg", quality=92)
                row.append((im, f"{kind}: {look.get('name')} ({look.get('evokes', '').split(':')[0]})"))
            if lib is not None:  # a deleted preview is re-rendered from spec.json + effects.json
                p = lib / sid / "looks" / fit["id"] / "preview.jpg"
                before = p.read_bytes()
                p.unlink()
                t0 = time.perf_counter()
                r = await c.get(fit["preview"])
                ms = round((time.perf_counter() - t0) * 1000)
                check(r.status_code == 200 and r.content == before, f"{name} preview re-render identical ({ms} ms)", failures)
                rep["rerender_ms"] = ms
            report["shots"][name]["row"] = row

        await asyncio.gather(*(one(p) for p in images))

        sid0 = next(iter(report["shots"].values()))["id"]
        r = await c.post(f"/api/shots/{sid0}/looks", json={"variant": "nope"})
        check(r.status_code == 400, f"bad variant -> {r.status_code}", failures)
        r = await c.get("/api/shots/20990101-000000-0000/looks")
        check(r.status_code == 404, f"unknown shot -> {r.status_code}", failures)
        r = await c.get(f"/api/shots/{sid0}/looks/look-fit-99/lut.cube")
        check(r.status_code == 404, f"unknown look -> {r.status_code}", failures)
        r = await c.get(f"/api/shots/{sid0}/looks/..%2Fshot.json/preview.jpg")
        check(r.status_code == 404, f"bad look id -> {r.status_code}", failures)
        r = await c.get(f"/api/shots/{sid0}/image.jpg")
        check(r.status_code == 200, "shots' asset route still works", failures)

    await asyncio.sleep(0.3)
    ev.task.cancel()
    for name, rep in report["shots"].items():
        seq = ev.looks_statuses(rep["id"])
        check("running" in seq and seq[-1] == "done", f"{name} SSE assets.looks {seq}", failures)

    # contact sheet: original | fit | bold per row
    H = 420
    rows = []
    for rep in report["shots"].values():
        cells = []
        for im, label in rep.pop("row"):
            im = im.resize((round(im.width * H / im.height), H), Image.LANCZOS)
            ImageDraw.Draw(im).text((8, 8), label, fill=(255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0))
            cells.append(im)
        rows.append(cells)
    W = max(sum(i.width for i in r) + 8 * (len(r) - 1) for r in rows)
    sheet = Image.new("RGB", (W, len(rows) * (H + 8) - 8), (24, 24, 24))
    for y, cells in enumerate(rows):
        x = 0
        for im in cells:
            sheet.paste(im, (x, y * (H + 8)))
            x += im.width + 8
    sheet.save(out / "contact.jpg", quality=90)
    report["contact"] = str(out / "contact.jpg")
    return report


def spawn(port: int, lib: Path, log_path: Path) -> subprocess.Popen:
    env = dict(os.environ, COACH_WARMUP="0", COACH_LIBRARY=str(lib), PYTHONUNBUFFERED="1")
    return subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--serve", str(port)],
                            env=env, cwd=SERVER, stdout=open(log_path, "w"), stderr=subprocess.STDOUT)


async def wait_up(base: str, proc: subprocess.Popen | None, timeout: float = 90.0) -> None:
    import httpx

    t0 = time.time()
    async with httpx.AsyncClient(timeout=2.0) as c:
        while time.time() - t0 < timeout:
            if proc is not None and proc.poll() is not None:
                raise RuntimeError("server exited")
            try:
                if (await c.get(f"{base}/api/shots?limit=1")).status_code == 200:
                    return
            except httpx.HTTPError:
                pass
            await asyncio.sleep(0.5)
    raise RuntimeError("server did not come up")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--serve", type=int, help=argparse.SUPPRESS)
    ap.add_argument("--port", type=int, default=8798)
    ap.add_argument("--url", help="use a running Core instead of spawning one")
    ap.add_argument("--images", nargs="+", type=Path, default=SAMPLES)
    ap.add_argument("--out", type=Path, default=Path(tempfile.gettempdir()) / "looks_check")
    ap.add_argument("--keep", action="store_true", help="keep the temp library")
    args = ap.parse_args()
    if args.serve:
        serve(args.serve)
        return
    sys.path.insert(0, str(SERVER))
    args.out.mkdir(parents=True, exist_ok=True)
    failures: list = []
    print("offline compiler checks")
    offline(failures)
    proc, lib = None, None
    base = args.url.rstrip("/") if args.url else f"http://127.0.0.1:{args.port}"
    if not args.url:
        lib = Path(tempfile.mkdtemp(prefix="looks-lib-"))
        proc = spawn(args.port, lib, args.out / "server.log")
    t0 = time.time()
    try:
        asyncio.run(wait_up(base, proc))
        print(f"server up at {base} in {time.time() - t0:.1f} s; images: {[p.name for p in args.images]}")
        report = asyncio.run(run(base, args.images, args.out, lib, failures))
    finally:
        if proc is not None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
            if lib is not None and not args.keep:
                shutil.rmtree(lib, ignore_errors=True)
    print("\ntimings (ms)")
    for name, rep in report["shots"].items():
        for kind in ("fit", "bold"):
            k = rep[kind]
            print(f"  {name} {kind:4s} {k['model']:18s} POST {k['post_ms']:6d}  gemini {k['timing']['gemini']:6d}  "
                  f"lut {k['timing']['lut']:4d}  preview {k['timing']['preview']:5d}  | GET cube {k['cube_ms']:4d}  "
                  f"GET preview {k['preview_ms']:4d}  | change LUT {k.get('lut_change_255')}/255, "
                  f"preview {k['preview_change_255']}/255")
    report["failures"] = failures
    print(json.dumps(report, indent=1))
    print(f"\n{'PASS' if not failures else f'FAIL ({len(failures)})'}; previews in {args.out}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
