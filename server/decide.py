"""Decision-1-style scoring of a photo's lighting and composition.

Gemini Decision 1 (Decisions API) answers closed-set questions with probabilities instead of
text. It is not on OpenRouter, so the default backend *emulates* a `score` question: the model
must answer with one digit 1-5, and we read the distribution over those digits from the first
answer token's top logprobs (a real token distribution, not a number the model verbalizes).

Per dimension we return (see ../CONTRACT.md, /api/score):
  distribution  P(level) for "1".."5", renormalized over the digit tokens in the top logprobs.
  score         expected value of the distribution (1..5).
  confidence    probability of the modal level, max_k P(k). This is the definition the real
                Decisions API uses ("the probability of the top answer"), so switching backends
                does not change its meaning, and it reads directly as "how likely the single
                best level is right". Range is [0.2, 1] for 5 levels.
  valid_mass    (extra field) raw probability mass that landed on the digits 1-5 before
                renormalization. Sanity check: a low value means the model wanted to say
                something other than a digit; below MIN_VALID_MASS we raise instead of
                inventing a distribution.
  label         <= 70 char human summary, from one cheap concurrent JSON call; "" on failure
                or if it isn't back LABEL_GRACE_S after the scores.

Model choice (tested 2026-11-20 on the sample photos): xiaomi/mimo-v2.6-pro gives spread,
non-degenerate distributions (modal mass ~0.55-0.8) with ~1 s latency. nvidia/nemotron-3.5-
super-vl is faster but puts ~95% on "4" for nearly everything; qwen/qwen3.8-omni-flash works but
caps top_logprobs at 5 and takes ~3 s. Override with env DECIDE_MODEL / DECIDE_LABEL_MODEL.

If GEMINI_API_KEY is set (the normal case), the real Decisions API scores both rubrics in ONE
request (the image is billed once; ~0.5-1 s) and the labels come from a fast Gemini Flash-Lite
call with minimal thinking (~1.1 s, inside the grace window), both through gemini.py. The
OpenRouter emulation and nemotron labels are the no-key fallback. Numbers: ../docs/BEST_PRACTICES.md.
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
import os
import re
import time

import httpx

import gemini

log = logging.getLogger("coach.decide")

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
DECISIONS_MODEL = "gemini-decision-1"
# Labels on the Gemini path: Flash-Lite with minimal thinking took 1.05-1.25 s (p50 ~1.1 s) with a
# medium-resolution image on 2026-11-21, vs 4.8-5.3 s for gemini-4-hydrogen at thinking "low".
GEMINI_LABEL_MODEL = os.environ.get("DECIDE_LABEL_GEMINI_MODEL", "gemini-3.5-flash-lite")
LABEL_SCHEMA = {
    "type": "object",
    "properties": {"lighting": {"type": "string"}, "composition": {"type": "string"}},
    "required": ["lighting", "composition"],
}
DEFAULT_MODEL = "xiaomi/mimo-v2.6-pro"
DEFAULT_LABEL_MODEL = "nvidia/nemotron-3.5-super-vl"
LONG_SIDE = 1024
TOP_LOGPROBS = 20
TOP_LOGPROBS_CAPS = {"qwen/": 5}  # Alibaba rejects top_logprobs > 5
MIN_VALID_MASS = 0.3
LABEL_TIMEOUT_S = 12  # hard cap on the label call
LABEL_GRACE_S = 1.5  # how long labels may lag the scores before we return without them
LEVELS = ("1", "2", "3", "4", "5")

RUBRICS: dict[str, dict] = {
    "lighting": {
        "instructions": (
            "Rate the LIGHTING of this photo. Judge only the light, not the subject or the "
            "composition. Consider exposure (clipped highlights, crushed shadows), light direction "
            "(flat front light vs. side or back light that shapes the subject), quality (soft vs. "
            "harsh, hard shadows on faces), contrast, color temperature (pleasing and consistent "
            "vs. color casts), and how well light separates the subject from the background."
        ),
        "criteria": [
            "Poor: badly over- or underexposed with large clipped or crushed areas, harsh or ugly "
            "light, strong color cast, subject lost in the background.",
            "Weak: clear exposure error or harsh/flat light, hard shadows on faces or a "
            "distracting color cast, little subject separation.",
            "Adequate: roughly correct exposure but ordinary, flat or slightly harsh light; minor "
            "contrast or color issues; some separation.",
            "Good: well exposed, light with clear direction and pleasing quality, controlled "
            "contrast, clean color, subject clearly separated.",
            "Excellent: deliberate, beautiful light (e.g. golden hour, sculpted window light), "
            "flawless exposure and color, strong separation and mood.",
        ],
    },
    "composition": {
        "instructions": (
            "Rate the COMPOSITION of this photo. Judge only framing and arrangement, not the light "
            "or how appealing the subject is. Consider subject placement (rule of thirds, negative "
            "space), framing and crop (cut-off heads or limbs, cramped or empty edges), leading "
            "lines, visual balance, distractions (clutter, objects at the edges, things growing "
            "out of heads), and whether the horizon and verticals are straight."
        ),
        "criteria": [
            "Poor: no clear subject or subject badly cut off, tilted horizon, cluttered and "
            "unbalanced, distractions dominate.",
            "Weak: subject identifiable but awkwardly placed or cramped, clumsy crop, noticeable "
            "distractions or tilt.",
            "Adequate: clear subject with snapshot framing (centered, some wasted space or minor "
            "distractions), no strong structure.",
            "Good: deliberate placement, clean framing and edges, lines or shapes guide the eye, "
            "balanced, few distractions, level horizon.",
            "Excellent: strong intentional design where placement, leading lines, layering and "
            "balance all work and nothing distracts.",
        ],
    },
}

LABEL_PROMPT = (
    "Describe this photo's LIGHTING and its COMPOSITION, each as one short coaching-style phrase "
    "of at most 8 words (under 60 characters, no trailing period) naming what works and the "
    "main flaw. "
    'Reply with JSON only: {"lighting": "...", "composition": "..."}'
)

_client: httpx.AsyncClient | None = None
_client_loop: asyncio.AbstractEventLoop | None = None


def _http() -> httpx.AsyncClient:
    """One pooled client per event loop (reuses TLS connections across requests)."""
    global _client, _client_loop
    loop = asyncio.get_running_loop()
    if _client is None or _client.is_closed or _client_loop is not loop:
        _client = httpx.AsyncClient(timeout=httpx.Timeout(45.0, connect=10.0))
        _client_loop = loop
    return _client


def _prepare(image_bytes: bytes) -> str:
    """EXIF-rotate, downscale to LONG_SIDE, re-encode as JPEG; return base64."""
    return gemini.b64(gemini.prepare_jpeg(image_bytes, LONG_SIDE))


def _prompt(rubric: dict) -> str:
    scale = "\n".join(f"{i} = {c}" for i, c in enumerate(rubric["criteria"], 1))
    return f"{rubric['instructions']}\nScale:\n{scale}\nAnswer with a single digit from 1 to 5 and nothing else."


def _image_part(b64: str) -> dict:
    return {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}}


async def _openrouter(body: dict, tag: str) -> dict:
    key = os.environ.get("OPENROUTER_API_KEY")
    if not key:
        raise RuntimeError("OPENROUTER_API_KEY is not set")
    t0, model = time.perf_counter(), f"openrouter:{body['model']}"
    try:
        r = await _http().post(OPENROUTER_URL, json=body, headers={"Authorization": f"Bearer {key}"})
        try:
            data = r.json()
        except ValueError:
            raise RuntimeError(f"OpenRouter HTTP {r.status_code}: {r.text[:200]}") from None
        if r.status_code != 200 or "error" in data:
            err = data.get("error", data)
            msg = err.get("message", err) if isinstance(err, dict) else err
            raw = (err.get("metadata") or {}).get("raw", "") if isinstance(err, dict) else ""
            raise RuntimeError(f"OpenRouter HTTP {r.status_code} ({body['model']}): {msg} {raw}"[:400])
    except BaseException as exc:  # incl. cancellation by the label grace timeout
        gemini.record(model, tag, (time.perf_counter() - t0) * 1000, ok=False, error=f"{type(exc).__name__}: {exc}")
        raise
    u = data.get("usage") or {}
    gemini.record(model, tag, (time.perf_counter() - t0) * 1000,
                  usage={"input": u.get("prompt_tokens"), "output": u.get("completion_tokens")})
    return data


def _summarize(dist: dict[str, float], valid_mass: float) -> dict:
    ev = sum(int(k) * p for k, p in dist.items())
    return {
        "score": round(ev, 2),
        "scale": [1, 5],
        "confidence": round(max(dist.values()), 3),
        "distribution": {k: round(p, 3) for k, p in dist.items()},
        "valid_mass": round(valid_mass, 3),
        "label": "",
    }


async def _score_emulated(model: str, name: str, b64: str) -> dict:
    top_k = next((cap for prefix, cap in TOP_LOGPROBS_CAPS.items() if model.startswith(prefix)), TOP_LOGPROBS)
    data = await _openrouter({
        "model": model,
        "messages": [{"role": "user", "content": [_image_part(b64), {"type": "text", "text": _prompt(RUBRICS[name])}]}],
        "temperature": 0,
        "max_tokens": 3,
        "logprobs": True,
        "top_logprobs": top_k,
        "reasoning": {"enabled": False},  # first output token must be the answer
        "provider": {"require_parameters": True},  # only providers that honor logprobs
    }, "score")
    positions = ((data["choices"][0].get("logprobs") or {}).get("content")) or []
    if not positions:
        raise RuntimeError(f"{model} returned no logprobs for {name}")
    # First non-whitespace token is the answer digit.
    pos = next((p for p in positions if p.get("token", "").strip()), positions[0])
    mass = {k: 0.0 for k in LEVELS}
    for alt in pos.get("top_logprobs") or []:
        tok = alt.get("token", "").strip()
        if tok in mass:
            mass[tok] += math.exp(alt["logprob"])
    valid = sum(mass.values())
    if valid < MIN_VALID_MASS:
        raise RuntimeError(
            f"{model}: only {valid:.2f} probability on digits 1-5 for {name} "
            f"(answer token {pos.get('token')!r})"
        )
    return _summarize({k: v / valid for k, v in mass.items()}, valid)


def _clean_labels(obj: dict) -> dict[str, str]:
    out = {}
    for k in RUBRICS:
        s = " ".join(str(obj.get(k, "")).split()).rstrip(".")
        out[k] = s if len(s) <= 70 else s[:69].rsplit(" ", 1)[0] + "…"
    return out


async def _labels(b64: str) -> dict[str, str]:
    """Both labels from one cheap call (Gemini Flash-Lite if GEMINI_API_KEY is set, else
    OpenRouter). Never raises: returns empty labels on any failure."""
    if gemini.has_key():
        model = GEMINI_LABEL_MODEL
        try:
            # One attempt: a retried label would miss the grace window anyway.
            obj = await gemini.generate_json(
                model, [gemini.image_part(b64), LABEL_PROMPT], LABEL_SCHEMA, thinking="minimal",
                media_resolution="medium", timeout=LABEL_TIMEOUT_S, tag="score_labels", attempts=1)
            return _clean_labels(obj if isinstance(obj, dict) else {})
        except Exception as exc:
            log.warning("decide labels failed (%s): %s: %s", model, type(exc).__name__, exc)
            return {k: "" for k in RUBRICS}
    model = os.environ.get("DECIDE_LABEL_MODEL", DEFAULT_LABEL_MODEL)
    try:
        data = await asyncio.wait_for(_openrouter({
            "model": model,
            "messages": [{"role": "user", "content": [_image_part(b64), {"type": "text", "text": LABEL_PROMPT}]}],
            "temperature": 0,
            "max_tokens": 120,
            "reasoning": {"enabled": False},
        }, "score_labels"), LABEL_TIMEOUT_S)
        text = data["choices"][0]["message"].get("content") or ""
        return _clean_labels(json.loads(re.search(r"\{.*\}", text, re.S).group(0)))
    except Exception as exc:
        log.warning("decide labels failed (%s): %s: %s", model, type(exc).__name__, exc)
        return {k: "" for k in RUBRICS}


async def _score_gemini(b64: str) -> dict[str, dict]:
    # Both rubrics in ONE Decisions request: the image is billed once (the API has no caching).
    # Score levels are indexed from 0 and `score` is the probability-weighted mean index.
    res = await gemini.decisions(
        [{"type": "image", "data": b64, "mime_type": "image/jpeg", "resolution": "medium"}],
        {name: {"type": "score", "instructions": r["instructions"], "criteria": r["criteria"]}
         for name, r in RUBRICS.items()},
        model=DECISIONS_MODEL, tag="score", timeout=15.0,
    )
    answers = res["answers"]
    out = {}
    for name in RUBRICS:
        probs = answers[name]["probabilities"]
        dist = {str(int(i) + 1): float(p) for i, p in probs.items()}
        dist = {k: dist.get(k, 0.0) for k in LEVELS}
        res = _summarize(dist, sum(dist.values()))
        res["score"] = round(float(answers[name]["score"]) + 1, 2)
        res["confidence"] = round(float(answers[name]["confidence"]), 3)
        out[name] = res
    return out


async def score_photo(image_bytes: bytes, mime: str) -> dict:
    """Score lighting and composition; returns the /api/score shape from CONTRACT.md.

    `mime` is accepted for the app's signature; the image is always re-encoded to JPEG.
    """
    t0 = time.perf_counter()
    b64 = await asyncio.to_thread(_prepare, image_bytes)
    gemini_key = gemini.has_key()
    labels_task = (asyncio.create_task(_labels(b64))
                   if gemini_key or os.environ.get("OPENROUTER_API_KEY") else None)

    try:
        if gemini_key:
            provider = DECISIONS_MODEL
            scores = await _score_gemini(b64)
        else:
            model = os.environ.get("DECIDE_MODEL", DEFAULT_MODEL)
            provider = f"emulated:{model}"
            results = await asyncio.gather(*(_score_emulated(model, name, b64) for name in RUBRICS))
            scores = dict(zip(RUBRICS, results))
    except BaseException:
        if labels_task:
            labels_task.cancel()
        raise

    labels: dict[str, str] = {}
    if labels_task:
        try:  # labels are optional: don't let a slow label call hold the scores hostage
            labels = await asyncio.wait_for(labels_task, LABEL_GRACE_S)
        except asyncio.TimeoutError:
            log.warning("decide labels still pending %.1fs after scores; returning without", LABEL_GRACE_S)
    for name, res in scores.items():
        res["label"] = labels.get(name, "")
    return {"provider": provider, "scores": scores, "ms": int((time.perf_counter() - t0) * 1000)}
