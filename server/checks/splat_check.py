"""Check /api/splat and /api/reframe against a running server.

Usage: cd server && uv run --no-sync python checks/splat_check.py [--base URL] [--keep-cache] [IMG...]
Defaults: --base http://127.0.0.1:8787, images img-1216 and img-1427 from web/public/samples/.

Each image is first normalized like the browser does (upright, long side 1536, JPEG). /api/splat
runs on the first image twice: cold (its cache entry is deleted first unless --keep-cache) and
warm (a cache hit). The .spz is sanity-checked (gzip, NGSP v3 header, count, metric depth) and
compared with the wayback splat of the same photo. The worker's memory comes from the server's
X-Splat-Peak-Mb header (worker lifetime peak physical footprint, Metal buffers included).
/api/reframe runs on every image (the second one with regions from /api/regions).
"""

import argparse
import gzip
import hashlib
import io
import json
import struct
import sys
import time
from pathlib import Path

import httpx
import numpy as np
from PIL import Image, ImageOps

SERVER = Path(__file__).resolve().parent.parent
ROOT = SERVER.parent
SAMPLES = ROOT / "web" / "public" / "samples"
SPLATS = ROOT / "web" / "public" / "splats"
CACHE = SERVER / "cache" / "splats"
OUT = ROOT / "out"


def normalize(path: Path) -> bytes:
    img = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    img.thumbnail((1536, 1536), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=90)
    return buf.getvalue()


def spz_info(raw_gz: bytes) -> dict:
    assert raw_gz[:2] == b"\x1f\x8b", "not gzip"
    raw = gzip.decompress(raw_gz)
    magic, version, n, sh, frac, flags, _ = struct.unpack("<IIIBBBB", raw[:16])
    assert magic == 0x5053474E, f"bad magic {magic:#x}"
    assert version in (2, 3), f"version {version}"
    b = np.frombuffer(raw, np.uint8, count=9 * n, offset=16).reshape(n, 3, 3).astype(np.int32)
    v = b[..., 0] | (b[..., 1] << 8) | (b[..., 2] << 16)
    v = np.where(v & 0x800000, v - (1 << 24), v).astype(np.float64) / (1 << frac)
    z = v[:, 2]
    return {"bytes": len(raw_gz), "version": version, "n": n, "sh": sh, "frac_bits": frac,
            "z_p05": float(np.percentile(z, 5)), "z_med": float(np.median(z)),
            "z_p95": float(np.percentile(z, 95)), "frac_z_pos": float(np.mean(z > 0))}


def splat(client: httpx.Client, base: str, data: bytes) -> tuple[bytes, dict, float]:
    t = time.perf_counter()
    r = client.post(f"{base}/api/splat", files={"image": ("photo.jpg", data, "image/jpeg")})
    wall = time.perf_counter() - t
    if r.status_code != 200:
        sys.exit(f"/api/splat HTTP {r.status_code}: {r.text[:300]}")
    return r.content, {k: v for k, v in r.headers.items() if k.lower().startswith("x-splat")}, wall


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8787")
    ap.add_argument("--keep-cache", action="store_true")
    ap.add_argument("images", nargs="*", type=Path,
                    default=[SAMPLES / "img-1216.jpg", SAMPLES / "img-1427.jpg"])
    args = ap.parse_args()
    client = httpx.Client(timeout=300.0)
    imgs = [(p, normalize(p)) for p in args.images]

    # --- /api/splat: cold then warm
    path, data = imgs[0]
    sha = hashlib.sha1(data).hexdigest()
    if not args.keep_cache:
        for suf in (".spz", ".json"):
            (CACHE / f"{sha}{suf}").unlink(missing_ok=True)
    w, h = Image.open(io.BytesIO(data)).size
    print(f"{path.name}: normalized {w}x{h}, {len(data) / 1024:.0f} KB, sha1 {sha[:10]}")
    for label in ("cold", "warm"):
        body, hdr, wall = splat(client, args.base, data)
        print(f"  {label}: {wall:.2f}s wall  " + "  ".join(f"{k}={v}" for k, v in sorted(hdr.items())))
        if label == "cold":
            info = spz_info(body)
            print(f"  spz: {info['bytes'] / 2**20:.1f} MB, v{info['version']}, {info['n']:,} gaussians, "
                  f"sh {info['sh']}, z p05/med/p95 {info['z_p05']:.2f}/{info['z_med']:.2f}/"
                  f"{info['z_p95']:.2f} m, {info['frac_z_pos'] * 100:.1f}% in front of camera")
            assert info["n"] > 500_000 and info["frac_z_pos"] > 0.99, "implausible splat"
            OUT.mkdir(exist_ok=True)
            (OUT / f"splat_{path.stem}.spz").write_bytes(body)
            ref = SPLATS / f"{path.stem}.spz"
            if ref.exists():
                ri = spz_info(ref.read_bytes())
                idx = json.loads((SPLATS / "index.json").read_text()).get(path.stem, {})
                f = float(hdr.get("x-splat-focal-px", "nan"))
                print(f"  wayback ref: {ri['n']:,} gaussians, z med {ri['z_med']:.2f} m; "
                      f"f/w ours {f / w:.3f} vs wayback {idx.get('f_over_w', float('nan')):.3f}")
        else:
            assert hdr.get("x-splat-cache") == "hit", "second request was not a cache hit"

    # --- /api/reframe
    for i, (path, data) in enumerate(imgs[:2]):
        form = {}
        if i == 1:
            r = client.post(f"{args.base}/api/regions", files={"image": ("p.jpg", data, "image/jpeg")})
            if r.status_code == 200:
                form["regions"] = json.dumps(r.json()["regions"])
                print(f"{path.name}: regions " + "; ".join(
                    f'{g["tag"]}: {g["note"]}' for g in r.json()["regions"]))
            else:
                print(f"{path.name}: /api/regions HTTP {r.status_code}, reframing without regions")
        t = time.perf_counter()
        r = client.post(f"{args.base}/api/reframe", files={"image": ("p.jpg", data, "image/jpeg")}, data=form)
        if r.status_code != 200:
            sys.exit(f"/api/reframe HTTP {r.status_code}: {r.text[:300]}")
        res = r.json()
        print(f"{path.name}: reframe {time.perf_counter() - t:.2f}s ({res['model']}, ms={res['ms']}) "
              f"{'with' if form else 'no'} regions: {json.dumps(res['move'])}  \"{res['note']}\"")
    print("ok")


if __name__ == "__main__":
    main()
