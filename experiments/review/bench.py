"""Latency/quality bench for the post-capture review pipelines.

    cd server && set -a; . ../.env; set +a
    uv run --no-sync python ../experiments/review/bench.py --run 1 --configs dec,h_low,...
    uv run --no-sync python ../experiments/review/bench.py --summary

Appends one line per call to results.jsonl and skips (config, case, run) triples already done,
so a rerun never re-spends calls. Hybrid timings are derived per case from the paired
Decision 1 and generated calls (they are independent requests that start together).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import review  # noqa: E402

RESULTS = HERE / "results.jsonl"
CONFIGS = {
    "dec": {"kind": "decision", "resolution": "low"},
    "h_low": {"kind": "gen", "model": "gemini-4-hydrogen", "media": "LOW"},
    "h_med": {"kind": "gen", "model": "gemini-4-hydrogen", "media": "MEDIUM"},
    "neon": {"kind": "gen", "model": "gemini-4-neon", "media": "LOW"},
    "f38": {"kind": "gen", "model": "gemini-3.8-flash", "media": "MEDIUM"},
    "f35": {"kind": "gen", "model": "gemini-3.5-flash", "media": "MEDIUM"},
    "lite": {"kind": "gen", "model": "gemini-3.5-flash-lite", "media": "MEDIUM"},
}


def load_cases() -> list[dict]:
    return json.loads((HERE / "set" / "cases.json").read_text())


def done() -> set:
    if not RESULTS.exists():
        return set()
    return {(r["config"], r["case"], r["run"]) for r in map(json.loads, RESULTS.read_text().splitlines()) if r.get("ok")}


async def one(cfg_name: str, case: dict, run: int, jpeg: bytes, sem: asyncio.Semaphore, calls: list) -> dict:
    cfg = CONFIGS[cfg_name]
    async with sem:
        rec = {"config": cfg_name, "case": case["id"], "run": run, "pv": 1 if run == 1 else 2, "t": time.time()}
        try:
            if cfg["kind"] == "decision":
                calls.append(1)
                res = await review.decide_review(jpeg, case["context"], resolution=cfg["resolution"], timeout=10)
                rec.update(ok=True, ms=res["ms"], first_ms=res["ms"], tokens=res["tokens"], review=res["review"],
                           answers={k: {"choice": v.get("choice"), "p": v.get("probabilities")} for k, v in res["answers"].items()})
            else:
                thinking = review.thinking_for(cfg["model"])
                try:
                    calls.append(1)
                    res = await review.generate_review(jpeg, case["context"], model=cfg["model"], thinking=thinking,
                                                       media_resolution=cfg["media"], timeout=30)
                except RuntimeError as exc:
                    if "HTTP 400" in str(exc) and thinking == "minimal":
                        rec["thinking_fallback"] = str(exc)[:160]
                        calls.append(1)
                        res = await review.generate_review(jpeg, case["context"], model=cfg["model"], thinking="low",
                                                           media_resolution=cfg["media"], timeout=30)
                    else:
                        raise
                rec.update(ok=True, ms=res["ms"], first_ms=res["first_ms"], usage=res["usage"], thinking=res["thinking"],
                           review=res["review"], raw=res["raw"])
        except Exception as exc:  # noqa: BLE001
            rec.update(ok=False, error=f"{type(exc).__name__}: {exc}"[:300])
        with RESULTS.open("a") as f:
            f.write(json.dumps(rec) + "\n")
        print(f"{cfg_name:6} {case['id']:20} run{run} {'ok ' if rec['ok'] else 'ERR'} "
              f"{rec.get('first_ms', '-')}/{rec.get('ms', '-')} ms {rec.get('error', '')[:120]}", flush=True)
        return rec


async def bench(run: int, configs: list[str], only: list[str] | None, limit: int, conc: int) -> None:
    cases = [c for c in load_cases() if not only or c["id"] in only][:limit or None]
    skip = done()
    # run 1 = prompt v1, raw frames; run 2+ = prompt v2 (checklist + `seen`), selfies mirrored
    jpegs = {c["id"]: review.prepare_jpeg((HERE / "set" / f"{c['id']}.jpg").read_bytes(),
                                          mirror=run >= 2 and review.needs_mirror(c["context"])) for c in cases}
    sem, calls = asyncio.Semaphore(conc), []
    # warm the connection pool so the first call doesn't pay the TLS handshake
    await review.http().get("https://generativelanguage.googleapis.com/", timeout=5)
    tasks = [one(cfg, c, run, jpegs[c["id"]], sem, calls)
             for c in cases for cfg in configs if (cfg, c["id"], run) not in skip]
    print(f"{len(tasks)} calls planned", flush=True)
    await asyncio.gather(*tasks)
    print(f"{len(calls)} Gemini calls made")
    await review.aclose()


def pct(v: list[float], q: float) -> float:
    v = sorted(v)
    if not v:
        return float("nan")
    k = (len(v) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def summary() -> None:
    rows = [json.loads(l) for l in RESULTS.read_text().splitlines()]
    ok = [r for r in rows if r.get("ok")]
    print(f"calls logged: {len(rows)} ({len(rows) - len(ok)} errors)")
    by: dict[str, list] = {}
    for r in ok:
        by.setdefault(r["config"], []).append(r)
    print(f"{'config':8} {'n':>3} {'first p50':>10} {'first p95':>10} {'total p50':>10} {'total p95':>10} {'in':>6} {'thought':>8}")
    for cfg, rs in by.items():
        f = [r["first_ms"] for r in rs]
        t = [r["ms"] for r in rs]
        tin = statistics.mean([(r.get("usage") or {}).get("in") or r.get("tokens") or 0 for r in rs])
        th = statistics.mean([(r.get("usage") or {}).get("thought") or 0 for r in rs])
        print(f"{cfg:8} {len(rs):>3} {pct(f, .5):>10.0f} {pct(f, .95):>10.0f} {pct(t, .5):>10.0f} {pct(t, .95):>10.0f} {tin:>6.0f} {th:>8.0f}")
    # hybrid: Decision 1 at its own latency, then the generated first suggestion; per (case, run)
    dec = {(r["case"], r["run"]): r for r in by.get("dec", [])}
    for gen in ("lite", "f38", "h_low"):
        pairs = [(dec[(r["case"], r["run"])], r) for r in by.get(gen, []) if (r["case"], r["run"]) in dec]
        if not pairs:
            continue
        first_paint = [d["ms"] for d, _ in pairs]
        wording = [g["first_ms"] for _, g in pairs]
        final = [max(d["ms"], g["ms"]) for d, g in pairs]
        print(f"hybrid dec+{gen:5} n={len(pairs)} verdict p50/p95 {pct(first_paint, .5):.0f}/{pct(first_paint, .95):.0f} "
              f"wording p50/p95 {pct(wording, .5):.0f}/{pct(wording, .95):.0f} final p50/p95 {pct(final, .5):.0f}/{pct(final, .95):.0f}")


def dump(configs: list[str], run: int) -> None:
    """Compact outputs per case for judging."""
    rows = [json.loads(l) for l in RESULTS.read_text().splitlines()]
    rows = [r for r in rows if r.get("ok") and r["run"] == run and r["config"] in configs]
    for cid in [c["id"] for c in load_cases()]:
        print(f"## {cid}")
        for cfg in configs:
            for r in rows:
                if r["case"] == cid and r["config"] == cfg:
                    rv = r["review"]
                    s = " | ".join(f"{x['action']} ({x['why']}) [{x['kind']}/{x['direction']}]" for x in rv["suggestions"])
                    print(f"  {cfg:6} {rv['verdict']:7} {s} || {rv['working']}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", type=int, default=1)
    ap.add_argument("--configs", default="dec,lite")
    ap.add_argument("--only", default="")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--conc", type=int, default=4)
    ap.add_argument("--summary", action="store_true")
    ap.add_argument("--dump", action="store_true")
    a = ap.parse_args()
    if a.summary:
        summary()
    elif a.dump:
        dump(a.configs.split(","), a.run)
    else:
        asyncio.run(bench(a.run, a.configs.split(","), [x for x in a.only.split(",") if x], a.limit, a.conc))
