"""Check POST /api/review (docs/CORE_API.md §5) against a running Core.

Usage: cd server && uv run --no-sync python checks/review_check.py [--base http://127.0.0.1:8797]
       [--ids d09_heads_cut,d10_tilted_coast,s02_tunnel_selfie,s08_road_hug] [--rounds 1]
       [--refine N] [--shot-id <id>]

Posts each image from experiments/review/set/ (downscaled to 1024 px like the phone) with its
context from set/cases.json, prints the event timeline (ms from request start, client-side) and
the cards, checks the event order (decision/suggestion before final, done last), and prints
p50s. `--refine N` asks for the hydrogen refine on the first N posts of the first round.
`--shot-id` attaches the first post to that shot and then checks assets.review and review.json.
Gemini calls: 2 per post (+1 per refine).
"""

import argparse
import asyncio
import io
import json
import statistics
import sys
import time
from pathlib import Path

import httpx
from PIL import Image

SERVER = Path(__file__).resolve().parents[1]
SET = SERVER.parent / "experiments" / "review" / "set"
DEFAULT_IDS = "d09_heads_cut,d10_tilted_coast,s02_tunnel_selfie,s08_road_hug"
ARROW = {"left": "<-", "right": "->", "up": "^", "down": "v", "closer": "(+)", "back": "(-)",
         "rotate_left": "ccw", "rotate_right": "cw", "none": ""}


def phone_jpeg(path: Path, side: int = 1024) -> bytes:
    im = Image.open(path).convert("RGB")
    im.thumbnail((side, side), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=85)
    return buf.getvalue()


def card_line(c: dict | None) -> str:
    if not c:
        return "(no card)"
    return (f"[{c.get('priority')}] {c.get('action')}  -- {c.get('why')}  "
            f"<{c.get('kind')} {ARROW.get(c.get('direction'), c.get('direction'))}>")


async def post_one(client: httpx.AsyncClient, base: str, cid: str, jpeg: bytes, ctx: dict) -> dict:
    events: list[tuple[float, str, dict]] = []
    t0 = time.perf_counter()
    async with client.stream("POST", f"{base}/api/review",
                             files={"image": ("shot.jpg", jpeg, "image/jpeg")},
                             data={"context": json.dumps(ctx)}) as r:
        if r.status_code != 200:
            return {"id": cid, "error": f"HTTP {r.status_code}: {(await r.aread()).decode()[:200]}", "events": []}
        name = None
        async for line in r.aiter_lines():
            if line.startswith("event:"):
                name = line[6:].strip()
            elif line.startswith("data:") and name:
                events.append(((time.perf_counter() - t0) * 1000, name, json.loads(line[5:])))
                name = None
    return {"id": cid, "events": events, "total": (time.perf_counter() - t0) * 1000}


def report(res: dict) -> list[str]:
    """Prints the timeline; returns order/shape problems."""
    problems = []
    print(f"\n== {res['id']}")
    if res.get("error"):
        print("  ERROR", res["error"])
        return [f"{res['id']}: {res['error']}"]
    names = [e[1] for e in res["events"]]
    for t, name, d in res["events"]:
        if name == "decision":
            p = " ".join(f"{k}={v:.2f}" for k, v in (d.get("p") or {}).items())
            print(f"  {t:6.0f} ms  decision   {d.get('verdict'):<7} p: {p}  card: {card_line(d.get('card'))}")
        elif name == "suggestion":
            print(f"  {t:6.0f} ms  suggestion {card_line(d)}  speak: \"{d.get('speak')}\"")
        elif name in ("final", "refined"):
            extra = f" changed={d.get('changed')}" if name == "refined" else ""
            print(f"  {t:6.0f} ms  {name:<10} {d.get('verdict'):<7} source={d.get('source')}{extra}"
                  f"  working: \"{d.get('working')}\"")
            for c in d.get("suggestions") or []:
                print(f"{'':22}{card_line(c)}")
            if d.get("errors"):
                print(f"{'':22}errors: {d['errors']}")
            if name == "final":
                print(f"{'':22}server timing: {d.get('timing')}")
        elif name == "done":
            print(f"  {t:6.0f} ms  done       saved={d.get('saved')} server_ms={d.get('ms')}"
                  + (f" errors={d['errors']}" if d.get("errors") else ""))
    if not names or names[-1] != "done":
        problems.append(f"{res['id']}: stream did not end with done: {names}")
    if "final" not in names:
        problems.append(f"{res['id']}: no final")
    else:
        fi = names.index("final")
        for n in ("decision", "suggestion"):
            if n in names and names.index(n) > fi:
                problems.append(f"{res['id']}: {n} after final")
        final = res["events"][fi][2]
        if not 1 <= len(final.get("suggestions") or []) <= 3:
            problems.append(f"{res['id']}: final has {len(final.get('suggestions') or [])} cards")
        for c in final.get("suggestions") or []:
            if len(c["action"].split()) > 8 or len(c["why"].split()) > 10 or not c.get("speak"):
                problems.append(f"{res['id']}: card over limits: {c}")
    return problems


def first_time(res: dict, name: str) -> float | None:
    return next((t for t, n, _ in res["events"] if n == name), None)


async def check_shot(client: httpx.AsyncClient, base: str, sid: str) -> list[str]:
    rec = (await client.get(f"{base}/api/shots/{sid}")).json()
    entry = (rec.get("assets") or {}).get("review")
    print(f"\n== shot {sid}: assets.review = {entry}")
    if not entry or entry.get("status") != "done":
        return [f"shot {sid}: assets.review missing"]
    r = await client.get(f"{base}{entry['url']}")
    if r.status_code != 200:
        return [f"shot {sid}: GET {entry['url']} -> {r.status_code}"]
    doc = r.json()
    print(f"  review.json: verdict={doc.get('verdict')} cards={len(doc.get('suggestions') or [])} "
          f"review_id={doc.get('review_id')} refined={'refined' in doc}")
    return []


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8797")
    ap.add_argument("--ids", default=DEFAULT_IDS)
    ap.add_argument("--rounds", type=int, default=1)
    ap.add_argument("--refine", type=int, default=0)
    ap.add_argument("--shot-id")
    args = ap.parse_args()
    cases = {c["id"]: c for c in json.loads((SET / "cases.json").read_text())}
    ids = [i for i in args.ids.split(",") if i]
    images = {i: phone_jpeg(SET / f"{i}.jpg") for i in ids}
    results, problems = [], []
    async with httpx.AsyncClient(timeout=30) as client:
        for rnd in range(args.rounds):
            for k, cid in enumerate(ids):
                ctx = dict(cases[cid]["context"])
                if rnd == 0 and k < args.refine:
                    ctx["refine"] = True
                if rnd == 0 and k == 0 and args.shot_id:
                    ctx["shot_id"] = args.shot_id
                res = await post_one(client, args.base, cid, images[cid], ctx)
                results.append(res)
                problems += report(res)
        if args.shot_id:
            problems += await check_shot(client, args.base, args.shot_id)
    dec = [t for r in results if (t := first_time(r, "decision")) is not None]
    sug = [t for r in results if (t := first_time(r, "suggestion")) is not None]
    fin = [t for r in results if (t := first_time(r, "final")) is not None]

    def p50(v):
        return f"{statistics.median(v):.0f} ms (n={len(v)}, min {min(v):.0f}, max {max(v):.0f})" if v else "-"

    print(f"\ndecision   p50 {p50(dec)}   target <= 800")
    print(f"suggestion p50 {p50(sug)}   target <= 1500")
    print(f"final      p50 {p50(fin)}")
    for p in problems:
        print("PROBLEM", p)
    print("OK" if not problems else f"{len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
