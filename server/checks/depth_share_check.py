"""Check that concurrent depth.infer_depth calls on the same image share one Depth Pro run (#31).

Usage: cd server && uv run --no-sync python checks/depth_share_check.py [--real]

Offline by default: depth._infer_depth_uncached is swapped for a slow fake that counts calls, and
threads call infer_depth the way Core does (asyncio.to_thread from concurrent requests).
--real also runs Depth Pro on a sample photo from 2 threads and counts real inferences.
"""

import argparse
import sys
import threading
import time
from pathlib import Path

import numpy as np

SERVER = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVER))

import depth  # noqa: E402

SAMPLE = SERVER.parent / "web" / "public" / "samples" / "img-1216.jpg"
failures: list[str] = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        failures.append(msg)


def run_threads(n: int, payloads: list[bytes]) -> tuple[list, list]:
    results, errors = [None] * n, [None] * n

    def work(i):
        try:
            results[i] = depth.infer_depth(payloads[i % len(payloads)])
        except Exception as exc:  # noqa: BLE001
            errors[i] = exc

    threads = [threading.Thread(target=work, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return results, errors


def fake_checks() -> None:
    print("fake model")
    real = depth._infer_depth_uncached
    calls: list[bytes] = []
    fail = {"left": 0}

    def fake(image_bytes):
        calls.append(image_bytes)
        time.sleep(0.3)
        if fail["left"]:
            fail["left"] -= 1
            raise RuntimeError("fake inference failure")
        return np.full((4, 3), float(len(image_bytes)), np.float32), {"infer_ms": 300}

    depth._infer_depth_uncached = fake
    try:
        depth._cache.clear()
        t0 = time.perf_counter()
        res, errs = run_threads(4, [b"same-image"])
        wall = time.perf_counter() - t0
        check(len(calls) == 1, f"4 concurrent calls, same bytes -> {len(calls)} inference(s)")
        check(not any(errs) and all(r is not None and r[0][0, 0] == 10 for r in res), "all 4 got the result")
        check(wall < 0.5, f"wall {wall:.2f} s (one 0.3 s inference, not four)")
        res[0][0][0, 0] = -1
        check(res[1][0][0, 0] == 10, "callers get their own copies")

        depth._cache.clear(); calls.clear()
        run_threads(4, [b"image-a", b"image-bb"])
        check(len(calls) == 2, f"4 calls on 2 different images -> {len(calls)} inferences")

        depth._cache.clear(); calls.clear(); fail["left"] = 1
        res, errs = run_threads(2, [b"flaky"])
        check(sum(e is not None for e in errs) == 1 and sum(r is not None for r in res) == 1,
              f"first run fails: one caller gets the error, the other retries and succeeds ({len(calls)} runs)")
        check(not getattr(depth, "_inflight", {}), f"no in-flight entries left: {list(getattr(depth, '_inflight', {}))}")
    finally:
        depth._infer_depth_uncached = real


def real_check() -> None:
    print("real Depth Pro")
    real = depth._infer_depth_uncached
    calls = []

    def counted(image_bytes):
        calls.append(1)
        return real(image_bytes)

    depth._infer_depth_uncached = counted
    try:
        depth._cache.clear()
        data = SAMPLE.read_bytes()
        depth.infer_depth(data + b"\0")  # warm the model and this shape; trailing byte = another cache key
        calls.clear()
        t0 = time.perf_counter()
        res, errs = run_threads(2, [data])
        wall = time.perf_counter() - t0
        check(not any(errs), f"no errors: {errs}")
        check(len(calls) == 1, f"2 concurrent calls on {SAMPLE.name} -> {len(calls)} Depth Pro run(s), {wall:.2f} s wall")
        check(np.array_equal(res[0][0], res[1][0]), "both callers got the same depth map")
    finally:
        depth._infer_depth_uncached = real


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--real", action="store_true", help="also run Depth Pro on a sample from 2 threads")
    args = ap.parse_args()
    fake_checks()
    if args.real:
        real_check()
    print(f"{len(failures)} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
