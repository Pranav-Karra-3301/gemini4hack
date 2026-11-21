"""Check the camera coach's behaviour against real Gemini Live (issue #30).

Usage:
  cd server && uv run --no-sync python checks/live_coach_check.py [--runs 2]

Connects straight to the Live API with GEMINI_API_KEY (the environment, else ../.env, else the
main checkout's .env; never printed) and the real camera setup (live_setup.build_setup). It plays
the iPhone app: sends JPEG frames (<=768 px) as realtimeInput.video, `[tick]` and `[scene]` text
turns in the app's wording, and answers every tool call SILENT the way the app does (set_camera
echoes the applied values, with the mode presets of AVCaptureEngine.preset()). Scenarios:
  1. a soda can at the far end of a messy table: set_intent object/food naming the can, a guide
     that is not hold, not ready; a second tick on the same frame must not flip to the opposite move.
  2. the same can, close and low with a clean wall behind ([scene] then a tick): shot_ready true,
     guide hold, set_intent (if any) still the can.
  5. a tick on that unchanged, ready frame ("Shot ready: yes"): no new correction, little speech.
  3. a completely different scene (friends at the ocean) after [scene]: a new set_intent (not the
     can) and no mention of the can.
  4. a fresh session with "Mode: portrait." on a wide coast scene: set_camera mode photo.
  D. a fresh session: the far can with a Director block in the tick (NEW shot, closer, portrait):
     set_intent naming the can, guide closer, set_camera mode portrait, not ready.
Each run is one camera session (1, 2, 5, 3 in order) plus one each for 4 and D; runs go in parallel.
Prints each turn's tool calls, transcript and latency, then pass counts per scenario.
"""

from __future__ import annotations

import asyncio
import base64
import io
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import websockets
from dotenv import load_dotenv
from PIL import Image

SERVER = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVER))

import live_setup  # noqa: E402

LIVE_URL = ("wss://generativelanguage.googleapis.com/ws/"
            "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")  # = cam.LIVE_URL
FIX = SERVER / "checks" / "fixtures" / "coach"
SAMPLES = SERVER.parent / "web" / "public" / "samples"
FRAMES = {
    "can_far": FIX / "can_far_messy_table.jpg",   # can at the far end of a cluttered table
    "can_close": FIX / "can_close_low.jpg",       # same kind of can, close, at can height, plain wall
    "friends_ocean": SAMPLES / "img-1491.jpg",    # three friends at an ocean overlook
    "coast": SAMPLES / "img-1457.jpg",            # wide coast, cliffs and a parking lot
}
SCENE = ("[scene] The view changed completely in the last few seconds. If the camera now points at a "
         "different subject, this is a new shot: call set_intent for it and drop the old advice. If it "
         "is the same subject reframed (closer, lower, new angle), keep going.")
CAN_SUBJECT = re.compile(r"\b(cans?|soda|coke|coca|cola|drinks?|beverage|pop)\b", re.I)
CAN_SPOKEN = re.compile(r"\b(soda|coke|cola|drinks?|beverage|(?:the|that|this|a|your) can)\b", re.I)
DIRECTOR = (' Director (Gemini 4, latest frame): shot object "soda can" (NEW shot), score 4/10; issues: '
            'table clutter behind the can; can small in frame; next move: closer (medium); best mode: '
            'portrait (now photo); ready: no; tip: "Get closer, level with the can."')
OPPOSITE = {"left": "right", "right": "left", "up": "down", "down": "up", "closer": "back",
            "back": "closer", "rotate_left": "rotate_right", "rotate_right": "rotate_left"}


def load_key() -> None:
    if os.environ.get("GEMINI_API_KEY"):
        return
    load_dotenv(SERVER.parent / ".env")
    if not os.environ.get("GEMINI_API_KEY"):  # a worktree: the main checkout holds .env
        common = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                cwd=SERVER, capture_output=True, text=True).stdout.strip()
        if common:
            load_dotenv(Path(common).parent / ".env")
    if not os.environ.get("GEMINI_API_KEY"):
        sys.exit("GEMINI_API_KEY is not set (environment or .env)")


def jpeg768(path: Path) -> str:
    im = Image.open(path).convert("RGB")
    im.thumbnail((768, 768))
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=70)
    return base64.b64encode(buf.getvalue()).decode()


def ms(t0: float) -> int:
    return int((time.perf_counter() - t0) * 1000)


class App:
    """The iPhone app's side of the session: camera state, tool answers and the [tick] line."""

    def __init__(self, mode: str = "photo", zoom: float = 1.0, ev: float = 0.0):
        self.cam = {"mode": mode, "lens": "wide", "zoom": zoom, "iso": "auto", "shutter": "auto",
                    "ev": ev, "focus": "auto", "wb_kelvin": "auto"}
        self.intent = self.subject = None
        self.subject_at = 0.0
        self.view_changed = False      # since the subject was set
        self.ready = False
        self.ready_at = 0.0
        self.moved_after_ready = False
        self.frame: str | None = None

    def show(self, name: str) -> None:
        if self.frame is not None and name != self.frame:
            if self.subject:
                self.view_changed = True
            if self.ready:
                self.ready, self.moved_after_ready = False, True
        self.frame = name

    def scene_shift(self) -> None:  # the app clears the ready glow and the arrow on its own
        if self.ready:
            self.ready, self.moved_after_ready = False, True

    def answer(self, name: str, args: dict) -> dict:
        if name == "shot_ready":
            self.ready, self.ready_at, self.moved_after_ready = bool(args.get("ready")), time.monotonic(), False
        elif name == "set_intent":
            self.intent, self.subject = args.get("intent"), args.get("subject") or ""
            self.subject_at, self.view_changed = time.monotonic(), False
        elif name == "set_camera":
            applied = {k: v for k, v in args.items() if k != "why"}
            mode = applied.get("mode")
            if mode == "portrait":
                if "zoom" not in applied and "lens" not in applied and self.cam["zoom"] < 1.9:
                    applied["zoom"] = 2.0
                applied.setdefault("ev", 0.3)
                applied.setdefault("focus", "auto")
            elif mode == "photo":
                applied.setdefault("ev", 0.0)
            elif mode == "night":
                applied.setdefault("shutter", 0.05)
                applied.setdefault("iso", 640)
            elif mode == "macro":
                applied.setdefault("lens", "ultrawide")
                applied.setdefault("zoom", 0.5)
                applied.setdefault("focus", "auto")
            for k in ("mode", "lens", "zoom", "iso", "shutter", "ev", "focus", "wb_kelvin"):
                if k in applied:
                    self.cam[k] = applied[k]
            return {"ok": True, "applied": applied}
        return {"ok": True}

    def tick(self) -> str:
        c, now = self.cam, time.monotonic()
        iso = "100 (auto)" if c["iso"] == "auto" else f"{c['iso']:g}"
        sh = c["shutter"]
        sh = "1/120 (auto)" if sh == "auto" else (f"1/{round(1 / sh)}" if sh < 1 else f"{sh:g} s")
        wb = "auto (~5200 K)" if c["wb_kelvin"] == "auto" else f"{c['wb_kelvin']:g} K"
        focus = c["focus"] if c["focus"] == "auto" else f"{c['focus']:g}"
        line = (f"[tick] Mode: {c['mode']}. Camera: mode {c['mode']}, lens {c['lens']}, zoom {c['zoom']:.1f}x, "
                f"ISO {iso}, shutter {sh}, EV {c['ev']:+.1f}, focus {focus}, WB {wb}. ")
        if not self.subject:
            line += "Subject: not set yet. "
        else:
            line += (f'Subject you last set: {self.intent} "{self.subject}" ({round(now - self.subject_at)} s ago); '
                     + ("the view has changed a lot since, check it is still the subject. " if self.view_changed
                        else "view steady since. "))
        if self.ready:
            line += f"Shot ready: yes (you said so {max(1, round(now - self.ready_at))} s ago)."
        elif self.moved_after_ready:
            line += "Shot ready: no (the view moved after you said ready)."
        else:
            line += "Shot ready: no."
        return line


async def send_frame(ws, app: App, name: str, frames: dict[str, str]) -> None:
    app.show(name)
    await ws.send(json.dumps({"realtimeInput": {"video": {"data": frames[name], "mimeType": "image/jpeg"}}}))


async def live_turn(ws, app: App, text: str, timeout: float = 25.0) -> dict:
    """Send a text turn; answer tool calls like the app (SILENT); collect calls and transcript.
    Reads until turnComplete plus a short grace period for trailing calls."""
    out = {"text": text, "calls": [], "said": "", "first_ms": None, "done_ms": None}
    t0 = time.perf_counter()
    await ws.send(json.dumps({"realtimeInput": {"text": text}}))
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            m = json.loads(await asyncio.wait_for(ws.recv(), max(0.1, end - time.monotonic())))
        except asyncio.TimeoutError:
            break
        if "toolCall" in m:
            out["first_ms"] = out["first_ms"] or ms(t0)
            resp = []
            for fc in m["toolCall"].get("functionCalls", []):
                args = fc.get("args") or {}
                out["calls"].append((fc["name"], args))
                resp.append({"id": fc["id"], "name": fc["name"], "response": app.answer(fc["name"], args),
                             "scheduling": "SILENT"})
            await ws.send(json.dumps({"toolResponse": {"functionResponses": resp}}))
            end = max(end, time.monotonic() + 5)
        sc = m.get("serverContent") or {}
        said = (sc.get("outputTranscription") or {}).get("text", "")
        if said:
            out["first_ms"] = out["first_ms"] or ms(t0)
            out["said"] += said
        if sc.get("turnComplete"):
            out["done_ms"] = ms(t0)
            end = min(end, time.monotonic() + 1.5)
    out["said"] = " ".join(out["said"].split())
    return out


def named(turns: list[dict], name: str) -> list[dict]:
    return [a for t in turns for n, a in t["calls"] if n == name]


def last_guide(turns: list[dict]) -> str | None:
    g = named(turns, "guide")
    return g[-1].get("direction") if g else None


def last_ready(turns: list[dict]) -> bool | None:
    r = named(turns, "shot_ready")
    return bool(r[-1].get("ready")) if r else None


class Run:
    def __init__(self, idx: int, frames: dict[str, str]):
        self.idx, self.frames = idx, frames
        self.log: list[str] = []
        self.results: dict[str, list[tuple[bool, str]]] = {}
        self.lat: list[tuple[int | None, int | None]] = []

    def p(self, s: str) -> None:
        self.log.append(s)

    def ok(self, scen: str, cond: bool, label: str, detail: str = "") -> None:
        self.results.setdefault(scen, []).append((bool(cond), label))
        self.p(f"    {'ok  ' if cond else 'FAIL'} {label}{(': ' + detail) if detail else ''}")

    def show(self, step: str, t: dict) -> None:
        self.lat.append((t["first_ms"], t["done_ms"]))
        calls = ", ".join(f"{n}({json.dumps(a, separators=(',', ':'))})" for n, a in t["calls"]) or "no calls"
        self.p(f"  [{step}] {t['text'][:150]}{'...' if len(t['text']) > 150 else ''}")
        self.p(f"    first {t['first_ms']} ms, done {t['done_ms']} ms | {calls}")
        self.p(f"    said: {t['said']!r}")

    async def connect(self, setup: dict):
        ws = await websockets.connect(LIVE_URL, additional_headers={"x-goog-api-key": os.environ["GEMINI_API_KEY"]},
                                      max_size=None, open_timeout=10)
        await ws.send(json.dumps({"setup": setup}))
        while "setupComplete" not in json.loads(await asyncio.wait_for(ws.recv(), 15)):
            pass
        return ws

    async def session_a(self) -> None:
        app = App()
        ws = await self.connect(live_setup.build_setup("camera", voice=True, facing="back"))
        try:
            # 1. Far can on a messy table.
            await send_frame(ws, app, "can_far", self.frames)
            await asyncio.sleep(1.5)
            t1 = await live_turn(ws, app, app.tick())
            self.show("1 far can, tick", t1)
            si = named([t1], "set_intent")
            self.ok("1", bool(si) and si[-1].get("intent") in ("object", "food")
                    and bool(CAN_SUBJECT.search(si[-1].get("subject") or "")),
                    "set_intent object/food naming the can", json.dumps(si[-1:]))
            g1 = last_guide([t1])
            self.ok("1", g1 not in (None, "hold"), "guide is a move, not hold", str(g1))
            self.ok("1", last_ready([t1]) is not True, "not ready")
            await asyncio.sleep(3)
            t1b = await live_turn(ws, app, app.tick())
            self.show("1b same frame, tick", t1b)
            g1b = last_guide([t1b])
            self.ok("1", g1b != "hold" and (g1 is None or g1b != OPPOSITE.get(g1)),
                    "same frame: no hold, no flip to the opposite move", f"{g1} -> {g1b}")
            self.ok("1", last_ready([t1b]) is not True, "same frame: still not ready")

            # 2. Close, low, clean: the same can reframed.
            await send_frame(ws, app, "can_close", self.frames)
            await asyncio.sleep(1.5)
            app.scene_shift()
            t2a = await live_turn(ws, app, SCENE)
            self.show("2 close can, [scene]", t2a)
            await asyncio.sleep(2)
            t2b = await live_turn(ws, app, app.tick())
            self.show("2 close can, tick", t2b)
            self.ok("2", last_ready([t2a, t2b]) is True, "shot_ready true")
            self.ok("2", last_guide([t2a, t2b]) == "hold", "guide hold", str(last_guide([t2a, t2b])))
            si2 = named([t2a, t2b], "set_intent")
            self.ok("2", all(CAN_SUBJECT.search(a.get("subject") or "") for a in si2),
                    "still the can (no new subject)", json.dumps(si2) if si2 else "no set_intent")
            said2 = (t2a["said"] + " " + t2b["said"]).strip()
            self.p(f"    info: ready line {said2!r} ({len(said2.split())} words)")

            # 5. Unchanged, already ready.
            if app.ready:
                await asyncio.sleep(3)
                t5 = await live_turn(ws, app, app.tick())
                self.show("5 ready, unchanged, tick", t5)
                g5 = [a.get("direction") for a in named([t5], "guide")]
                self.ok("5", all(d == "hold" for d in g5), "no move (hold or no guide)", str(g5))
                self.ok("5", last_ready([t5]) is not False, "does not take ready back")
                self.ok("5", not named([t5], "set_camera"), "no settings tweak", json.dumps(named([t5], "set_camera")))
                self.ok("5", len(t5["said"].split()) <= 4, "little or no speech", repr(t5["said"]))
            else:
                self.ok("5", False, "precondition: step 2 left the shot ready")

            # 3. A completely different scene.
            await send_frame(ws, app, "friends_ocean", self.frames)
            await asyncio.sleep(1.5)
            app.scene_shift()
            t3a = await live_turn(ws, app, SCENE)
            self.show("3 friends at the ocean, [scene]", t3a)
            await asyncio.sleep(2)
            t3b = await live_turn(ws, app, app.tick())
            self.show("3 friends at the ocean, tick", t3b)
            si3 = named([t3a, t3b], "set_intent")
            self.ok("3", any(a.get("intent") not in ("object", "food") and not CAN_SUBJECT.search(a.get("subject") or "")
                             for a in si3), "set_intent for the new shot", json.dumps(si3))
            said3 = t3a["said"] + " " + t3b["said"]
            self.ok("3", not CAN_SPOKEN.search(said3), "never mentions the can", repr(said3.strip()))
            self.ok("3", not CAN_SUBJECT.search(json.dumps(named([t3a, t3b], "set_camera"))),
                    "no can in set_camera why")
        finally:
            await ws.close()

    async def session_b(self) -> None:
        app = App(mode="portrait", zoom=2.0, ev=0.3)
        ws = await self.connect(live_setup.build_setup("camera", voice=True, facing="back"))
        try:
            await send_frame(ws, app, "coast", self.frames)
            await asyncio.sleep(1.5)
            t4 = await live_turn(ws, app, app.tick())
            self.show("4 portrait mode on a wide coast, tick", t4)
            modes = [a.get("mode") for a in named([t4], "set_camera") if a.get("mode")]
            self.ok("4", "photo" in modes, "set_camera mode photo", str(modes))
        finally:
            await ws.close()

    async def session_c(self) -> None:
        app = App()
        ws = await self.connect(live_setup.build_setup("camera", voice=True, facing="back"))
        try:
            await send_frame(ws, app, "can_far", self.frames)
            await asyncio.sleep(1.5)
            td = await live_turn(ws, app, app.tick() + DIRECTOR)
            self.show("D far can, tick + Director", td)
            si = named([td], "set_intent")
            self.ok("D", any(CAN_SUBJECT.search(a.get("subject") or "") for a in si), "set_intent naming the can",
                    json.dumps(si))
            self.ok("D", last_guide([td]) == "closer", "guide closer", str(last_guide([td])))
            modes = [a.get("mode") for a in named([td], "set_camera") if a.get("mode")]
            self.ok("D", "portrait" in modes, "set_camera mode portrait", str(modes))
            self.ok("D", last_ready([td]) is not True, "not ready")
        finally:
            await ws.close()

    async def go(self) -> None:
        for name, fn in (("A", self.session_a), ("B", self.session_b), ("C", self.session_c)):
            self.p(f" session {name}")
            try:
                await fn()
            except Exception as exc:  # fail loudly, keep the other session going
                self.ok(name, False, f"session {name} crashed", f"{type(exc).__name__}: {exc}"[:200])


async def main() -> int:
    args = sys.argv[1:]
    runs = int(args[args.index("--runs") + 1]) if "--runs" in args else 2
    load_key()
    frames = {k: jpeg768(p) for k, p in FRAMES.items()}
    setup = live_setup.build_setup("camera")
    print(f"model {setup['model']}, camera prompt {len(setup['systemInstruction']['parts'][0]['text'])} chars, "
          f"{runs} run(s)")
    rs = [Run(i + 1, frames) for i in range(runs)]
    await asyncio.gather(*(r.go() for r in rs))
    for r in rs:
        print(f"\n=== run {r.idx}")
        print("\n".join(r.log))
    print("\nsummary (passed runs / runs):")
    fails = 0
    for scen in ("1", "2", "5", "3", "4", "D", "A", "B", "C"):
        per_run = [all(c for c, _ in r.results[scen]) for r in rs if scen in r.results]
        if not per_run:
            continue
        fails += per_run.count(False)
        failed = sorted({lbl for r in rs for c, lbl in r.results.get(scen, []) if not c})
        print(f"  scenario {scen}: {sum(per_run)}/{len(per_run)}" + (f"  (failed: {'; '.join(failed)})" if failed else ""))
    lat = [x for r in rs for x in r.lat]
    firsts = sorted(f for f, _ in lat if f is not None)
    dones = sorted(d for _, d in lat if d is not None)
    if firsts and dones:
        print(f"  latency: first response median {firsts[len(firsts) // 2]} ms (max {firsts[-1]}), "
              f"turn done median {dones[len(dones) // 2]} ms (max {dones[-1]}) over {len(lat)} turns")
    print("\nALL OK" if not fails else f"\n{fails} scenario run(s) FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
