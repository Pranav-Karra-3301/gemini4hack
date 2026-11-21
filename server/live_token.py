"""POST /api/live/token: mint a Gemini Live ephemeral token with the whole session setup locked
inside it, so the iPhone / Mac app talks to Gemini directly (no media through Core, and the API
key never leaves the Mac). docs/CORE_API.md §2.

Request JSON (all optional except shot_id in edit mode):
  {"mode": "camera"|"edit", "voice": true, "facing": "back"|"front", "shot_id": null,
   "context": "", "values": {slider: value}, "subject": "r1"}
  `values` / `subject` (edit mode) are the editor's current state; they default to the shot's
  saved edit. Edit mode bakes shot.json, regions.json, score.json and suggest.json from
  server/library/<shot_id>/ into the prompt (missing files are skipped).

Response:
  {"token": "auth_tokens/...", "model": "gemini-3.8-live", "mode": "camera",
   "ws_url": "wss://...BidiGenerateContentConstrained?access_token=...",
   "setup": {"sessionResumption": {}}, "expire_time": "...", "new_session_expire_time": "...",
   "ms": 180}

Client protocol (verified against the live API, 2026-11-21; server/checks/live_token_check.py):
  1. Connect to ws_url and send {"setup": <response.setup>}, i.e. {"setup": {"sessionResumption":
     {}}}; wait for setupComplete (~0.3 s). Everything else (model, prompt, tools, VAD,
     transcription, compression, media resolution, voice) is locked by the token's fieldMask.
  2. Keep the latest sessionResumptionUpdate.newHandle (when resumable).
  3. On goAway or a drop, reconnect to the SAME ws_url before expire_time and send
     {"setup": {"sessionResumption": {"handle": "<handle>"}}}: the conversation continues
     (~0.4 s) and it does not count as a use. A brand-new session on the same token is rejected
     (uses: 1) with close 1011 "Token has been used too many times": mint a new token for that.
     A new token can also resume an old handle.
  Why the fieldMask: without one the server takes the setup entirely from the token and ignores
  the client's setup message, so the handle is dropped and the reconnect is a second "use".
  See live_setup.token_constraints.

Mint: POST https://generativelanguage.googleapis.com/v1beta/auth_tokens (x-goog-api-key) with
{"uses": 1, "expireTime", "newSessionExpireTime", "fieldMask", "bidiGenerateContentSetup"},
via gemini.mint_live_token (shared pooled client, retries, stats); ~0.15 s warm. TTLs: env LIVE_TOKEN_TTL_MIN (default 30, max 1200)
and LIVE_TOKEN_START_S (default 120: time to open the first session).
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
from pathlib import Path

from fastapi import APIRouter, Body
from fastapi.responses import JSONResponse

import gemini
import live_setup

log = logging.getLogger("coach.live_token")
router = APIRouter()

SHOT_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
DEFAULT_LIBRARY = Path(__file__).resolve().parent / "library"

def _err(status: int, msg: str) -> JSONResponse:
    return JSONResponse({"error": msg}, status_code=status)


def _env_num(name: str, default: float, lo: float, hi: float) -> float:
    try:
        return min(hi, max(lo, float(os.environ.get(name) or default)))
    except ValueError:
        return default


def library_dir() -> Path:
    """shots.py's library when it defines one, else server/library."""
    try:
        import shots
        lib = getattr(shots, "LIBRARY", None) or getattr(shots, "LIBRARY_DIR", None)
        if lib:
            return Path(lib)
    except Exception:
        pass
    return DEFAULT_LIBRARY


def _read_json(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def load_shot(shot_id: str, values: dict | None = None, subject: str | None = None) -> dict | None:
    """Edit-mode context for live_setup.build_setup, or None if the shot doesn't exist.
    Tolerates missing or half-written files (the pipeline may still be running)."""
    d = library_dir() / shot_id
    if not d.is_dir():
        return None
    record = _read_json(d / "shot.json") or {"id": shot_id}
    suggest = _read_json(d / "suggest.json")
    saved = record.get("edit") if isinstance(record.get("edit"), dict) else {}
    if not isinstance(values, dict):
        values = saved.get("values") if isinstance(saved.get("values"), dict) else {}
    subject = subject or saved.get("subject") or (suggest or {}).get("subject")
    return {"record": record, "regions": _read_json(d / "regions.json"),
            "score": _read_json(d / "score.json"), "suggest": suggest,
            "values": values, "subject": subject}


async def mint(setup: dict) -> dict:
    """Mint a 1-use token for `setup` through gemini.py (pooled keep-alive client, 429/5xx
    retries inside a 10 s deadline, a `coach.gemini` log line and /api/stats tag `live_token`).
    Returns gemini.mint_live_token's dict: token, ws_url, model, expire_time,
    new_session_expire_time, ms."""
    locked, mask = live_setup.token_constraints(setup)
    return await gemini.mint_live_token(
        locked, uses=1, field_mask=mask, tag="live_token", timeout=10.0,
        expire_s=int(_env_num("LIVE_TOKEN_TTL_MIN", 30, 2, 1200) * 60),
        new_session_s=int(_env_num("LIVE_TOKEN_START_S", 120, 30, 3600)),
    )


@router.post("/api/live/token")
async def api_live_token(body: dict | None = Body(default=None)):
    t0 = time.perf_counter()
    body = body if isinstance(body, dict) else {}
    mode = body.get("mode") or "camera"
    if mode not in ("camera", "edit"):
        return _err(400, "mode must be 'camera' or 'edit'")
    voice = body.get("voice", True) not in (False, 0, "0", "false", "off")
    facing = "front" if str(body.get("facing") or "").lower() in ("front", "user") else "back"
    context = str(body.get("context") or "")[:2000]
    shot = None
    if mode == "edit":
        shot_id = str(body.get("shot_id") or "")
        if not shot_id:
            return _err(400, "edit mode needs shot_id")
        if not SHOT_ID.match(shot_id):
            return _err(400, "bad shot_id")
        subject = body.get("subject") if isinstance(body.get("subject"), str) else None
        shot = load_shot(shot_id, body.get("values"), subject)
        if shot is None:
            return _err(404, f"shot {shot_id} not found")
    setup = live_setup.build_setup(mode, voice=voice, facing=facing, context=context, shot=shot)
    try:
        tok = await mint(setup)
    except gemini.GeminiError as exc:  # HTTP or network failure that survived the retries
        log.warning("live token mint failed: %s", exc)
        return _err(502, str(exc))
    except RuntimeError as exc:  # GEMINI_API_KEY is not set
        log.warning("live token mint failed: %s", exc)
        return _err(500, str(exc))
    ms = int((time.perf_counter() - t0) * 1000)
    log.info("live token: mode=%s %s ms=%d", mode, live_setup.describe(setup), ms)
    return {
        "token": tok["token"],
        "model": live_setup.live_model(),
        "mode": mode,
        "ws_url": tok["ws_url"],
        "setup": {"sessionResumption": {}},
        "expire_time": tok["expire_time"],
        "new_session_expire_time": tok["new_session_expire_time"],
        "ms": ms,
    }
