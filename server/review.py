"""Instant post-capture review: POST /api/review as Server-Sent Events (docs/CORE_API.md §5).

Ported from experiments/review/review.py (design and benchmarks: experiments/review/REPORT.md).
The phone posts a <=1024 px JPEG and its live-session context right after the shutter. Core
re-encodes it once (EXIF-upright, mirrored for selfies so left/right match what the user saw,
long side 1024) and starts two calls at once on the same bytes:

  ~0.6 s  event decision    Gemini Decision 1: calibrated verdict (keeper >= 0.6, retake >= 0.45),
                            its probabilities and, when confident, one templated card (never a
                            rotation). `card` is null when the worded card already went out.
  ~1.1 s  event suggestion  gemini-3.5-flash-lite, streamed (`streamGenerateContent?alt=sse`,
                            responseSchema): the first card, sent as soon as its object closes.
  ~1.2 s  event final       {verdict, suggestions [1..3 cards], working, speak, source, ...}
  ~5 s    event refined     optional (context `refine: true` or env REVIEW_REFINE=1):
                            gemini-4-hydrogen, same shape plus `changed`.
          event done        always last: {review_id, ms, saved, errors?}.

Hard deadlines: Decision 3 s, Flash 4 s, refine 12 s, and an overall stream deadline on top, so
the stream always ends with `done`. If Flash fails or is late the Decision card stays (or the
streamed first card, if it already went out); if both fail, `final` has no suggestions and
`errors` says why. Card: {action <=8 words, why <=10 words, kind, direction, priority, speak}.

Persistence: with `shot_id` in the context the final (then refined) review is written to
library/<id>/review.json and the record gets `assets.review` (broadcast on /api/events). Every
review is also remembered by `review_id` (from the context, or generated and returned) so the
shot upload can claim it later: `review.attach(shot_id, review_id)`.

Every Gemini call goes through gemini.py's pooled client and stats (tags review_decide, review,
review_refine); the streamed call uses `stream_generate` below (gemini.py has no streaming
helper) with the same retry policy before the first byte, inside the hard deadline.
"""

from __future__ import annotations

import asyncio
import io
import json
import logging
import os
import random
import re
import secrets
import time
from collections import OrderedDict
from datetime import datetime, timezone
from typing import AsyncIterator, Awaitable, Callable

import httpx
from fastapi import APIRouter, File, Form, UploadFile
from fastapi.responses import JSONResponse, StreamingResponse

import gemini
import shots

router = APIRouter()
log = gemini.log.getChild("review")  # same stderr handler/format as the per-call lines

GEN_MODEL = os.environ.get("REVIEW_MODEL", "gemini-3.5-flash-lite")
REFINE_MODEL = "gemini-4-hydrogen"
DECISION_MODEL = "gemini-decision-1"
LONG_SIDE = 1024
GEN_TIMEOUT_S = 4.0       # Flash-Lite p95 was 1.5 s; past 4 s the moment has passed
REFINE_TIMEOUT_S = 12.0
DECISION_TIMEOUT_S = 3.0
SLACK_S = 1.0             # overall stream deadline = the slowest call's deadline + this
MAX_IMAGE = 20 * 1024 * 1024
MAX_CONTEXT = 16 * 1024
RECENT = 64               # reviews remembered by review_id for a later attach()
REVIEW_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
SETTING_KEYS = ("mode", "lens", "zoom", "iso", "shutter", "ev", "flash")

KINDS = ["move", "angle", "light", "timing", "setting", "subject"]
DIRECTIONS = ["left", "right", "up", "down", "closer", "back", "rotate_left", "rotate_right", "none"]
VERDICTS = ["keeper", "almost", "retake"]

# Gemini 4 rejects "minimal" and ignores thinkingBudget; 3.8 Flash rejects "minimal".
THINKING = {"gemini-4": "low", "gemini-3.8-flash": "low", "gemini-3.5-flash": "minimal"}


def thinking_for(model: str) -> str:
    for prefix, level in THINKING.items():
        if model.startswith(prefix):
            return level
    return "low"


# ---------------------------------------------------------------------------------------------
# Context and image prep.

def _num(v) -> float | None:
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _strs(v, n: int, width: int) -> list[str]:
    if isinstance(v, str):
        v = [v]
    if not isinstance(v, list):
        return []
    return [str(x)[:width] for x in v if x not in (None, "")][:n]


def clean_context(raw) -> dict:
    """The phone's context with types coerced (bad fields dropped, never an error)."""
    ctx = raw if isinstance(raw, dict) else {}
    out = {k: ctx[k] for k in ("facing", "intent", "subject", "scene", "heard", "shot_id", "review_id")
           if isinstance(ctx.get(k), str) and ctx[k]}
    out.update({k: True for k in ("selfie", "mirrored", "refine") if ctx.get(k) in (True, 1, "1", "true")})
    out["keep"] = _strs(ctx.get("keep"), 8, 60)
    coach = ctx.get("coach")
    out["coach"] = _strs(coach[-3:] if isinstance(coach, list) else coach, 3, 60)
    # capture settings: nested `settings`, or top-level like the shot meta (CORE_API.md §3)
    settings = ctx.get("settings") if isinstance(ctx.get("settings"), dict) else \
        {k: ctx[k] for k in SETTING_KEYS if ctx.get(k) not in (None, "")}
    if settings:
        out["settings"] = {k: v for k, v in settings.items() if k in SETTING_KEYS and isinstance(v, (str, int, float))}
    return out


def is_selfie(ctx: dict) -> bool:
    return bool(ctx.get("selfie")) or ctx.get("facing") == "front"


def needs_mirror(ctx: dict) -> bool:
    """Front-camera JPEGs are saved unmirrored (iOS default) but were framed on a mirrored
    preview: review them mirrored so left/right and clockwise match what the user saw. Set
    context["mirrored"] = true if the app already saved the mirrored version."""
    return is_selfie(ctx) and not ctx.get("mirrored")


def prepare_jpeg(data: bytes, mirror: bool, long_side: int = LONG_SIDE, quality: int = 85) -> bytes:
    """EXIF-upright RGB JPEG, long side <= `long_side`, optionally mirrored. Done once per review
    (both calls share the bytes). Raises ValueError if undecodable."""
    from PIL import Image, ImageOps

    try:
        im = Image.open(io.BytesIO(data))
        im.draft("RGB", (long_side, long_side))
        im = ImageOps.exif_transpose(im).convert("RGB")
    except Exception as exc:
        raise ValueError(f"could not decode image: {exc}") from exc
    if mirror:
        im = ImageOps.mirror(im)
    im.thumbnail((long_side, long_side), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=quality)
    return buf.getvalue()


# ---------------------------------------------------------------------------------------------
# The generated review. Static system instruction first (byte-stable: the cacheable prefix),
# then the image, then the per-shot context last.

SYSTEM = """\
You are a photographer friend looking at the photo the user JUST took on their phone. In one \
glance, tell them what to change for the NEXT shot: 1 to 3 suggestions, most important first.

Read the live-session context below the photo: intent, subject, the people/things to keep, the \
scenery to show, what the user said, and the camera settings. That is what they were trying to \
capture. If the context is vague or empty, infer the goal from the photo. If the context and \
the photo disagree, trust the photo, but serve the goal.

Rules:
- Every suggestion is ONE physical or camera instruction, imperative, at most 8 words, sized \
and concrete: "Take half a step back", "Crouch to chest height", "Tilt down about 10 degrees", \
"Rotate the phone 5 degrees clockwise", "Zoom back to 1x", "Tap her face, slide exposure up", \
"Wait for the walker to pass". Never vague ("adjust the framing", "consider", "try to").
- Keep every person or thing in "keep" fully in frame. Never suggest a move that would cut \
one of them off, and fix any that is already cut (a head at the top edge, feet, a plate, a \
sign) first.
- Which way: cut off at the TOP edge -> tilt up or step back (never down); cut off at the \
BOTTOM edge -> tilt down or step back (never up); at the left or right edge -> move toward \
that side or step back. Too much empty sky -> tilt down. Too much empty foreground (pavement, \
ground, table) -> step closer or tilt up. Never combine moves that undo each other.
- Only name problems you can clearly see. If the photo already works, the verdict is keeper \
and the one suggestion is an optional variation.
- Respect the scene: show more of the place-defining scenery, never trade it away.
- Selfie (front camera): the photo is shown mirrored, exactly as the user saw it on screen. \
Moves are arm moves ("Hold the phone higher, tilt it down", "Stretch your arm out further"), \
not steps.
- Directions are camera moves on the frame as shown: "left" = move or pan the camera left so \
more of what is beyond the left edge comes in. If the horizon slopes UP toward the right, \
the fix is counter-clockwise (rotate_left); slopes DOWN toward the right: clockwise \
(rotate_right).
- Don't repeat a setting already in place (Portrait when mode is portrait, 1x when zoom is 1).
- why: at most 10 words, the visible reason, specific to this photo ("his head touches the \
top edge", "the sun is behind them, faces are dark").
- kind: move (step closer/back/left/right), angle (height, tilt, roll/level), light (turn the \
subject to the light, move into shade, avoid backlight), timing (wait for a passer-by or \
wave, catch the moment, burst), setting (exposure, focus, zoom/lens, Portrait/Night mode, \
flash), subject (direct the people: squeeze in, chin down, look at the lens; or tidy the \
scene: move the clutter).
- direction: the arrow to show: left/right/up/down/closer/back for moves and height/tilt \
(up = raise or tilt up, down = lower or tilt down), rotate_left/rotate_right for leveling, \
none for light, timing, setting and subject.
- priority: 1 for the first suggestion, then 2, 3.
- verdict: keeper = good as it is; almost = one quick fix away; retake = a real problem \
(someone to keep is cut off, crooked, too dark, blurred, the subject is lost or a stranger \
is in the way).
- working: one specific thing that is good about this photo, at most 10 words.
Plain words, warm and brief, like a friend standing next to them."""

SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "verdict": {"type": "STRING", "enum": VERDICTS},
        "suggestions": {
            "type": "ARRAY", "minItems": 1, "maxItems": 3,
            "items": {
                "type": "OBJECT",
                "properties": {
                    "action": {"type": "STRING", "description": "Imperative, at most 8 words, sized."},
                    "why": {"type": "STRING", "description": "At most 10 words."},
                    "kind": {"type": "STRING", "enum": KINDS},
                    "direction": {"type": "STRING", "enum": DIRECTIONS},
                    "priority": {"type": "INTEGER"},
                },
                "required": ["action", "why", "kind", "direction", "priority"],
                "propertyOrdering": ["action", "why", "kind", "direction", "priority"],
            },
        },
        "working": {"type": "STRING", "description": "At most 10 words."},
    },
    "required": ["verdict", "suggestions", "working"],
    "propertyOrdering": ["verdict", "suggestions", "working"],
}


def _fmt_settings(s: dict) -> str:
    bits = []
    if s.get("mode"):
        bits.append(f"mode {s['mode']}")
    if s.get("lens") or s.get("zoom"):
        bits.append(f"lens {s.get('lens', '?')} {s.get('zoom', 1)}x")
    if s.get("iso"):
        bits.append(f"ISO {s['iso']}")
    sh = _num(s.get("shutter"))
    if sh:
        bits.append(f"1/{round(1 / sh)} s" if 0 < sh < 1 else f"{sh} s")
    ev = _num(s.get("ev"))
    if ev is not None:
        bits.append(f"EV {ev:+.1f}")
    if s.get("flash"):
        bits.append(f"flash {s['flash']}")
    return ", ".join(bits)


def context_text(ctx: dict) -> str:
    """The per-shot context as short lines (goes LAST in the request)."""
    keep = ctx.get("keep") or []
    lines = ["Live-session context at capture (may be incomplete):",
             f"- camera: {ctx.get('facing') or 'back'}"
             f"{' (selfie, shown as the user saw it: moves are arm moves)' if is_selfie(ctx) else ''}",
             f"- intent: {ctx.get('intent') or 'unknown'}",
             f"- subject: {str(ctx.get('subject') or '')[:60] or 'unknown'}",
             "- keep fully in frame: " + ("; ".join(keep) if keep else "(not given: everyone who is part of the shot)"),
             f"- scenery to show: {str(ctx.get('scene') or '')[:100] or '(none given)'}",
             f"- the user said: \"{str(ctx.get('heard'))[:200]}\"" if ctx.get("heard") else "- the user said: (nothing)"]
    if ctx.get("coach"):
        lines.append("- coach already said: " + " / ".join(ctx["coach"]))
    if ctx.get("settings"):
        lines.append("- settings: " + _fmt_settings(ctx["settings"]))
    return "\n".join(lines)


def _first_object(text: str, key: str = '"suggestions"') -> dict | None:
    """The first complete object inside the streamed `suggestions` array, or None yet."""
    i = text.find(key)
    if i < 0:
        return None
    j = text.find("{", text.find("[", i))
    if j < 0:
        return None
    depth, in_str, esc = 0, False, False
    for k in range(j, len(text)):
        ch = text[k]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(text[j:k + 1])
                except ValueError:
                    return None
    return None


def _clip_words(s, n: int) -> str:
    return " ".join(str(s or "").strip().split()[:n]).rstrip(",;")


def speak(card: dict | None) -> str:
    """What the coach says out loud for a card: the action and its reason."""
    if not card or not card.get("action"):
        return ""
    action, why = card["action"].rstrip("."), (card.get("why") or "").rstrip(".")
    return f"{action}. {why[:1].upper() + why[1:]}." if why else f"{action}."


def _card(s: dict, priority: int) -> dict:
    kind = s.get("kind") if s.get("kind") in KINDS else "move"
    direction = s.get("direction") if s.get("direction") in DIRECTIONS else "none"
    if kind in ("light", "timing", "setting", "subject"):
        direction = "none"  # the arrow is for camera moves only
    card = {"action": _clip_words(s.get("action"), 8), "why": _clip_words(s.get("why"), 10),
            "kind": kind, "direction": direction, "priority": priority}
    card["speak"] = speak(card)
    return card


def normalize(obj: dict) -> dict:
    """Clamp a generated review to the contract (enums, word limits, 1-3 items, priorities)."""
    obj = obj if isinstance(obj, dict) else {}
    cards = []
    for s in (obj.get("suggestions") or [])[:3]:
        if isinstance(s, dict) and s.get("action"):
            cards.append(_card(s, len(cards) + 1))
    verdict = obj.get("verdict") if obj.get("verdict") in VERDICTS else "almost"
    return {"verdict": verdict, "suggestions": cards, "working": _clip_words(obj.get("working"), 10)}


# ---------------------------------------------------------------------------------------------
# Streamed generateContent through gemini.py's pooled client and stats.

def _err_text(r: httpx.Response) -> str:
    try:
        err = r.json().get("error", {})
        msg = err.get("message", err) if isinstance(err, dict) else err
    except Exception:  # noqa: BLE001
        msg = r.text
    return " ".join(str(msg).split())[:300]


async def stream_generate(model: str, body: dict, *, tag: str, timeout: float,
                          on_text: Callable[[str], Awaitable[None] | None] | None = None) -> tuple[str, dict]:
    """POST models/{model}:streamGenerateContent?alt=sse; returns (full non-thought text, usage).

    `on_text(text_so_far)` runs after every chunk. One hard deadline (`timeout`) covers the
    whole call; 429/5xx and network errors are retried with gemini.py's backoff only before the
    first byte and only while at least gemini.MIN_ATTEMPT_S is left. Recorded in gemini's stats
    (GET /api/stats) and logged like gemini.post. Raises gemini.GeminiError."""
    url = f"{gemini.API}/models/{model}:streamGenerateContent?alt=sse"
    payload = json.dumps(body, separators=(",", ":")).encode()
    kb = len(payload) / 1024
    headers = {"x-goog-api-key": gemini.api_key(), "content-type": "application/json"}
    t0 = time.perf_counter()
    deadline = time.monotonic() + timeout
    text, usage, retries, status, err = "", {}, 0, 0, "deadline exceeded"

    async def attempt() -> httpx.Response:
        nonlocal text, usage, status
        async with gemini.http().stream("POST", url, content=payload, headers=headers) as r:
            status = r.status_code
            if status != 200:
                await r.aread()
                return r
            async for line in r.aiter_lines():
                if not line.startswith("data:"):
                    continue
                chunk = json.loads(line[5:])
                usage = chunk.get("usageMetadata") or usage
                piece = "".join(p.get("text", "") for c in chunk.get("candidates") or []
                                for p in (c.get("content") or {}).get("parts") or [] if not p.get("thought"))
                if piece:
                    text += piece
                    if on_text:
                        res = on_text(text)
                        if asyncio.iscoroutine(res):
                            await res
            return r

    for n in range(gemini.MAX_ATTEMPTS):
        try:
            r = await asyncio.wait_for(attempt(), deadline - time.monotonic())
            if status == 200:
                err = ""
                break
            err = f"Gemini HTTP {status} ({model}): {_err_text(r)}"
            if status not in gemini.RETRY_STATUS:
                break
        except (httpx.TransportError, asyncio.TimeoutError, ValueError) as exc:
            if isinstance(exc, ValueError):  # a malformed SSE line
                status = 200
            err = f"Gemini {type(exc).__name__} ({model}): {exc}".rstrip(": ")
            if isinstance(exc, asyncio.TimeoutError):
                err = f"Gemini timeout ({model}) after {timeout:g} s" + (" mid-stream" if text else "")
        if text or n == gemini.MAX_ATTEMPTS - 1:
            break  # never retry once bytes went to the caller
        backoff = min(gemini.BACKOFF_MAX_S, gemini.BACKOFF_BASE_S * 2 ** n)
        wait = random.uniform(backoff / 2, backoff)
        if time.monotonic() + wait + gemini.MIN_ATTEMPT_S > deadline:
            break
        retries += 1
        log.warning("retry tag=%s model=%s status=%s attempt=%d wait_ms=%d err=%s",
                    tag, model, status, n + 1, wait * 1000, err[:120])
        await asyncio.sleep(wait)
    ms = (time.perf_counter() - t0) * 1000
    u = {"input": usage.get("promptTokenCount", 0), "output": usage.get("candidatesTokenCount", 0),
         "thought": usage.get("thoughtsTokenCount", 0), "cached": usage.get("cachedContentTokenCount", 0)}
    if err:
        gemini.record(model, tag, ms, ok=False, usage=u, retries=retries, error=err, kb=kb)
        log.warning("call tag=%s model=%s status=%s ms=%d retries=%d kb=%.0f stream=1 error=%s",
                    tag, model, status or "net", ms, retries, kb, err[:200])
        raise gemini.GeminiError(err, status)
    gemini.record(model, tag, ms, usage=u, retries=retries, kb=kb)
    log.info("call tag=%s model=%s status=200 ms=%d in=%s out=%s thought=%s cached=%s retries=%d kb=%.0f stream=1",
             tag, model, ms, u["input"], u["output"], u["thought"], u["cached"], retries, kb)
    return text, u


async def generate_review(b64img: str, ctx: dict, *, model: str, media_resolution: str, timeout: float,
                          tag: str, on_first: Callable[[dict], None] | None = None) -> dict:
    """The worded review (normalized). `on_first(raw_suggestion)` fires once, as soon as the first
    suggestion object is complete in the stream."""
    body = {
        "systemInstruction": {"parts": [{"text": SYSTEM}]},
        "contents": [{"role": "user", "parts": [gemini.image_part(b64img), {"text": context_text(ctx)}]}],
        "generationConfig": {
            "responseMimeType": "application/json", "responseSchema": SCHEMA,
            "thinkingConfig": {"thinkingLevel": thinking_for(model)},
            "mediaResolution": f"MEDIA_RESOLUTION_{media_resolution.upper()}",
            "temperature": 0.4,
        },
    }
    fired = False

    def watch(text: str) -> None:
        nonlocal fired
        if not fired and on_first:
            obj = _first_object(text)
            if obj is not None:
                fired = True
                on_first(obj)

    text, _usage = await stream_generate(model, body, tag=tag, timeout=timeout, on_text=watch)
    try:
        raw = json.loads(text)
    except ValueError:
        raise gemini.GeminiError(f"non-JSON review ({model}): {text[:120]}", 200) from None
    return normalize(raw)


# ---------------------------------------------------------------------------------------------
# Gemini Decision 1: calibrated verdict + one confident move from a fixed menu, worded from
# templates. Measured: verdict right on 12/13 shots; a move card on ~5/13, right on 4/5.
# Its horizon/rotate answers were wrong on every tilted shot, so rotations are never shown.

_KEEP_RULE = ("Everyone and everything the user wants to keep must end up fully in frame, and "
              "place-defining scenery should be shown more, not traded away. In a selfie, camera "
              "moves are arm moves. Directions are camera moves on the frame as shown.")

ACTIONS = {  # id: (criterion, kind, direction)
    "hold": ("Nothing important to fix: everyone to keep is fully in frame, the frame is level, sharp and well exposed, and the scenery shows.", "move", "none"),
    "step_back": ("Move the camera farther away (selfie: stretch the arm out; or zoom out): someone or something to keep is cut off at an edge (a head, feet, a plate, a sign), or fills the frame so the scene around it is lost.", "move", "back"),
    "step_closer": ("Move the camera closer (selfie: bring the phone in; or zoom in): the subject is small, with lots of empty or distracting space around it, and nobody to keep would be cut off.", "move", "closer"),
    "move_left": ("Shift or pan the camera LEFT so more of what is beyond the LEFT edge comes in: something to keep is cut off or crowded at the left edge, or the subject should sit off-centre to the right, or the scenery lies to the left.", "move", "left"),
    "move_right": ("Shift or pan the camera RIGHT so more of what is beyond the RIGHT edge comes in: something to keep is cut off or crowded at the right edge, or a stranger or half-person at the left edge should leave the frame, or the scenery lies to the right.", "move", "right"),
    "aim_up": ("Raise the camera or tilt it up so more of what is above the TOP edge comes in: a head or the top of the subject is cut off at the top edge, the place-defining scenery is above the frame or hidden behind heads, or there is too much empty ground in the foreground.", "angle", "up"),
    "aim_down": ("Lower the camera or tilt it down so more of what is below the BOTTOM edge comes in: the subject is cut off at the bottom (a chin, a plate, feet), or there is too much empty sky or ceiling above it.", "angle", "down"),
    "shoot_from_above": ("Hold the phone higher and shoot straight down: a flat subject (food on a table, a document, a sign, a map) is shot at a slant or with its far side receding.", "angle", "up"),
    "get_lower": ("Crouch and shoot from lower: standing people look squat because the camera is above their eye line, or a low subject (a pet, a child) needs its own eye level.", "angle", "down"),
    "rotate_left": ("Roll the camera counter-clockwise: the horizon or other level lines clearly slope UP toward the right side of the frame.", "angle", "rotate_left"),
    "rotate_right": ("Roll the camera clockwise: the horizon or other level lines clearly slope DOWN toward the right side of the frame.", "angle", "rotate_right"),
    "wait": ("Wait a moment and shoot again: a passer-by, car or stranger is in the frame, someone is mid-blink, looking away or half-hidden, or a wave or the light is about to get better.", "timing", "none"),
    "face_light": ("Turn the subject toward the light, or swap sides with them: faces are in shadow or backlit (the sun is behind them) while the scene is bright.", "light", "none"),
    "brighter": ("Raise the exposure (tap the face, slide up): the subject is clearly too dark or murky.", "setting", "none"),
    "darker": ("Lower the exposure (expose for the sky): the sky or highlights are blown out to white.", "setting", "none"),
    "portrait_mode": ("Switch to Portrait mode: one person or object at close to medium distance with a busy background that blur would help, and the camera is not in portrait mode already.", "setting", "none"),
    "squeeze_in": ("Direct the people: someone is hidden behind another person or squeezed out, or the group has gaps; ask them to squeeze in or shift.", "subject", "none"),
    "tidy": ("Move the clutter: empty packaging, bottles, bags or other distracting objects sit in the frame next to the subject.", "subject", "none"),
}

WORKING = {
    "everyone_in": "Everyone's fully in the frame",
    "scenery": "The backdrop really shows where you are",
    "light": "Lovely light on the faces",
    "expressions": "Real, happy expressions",
    "composition": "Clean, balanced composition",
    "sharp": "Sharp and clearly readable",
    "moment": "A genuine candid moment",
}

DECISION_QUESTIONS = {
    "verdict": {
        "type": "choice",
        "instructions": "You are a photographer reviewing the photo the user just took, given what they were trying to capture. " + _KEEP_RULE + " How good is it?",
        "criteria": {
            "keeper": "Good as it is: what the user wanted is captured, everyone to keep is fully in frame, level, sharp and well exposed.",
            "almost": "Close: one small fix (a small move, a little exposure, a nudge of the angle) would make it right.",
            "retake": "A real problem: someone or something to keep is cut off, the frame is crooked, too dark or too bright, blurred, a stranger blocks it, or the subject is lost.",
        },
    },
    "next": {
        "type": "choice",
        "instructions": "Which single change would most improve the NEXT shot? " + _KEEP_RULE,
        "criteria": {k: v[0] for k, v in ACTIONS.items()},
    },
    "size": {
        "type": "choice",
        "instructions": "If the camera has to move, roll or tilt to fix this photo, how big is the change?",
        "criteria": {
            "small": "A nudge: half a step, a few degrees, a little higher or lower.",
            "medium": "About one step, about ten degrees, or from standing to crouching.",
            "large": "Two or more steps, a big change of height or angle.",
        },
    },
    "working": {
        "type": "choice",
        "instructions": "What is the best thing about this photo?",
        "criteria": {
            "everyone_in": "Everyone who is part of the shot is fully in frame.",
            "scenery": "The place-defining scenery (a view, a landmark, a sunset) shows well.",
            "light": "The light on the subject is flattering.",
            "expressions": "Faces and expressions are genuine and happy.",
            "composition": "The composition is clean and balanced.",
            "sharp": "The subject is sharp and clearly readable.",
            "moment": "It captures a genuine candid moment.",
        },
    },
}

STEP = {"small": "half a step", "medium": "one step", "large": "a few steps"}
KEEPER_P, RETAKE_P, MOVE_P = 0.6, 0.45, 0.25  # calibrated on the 13-shot set (REPORT.md)
NEVER_SHOW = {"hold", "rotate_left", "rotate_right"}


def _template(action: str, size: str, selfie: bool, settings: dict) -> tuple[str, str]:
    """(action <= 8 words, why <= 10 words) for a menu choice."""
    step = STEP.get(size, "one step")
    if action == "step_back":
        if selfie:
            return "Stretch your arm out further", "something you want is cut off"
        if (_num(settings.get("zoom")) or 1) > 1.05:
            return "Zoom back out to 1x", "something you want is cut off"
        return f"Take {step} back", "something you want is cut off"
    if action == "step_closer":
        return ("Bring the phone a bit closer" if selfie else f"Take {step} closer"), "the subject is small in the frame"
    if action in ("move_left", "move_right"):
        side = "left" if action == "move_left" else "right"
        return (f"Swing the phone a little {side}" if selfie else f"Step {step} to the {side}"), f"there's more to include on the {side}"
    if action == "aim_up":
        return ("Hold the phone higher, tilt it down" if selfie else "Tilt up a little"), "more of what's above should show"
    if action == "aim_down":
        return ("Lower the phone a little" if selfie else "Tilt down a little"), "the bottom is cut or sky is empty"
    if action == "shoot_from_above":
        return "Hold the phone overhead, shoot straight down", "a flat subject reads best from above"
    if action == "get_lower":
        return "Crouch to chest height", "a lower angle flatters the subject"
    if action == "wait":
        return "Wait a moment, then shoot again", "someone's in the way or not ready"
    if action == "face_light":
        return "Turn them to face the light", "their faces are in shadow"
    if action == "brighter":
        return ("Reset exposure to 0" if (_num(settings.get("ev")) or 0) < -0.3 else "Tap the face, slide exposure up"), "the subject is too dark"
    if action == "darker":
        return "Tap the sky, slide exposure down", "the bright parts are blown out"
    if action == "portrait_mode":
        return "Switch to Portrait mode", "blur the busy background behind them"
    if action == "squeeze_in":
        return "Ask everyone to squeeze in closer", "someone is hidden or left out"
    if action == "tidy":
        return "Move the clutter out of frame", "it pulls the eye from the subject"
    return "Keep this framing", "it already works"


def calibrated_verdict(answers: dict) -> str:
    """Decision 1 leans "keeper" (p 0.45-0.5 on shots that need a fix): require p >= 0.6."""
    p = (answers.get("verdict") or {}).get("probabilities") or {}
    if float(p.get("retake", 0)) >= RETAKE_P:
        return "retake"
    if float(p.get("keeper", 0)) >= KEEPER_P:
        return "keeper"
    return "almost"


def decision_to_review(answers: dict, ctx: dict) -> dict:
    """Templated review: calibrated verdict, the top menu move only when confident, a working
    line, and the verdict probabilities as `p`."""
    settings = ctx.get("settings") or {}
    verdict = calibrated_verdict(answers)
    size = (answers.get("size") or {}).get("choice") or "medium"
    probs = (answers.get("next") or {}).get("probabilities") or {}
    ranked = sorted(((float(p), a) for a, p in probs.items() if a in ACTIONS and a not in NEVER_SHOW), reverse=True)
    picks = [a for p, a in ranked[:1] if p >= MOVE_P]
    if settings.get("mode") == "portrait":
        picks = [a for a in picks if a != "portrait_mode"]
    if verdict == "keeper" and not picks:
        picks = ["hold"]
    cards = []
    for a in picks:
        text, why = _template(a, size, is_selfie(ctx), settings)
        _, kind, direction = ACTIONS[a]
        cards.append(_card({"action": text, "why": why, "kind": kind, "direction": direction}, 1))
    work = (answers.get("working") or {}).get("choice")
    vp = (answers.get("verdict") or {}).get("probabilities") or {}
    return {"verdict": verdict, "suggestions": cards, "working": WORKING.get(work, ""),
            "p": {k: round(float(v), 3) for k, v in vp.items()}}


async def decide_review(b64img: str, ctx: dict) -> dict:
    """POST /v1beta/decisions, every question in one request (gemini.decisions: retries inside
    the deadline)."""
    items = [{"type": "text", "text": "The photo the user just took.\n" + context_text(ctx) + "\n"},
             {"type": "image", "data": b64img, "mime_type": "image/jpeg", "resolution": "low"}]
    res = await gemini.decisions(items, DECISION_QUESTIONS, model=DECISION_MODEL, tag="review_decide",
                                 timeout=DECISION_TIMEOUT_S)
    return decision_to_review(res.get("answers") or {}, ctx)


# ---------------------------------------------------------------------------------------------
# The pipeline.

def merge(dec: dict | None, gen: dict | None, first: dict | None = None) -> dict:
    """Generated wording wins; Decision 1 is the instant placeholder and the fallback. Verdict:
    retake if Decision's calibrated verdict says so (reliable; Flash-Lite under-calls retakes),
    otherwise the generated one. `first`: the streamed first card, kept if Flash died after it
    went out (so `final` never takes back a card the user already saw)."""
    if gen and gen.get("suggestions"):
        out = {k: gen[k] for k in ("verdict", "suggestions", "working")}
        if dec:
            if dec["verdict"] == "retake":
                out["verdict"] = "retake"
            out["working"] = out["working"] or dec["working"]
        out["source"] = "merged" if dec else "generated"
    elif first:
        out = {"verdict": dec["verdict"] if dec else "almost", "suggestions": [first],
               "working": dec["working"] if dec else "", "source": "partial"}
    elif dec:
        out = {k: dec[k] for k in ("verdict", "suggestions", "working")}
        out["source"] = "decision"
    else:
        out = {"verdict": "almost", "suggestions": [], "working": "", "source": "none"}
    out["speak"] = speak((out["suggestions"] or [None])[0])
    return out


def _differs(a: dict, b: dict) -> bool:
    """True if the top card changed in substance (kind or arrow), so the UI should swap."""
    sa, sb = (a.get("suggestions") or [{}])[0], (b.get("suggestions") or [{}])[0]
    return (sa.get("kind"), sa.get("direction")) != (sb.get("kind"), sb.get("direction"))


def _short(exc: BaseException | None) -> str:
    if exc is None:
        return "cancelled"
    if isinstance(exc, TimeoutError):
        return "timeout"
    return (str(exc) if isinstance(exc, gemini.GeminiError) else f"{type(exc).__name__}: {exc}")[:200]


async def review_events(b64img: str, ctx: dict, *, refine: bool, t0: float) -> AsyncIterator[tuple[str, dict]]:
    """Yields (event, data): decision, suggestion, final, refined (only with `refine`), and an
    internal `_errors` {refine: ...} if the refine failed. Never raises for a model failure; ends
    by the overall deadline at the latest. Times are ms since `t0` (perf_counter at request start)."""
    ms = lambda: round((time.perf_counter() - t0) * 1000)  # noqa: E731
    q: asyncio.Queue = asyncio.Queue()
    first: dict | None = None  # the streamed first card, once sent

    def on_first(obj: dict) -> None:
        if obj.get("action"):
            q.put_nowait(("card", _card(obj, 1)))

    tasks = {
        "dec": asyncio.create_task(asyncio.wait_for(decide_review(b64img, ctx), DECISION_TIMEOUT_S + 0.25)),
        "gen": asyncio.create_task(generate_review(b64img, ctx, model=GEN_MODEL, media_resolution="MEDIUM",
                                                   timeout=GEN_TIMEOUT_S, tag="review", on_first=on_first)),
    }
    if refine:
        tasks["refine"] = asyncio.create_task(generate_review(b64img, ctx, model=REFINE_MODEL, media_resolution="LOW",
                                                              timeout=REFINE_TIMEOUT_S, tag="review_refine"))
    for name, t in tasks.items():
        t.add_done_callback(lambda _t, n=name: q.put_nowait(("task", n)))
    deadline = time.monotonic() + max(DECISION_TIMEOUT_S, GEN_TIMEOUT_S, REFINE_TIMEOUT_S if refine else 0) + SLACK_S
    dec = gen = final = None
    errors: dict[str, str] = {}
    timing: dict[str, int] = {}
    pending = set(tasks)
    try:
        while pending:
            try:
                kind, val = await asyncio.wait_for(q.get(), max(0.0, deadline - time.monotonic()))
            except asyncio.TimeoutError:
                for n in pending:
                    errors[n] = "stream deadline"
                pending.clear()
                kind, val = "task", None
            if kind == "card":
                if first is None and final is None:
                    first = val
                    timing["first_ms"] = ms()
                    yield "suggestion", {**val, "ms": timing["first_ms"]}
                continue
            if val is not None:
                pending.discard(val)
                t = tasks[val]
                if t.cancelled() or t.exception() is not None:
                    errors[val] = _short(None if t.cancelled() else t.exception())
                elif val == "dec":
                    dec = t.result()
                    timing["decision_ms"] = ms()
                    card = None if first or gen else (dec["suggestions"] or [None])[0]
                    yield "decision", {"verdict": dec["verdict"], "p": dec["p"], "card": card,
                                       "working": dec["working"], "ms": timing["decision_ms"]}
                elif val == "gen":
                    gen = t.result()
                    timing["gen_ms"] = ms()
                    if first is None and gen["suggestions"] and final is None:
                        first = gen["suggestions"][0]
                        timing["first_ms"] = timing["gen_ms"]
                        yield "suggestion", {**first, "ms": timing["first_ms"]}
                elif val == "refine":
                    timing["refine_ms"] = ms()
            if final is None and not ({"dec", "gen"} & pending):
                timing["final_ms"] = ms()
                final = merge(dec, gen, first)
                yield "final", {**final, "timing": dict(timing),
                                **({"errors": dict(errors)} if errors else {})}
            t = tasks.get("refine")
            if final is not None and t is not None and t.done() and not t.cancelled() \
                    and t.exception() is None and "refined" not in timing:
                timing["refined"] = 1
                refined = merge(dec, t.result())
                yield "refined", {**refined, "changed": _differs(final, refined), "ms": ms()}
        if errors.get("refine"):
            yield "_errors", {"refine": errors["refine"]}
    finally:
        for t in tasks.values():
            if not t.done():
                t.cancel()


# ---------------------------------------------------------------------------------------------
# Persistence into the shot library.

_recent: OrderedDict[str, dict] = OrderedDict()  # review_id -> review.json payload


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _remember(review_id: str, doc: dict) -> None:
    _recent[review_id] = doc
    _recent.move_to_end(review_id)
    while len(_recent) > RECENT:
        _recent.popitem(last=False)


def _persist(shot_id: str, doc: dict) -> bool:
    """Write library/<id>/review.json atomically and set `assets.review` (shots._set persists
    shot.json and broadcasts `event: shot`). False if the shot is unknown or gone."""
    if not shots.ID_RE.match(shot_id or "") or shots.get_record(shot_id) is None:
        return False
    d = shots.LIBRARY / shot_id
    tmp = d / f".review.json.{secrets.token_hex(3)}"
    try:
        tmp.write_text(json.dumps({**doc, "shot_id": shot_id}, separators=(",", ":")))
        os.replace(tmp, d / "review.json")
    except OSError as exc:
        log.warning("review.json for %s not written: %s", shot_id, exc)
        return False
    entry = {"status": "done", "url": f"/api/shots/{shot_id}/review.json", "verdict": doc.get("verdict")}
    return shots.set_asset(shot_id, "review", entry) is not None


def attach(shot_id: str, review_id: str | None) -> bool:
    """Save a recent review (by `review_id`) into a shot that arrived after it. Meant for
    shots.create_shot: `review.attach(rec["id"], meta.get("review_id"))`."""
    doc = _recent.get(review_id or "")
    if doc is None:
        return False
    doc["shot_id"] = shot_id
    return _persist(shot_id, doc)


# review.json is a servable shot asset (GET /api/shots/{id}/review.json is shots.py's route).
shots.FILES.setdefault("review.json", "application/json")


# ---------------------------------------------------------------------------------------------
# HTTP.

def _err(status: int, msg: str) -> JSONResponse:
    return JSONResponse({"error": msg}, status_code=status)


def _sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'), ensure_ascii=False)}\n\n"


@router.post("/api/review")
async def post_review(image: UploadFile | None = File(None), context: str | None = Form(None)):
    t0 = time.perf_counter()
    if image is None:
        return _err(400, "missing form field 'image' (JPEG)")
    data = await image.read(MAX_IMAGE + 1)
    if not data:
        return _err(400, "empty image")
    if len(data) > MAX_IMAGE:
        return _err(413, f"image over {MAX_IMAGE // (1024 * 1024)} MB")
    raw = {}
    if context:
        if len(context) > MAX_CONTEXT:
            return _err(413, "context over 16 KB")
        try:
            raw = json.loads(context)
        except ValueError:
            return _err(400, "context is not valid JSON")
        if not isinstance(raw, dict):
            return _err(400, "context must be a JSON object")
    ctx = clean_context(raw)
    if not gemini.has_key():
        return _err(503, "GEMINI_API_KEY is not set")
    try:
        jpeg = await asyncio.to_thread(prepare_jpeg, data, needs_mirror(ctx))
    except ValueError as exc:
        return _err(400, str(exc))
    b64img = gemini.b64(jpeg)
    prep_ms = round((time.perf_counter() - t0) * 1000)
    rid = ctx.get("review_id") if REVIEW_ID_RE.match(ctx.get("review_id") or "") else secrets.token_hex(6)
    shot_id = ctx.get("shot_id")
    refine = bool(ctx.get("refine")) or os.environ.get("REVIEW_REFINE") == "1"

    async def stream():
        doc: dict | None = None
        saved: bool | None = None
        errors: dict = {}
        try:
            async for event, payload in review_events(b64img, ctx, refine=refine, t0=t0):
                if event == "_errors":
                    errors.update(payload)
                    continue
                if event == "final":
                    payload = {**payload, "review_id": rid}
                    payload["timing"]["prep_ms"] = prep_ms
                    errors.update(payload.get("errors") or {})
                    doc = {"review_id": rid, "created": _now(), "context": ctx,
                           **{k: v for k, v in payload.items() if k != "errors"}}
                    _remember(rid, doc)
                    log.info("review id=%s verdict=%s source=%s decision_ms=%s first_ms=%s final_ms=%s%s",
                             rid, payload["verdict"], payload["source"], payload["timing"].get("decision_ms"),
                             payload["timing"].get("first_ms"), payload["timing"]["final_ms"],
                             f" errors={errors}" if errors else "")
                elif event == "refined" and doc is not None:
                    doc["refined"] = dict(payload)
                yield _sse(event, payload)
                if event in ("final", "refined") and doc is not None and (shot_id or doc.get("shot_id")):
                    saved = _persist(shot_id or doc["shot_id"], doc)
        except Exception as exc:  # noqa: BLE001  (a bug, not a model failure: still end cleanly)
            log.exception("review %s failed", rid)
            errors["review"] = f"{type(exc).__name__}: {exc}"[:200]
        done = {"review_id": rid, "ms": round((time.perf_counter() - t0) * 1000), "saved": saved}
        if errors:
            done["errors"] = errors
        yield _sse("done", done)

    return StreamingResponse(stream(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
