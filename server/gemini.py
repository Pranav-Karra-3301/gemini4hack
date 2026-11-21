"""The one Gemini API client for Coach Core: pooled HTTP, retries, logging, stats.

Every Gemini REST call in Core goes through here, so each one gets the same connection reuse,
retry policy, structured log line and latency/token/cost accounting (GET /api/stats).

    import gemini
    out = await gemini.generate_json("gemini-4-hydrogen", [gemini.image_part(jpg), "prompt"],
                                     SCHEMA, system=SYSTEM, media_resolution="medium", tag="suggest")
    res = await gemini.decisions(input_items, questions, tag="cam_decide")   # full response dict
    wav = await gemini.tts("Hold still", "Kore", tag="say")                  # WAV bytes
    tok = await gemini.mint_live_token(setup, tag="live_token")              # {token, ws_url, ...}

Errors are `gemini.GeminiError` (a RuntimeError) with `.status` (0 = network/timeout).
Best practices and measured numbers: ../docs/BEST_PRACTICES.md.
"""

from __future__ import annotations

import asyncio
import base64
import email.utils
import importlib.util
import io
import json
import logging
import os
import random
import re
import sys
import threading
import time
import wave
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

import httpx

API = "https://generativelanguage.googleapis.com/v1beta"
LIVE_WS = ("wss://generativelanguage.googleapis.com/ws/"
           "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained")

HTTP2 = importlib.util.find_spec("h2") is not None  # only if the h2 package is already installed
CONNECT_S = 5.0
READ_S = 60.0
RETRY_STATUS = frozenset({429, 500, 502, 503, 504})
MAX_ATTEMPTS = 3
BACKOFF_BASE_S = 0.5
BACKOFF_MAX_S = 8.0
MIN_ATTEMPT_S = 1.0  # don't start a retry with less time than this left before the deadline

# USD per 1M tokens (input, output incl. thinking), standard paid tier, from
# https://ai.google.dev/gemini-api/docs/pricing on 2026-11-21. Argon/Carbon double on 2026-12-01.
# Cached input is billed at CACHED_FACTOR x input. Unknown models count tokens but cost 0.
PRICES: dict[str, tuple[float, float]] = {
    "gemini-4-carbon": (2.00, 10.00),
    "gemini-4-argon": (2.00, 10.00),
    "gemini-4-neon": (3.00, 15.00),
    "gemini-4-hydrogen": (1.50, 7.50),
    "gemini-3.8-flash": (0.75, 3.75),
    "gemini-3.5-flash-lite": (0.30, 2.50),
    "gemini-3.8-flash-lite-tts": (0.50, 6.00),  # output = audio tokens
    "gemini-3.8-flash-tts": (1.00, 20.00),
    "gemini-decision-1": (0.10, 0.0),
}
CACHED_FACTOR = 0.05

log = logging.getLogger("coach.gemini")


def _setup_logging() -> None:
    """uvicorn only configures its own loggers, so give ours a stderr handler in the same style
    (`INFO:     coach.gemini call ...`). GEMINI_LOG=0 silences the per-call lines."""
    if log.handlers:
        return
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(logging.Formatter("%(levelname)s:     %(name)s %(message)s"))
    log.addHandler(handler)
    log.setLevel(logging.WARNING if os.environ.get("GEMINI_LOG") == "0" else logging.INFO)
    log.propagate = False


_setup_logging()


class GeminiError(RuntimeError):
    def __init__(self, msg: str, status: int = 0):
        super().__init__(msg)
        self.status = status


def has_key() -> bool:
    return bool(os.environ.get("GEMINI_API_KEY"))


def api_key() -> str:
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        raise RuntimeError("GEMINI_API_KEY is not set")
    return key


# ---------------------------------------------------------------------------------------------
# HTTP client: one pooled AsyncClient per event loop (keep-alive TLS connections are reused, so
# only the first call after start pays the ~100-200 ms handshake).

_clients: dict[int, tuple[asyncio.AbstractEventLoop, httpx.AsyncClient]] = {}


def http() -> httpx.AsyncClient:
    loop = asyncio.get_running_loop()
    entry = _clients.get(id(loop))
    if entry is None or entry[0] is not loop or entry[1].is_closed:
        for k, (lp, _c) in list(_clients.items()):  # forget clients of loops that are gone
            if lp.is_closed():
                del _clients[k]
        client = httpx.AsyncClient(
            http2=HTTP2,
            timeout=httpx.Timeout(READ_S, connect=CONNECT_S),
            limits=httpx.Limits(max_connections=64, max_keepalive_connections=16, keepalive_expiry=120),
        )
        _clients[id(loop)] = entry = (loop, client)
    return entry[1]


async def aclose() -> None:
    entry = _clients.pop(id(asyncio.get_running_loop()), None)
    if entry:
        await entry[1].aclose()


async def warm() -> None:
    """Open a keep-alive connection to the API (cheap metadata GET) so the first real call skips
    DNS + TLS. Never raises."""
    if not has_key():
        return
    try:
        await http().get(f"{API}/models/gemini-decision-1", headers={"x-goog-api-key": api_key()}, timeout=5)
    except Exception as exc:  # noqa: BLE001
        log.info("warm failed: %s", type(exc).__name__)


# ---------------------------------------------------------------------------------------------
# Stats: per (model, tag) latency percentiles, tokens, estimated cost.

_LAT_WINDOW = 500


@dataclass
class _Stat:
    n: int = 0
    errors: int = 0
    invalid: int = 0  # 200 OK but unusable (no candidates, non-JSON)
    retries: int = 0
    tok_in: int = 0
    tok_out: int = 0
    tok_thought: int = 0
    tok_cached: int = 0
    cost: float = 0.0
    kb_sent: float = 0.0
    lat: deque = field(default_factory=lambda: deque(maxlen=_LAT_WINDOW))
    last_error: str | None = None
    last_at: float = 0.0


_stats: dict[tuple[str, str], _Stat] = {}
_lock = threading.Lock()
_started = time.time()


def _pct(values: list[float], q: float) -> float | None:
    if not values:
        return None
    v = sorted(values)
    k = (len(v) - 1) * q / 100.0
    lo, hi = int(k), min(int(k) + 1, len(v) - 1)
    return round(v[lo] + (v[hi] - v[lo]) * (k - lo))


def _cost(model: str, tin: int, tout: int, cached: int) -> float:
    pin, pout = PRICES.get(model, (0.0, 0.0))
    return ((tin - cached) * pin + cached * pin * CACHED_FACTOR + tout * pout) / 1e6


def record(model: str, tag: str, ms: float, *, ok: bool = True, usage: dict | None = None,
           retries: int = 0, error: str | None = None, kb: float = 0.0) -> None:
    """Add one call to the stats. Public so code that talks to Gemini some other way (e.g. the
    Live WebSocket) can report its timings too. `usage` keys: input, output, thought, cached."""
    u = usage or {}
    tin, tout, tth, tca = (int(u.get(k) or 0) for k in ("input", "output", "thought", "cached"))
    with _lock:
        s = _stats.setdefault((model, tag), _Stat())
        s.n += 1
        s.retries += retries
        s.last_at = time.time()
        s.kb_sent += kb
        if ok:
            s.lat.append(ms)
        else:
            s.errors += 1
            s.last_error = (error or "")[:200]
        s.tok_in += tin
        s.tok_out += tout
        s.tok_thought += tth
        s.tok_cached += tca
        s.cost += _cost(model, tin, tout + tth, tca)


def _mark_invalid(model: str, tag: str, why: str) -> None:
    with _lock:
        s = _stats.setdefault((model, tag), _Stat())
        s.invalid += 1
        s.last_error = why[:200]


def snapshot() -> dict:
    with _lock:
        rows = []
        tot = {"calls": 0, "errors": 0, "invalid": 0, "retries": 0, "input_tokens": 0,
               "output_tokens": 0, "thought_tokens": 0, "cached_tokens": 0, "cost_usd": 0.0}
        for (model, tag), s in sorted(_stats.items(), key=lambda kv: (kv[0][1], kv[0][0])):
            lat = list(s.lat)
            ok = max(len(lat), 1)
            rows.append({
                "model": model, "tag": tag, "calls": s.n, "errors": s.errors, "invalid": s.invalid,
                "retries": s.retries,
                "p50_ms": _pct(lat, 50), "p95_ms": _pct(lat, 95),
                "mean_ms": round(sum(lat) / ok) if lat else None, "max_ms": round(max(lat)) if lat else None,
                "tokens": {"input": s.tok_in, "output": s.tok_out, "thought": s.tok_thought, "cached": s.tok_cached,
                           "input_per_call": round(s.tok_in / max(s.n, 1))},
                "kb_sent_per_call": round(s.kb_sent / max(s.n, 1), 1),
                "cost_usd": round(s.cost, 5),
                "last_error": s.last_error,
                "last_at": datetime.fromtimestamp(s.last_at, timezone.utc).isoformat(timespec="seconds")
                if s.last_at else None,
            })
            tot["calls"] += s.n
            tot["errors"] += s.errors
            tot["invalid"] += s.invalid
            tot["retries"] += s.retries
            tot["input_tokens"] += s.tok_in
            tot["output_tokens"] += s.tok_out
            tot["thought_tokens"] += s.tok_thought
            tot["cached_tokens"] += s.tok_cached
            tot["cost_usd"] += s.cost
        tot["cost_usd"] = round(tot["cost_usd"], 4)
    return {
        "since": datetime.fromtimestamp(_started, timezone.utc).isoformat(timespec="seconds"),
        "uptime_s": round(time.time() - _started),
        "window": _LAT_WINDOW, "http2": HTTP2,
        "calls": rows, "totals": tot,
        "pricing": "USD per 1M tokens, standard tier, ai.google.dev/gemini-api/docs/pricing (2026-11-21); "
                   "estimate only",
    }


def reset_stats() -> None:
    global _started
    with _lock:
        _stats.clear()
        _started = time.time()


# ---------------------------------------------------------------------------------------------
# Core POST with retries.

def _err_text(r: httpx.Response) -> str:
    try:
        err = r.json().get("error", {})
        msg = err.get("message", err) if isinstance(err, dict) else err
    except Exception:  # noqa: BLE001
        msg = r.text
    return " ".join(str(msg).split())[:300]


def _retry_after(r: httpx.Response) -> float | None:
    """Server-requested delay: Retry-After (seconds or HTTP date), or google.rpc.RetryInfo."""
    h = r.headers.get("retry-after")
    if h:
        try:
            return max(0.0, float(h))
        except ValueError:
            try:
                return max(0.0, email.utils.parsedate_to_datetime(h).timestamp() - time.time())
            except (TypeError, ValueError):
                pass
    try:
        for d in r.json().get("error", {}).get("details", []) or []:
            m = re.fullmatch(r"([\d.]+)s", str(d.get("retryDelay", "")))
            if m:
                return float(m.group(1))
    except Exception:  # noqa: BLE001
        pass
    return None


def _usage(resp: dict) -> dict:
    if "usageMetadata" in resp:  # generateContent
        u = resp["usageMetadata"]
        return {"input": u.get("promptTokenCount", 0), "output": u.get("candidatesTokenCount", 0),
                "thought": u.get("thoughtsTokenCount", 0), "cached": u.get("cachedContentTokenCount", 0)}
    if "usage" in resp:  # decisions
        u = resp["usage"] or {}
        return {"input": u.get("total_input_tokens", u.get("total_tokens", 0)),
                "output": u.get("total_output_tokens", 0)}
    return {}


async def post(path: str, body: dict, *, model: str, tag: str, timeout: float = 60.0,
               attempts: int = MAX_ATTEMPTS) -> tuple[dict, dict]:
    """POST JSON to the Gemini API with retries; returns (response JSON, meta).

    Retries 429/500/502/503/504 and network errors with exponential backoff + jitter, honouring
    Retry-After / RetryInfo, all inside one `timeout` deadline. Other 4xx fail at once.
    meta = {ms, retries, usage, status}.
    """
    url = path if path.startswith("http") else f"{API}/{path.lstrip('/')}"
    payload = json.dumps(body, separators=(",", ":")).encode()
    kb = len(payload) / 1024
    headers = {"x-goog-api-key": api_key(), "content-type": "application/json"}
    t0 = time.perf_counter()
    deadline = time.monotonic() + timeout
    retries, status, err = 0, 0, "deadline exceeded"
    for attempt in range(attempts):
        remaining = deadline - time.monotonic()
        server_wait = None
        try:
            r = await asyncio.wait_for(http().post(url, content=payload, headers=headers), remaining)
            status = r.status_code
            if status == 200:
                try:
                    resp = r.json()
                except ValueError:
                    err = f"Gemini HTTP 200 ({model}) with a non-JSON body: {r.text[:120]}"
                    break
                ms = (time.perf_counter() - t0) * 1000
                usage = _usage(resp)
                record(model, tag, ms, usage=usage, retries=retries, kb=kb)
                log.info("call tag=%s model=%s status=200 ms=%d in=%s out=%s thought=%s cached=%s "
                         "retries=%d kb=%.0f", tag, model, ms, usage.get("input", "-"), usage.get("output", "-"),
                         usage.get("thought", "-"), usage.get("cached", "-"), retries, kb)
                return resp, {"ms": round(ms), "retries": retries, "usage": usage, "status": 200}
            err = f"Gemini HTTP {status} ({model}): {_err_text(r)}"
            if status not in RETRY_STATUS:
                break
            server_wait = _retry_after(r)
        except (httpx.TransportError, asyncio.TimeoutError) as exc:
            status, err = 0, f"Gemini {type(exc).__name__} ({model}): {exc}".rstrip(": ")
        if attempt == attempts - 1:
            break
        backoff = min(BACKOFF_MAX_S, BACKOFF_BASE_S * 2 ** attempt)
        wait = max(server_wait or 0.0, random.uniform(backoff / 2, backoff))
        if time.monotonic() + wait + MIN_ATTEMPT_S > deadline:
            break
        retries += 1
        log.warning("retry tag=%s model=%s status=%s attempt=%d wait_ms=%d err=%s",
                    tag, model, status, attempt + 1, wait * 1000, err[:120])
        await asyncio.sleep(wait)
    ms = (time.perf_counter() - t0) * 1000
    record(model, tag, ms, ok=False, retries=retries, error=err, kb=kb)
    log.warning("call tag=%s model=%s status=%s ms=%d retries=%d kb=%.0f error=%s",
                tag, model, status or "net", ms, retries, kb, err[:200])
    raise GeminiError(err, status)


# ---------------------------------------------------------------------------------------------
# Content helpers.

def prepare_jpeg(data: bytes, long_side: int, quality: int = 85) -> bytes:
    """EXIF-upright, RGB, downscaled to `long_side`, JPEG. Raises ValueError if undecodable.
    Gemini 4 bills images by media resolution (280/560/1120 tokens), not by pixels, so a smaller
    upload costs no tokens and only saves bytes and decode time."""
    from PIL import Image, ImageOps  # local: keep `import gemini` light for scripts

    try:
        im = Image.open(io.BytesIO(data))
        im.draft("RGB", (long_side, long_side))  # JPEG DCT downscale on decode: 4032 px -> 1024 in ~60 ms, not ~150
        im = ImageOps.exif_transpose(im).convert("RGB")
    except Exception as exc:
        raise ValueError(f"could not decode image: {exc}") from exc
    im.thumbnail((long_side, long_side), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=quality)
    return buf.getvalue()


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def image_part(data: bytes | str, mime: str = "image/jpeg", resolution: str | None = None) -> dict:
    """inlineData part from raw bytes or an already base64-encoded string. `resolution`
    (low/medium/high/ultra_high) sets this part's media resolution (per-part control, Gemini 3+;
    verified on generateContent REST 2026-11-21: low = ~280 tokens, high = ~1100)."""
    part = {"inlineData": {"mimeType": mime, "data": data if isinstance(data, str) else b64(data)}}
    if resolution:
        part["mediaResolution"] = {"level": _media_res(resolution)}
    return part


def _part(p) -> dict:
    if isinstance(p, dict):
        return p
    if isinstance(p, (bytes, bytearray)):
        return image_part(bytes(p))
    return {"text": str(p)}


def _media_res(level: str) -> str:
    level = level.upper()
    return level if level.startswith("MEDIA_RESOLUTION_") else f"MEDIA_RESOLUTION_{level}"


def _is_openapi_schema(schema: dict) -> bool:
    """True for the OpenAPI-subset form (uppercase types, `responseSchema`), False for JSON
    Schema (`responseJsonSchema`)."""
    t = schema.get("type")
    return isinstance(t, str) and t.isupper()


def _parse_json_text(text: str):
    text = text.strip()
    m = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    if m:
        text = m.group(1).strip()
    return json.loads(text)


@dataclass
class Reply:
    model: str
    tag: str
    text: str
    data: object
    usage: dict
    ms: int
    retries: int
    finish: str | None
    raw: dict


async def generate(model: str, parts: list, *, schema: dict | None = None, system: str | None = None,
                   thinking: str | None = "low", media_resolution: str | None = None,
                   temperature: float | None = None, max_output_tokens: int | None = None,
                   generation_config: dict | None = None, tag: str = "generate",
                   timeout: float = 60.0, attempts: int = MAX_ATTEMPTS) -> Reply:
    """generateContent. `parts` items may be Gemini part dicts, str (text) or bytes (a JPEG).
    `system` goes in systemInstruction (stable prefix, separate from per-call content).
    `thinking` is a thinkingLevel (Gemini 4: low/medium/high[/xhigh]; None = model default).
    `media_resolution` low/medium/high applies to every image in the request.
    With `schema`, the reply is constrained JSON and `Reply.data` holds the parsed value.
    `attempts=1` disables retries (for calls whose answer is useless if late)."""
    gen: dict = {}
    if thinking:
        gen["thinkingConfig"] = {"thinkingLevel": thinking}
    if media_resolution:
        gen["mediaResolution"] = _media_res(media_resolution)
    if temperature is not None:
        gen["temperature"] = temperature
    if max_output_tokens:
        gen["maxOutputTokens"] = max_output_tokens
    if schema is not None:
        gen["responseMimeType"] = "application/json"
        gen["responseSchema" if _is_openapi_schema(schema) else "responseJsonSchema"] = schema
    if generation_config:
        gen.update(generation_config)
    body: dict = {}
    if system:
        body["systemInstruction"] = {"parts": [{"text": system}]}
    body["contents"] = [{"role": "user", "parts": [_part(p) for p in parts]}]
    if gen:
        body["generationConfig"] = gen
    resp, meta = await post(f"models/{model}:generateContent", body, model=model, tag=tag, timeout=timeout,
                            attempts=attempts)
    cands = resp.get("candidates") or []
    if not cands:
        why = f"Gemini returned no candidates ({model}): {str(resp.get('promptFeedback'))[:200]}"
        _mark_invalid(model, tag, why)
        raise GeminiError(why, 200)
    finish = cands[0].get("finishReason")
    cparts = (cands[0].get("content") or {}).get("parts") or []
    text = "".join(p.get("text", "") for p in cparts if not p.get("thought")).strip()
    data = None
    if schema is not None:
        if not text:
            why = f"Gemini returned no text ({model}, finishReason {finish})"
            _mark_invalid(model, tag, why)
            raise GeminiError(why, 200)
        try:
            data = _parse_json_text(text)
        except ValueError:
            why = f"Gemini returned non-JSON ({model}, finishReason {finish}): {text[:200]}"
            _mark_invalid(model, tag, why)
            raise GeminiError(why, 200) from None
    return Reply(model, tag, text, data, meta["usage"], meta["ms"], meta["retries"], finish, resp)


async def generate_json(model: str, parts: list, schema: dict, system: str | None = None,
                        thinking: str | None = "low", media_resolution: str | None = None,
                        timeout: float = 60.0, tag: str = "generate", **kw):
    """Structured output: returns the parsed JSON value (see `generate` for the arguments)."""
    reply = await generate(model, parts, schema=schema, system=system, thinking=thinking,
                           media_resolution=media_resolution, timeout=timeout, tag=tag, **kw)
    return reply.data


async def decisions(input: list | str, questions: dict, *, model: str = "gemini-decision-1",
                    tag: str = "decisions", timeout: float = 15.0, attempts: int = MAX_ATTEMPTS) -> dict:
    """POST /v1beta/decisions. `input` is a list of {"type": "text"|"image"|"audio", ...} items
    (or one string). Put every question about the same input in ONE request: the input is billed
    once per request and there is no caching. Returns the full response ({answers, usage})."""
    if isinstance(input, str):
        input = [{"type": "text", "text": input}]
    resp, _meta = await post("decisions", {"model": model, "input": input, "questions": questions},
                             model=model, tag=tag, timeout=timeout, attempts=attempts)
    if "answers" not in resp:
        _mark_invalid(model, tag, "no answers")
        raise GeminiError(f"Decisions API returned no answers ({model})", 200)
    return resp


def pcm_to_wav(pcm: bytes, rate: int = 24000) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()


async def tts(text: str, voice: str = "Kore", *, model: str = "gemini-3.8-flash-lite-tts",
              tag: str = "tts", timeout: float = 20.0) -> bytes:
    """Speech for `text` as WAV bytes (the API returns 24 kHz PCM16, which we wrap)."""
    reply = await generate(model, [text], thinking=None, tag=tag, timeout=timeout, generation_config={
        "responseModalities": ["AUDIO"],
        "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice}}},
    })
    parts = ((reply.raw.get("candidates") or [{}])[0].get("content") or {}).get("parts", [])
    data = next((p["inlineData"] for p in parts if "inlineData" in p), None)
    if not data:
        _mark_invalid(model, tag, "no audio")
        raise GeminiError(f"no audio in TTS response ({model})", 200)
    raw = base64.b64decode(data["data"])
    if raw[:4] == b"RIFF":
        return raw
    rate = 24000
    for piece in str(data.get("mimeType", "")).split(";"):
        if piece.strip().startswith("rate="):
            rate = int(piece.split("=")[1])
    return pcm_to_wav(raw, rate)


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


async def mint_live_token(setup: dict, *, uses: int = 1, expire_s: int = 1800, new_session_s: int = 60,
                          field_mask: str | None = None, tag: str = "live_token", timeout: float = 10.0) -> dict:
    """Ephemeral Live API token with the whole session `setup` (a BidiGenerateContentSetup:
    model, generationConfig, systemInstruction, tools, ...) locked inside it.
    `field_mask` (comma-separated setup fields) locks only those fields, so the client may still
    send e.g. sessionResumption.handle (see live_setup.token_constraints).
    Returns {token, ws_url, model, expire_time, new_session_expire_time, ms}. The client opens
    ws_url, sends {"setup": {"sessionResumption": {}}} ({"handle": h} inside it when resuming)
    and streams. With a fieldMask that omits sessionResumption, {"setup": {}} gets no handles."""
    setup = dict(setup)
    model = str(setup.get("model") or "gemini-3.8-live")
    setup["model"] = model if model.startswith("models/") else f"models/{model}"
    now = datetime.now(timezone.utc)
    exp, new_exp = now + timedelta(seconds=expire_s), now + timedelta(seconds=new_session_s)
    body = {"uses": uses, "expireTime": _iso(exp), "newSessionExpireTime": _iso(new_exp),
            "bidiGenerateContentSetup": setup}
    if field_mask:
        body["fieldMask"] = field_mask
    short = setup["model"].removeprefix("models/")
    resp, meta = await post("auth_tokens", body, model=short, tag=tag, timeout=timeout)
    token = resp.get("name")
    if not token:
        raise GeminiError("auth_tokens returned no name", 200)
    return {"token": token, "ws_url": f"{LIVE_WS}?access_token={token}", "model": short,
            "expire_time": _iso(exp), "new_session_expire_time": _iso(new_exp), "ms": meta["ms"]}
