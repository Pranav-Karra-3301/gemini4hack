"""Check Core's token rules for proxied requests (docs/ARCHITECTURE.md §6, issue #9), offline.

Usage: cd server && uv run --no-sync python checks/proxy_auth_check.py

The Vite dev proxy forwards with xfwd, so every /api request from it carries X-Forwarded-For and
arrives from a loopback peer. Localhost through the proxy must pass without a token; a LAN client
through the proxy, a spoofed X-Forwarded-For from a LAN peer, and tunnel requests need the token.
Calls app.token_ok / app.is_local directly with a throwaway COACH_TOKEN; no server, no models.
"""

import os
import sys
from pathlib import Path

SERVER = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVER))
os.environ["COACH_TOKEN"] = "proxy-auth-check"

import app  # noqa: E402

TOKEN = os.environ["COACH_TOKEN"]
LAN = "192.168.1.23"
BEARER = {"authorization": f"Bearer {TOKEN}"}

# (name, headers, cookies, peer, token_ok expected, is_local expected)
CASES = [
    ("loopback direct", {}, {}, "127.0.0.1", True, True),
    ("localhost via vite (xfwd)", {"x-forwarded-for": "127.0.0.1"}, {}, "127.0.0.1", True, True),
    ("::1 via vite (xfwd)", {"x-forwarded-for": "::1"}, {}, "127.0.0.1", True, True),
    ("LAN via vite, no token", {"x-forwarded-for": LAN}, {}, "127.0.0.1", False, False),
    ("LAN via vite, bearer", {"x-forwarded-for": LAN, **BEARER}, {}, "127.0.0.1", True, False),
    ("LAN via vite, cookie", {"x-forwarded-for": LAN}, {"coach_k": TOKEN}, "127.0.0.1", True, False),
    ("LAN via vite, spoofed 127.0.0.1 first", {"x-forwarded-for": f"127.0.0.1, {LAN}"}, {}, "127.0.0.1",
     False, False),
    ("LAN direct, spoofed xff", {"x-forwarded-for": "127.0.0.1"}, {}, LAN, False, False),
    ("LAN direct, no token", {}, {}, LAN, False, False),
    ("tunnel (cf-connecting-ip)", {"cf-connecting-ip": "1.2.3.4", "x-forwarded-for": "1.2.3.4"}, {},
     "127.0.0.1", False, False),
    ("tunnel via vite (loopback xff)", {"cf-connecting-ip": "1.2.3.4", "x-forwarded-for": "127.0.0.1"}, {},
     "127.0.0.1", False, False),
    ("Forwarded header", {"forwarded": "for=127.0.0.1"}, {}, "127.0.0.1", False, False),
    ("xff with unknown peer", {"x-forwarded-for": "127.0.0.1"}, {}, None, False, False),
]


def main() -> int:
    failed = 0
    for name, headers, cookies, peer, want_ok, want_local in CASES:
        ok = app.token_ok(headers, cookies, peer)
        local = app.is_local(headers, peer)
        good = ok == want_ok and local == want_local
        failed += not good
        print(f"{'ok  ' if good else 'FAIL'} {name}: token_ok={ok} is_local={local}")
    print(f"{len(CASES) - failed}/{len(CASES)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
