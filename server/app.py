"""Coach Core API. Run: cd server && uv run uvicorn app:app --port 8787 (or ../dev.sh [lan]).

Reaching Core (docs/CORE_API.md §1): loopback clients pass; requests through the Cloudflare tunnel
(cf-connecting-ip) and LAN clients need the coach token (Authorization: Bearer <token> or cookie
coach_k). COACH_LAN=1 (with uvicorn --host 0.0.0.0) creates server/.coach_token if needed and
advertises Bonjour _coachcore._tcp on COACH_PORT (default 8787) while the server runs.
"""

import asyncio
import hmac
import importlib
import ipaddress
import json
import logging
import os
import secrets
import socket
import subprocess
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlsplit

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

from fastapi import FastAPI, File, Form, Request, UploadFile  # noqa: E402
from fastapi.concurrency import run_in_threadpool  # noqa: E402
from fastapi.middleware.cors import CORSMiddleware  # noqa: E402
from fastapi.responses import JSONResponse, Response  # noqa: E402

import decide  # noqa: E402
import depth  # noqa: E402
import gemini  # noqa: E402
import regions  # noqa: E402
import segment  # noqa: E402

log = logging.getLogger("coach")


VERSION = 1
LAN = os.environ.get("COACH_LAN") == "1"
TOKEN_FILE = Path(__file__).resolve().parent / ".coach_token"


def coach_port() -> int:
    try:
        return int(os.environ.get("COACH_PORT") or 8787)
    except ValueError:
        return 8787


def ensure_token_file() -> None:
    """LAN mode: create server/.coach_token (32 hex chars, chmod 600) unless COACH_TOKEN is set or
    the file exists. phone.sh reuses the same file."""
    if os.environ.get("COACH_TOKEN"):
        return
    try:
        fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        os.chmod(TOKEN_FILE, 0o600)
        if TOKEN_FILE.read_text().strip():
            return
        fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_TRUNC)
    with os.fdopen(fd, "w") as f:
        f.write(secrets.token_hex(16) + "\n")


def bonjour_name() -> str:
    return f"Coach Core ({socket.gethostname().split('.')[0]})"


# dns-sd runs under a tiny sh watchdog so the advertisement also ends if this process is
# SIGKILLed (the watchdog polls our pid); a normal shutdown terminates it right away.
_BONJOUR_SH = """dns-sd -R "$1" _coachcore._tcp local "$2" v=1 >/dev/null 2>&1 &
p=$!
trap 'kill $p 2>/dev/null; exit 0' TERM INT HUP
while kill -0 "$3" 2>/dev/null && kill -0 $p 2>/dev/null; do sleep 1 & wait $!; done
kill $p 2>/dev/null"""


def start_bonjour() -> subprocess.Popen | None:
    try:
        return subprocess.Popen(
            ["/bin/sh", "-c", _BONJOUR_SH, "coach-bonjour", bonjour_name(), str(coach_port()), str(os.getpid())],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        log.exception("could not start dns-sd (Bonjour)")
        return None


def stop_bonjour(proc: subprocess.Popen | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    bonjour = None
    if LAN:
        ensure_token_file()
    # Open the pooled Gemini connection in the background (DNS + TLS, ~150 ms) so the first real
    # call (often a live-token mint) doesn't pay for it. Never raises, never blocks startup.
    warm = asyncio.create_task(gemini.warm())
    # COACH_WARMUP=0 skips loading Depth Pro and SAM at startup (they load on first use).
    if os.environ.get("COACH_WARMUP", "1") != "0":
        for name, fn in (("depth", depth.warmup), ("segment", segment.warmup)):
            try:
                await run_in_threadpool(fn)
            except Exception:  # keep the other endpoints usable if one model fails to load
                log.exception("%s warmup failed", name)
    if LAN:  # advertise once we're about to accept connections
        bonjour = start_bonjour()
    try:
        yield
    finally:
        stop_bonjour(bonjour)
        warm.cancel()
        try:
            await gemini.aclose()
        except Exception:  # noqa: BLE001
            pass


app = FastAPI(title="lighting-coach", lifespan=lifespan)

# Optional feature routers: each module exposes `router` (an APIRouter). A broken or missing
# module is logged and skipped so the rest of the API keeps working.
for _mod in ("cam", "splat", "live_token", "looks", "review", "semantic", "stats", "shots"):  # specific routes before shots' catch-all
    try:
        app.include_router(importlib.import_module(_mod).router)
    except ModuleNotFoundError as exc:
        if exc.name != _mod:
            log.exception("router %s failed to import", _mod)
    except Exception:
        log.exception("router %s failed to import", _mod)


def coach_token() -> str | None:
    """The coach token: env COACH_TOKEN, else server/.coach_token (created on the first LAN start,
    or by phone.sh while its tunnel is up), read per request so a new file needs no restart."""
    if os.environ.get("COACH_TOKEN"):
        return os.environ["COACH_TOKEN"]
    try:
        return TOKEN_FILE.read_text().strip() or None
    except OSError:
        return None


def _is_loopback(host: str | None) -> bool:
    if not host:
        return False
    try:
        ip = ipaddress.ip_address(host.split("%")[0])
    except ValueError:
        return host in ("localhost", "testclient")  # Starlette's in-process TestClient
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip.is_loopback


def _proxied(headers, client_host: str | None = None) -> bool:
    """Came through a proxy (the Cloudflare tunnel, or anything that forwards for someone else):
    the TCP peer being loopback says nothing about the real client then. The one exception is the
    local Vite proxy (xfwd) forwarding for this Mac: a loopback peer whose X-Forwarded-For hops are
    all loopback. X-Forwarded-For from any other peer is never trusted."""
    if headers.get("cf-connecting-ip") or headers.get("forwarded"):
        return True
    xff = headers.get("x-forwarded-for")
    if not xff:
        return False
    hops = [h.strip() for h in xff.split(",")]
    return not (_is_loopback(client_host) and all(_is_loopback(h) for h in hops))


def _foreign_origin(headers) -> bool:
    """A browser request from a page that isn't served from this Mac (Origin not localhost /
    loopback, or "null"). Every coach page calls /api on its own origin through Vite, so a
    foreign Origin means some other website is calling Core; it must not get the loopback
    exemption (it could read /api/pair's token or open paid Live sessions)."""
    origin = headers.get("origin")
    if not origin:
        return False
    try:
        host = urlsplit(origin).hostname
    except ValueError:
        return True
    return not (host and _is_loopback(host))


def _same(a: str, b: str) -> bool:
    return bool(a) and hmac.compare_digest(a.encode(), b.encode())


def token_ok(headers, cookies, client_host: str | None = None) -> bool:
    """Loopback requests pass, unless a web page from another site sent them (a foreign `Origin`).
    Tunnel requests (cf-connecting-ip / forwarded) and LAN requests (a
    non-loopback peer) need the coach token as `Authorization: Bearer <token>` or cookie
    `coach_k`. `client_host` None means the caller didn't say; then only the proxy rule applies
    (the ASGI gate below always passes the peer)."""
    if (not _proxied(headers, client_host) and not _foreign_origin(headers)
            and (client_host is None or _is_loopback(client_host))):
        return True
    token = coach_token()
    if not token:
        return False
    auth = headers.get("authorization") or ""
    bearer = auth[7:].strip() if auth[:7].lower() == "bearer " else ""
    return _same(bearer, token) or _same(cookies.get("coach_k") or "", token)


def is_local(headers, client_host: str | None) -> bool:
    """A direct loopback request (the Mac itself), not a tunnel, LAN client or foreign web page."""
    return _is_loopback(client_host) and not _proxied(headers, client_host) and not _foreign_origin(headers)


class TokenGate:
    """Pure ASGI gate for HTTP and WebSocket (no BaseHTTPMiddleware overhead, and it also covers
    every WS route). Applies token_ok to every path when the peer isn't plain loopback."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] not in ("http", "websocket"):
            return await self.app(scope, receive, send)
        from starlette.requests import HTTPConnection

        conn = HTTPConnection(scope)
        host = conn.client.host if conn.client else None
        if token_ok(conn.headers, conn.cookies, host or ""):
            return await self.app(scope, receive, send)
        if scope["type"] == "websocket":
            await send({"type": "websocket.close", "code": 1008, "reason": "missing or wrong coach token"})
            return
        await JSONResponse({"error": "missing or wrong coach token"}, status_code=401,
                           headers={"WWW-Authenticate": "Bearer"})(scope, receive, send)


app.add_middleware(TokenGate)

DEPTH_HEADERS = [
    "X-Depth-Width", "X-Depth-Height", "X-Depth-Min", "X-Depth-Max",
    "X-Depth-P02", "X-Depth-P98", "X-Focal-Px", "X-Infer-Ms", "X-Device",
    "X-Splat-Width", "X-Splat-Height", "X-Splat-Focal-Px", "X-Splat-Focal-Source", "X-Splat-Ms",
    "X-Splat-Cache",
]
app.add_middleware(  # pages on this Mac only; the coach pages are same-origin through Vite anyway
    CORSMiddleware, allow_origin_regex=r"https?://(localhost|127\.\d+\.\d+\.\d+|\[::1\])(:\d+)?",
    allow_methods=["*"], allow_headers=["*"], expose_headers=DEPTH_HEADERS,
)


def _err(status: int, exc: Exception) -> JSONResponse:
    log.exception("request failed")
    return JSONResponse({"error": f"{type(exc).__name__}: {exc}"}, status_code=status)


def _model_states() -> dict:
    def state(mod, attr="_model", err_attr=None):
        if getattr(mod, attr, None) is not None:
            return "warm"
        return "error" if err_attr and getattr(mod, err_attr, None) else "cold"

    out = {"depth": state(depth), "segment": state(segment, err_attr="_load_error")}
    try:
        import live_setup
        out["live"] = live_setup.live_model()
    except Exception:
        pass
    return out


@app.get("/api/health")
async def health():
    return {"ok": True, "version": VERSION, "lan": LAN, "port": coach_port(), "models": _model_states()}


def lan_ip() -> str | None:
    """The Mac's LAN address (env COACH_LAN_HOST overrides): the source address of the default
    route (a UDP connect sends no packets), else en0/en1."""
    if os.environ.get("COACH_LAN_HOST"):
        return os.environ["COACH_LAN_HOST"]
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
            if ip and not ip.startswith("127."):
                return ip
    except OSError:
        pass
    for iface in ("en0", "en1"):
        try:
            ip = subprocess.run(["ipconfig", "getifaddr", iface], capture_output=True, text=True,
                                timeout=2).stdout.strip()
            if ip:
                return ip
        except (OSError, subprocess.SubprocessError):
            pass
    return None


@app.get("/api/pair")
async def pair(request: Request):
    """Pairing info for the iPhone (the Mac app shows `url` as a QR code). Loopback only."""
    if not is_local(request.headers, request.client.host if request.client else None):
        return JSONResponse({"error": "pairing info is only available on the Mac itself"}, status_code=403)
    if not LAN:
        return JSONResponse({"error": "LAN mode is off: start Core with COACH_LAN=1 (./dev.sh lan)"},
                            status_code=409)
    token = coach_token()
    host = await asyncio.to_thread(lan_ip)
    if not token or not host:
        return JSONResponse({"error": "no coach token or LAN address yet"}, status_code=503)
    port = coach_port()
    return {"host": host, "port": port, "token": token, "name": bonjour_name(),
            "url": f"coach://pair?host={host}&port={port}&token={token}"}


@app.post("/api/depth")
async def api_depth(image: UploadFile = File(...)):
    data = await image.read()
    try:
        arr, meta = await run_in_threadpool(depth.infer_depth, data)
    except Exception as exc:
        return _err(500, exc)
    headers = {
        "X-Depth-Width": str(meta["width"]), "X-Depth-Height": str(meta["height"]),
        "X-Depth-Min": f'{meta["min"]:.4f}', "X-Depth-Max": f'{meta["max"]:.4f}',
        "X-Depth-P02": f'{meta["p02"]:.4f}', "X-Depth-P98": f'{meta["p98"]:.4f}',
        "X-Focal-Px": f'{meta.get("focal_px") or 0:.2f}',
        "X-Infer-Ms": str(int(meta["infer_ms"])), "X-Device": str(meta["device"]),
    }
    return Response(arr.astype("<f4").tobytes(), media_type="application/octet-stream", headers=headers)


@app.post("/api/regions")
async def api_regions(image: UploadFile = File(...)):
    data = await image.read()
    try:
        return await regions.find_regions(data, image.content_type or "image/jpeg")
    except Exception as exc:
        return _err(502, exc)


@app.post("/api/masks")
async def api_masks(image: UploadFile = File(...), regions: str = Form(...)):
    data = await image.read()
    try:
        regs = json.loads(regions)
        if isinstance(regs, dict):
            regs = regs.get("regions", [])
        return await run_in_threadpool(segment.segment_regions, data, regs)
    except Exception as exc:
        return _err(500, exc)


@app.post("/api/score")
async def api_score(image: UploadFile = File(...)):
    data = await image.read()
    try:
        return await decide.score_photo(data, image.content_type or "image/jpeg")
    except Exception as exc:
        return _err(502, exc)
