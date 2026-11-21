"""Guard against a runaway Gemini Live bill (docs/CORE_API.md §2, issue #10).

Live cost is per session minute and the apps talk to Gemini directly, so Core can't meter it.
What Core does see is every session *start*: each minted token (POST /api/live/token, uses: 1)
and each new browser socket on WS /api/live. This caps starts in a rolling window:
LIVE_MAX_STARTS (default 20, 0 = no cap) per LIVE_BUDGET_WINDOW_MIN minutes (default 10).
Browser resumes (WS /api/live?resume=) and goAway rotations reuse a session and don't count.
The apps mint a fresh token to reconnect once their token's first-session window
(LIVE_TOKEN_START_S) has passed, so those reconnects do count.
"""

from __future__ import annotations

import math
import os
import time
from collections import deque

_starts: deque[float] = deque()


def _env_num(name: str, default: float) -> float:
    """A finite, non-negative number from env, else `default` (so a typo never turns the cap off
    or crashes the mint)."""
    try:
        v = float(os.environ.get(name) or default)
    except ValueError:
        return default
    return v if math.isfinite(v) and v >= 0 else default


def limits() -> tuple[int, float]:
    """(max starts, window seconds), read per call so .env edits need no restart."""
    window = _env_num("LIVE_BUDGET_WINDOW_MIN", 10)
    return int(_env_num("LIVE_MAX_STARTS", 20)), (window if window > 0 else 10) * 60


def take(now: float | None = None) -> dict | None:
    """Count one session start. None if it fits the budget, else an error body for the client:
    {"error": "...", "retry_after_s": N} (N = seconds until the oldest start leaves the window)."""
    now = time.monotonic() if now is None else now
    cap, window = limits()
    while _starts and _starts[0] <= now - window:
        _starts.popleft()
    if cap <= 0 or len(_starts) < cap:
        _starts.append(now)
        return None
    retry = max(1, math.ceil(_starts[0] + window - now))
    return {"error": f"Live budget reached: {cap} sessions started in the last {window / 60:g} min "
                     f"(LIVE_MAX_STARTS). Try again in {math.ceil(retry / 60)} min.",
            "retry_after_s": retry}


def refund() -> None:
    """Give back one start whose session never opened (the mint or the upstream connect failed)."""
    if _starts:
        _starts.pop()
