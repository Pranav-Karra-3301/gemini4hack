"""Build the post-capture review test set: 8 samples + 5 derived non-selfie cases.

Writes set/<id>.jpg (EXIF-upright, long side 1536, like Core's image.jpg) and set/cases.json
(the "live context" the phone would have at the moment of capture).

    cd server && uv run --no-sync python ../experiments/review/make_set.py
"""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageEnhance, ImageOps

HERE = Path(__file__).resolve().parent
SAMPLES = HERE.parent.parent / "web" / "public" / "samples"
OUT = HERE / "set"
LONG = 1536


def load(name: str) -> Image.Image:
    return ImageOps.exif_transpose(Image.open(SAMPLES / name)).convert("RGB")


def crop(im: Image.Image, x0: float, y0: float, x1: float, y1: float) -> Image.Image:
    w, h = im.size
    return im.crop((round(x0 * w), round(y0 * h), round(x1 * w), round(y1 * h)))


def rotate_inner(im: Image.Image, deg: float) -> Image.Image:
    """Rotate counter-clockwise by `deg` and crop away the empty corners."""
    w, h = im.size
    r = im.rotate(deg, resample=Image.BICUBIC, expand=False)
    m = 0.11  # enough margin for ~6 degrees at these aspect ratios
    return r.crop((round(w * m), round(h * m), round(w * (1 - m)), round(h * (1 - m))))


def underexpose(im: Image.Image, factor: float = 0.32) -> Image.Image:
    return ImageEnhance.Contrast(ImageEnhance.Brightness(im).enhance(factor)).enhance(0.9)


# Settings shorthand: what AVFoundation would report at capture.
def settings(mode="photo", lens="wide", zoom=1.0, iso=50, shutter=0.002, ev=0.0, flash="off"):
    return {"mode": mode, "lens": lens, "zoom": zoom, "iso": iso, "shutter": shutter, "ev": ev, "flash": flash}


SELFIE = {"facing": "front", "selfie": True}
BACK = {"facing": "back", "selfie": False}

CASES = [
    # --- the 8 samples, as shot ---------------------------------------------------------------
    dict(id="s01_sunset_selfie", src="img-1016.jpg", **SELFIE,
         intent="group", subject="five friends at sunset",
         keep=["man in front, centre", "man in teal shirt, left", "man in green shirt, back left",
               "man with glasses, back right", "man in grey t-shirt, right"],
         scene="sunset over the sea and the coastline", heard="get all of us and the sunset",
         coach=["Raise the phone a little"], settings=settings(iso=40, shutter=0.001)),
    dict(id="s02_tunnel_selfie", src="img-1216.jpg", **SELFIE,
         intent="group", subject="friends in tree tunnel",
         keep=["man in sunglasses, front", "man in black shirt, left", "man with beard, back left",
               "man in green shirt, back right", "man in black t-shirt, right"],
         scene="cypress tree tunnel and its vanishing point", heard="I want the whole tunnel behind us",
         coach=["Hold the phone higher, tilt down"], settings=settings(iso=64, shutter=0.004)),
    dict(id="s03_bench_backs", src="img-1408.jpg", **BACK,
         intent="group", subject="three friends on bench",
         keep=["person on the left", "man in the middle", "man in white shirt, right"],
         scene="Big Sur coastline", heard="take one of them looking at the view",
         coach=[], settings=settings(iso=32, shutter=0.0008)),
    dict(id="s04_picnic_selfie", src="img-1427.jpg", **SELFIE,
         intent="group", subject="lunch with a view",
         keep=["man in sunglasses, right", "man in striped shirt, middle", "man with beard, back"],
         scene="rocky beach and sea stacks", heard="",
         coach=[], settings=settings(iso=40, shutter=0.001)),
    dict(id="s05_car_cliffs", src="img-1457.jpg", **BACK,
         intent="group", subject="two of us with the car",
         keep=["man on the car", "man standing by the car", "black car"],
         scene="cliffs and the sea", heard="get the car and the cliffs, we're over here",
         coach=[], settings=settings(iso=50, shutter=0.002)),
    dict(id="s06_railing_trio", src="img-1491.jpg", **BACK,
         intent="group", subject="three friends at railing",
         keep=["man in tan jacket", "man in floral shirt", "man in striped shirt"],
         scene="waves and rocks", heard="all three of us with the waves please",
         coach=["Step back a bit"], settings=settings(iso=40, shutter=0.001)),
    dict(id="s07_cliff_sign", src="img-1931.jpg", **BACK,
         intent="group", subject="two friends with sign",
         keep=["man in red shirt", "man in black shirt", "the 'stay back' sign"],
         scene="", heard="the funny one with the sign",
         coach=[], settings=settings(iso=32, shutter=0.0005)),
    dict(id="s08_road_hug", src="img-2178.jpg", **BACK,
         intent="", subject="", keep=[], scene="", heard="quick, quick, everyone hug",
         coach=[], settings=settings(iso=64, shutter=0.004)),
    # --- derived non-selfie cases ------------------------------------------------------------
    dict(id="d09_heads_cut", src="img-1491.jpg", make="heads_cut", **BACK,
         intent="group", subject="three friends at railing",
         keep=["man in tan jacket", "man in floral shirt", "man in striped shirt"],
         scene="the sea", heard="",
         coach=[], settings=settings(zoom=2.0, lens="tele", iso=50, shutter=0.001)),
    dict(id="d10_tilted_coast", src="img-1408.jpg", make="tilted_landscape", **BACK,
         intent="landscape", subject="", keep=[], scene="", heard="whoa, look at that",
         coach=[], settings=settings(iso=25, shutter=0.0005)),
    dict(id="d11_dark_portrait", src="img-1931.jpg", make="dark_portrait", **BACK,
         intent="portrait", subject="him in the red shirt", keep=["man in red shirt"],
         scene="the ocean", heard="just him this time",
         coach=[], settings=settings(iso=32, shutter=0.0003, ev=-1.7)),
    dict(id="d12_food", src="img-1427.jpg", make="food", **BACK,
         intent="food", subject="my sandwich", keep=["sandwich"], scene="",
         heard="get the sandwich", coach=[], settings=settings(iso=50, shutter=0.002)),
    dict(id="d13_sign_doc", src="img-1931.jpg", make="sign_doc", **BACK,
         intent="document", subject="warning sign", keep=["the whole sign"], scene="",
         heard="I want to read that sign later", coach=[], settings=settings(zoom=2.0, lens="tele")),
]


def derive(kind: str, im: Image.Image) -> Image.Image:
    if kind == "heads_cut":  # tight crop: tops of heads and the feet cut off
        return crop(im, 0.234, 0.4375, 0.734, 0.9375)
    if kind == "tilted_landscape":  # top of the bench shot (no people), rolled 6 degrees
        return rotate_inner(crop(im, 0.0, 0.0, 1.0, 0.45), 6.0)
    if kind == "dark_portrait":  # red-shirt man dead centre, friend half cut, -1.7 EV
        return underexpose(crop(im, 0.133, 0.125, 0.523, 0.819))
    if kind == "food":  # the sandwich cut by the bottom edge, shot at a slant
        return crop(im, 0.3125, 0.625, 0.6875, 1.0)
    if kind == "sign_doc":  # the sign at an angle, its right side cut
        return crop(im, 0.297, 0.5, 0.531, 0.875)
    raise ValueError(kind)


def main() -> None:
    OUT.mkdir(exist_ok=True)
    out = []
    for c in CASES:
        im = load(c["src"])
        if c.get("make"):
            im = derive(c["make"], im)
        im.thumbnail((LONG, LONG), Image.LANCZOS)
        im.save(OUT / f"{c['id']}.jpg", quality=88)
        ctx = {k: v for k, v in c.items() if k not in ("id", "src", "make")}
        out.append({"id": c["id"], "src": c["src"], "make": c.get("make"), "size": im.size, "context": ctx})
        print(c["id"], im.size)
    (OUT / "cases.json").write_text(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
