"""Gemini Live session setup, shared by POST /api/live/token (live_token.py, which locks it inside
an ephemeral token) and the WS /api/live proxy (cam.py). See docs/CORE_API.md §2.

build_setup(mode, ...) returns a BidiGenerateContentSetup:
  - mode "camera": the iPhone shooting coach. Gemini sees ~1 fps frames, hears the user, and
    drives the real manual camera (set_camera: lens, zoom, ISO, shutter, EV, focus, white balance,
    tint, flash, torch); the app animates the matching dial so the user sees what changed.
  - mode "edit": the Mac photo editor. The shot's regions, scores, depth summary, the suggested
    plan and the current slider values are baked into the system prompt; Gemini moves the
    Paper-style sliders (edit_step / set_sliders) and explains each move as it goes.

Session settings (both modes), per the Live API guides:
  - responseModalities AUDIO (the only output gemini-3.8-live supports) + outputAudioTranscription
    for captions, inputAudioTranscription so the app can show what was heard.
  - realtimeInputConfig: automatic VAD that ends the user's turn after ~600 ms of silence.
  - contextWindowCompression slidingWindow: audio+video sessions stop after ~2 min without it, and
    Live bills EVERY turn for the whole context window, so the window size is the main cost lever.
    Measured 2026-11-21 (camera setup): prompt+tools 2.8k tokens, each frame ~165 tokens at LOW
    (MEDIUM is the same, HIGH ~540; 384-1024 px all cost the same), so 1 fps adds ~9.9k tokens/min.
    Trigger 16k / target 8k (env LIVE_CWC_TRIGGER / LIVE_CWC_TARGET) bills ~12k per turn on
    average instead of ~18k at 24k/12k; compression showed no latency spike (0.5-0.9 s per turn).
  - sessionResumption: the server sends resumable handles; reconnect with one on goAway/drops.
  - mediaResolution LOW: 1 fps JPEG frames at the lowest token cost.
  - No thinkingConfig / proactivity / affective dialog: gemini-3.8-live rejects or ignores them.
"""

from __future__ import annotations

import json
import os

# Mirrors web/src/cam/bus.js and the iPhone app.
MOVES = ["left", "right", "up", "down", "closer", "back", "rotate_left", "rotate_right", "hold"]
INTENTS = ["portrait", "group", "landscape", "object", "food", "street", "document", "other"]
REACTIONS = ["pleased", "disappointed", "neutral"]
MODES = ["photo", "portrait", "night", "macro"]
LENSES = ["ultrawide", "wide", "tele"]
FLASH = ["off", "on", "auto"]

# CORE_API.md §4: (name, min, max, default, meaning). focus_depth is metres or null.
SLIDERS: list[tuple[str, float, float, float | None, str]] = [
    ("exposure", -3, 3, 0, "overall brightness, in EV"),
    ("contrast", -100, 100, 0, "global contrast"),
    ("highlights", -100, 100, 0, "bright tones"),
    ("shadows", -100, 100, 0, "dark tones"),
    ("whites", -100, 100, 0, "white point"),
    ("blacks", -100, 100, 0, "black point"),
    ("warmth", -100, 100, 0, "white balance, cooler (-) to warmer (+)"),
    ("tint", -100, 100, 0, "green (-) to magenta (+)"),
    ("vibrance", -100, 100, 0, "boosts muted colors only (safe on skin)"),
    ("saturation", -100, 100, 0, "all colors"),
    ("clarity", -100, 100, 0, "local contrast, midtone detail"),
    ("vignette", -100, 100, 0, "negative darkens the edges"),
    ("subject_light", -100, 100, 0, "brightness inside the subject mask"),
    ("background_light", -100, 100, 0, "brightness outside the subject mask"),
    ("depth_blur", 0, 100, 0, "lens blur from the depth map, focused at focus_depth"),
    ("focus_depth", 0.1, 100, None, "metres; null = the subject's median depth"),
]
SLIDER_NAMES = [s[0] for s in SLIDERS]
SLIDER_DEFAULTS = {s[0]: s[3] for s in SLIDERS}


def live_model() -> str:
    model = os.environ.get("LIVE_MODEL") or "gemini-3.8-live"
    return model.removeprefix("models/")


# ---------------------------------------------------------------------------------------------
# Shared wording: camera directions are moves of the CAMERA, judged on the raw frame.
# (Also used by cam.py's Decisions/understand prompts.)

DIRECTIONS_TEXT = """\
Directions are moves of the CAMERA (the phone), judged on the frame exactly as you see it. The \
frames are never mirrored, not even from the selfie camera, so never swap left and right.
- left: pan or step the camera to the left, so more of what lies beyond the frame's LEFT edge \
comes in (everything in the frame slides right). Use it when the subject is cut off at, or \
crowded against, the left edge.
- right: pan or step the camera to the right, so more of what lies beyond the frame's RIGHT \
edge comes in. Use it when the subject is cut off at, or crowded against, the right edge.
- up: tilt or raise the camera, so more of what is above the TOP edge comes in. Use it when a \
head or the top of the subject is cut off, or there is too much empty floor or ground below it.
- down: tilt or lower the camera, so more of what is below the BOTTOM edge comes in. Use it \
when feet, a plate or the bottom of the subject is cut off, or there is too much empty sky or \
ceiling above it.
- closer: move the camera toward the subject (it is small, with too much empty or busy space).
- back: move the camera away (the subject is too big or cropped on several sides).
- rotate_left: roll the camera counter-clockwise; use it when level lines (horizon, table, \
door frames) slope UP toward the right side of the frame.
- rotate_right: roll the camera clockwise; use it when level lines slope DOWN toward the right.
- hold: keep the camera where it is; the framing works."""

# Same judgement as /api/reframe (splat.py): people stay whole, the place gets shown.
FRAMING_TEXT = """Framing rules, in this order:
1. People are the subject. Everyone who is part of the shot must stay fully in frame: never crop \
a head or a face, never cut a body at the joints. If anyone in the group is cut off at an edge, \
fix that first.
2. Show the place. If there is place-defining scenery (a landmark, a tree tunnel, a sunset, a \
view), prefer the move that shows MORE of it behind the people; never trade it away for a \
tighter crop.
3. Then composition: subject placement, level horizon, cleaner background, light.
Selfies: in a selfie (the front camera, or anyone in the frame holding the phone at arm's length) \
the camera is in the user's hand, so every move is an arm move: up = raise the phone and tilt it \
down a little so the faces stay in, down = lower the phone, back = extend the arm (or zoom out), \
closer = bring the phone in, left/right = swing the arm that way, rotate = twist the wrist. Keep \
selfie moves small. Example: a group selfie in a tree tunnel with faces cut at the edges and the \
tunnel above the frame: extend the arm (back) until every face is whole, then raise the phone \
and tilt down (up) so the tunnel's vanishing point shows above the heads."""

CAMERA_SETTINGS_TEXT = """\
The screen shows the camera's real manual dials: lens, zoom, ISO, shutter, EV, focus and white \
balance. When you call set_camera the matching dial visibly turns to the new value, so the user \
learns from watching it. Change settings yourself whenever it clearly helps, pass only what \
should change, and put the reason in `why` (a few words, shown under the dial). Say the reason \
out loud too, briefly ("Faster shutter, she's moving."). How to choose:
- mode: only set_camera changes it (the app has no mode picker), and every [tick] starts with the \
current one. In this app: "photo" is standard auto exposure (landscapes, streets, groups at a \
view, documents). "portrait" zooms to about 2x, adds +0.3 EV and records depth; the background \
blur is added AFTERWARDS in the editor (the preview shows none). Use it for one person, a pet, or \
a single object 0.3-2 m away with clutter behind it, and keep space between the subject and the \
background. "night" holds the shutter at 1/20 s or slower for dark scenes: brace the phone, keep \
the subject still. "macro" switches to the ultrawide lens with near focus, for tiny things a few \
cm away. If the mode doesn't suit the current subject, change it in the same turn (portrait on a \
landscape or street -> photo).
- lens: "ultrawide" for big scenes and tight rooms, "wide" by default, "tele" for flattering \
portraits and far subjects. zoom is the device zoom factor (0.5 = ultrawide, 1 = wide, 2-5 = \
tele); use it to tighten framing when the user can't step closer.
- ev (-3..3): the simple brightness fix. Raise it for a dark subject or a backlit face, lower it \
for blown skies, snow or bright walls.
- shutter (seconds) and iso: for motion and low light. Moving subject: 1/500 s (0.002) or \
faster. Handheld low light: no slower than 1/30 s (0.033); raise ISO before slowing further. \
Keep ISO as low as the light allows (noise). "auto" hands a setting back to the camera.
- focus: lens position 0 (nearest) .. 1 (farthest), or "auto"; prefer focus_x/focus_y on the \
subject's eyes (0..1 of the raw frame, origin top-left).
- wb_kelvin (2500..9000) is the light being corrected for: a HIGHER value makes the photo \
WARMER, a lower one cooler. ~3200 neutralizes warm bulbs, ~5500 daylight, ~7000 shade. tint \
(-50..50) fixes green (negative) or magenta (positive) casts.
- flash for a dark close subject; torch for continuous light on close-ups and video.
The app answers with the values it actually applied (clamped to the device): trust those."""


def _norm_facing(facing: str | None) -> str:
    return "front" if (facing or "").lower() in ("front", "user", "selfie") else "back"


def camera_prompt(voice: bool = True, facing: str = "back", context: str = "") -> str:
    camera = (
        "The user is on the FRONT (selfie) camera: the person in the frame is probably the user, "
        "holding the phone, so moves are arm moves."
        if _norm_facing(facing) == "front"
        else "The user is on the BACK camera; if someone in the frame is holding the phone at arm's "
        "length, it is still a selfie and moves are arm moves."
    )
    talk = (
        "Voice is ON: the user hears you. Speak rarely and briefly: at most 8 words, calm and "
        "warm, like a photographer friend standing next to them."
        if voice
        else "Voice is OFF: the user cannot hear you and only sees a caption. Say at most one or "
        "two words, or nothing at all, and let the tools do the work."
    )
    extra = f"\n\nContext from the app: {context.strip()}" if context and context.strip() else ""
    return f"""\
You are Coach, a calm photographer friend helping someone take a great photo with their phone. \
You see the live camera frame (about one per second) and hear the user. {camera}

{talk} When the user talks to you, answer out loud in a few words as well as with tools; \
otherwise speak only when it really helps. Never narrate or mention your tool calls, never \
describe the scene unless asked, and don't repeat yourself. Silence is fine when the user is \
doing well.

Your tools drive the camera screen; use them, they matter more than your words:
- guide: show an arrow telling the user how to move the camera. ALWAYS use guide for any \
direction, even when you also say it. Use direction "hold" when the framing is right.
- shot_ready: true when the frame is ready to shoot (the shutter glows), false when it needs work.
- set_intent: the shot's kind (portrait, group, landscape, object, food, street, document, \
other) and its subject. A single thing (a can, a bottle, a cup, a toy) is "object"; "food" is a \
meal or a dish. Call it for every new shot.
- set_camera: turn the camera's manual dials (below).
- user_reaction: when the user reacts to the shot or to your advice.
- take_photo: ONLY when the user asks you to take the picture ("take it", "shoot", "snap it", \
"cheese"). Never on your own.

What is the shot now? On every [tick] and [scene], look at the newest frame first and compare it \
with the subject you last set. If it shows a different subject or place, it is a NEW shot: call \
set_intent for it, drop all earlier advice, never mention the old subject, and coach the new one \
from scratch. The same subject reframed (closer, lower, another angle) is the same shot: keep \
going. The subject is the one thing the photo is about (the can, not the mess around it). If the \
user says what they want ("a portrait of my friend"), coach toward exactly that (one friend in a \
group: closer, crop the others out) while the camera stays on it; if they point the camera at \
something else without a word, follow the camera.

Coach toward ready, ONE instruction at a time, the most important first: 1) the subject is clear \
and whole; 2) no clutter crossing or crowding it (move closer, change height or angle so the \
background is clean, or move the clutter away); 3) placement (a third, or centred for a single \
symmetric object) and level lines; 4) light and exposure. Tips: object or food on a table: fill \
at least a third of the frame; shoot upright things (cans, bottles, glasses) from their own \
height so the background is the wall or the far room, flat things (plates, documents) from \
straight above; turn the label to the camera. Portrait: eyes on the upper third, never crop at \
joints. Landscape: horizon on a third and level, something in the foreground. Document: straight \
on, all four corners in. Never switch to the opposite direction on the next tick unless the \
frame changed.

Good enough is ready. Call shot_ready true as soon as the essentials are right (subject clear \
and whole, no clutter crossing it, placed, level, exposure fine); don't chase perfection, and \
after a couple of fixes that worked it is ready. Spoken tips are scarce: at most TWO per subject \
before you call it ready (the arrow can keep guiding silently). Never say "almost", never repeat \
a tip, and never ask for a step back unless a person or the subject is actually cut off at an \
edge. Editing afterwards (depth blur, light) will clean up a busy background, so a clear, \
well-placed subject is enough. When it BECOMES ready, call shot_ready true AND \
guide "hold" in the same turn, and say so once in 2 to 4 warm, confident words ("That's it. Take it." / "Perfect, shoot."). While it stays \
ready, stay silent and add no tweaks. If the view moves off it, call shot_ready false and guide \
back.

{CAMERA_SETTINGS_TEXT}

{DIRECTIONS_TEXT}

{FRAMING_TEXT}

Treat the user's voice as a signal, and answer every time they speak with at least one tool call:
- A disappointed sigh, "hmm, no" or "not that" means change the plan: call user_reaction \
(disappointed), then guide in a clearly different direction (or change a setting), and say the \
new idea in a few words.
- "Oh, that's good", "yes, that one" or "perfect" means it works: call user_reaction (pleased), \
guide "hold" and shot_ready true, and at most say "Hold it there." Don't suggest changes then.
- Requests about the picture itself ("brighter", "blur the background", "it's too orange") are \
set_camera changes: make them and say what you changed.

Messages in brackets come from the app, not from the user:
- [tick]: a routine check-in: the mode, the dials, the subject YOU last set (a memory, not a \
fact: the frame decides) and whether the shot is ready. Look at the newest frame and call guide \
and shot_ready (plus set_intent or set_camera if needed). Speak only if your advice changed in an \
important way, in a few words.
- [scene]: either the view changed completely (decide if it is a new shot, as above; the app has \
already cleared the arrow and the ready glow), or scene notes (who must stay in frame, the \
scenery to reveal, a selfie): use those for every guide call.
- [user], [app], [state], [review]: facts about what the user or the app did. Use them; no reply \
needed.
- A tick may end with "Director (Gemini 4, latest frame): ...": a slower, stronger vision model \
that studies each frame closely. Treat it as the plan: set_intent if it says NEW shot or names a \
different subject; guide with its next move; shot_ready with its ready; set_camera mode if its \
best mode differs from the current one; say its tip in your own words (at most 8 words) only when \
it is new or the plan changed, and only within your two-tip budget. Your own view wins only when the newest frame clearly shows the \
user already made the move, or the user just asked for something else. When its ready turns to \
yes, that is the "take it" moment.{extra}"""


def _tool(name: str, description: str, props: dict | None = None, required: list[str] | None = None) -> dict:
    decl: dict = {"name": name, "description": description}
    if props:
        params: dict = {"type": "OBJECT", "properties": props}
        if required:
            params["required"] = required
        decl["parameters"] = params
    return decl


def _num_or_auto(description: str) -> dict:
    # anyOf is accepted by the Live API (verified 2026-11-21): the model sends 0.002 or "auto".
    return {"anyOf": [{"type": "NUMBER"}, {"type": "STRING", "enum": ["auto"]}], "description": description}


CAMERA_TOOLS = [
    _tool(
        "guide",
        "Show an arrow on the camera screen telling the user how to move the CAMERA, judged on "
        "the frame as you see it (in a selfie these are arm moves). Aim for everyone fully in frame "
        "and the place-defining scenery shown. Use 'hold' when the framing is right.",
        {
            "direction": {"type": "STRING", "enum": MOVES},
            "strength": {"type": "STRING", "enum": ["small", "medium", "large"],
                         "description": "How far to move."},
        },
        ["direction"],
    ),
    _tool(
        "set_camera",
        "Turn the camera's manual dials. Pass only what should change; the matching dial animates "
        "to the new value.",
        {
            "mode": {"type": "STRING", "enum": MODES,
                     "description": "photo standard; portrait ~2x + depth (blur added later); night "
                                    "slow shutter, brace; macro ultrawide, a few cm"},
            "lens": {"type": "STRING", "enum": LENSES},
            "zoom": {"type": "NUMBER", "description": "Device zoom factor, 0.5 to 10 (0.5 ultrawide, 1 wide, 2+ tele)"},
            "iso": _num_or_auto("ISO, e.g. 100 or 800, or \"auto\""),
            "shutter": _num_or_auto("Shutter time in seconds, or \"auto\". Moving subject 0.002 (1/500) or "
                                    "faster; handheld never slower than 0.033 (1/30): raise ISO instead"),
            "ev": {"type": "NUMBER", "description": "Exposure compensation, -3 to 3 EV"},
            "focus": _num_or_auto("Lens position 0 (near) to 1 (far), or \"auto\""),
            "focus_x": {"type": "NUMBER", "description": "Focus/exposure point x, 0 (left) to 1 (right) of the raw frame"},
            "focus_y": {"type": "NUMBER", "description": "Focus/exposure point y, 0 (top) to 1 (bottom) of the raw frame"},
            "wb_kelvin": _num_or_auto("White balance 2500 to 9000 K (higher = warmer photo), or \"auto\""),
            "tint": {"type": "NUMBER", "description": "-50 (green) to 50 (magenta)"},
            "flash": {"type": "STRING", "enum": FLASH},
            "torch": {"type": "BOOLEAN"},
            "why": {"type": "STRING", "description": "Why, at most 8 words; shown under the dial"},
        },
    ),
    _tool(
        "set_intent",
        "Record the current shot: its kind and main subject. Call it for every new shot (a "
        "different subject or place), not when the same subject is reframed.",
        {
            "intent": {"type": "STRING", "enum": INTENTS},
            "subject": {"type": "STRING", "description": "The main subject, at most 4 words"},
        },
        ["intent"],
    ),
    _tool(
        "user_reaction",
        "Record how the user reacted to the shot or to your advice.",
        {
            "reaction": {"type": "STRING", "enum": REACTIONS},
            "heard": {"type": "STRING", "description": "What the user said, briefly"},
        },
        ["reaction"],
    ),
    _tool(
        "shot_ready",
        "Say whether the current frame is ready to shoot (the shutter glows). True as soon as the "
        "essentials are right (then also guide 'hold'); false when the view moves off it.",
        {"ready": {"type": "BOOLEAN"}},
        ["ready"],
    ),
    _tool(
        "take_photo",
        "Take the photo now. Only when the user asks for it.",
        {"reason": {"type": "STRING", "description": "Why, in a few words"}},
    ),
]


# ---------------------------------------------------------------------------------------------
# Edit mode

def _slider_prop(name: str, lo: float, hi: float, meaning: str) -> dict:
    if name == "focus_depth":
        return {"type": "NUMBER", "nullable": True,
                "description": f"{meaning} (0.1 to 100)"}
    return {"type": "NUMBER", "description": f"{meaning} ({lo:g} to {hi:g})"}


def edit_tools(region_ids: list[str] | None = None) -> list[dict]:
    region_desc = "Region id"
    if region_ids:
        region_desc += f" ({', '.join(region_ids)})"
    region_desc += "; omit for the whole photo."
    return [
        _tool(
            "edit_step",
            "One step of a guided edit: animates one slider to an absolute value (~600 ms), shows "
            "`why` as the caption and highlights `region`. Answers when the animation finishes; "
            "wait for it before the next step.",
            {
                "slider": {"type": "STRING", "enum": SLIDER_NAMES},
                "value": {"type": "NUMBER", "nullable": True,
                          "description": "The new absolute slider value, within the slider's range "
                                         "(null only for focus_depth)"},
                "why": {"type": "STRING", "description": "Why, at most 12 words"},
                "region": {"type": "STRING", "description": region_desc},
            },
            ["slider", "value", "why"],
        ),
        _tool(
            "set_sliders",
            "Set several sliders at once (animated). Absolute values; pass only what changes.",
            {
                "values": {"type": "OBJECT", "properties": {
                    n: _slider_prop(n, lo, hi, m) for n, lo, hi, _d, m in SLIDERS}},
                "why": {"type": "STRING", "description": "Why, at most 12 words"},
            },
            ["values"],
        ),
        _tool(
            "select_region",
            "Highlight a region's mask on the photo while you talk about it.",
            {"region": {"type": "STRING", "description": region_desc.replace("whole photo", "no highlight")}},
        ),
        _tool(
            "compare",
            "Show the original (before) or the edit (after).",
            {"show": {"type": "STRING", "enum": ["before", "after"]}},
            ["show"],
        ),
        _tool("reset", "Put every slider back to its default (the original photo)."),
        _tool("save_edit", "Save the current edit to the shot. Only when the user wants to keep it."),
    ]


def _fmt(v) -> str:
    if v is None:
        return "null"
    if isinstance(v, float):
        return f"{v:.3g}"
    return str(v)


def _notes(record: dict, score: dict | None, regions: dict | None) -> str:
    """Shot notes: edit.py's shot_context (shared with the suggest call) or a compact fallback."""
    try:
        import edit as _edit
        return _edit.shot_context(record, score, regions)
    except Exception:  # edit.py missing or mid-change: keep the live session usable
        lines = []
        for r in (regions or {}).get("regions") or []:
            lines.append(f"- {r.get('id')} [{r.get('tag')}] box {json.dumps(r.get('box'))}: {r.get('note', '')}")
        return ("Regions:\n" + "\n".join(lines)) if lines else ""


def _shot_text(shot: dict) -> str:
    """The per-shot facts baked into the edit prompt. `shot` = {"record": shot.json,
    "score": score.json, "regions": regions.json, "suggest": suggest.json, "values": {...},
    "subject": region id}; every part is optional."""
    lines: list[str] = []
    notes = _notes(shot.get("record") or {}, shot.get("score"), shot.get("regions"))
    if notes:
        lines.append(notes)
    meta = (shot.get("record") or {}).get("meta") or {}
    if isinstance(meta.get("coach"), list) and meta["coach"]:
        lines.append("Coaching while shooting: " + " | ".join(str(c)[:80] for c in meta["coach"][-3:]) + ".")
    if shot.get("subject"):
        lines.append(f"Subject region (drives subject_light, background_light and the default "
                     f"focus_depth): {shot['subject']}.")
    suggest = shot.get("suggest") or {}
    steps = suggest.get("steps") if isinstance(suggest.get("steps"), list) else []
    if steps:
        lines.append("Suggested plan" + (f" ({suggest['summary']})" if suggest.get("summary") else "")
                     + ", a starting point, not a script:")
        for st in steps[:8]:
            reg = f" [{st['region']}]" if st.get("region") else ""
            lines.append(f"- {st.get('slider')} -> {_fmt(st.get('value'))}{reg}: {st.get('why', '')}")
    values = {k: v for k, v in (shot.get("values") or {}).items()
              if k in SLIDER_DEFAULTS and v != SLIDER_DEFAULTS[k]}
    lines.append("Current sliders: " + (", ".join(f"{k} {_fmt(v)}" for k, v in values.items())
                                        if values else "all at default (the original photo)") + ".")
    return "\n".join(lines)


def edit_prompt(shot: dict | None = None, voice: bool = True, context: str = "") -> str:
    shot = shot or {}
    table = "\n".join(
        f"- {n}: {'metres or null' if n == 'focus_depth' else f'{lo:g}..{hi:g}'}, default {_fmt(d)}: {m}"
        for n, lo, hi, d, m in SLIDERS)
    talk = (
        "Voice is ON: speak like a friendly editor at the user's shoulder, one short sentence per "
        "move (at most 12 words), never a lecture."
        if voice
        else "Voice is OFF: the user only sees captions, so put the teaching in each tool's `why` "
        "and say almost nothing."
    )
    extra = f"\n\nContext from the app: {context.strip()}" if context and context.strip() else ""
    return f"""\
You are Coach, a photo editor teaching as you go. The user is editing one photo on their Mac with \
sliders that you can move; the app animates every slider you change so the user sees and learns \
each move. You may see the current edited image as a frame and hear the user.

{talk} Explain each move in one short sentence: what it does and why this photo needs it \
("Warmer, to bring back the sunset."). Never mention tool names.

Edit in a sensible order: white balance and exposure first, then tone (contrast, highlights, \
shadows, whites, blacks), then color (vibrance, saturation), then local (clarity, subject_light, \
background_light, depth_blur), then vignette. Keep it natural: small moves beat big ones, and \
vibrance is safer than saturation on skin.

Tools:
- edit_step: one guided step (one slider, its new value, why, and the region it is about). Use \
it when you walk the user through an edit: call one step, wait until it answers, then the next. \
3 to 8 steps make a full edit.
- set_sliders: several sliders at once, for quick requests that touch more than one slider.
- select_region: highlight a region while you talk about it.
- compare: show before or after (after a full edit, or when asked).
- reset: back to the original, when the user wants to start over.
- save_edit: only when the user says to keep or save it.

Values are ABSOLUTE slider positions, not changes: to warm it up from warmth 10, send 25. A \
nudge is about 10, a clear change 20 to 30, a strong one 40 or more (exposure: 0.2, 0.4, 0.7 \
EV). Take requests like "make it warmer" (raise warmth), "make them pop" (subject_light up, \
background_light down a little, maybe vibrance), "too dark" (exposure, then shadows), "blur the \
background" (depth_blur 30 to 60; focus_depth stays null to focus on the subject). After a request, \
make the change at once, then say what you did in a few words.

Messages that start with "[sliders]" come from the app when the user moves a slider by hand: they \
hold the current values. Build on them and don't undo the user's own moves unless asked.

Sliders (name: range, default: meaning):
{table}

This photo:
{_shot_text(shot)}{extra}"""


# ---------------------------------------------------------------------------------------------

def build_setup(
    mode: str = "camera",
    *,
    voice: bool = True,
    facing: str = "back",
    context: str = "",
    shot: dict | None = None,
    handle: str | None = None,
) -> dict:
    """The BidiGenerateContentSetup for a Live session in `mode` ("camera" or "edit").

    `shot` (edit mode): {"record": shot.json, "score": score.json, "regions": regions.json,
    "suggest": suggest.json, "values": {slider: value}, "subject": region id}, all optional.
    `handle` resumes a previous session (only the WS proxy passes one; token clients send it in
    their own setup message)."""
    if mode == "edit":
        prompt = edit_prompt(shot, voice, context)
        regs = ((shot or {}).get("regions") or {}).get("regions") or []
        region_ids = [r["id"] for r in regs if isinstance(r, dict) and r.get("id")]
        tools = edit_tools(region_ids)
    elif mode == "camera":
        prompt = camera_prompt(voice, facing, context)
        tools = CAMERA_TOOLS
    else:
        raise ValueError(f"unknown live mode {mode!r}")
    gen: dict = {"responseModalities": ["AUDIO"], "mediaResolution": "MEDIA_RESOLUTION_LOW"}
    trigger = max(6000, int(os.environ.get("LIVE_CWC_TRIGGER") or 16000))
    target = max(3000, int(os.environ.get("LIVE_CWC_TARGET") or 8000))
    if os.environ.get("LIVE_VOICE"):
        gen["speechConfig"] = {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": os.environ["LIVE_VOICE"]}}}
    return {
        "model": f"models/{live_model()}",
        "generationConfig": gen,
        "systemInstruction": {"parts": [{"text": prompt}]},
        "tools": [{"functionDeclarations": tools}],
        "inputAudioTranscription": {},
        "outputAudioTranscription": {},
        # End the user's turn after ~0.6 s of silence; the default sometimes ran several
        # utterances (and the pauses between them) into one 20 s turn.
        "realtimeInputConfig": {"automaticActivityDetection": {
            "endOfSpeechSensitivity": "END_SENSITIVITY_HIGH", "silenceDurationMs": 600}},
        # Audio+video sessions stop at ~2 min without compression. Every turn is billed for the
        # whole window, so a smaller window is cheaper per turn (see the module docstring).
        "contextWindowCompression": {"triggerTokens": trigger,
                                     "slidingWindow": {"targetTokens": min(target, trigger // 2)}},
        "sessionResumption": {"handle": handle} if handle else {},
    }


def token_constraints(setup: dict) -> tuple[dict, str]:
    """(bidiGenerateContentSetup, fieldMask) for POST /v1beta/auth_tokens.

    Verified against the live API on 2026-11-21:
      - With NO fieldMask the server takes the setup entirely from the token and ignores the
        client's setup message, so a reconnect that sends sessionResumption.handle is treated as a
        new session and fails with 1011 "Token has been used too many times" (uses: 1).
      - With a fieldMask that lists every field except sessionResumption, those fields are locked
        to the token's values and sessionResumption comes from the client: the first connect sends
        {"setup": {"sessionResumption": {}}} (handles arrive), a reconnect sends
        {"setup": {"sessionResumption": {"handle": h}}} and keeps the conversation, and a second
        fresh session is still rejected (uses: 1 holds).
      - Every field present in the token's setup must be listed in the mask (else HTTP 400
        "BidiGenerateContentSetup contains fields that are not specified in field_mask"), so
        sessionResumption is dropped from the token's setup.
    """
    locked = {k: v for k, v in setup.items() if k != "sessionResumption"}
    return locked, ",".join(locked)


def describe(setup: dict) -> str:
    """One-line summary for logs (never includes the prompt)."""
    decls = setup.get("tools", [{}])[0].get("functionDeclarations", [])
    prompt = setup.get("systemInstruction", {}).get("parts", [{}])[0].get("text", "")
    return json.dumps({"model": setup.get("model"), "tools": [d["name"] for d in decls],
                       "prompt_chars": len(prompt)})
