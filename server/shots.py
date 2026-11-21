"""Shot library, background pipeline and live sync: docs/CORE_API.md §3 and §4.

Storage: library/<id>/ (env COACH_LIBRARY overrides the root) holding original.jpg, image.jpg
(upright, long side 1536: what every model sees), thumb.jpg, depth.png (16-bit mm), regions.json,
masks/<rid>.png, score.json, suggest.json, splat.spz and shot.json (the record, written
atomically). Ids are time-sortable `YYYYMMDD-HHMMSS-xxxx` (UTC; xxxx = 3 hex digits of the
millisecond + 1 random hex digit, so ids sort to the millisecond).

Pipeline: one asyncio worker, newest shot first, re-picking the newest shot after every phase:
  A. depth (GPU) ∥ score ∥ regions   score and regions are network-bound and don't need depth,
                                     so they overlap Depth Pro instead of waiting for it
  B. masks (GPU; needs regions; reuses depth.py's LRU depth map for the same image bytes)
     ∥ suggest (Gemini edit plan, edit.py; needs regions, not masks: region depths come from
     their boxes in depth.png, and the default subject is the first focus region)
Every stage goes pending -> running -> done | error and each transition is persisted and
broadcast on /api/events. GPU models (Depth Pro, SAM, SHARP) run in threads/subprocesses under
one lock, so at most one runs at a time. On startup unfinished stages are re-queued; an
interrupted splat is marked error (it is heavy, so the client asks again). If another Core
process already owns the library (flock on library/.lock), this one serves it read-only and
does not process.
"""

from __future__ import annotations

import asyncio
import importlib
import base64
import fcntl
import io
import json
import logging
import math
import os
import re
import secrets
import shutil
import signal
import time
from collections import OrderedDict
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from fastapi import APIRouter, File, Form, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse
from PIL import ExifTags, Image, ImageOps, UnidentifiedImageError

import decide
import depth
import edit
import regions
import segment

log = logging.getLogger("shots")

SERVER = Path(__file__).resolve().parent
LIBRARY = Path(os.environ.get("COACH_LIBRARY") or SERVER / "library").resolve()
ORIGINAL_SIDE = 4032
IMAGE_SIDE = 1536
THUMB_SIDE = 400
MAX_UPLOAD = 60 * 1024 * 1024
MAX_META = 16 * 1024
PING_S = 15.0
SUB_QUEUE = 512
STAGES = ("depth", "score", "regions", "masks", "suggest")
PHASES = (("depth", "score", "regions"), ("masks", "suggest"))
FILES = {  # servable asset files -> media type
    "image.jpg": "image/jpeg", "original.jpg": "image/jpeg", "thumb.jpg": "image/jpeg",
    "depth.png": "image/png", "regions.json": "application/json", "score.json": "application/json",
    "suggest.json": "application/json", "splat.spz": "application/octet-stream",
    "review.json": "application/json",
}
IMMUTABLE = {"image.jpg", "original.jpg", "thumb.jpg"}
ID_RE = re.compile(r"^\d{8}-\d{6}-[0-9a-f]{4}$")
RID_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")

router = APIRouter()

_records: dict[str, dict] = {}
_pending: set[str] = set()
_wake = asyncio.Event()
_gpu = asyncio.Lock()  # Depth Pro, SAM and SHARP share the GPU: one at a time
_subs: set[_Sub] = set()
_closing = False
_owner = False
_lock_fd: int | None = None
_tasks: dict[str, asyncio.Task] = {}  # worker + splat tasks
_suggest_cache: OrderedDict[tuple, dict] = OrderedDict()
_suggest_inflight: dict[tuple, asyncio.Future] = {}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _err(status: int, msg: str) -> JSONResponse:
    return JSONResponse({"error": msg}, status_code=status)


def _dir(sid: str) -> Path:
    return LIBRARY / sid


def _url(sid: str, name: str) -> str:
    return f"/api/shots/{sid}/{name}"


# ------------------------------------------------------------------------------------------------
# records and events


class _Sub:
    __slots__ = ("q",)

    def __init__(self) -> None:
        self.q: asyncio.Queue[str | None] = asyncio.Queue(SUB_QUEUE)


def _save(rec: dict) -> None:
    """Atomic write of shot.json (tmp + rename). Silently skipped if the shot was deleted."""
    d = _dir(rec["id"])
    tmp = d / f".shot.json.{secrets.token_hex(3)}"
    try:
        tmp.write_text(json.dumps(rec, separators=(",", ":")))
        os.replace(tmp, d / "shot.json")
    except FileNotFoundError:
        pass


def _broadcast(event: str, data: dict) -> None:
    msg = f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n"
    for sub in list(_subs):
        try:
            sub.q.put_nowait(msg)
        except asyncio.QueueFull:  # a stalled client: end its stream; it reconnects and refetches
            _subs.discard(sub)
            while not sub.q.empty():
                sub.q.get_nowait()
            sub.q.put_nowait(None)


def _commit(rec: dict) -> None:
    rec["updated"] = _now()
    _save(rec)
    _broadcast("shot", rec)


def _set(sid: str, changes: dict[str, dict]) -> dict | None:
    """Replace asset entries (one event for all of them); None if the shot is gone."""
    rec = _records.get(sid)
    if rec is None:
        return None
    rec["assets"].update(changes)
    _commit(rec)
    return rec


def set_asset(sid: str, name: str, entry: dict) -> dict | None:
    """Public: replace one asset entry, persist and broadcast (review, looks, semantic use it)."""
    return _set(sid, {name: entry})


_followups: set[asyncio.Task] = set()


def _followup(module: str, fn: str, sid: str) -> None:
    """Fire-and-forget a feature step after a pipeline stage (semantic after masks, the fit look
    after suggest). Lazy import keeps shots.py free of import cycles; failures only log."""
    async def run():
        try:
            await getattr(importlib.import_module(module), fn)(sid)
        except Exception:
            log.exception("follow-up %s.%s failed for %s", module, fn, sid)
    task = asyncio.create_task(run(), name=f"{module}-{sid}")
    _followups.add(task)
    task.add_done_callback(_followups.discard)


FOLLOWUPS = {"masks": ("semantic", "ensure_semantic"), "suggest": ("looks", "ensure_fit_look")}


def _status(rec: dict, name: str) -> str:
    return (rec["assets"].get(name) or {}).get("status", "none")


def _read_json(sid: str, name: str) -> dict | None:
    try:
        return json.loads((_dir(sid) / name).read_text())
    except (OSError, ValueError):
        return None


def _write_json(sid: str, name: str, data) -> None:
    d = _dir(sid)
    tmp = d / f".{name}.{secrets.token_hex(3)}"
    tmp.write_text(json.dumps(data, separators=(",", ":")))
    os.replace(tmp, d / name)


# ------------------------------------------------------------------------------------------------
# upload


def _new_id() -> str:
    t = datetime.now(timezone.utc)
    while True:
        sid = f"{t:%Y%m%d-%H%M%S}-{t.microsecond // 1000:03x}{secrets.randbelow(16):x}"
        if sid not in _records and not _dir(sid).exists():
            return sid


def _jpeg(img: Image.Image, quality: int, **kw) -> bytes:
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality, **{k: v for k, v in kw.items() if v is not None})
    return buf.getvalue()


def _prepare_upload(data: bytes) -> dict:
    """original.jpg (as uploaded, up to 4032 px), image.jpg (upright, 1536, EXIF focal kept so
    Depth Pro uses it) and thumb.jpg (400). Width/height are the upright original's."""
    try:
        im = Image.open(io.BytesIO(data))
        fmt = im.format
        w0, h0 = im.size
        orient = im.getexif().get(ExifTags.Base.Orientation, 1)
        icc = im.info.get("icc_profile")
        keep = fmt == "JPEG" and max(w0, h0) <= ORIGINAL_SIDE
        if keep and fmt == "JPEG":  # decode at a reduced DCT scale: only the 1536 copy is needed
            s = IMAGE_SIDE / max(w0, h0)
            if s < 1:
                im.draft("RGB", (math.ceil(w0 * s), math.ceil(h0 * s)))
        up = ImageOps.exif_transpose(im)
    except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError) as exc:
        raise ValueError(f"could not decode image: {exc}") from exc
    width, height = (h0, w0) if orient in (5, 6, 7, 8) else (w0, h0)
    exif = up.getexif()
    exif.get_ifd(ExifTags.IFD.Exif)  # load the Exif sub-IFD (FocalLengthIn35mmFilm) so it is saved
    exif_bytes = exif.tobytes() if len(exif) else None
    rgb = up.convert("RGB")
    if keep:
        original = data
    else:
        o = rgb.copy()
        o.thumbnail((ORIGINAL_SIDE, ORIGINAL_SIDE), Image.LANCZOS)
        original = _jpeg(o, 92, exif=exif_bytes, icc_profile=icc)
    img = rgb
    img.thumbnail((IMAGE_SIDE, IMAGE_SIDE), Image.LANCZOS)
    thumb = img.copy()
    thumb.thumbnail((THUMB_SIDE, THUMB_SIDE), Image.LANCZOS)
    return {"width": width, "height": height, "original.jpg": original,
            "image.jpg": _jpeg(img, 90, exif=exif_bytes, icc_profile=icc),
            "thumb.jpg": _jpeg(thumb, 80, icc_profile=icc)}


def _new_record(sid: str, width: int, height: int, meta: dict) -> dict:
    done = {"status": "done"}
    return {
        "id": sid, "created": _now(), "updated": _now(), "width": width, "height": height,
        "meta": meta,
        "assets": {
            "image": {**done, "url": _url(sid, "image.jpg")},
            "original": {**done, "url": _url(sid, "original.jpg")},
            "thumb": {**done, "url": _url(sid, "thumb.jpg")},
            **{name: {"status": "pending"} for name in STAGES},
            "splat": {"status": "none"},
        },
        "edit": None,
    }


def _store(sid: str, prep: dict, rec: dict) -> None:
    tmp = LIBRARY / f".tmp-{sid}"
    tmp.mkdir(parents=True)
    for name in ("original.jpg", "image.jpg", "thumb.jpg"):
        (tmp / name).write_bytes(prep[name])
    (tmp / "shot.json").write_text(json.dumps(rec, separators=(",", ":")))
    os.rename(tmp, _dir(sid))


# ------------------------------------------------------------------------------------------------
# pipeline stages (each returns the extra fields of its "done" asset entry)


def _write_depth(sid: str, arr: np.ndarray, meta: dict) -> dict:
    mm = np.nan_to_num(arr.astype(np.float64) * 1000.0, nan=0.0, posinf=65535.0, neginf=0.0)
    mm = np.clip(np.rint(mm), 0, 65535).astype(np.uint16)
    buf = io.BytesIO()
    Image.fromarray(mm).save(buf, "PNG")
    (_dir(sid) / "depth.png").write_bytes(buf.getvalue())
    near = (mm > 0) & (mm < 65535)
    return {
        "width": int(arr.shape[1]), "height": int(arr.shape[0]),
        "p02": round(meta["p02"], 3), "p98": round(meta["p98"], 3),
        "median": round(float(np.median(mm[near])) / 1000.0, 3) if near.any() else None,
        "far_frac": round(float((mm >= 65535).mean()), 4),
        "focal_px": round(meta["focal_px"], 2) if meta.get("focal_px") else None,
        "focal_source": meta.get("focal_source"), "units": "mm",
    }


async def _do_depth(sid: str, data: bytes) -> dict:
    async with _gpu:
        arr, meta = await asyncio.to_thread(depth.infer_depth, data)
    dmeta = await asyncio.to_thread(_write_depth, sid, arr, meta)
    return {"url": _url(sid, "depth.png"), "meta": dmeta}


async def _do_score(sid: str, data: bytes) -> dict:
    res = await decide.score_photo(data, "image/jpeg")  # gemini.py retries transient errors
    await asyncio.to_thread(_write_json, sid, "score.json", res)
    summary = {k: v.get("score") for k, v in (res.get("scores") or {}).items() if isinstance(v, dict)}
    return {"url": _url(sid, "score.json"), "summary": summary}


async def _do_regions(sid: str, data: bytes) -> dict:
    res = await regions.find_regions(data, "image/jpeg")  # retries once itself
    await asyncio.to_thread(_write_json, sid, "regions.json", res)
    return {"url": _url(sid, "regions.json"), "count": len(res.get("regions") or [])}


def _write_masks(sid: str, res: dict) -> dict:
    d = _dir(sid)
    (d / "masks").mkdir(exist_ok=True)  # no parents=True: never resurrect a deleted shot
    try:
        dm = np.asarray(Image.open(d / "depth.png"))
    except OSError:
        dm = None
    urls, meta = {}, {}
    for rid, m in (res.get("masks") or {}).items():
        if not RID_RE.match(str(rid)) or not isinstance(m, dict) or not m.get("png"):
            continue
        png = base64.b64decode(m["png"].split(",", 1)[-1])
        (d / "masks" / f"{rid}.png").write_bytes(png)
        info = {"area": m.get("area"), "source": m.get("source"), "width": m.get("width"),
                "height": m.get("height"), "depth_m": None}
        if dm is not None:
            mk = np.asarray(Image.open(io.BytesIO(png)).convert("L").resize(
                (dm.shape[1], dm.shape[0]), Image.BILINEAR)) > 127
            vals = dm[mk & (dm > 0) & (dm < 65535)]
            if vals.size:
                info["depth_m"] = round(float(np.median(vals)) / 1000.0, 3)
        urls[rid] = _url(sid, f"masks/{rid}.png")
        meta[rid] = info
    return {"urls": urls, "meta": meta}


async def _do_masks(sid: str, data: bytes) -> dict:
    rec = _records.get(sid)
    regs = _read_json(sid, "regions.json") if rec and _status(rec, "regions") == "done" else None
    if not regs or not regs.get("regions"):
        raise RuntimeError("no regions to segment")
    async with _gpu:
        res = await asyncio.to_thread(segment.segment_regions, data, regs["regions"])
    out = await asyncio.to_thread(_write_masks, sid, res)
    return {**out, "model": res.get("model")}


def _box_depths(sid: str, regs: dict) -> dict[str, float]:
    """Median depth (m) inside each region's box, from depth.png: stands in for the masks'
    depth_m when suggest runs before masks are done."""
    try:
        dm = np.asarray(Image.open(_dir(sid) / "depth.png"))
    except OSError:
        return {}
    h, w = dm.shape
    out = {}
    for r in regs.get("regions") or []:
        b = r.get("box") or {}
        try:
            x0, y0 = int(b["x"] * w), int(b["y"] * h)
            x1, y1 = int((b["x"] + b["w"]) * w) + 1, int((b["y"] + b["h"]) * h) + 1
        except (KeyError, TypeError):
            continue
        crop = dm[max(y0, 0):min(y1, h), max(x0, 0):min(x1, w)]
        vals = crop[(crop > 0) & (crop < 65535)]
        if r.get("id") and vals.size:
            out[r["id"]] = round(float(np.median(vals)) / 1000.0, 3)
    return out


def _notes(sid: str) -> tuple[str, list[str], str | None]:
    """Shot notes for Gemini, the region ids, and the default subject (first focus region that
    got a usable mask, else the first focus region). Before masks are done, region depths come
    from their boxes."""
    rec = _records[sid]
    score = _read_json(sid, "score.json") if _status(rec, "score") == "done" else None
    regs = _read_json(sid, "regions.json") if _status(rec, "regions") == "done" else None
    ids = [r.get("id") for r in (regs or {}).get("regions", []) if r.get("id")]
    focus = [r.get("id") for r in (regs or {}).get("regions", []) if r.get("tag") == "focus"]
    mmeta = (rec["assets"].get("masks") or {}).get("meta") or {}
    masked = [rid for rid in focus if (mmeta.get(rid) or {}).get("area", 0) and mmeta[rid]["area"] > 0.005]
    subject = (masked or focus or [None])[0]
    box_depth = (_box_depths(sid, regs) if regs and _status(rec, "masks") != "done"
                 and _status(rec, "depth") == "done" else None)
    return edit.shot_context(rec, score, regs, box_depth), ids, subject


def shot_notes(shot_id: str) -> str | None:
    """Compact notes about a shot (scores, regions, depth) for other modules, e.g. the live
    edit-mode prompt. None for an unknown shot."""
    if shot_id not in _records:
        return None
    return _notes(shot_id)[0]


def get_record(shot_id: str) -> dict | None:
    return _records.get(shot_id)


async def _do_suggest(sid: str, data: bytes) -> dict:
    notes, ids, subject = _notes(sid)
    res = await edit.suggest(data, notes, None, None, ids, subject)
    await asyncio.to_thread(_write_json, sid, "suggest.json", res)
    return {"url": _url(sid, "suggest.json"), "summary": res.get("summary")}


STAGE_FN = {"depth": _do_depth, "score": _do_score, "regions": _do_regions, "masks": _do_masks,
            "suggest": _do_suggest}


async def _run_stage(sid: str, name: str, data: bytes) -> None:
    t0 = time.perf_counter()
    try:
        extra = await STAGE_FN[name](sid, data)
    except FileNotFoundError:
        if sid not in _records:
            return  # deleted while running
        raise
    except Exception as exc:
        log.exception("stage %s failed for %s", name, sid)
        _set(sid, {name: {"status": "error", "error": f"{type(exc).__name__}: {exc}"[:400]}})
        return
    ms = int((time.perf_counter() - t0) * 1000)
    log.info("shot %s %s done in %d ms", sid, name, ms)
    _set(sid, {name: {"status": "done", **extra, "ms": ms}})
    if name in FOLLOWUPS and os.environ.get("COACH_FOLLOWUPS", "1") != "0":
        _followup(*FOLLOWUPS[name], sid)


def _next_phase(rec: dict) -> tuple[str, ...] | None:
    for phase in PHASES:
        todo = tuple(n for n in phase if _status(rec, n) in ("pending", "running"))
        if todo:
            return todo
    return None


async def _worker() -> None:
    while not _closing:
        try:
            live = [s for s in _pending if s in _records]
            _pending.intersection_update(live)
            if not live:
                _wake.clear()
                await _wake.wait()
                continue
            sid = max(live)  # newest first, re-picked after every phase
            rec = _records[sid]
            todo = _next_phase(rec)
            if todo is None:
                _pending.discard(sid)
                continue
            data = await asyncio.to_thread((_dir(sid) / "image.jpg").read_bytes)
            _set(sid, {n: {"status": "running"} for n in todo})
            await asyncio.gather(*(_run_stage(sid, n, data) for n in todo))
            rec = _records.get(sid)
            if rec is not None:  # a stage that neither finished nor failed must not loop forever
                stuck = {n: {"status": "error", "error": "stage did not finish"}
                         for n in todo if _status(rec, n) == "running"}
                if stuck:
                    _set(sid, stuck)
        except asyncio.CancelledError:
            raise
        except FileNotFoundError:
            pass  # shot deleted mid-phase
        except Exception:
            log.exception("shot worker error")
            await asyncio.sleep(0.5)


def _kick(sid: str) -> None:
    _pending.add(sid)
    _wake.set()


# ------------------------------------------------------------------------------------------------
# splat (SHARP via splat.py's own endpoint function, cache and worker; no changes there)


async def _do_splat(sid: str) -> None:
    import splat  # lazy: keeps the library usable if the SHARP setup is missing

    t0 = time.perf_counter()
    try:
        data = await asyncio.to_thread((_dir(sid) / "image.jpg").read_bytes)
        _set(sid, {"splat": {"status": "running"}})
        async with _gpu:
            resp = await splat.api_splat(UploadFile(io.BytesIO(data), filename="image.jpg"))
        if not isinstance(resp, FileResponse):
            try:
                msg = json.loads(bytes(resp.body)).get("error")
            except (ValueError, AttributeError):
                msg = None
            raise RuntimeError(msg or f"splat HTTP {resp.status_code}")
        dst = _dir(sid) / "splat.spz"
        tmp = dst.with_name(f".splat.{secrets.token_hex(3)}")
        try:
            os.link(resp.path, tmp)  # survives splat.py's cache pruning, costs no space
        except OSError:
            await asyncio.to_thread(shutil.copyfile, resp.path, tmp)
        os.replace(tmp, dst)
        h = resp.headers
        meta = {"width": int(h["x-splat-width"]), "height": int(h["x-splat-height"]),
                "focal_px": float(h["x-splat-focal-px"]), "focal_source": h["x-splat-focal-source"],
                "cache": h.get("x-splat-cache"), "bytes": dst.stat().st_size}
        _set(sid, {"splat": {"status": "done", "url": _url(sid, "splat.spz"), "meta": meta,
                             "ms": int((time.perf_counter() - t0) * 1000)}})
    except FileNotFoundError:
        if sid in _records:
            _set(sid, {"splat": {"status": "error", "error": "image missing"}})
    except Exception as exc:
        log.exception("splat failed for %s", sid)
        _set(sid, {"splat": {"status": "error", "error": f"{type(exc).__name__}: {exc}"[:400]}})
    finally:
        _tasks.pop(f"splat:{sid}", None)


# ------------------------------------------------------------------------------------------------
# startup / shutdown


def _load_library() -> None:
    LIBRARY.mkdir(parents=True, exist_ok=True)
    for junk in list(LIBRARY.glob(".tmp-*")) + list(LIBRARY.glob(".trash-*")):
        shutil.rmtree(junk, ignore_errors=True)
    for f in LIBRARY.glob("*/shot.json"):
        sid = f.parent.name
        if not ID_RE.match(sid):
            continue
        try:
            rec = json.loads(f.read_text())
        except (OSError, ValueError):
            log.warning("skipping unreadable %s", f)
            continue
        _records[sid] = rec
        if not _owner:
            continue
        changed = False
        for name in STAGES:
            if _status(rec, name) == "running":
                rec["assets"][name] = {"status": "pending"}
                changed = True
            if _status(rec, name) == "pending":
                _pending.add(sid)
        for name in ("semantic", "looks"):
            if _status(rec, name) == "running":
                rec["assets"][name] = {"status": "error", "error": "interrupted by a restart; request it again"}
                changed = True
        if _status(rec, "splat") in ("pending", "running"):
            rec["assets"]["splat"] = {"status": "error", "error": "interrupted by a restart; request it again"}
            changed = True
        if changed:
            _save(rec)


def _take_ownership() -> bool:
    global _lock_fd
    LIBRARY.mkdir(parents=True, exist_ok=True)
    fd = os.open(LIBRARY / ".lock", os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return False
    _lock_fd = fd
    return True


def _close_streams() -> None:
    global _closing
    _closing = True
    for sub in list(_subs):
        try:
            sub.q.put_nowait(None)
        except asyncio.QueueFull:
            pass
    _subs.clear()


def _hook_signals(loop: asyncio.AbstractEventLoop) -> None:
    """End SSE streams as soon as uvicorn is asked to stop: it waits for open responses before
    running lifespan shutdown, so without this a connected app would block every restart."""
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            prev = signal.getsignal(sig)
            if not callable(prev):
                continue

            def handler(signum, frame, prev=prev):
                loop.call_soon_threadsafe(_close_streams)
                prev(signum, frame)

            signal.signal(sig, handler)
        except (ValueError, OSError):  # not the main thread (tests): nothing to hook
            pass


@asynccontextmanager
async def _lifespan(_app):
    global _owner, _closing
    _closing = False
    _owner = _take_ownership()
    if not _owner:
        log.warning("library %s is owned by another Core process: serving it read-only, "
                    "no background processing here", LIBRARY)
    await asyncio.to_thread(_load_library)
    log.info("shot library %s: %d shots, %d with pending stages", LIBRARY, len(_records), len(_pending))
    _hook_signals(asyncio.get_running_loop())
    if _owner:
        _tasks["worker"] = asyncio.create_task(_worker(), name="shots-worker")
        _wake.set()
    try:
        yield
    finally:
        _close_streams()
        for t in list(_tasks.values()):
            t.cancel()
        await asyncio.gather(*_tasks.values(), return_exceptions=True)
        _tasks.clear()


router.lifespan_context = _lifespan


# ------------------------------------------------------------------------------------------------
# routes


def _shot_or_404(sid: str) -> dict | JSONResponse:
    rec = _records.get(sid) if ID_RE.match(sid) else None
    return rec if rec is not None else _err(404, f"no shot {sid}")


@router.post("/api/shots", status_code=201)
async def create_shot(image: UploadFile | None = File(None), meta: str | None = Form(None)):
    if image is None:
        return _err(400, "multipart field 'image' (JPEG) is required")
    data = await image.read(MAX_UPLOAD + 1)
    if len(data) > MAX_UPLOAD:
        return _err(413, f"image larger than {MAX_UPLOAD // 1048576} MB")
    if not data:
        return _err(400, "empty image")
    try:
        m = json.loads(meta) if meta else {}
    except ValueError:
        return _err(400, "meta must be a JSON object string")
    if not isinstance(m, dict) or len(meta or "") > MAX_META:
        return _err(400, f"meta must be a JSON object under {MAX_META // 1024} KB")
    try:
        prep = await asyncio.to_thread(_prepare_upload, data)
    except ValueError as exc:
        return _err(400, str(exc))
    sid = _new_id()
    rec = _new_record(sid, prep["width"], prep["height"], m)
    await asyncio.to_thread(_store, sid, prep, rec)
    _records[sid] = rec
    _broadcast("shot", rec)
    if _owner:
        _kick(sid)
    if m.get("review_id"):
        try:  # a review streamed at the shutter, before this upload, gets saved into the shot
            importlib.import_module("review").attach(sid, str(m["review_id"]))
        except Exception:
            log.exception("attaching review %s to %s failed", m.get("review_id"), sid)
    return JSONResponse(rec, status_code=201)


@router.get("/api/shots")
async def list_shots(limit: int = 50, before: str | None = None):
    limit = max(1, min(int(limit), 500))
    ids = sorted((s for s in _records if before is None or s < before), reverse=True)[:limit]
    return {"shots": [_records[s] for s in ids]}


@router.get("/api/shots/{sid}")
async def get_shot(sid: str):
    return _shot_or_404(sid)


@router.delete("/api/shots/{sid}")
async def delete_shot(sid: str):
    rec = _shot_or_404(sid)
    if isinstance(rec, JSONResponse):
        return rec
    _records.pop(sid, None)
    _pending.discard(sid)
    t = _tasks.pop(f"splat:{sid}", None)
    if t:
        t.cancel()
    for k in [k for k in _suggest_cache if k[0] == sid]:
        _suggest_cache.pop(k, None)
    trash = LIBRARY / f".trash-{sid}-{secrets.token_hex(2)}"
    try:
        os.rename(_dir(sid), trash)  # atomic: in-flight writers fail instead of resurrecting it
    except FileNotFoundError:
        trash = None
    if trash is not None:
        await asyncio.to_thread(shutil.rmtree, trash, True)
    _broadcast("shot_deleted", {"id": sid})
    return Response(status_code=204)


async def _json_body(request: Request):
    raw = await request.body()
    if not raw.strip():
        return None
    return json.loads(raw)


def _clean_recipe(body: dict) -> dict:
    if not isinstance(body, dict):
        raise ValueError("recipe must be a JSON object")
    if body.get("version", 1) != 1:
        raise ValueError("unsupported recipe version (expected 1)")
    values = edit.clamp_values(body.get("values") or {})
    subject = body.get("subject")
    if subject is not None and (not isinstance(subject, str) or not RID_RE.match(subject)):
        raise ValueError("subject must be a region id or null")
    crop = body.get("crop")
    if crop is not None:
        if not isinstance(crop, dict):
            raise ValueError("crop must be {x, y, w, h, angle}")
        try:
            x, y = (min(max(float(crop.get(k, 0)), 0.0), 1.0) for k in ("x", "y"))
            w = min(max(float(crop.get("w", 1)), 0.01), 1.0 - x)
            h = min(max(float(crop.get("h", 1)), 0.01), 1.0 - y)
            angle = min(max(float(crop.get("angle", 0)), -45.0), 45.0)
        except (TypeError, ValueError):
            raise ValueError("crop fields must be numbers") from None
        if not all(map(math.isfinite, (x, y, w, h, angle))) or w <= 0 or h <= 0:
            raise ValueError("crop is empty or not finite")
        crop = {"x": round(x, 4), "y": round(y, 4), "w": round(w, 4), "h": round(h, 4),
                "angle": round(angle, 2)}
    look = body.get("look")
    if look is not None:
        if not isinstance(look, dict) or not RID_RE.match(str(look.get("id", ""))):
            raise ValueError("look must be {id, strength}")
        try:
            strength = min(max(float(look.get("strength", 1.0)), 0.0), 1.0)
        except (TypeError, ValueError):
            raise ValueError("look.strength must be a number") from None
        look = {"id": look["id"], "strength": round(strength, 3)}
    layers = body.get("layers")
    if layers is not None:
        layers = importlib.import_module("semantic").clean_layers(layers)
    return {"version": 1, "values": values, "subject": subject, "crop": crop, "look": look,
            "layers": layers, "updated": _now()}


@router.put("/api/shots/{sid}/edit")
async def put_edit(sid: str, request: Request):
    rec = _shot_or_404(sid)
    if isinstance(rec, JSONResponse):
        return rec
    try:
        body = await _json_body(request)
        rec["edit"] = None if body is None else _clean_recipe(body)
    except ValueError as exc:
        return _err(400, str(exc))
    _commit(rec)
    return rec


async def _suggest_call(sid: str, key: tuple, values: dict, goal: str | None) -> dict:
    data = await asyncio.to_thread((_dir(sid) / "image.jpg").read_bytes)
    notes, ids, subject = _notes(sid)
    res = await edit.suggest(data, notes, values, goal, ids, subject)
    if sid in _records:
        _suggest_cache[key] = res
        while len(_suggest_cache) > 64:
            _suggest_cache.popitem(last=False)
    return res


@router.post("/api/shots/{sid}/edit/suggest")
async def post_suggest(sid: str, request: Request):
    rec = _shot_or_404(sid)
    if isinstance(rec, JSONResponse):
        return rec
    try:
        body = await _json_body(request) or {}
        if not isinstance(body, dict):
            raise ValueError("body must be {values, goal}")
        values = edit.clamp_values(body.get("values"))
        goal = " ".join(str(body.get("goal") or "").split())[: edit.GOAL_CHARS] or None
    except ValueError as exc:
        return _err(400, str(exc))
    if not values and not goal and _status(rec, "suggest") == "done":
        auto = await asyncio.to_thread(_read_json, sid, "suggest.json")
        if auto:
            return {**auto, "cached": True}
    key = (sid, json.dumps(values, sort_keys=True), goal)
    if key in _suggest_cache:
        _suggest_cache.move_to_end(key)
        return {**_suggest_cache[key], "cached": True}
    task = _suggest_inflight.get(key)
    if task is None:  # identical concurrent requests share one Gemini call
        task = asyncio.create_task(_suggest_call(sid, key, values, goal))
        _suggest_inflight[key] = task
        task.add_done_callback(lambda _t: _suggest_inflight.pop(key, None))
    try:
        return await asyncio.shield(task)  # a client hanging up doesn't cancel the shared call
    except FileNotFoundError:
        return _err(404, f"shot {sid} was deleted")
    except Exception as exc:
        log.exception("suggest failed for %s", sid)
        return _err(502, f"{type(exc).__name__}: {exc}"[:400])


@router.post("/api/shots/{sid}/splat")
async def post_splat(sid: str):
    rec = _shot_or_404(sid)
    if isinstance(rec, JSONResponse):
        return rec
    st = _status(rec, "splat")
    if st == "done" and (_dir(sid) / "splat.spz").exists():
        return rec
    if st not in ("pending", "running") or f"splat:{sid}" not in _tasks:
        _set(sid, {"splat": {"status": "pending"}})
        _tasks[f"splat:{sid}"] = asyncio.create_task(_do_splat(sid), name=f"splat-{sid}")
    return JSONResponse(rec, status_code=202)


@router.get("/api/shots/{sid}/masks/{rid}.png")
async def get_mask(sid: str, rid: str):
    if not ID_RE.match(sid) or not RID_RE.match(rid):
        return _err(404, "not found")
    path = _dir(sid) / "masks" / f"{rid}.png"
    if not path.is_file():
        return _err(404, f"no mask {rid} for shot {sid}")
    return FileResponse(path, media_type="image/png", headers={"Cache-Control": "no-cache"})


@router.get("/api/shots/{sid}/{name}")
async def get_asset(sid: str, name: str):
    if not ID_RE.match(sid) or name not in FILES:
        return _err(404, "not found")
    path = _dir(sid) / name
    if not path.is_file():
        return _err(404, f"{name} is not ready for shot {sid}")
    cache = "public, max-age=31536000, immutable" if name in IMMUTABLE else "no-cache"
    return FileResponse(path, media_type=FILES[name], headers={"Cache-Control": cache})


@router.get("/api/events")
async def events():
    sub = _Sub()
    if not _closing:
        _subs.add(sub)
    newest = max(_records) if _records else None
    hello = {"version": 1, "time": _now(), "shots": len(_records), "newest": newest,
             "processing": _owner}

    async def stream():
        try:
            yield f"retry: 2000\nevent: hello\ndata: {json.dumps(hello)}\n\n"
            while not _closing:
                try:
                    item = await asyncio.wait_for(sub.q.get(), PING_S)
                except TimeoutError:
                    yield ": ping\n\n"
                    continue
                if item is None:
                    break
                yield item
        finally:
            _subs.discard(sub)

    return StreamingResponse(stream(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
