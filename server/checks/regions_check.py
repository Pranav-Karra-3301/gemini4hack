"""Check regions.find_regions on sample images and draw the boxes.

Usage: cd server && uv run --no-sync python checks/regions_check.py [--effort low|medium|high|none|default]
       [--no-depth] IMG...
Writes ../out/regions_<stem>.jpg (boxes + tags, notes in a footer, ~768 px long side).
Depth Pro runs first and its summary goes into the prompt, as in the pipeline (--no-depth skips it).
The photo is already taken, so a note the editor can't act on (move the camera, wait, retake,
erase an object…) fails the check: exit 1.
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
# Notes the editor can't act on: advice for the photographer at the scene, or erasing objects.
# Verbs count only where an instruction starts ("Crop or step left" fails, "Straighten the tilt
# to the left" passes).
_START = r"(?:^|[;:.!?]\s+|,\s+|\b(?:or|and|then)\s+)"
CAPTURE = re.compile(
    _START + r"(pan|tilt|angle|step|move|walk|lean|position|reposition|re-?shoot|re-?take|wait|ask|"
    r"remove|erase|clone|delete|heal|retouch)\b"
    r"|" + _START + r"turn\b(?!\s+(down|up)\b)"
    r"|" + _START + r"(shoot|get)\s+(\w+\s+)?(again|later|from|closer|lower|higher|wider|tighter)\b"
    r"|\b(use|add|with|try)\s+(a\s+|the\s+|some\s+)?(fill[- ])?(flash|reflector)\b"
    r"|\b(wait (for|until|till)|next time|come back|switch off|shutter speed|aperture)\b", re.I)
# Regression cases for CAPTURE itself, checked before any API call.
CAPTURE_CASES = {
    True: ["Wait for the walker and dog to clear the tree tunnel.", "Step much closer; the subjects are tiny.",
           "Crop or step left to exclude the messy dry brush.", "Turn toward the sun or add fill flash.",
           "Angle the group slightly left to catch side-light.", "Pan right or lower highlights on the sun.",
           "Clone out or crop the bright orange date stamp.", "Remove the trash can at left.",
           "Turn off the lamp.", "Use a faster shutter speed.", "Shoot this again later.",
           "Position the receding cliffs to lead the eye.",
           "Use fill flash or a reflector to lift the shadows."],
    False: ["Straighten the tilt to the left horizon.", "Crop the tilted angle at left.",
            "Crop the angle in tighter.", "Tone down the flash glare on her forehead.",
            "Crop to reposition her left of center.", "Crop tighter to get closer to her face.",
            "Crop up from the bottom to remove the bare dirt foreground.",
            "Turn down the saturation of the orange sign.", "Lower highlights on the blown-out sun corner.",
            "Add lens blur beyond 5 m to soften the distant walker and dog.",
            "Crop up through the near pavement; it removes the painted line too.",
            "Lift shadows and warm the foreground subjects under 2 m."],
}
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
    wrong = [n for want, notes in CAPTURE_CASES.items() for n in notes if bool(CAPTURE.search(n)) != want]
    if wrong:
        print("CAPTURE regex misclassifies:", *wrong, sep="\n   ")
        sys.exit(2)
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
        print(f"FAIL: {len(capture)} note(s) ask for something the editor can't do (the photo is taken):")
        print("\n".join(f"   {c}" for c in capture))
        sys.exit(1)
    print(f"OK: {len(args.images)} image(s), every note is an edit")


if __name__ == "__main__":
    asyncio.run(main())
