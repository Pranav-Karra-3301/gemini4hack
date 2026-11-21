"""End-to-end check of the recommended pipeline (review_shot_stream: Decision 1 || Flash-Lite,
truly in parallel) on a few cases; logs every event with its time and appends the final
reviews to results.jsonl as config "final" (run 3).

    cd server && set -a; . ../.env; set +a
    uv run --no-sync python ../experiments/review/validate.py d09_heads_cut,s08_road_hug
"""
import asyncio, json, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import review  # noqa: E402


async def main(ids: list[str]):
    cases = {c["id"]: c for c in json.loads((HERE / "set/cases.json").read_text())}
    await review.http().get("https://generativelanguage.googleapis.com/", timeout=5)  # warm TLS
    for cid in ids:
        c = cases[cid]
        img = (HERE / "set" / f"{cid}.jpg").read_bytes()  # the 1536 px shot, as Core stores it
        print(f"## {cid}")
        async for ev in review.review_shot_stream(img, c["context"]):
            if ev["event"] == "final":
                print(f"  final @{ev['timing']['final_ms']} ms {json.dumps(ev['timing'])} {ev.get('errors', '')}")
                print(f"    {ev['verdict']} | " + " | ".join(f"{s['action']} ({s['why']}) [{s['kind']}/{s['direction']}]" for s in ev["suggestions"]) + f" || {ev['working']}")
                print(f"    speak: {ev['speak']}")
                with (HERE / "results.jsonl").open("a") as f:
                    f.write(json.dumps({"config": "final", "case": cid, "run": 3, "pv": 3, "ok": True,
                                        "ms": ev["timing"]["final_ms"], "first_ms": ev["timing"]["first_ms"],
                                        "decision_ms": ev["timing"].get("decision_ms"), "review": {k: ev[k] for k in ("verdict", "suggestions", "working")},
                                        "t": time.time()}) + "\n")
            elif ev["event"] == "decision":
                print(f"  decision @{ev['ms']} ms: {ev['verdict']} {[s['action'] for s in ev['suggestions']]}")
            elif ev["event"] == "suggestion":
                print(f"  first suggestion @{ev['ms']} ms: {ev['suggestion']['action']}")
    await review.aclose()

asyncio.run(main(sys.argv[1].split(",")))
