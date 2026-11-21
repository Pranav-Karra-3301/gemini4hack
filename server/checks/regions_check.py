"""Check regions.find_regions on sample images and draw the boxes.

Usage: cd server && uv run --no-sync python checks/regions_check.py [--effort low|medium|high|none|default]
       [--no-depth] IMG...
Writes ../out/regions_<stem>.jpg (boxes + tags, notes in a footer, ~768 px long side).
Depth Pro runs first and its summary goes into the prompt, as in the pipeline (--no-depth skips it).
The photo is already taken, so a note that asks for a reshoot (move the camera, wait, retake…)
fails the check: exit 1.
"""

import argparse
import asyncio
import json
import re
import sys
from pathlib import Path

from dotenv import load_dotenv
from PIL import Image, ImageDraw, ImageFont

SERVER = Path(__file__).resolve().parent.parent
ROOT = SERVER.parent
sys.path.insert(0, str(SERVER))
load_dotenv(ROOT / ".env")

import regions  # noqa: E402

OUT = ROOT / "out"
COLORS = {"focus": (40, 220, 120), "remove": (255, 70, 70)}
# Advice only a photographer at the scene can follow; none of it is possible in the editor.
CAPTURE = re.compile(
    r"\b(pan|tilt|angle|step|move|walk|lean|reposition)\b(\s+\w+){0,3}?\s+"
    r"(left|right|up|down|closer|back|forward|toward|towards|away|aside|in)\b"
    r"|\bturn (the |your )?(group|subject|camera|him|her|them|toward|towards|away|around|into)\b"
    r"|\b(re-?shoot|re-?take|wait (for|until|till)|next time|come back|shoot (from|again|at|wider|tighter)|"
    r"(fill[- ])?flash|reflector|position the|ask (him|her|them|the)|change (the |your )?(angle|position|viewpoint)|"
    r"get (closer|lower|higher)|(lower|raise) the (camera|lens|phone))\b", re.I)
VIEW = 768


def font(size: int):
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def draw(path: Path, result: dict, labels: list[str]) -> Path:
    im = Image.open(path).convert("RGB")
    im.thumbnail((VIEW, VIEW), Image.LANCZOS)
    W, H = im.size
    f, fs = font(16), font(13)
    footer_h = 22 * len(result["regions"]) + 8
    canvas = Image.new("RGB", (W, H + footer_h), (20, 20, 20))
    canvas.paste(im, (0, 0))
    d = ImageDraw.Draw(canvas)
    for r, label in zip(result["regions"], labels):
        b, c = r["box"], COLORS[r["tag"]]
        x0, y0 = b["x"] * W, b["y"] * H
        x1, y1 = (b["x"] + b["w"]) * W, (b["y"] + b["h"]) * H
        d.rectangle([x0, y0, x1, y1], outline=c, width=3)
        text = f'{r["id"]} {r["tag"]}: {label}'
        tw = d.textlength(text, font=f)
        ty = y0 + 2 if y0 < 20 else y0 - 20
        d.rectangle([x0, ty, x0 + tw + 6, ty + 19], fill=c)
        d.text((x0 + 3, ty + 1), text, fill=(0, 0, 0), font=f)
    for i, r in enumerate(result["regions"]):
        d.text((6, H + 6 + 22 * i), f'{r["id"]} [{r["tag"]}] {r["note"]}', fill=COLORS[r["tag"]], font=fs)
    OUT.mkdir(exist_ok=True)
    dst = OUT / f"regions_{path.stem}.jpg"
    canvas.save(dst, quality=88)
    return dst


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("images", nargs="+", type=Path)
    ap.add_argument("--effort", help="reasoning effort; 'default' = omit the param")
    ap.add_argument("--no-depth", action="store_true", help="don't send a depth summary")
    args = ap.parse_args()
    if args.effort:
        regions.EFFORT = "" if args.effort == "default" else args.effort
    capture = []
    for path in args.images:
        data = path.read_bytes()
        depth_m = None
        if not args.no_depth:
            import depth  # Depth Pro: loads the model on first use

            depth_m, _ = await asyncio.to_thread(depth.infer_depth, data)
        result = await regions.find_regions(data, "image/jpeg", depth_m)
        dbg = regions.last_debug
        print(f"== {path.name}  effort={dbg['effort'] or 'default'}  attempts={dbg['attempts']}")
        if dbg.get("depth_notes"):
            print("   " + dbg["depth_notes"].replace("\n", "\n   "))
        print(json.dumps(result, indent=2, ensure_ascii=False))
        for u in dbg["usage"]:
            print(
                f"   usage: prompt={u.get('prompt_tokens')} completion={u.get('completion_tokens')} "
                f"reasoning={(u.get('completion_tokens_details') or {}).get('reasoning_tokens')} "
                f"cost=${u.get('cost')}"
            )
        print(f"   labels: {dbg['labels']}")
        print(f"   wrote {draw(path, result, dbg['labels'])}")
        capture += [f"{path.name} {r['id']}: {r['note']}" for r in result["regions"] if CAPTURE.search(r["note"])]
    if capture:
        print(f"FAIL: {len(capture)} note(s) ask for a reshoot, but the photo is already taken:")
        print("\n".join(f"   {c}" for c in capture))
        sys.exit(1)
    print(f"OK: {len(args.images)} image(s), no reshoot advice")


if __name__ == "__main__":
    asyncio.run(main())
