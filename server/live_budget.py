"""Guard against a runaway Gemini Live bill (docs/CORE_API.md §2, issue #10).

Live cost is per session minute and the apps talk to Gemini directly, so Core can't meter it.
What Core does see is every session *start*: each minted token (POST /api/live/token, uses: 1)
and each new browser socket on WS /api/live. This caps starts in a rolling window:
LIVE_MAX_STARTS (default 20, 0 = no cap) per LIVE_BUDGET_WINDOW_MIN minutes (default 10).
Resumes and goAway rotations reuse a session and don't count.
"""

from __future__ import annotations

import math
import os
import time
from collections import deque

_starts: deque[float] = deque()


def _env_num(name: str, default: float) -> float:
    try:
        return max(0.0, float(os.environ.get(name) or default))
    except ValueError:
        return default


def limits() -> tuple[int, float]:
    """(max starts, window seconds), read per call so .env edits need no restart."""
    return int(_env_num("LIVE_MAX_STARTS", 20)), _env_num("LIVE_BUDGET_WINDOW_MIN", 10) * 60


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
    """Give back one start whose session never opened (the token mint failed)."""
    if _starts:
        _starts.pop()
