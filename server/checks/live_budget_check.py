"""Check the Live spend cap (server/live_budget.py, issue #10) offline.

Usage: cd server && uv run --no-sync python checks/live_budget_check.py

1. The rolling window: LIVE_MAX_STARTS starts per LIVE_BUDGET_WINDOW_MIN pass, the next one gets
   an error with retry_after_s, and starts leave the window on time; LIVE_MAX_STARTS=0 is no cap.
2. POST /api/live/token through the real router with gemini.mint_live_token faked: 200s up to the
   cap, then 429 + Retry-After + {"error", "retry_after_s"}; a failed mint doesn't use budget.
3. WS /api/live over the cap: {"error", "retry_after_s"} then close 1013.
No Gemini calls, no server, no models.
"""

import os
import sys
from pathlib import Path

SERVER = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVER))

from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from starlette.websockets import WebSocketDisconnect  # noqa: E402

import cam  # noqa: E402
import gemini  # noqa: E402
import live_budget  # noqa: E402
import live_token  # noqa: E402

failures: list[str] = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        failures.append(msg)


def reset(cap: int, window_min: float) -> None:
    os.environ["LIVE_MAX_STARTS"] = str(cap)
    os.environ["LIVE_BUDGET_WINDOW_MIN"] = str(window_min)
    live_budget._starts.clear()


def window() -> None:
    print("rolling window")
    reset(3, 10)
    check([live_budget.take(now=t) for t in (0, 1, 2)] == [None] * 3, "3 starts within the cap pass")
    over = live_budget.take(now=100)
    check(over is not None and over["retry_after_s"] == 500, f"4th start refused, retry in 500 s: {over}")
    check(over is not None and "LIVE_MAX_STARTS" in over["error"] and "9 min" in over["error"],
          f"error names the env var and the wait: {over and over['error']!r}")
    check(live_budget.take(now=599) is not None, "still refused just before the first start expires")
    check(live_budget.take(now=600) is None, "passes once the first start leaves the window")
    live_budget.refund()
    check(len(live_budget._starts) == 2, "refund gives one start back")
    reset(0, 10)
    check(all(live_budget.take(now=t) is None for t in range(50)), "LIVE_MAX_STARTS=0: no cap")
    os.environ["LIVE_MAX_STARTS"] = "junk"
    check(live_budget.limits()[0] == 20, "a bad LIVE_MAX_STARTS falls back to 20")


def routes() -> None:
    print("routes")
    app = FastAPI()
    app.include_router(live_token.router)
    app.include_router(cam.router)
    client = TestClient(app)
    real_mint = gemini.mint_live_token
    fail = {"on": False}

    async def fake_mint(*args, **kwargs):
        if fail["on"]:
            raise gemini.GeminiError("fake upstream failure")
        return {"token": "auth_tokens/fake", "ws_url": "wss://example.invalid/ws", "model": "fake",
                "expire_time": "2026-01-01T00:00:00Z", "new_session_expire_time": "2026-01-01T00:00:00Z",
                "ms": 1}

    gemini.mint_live_token = fake_mint
    try:
        reset(2, 10)
        codes = [client.post("/api/live/token", json={"mode": "camera"}).status_code for _ in range(2)]
        check(codes == [200, 200], f"two mints under the cap: {codes}")
        r = client.post("/api/live/token", json={"mode": "camera"})
        body = r.json()
        check(r.status_code == 429, f"third mint -> {r.status_code}")
        check(r.headers.get("retry-after") == str(body.get("retry_after_s")) and body.get("retry_after_s", 0) > 0,
              f"Retry-After {r.headers.get('retry-after')} matches retry_after_s {body.get('retry_after_s')}")
        check("Live budget reached" in body.get("error", ""), f"error text: {body.get('error')!r}")

        reset(1, 10)
        fail["on"] = True
        r = client.post("/api/live/token", json={"mode": "camera"})
        check(r.status_code == 502, f"failed mint -> {r.status_code}")
        fail["on"] = False
        r = client.post("/api/live/token", json={"mode": "camera"})
        check(r.status_code == 200, f"a failed mint didn't use the budget: next mint -> {r.status_code}")

        reset(1, 10)
        live_budget.take()
        os.environ.setdefault("GEMINI_API_KEY", "fake-key-for-check")
        msg, code = None, None
        try:
            with client.websocket_connect("/api/live") as ws:
                msg = ws.receive_json()
                ws.receive_text()
        except WebSocketDisconnect as exc:
            code = exc.code
        check(bool(msg) and "Live budget reached" in msg.get("error", "") and msg.get("retry_after_s", 0) > 0,
              f"WS over the cap sends the error: {msg}")
        check(code == 1013, f"WS closes 1013: {code}")
    finally:
        gemini.mint_live_token = real_mint


def main() -> int:
    window()
    routes()
    print(f"{len(failures)} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
