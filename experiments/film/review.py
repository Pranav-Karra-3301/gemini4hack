"""Per-sample review sheet: full frames on top, 1:1 crops (faces) below.
usage: review.py <sample> <col1> <col2> ...   (col = file stem in out/, or 'orig')"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
CROPS = {"img-1016": (400, 320), "img-1216": (220, 330), "img-1408": (220, 480),
         "img-1931": (290, 270), "img-2178": (330, 180)}
s, cols = sys.argv[1], sys.argv[2:]
cw, ch, fw = 400, 300, 400
ims = [Image.open(HERE / "out/work" / f"{s}.jpg") if c == "orig" else Image.open(HERE / "out" / f"{c}.jpg")
       for c in cols]
th = [im.copy() for im in ims]
for t in th:
    t.thumbnail((fw, fw))
H1 = max(t.height for t in th)
sheet = Image.new("RGB", (len(cols) * (fw + 6), H1 + ch + 40), (24, 24, 24))
d = ImageDraw.Draw(sheet)
font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 14)
x0, y0 = CROPS[s]
for i, (c, im, t) in enumerate(zip(cols, ims, th)):
    x = i * (fw + 6)
    d.text((x + 2, 2), c, fill=(230, 230, 230), font=font)
    sheet.paste(t, (x, 20))
    sheet.paste(im.crop((x0, y0, x0 + cw, y0 + ch)), (x, H1 + 34))
out = Path(sys.argv[0]).parent / "out" / f"review_{s}.jpg"
sheet.save(f"/tmp/review_{s}.jpg", quality=90)
print(f"/tmp/review_{s}.jpg", sheet.size)
