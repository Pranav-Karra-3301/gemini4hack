"""Instant post-capture review: 1-3 "next shot" suggestions the moment a photo is taken.

Recommended pipeline (REPORT.md). Two calls start together on the same 1024 px JPEG (front-camera
shots mirrored, so left/right/clockwise match what the user saw on screen):
  ~0.6 s  Gemini Decision 1: calibrated verdict (keeper/almost/retake) and, when it is confident,
          one templated move card with its arrow                      -> event "decision"
  ~1.1 s  gemini-3.5-flash-lite (streamed, responseSchema): the first worded suggestion
                                                                      -> event "suggestion"
  ~1.2 s  the full review (1-3 suggestions + "what's working"), merged -> event "final"
Optional (`refine_model="gemini-4-hydrogen"`): a third call whose better-judged review lands at
~5 s                                                                   -> event "refined"
If the Flash call fails or is late, the Decision 1 card stays: the user always gets something.

    import review
    out = await review.review_shot(jpeg_bytes, context)                  # the "final" dict
    async for ev in review.review_shot_stream(jpeg_bytes, context):      # for SSE / WebSocket
        ...

`context` is the phone's live-session state at capture (all optional):
    {"facing": "back", "selfie": false, "mirrored": false, "intent": "portrait",
     "subject": "friend by the window", "keep": ["friend"], "scene": "", "heard": "turn a bit",
     "coach": ["Step back"], "settings": {"mode": "photo", "lens": "wide", "zoom": 1.0,
     "iso": 64, "shutter": 0.004, "ev": 0.0, "flash": "off"}}

Final event / `review_shot` result:
    {"verdict": "almost", "suggestions": [{"action": "Take one step back", "why": "...",
      "kind": "move", "direction": "back", "priority": 1}, ...], "working": "...",
     "speak": "Take one step back. ...", "source": "merged" | "decision" | "generated",
     "timing": {"prep_ms", "decision_ms", "first_ms", "final_ms"}}

Needs GEMINI_API_KEY. One shared httpx.AsyncClient (or pass Core's as `client=`).
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import io
import json
import os
import time
from typing import AsyncIterator

import httpx

API = "https://generativelanguage.googleapis.com/v1beta"
GEN_MODEL = os.environ.get("REVIEW_MODEL", "gemini-3.5-flash-lite")
REFINE_MODEL = "gemini-4-hydrogen"
DECISION_MODEL = "gemini-decision-1"
LONG_SIDE = 1024
GEN_TIMEOUT_S = 4.0       # Flash-Lite p95 was 1.5 s; past 4 s the moment has passed
REFINE_TIMEOUT_S = 12.0
DECISION_TIMEOUT_S = 3.0

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
# Shared HTTP client and image prep.

_client: httpx.AsyncClient | None = None


def http() -> httpx.AsyncClient:
    global _client
    if _client is None or _client.is_closed:
        _client = httpx.AsyncClient(timeout=httpx.Timeout(15.0, connect=5.0),
                                    limits=httpx.Limits(max_connections=32, max_keepalive_connections=16))
    return _client


async def aclose() -> None:
    if _client is not None and not _client.is_closed:
        await _client.aclose()


def _key() -> str:
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        raise RuntimeError("GEMINI_API_KEY is not set")
    return key


def prepare_jpeg(data: bytes, long_side: int = LONG_SIDE, quality: int = 85, mirror: bool = False) -> bytes:
    """EXIF-upright RGB JPEG, long side `long_side`. Gemini bills by media resolution, not pixels.
    `mirror`: flip left-right (front-camera shots, so the model sees what the user saw on screen)."""
    from PIL import Image, ImageOps

    im = Image.open(io.BytesIO(data))
    im.draft("RGB", (long_side, long_side))
    im = ImageOps.exif_transpose(im).convert("RGB")
    if mirror:
        im = ImageOps.mirror(im)
    im.thumbnail((long_side, long_side), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=quality)
    return buf.getvalue()


def is_selfie(ctx: dict) -> bool:
    return bool((ctx or {}).get("selfie")) or (ctx or {}).get("facing") == "front"


def needs_mirror(ctx: dict) -> bool:
    """Front-camera JPEGs are saved unmirrored (iOS default) but were framed on a mirrored
    preview: review them mirrored so left/right and clockwise match what the user saw (a
    horizon that slopes up in the file slopes down on screen, and the fix flips).
    Set context["mirrored"] = true if the app saved the mirrored version."""
    return is_selfie(ctx) and not (ctx or {}).get("mirrored")


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
    if s.get("shutter"):
        sh = float(s["shutter"])
        bits.append(f"1/{round(1 / sh)} s" if 0 < sh < 1 else f"{sh} s")
    if "ev" in s:
        bits.append(f"EV {float(s['ev']):+.1f}")
    if s.get("flash"):
        bits.append(f"flash {s['flash']}")
    return ", ".join(bits)


def context_text(ctx: dict) -> str:
    """The per-shot context as short lines (goes LAST in the request)."""
    ctx = ctx or {}
    keep = [str(k)[:60] for k in (ctx.get("keep") or [])][:8]
    lines = ["Live-session context at capture (may be incomplete):",
             f"- camera: {ctx.get('facing') or 'back'}"
             f"{' (selfie, shown as the user saw it: moves are arm moves)' if is_selfie(ctx) else ''}",
             f"- intent: {ctx.get('intent') or 'unknown'}",
             f"- subject: {str(ctx.get('subject') or '')[:60] or 'unknown'}",
             "- keep fully in frame: " + ("; ".join(keep) if keep else "(not given: everyone who is part of the shot)"),
             f"- scenery to show: {str(ctx.get('scene') or '')[:100] or '(none given)'}",
             f"- the user said: \"{str(ctx.get('heard'))[:200]}\"" if ctx.get("heard") else "- the user said: (nothing)"]
    if ctx.get("coach"):
        lines.append("- coach already said: " + " / ".join(str(c)[:60] for c in ctx["coach"][-3:]))
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


def _suggestion(s: dict, priority: int) -> dict:
    kind = s.get("kind") if s.get("kind") in KINDS else "move"
    direction = s.get("direction") if s.get("direction") in DIRECTIONS else "none"
    if kind in ("light", "timing", "setting", "subject"):
        direction = "none"  # the arrow is for camera moves only
    return {"action": _clip_words(s.get("action"), 8), "why": _clip_words(s.get("why"), 10),
            "kind": kind, "direction": direction, "priority": priority}


def normalize(obj: dict) -> dict:
    """Clamp a generated review to the contract (enums, word limits, 1-3 items, priorities)."""
    obj = obj if isinstance(obj, dict) else {}
    sugg = []
    for s in (obj.get("suggestions") or [])[:3]:
        if isinstance(s, dict) and s.get("action"):
            sugg.append(_suggestion(s, len(sugg) + 1))
    verdict = obj.get("verdict") if obj.get("verdict") in VERDICTS else "almost"
    return {"verdict": verdict, "suggestions": sugg, "working": _clip_words(obj.get("working"), 10)}


def speak(review: dict) -> str:
    """What the coach says out loud: the first suggestion and its reason."""
    s = (review.get("suggestions") or [None])[0]
    if not s:
        return ""
    why = s.get("why", "").rstrip(".")
    return f"{s['action'].rstrip('.')}. {why[:1].upper() + why[1:]}." if why else f"{s['action'].rstrip('.')}."


async def generate_review(jpeg: bytes, ctx: dict, *, model: str = GEN_MODEL, thinking: str | None = None,
                          media_resolution: str = "MEDIUM", client: httpx.AsyncClient | None = None,
                          timeout: float = GEN_TIMEOUT_S, on_first=None, thinking_budget: int | None = None) -> dict:
    """streamGenerateContent (SSE) with responseSchema. Returns {review, raw, ms, first_ms, usage}.
    `on_first(suggestion, ms)` (sync or async) fires as soon as the first suggestion is complete."""
    thinking = thinking or thinking_for(model)
    body = {
        "systemInstruction": {"parts": [{"text": SYSTEM}]},
        "contents": [{"role": "user", "parts": [
            {"inlineData": {"mimeType": "image/jpeg", "data": base64.b64encode(jpeg).decode()}},
            {"text": context_text(ctx)},
        ]}],
        "generationConfig": {
            "responseMimeType": "application/json", "responseSchema": SCHEMA,
            "thinkingConfig": ({"thinkingBudget": thinking_budget} if thinking_budget is not None
                               else {"thinkingLevel": thinking}),
            "mediaResolution": f"MEDIA_RESOLUTION_{media_resolution.upper()}",
            "temperature": 0.4,
        },
    }
    url = f"{API}/models/{model}:streamGenerateContent?alt=sse"
    headers = {"x-goog-api-key": _key(), "content-type": "application/json"}
    t0 = time.perf_counter()
    text, usage, first, first_ms = "", {}, None, None

    async def run():
        nonlocal text, usage, first, first_ms
        async with (client or http()).stream("POST", url, headers=headers, json=body) as r:
            if r.status_code != 200:
                raise RuntimeError(f"HTTP {r.status_code} ({model}): {(await r.aread()).decode()[:300]}")
            async for line in r.aiter_lines():
                if not line.startswith("data:"):
                    continue
                chunk = json.loads(line[5:])
                usage = chunk.get("usageMetadata") or usage
                for c in chunk.get("candidates") or []:
                    for p in (c.get("content") or {}).get("parts") or []:
                        if not p.get("thought"):
                            text += p.get("text", "")
                if first is None:
                    first = _first_object(text)
                    if first is not None:
                        first_ms = (time.perf_counter() - t0) * 1000
                        if on_first:
                            res = on_first(first, first_ms)
                            if asyncio.iscoroutine(res):
                                await res

    await asyncio.wait_for(run(), timeout)
    ms = (time.perf_counter() - t0) * 1000
    raw = json.loads(text)
    return {"review": normalize(raw), "raw": raw, "ms": round(ms), "first_ms": round(first_ms or ms),
            "usage": {"in": usage.get("promptTokenCount"), "out": usage.get("candidatesTokenCount"),
                      "thought": usage.get("thoughtsTokenCount", 0), "cached": usage.get("cachedContentTokenCount", 0)},
            "model": model, "thinking": thinking, "media": media_resolution.upper()}


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
        if float(settings.get("zoom") or 1) > 1.05:
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
        return ("Reset exposure to 0" if float(settings.get("ev") or 0) < -0.3 else "Tap the face, slide exposure up"), "the subject is too dark"
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
    """Templated review: calibrated verdict, the top menu move only when confident, a working line."""
    ctx = ctx or {}
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
    sugg = []
    for a in picks:
        text, why = _template(a, size, is_selfie(ctx), settings)
        _, kind, direction = ACTIONS[a]
        sugg.append({"action": text, "why": why, "kind": kind, "direction": direction, "priority": 1})
    work = (answers.get("working") or {}).get("choice")
    return {"verdict": verdict, "suggestions": sugg, "working": WORKING.get(work, "")}


def decision_input(jpeg: bytes, ctx: dict, resolution: str = "low") -> list:
    return [
        {"type": "text", "text": "The photo the user just took.\n" + context_text(ctx) + "\n"},
        {"type": "image", "data": base64.b64encode(jpeg).decode(), "mime_type": "image/jpeg", "resolution": resolution},
    ]


async def decide_review(jpeg: bytes, ctx: dict, *, resolution: str = "low",
                        client: httpx.AsyncClient | None = None, timeout: float = DECISION_TIMEOUT_S) -> dict:
    """POST /v1beta/decisions, every question in one request. Returns {review, answers, ms, tokens}."""
    t0 = time.perf_counter()
    r = await (client or http()).post(
        f"{API}/decisions", headers={"x-goog-api-key": _key()}, timeout=timeout,
        json={"model": DECISION_MODEL, "input": decision_input(jpeg, ctx, resolution), "questions": DECISION_QUESTIONS})
    ms = (time.perf_counter() - t0) * 1000
    if r.status_code != 200:
        raise RuntimeError(f"HTTP {r.status_code} (decisions): {r.text[:300]}")
    res = r.json()
    answers = res.get("answers") or {}
    return {"review": decision_to_review(answers, ctx), "answers": answers, "ms": round(ms),
            "tokens": (res.get("usage") or {}).get("total_tokens")}


# ---------------------------------------------------------------------------------------------
# The recommended pipeline.

def merge(dec: dict | None, gen: dict | None) -> dict:
    """Generated wording wins; Decision 1 is the instant placeholder and the fallback.
    Verdict: retake if Decision's calibrated verdict says so (reliable; Flash-Lite under-calls
    retakes), otherwise the generated verdict."""
    if gen and gen.get("suggestions"):
        out = dict(gen)
        if dec:
            if dec.get("verdict") == "retake":
                out["verdict"] = "retake"
            if not out.get("working"):
                out["working"] = dec.get("working", "")
        out["source"] = "merged" if dec else "generated"
    elif dec:
        out = {**dec, "source": "decision"}
    else:
        out = {"verdict": "almost", "suggestions": [], "working": "", "source": "none"}
    out["speak"] = speak(out)
    return out


async def review_shot_stream(image_bytes: bytes, context: dict, *, model: str = GEN_MODEL,
                             refine_model: str | None = None,
                             client: httpx.AsyncClient | None = None) -> AsyncIterator[dict]:
    """Yields {"event": "decision" | "suggestion" | "final" | "refined", ...} as each part lands.
    "decision" is skipped if the generated review is already in; "refined" (only with
    `refine_model`) comes after "final" and carries the slower model's review."""
    t0 = time.perf_counter()
    ms = lambda: round((time.perf_counter() - t0) * 1000)  # noqa: E731
    jpeg = await asyncio.to_thread(prepare_jpeg, image_bytes, LONG_SIDE, 85, needs_mirror(context))
    timing = {"prep_ms": ms()}
    q: asyncio.Queue = asyncio.Queue()

    async def first(s, _ms):
        sug = _suggestion(s, 1)
        await q.put({"event": "suggestion", "suggestion": sug, "speak": speak({"suggestions": [sug]}), "ms": ms()})

    tasks = {
        "dec": asyncio.create_task(decide_review(jpeg, context, client=client)),
        "gen": asyncio.create_task(generate_review(jpeg, context, model=model, client=client, on_first=first)),
    }
    if refine_model:
        tasks["refine"] = asyncio.create_task(generate_review(
            jpeg, context, model=refine_model, media_resolution="LOW", client=client, timeout=REFINE_TIMEOUT_S))
    for name, t in tasks.items():
        t.add_done_callback(lambda _t, n=name: q.put_nowait({"event": "_done", "task": n}))
    dec = gen = ref = None
    final = None
    errors = []
    try:
        pending = set(tasks)
        while pending:
            ev = await q.get()
            if ev["event"] == "suggestion":
                if final is None:
                    timing.setdefault("first_ms", ev["ms"])
                    yield ev
                continue
            name = ev["task"]
            pending.discard(name)
            t = tasks[name]
            if t.cancelled() or t.exception():
                errors.append(f"{name}: {t.exception()!r}"[:200] if not t.cancelled() else f"{name}: cancelled")
            elif name == "dec":
                dec = t.result()["review"]
                timing["decision_ms"] = ms()
                if gen is None:
                    yield {"event": "decision", **dec, "ms": timing["decision_ms"]}
            elif name == "gen":
                gen = t.result()["review"]
            elif name == "refine":
                ref = t.result()["review"]
            if final is None and {"dec", "gen"}.isdisjoint(pending):
                timing["final_ms"] = ms()
                timing.setdefault("first_ms", timing.get("decision_ms"))
                final = merge(dec, gen)
                yield {"event": "final", **final, "timing": timing, **({"errors": errors} if errors else {})}
            if final is not None and ref is not None:
                refined = merge(dec, ref)
                ref = None
                yield {"event": "refined", **refined, "changed": _differs(final, refined), "ms": ms()}
    finally:
        for t in tasks.values():
            if not t.done():
                t.cancel()


def _differs(a: dict, b: dict) -> bool:
    """True if the top suggestion changed in substance (kind or arrow), so the UI should swap."""
    sa, sb = (a.get("suggestions") or [{}])[0], (b.get("suggestions") or [{}])[0]
    return (sa.get("kind"), sa.get("direction")) != (sb.get("kind"), sb.get("direction"))


async def review_shot(image_bytes: bytes, context: dict, **kw) -> dict:
    """The recommended pipeline: Decision 1 + Flash-Lite in parallel; returns the "final" event."""
    async with contextlib.aclosing(review_shot_stream(image_bytes, context, **kw)) as stream:
        async for ev in stream:
            if ev["event"] == "final":
                ev.pop("event")
                return ev
    raise RuntimeError("review produced no result")
