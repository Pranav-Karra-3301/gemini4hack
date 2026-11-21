"""Measure Gemini Live token accounting for the camera setup (usageMetadata per turn).

  cd server && uv run --no-sync python checks/live_cost.py <seconds> <tick_s> <img1> [img2 ...]
  env: FRAME_PX (768), MEDIA_RES (e.g. MEDIA_RESOLUTION_HIGH), CWC=trigger,target
Reads GEMINI_API_KEY from ../.env (never printed). Costs a few cents per minute of session. Sends a JPEG every 1 s (cycling the images,
768 px long side), a "[tick]" realtimeInput.text every tick_s seconds, answers tool calls SILENT,
and prints one line per usageMetadata message.
"""
import asyncio, base64, io, json, os, sys, time
from pathlib import Path

from dotenv import load_dotenv
from PIL import Image

SERVER = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVER))
load_dotenv(SERVER.parent / ".env")
import websockets  # noqa: E402

import cam  # noqa: E402
import gemini  # noqa: E402
import live_setup  # noqa: E402


def jpeg768(path: str) -> bytes:
    im = Image.open(path).convert("RGB")
    px = int(os.environ.get("FRAME_PX", "768"))
    im.thumbnail((px, px))
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=70)
    return buf.getvalue()


def _b(x):
    return x if isinstance(x, bytes) else x.encode()


async def main() -> None:
    secs, tick_s = float(sys.argv[1]), float(sys.argv[2])
    frames = [base64.b64encode(jpeg768(p)).decode() for p in sys.argv[3:]]
    setup = live_setup.build_setup("camera")
    if os.environ.get("CWC"):
        trig, tgt = map(int, os.environ["CWC"].split(","))
        setup["contextWindowCompression"] = {"triggerTokens": trig, "slidingWindow": {"targetTokens": tgt}}
    if os.environ.get("MEDIA_RES"):
        setup["generationConfig"]["mediaResolution"] = os.environ["MEDIA_RES"]
    t0 = time.monotonic()
    async with websockets.connect(cam.LIVE_URL, additional_headers={"x-goog-api-key": gemini.api_key()},
                                  max_size=None) as ws:
        await ws.send(json.dumps({"setup": setup}))
        while b"setupComplete" not in _b(await ws.recv()):
            pass
        print(f"setupComplete {time.monotonic() - t0:.2f}s", flush=True)
        stop = time.monotonic() + secs
        sent = {"frames": 0, "ticks": 0}
        lat = {"tick_at": None, "first": []}

        async def pump():
            i, next_tick = 0, time.monotonic() + 2
            while time.monotonic() < stop:
                await ws.send(json.dumps({"realtimeInput": {"video": {"data": frames[i % len(frames)],
                                                                      "mimeType": "image/jpeg"}}}))
                sent["frames"] += 1
                i += 1
                if tick_s > 0 and time.monotonic() >= next_tick:
                    await ws.send(json.dumps({"realtimeInput": {"text": "[tick] mode photo, zoom 1.0x, ev 0.0."}}))
                    sent["ticks"] += 1
                    lat["tick_at"] = time.monotonic()
                    next_tick = time.monotonic() + tick_s
                await asyncio.sleep(1.0)

        async def read():
            async for raw in ws:
                m = json.loads(raw)
                if lat["tick_at"] and ("toolCall" in m or (m.get("serverContent") or {}).get("modelTurn")):
                    lat["first"].append(round(time.monotonic() - lat["tick_at"], 2)); lat["tick_at"] = None
                if "toolCall" in m:
                    fr = [{"id": c.get("id"), "name": c.get("name"), "response": {"ok": True},
                           "scheduling": "SILENT"} for c in m["toolCall"].get("functionCalls", [])]
                    await ws.send(json.dumps({"toolResponse": {"functionResponses": fr}}))
                u = m.get("usageMetadata")
                if u:
                    det = {d.get("modality"): d.get("tokenCount") for d in u.get("promptTokensDetails") or []}
                    rdet = {d.get("modality"): d.get("tokenCount") for d in u.get("responseTokensDetails") or []}
                    print(json.dumps({"t": round(time.monotonic() - t0, 1), "frames": sent["frames"],
                                      "ticks": sent["ticks"], "prompt": u.get("promptTokenCount"),
                                      "resp": u.get("responseTokenCount"), "total": u.get("totalTokenCount"),
                                      "thought": u.get("thoughtsTokenCount"), "tooluse": u.get("toolUsePromptTokenCount"),
                                      "pdet": det, "rdet": rdet}), flush=True)

        reader = asyncio.create_task(read())
        await pump()
        await asyncio.sleep(4)
        reader.cancel()
        print(json.dumps({"done": sent, "tick_to_first_s": lat["first"]}), flush=True)


asyncio.run(main())
