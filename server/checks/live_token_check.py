"""Check POST /api/live/token, session resumption, LAN auth and Bonjour against a running Core.

Usage:
  cd server && uv run --no-sync python checks/live_token_check.py [http://127.0.0.1:8787]
      [--lan-ip 172.16.248.215] [--shot <shot_id>] [--no-live]

- camera: mint (ms), connect to Gemini directly with the token, setupComplete (ms), a text prompt
  -> tool calls (first-tool ms; expects guide/set_camera), then session resumption: reconnect to
  the same ws_url with the latest handle and check the conversation survived (a code word), that
  a fresh session on the same 1-use token is rejected, and that a NEW token can resume the handle.
- edit: mint for --shot (else a temporary fixture shot in $COACH_LIBRARY or server/library,
  removed afterwards),
  "make it warmer" -> edit_step/set_sliders raising warmth; bad requests -> 400/404.
- auth (needs --lan-ip and a server started with COACH_LAN=1 --host 0.0.0.0): loopback ok,
  tunnel-style headers and LAN requests need the token (Bearer or cookie coach_k), /api/pair is
  loopback only, the WS gate, and minting a token over the LAN with Bearer (the iPhone's path).
- bonjour (with --lan-ip): dns-sd -B/-L shows _coachcore._tcp on the server's port with v=1.
Never prints the API key or the coach token.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import httpx
import websockets

FAILS: list[str] = []
FIXTURE_ID = "19700101-000000-lchk"


def ok(cond: bool, label: str, detail: str = "") -> bool:
    print(f"  {'ok  ' if cond else 'FAIL'} {label}{(': ' + detail) if detail else ''}")
    if not cond:
        FAILS.append(label)
    return cond


def ms(t0: float) -> int:
    return int((time.perf_counter() - t0) * 1000)


async def live_turn(ws, text: str, want_tool: bool = True, timeout: float = 20.0) -> dict:
    """Send a text turn; answer tool calls (SILENT); collect calls, transcript, latest handle."""
    out = {"calls": [], "said": "", "handle": None, "first_tool_ms": None}
    t0 = time.perf_counter()
    await ws.send(json.dumps({"realtimeInput": {"text": text}}))
    end = time.monotonic() + timeout
    done = False
    while time.monotonic() < end:
        try:
            m = json.loads(await asyncio.wait_for(ws.recv(), max(0.1, end - time.monotonic())))
        except asyncio.TimeoutError:
            break
        u = m.get("sessionResumptionUpdate") or {}
        if u.get("resumable") and u.get("newHandle"):
            out["handle"] = u["newHandle"]
            if done:
                break
        if "toolCall" in m:
            out["first_tool_ms"] = out["first_tool_ms"] or ms(t0)
            resp = []
            for fc in m["toolCall"].get("functionCalls", []):
                out["calls"].append((fc["name"], fc.get("args") or {}))
                resp.append({"id": fc["id"], "name": fc["name"], "response": {"ok": True}, "scheduling": "SILENT"})
            await ws.send(json.dumps({"toolResponse": {"functionResponses": resp}}))
        sc = m.get("serverContent") or {}
        out["said"] += (sc.get("outputTranscription") or {}).get("text", "")
        if sc.get("turnComplete") and (out["calls"] or not want_tool):
            done = True
            end = min(end, time.monotonic() + 3)  # a resumable handle usually follows the turn
    return out


async def connect(ws_url: str, setup: dict):
    t0 = time.perf_counter()
    ws = await websockets.connect(ws_url, max_size=None, open_timeout=10)
    await ws.send(json.dumps({"setup": setup}))
    handle = None
    while True:
        m = json.loads(await asyncio.wait_for(ws.recv(), 10))
        u = m.get("sessionResumptionUpdate") or {}
        if u.get("newHandle"):
            handle = u["newHandle"]
        if "setupComplete" in m:
            return ws, ms(t0), handle


async def mint(c: httpx.AsyncClient, body: dict, headers: dict | None = None) -> tuple[httpx.Response, int]:
    t0 = time.perf_counter()
    r = await c.post("/api/live/token", json=body, headers=headers or {})
    return r, ms(t0)


async def check_camera(c: httpx.AsyncClient) -> None:
    print("camera mode")
    r, t = await mint(c, {"mode": "camera", "voice": True, "facing": "back"})
    if not ok(r.status_code == 200, "mint camera token", f"{r.status_code} in {t} ms (server {r.json().get('ms')} ms)"
              if r.status_code == 200 else r.text[:200]):
        return
    tok = r.json()
    ok(tok["ws_url"].endswith(tok["token"]) and tok["setup"] == {"sessionResumption": {}}, "response shape",
       f"model {tok['model']}, expires {tok['expire_time']}")
    ws, setup_ms, _ = await connect(tok["ws_url"], tok["setup"])
    ok(True, "setupComplete", f"{setup_ms} ms")
    a = await live_turn(ws, "Remember this code word for later: PELICAN. Just say OK.", want_tool=False, timeout=12)
    b = await live_turn(ws, "[tick] Settings: auto. The room is very dim and my friend is cut off at the left "
                            "edge of the frame. Fix it.")
    names = [n for n, _ in b["calls"]]
    ok(bool(names), "tool calls from a text prompt", f"first after {b['first_tool_ms']} ms: {json.dumps(b['calls'])[:220]}")
    ok("guide" in names, "guide called")
    handle = b["handle"] or a["handle"]
    await ws.close()
    if not ok(bool(handle), "got a resumable handle"):
        return

    print("resumption")
    ws, setup_ms, _ = await connect(tok["ws_url"], {"sessionResumption": {"handle": handle}})
    c2 = await live_turn(ws, "What was the code word I told you? Call set_intent with intent other and "
                             "subject set to the code word.")
    got = json.dumps(c2["calls"]) + c2["said"]
    ok("pelican" in got.lower(), "reconnect with handle keeps the conversation",
       f"setup {setup_ms} ms, {json.dumps(c2['calls'])[:120]} said {c2['said'][:60]!r}")
    handle = c2["handle"] or handle
    await ws.close()
    try:
        ws, _, _ = await connect(tok["ws_url"], {"sessionResumption": {}})
        await live_turn(ws, "hello", want_tool=False, timeout=4)
        await ws.close()
        ok(False, "fresh session on a used 1-use token is rejected", "it was accepted")
    except websockets.ConnectionClosed as exc:
        ok(True, "fresh session on a used 1-use token is rejected", f"{exc.rcvd.code if exc.rcvd else ''} "
           f"{exc.rcvd.reason if exc.rcvd else ''}"[:90])
    r, _ = await mint(c, {"mode": "camera"})
    if r.status_code == 200:
        try:
            ws, setup_ms, _ = await connect(r.json()["ws_url"], {"sessionResumption": {"handle": handle}})
            d = await live_turn(ws, "Say the code word again: call set_intent with intent other and subject "
                                    "set to the code word.")
            await ws.close()
            ok("pelican" in (json.dumps(d["calls"]) + d["said"]).lower(), "a NEW token resumes the old handle",
               f"setup {setup_ms} ms")
        except Exception as exc:
            ok(False, "a NEW token resumes the old handle", f"{type(exc).__name__}: {exc}"[:150])


def make_fixture(server_dir: Path) -> Path:
    # The server's library: COACH_LIBRARY when the instance under test was started with one.
    d = Path(os.environ.get("COACH_LIBRARY") or server_dir / "library") / FIXTURE_ID
    d.mkdir(parents=True, exist_ok=True)
    (d / "shot.json").write_text(json.dumps({
        "id": FIXTURE_ID, "width": 4032, "height": 3024,
        "meta": {"iso": 800, "shutter": 0.02, "intent": "portrait", "subject": "friend at sunset"},
        "assets": {"depth": {"status": "done", "meta": {"p02": 1.2, "p98": 40.0}}},
        "edit": {"version": 1, "values": {"warmth": 10}, "subject": "r1"}}))
    (d / "regions.json").write_text(json.dumps({"regions": [
        {"id": "r1", "box": {"x": 0.35, "y": 0.2, "w": 0.3, "h": 0.7}, "tag": "focus", "note": "Face a bit dark"},
        {"id": "r2", "box": {"x": 0.0, "y": 0.0, "w": 1.0, "h": 0.3}, "tag": "focus", "note": "Sunset sky, washed out"},
        {"id": "r3", "box": {"x": 0.8, "y": 0.6, "w": 0.2, "h": 0.4}, "tag": "remove", "note": "Trash can"}]}))
    (d / "score.json").write_text(json.dumps({"scores": {
        "lighting": {"score": 2.9, "label": "Backlit, face underexposed"},
        "composition": {"score": 3.8, "label": "Centered, good sky"}}}))
    # suggest.json deliberately missing: the loader must tolerate it.
    return d


async def check_edit(c: httpx.AsyncClient, shot: str | None, server_dir: Path) -> None:
    print("edit mode")
    r, _ = await mint(c, {"mode": "edit"})
    ok(r.status_code == 400, "edit without shot_id -> 400", str(r.status_code))
    r, _ = await mint(c, {"mode": "edit", "shot_id": "../etc"})
    ok(r.status_code == 400, "bad shot_id -> 400", str(r.status_code))
    r, _ = await mint(c, {"mode": "edit", "shot_id": "19700101-000000-none"})
    ok(r.status_code == 404, "unknown shot -> 404", str(r.status_code))
    fixture = None if shot else make_fixture(server_dir)
    try:
        r, t = await mint(c, {"mode": "edit", "shot_id": shot or FIXTURE_ID})
        if not ok(r.status_code == 200, "mint edit token", f"{r.status_code} in {t} ms" if r.status_code == 200 else r.text[:200]):
            return
        tok = r.json()
        ws, setup_ms, _ = await connect(tok["ws_url"], tok["setup"])
        ok(True, "setupComplete", f"{setup_ms} ms")
        e = await live_turn(ws, "make it warmer")
        await ws.close()
        warm = [a for n, a in e["calls"] if (n == "edit_step" and a.get("slider") == "warmth")
                or (n == "set_sliders" and "warmth" in (a.get("values") or {}))]
        val = None
        if warm:
            val = warm[0].get("value", (warm[0].get("values") or {}).get("warmth"))
        ok(bool(warm) and isinstance(val, (int, float)) and val > 10, "'make it warmer' -> warmth up from 10",
           f"first tool after {e['first_tool_ms']} ms: {json.dumps(e['calls'])[:200]}")
    finally:
        if fixture:
            shutil.rmtree(fixture, ignore_errors=True)


async def check_auth(base: str, lan_ip: str) -> None:
    print("auth")
    port = httpx.URL(base).port
    lan = f"http://{lan_ip}:{port}"
    async with httpx.AsyncClient(timeout=20) as c:
        r = await c.get(f"{base}/api/health")
        ok(r.status_code == 200, "loopback health", json.dumps(r.json()))
        ok(r.json().get("lan") is True, "health says lan: true")
        r = await c.get(f"{base}/api/pair")
        if not ok(r.status_code == 200 and "token" in r.json(), "loopback /api/pair", str(r.status_code)):
            return
        pair = r.json()
        token = pair["token"]
        ok(len(token) == 32 and pair["url"].startswith("coach://pair?host="), "pair shape",
           f"host {pair['host']} port {pair['port']} name {pair.get('name')!r}")
        bearer = {"Authorization": f"Bearer {token}"}
        cases = [
            ("LAN no token -> 401", f"{lan}/api/health", {}, {}, 401),
            ("LAN wrong Bearer -> 401", f"{lan}/api/health", {"Authorization": "Bearer nope"}, {}, 401),
            ("LAN Bearer -> 200", f"{lan}/api/health", bearer, {}, 200),
            ("LAN cookie coach_k -> 200", f"{lan}/api/health", {}, {"coach_k": token}, 200),
            ("LAN /api/pair with Bearer -> 403 (loopback only)", f"{lan}/api/pair", bearer, {}, 403),
            ("tunnel header, no token -> 401", f"{base}/api/health", {"cf-connecting-ip": "1.2.3.4"}, {}, 401),
            ("tunnel header + cookie -> 200", f"{base}/api/health", {"cf-connecting-ip": "1.2.3.4"}, {"coach_k": token}, 200),
            ("tunnel header + Bearer -> 200", f"{base}/api/health", {"cf-connecting-ip": "1.2.3.4", **bearer}, {}, 200),
            ("loopback with X-Forwarded-For, no token -> 401", f"{base}/api/health", {"X-Forwarded-For": "10.0.0.9"}, {}, 401),
            ("tunnel /api/pair with token -> 403", f"{base}/api/pair", {"cf-connecting-ip": "1.2.3.4", **bearer}, {}, 403),
        ]
        for label, url, headers, cookies, want in cases:
            r = await c.get(url, headers=headers, cookies=cookies)
            ok(r.status_code == want, label, str(r.status_code))
        r = await c.post(f"{lan}/api/live/token", json={"mode": "camera"})
        ok(r.status_code == 401, "LAN mint without token -> 401", str(r.status_code))
        t0 = time.perf_counter()
        r = await c.post(f"{lan}/api/live/token", json={"mode": "camera"}, headers=bearer)
        ok(r.status_code == 200 and r.json().get("token"), "LAN mint with Bearer (iPhone path)", f"{r.status_code} in {ms(t0)} ms")
    ws_lan = f"ws://{lan_ip}:{port}/api/live?voice=0"
    try:
        w = await websockets.connect(ws_lan, open_timeout=5)
        await w.close()
        ok(False, "LAN WS without token rejected", "accepted")
    except websockets.InvalidStatus as exc:
        ok(True, "LAN WS without token rejected", f"HTTP {exc.response.status_code}")
    except Exception as exc:
        ok(False, "LAN WS without token rejected", f"{type(exc).__name__}: {exc}"[:120])
    try:
        w = await websockets.connect(ws_lan, open_timeout=5, additional_headers={"Authorization": f"Bearer {token}"})
        first = json.loads(await asyncio.wait_for(w.recv(), 10))
        await w.close()
        ok("setupComplete" in first, "LAN WS with Bearer -> proxy setupComplete", list(first)[0])
    except Exception as exc:
        ok(False, "LAN WS with Bearer accepted", f"{type(exc).__name__}: {exc}"[:120])


def check_bonjour(port: int) -> None:
    print("bonjour")

    def run(args: list[str], secs: float) -> str:
        p = subprocess.Popen(["dns-sd", *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        time.sleep(secs)
        p.terminate()
        return p.communicate(timeout=3)[0]

    browse = run(["-B", "_coachcore._tcp", "local."], 2.5)
    names = sorted({line.split("_coachcore._tcp.")[-1].strip() for line in browse.splitlines()
                    if "Add" in line and "_coachcore._tcp." in line})
    if not ok(bool(names), "dns-sd -B _coachcore._tcp finds Core", ", ".join(names)):
        return
    found = False
    for name in names:
        out = run(["-L", name, "_coachcore._tcp", "local."], 2.0)
        if f":{port} " in out or f":{port}\n" in out or f"port {port}" in out.lower():
            found = ok("v=1" in out, f"'{name}' resolves to port {port} with TXT v=1")
    if not found:
        ok(False, f"a Core service on port {port}", ", ".join(names))


async def main() -> int:
    args = sys.argv[1:]
    base = next((a for a in args if a.startswith("http")), "http://127.0.0.1:8787").rstrip("/")
    lan_ip = args[args.index("--lan-ip") + 1] if "--lan-ip" in args else None
    shot = args[args.index("--shot") + 1] if "--shot" in args else None
    server_dir = Path(__file__).resolve().parent.parent
    async with httpx.AsyncClient(base_url=base, timeout=30) as c:
        if "--no-live" not in args:
            await check_camera(c)
            await check_edit(c, shot, server_dir)
    if lan_ip:
        await check_auth(base, lan_ip)
        check_bonjour(httpx.URL(base).port or 80)
    print(f"\n{'ALL OK' if not FAILS else f'{len(FAILS)} FAILED: ' + '; '.join(FAILS)}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
