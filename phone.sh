#!/usr/bin/env bash
# Open Coach Cam on your phone (iPhone Safari or Android Chrome), no app install.
#
# Starts the API (:8787) and web (:5320) if they aren't already running, then opens a Cloudflare
# quick tunnel: a public HTTPS URL, which phone camera/mic access requires. The tunnel is gated
# by the coach token (server/.coach_token, the same one LAN mode uses; see docs/CORE_API.md §1).
# Only the printed URL (with ?k=) can use the API, which spends your Gemini credit. Ctrl-C closes
# the tunnel; it also revokes the token if this script created it (a LAN token is left alone).
set -euo pipefail
cd "$(dirname "$0")"
PAGE="${1:-cam.html}"
TOKEN_FILE=server/.coach_token

up() { curl -s -o /dev/null --max-time 1 "$1"; }
pids=()
CREATED=0
cleanup() {
  if [ "$CREATED" = 1 ]; then rm -f "$TOKEN_FILE"; fi
  for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM

if ! up http://127.0.0.1:8787/api/health; then
  (cd server && exec uv run uvicorn app:app --host 127.0.0.1 --port 8787) & pids+=($!)
fi
if ! up http://localhost:5320/; then
  (cd web && exec npm run dev) & pids+=($!)
fi
echo "waiting for the API and web server…"
for _ in $(seq 1 120); do up http://127.0.0.1:8787/api/health && up http://localhost:5320/ && break; sleep 1; done

if [ -n "${COACH_TOKEN:-}" ]; then
  TOKEN="$COACH_TOKEN"
else
  if [ ! -s "$TOKEN_FILE" ]; then
    (umask 077 && openssl rand -hex 16 > "$TOKEN_FILE")
    CREATED=1
  fi
  chmod 600 "$TOKEN_FILE"
  TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
fi

cloudflared tunnel --no-autoupdate --url http://localhost:5320 2>&1 | while IFS= read -r line; do
  if [[ $line =~ (https://[a-z0-9-]+\.trycloudflare\.com) ]]; then
    URL="${BASH_REMATCH[1]}/${PAGE}?k=${TOKEN}"
    echo
    echo "  Open on your phone:  $URL"
    echo
    uvx --quiet --from qrcode qr --ascii "$URL" 2>/dev/null || true
    echo "  (same Wi-Fi not needed. Ctrl-C to close the tunnel.)"
  fi
done
