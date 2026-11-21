"""Coach Cam brains: Gemini Live proxy, Decision 1 fast loop, Hydrogen understanding, TTS.

Routes (CAM_CONTRACT.md):
  WS   /api/live?voice=1&facing=user|environment[&resume=<handle>]  Gemini Live bridge
  POST /api/cam/decide       frame (+ audio) -> Decisions API answers
  POST /api/cam/understand   1-3 frames (+ audio) -> intent / heard / reaction / tip / settings
  POST /api/cam/director     1 frame + state -> Gemini 4 composition plan (subject, move, ready, tip)
  POST /api/cam/say          {"text", "voice"} -> audio/wav

The API key stays here: it goes upstream in the x-goog-api-key header, never in a URL, a log
line or a response.
"""

from __future__ import annotations

import asyncio
import base64
import io
import json
import logging
import os
import re
import sys
import time
import wave
from collections import OrderedDict

import websockets
from fastapi import APIRouter, File, Form, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse, Response

import gemini

log = logging.getLogger("coach.cam")
router = APIRouter()

LIVE_URL = (
    "wss://generativelanguage.googleapis.com/ws/"
    "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
)

# Shared with the ephemeral-token path (live_token.py): enums, wording, and the Live setup.
from live_setup import DIRECTIONS_TEXT, FLASH, FRAMING_TEXT, INTENTS, MODES, MOVES, REACTIONS  # noqa: E402,F401
import live_budget  # noqa: E402
import live_setup  # noqa: E402


def _env(name: str, default: str) -> str:
    return os.environ.get(name) or default


def _key() -> str:
    return gemini.api_key()


# HTTP calls (decide, understand, say) go through gemini.py: pooled keep-alive client, 429/5xx
# retries with backoff inside one deadline, a `coach.gemini` log line and /api/stats per call.


def _err(status: int, exc: Exception) -> JSONResponse:
    log.warning("cam request failed: %s: %s", type(exc).__name__, exc)
    return JSONResponse({"error": f"{type(exc).__name__}: {exc}"}, status_code=status)


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def _clamp(v, lo, hi):
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    if v != v:  # NaN
        return None
    return max(lo, min(hi, v))


def _parse_state(state: str | None) -> dict:
    if not state:
        return {}
    try:
        s = json.loads(state)
        return s if isinstance(s, dict) else {}
    except ValueError:
        return {}


def _trim_wav(data: bytes, max_s: float) -> bytes | None:
    """Return a WAV with at most the last `max_s` seconds, or None if it isn't a readable WAV."""
    if not data or data[:4] != b"RIFF":
        return None
    try:
        with wave.open(io.BytesIO(data)) as w:
            rate, ch, width, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
            keep = int(rate * max_s)
            if n <= keep:
                return data
            w.setpos(n - keep)
            frames = w.readframes(keep)
        out = io.BytesIO()
        with wave.open(out, "wb") as o:
            o.setnchannels(ch)
            o.setsampwidth(width)
            o.setframerate(rate)
            o.writeframes(frames)
        return out.getvalue()
    except (wave.Error, EOFError):
        return None


# ---------------------------------------------------------------------------------------------
# WS /api/live

def _live_setup(voice: bool, facing: str, handle: str | None) -> dict:
    """Camera-mode setup from the shared builder (same prompt and tools as /api/live/token)."""
    return live_setup.build_setup("camera", voice=voice, facing=facing, handle=handle)


def _legacy_set_camera(text: str) -> str:
    """The web client (web/src/cam/live.js) reads set_camera's older `exposure` (EV) and
    `warmth` (-1..1); mirror the manual-control args into them."""
    try:
        msg = json.loads(text)
        changed = False
        for fc in msg["toolCall"]["functionCalls"]:
            a = fc.get("args") or {}
            if fc.get("name") != "set_camera":
                continue
            if "ev" in a and "exposure" not in a:
                a["exposure"] = a["ev"]
                changed = True
            k = a.get("wb_kelvin")
            if isinstance(k, (int, float)) and "warmth" not in a:
                a["warmth"] = round(max(-1.0, min(1.0, (k - 5500) / 2500)), 2)
                changed = True
        return json.dumps(msg) if changed else text
    except (ValueError, KeyError, TypeError):
        return text


class LiveBridge:
    """One browser socket <-> one upstream Live session. On goAway (or an unexpected upstream
    drop) it reconnects upstream with the latest resumption handle, transparently to the client."""

    def __init__(self, client: WebSocket, voice: bool, facing: str, handle: str | None):
        self.client = client
        self.voice = voice
        self.facing = facing
        self.handle = handle
        self.up = None
        self.closed = False
        self.rotating = False
        self.send_lock = asyncio.Lock()
        self.tasks: set[asyncio.Task] = set()
        self.early: list[str] = []

    async def _send_client(self, text: str) -> None:
        if self.closed:
            return
        async with self.send_lock:
            try:
                await self.client.send_text(text)
            except Exception:
                self.closed = True

    async def _open(self):
        t0 = time.perf_counter()
        model = live_setup.live_model()
        try:
            up = await websockets.connect(
                LIVE_URL, additional_headers={"x-goog-api-key": _key()}, max_size=None,
                open_timeout=10, ping_interval=20, ping_timeout=20,
            )
        except Exception as exc:
            gemini.record(model, "live_proxy_connect", (time.perf_counter() - t0) * 1000, ok=False,
                          error=f"{type(exc).__name__}: {exc}")
            raise
        # Wait for setupComplete. A resumed session sends an empty {} first; other early
        # messages (e.g. sessionResumptionUpdate) are kept and forwarded after it.
        self.early = []
        try:
            await up.send(json.dumps({"setup": _live_setup(self.voice, self.facing, self.handle)}))
            deadline = time.monotonic() + 10
            while True:
                raw = await asyncio.wait_for(up.recv(), max(0.1, deadline - time.monotonic()))
                text = raw.decode() if isinstance(raw, bytes) else raw
                if "setupComplete" in text:
                    gemini.record(model, "live_proxy_connect", (time.perf_counter() - t0) * 1000)
                    return up, text
                if text.strip() in ("", "{}"):
                    continue
                if '"error"' in text or len(self.early) > 20:
                    raise RuntimeError(f"unexpected message before setupComplete: {text[:200]}")
                self.early.append(text)
        except Exception as exc:
            gemini.record(model, "live_proxy_connect", (time.perf_counter() - t0) * 1000, ok=False,
                          error=f"{type(exc).__name__}: {exc}")
            await up.close()
            raise

    def _spawn(self, coro) -> None:
        t = asyncio.create_task(coro)
        self.tasks.add(t)
        t.add_done_callback(self.tasks.discard)

    async def _read(self, up) -> None:
        close_note = "closed"
        try:
            async for raw in up:
                text = raw.decode() if isinstance(raw, bytes) else raw
                if '"sessionResumptionUpdate"' in text or '"goAway"' in text:
                    try:
                        msg = json.loads(text)
                    except ValueError:
                        msg = {}
                    upd = msg.get("sessionResumptionUpdate") or {}
                    if upd.get("resumable") and upd.get("newHandle"):
                        self.handle = upd["newHandle"]
                    if "goAway" in msg and up is self.up:
                        self._spawn(self._rotate("goAway"))
                if '"set_camera"' in text and '"toolCall"' in text:
                    text = _legacy_set_camera(text)
                await self._send_client(text)
        except websockets.ConnectionClosed as exc:
            rcvd = exc.rcvd
            close_note = f"{rcvd.code} {rcvd.reason}" if rcvd else "connection lost"
        except Exception as exc:  # network errors
            close_note = f"{type(exc).__name__}: {exc}"
        if self.closed or up is not self.up or self.rotating:
            return
        # Unexpected upstream end: errors like 1007/1008 are our fault, don't loop on them.
        if self.handle and not close_note.startswith(("1007", "1008")):
            await self._rotate(f"upstream {close_note}")
        else:
            await self._fail(f"upstream {close_note}")

    async def _rotate(self, why: str) -> None:
        if self.rotating or self.closed:
            return
        self.rotating = True
        old = self.up
        try:
            log.warning("live: reconnecting upstream (%s), resume=%s", why, bool(self.handle))
            # A session can't be resumed while the old connection still holds it: close first
            # (media from the client is dropped for the ~0.5 s this takes).
            if old is not None:
                try:
                    await old.close()
                except Exception:
                    pass
            try:
                new, _first = await self._open()
            except Exception as exc:
                if not self.handle:
                    raise
                log.warning("live: resume failed (%s: %s), starting a fresh session", type(exc).__name__, exc)
                self.handle = None  # stale handle: start fresh rather than fail
                new, _first = await self._open()
            self.up = new
            for text in self.early:
                await self._send_client(text)
            self._spawn(self._read(new))
            # Not a Live message: tells the client the session moved (resumed = context kept).
            await self._send_client(json.dumps({"sessionRotated": {"resumed": bool(self.handle), "why": why}}))
        except Exception as exc:
            self.rotating = False
            await self._fail(f"reconnect failed: {type(exc).__name__}: {exc}")
            return
        self.rotating = False

    async def _fail(self, msg: str) -> None:
        log.warning("live: %s", msg)
        await self._send_client(json.dumps({"error": msg}))
        self.closed = True
        try:
            await self.client.close(code=1011)
        except Exception:
            pass

    async def run(self) -> None:
        try:
            try:
                self.up, first = await self._open()
            except Exception:
                if not self.handle:
                    raise
                self.handle = None  # expired or unknown resume handle: start a fresh session
                self.up, first = await self._open()
        except Exception as exc:
            await self._fail(f"upstream connect failed: {type(exc).__name__}: {exc}")
            return
        await self._send_client(first)
        for text in self.early:
            await self._send_client(text)
        self._spawn(self._read(self.up))
        try:
            while not self.closed:
                msg = await self.client.receive()
                if msg["type"] == "websocket.disconnect":
                    break
                text = msg.get("text")
                if text is None and msg.get("bytes") is not None:
                    text = msg["bytes"].decode(errors="replace")
                if not text or '"setup"' in text[:20]:
                    continue  # the server owns setup
                if '"_debug"' in text[:20]:
                    # CAM_DEBUG=1 only: {"_debug": "rotate"} exercises the goAway reconnect path.
                    if os.environ.get("CAM_DEBUG") == "1" and "rotate" in text:
                        self._spawn(self._rotate("debug"))
                    continue
                up = self.up
                if up is None or self.rotating:
                    continue  # drop media while swapping sessions
                try:
                    await up.send(text)
                except websockets.ConnectionClosed:
                    pass  # the reader handles reconnect/fail
        except (WebSocketDisconnect, RuntimeError):
            pass
        finally:
            self.closed = True
            for t in list(self.tasks):
                t.cancel()
            if self.up is not None:
                try:
                    await self.up.close()
                except Exception:
                    pass


def _ws_token_ok(ws: WebSocket) -> bool:
    """Same rule as app.py's gate (token_ok: loopback passes; tunnel and LAN clients need the
    coach token). Looked up at request time because app.py imports this module before defining
    it. app.py's ASGI gate already covers this route; this is defense in depth."""
    check = getattr(sys.modules.get("app"), "token_ok", None)
    if callable(check):
        return bool(check(ws.headers, ws.cookies, ws.client.host if ws.client else None))
    token = os.environ.get("COACH_TOKEN")
    return not token or ws.cookies.get("coach_k") == token


@router.websocket("/api/live")
async def api_live(ws: WebSocket):
    await ws.accept()
    if not _ws_token_ok(ws):
        await ws.close(code=4401, reason="missing or wrong coach token")
        return
    if not os.environ.get("GEMINI_API_KEY"):
        await ws.send_text(json.dumps({"error": "GEMINI_API_KEY is not set on the server"}))
        await ws.close(code=1011)
        return
    q = ws.query_params
    voice = q.get("voice", "1") not in ("0", "false", "off")
    facing = "user" if q.get("facing") == "user" else "environment"
    handle = (q.get("resume") or "").strip() or None
    counted = handle is None  # a resume continues a session that already counted
    if counted:
        over = live_budget.take()
        if over:
            await ws.send_text(json.dumps({"error": over["error"]}))
            await ws.close(code=1013, reason="live budget reached")
            return
    bridge = LiveBridge(ws, voice, facing, handle)
    await bridge.run()
    if counted and bridge.up is None:  # upstream never opened: no session was billed
        live_budget.refund()


# ---------------------------------------------------------------------------------------------
# POST /api/cam/decide

def _context_text(state: dict, with_audio: bool = False) -> str:
    facing = state.get("facing")
    lines = [
        "A live frame from a phone camera app, exactly as the camera sensor sees it (never "
        "mirrored, not even from the selfie camera).",
        "Camera: front (selfie) camera, so the person in frame is probably the user."
        if facing == "user" else "Camera: back camera.",
    ]
    mode, zoom = state.get("mode"), state.get("zoom")
    if mode:
        lines.append(f"Current mode: {mode}" + (f", zoom {float(zoom):.1f}x." if isinstance(zoom, (int, float)) else "."))
    exp = state.get("exposure")
    caps = state.get("caps") or {}
    if isinstance(exp, (int, float)) and abs(exp) >= 0.05 and not caps.get("exposure"):
        lines.append(f"The app already adds {exp:+.1f} EV of exposure compensation to the photo "
                     "(not visible in this frame).")
    if state.get("selfie") or facing == "user":
        lines.append("This is a selfie: someone in the photo holds the phone at arm's length, so camera "
                     "moves are arm moves (raise/lower the phone, extend the arm, tilt, turn).")
    if state.get("intent"):
        sub = state.get("subject")
        lines.append(f"Photo type so far: {state['intent']}" + (f" ({str(sub)[:60]})." if sub else "."))
    keep = [str(k)[:60] for k in (state.get("keep") or []) if k][:8]
    if keep:
        lines.append("Must stay fully in frame (no cropped heads or faces): " + "; ".join(keep) + ".")
    if state.get("scene"):
        lines.append(f"Place-defining scenery to show more of: {str(state['scene'])[:120]}.")
    if state.get("wants"):
        lines.append(f"The user wants: {str(state['wants'])[:200]}")
    if state.get("heard") and not with_audio:  # with a clip, old words would bias `reaction`
        lines.append(f'The user last said: "{str(state["heard"])[:200]}"')
    return "\n".join(lines) + "\n"


DECIDE_QUESTIONS = {
    "move": {
        "type": "choice",
        "instructions": (
            "You are a photographer coaching the person holding this camera. Which single move of "
            "the CAMERA would most improve this photo? Everyone who is part of the shot must end up "
            "fully in frame (no cropped heads or faces), and place-defining scenery (a landmark, a "
            "tree tunnel, a sunset, a view) should be shown more, not traded away. In a selfie the "
            "moves are arm moves. Judge directions on the frame exactly as shown: 'left' means move "
            "the camera left so more of what is beyond the frame's left edge comes in."
        ),
        "criteria": {
            "back": "Move the camera away, or in a selfie extend the arm (zoom out): someone who is part of the shot has a head, face or body cut off at an edge, or the people fill the frame and hide the scenery around them.",
            "closer": "Move the camera toward the subject, or in a selfie bring the phone in: the people or subject are small, with too much empty or distracting space around them, and nobody would get cut off.",
            "down": "Lower the camera or tilt down so more of what is below the BOTTOM edge comes in: the subject is cut off at the bottom (chin, feet, plate) or sits too low, or there is too much empty sky or ceiling above it and no scenery worth showing there.",
            "hold": "Keep the camera where it is: everyone who is part of the shot is fully in frame and the scenery, if any, is shown well.",
            "left": "Pan, step or (in a selfie) swing the arm to the LEFT so more of what is beyond the LEFT edge comes in (everything slides right): someone who is part of the shot is cut off at, or crowded against, the left edge, or the scenery lies to the left.",
            "right": "Pan, step or (in a selfie) swing the arm to the RIGHT so more of what is beyond the RIGHT edge comes in (everything slides left): someone who is part of the shot is cut off at, or crowded against, the right edge, or the scenery lies to the right.",
            "rotate_left": "Roll the camera counter-clockwise: the horizon or other level lines clearly slope UP toward the right side of the frame.",
            "rotate_right": "Roll the camera clockwise: the horizon or other level lines clearly slope DOWN toward the right side of the frame.",
            "up": "Raise the camera or tilt up so more of what is above the TOP edge comes in: a head is cut off at, or crowded against, the top edge, or the place-defining scenery (a landmark, a tree tunnel, a sunset sky) is above the frame or hidden behind the heads; in a selfie, raise the phone and tilt it down a little so the scenery shows above the heads.",
        },
    },
    "ready": {
        "type": "noul",
        "instructions": "Is this frame ready to shoot as a good photo of what the user wants?",
        "criteria": {
            "true_description": "Everyone who is part of the shot is fully in frame (no cropped heads, faces or bodies), the place-defining scenery (if any) shows behind them, and the frame is level, sharp and reasonably exposed; a good photo could be taken right now.",
            "false_description": "The framing, angle, sharpness or exposure should be fixed first, or there is no clear subject.",
        },
    },
    "intent": {
        "type": "choice",
        "instructions": "What kind of photo is the user most likely trying to take?",
        "criteria": {
            "document": "A document, page, receipt, whiteboard or screen to capture flat and readable.",
            "food": "A plate of food or drinks.",
            "group": "Two or more people together as the subject, including group selfies.",
            "landscape": "Scenery or a wide view: sky, mountains, sea, a city or buildings from a distance.",
            "object": "A single thing up close: a product, plant, gadget, artwork or toy.",
            "other": "Anything else, or no clear subject yet.",
            "portrait": "One person (or one pet) as the main subject.",
            "street": "A candid scene of streets, traffic or passers-by.",
        },
    },
    "mode": {
        "type": "choice",
        "instructions": "Which camera mode suits this photo best?",
        "criteria": {
            "macro": "A tiny subject a few centimetres from the lens (an insect, a ring, flower details).",
            "night": "The scene is dark or dimly lit (night outdoors, a dark room) and needs a long, low-noise exposure.",
            "photo": "The standard mode: groups, landscapes, food, documents, street or anything else in normal light.",
            "portrait": "One person or one pet as the main subject at close to medium distance, where a blurred background helps.",
        },
    },
    "exposure": {
        "type": "choice",
        "instructions": "Ignoring composition, how should the brightness of the photo change so the main subject is well exposed?",
        "criteria": {
            "brighter": "Too dark: the subject is underexposed, with murky shadows or dim faces.",
            "darker": "Too bright: blown-out highlights, washed-out faces or sky.",
            "ok": "The brightness is fine, or the scene is dark or bright on purpose and the subject still reads well.",
        },
    },
}

REACTION_QUESTION = {
    "type": "choice",
    "instructions": (
        "In the audio clip of the user's voice, how does the user feel about the current shot or "
        "the coach's last suggestion?"
    ),
    "criteria": {
        "disappointed": "Unhappy or unconvinced: a sigh, 'hmm, no', 'not that', 'I don't like it', a let-down tone.",
        "neutral": "No clear feeling: silence, background noise, or just saying what they want or giving instructions.",
        "pleased": "Happy or approving: 'oh that's good', 'yes, that one', 'perfect', 'love it', an excited or satisfied tone.",
    },
}


@router.post("/api/cam/decide")
async def api_decide(
    frame: UploadFile = File(...),
    audio: UploadFile | None = File(None),
    state: str | None = Form(None),
):
    t0 = time.perf_counter()
    try:
        img = await frame.read()
        if not img:
            raise ValueError("empty frame")
        st = _parse_state(state)
        wav = _trim_wav(await audio.read(), 6.0) if audio is not None else None
        inp = [
            {"type": "text", "text": _context_text(st, bool(wav))},
            {"type": "image", "data": _b64(img), "mime_type": frame.content_type or "image/jpeg", "resolution": "low"},
        ]
        questions = dict(DECIDE_QUESTIONS)
        if wav:
            inp.append({"type": "text", "text": "\nThe last few seconds of the user's voice:\n"})
            inp.append({"type": "audio", "data": _b64(wav), "mime_type": "audio/wav"})
            questions["reaction"] = REACTION_QUESTION
        model = _env("DECIDE_CAM_MODEL", "gemini-decision-1")
        # A ~1 Hz loop: an answer older than a few seconds is useless, and 3 attempts per tick
        # would triple the load on an overloaded backend. p95 is ~0.75 s.
        res = await gemini.decisions(inp, questions, model=model, tag="cam_decide", timeout=6.0, attempts=2)
        return {
            "answers": res.get("answers", {}),
            "model": model,
            "ms": round((time.perf_counter() - t0) * 1000),
            "tokens": (res.get("usage") or {}).get("total_tokens"),
        }
    except ValueError as exc:
        return _err(400, exc)
    except Exception as exc:
        return _err(502, exc)


# ---------------------------------------------------------------------------------------------
# POST /api/cam/understand

UNDERSTAND_SYSTEM = f"""\
You are the brain of a live camera coach: a calm photographer friend helping someone take a \
photo with their phone. You get 1 to 3 recent camera frames (oldest first, about a second \
apart), sometimes a short clip of the user's voice, and the camera state as JSON (it may include \
the coach's last tip and what the user said before).

Fill in:
- heard: what the user said in the audio clip, word for word; "" if there is no audio or no speech.
- reaction: how the user feels about the current shot or the last tip, from their words and \
tone: pleased ("oh that's good", "yes, that one"), disappointed (a sigh, "hmm, no", "not that"), \
or neutral (no clear feeling, or no audio).
- intent: the kind of photo they are taking, inferred from what you see and hear.
- subject: the main subject, at most 4 words.
- selfie: true if this is a selfie (the front camera, or someone in the frame holding the phone \
at arm's length), so camera moves are arm moves.
- keep: every person (and any other real subject) who is part of the shot and must stay fully in \
frame, as short names like "man in sunglasses, centre". All people clearly in the shot; if the \
user asked for one person, just that person.
- scene: the place-defining background worth showing more of (e.g. "cypress tree tunnel and its \
vanishing point", "Eiffel Tower", "sunset over the sea"), or "" if there is none.
- wants: one short phrase describing the photo they are after.
The state's intent, subject and wants come from earlier turns (heard_before and heard are what \
the user said before): keep them unless the user asks for something else or the scene clearly \
changed. "That's good" or a sigh is a reaction, not a new goal.
- tip: what the coach says out loud next: at most 8 words, warm and calm, one concrete action \
(a camera move, a pose, light, or a setting) that follows the framing rules below: in a \
selfie, arm moves ("Raise the phone, tilt down for the tunnel"). If the user sounded disappointed, suggest a \
clearly different approach from the last tip. If they sounded pleased or the shot already \
works, say something like "Hold it there, that's lovely." Use "" when there is nothing new \
worth saying; never repeat the last tip.
- settings: camera changes to make now, only ones that clearly help; {{}} for none. mode: \
"portrait" for one person or pet, "night" when the scene is dark, "macro" for a tiny close-up, \
"photo" otherwise. exposure: absolute EV -2..2; zoom 1..5; warmth -1 (cooler) to 1 (warmer). \
If the tip mentions a setting change, put that change in settings too.

{DIRECTIONS_TEXT}

{FRAMING_TEXT}"""

UNDERSTAND_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "heard": {"type": "STRING"},
        "reaction": {"type": "STRING", "enum": REACTIONS},
        "intent": {"type": "STRING", "enum": INTENTS},
        "subject": {"type": "STRING"},
        "selfie": {"type": "BOOLEAN"},
        "keep": {"type": "ARRAY", "items": {"type": "STRING"},
                 "description": "Everyone who must stay fully in frame, short names."},
        "scene": {"type": "STRING", "description": "Place-defining background to show more of, or ''."},
        "wants": {"type": "STRING"},
        "tip": {"type": "STRING", "description": "At most 8 words, one short sentence."},
        "settings": {
            "type": "OBJECT",
            "properties": {
                "mode": {"type": "STRING", "enum": MODES},
                "zoom": {"type": "NUMBER"},
                "exposure": {"type": "NUMBER"},
                "warmth": {"type": "NUMBER"},
            },
        },
    },
    "required": ["heard", "reaction", "intent", "subject", "selfie", "keep", "scene", "wants", "tip", "settings"],
    "propertyOrdering": ["heard", "reaction", "intent", "subject", "selfie", "keep", "scene", "wants", "tip",
                         "settings"],
}

STATE_KEYS = ("facing", "mode", "zoom", "exposure", "warmth", "intent", "subject", "selfie", "keep", "scene",
              "heard_before", "heard", "wants", "last_tip", "reaction", "voice")


def _clean_settings(s: dict) -> dict:
    out: dict = {}
    if not isinstance(s, dict):
        return out
    if s.get("mode") in MODES:
        out["mode"] = s["mode"]
    for k, lo, hi in (("zoom", 1, 5), ("exposure", -2, 2), ("warmth", -1, 1)):
        if k in s:
            v = _clamp(s[k], lo, hi)
            if v is not None:
                out[k] = round(v, 2)
    return out


def _tip_settings(tip: str, settings: dict) -> dict:
    """The model sometimes says "switching to portrait mode" without setting it: make them agree."""
    m = re.search(r"\b(portrait|night|macro|photo) mode\b", tip.lower())
    if m and not re.search(r"\b(no|not|without|off)\b", tip.lower()):
        settings = {**settings, "mode": m.group(1)}
    return settings


def _tip(text: str) -> str:
    """Keep tips short without cutting a sentence mid-clause: up to 10 words as is, otherwise
    the first clause that ends within 10 words, otherwise the first 8 words."""
    words = str(text or "").strip().split()
    if len(words) <= 10:
        return " ".join(words)
    for i in range(min(10, len(words)) - 1, 0, -1):
        if words[i][-1] in ",.;:!?":
            return " ".join(words[: i + 1]).rstrip(",;:") + ("" if words[i][-1] in ".!?" else ".")
    return " ".join(words[:8])


def _words(text: str, n: int) -> str:
    w = str(text or "").strip().split()
    return " ".join(w[:n])


@router.post("/api/cam/understand")
async def api_understand(
    frames: list[UploadFile] = File(...),
    audio: UploadFile | None = File(None),
    state: str | None = Form(None),
):
    t0 = time.perf_counter()
    try:
        imgs = [b for b in [await f.read() for f in frames[-3:]] if b]
        if not imgs:
            raise ValueError("no frames")
        st = _parse_state(state)
        wav = _trim_wav(await audio.read(), 10.0) if audio is not None else None
        slim = {k: st[k] for k in STATE_KEYS if st.get(k) not in (None, "")}
        parts: list[dict] = [{"text": "Camera state: " + json.dumps(slim)[:1500]}]
        for i, b in enumerate(imgs):
            parts.append({"text": f"Frame {i + 1} of {len(imgs)}:"})
            parts.append({"inlineData": {"mimeType": "image/jpeg", "data": _b64(b)}})
        if wav:
            parts.append({"text": "The user's voice (their last utterance):"})
            parts.append({"inlineData": {"mimeType": "audio/wav", "data": _b64(wav)}})
        else:
            parts.append({"text": "No audio this time: heard is \"\" and reaction is neutral."})
        model = _env("UNDERSTAND_MODEL", "gemini-4-hydrogen")
        # gemini.generate raises GeminiError (-> 502) on no text or non-JSON, like before.
        out = (await gemini.generate(
            model, parts, schema=UNDERSTAND_SCHEMA, system=UNDERSTAND_SYSTEM,
            thinking=_env("UNDERSTAND_THINKING", "low"), media_resolution="low",
            tag="cam_understand", timeout=30.0,
        )).data
        if not isinstance(out, dict):
            raise gemini.GeminiError(f"understand: expected a JSON object from {model}", 200)
        return {
            "intent": out.get("intent") if out.get("intent") in INTENTS else "other",
            "subject": _words(out.get("subject"), 4),
            "selfie": bool(out.get("selfie")),
            "keep": [_words(k, 8) for k in (out.get("keep") or []) if str(k).strip()][:8],
            "scene": _words(out.get("scene"), 14),
            "heard": str(out.get("heard") or "").strip() if wav else "",
            "reaction": out.get("reaction") if (wav and out.get("reaction") in REACTIONS) else "neutral",
            "wants": str(out.get("wants") or "").strip()[:200],
            "tip": _tip(out.get("tip")),
            "settings": _tip_settings(_tip(out.get("tip")), _clean_settings(out.get("settings") or {})),
            "model": model,
            "ms": round((time.perf_counter() - t0) * 1000),
        }
    except ValueError as exc:
        return _err(400, exc)
    except Exception as exc:
        return _err(502, exc)


# ---------------------------------------------------------------------------------------------
# POST /api/cam/director: Gemini 4 studies the newest frame and plans the next step. The phone
# runs it back to back (one in flight) and folds the answer into its next Live [tick], so the
# voice coach (Gemini Live) acts on a stronger model's composition judgement.

DIRECTOR_SYSTEM = f"""\
You are Director, an expert photographer studying one live camera frame from a phone. The \
user is composing a photo right now; a voice coach will relay your plan in a few words. Judge \
the frame exactly as you see it, never mirrored.

Return:
- subject: the ONE thing the photo is of, at most 4 words ("soda can", "friend by the window"). \
On a cluttered surface the subject is the object the camera is centred on or that stands out, \
not the clutter.
- intent: the kind of photo.
- new_shot: true if the subject or place is clearly different from the state's last_subject \
(the phone now points at something else). False if it is the same subject reframed (closer, \
lower, another angle), and false when last_subject is empty.
- score: 0-10, how good this frame is as a photo of the subject right now.
- issues: at most 3 short phrases, the most important first, only real problems (cut-off \
subject, clutter behind or around it, subject too small, tilted horizon, subject not \
separated from the background, too dark, blown highlights).
- move, strength: the ONE camera move that fixes the first issue, or "hold" when the framing \
works. Object on a table seen from above or far away: "closer" first, then "down" (lower the \
phone to the object's height so a wall or far room is behind it, not the table clutter).
- mode: the capture mode that suits this subject: "portrait" for one person, a pet or a single \
object 0.3-2 m away with a busy background (the app records depth so the background can be \
blurred later), "night" when the scene is dark, "macro" for something a few cm away, "photo" \
otherwise.
- ready: true when the essentials are right (subject clear and whole, nothing messy crossing \
or crowding it, placed well, level, exposure fine). Do not chase perfection: a score of 6 or \
more with the subject clear and whole is ready (a busy background is fine; it gets blurred from \
depth after the shot). Never ask for "back" unless a person or the subject is cut off at an edge. Keep ready true for a frame that still matches the last \
ready framing.
- tip: what the coach should say next, at most 8 words, warm, one concrete action \
("Closer, and drop to the can's height."). When ready just became true: "That's it, take it." \
Use "" when the state's last_tip already says the same thing.

{DIRECTIONS_TEXT}

{FRAMING_TEXT}"""

DIRECTOR_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "subject": {"type": "STRING"},
        "intent": {"type": "STRING", "enum": INTENTS},
        "new_shot": {"type": "BOOLEAN"},
        "issues": {"type": "ARRAY", "items": {"type": "STRING"}},
        "move": {"type": "STRING", "enum": MOVES},
        "strength": {"type": "STRING", "enum": ["small", "medium", "large"]},
        "mode": {"type": "STRING", "enum": MODES},
        "score": {"type": "INTEGER"},
        "ready": {"type": "BOOLEAN"},
        "tip": {"type": "STRING"},
    },
    "required": ["subject", "intent", "new_shot", "issues", "move", "strength", "mode", "score", "ready", "tip"],
    "propertyOrdering": ["subject", "intent", "new_shot", "issues", "move", "strength", "mode", "score", "ready",
                         "tip"],
}

DIRECTOR_STATE_KEYS = ("mode", "state_line", "last_subject", "last_intent", "last_move", "last_tip", "ready",
                       "scene_shift", "heard", "facing")


@router.post("/api/cam/director")
async def api_director(frame: UploadFile = File(...), state: str | None = Form(None)):
    t0 = time.perf_counter()
    try:
        img = await frame.read()
        if not img:
            raise ValueError("empty frame")
        st = _parse_state(state)
        # The phone sends its current subject/intent as `subject`/`intent`; the prompt calls them last_*.
        for k in ("subject", "intent"):
            if st.get(k) and not st.get("last_" + k):
                st["last_" + k] = st[k]
        slim = {k: st[k] for k in DIRECTOR_STATE_KEYS if st.get(k) not in (None, "")}
        parts: list[dict] = [
            {"text": "Camera state: " + json.dumps(slim)[:1500]},
            {"inlineData": {"mimeType": "image/jpeg", "data": _b64(img)}},
        ]
        model = _env("DIRECTOR_MODEL", "gemini-4-hydrogen")
        out = (await gemini.generate(
            model, parts, schema=DIRECTOR_SCHEMA, system=DIRECTOR_SYSTEM,
            thinking=_env("DIRECTOR_THINKING", "low"), media_resolution=_env("DIRECTOR_MEDIA", "low"),
            tag="cam_director", timeout=15.0, attempts=1,
        )).data
        if not isinstance(out, dict):
            raise gemini.GeminiError(f"director: expected a JSON object from {model}", 200)
        score = _clamp(out.get("score"), 0, 10)
        return {
            "subject": _words(out.get("subject"), 4),
            "intent": out.get("intent") if out.get("intent") in INTENTS else "other",
            "new_shot": bool(out.get("new_shot")) and bool(st.get("last_subject")),
            "issues": [_words(i, 10) for i in (out.get("issues") or []) if str(i).strip()][:3],
            "move": out.get("move") if out.get("move") in MOVES else "hold",
            "strength": out.get("strength") if out.get("strength") in ("small", "medium", "large") else "medium",
            "mode": out.get("mode") if out.get("mode") in MODES else "photo",
            "score": int(score) if score is not None else 0,
            "ready": bool(out.get("ready")),
            "tip": _tip(out.get("tip")),
            "model": model,
            "ms": round((time.perf_counter() - t0) * 1000),
        }
    except ValueError as exc:
        return _err(400, exc)
    except Exception as exc:
        return _err(502, exc)


# ---------------------------------------------------------------------------------------------
# POST /api/cam/say

_tts_cache: OrderedDict[tuple[str, str, str], bytes] = OrderedDict()


@router.post("/api/cam/say")
async def api_say(body: dict):
    text = " ".join(str(body.get("text") or "").split())[:300]
    if not text:
        return JSONResponse({"error": "text is required"}, status_code=400)
    voice = str(body.get("voice") or _env("TTS_VOICE", "Kore"))[:40]
    model = _env("TTS_MODEL", "gemini-3.8-flash-lite-tts")
    key = (model, voice, text.lower())
    t0 = time.perf_counter()
    wav = _tts_cache.get(key)
    if wav is None:
        try:
            # WAV (raw 24 kHz PCM wrapped) via gemini.tts: retries, log line, stats.
            wav = await gemini.tts(text, voice, model=model, tag="cam_say", timeout=20.0)
        except Exception as exc:
            return _err(502, exc)
        _tts_cache[key] = wav
        while len(_tts_cache) > 128:
            _tts_cache.popitem(last=False)
    else:
        _tts_cache.move_to_end(key)
    ms = round((time.perf_counter() - t0) * 1000)
    return Response(wav, media_type="audio/wav", headers={"X-TTS-Ms": str(ms), "X-TTS-Model": model,
                                                           "Access-Control-Expose-Headers": "X-TTS-Ms, X-TTS-Model"})
