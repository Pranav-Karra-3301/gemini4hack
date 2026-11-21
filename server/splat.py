"""3D page routes: /api/splat (Apple SHARP gaussians) and /api/reframe (one suggested camera move).

/api/splat runs SHARP through the wayback project's MLX port in a long-lived worker subprocess
(splat_worker.py, wayback vendor venv, `nice`, 12 GB MLX cap, 4 CPU threads). The worker starts on
the first request, loads the weights once and is restarted if it dies. One job at a time; results
are cached on disk by sha1 of the uploaded bytes (cache/splats/<sha1>.spz + .json sidecar).

.spz coordinates: gzipped SPZ v3 (magic "NGSP", SH degree 0), metric meters in the capture camera's
OpenCV frame: camera at the origin, x right, y down, z forward (into the scene); three.js viewers
flip y and z (scale (1, -1, -1)), as wayback/src/memory.js does.

Focal length: uploads are EXIF-less normalized JPEGs, so SHARP gets Depth Pro's estimate
(depth.infer_depth meta `focal_px`, which is in pixels of the image Depth Pro decoded, long side
<= depth.MAX_INFER_SIDE), rescaled to the image SHARP sees. Fallback: 26 mm equivalent.
"""

from __future__ import annotations

import asyncio
import atexit
import base64
import hashlib
import io
import json
import logging
import math
import os
import signal
import time
import uuid
from pathlib import Path

import numpy as np
from fastapi import APIRouter, File, Form, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse, JSONResponse
from PIL import Image, ImageOps

import depth
import gemini

log = logging.getLogger("coach.splat")
router = APIRouter()

SERVER = Path(__file__).resolve().parent
CACHE = SERVER / "cache" / "splats"
WAYBACK = Path(os.environ.get("WAYBACK_DIR", "/Users/pranav/developer/wayback"))
WORKER_PY = WAYBACK / "vendor" / ".venv" / "bin" / "python"
WORKER = SERVER / "splat_worker.py"
SHARP_MAX_SIDE = 1536  # SHARP works at 1536x1536 internally; bigger uploads are downscaled first
LOAD_TIMEOUT_S = 180.0
JOB_TIMEOUT_S = 180.0
CACHE_MAX = int(os.environ.get("SPLAT_CACHE_MAX", "60"))  # ~15 MB each
FALLBACK_F35 = 26.0  # mm, 35 mm-equivalent (typical phone main camera), same as wayback

# Response headers; app.py's CORS expose_headers lists them (CORSMiddleware overwrites any
# Access-Control-Expose-Headers a route sets, so they must live there).
SPLAT_HEADERS = ["X-Splat-Width", "X-Splat-Height", "X-Splat-Focal-Px", "X-Splat-Focal-Source",
                 "X-Splat-Ms", "X-Splat-Cache"]


def _err(status: int, exc: Exception | str) -> JSONResponse:
    if isinstance(exc, Exception):
        log.exception("request failed")
        msg = f"{type(exc).__name__}: {exc}"
    else:
        log.warning("request failed: %s", exc)
        msg = exc
    return JSONResponse({"error": msg}, status_code=status)


def _open(data: bytes) -> Image.Image:
    if not data:
        raise ValueError("empty upload")
    try:
        img = Image.open(io.BytesIO(data))
        img = ImageOps.exif_transpose(img).convert("RGB")
    except Exception as exc:  # UnidentifiedImageError, OSError, DecompressionBombError, ...
        raise ValueError(f"could not decode image: {exc}") from exc
    return img


# ---------------------------------------------------------------------------------------------
# SHARP worker


class _Worker:
    def __init__(self) -> None:
        self.proc: asyncio.subprocess.Process | None = None
        self.seq = 0

    def alive(self) -> bool:
        return self.proc is not None and self.proc.returncode is None

    def kill(self) -> None:
        if self.alive():
            try:
                self.proc.kill()
            except ProcessLookupError:
                pass
        self.proc = None

    async def _start(self) -> None:
        if not WORKER_PY.exists():
            raise RuntimeError(f"SHARP venv python not found at {WORKER_PY}")
        env = {k: os.environ[k] for k in ("PATH", "HOME", "TMPDIR", "LANG") if k in os.environ}
        env.update(VECLIB_MAXIMUM_THREADS="4", OMP_NUM_THREADS="4", PYTHONUNBUFFERED="1")
        t = time.perf_counter()
        # -I: isolated (no server/ on sys.path), -B: no .pyc written into the wayback tree.
        self.proc = await asyncio.create_subprocess_exec(
            "/usr/bin/nice", "-n", "10", str(WORKER_PY), "-I", "-B", str(WORKER),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=None,
            env=env, cwd=str(CACHE), limit=1 << 20,
        )
        try:
            line = await asyncio.wait_for(self.proc.stdout.readline(), LOAD_TIMEOUT_S)
        except asyncio.TimeoutError:
            self.kill()
            raise RuntimeError("SHARP worker did not load in time") from None
        if not line:
            self.kill()
            raise RuntimeError("SHARP worker exited while loading (see server log)")
        msg = json.loads(line)
        log.info("SHARP worker pid %s ready: weights %s ms, start %.1fs", msg.get("pid"),
                 msg.get("load_ms"), time.perf_counter() - t)

    async def run(self, image: Path, focal_px: float, out: Path) -> dict:
        for attempt in (0, 1):
            if not self.alive():
                await self._start()
            self.seq += 1
            rid = str(self.seq)
            try:
                req = {"id": rid, "image": str(image), "focal_px": focal_px, "out": str(out)}
                self.proc.stdin.write((json.dumps(req) + "\n").encode())
                await self.proc.stdin.drain()
            except (BrokenPipeError, ConnectionResetError):
                self.kill()  # died while idle: restart once and resend
                if attempt:
                    raise RuntimeError("SHARP worker keeps dying (see server log)") from None
                continue
            deadline = time.monotonic() + JOB_TIMEOUT_S
            while True:
                try:
                    line = await asyncio.wait_for(self.proc.stdout.readline(),
                                                  max(1.0, deadline - time.monotonic()))
                except asyncio.TimeoutError:
                    self.kill()
                    raise RuntimeError(f"SHARP timed out after {JOB_TIMEOUT_S:.0f}s") from None
                if not line:
                    self.kill()
                    raise RuntimeError("SHARP worker died during the job (see server log)")
                msg = json.loads(line)
                if msg.get("id") == rid:
                    break
                log.warning("dropping stale SHARP reply %s", msg.get("id"))  # from a cancelled job
            if not msg.get("ok"):
                raise RuntimeError(f"SHARP failed: {msg.get('error')}")
            return msg
        raise AssertionError("unreachable")


_worker = _Worker()
_lock = asyncio.Lock()


@atexit.register
def _stop_worker() -> None:
    # The worker also exits on its own when its stdin closes.
    p = _worker.proc
    if p is not None and p.returncode is None:
        try:
            os.kill(p.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass


def _focal(data: bytes, w0: int, h0: int, w: int, h: int) -> tuple[float, str]:
    """Focal length in px of the (w, h) image SHARP sees; (w0, h0) is the upload, upright."""
    try:
        _, meta = depth.infer_depth(data)
        f = meta.get("focal_px")
        if f and math.isfinite(f):
            s = min(1.0, depth.MAX_INFER_SIDE / max(w0, h0))
            infer_w = max(1, round(w0 * s))  # width of the image Depth Pro ran on
            f_img = float(f) * w / infer_w
            if 0.3 <= f_img / max(w, h) <= 6.0:  # ~118 deg .. ~10 deg across the long side
                return f_img, "exif" if meta.get("focal_source") == "exif" else "depth_pro"
            log.warning("implausible Depth Pro focal %.1f px for %dx%d, using 26 mm", f_img, w, h)
    except Exception:
        log.exception("Depth Pro focal estimate failed, using 26 mm")
    return FALLBACK_F35 * math.hypot(w, h) / 43.27, "default_26mm"  # 43.27 mm = FF diagonal


def _prepare_input(data: bytes, path: Path) -> tuple[int, int, int, int]:
    """Write the image SHARP will read; return upload (w0, h0) and SHARP's (w, h), upright."""
    img = _open(data)
    w0, h0 = img.size
    if max(w0, h0) > SHARP_MAX_SIDE:
        img.thumbnail((SHARP_MAX_SIDE, SHARP_MAX_SIDE), Image.LANCZOS)
        img.save(path, "JPEG", quality=95)
    else:
        path.write_bytes(data)
    w, h = img.size
    return w0, h0, w, h


def _prune() -> None:
    spz = sorted(CACHE.glob("*.spz"), key=lambda p: p.stat().st_mtime)
    for p in spz[: max(0, len(spz) - CACHE_MAX)]:
        p.unlink(missing_ok=True)
        p.with_suffix(".json").unlink(missing_ok=True)


def _splat_response(spz: Path, meta: dict, cache: str, t0: float) -> FileResponse:
    headers = {
        "X-Splat-Width": str(meta["w"]), "X-Splat-Height": str(meta["h"]),
        "X-Splat-Focal-Px": f'{meta["f"]:.2f}', "X-Splat-Focal-Source": meta["focal_source"],
        "X-Splat-Ms": str(round((time.perf_counter() - t0) * 1000.0)), "X-Splat-Cache": cache,
        "Cache-Control": "no-store",
    }
    if "peak_mb" in meta and cache == "miss":
        headers["X-Splat-Peak-Mb"] = str(meta["peak_mb"])  # diagnostic: worker lifetime peak footprint
    return FileResponse(spz, media_type="application/octet-stream", headers=headers)


def _cached(sha: str) -> tuple[Path, dict] | None:
    spz, side = CACHE / f"{sha}.spz", CACHE / f"{sha}.json"
    if spz.exists() and side.exists():
        try:
            meta = json.loads(side.read_text())
            os.utime(spz)  # LRU by mtime
            return spz, meta
        except (OSError, ValueError):
            pass
    return None


@router.post("/api/splat")
async def api_splat(image: UploadFile = File(...)):
    t0 = time.perf_counter()
    data = await image.read()
    sha = hashlib.sha1(data).hexdigest()
    CACHE.mkdir(parents=True, exist_ok=True)
    hit = _cached(sha)
    if hit:
        return _splat_response(*hit, "hit", t0)

    tmp = CACHE / f"{sha}.{uuid.uuid4().hex[:8]}.in.jpg"
    try:
        w0, h0, w, h = await run_in_threadpool(_prepare_input, data, tmp)
    except ValueError as exc:
        return _err(400, str(exc))
    try:
        f_px, source = await run_in_threadpool(_focal, data, w0, h0, w, h)
        async with _lock:
            hit = _cached(sha)  # another request may have made it while we waited
            if hit:
                return _splat_response(*hit, "hit", t0)
            spz = CACHE / f"{sha}.spz"
            res = await _worker.run(tmp, f_px, spz)
            meta = {"w": w, "h": h, "f": round(f_px, 2), "focal_source": source, "n": res["n"],
                    "sharp_ms": res["ms"], "peak_mb": res.get("footprint_peak_mb")}
            (CACHE / f"{sha}.json").write_text(json.dumps(meta))  # before waiters see the .spz
        log.info("splat %s %dx%d f=%.1f (%s) n=%d sharp %d ms (infer %s); worker memory MB: "
                 "MLX peak %s, footprint %s now / %s peak, max RSS %s", sha[:10], w, h, f_px,
                 source, res["n"], res["ms"], res.get("infer_ms"), res.get("mlx_peak_mb"),
                 res.get("footprint_mb"), res.get("footprint_peak_mb"), res.get("maxrss_mb"))
        await run_in_threadpool(_prune)
        return _splat_response(spz, meta, "miss", t0)
    except Exception as exc:
        return _err(500, exc)
    finally:
        tmp.unlink(missing_ok=True)


# ---------------------------------------------------------------------------------------------
# /api/reframe

LIMITS = {"x_m": 0.6, "y_m": 0.6, "z_m": 0.8, "yaw_deg": 15.0, "pitch_deg": 15.0}
NOTE_WORDS = 10
REFRAME_LONG_SIDE = 1024

REFRAME_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "shot": {"type": "STRING", "enum": ["selfie", "group", "portrait", "landscape", "object", "street", "other"],
                 "description": "What kind of photo this is. selfie = the camera is held by one of the people in it."},
        "keep": {"type": "ARRAY", "items": {"type": "STRING"},
                 "description": "Every person (and any other subject) that must stay fully in frame, short names "
                                "like 'man in grey tee, centre'. All people who are clearly part of the shot."},
        "scene": {"type": "STRING",
                  "description": "The background element that makes this place worth photographing (e.g. "
                                 "'cypress tree tunnel and its vanishing point'), or '' if none."},
        "problem": {"type": "STRING", "description": "What the current framing gets wrong, at most 12 words."},
        "note": {"type": "STRING", "description": "Imperative coaching line, at most 10 words."},
        "x_m": {"type": "NUMBER", "description": "meters, + = move right"},
        "y_m": {"type": "NUMBER", "description": "meters, + = move down (lower the camera)"},
        "z_m": {"type": "NUMBER", "description": "meters, + = move forward toward the scene"},
        "yaw_deg": {"type": "NUMBER", "description": "degrees, + = turn right"},
        "pitch_deg": {"type": "NUMBER", "description": "degrees, + = tilt up"},
    },
    "required": ["shot", "keep", "scene", "problem", "note", "x_m", "y_m", "z_m", "yaw_deg", "pitch_deg"],
    "propertyOrdering": ["shot", "keep", "scene", "problem", "note", "x_m", "y_m", "z_m", "yaw_deg", "pitch_deg"],
}

REFRAME_PROMPT = """\
You are a photography coach looking at a photo someone just took. Suggest ONE small camera move \
from where the camera was that would most improve this shot.

Work in this order:
1. shot: what kind of photo it is. If it's a selfie, the camera is in the hand of one of the \
people in it, so the move is an arm move (raise or lower the phone, extend the arm, tilt, turn), \
not walking away from the group.
2. keep: list every person who is part of the shot (and any other real subject). The new framing \
MUST keep all of them fully in frame: no cropped heads, faces or bodies cut at the joints. People \
are the subject of a selfie or group photo, always.
3. scene: name the place-defining background (a landmark, a tree tunnel, a sunset, a view) if \
there is one. A good move shows MORE of it behind the people (e.g. raise the phone and tilt down \
so the tunnel's vanishing point shows above the heads), never trades it away for a tighter crop.
4. problem, then the move that fixes it while satisfying 2 and 3: stronger composition, the \
scene revealed behind the subjects, cleaner background, better light direction, or a distraction \
moved out of frame.

Camera frame (meters, degrees): x right, y down, z forward into the scene. x_m > 0 moves right, \
y_m < 0 raises the camera and y_m > 0 lowers it, z_m > 0 moves toward the scene (z_m < 0 = step \
back or extend nothing). yaw_deg > 0 turns right, pitch_deg > 0 tilts up. Limits: |x_m|, |y_m| <= \
0.6, |z_m| <= 0.8, |yaw_deg|, |pitch_deg| <= 15. Usually change one or two values, rest 0.

Size the move with the metric depth below. Parallax matters: a sideways move shifts near things \
much more than far ones (0.3 m moves a subject at 2 m about 9 degrees against a distant \
background); at selfie distance (under 1 m) keep moves small, about 0.1-0.25 m. Turning \
(yaw/pitch) recenters without changing parallax.

note: what to do and why, imperative, at most 10 words, e.g. "Step left so the doorway frames her". \
No praise.

{context}"""

def _parse_regions(raw: str | None) -> list[dict]:
    if not raw or not raw.strip():
        return []
    regs = json.loads(raw)
    if isinstance(regs, dict):
        regs = regs.get("regions", [])
    if not isinstance(regs, list):
        raise ValueError("regions must be a JSON array or an object with a `regions` array")
    return [r for r in regs if isinstance(r, dict) and isinstance(r.get("box"), dict)]


def _fmt_m(v: float) -> str:
    return f"{v:.1f} m" if v < 100 else f"{v:.0f} m"


def _depth_context(data: bytes, regs: list[dict]) -> str:
    """Short text with the scene's metric depth (and each region's median depth)."""
    try:
        arr, meta = depth.infer_depth(data)
    except Exception:
        log.exception("depth for reframe failed")
        return "Scene depth: unavailable; judge distances from the image."
    p02, p98 = meta["p02"], meta["p98"]
    solid = arr[arr <= p98]
    median = float(np.median(solid)) if solid.size else float(np.median(arr))
    far = float(np.mean(arr > max(3.0 * p98, 200.0)))
    lines = [f"Scene depth from the camera (Depth Pro, meters): near (2nd pct) {_fmt_m(p02)}, "
             f"median {_fmt_m(median)}, far (98th pct) {_fmt_m(p98)}."]
    if far >= 0.02:
        lines.append(f"About {far * 100:.0f}% of the frame is sky or very far away.")
    hh, ww = arr.shape
    for r in regs:
        b = r["box"]
        try:
            x0, y0 = int(float(b["x"]) * ww), int(float(b["y"]) * hh)
            x1 = math.ceil((float(b["x"]) + float(b["w"])) * ww)
            y1 = math.ceil((float(b["y"]) + float(b["h"])) * hh)
        except (KeyError, TypeError, ValueError):
            continue
        sub = arr[max(0, y0):min(hh, max(y1, y0 + 1)), max(0, x0):min(ww, max(x1, x0 + 1))]
        if not sub.size:
            continue
        med = float(np.median(sub))
        dist = "far (sky or beyond the 98th pct)" if med > p98 else _fmt_m(med)
        note = str(r.get("note", "")).strip()
        lines.append(f'Region {r.get("id", "?")} [{r.get("tag", "?")}] box x={float(b["x"]):.2f} '
                     f'y={float(b["y"]):.2f} w={float(b["w"]):.2f} h={float(b["h"]):.2f} '
                     f'(normalized, origin top-left), median depth {dist}: "{note}"')
    return "\n".join(lines)


def _jpeg_b64(data: bytes) -> str:
    img = _open(data)
    img.thumbnail((REFRAME_LONG_SIDE, REFRAME_LONG_SIDE), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=85)
    return base64.b64encode(buf.getvalue()).decode()


def _clamp_move(raw: dict) -> dict:
    move = {}
    for k, lim in LIMITS.items():
        try:
            v = float(raw.get(k, 0.0))
        except (TypeError, ValueError):
            v = 0.0
        v = max(-lim, min(lim, v)) if math.isfinite(v) else 0.0
        move[k] = round(v, 2 if k.endswith("_m") else 1) + 0.0  # + 0.0 drops -0.0
    return move


def _short_note(note: str) -> str:
    words = " ".join(str(note).split()).split(" ")
    if len(words) > NOTE_WORDS:
        words = words[:NOTE_WORDS]
    return " ".join(words).strip().rstrip(".,;:")


async def _ask_reframe(b64: str, context: str, model: str) -> dict:
    # Through gemini.py: pooled connection, retries on 429/5xx inside a 45 s deadline, stats.
    out = await gemini.generate_json(
        model, [gemini.image_part(b64), REFRAME_PROMPT.format(context=context)], REFRAME_SCHEMA,
        thinking="low", media_resolution="medium", timeout=45.0, tag="reframe",
    )
    if not isinstance(out, dict):
        raise RuntimeError(f"Gemini returned {type(out).__name__}, expected an object")
    return out


@router.post("/api/reframe")
async def api_reframe(image: UploadFile = File(...), regions: str | None = Form(None)):
    t0 = time.perf_counter()
    data = await image.read()
    model = os.environ.get("REFRAME_MODEL", "gemini-4-hydrogen")
    try:
        regs = _parse_regions(regions)
        b64 = await run_in_threadpool(_jpeg_b64, data)
    except ValueError as exc:
        return _err(400, str(exc))
    try:
        context = await run_in_threadpool(_depth_context, data, regs)
        raw = await _ask_reframe(b64, context, model)
    except Exception as exc:
        return _err(502, exc)
    return {
        "move": _clamp_move(raw),
        "note": _short_note(raw.get("note", "")),
        "shot": str(raw.get("shot", "")),
        "keep": [str(k) for k in (raw.get("keep") or [])][:8],
        "scene": str(raw.get("scene", "")),
        "model": model,
        "ms": round((time.perf_counter() - t0) * 1000.0),
    }
