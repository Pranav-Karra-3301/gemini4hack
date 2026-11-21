"""Check the Coach Cam routes against a running server.

Usage: cd server && uv run --no-sync python checks/cam_check.py [http://127.0.0.1:8787] [--no-live | --live-only]

Runs: decide (frame; frame + "meh" audio; frame + "good" audio), understand (2 frames + the
"I want a nice portrait" utterance), say (-> WAV), and a Live round trip over WS /api/live
(frame + the same utterance streamed in real time; expects a tool call and audio back).
Fixtures: /tmp/lc_qa/fixtures/{intent16,meh16,good16}.wav and web/public/samples/img-1216.jpg.
Set COACH_TOKEN in the environment if the server is gated.
"""

import asyncio
import base64
import io
import json
import os
import sys
import time
import wave
from pathlib import Path

import httpx
import websockets
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
FIX = Path(os.environ.get("CAM_FIXTURES", "/tmp/lc_qa/fixtures"))
SAMPLE = ROOT / "web/public/samples/img-1216.jpg"


def jpeg(path: Path, max_side: int = 768, crop: float = 0.0) -> bytes:
    im = Image.open(path).convert("RGB")
    if crop:  # shift the view right by `crop` of the width (as if the camera panned right)
        w, h = im.size
        im = im.crop((int(w * crop), 0, w, h))
    im.thumbnail((max_side, max_side))
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=70)
    return buf.getvalue()


def pcm16(path: Path) -> tuple[bytes, int]:
    with wave.open(str(path)) as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2
        return w.readframes(w.getnframes()), w.getframerate()


def top(ans: dict) -> str:
    if not ans:
        return "-"
    if "noul" in ans:
        return f"yes={ans['noul']:.2f}"
    probs = sorted(ans.get("probabilities", {}).items(), key=lambda kv: -kv[1])[:3]
    return f"{ans.get('choice')} ({', '.join(f'{k} {v:.2f}' for k, v in probs)})"


async def check_decide(c: httpx.AsyncClient, frame: bytes) -> bool:
    ok = True
    state = {"facing": "environment", "mode": "photo", "zoom": 1, "exposure": 0, "caps": {}}
    for label, audio in (("frame only", None), ("meh16.wav", "meh16.wav"), ("good16.wav", "good16.wav")):
        files = {"frame": ("f.jpg", frame, "image/jpeg")}
        if audio:
            files["audio"] = (audio, (FIX / audio).read_bytes(), "audio/wav")
        t = time.perf_counter()
        r = await c.post("/api/cam/decide", files=files, data={"state": json.dumps(state)})
        ms = (time.perf_counter() - t) * 1000
        if r.status_code != 200:
            print(f"  decide [{label}] FAIL {r.status_code}: {r.text[:300]}")
            ok = False
            continue
        j = r.json()
        a = j["answers"]
        print(f"  decide [{label}] {ms:.0f} ms (server {j['ms']} ms, {j.get('tokens')} tokens)")
        for k in ("move", "ready", "intent", "mode", "exposure", "reaction"):
            if k in a:
                print(f"      {k:9s} {top(a[k])}")
        missing = [k for k in ("move", "ready", "intent", "mode", "exposure") if k not in a]
        if missing or (audio and "reaction" not in a) or (not audio and "reaction" in a):
            print(f"      FAIL: missing {missing} or reaction presence wrong")
            ok = False
        if audio and "reaction" in a:
            p = a["reaction"]["probabilities"]
            want = "disappointed" if audio.startswith("meh") else "pleased"
            other = "pleased" if want == "disappointed" else "disappointed"
            lean = p.get(want, 0) > p.get(other, 0)
            print(f"      reaction leans {'the right way' if lean else 'THE WRONG WAY'} ({want} {p.get(want, 0):.2f} vs {other} {p.get(other, 0):.2f})")
            ok &= lean
    return ok


async def check_understand(c: httpx.AsyncClient, frames: list[bytes]) -> bool:
    files = [("frames", (f"f{i}.jpg", f, "image/jpeg")) for i, f in enumerate(frames)]
    files.append(("audio", ("intent16.wav", (FIX / "intent16.wav").read_bytes(), "audio/wav")))
    state = {"facing": "environment", "mode": "photo", "zoom": 1, "exposure": 0, "voice": True}
    t = time.perf_counter()
    r = await c.post("/api/cam/understand", files=files, data={"state": json.dumps(state)})
    ms = (time.perf_counter() - t) * 1000
    if r.status_code != 200:
        print(f"  understand FAIL {r.status_code}: {r.text[:300]}")
        return False
    j = r.json()
    print(f"  understand {ms:.0f} ms (server {j['ms']} ms, {j['model']})")
    for k in ("heard", "reaction", "intent", "subject", "selfie", "keep", "scene", "wants", "tip", "settings"):
        print(f"      {k:9s} {json.dumps(j.get(k))}")
    ok = (bool(j.get("heard")) and "portrait" in j["heard"].lower() and len(j.get("tip", "").split()) <= 10
          and isinstance(j.get("keep"), list) and isinstance(j.get("scene"), str) and isinstance(j.get("selfie"), bool))
    if not ok:
        print("      FAIL: expected the portrait request in `heard`, a short tip, and keep/scene/selfie")
    return ok


async def check_say(c: httpx.AsyncClient) -> bool:
    ok = True
    for text in ("Step a little to your left.", "Step a little to your left."):
        t = time.perf_counter()
        r = await c.post("/api/cam/say", json={"text": text})
        ms = (time.perf_counter() - t) * 1000
        if r.status_code != 200 or r.content[:4] != b"RIFF":
            print(f"  say FAIL {r.status_code}: {r.text[:200]}")
            return False
        with wave.open(io.BytesIO(r.content)) as w:
            dur = w.getnframes() / w.getframerate()
            rate = w.getframerate()
        print(f"  say {ms:.0f} ms (server {r.headers.get('x-tts-ms')} ms) -> {len(r.content)} B WAV, {rate} Hz, {dur:.2f} s")
        ok &= dur > 0.5
    return ok


async def check_live(base: str, frame: bytes, token: str | None) -> bool:
    url = base.replace("http", "ws", 1) + "/api/live?voice=1&facing=environment"
    headers = {"Cookie": f"coach_k={token}"} if token else {}
    pcm, rate = pcm16(FIX / "intent16.wav")
    t0 = time.perf_counter()
    async with websockets.connect(url, additional_headers=headers, max_size=None) as ws:
        first = json.loads(await asyncio.wait_for(ws.recv(), 15))
        if "setupComplete" not in first:
            print(f"  live FAIL: first message {first}")
            return False
        print(f"  live setupComplete {1000 * (time.perf_counter() - t0):.0f} ms")
        events: list[str] = []
        state = {"tool": None, "audio": None, "audio_bytes": 0, "said": "", "heard": "", "turns": 0}
        pending: list[dict] = []  # like live.js: answer at turn end, WHEN_IDLE if the model didn't speak
        spoke = [False]
        speech_end = [None]

        async def reader():
            while True:
                m = json.loads(await ws.recv())
                now = time.perf_counter()
                if "error" in m:
                    events.append(f"error {m['error']}")
                    return
                if "toolCall" in m:
                    if state["tool"] is None and speech_end[0]:
                        state["tool"] = now - speech_end[0]
                    for fc in m["toolCall"].get("functionCalls", []):
                        events.append(f"toolCall {fc['name']} {json.dumps(fc.get('args', {}))}")
                        pending.append({"id": fc["id"], "name": fc["name"], "response": {"ok": True}})
                sc = m.get("serverContent") or {}
                for p in (sc.get("modelTurn") or {}).get("parts", []):
                    if "inlineData" in p:
                        if state["audio"] is None and speech_end[0]:
                            state["audio"] = now - speech_end[0]
                        state["audio_bytes"] += len(p["inlineData"]["data"]) * 3 // 4
                        spoke[0] = True
                if "outputTranscription" in sc:
                    state["said"] += sc["outputTranscription"].get("text", "")
                if "inputTranscription" in sc:
                    state["heard"] += sc["inputTranscription"].get("text", "")
                if (sc.get("turnComplete") or sc.get("interrupted")) and pending:
                    sched = "SILENT" if spoke[0] else "WHEN_IDLE"
                    events.append(f"toolResponse x{len(pending)} scheduling={sched}")
                    await ws.send(json.dumps({"toolResponse": {"functionResponses": [{**r, "scheduling": sched} for r in pending]}}))
                    pending.clear()
                if sc.get("turnComplete"):
                    state["turns"] += 1
                    spoke[0] = False

        task = asyncio.create_task(reader())
        await ws.send(json.dumps({"realtimeInput": {"video": {"data": base64.b64encode(frame).decode(), "mimeType": "image/jpeg"}}}))
        chunk = rate // 10 * 2  # 100 ms
        silence = b"\0" * chunk
        for i in range(0, len(pcm), chunk):  # real-time pace, like the browser
            await ws.send(json.dumps({"realtimeInput": {"audio": {"data": base64.b64encode(pcm[i:i + chunk]).decode(), "mimeType": f"audio/pcm;rate={rate}"}}}))
            await asyncio.sleep(0.1)
        speech_end[0] = time.perf_counter()
        deadline = time.perf_counter() + 12
        while time.perf_counter() < deadline and not task.done():
            await ws.send(json.dumps({"realtimeInput": {"audio": {"data": base64.b64encode(silence).decode(), "mimeType": f"audio/pcm;rate={rate}"}}}))
            await asyncio.sleep(0.1)
            if state["tool"] is not None and state["audio"] is not None and state["turns"] >= 2:
                break
        task.cancel()
    fmt = lambda v: f"{v * 1000:.0f} ms" if v is not None else "none"  # noqa: E731
    for e in events:
        print(f"      {e[:160]}")
    print(f"      heard: {state['heard'].strip()!r}")
    print(f"      said:  {state['said'].strip()!r}")
    print(f"  live after end of speech: first tool call {fmt(state['tool'])}, first audio {fmt(state['audio'])} ({state['audio_bytes']} B PCM)")
    ok = state["tool"] is not None and state["audio_bytes"] > 0
    if not ok:
        print("      FAIL: expected a tool call and audio")
    return ok


async def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    base = (args[0] if args else os.environ.get("CAM_BASE", "http://127.0.0.1:8787")).rstrip("/")
    token = os.environ.get("COACH_TOKEN")
    cookies = {"coach_k": token} if token else None
    frame = jpeg(SAMPLE)
    frames = [jpeg(SAMPLE, crop=0.0), jpeg(SAMPLE, crop=0.08)]
    results = {}
    async with httpx.AsyncClient(base_url=base, timeout=60, cookies=cookies) as c:
        if "--live-only" not in sys.argv:
            print("decide:")
            results["decide"] = await check_decide(c, frame)
            print("understand:")
            results["understand"] = await check_understand(c, frames)
            print("say:")
            results["say"] = await check_say(c)
    if "--no-live" not in sys.argv:
        print("live:")
        try:
            results["live"] = await check_live(base, frame, token)
        except Exception as exc:
            print(f"  live FAIL: {type(exc).__name__}: {exc}")
            results["live"] = False
    print("\n" + "  ".join(f"{k}: {'ok' if v else 'FAIL'}" for k, v in results.items()))
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
