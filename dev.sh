#!/usr/bin/env bash
# Start the lighting coach: API (Coach Core) on :8787, web on :5320. Ctrl-C stops both.
#   ./dev.sh        API on 127.0.0.1: this Mac only, no auth.
#   ./dev.sh lan    API on 0.0.0.0 with COACH_LAN=1: other devices need the coach token
#                   (server/.coach_token, created on first start), Core advertises Bonjour
#                   _coachcore._tcp, and the iPhone pairing URL (+ QR) is printed.
# COACH_PORT overrides the API port (the web proxy follows it).
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-local}"
case "$MODE" in local|lan) ;; *) echo "usage: ./dev.sh [lan]" >&2; exit 2 ;; esac
export COACH_PORT="${COACH_PORT:-8787}"
HOST=127.0.0.1
if [ "$MODE" = lan ]; then export COACH_LAN=1; HOST=0.0.0.0; fi
trap 'kill 0' EXIT INT TERM
(cd server && exec uv run uvicorn app:app --host "$HOST" --port "$COACH_PORT") &
(cd web && API_PORT="$COACH_PORT" npm run dev) &
if [ "$MODE" = lan ]; then
  (
    for _ in $(seq 1 300); do
      if pair=$(curl -sf --max-time 1 "http://127.0.0.1:$COACH_PORT/api/pair"); then
        url=$(printf '%s' "$pair" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')
        echo
        echo "  Pair the iPhone (CoachCam > Pair, or scan):  $url"
        echo
        uvx --quiet --from qrcode qr --ascii "$url" 2>/dev/null || true
        break
      fi
      sleep 1
    done
  ) &
fi
wait
