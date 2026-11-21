"""Latency bench for every Gemini call path Core uses (p50/p95 per path).

Usage (against YOUR server instance, never the lead's :8787):
  cd server && uv run --no-sync python checks/bench.py --base http://127.0.0.1:8795 -n 3 --label after
  uv run --no-sync python checks/bench.py --compare ../out/bench_before.json ../out/bench_after.json

Paths (sequential, so numbers are per-call latency, not throughput):
  regions      POST /api/regions          (1536 px photo, like the shot library's image.jpg)
  score        POST /api/score            (Decisions API + labels; reports label fill rate)
  decide_cam   POST /api/cam/decide       (768 px frame + camera state)
  understand   POST /api/cam/understand   (one 768 px frame)
  say          POST /api/cam/say          (unique text each time, so the TTS cache never hits)
  reframe      in-process splat._ask_reframe with a fixed depth context (the Gemini call only;
               the endpoint would also run Depth Pro)
  live         token mint (/api/live/token if the server has it, else gemini.mint_live_token),
               then WebSocket setup and the first tool call on gemini-3.8-live
Rough spend at -n 3: well under $0.30. Writes ../out/bench_<label>.json.
"""

from __future__ import annotations

import argparse
import asyncio
import io
import json
import sys
import time
import uuid
from pathlib import Path

import httpx
from dotenv import load_dotenv
from PIL import Image

SERVER = Path(__file__).resolve().parents[1]
ROOT = SERVER.parent
load_dotenv(ROOT / ".env")
sys.path.insert(0, str(SERVER))

SAMPLE = ROOT / "web/public/samples/img-1016.jpg"
PATHS = ["regions", "score", "decide_cam", "understand", "say", "reframe", "live"]
REFRAME_CONTEXT = (
    "Scene depth from the camera (Depth Pro, meters): near (2nd pct) 1.2 m, median 3.4 m, far "
    "(98th pct) 41 m.\nAbout 12% of the frame is sky or very far away."
)


def pct(values: list[float], q: float) -> float | None:
    """Linear-interpolated percentile (q in 0..100); None for no data."""
    if not values:
        return None
    v = sorted(values)
    k = (len(v) - 1) * q / 100.0
    lo, hi = int(k), min(int(k) + 1, len(v) - 1)
    return round(v[lo] + (v[hi] - v[lo]) * (k - lo), 1)


def jpeg(long_side: int) -> bytes:
    im = Image.open(SAMPLE).convert("RGB")
    im.thumbnail((long_side, long_side), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=85)
    return buf.getvalue()


async def _timed(coro) -> tuple[float, object]:
    t0 = time.perf_counter()
    res = await coro
    return (time.perf_counter() - t0) * 1000.0, res


async def bench_http(client: httpx.AsyncClient, base: str, path: str, i: int, photo: bytes, frame: bytes) -> dict:
    state = json.dumps({"facing": "back", "zoom": 1.0, "intent": "landscape", "subject": "street"})
    if path == "regions":
        req = client.post(f"{base}/api/regions", files={"image": ("p.jpg", photo, "image/jpeg")})
    elif path == "score":
        req = client.post(f"{base}/api/score", files={"image": ("p.jpg", photo, "image/jpeg")})
    elif path == "decide_cam":
        req = client.post(f"{base}/api/cam/decide", files={"frame": ("f.jpg", frame, "image/jpeg")},
                          data={"state": state})
    elif path == "understand":
        req = client.post(f"{base}/api/cam/understand", files={"frames": ("f.jpg", frame, "image/jpeg")},
                          data={"state": state})
    elif path == "say":
        text = f"Step a little left so the light hits her face. Take {i} {uuid.uuid4().hex[:4]}."
        req = client.post(f"{base}/api/cam/say", json={"text": text})
    else:
        raise ValueError(path)
    ms, r = await _timed(req)
    out = {"ms": round(ms, 1), "status": r.status_code}
    if r.status_code != 200:
        out["error"] = r.text[:200]
        return out
    if path == "say":
        out["server_ms"] = int(r.headers.get("X-TTS-Ms", 0))
        out["bytes"] = len(r.content)
        return out
    body = r.json()
    out["server_ms"] = body.get("ms")
    if path == "score":
        out["provider"] = body.get("provider")
        out["labels"] = sum(1 for s in body["scores"].values() if s.get("label"))
    if path == "regions":
        out["model"] = body.get("model")
    return out


async def bench_reframe(i: int, photo: bytes) -> dict:
    import os

    import splat

    b64 = await asyncio.to_thread(splat._jpeg_b64, photo)
    model = os.environ.get("REFRAME_MODEL", "gemini-4-hydrogen")
    try:
        ms, raw = await _timed(splat._ask_reframe(b64, REFRAME_CONTEXT, model))
    except Exception as exc:
        return {"ms": None, "status": 0, "error": f"{type(exc).__name__}: {exc}"[:200]}
    return {"ms": round(ms, 1), "status": 200, "note": str(raw.get("note", ""))[:60]}


async def _mint(client: httpx.AsyncClient, base: str) -> tuple[str, str, float, str]:
    """Returns (token, ws_url, ms, how)."""
    t0 = time.perf_counter()
    r = await client.post(f"{base}/api/live/token", json={"mode": "camera", "voice": True, "facing": "back"})
    if r.status_code == 200:
        d = r.json()
        return d["token"], d["ws_url"], (time.perf_counter() - t0) * 1000.0, "endpoint"
    import cam
    import gemini

    t0 = time.perf_counter()
    d = await gemini.mint_live_token(cam._live_setup(True, "back", None), tag="bench_live_token")
    return d["token"], d["ws_url"], (time.perf_counter() - t0) * 1000.0, "helper"


async def bench_live(client: httpx.AsyncClient, base: str, i: int) -> dict:
    import websockets

    try:
        token, url, mint_ms, how = await _mint(client, base)
    except Exception as exc:
        return {"ms": None, "status": 0, "error": f"mint {type(exc).__name__}: {exc}"[:200]}
    out = {"mint_ms": round(mint_ms, 1), "mint_via": how, "status": 200}
    t0 = time.perf_counter()
    try:
        async with websockets.connect(url, max_size=None, open_timeout=10) as ws:
            await ws.send(json.dumps({"setup": {}}))
            while "setupComplete" not in json.loads(await asyncio.wait_for(ws.recv(), 10)):
                pass
            out["setup_ms"] = round((time.perf_counter() - t0) * 1000.0, 1)
            t1 = time.perf_counter()
            await ws.send(json.dumps({"realtimeInput": {"text": (
                "The person is cut off at the left edge of the frame. Call the guide tool now "
                "with the direction to move the camera.")}}))
            while True:
                m = json.loads(await asyncio.wait_for(ws.recv(), 15))
                if "first_ms" not in out and ("serverContent" in m or "toolCall" in m):
                    out["first_ms"] = round((time.perf_counter() - t1) * 1000.0, 1)
                if "toolCall" in m:
                    fc = m["toolCall"]["functionCalls"][0]
                    out["ms"] = round((time.perf_counter() - t1) * 1000.0, 1)
                    out["tool"] = f'{fc["name"]}({json.dumps(fc.get("args", {}))[:60]})'
                    break
    except Exception as exc:
        out.update(ms=None, status=0, error=f"{type(exc).__name__}: {exc}"[:200])
    return out


def summarize(runs: list[dict]) -> dict:
    s = {}
    for key in ("ms", "server_ms", "mint_ms", "setup_ms", "first_ms"):
        vals = [r[key] for r in runs if isinstance(r.get(key), (int, float))]
        if vals:
            s[key] = {"p50": pct(vals, 50), "p95": pct(vals, 95), "n": len(vals)}
    s["errors"] = sum(1 for r in runs if r.get("status") != 200)
    return s


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8795")
    ap.add_argument("-n", type=int, default=3)
    ap.add_argument("--only", default=",".join(PATHS))
    ap.add_argument("--label", default="run")
    ap.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"))
    args = ap.parse_args()
    if args.compare:
        return compare(*args.compare)
    if ":8787" in args.base:
        print("refusing to bench the lead's :8787 instance; start your own")
        return 2
    photo, frame = jpeg(1536), jpeg(768)
    report: dict = {"label": args.label, "base": args.base, "n": args.n,
                    "at": time.strftime("%Y-%m-%dT%H:%M:%S"), "paths": {}}
    async with httpx.AsyncClient(timeout=90) as client:
        for path in [p for p in args.only.split(",") if p]:
            runs = []
            for i in range(args.n):
                if path == "reframe":
                    runs.append(await bench_reframe(i, photo))
                elif path == "live":
                    runs.append(await bench_live(client, args.base, i))
                else:
                    runs.append(await bench_http(client, args.base, path, i, photo, frame))
                extra = {k: v for k, v in runs[-1].items() if k not in ("ms", "status")}
                print(f"  {path:<11} #{i + 1} {runs[-1].get('ms')} ms  {json.dumps(extra)[:140]}", flush=True)
            report["paths"][path] = {"runs": runs, "summary": summarize(runs)}
        try:
            r = await client.get(f"{args.base}/api/stats")
            if r.status_code == 200:
                report["server_stats"] = r.json()
        except httpx.HTTPError:
            pass
    print(f"\n{'path':<11} {'p50 ms':>8} {'p95 ms':>8} {'srv p50':>8}  errors")
    for path, d in report["paths"].items():
        s = d["summary"]
        ms, srv = s.get("ms", {}), s.get("server_ms", {})
        print(f"{path:<11} {ms.get('p50')!s:>8} {ms.get('p95')!s:>8} {srv.get('p50')!s:>8}  {s['errors']}")
    out = ROOT / "out" / f"bench_{args.label}.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(report, indent=1))
    print(f"wrote {out}")
    return 0


def compare(before: str, after: str) -> int:
    a, b = json.loads(Path(before).read_text()), json.loads(Path(after).read_text())
    print(f"{'path':<11} {'before p50':>10} {'after p50':>10} {'before p95':>10} {'after p95':>10}  delta p50")
    for path in a["paths"].keys() | b["paths"].keys():
        sa = a["paths"].get(path, {}).get("summary", {}).get("ms", {})
        sb = b["paths"].get(path, {}).get("summary", {}).get("ms", {})
        d = (f"{(sb['p50'] - sa['p50']) / sa['p50'] * 100:+.0f}%"
             if sa.get("p50") and sb.get("p50") else "")
        print(f"{path:<11} {sa.get('p50')!s:>10} {sb.get('p50')!s:>10} {sa.get('p95')!s:>10} "
              f"{sb.get('p95')!s:>10}  {d}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
