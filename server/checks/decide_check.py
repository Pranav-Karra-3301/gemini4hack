"""Check decide.score_photo on sample images.

Usage: cd server && uv run --no-sync python checks/decide_check.py ../web/public/samples/img-1016.jpg ...
Each image costs 3 OpenRouter calls (lighting, composition, labels).
"""

import asyncio
import sys
from pathlib import Path

from dotenv import load_dotenv

SERVER = Path(__file__).resolve().parents[1]
load_dotenv(SERVER.parent / ".env")
sys.path.insert(0, str(SERVER))

import decide  # noqa: E402


def _dist(d: dict) -> str:
    cells = (f"{d[k]:.2f}" for k in decide.LEVELS)
    return " ".join(s[1:] if s.startswith("0") else s[:3] for s in cells)


async def main(paths: list[str]) -> int:
    if not paths:
        print(__doc__)
        return 2
    failed = 0
    print(f"{'image':<10} {'L':>4} {'Lconf':>5} {'C':>4} {'Cconf':>5} {'mass L/C':>9} {'ms':>6}  "
          f"{'L dist 1..5':<19} {'C dist 1..5':<19}")
    for p in paths:
        name = Path(p).stem
        try:
            res = await decide.score_photo(Path(p).read_bytes(), "image/jpeg")
        except Exception as exc:
            failed += 1
            print(f"{name:<10} ERROR {type(exc).__name__}: {exc}")
            continue
        L, C = res["scores"]["lighting"], res["scores"]["composition"]
        print(f"{name:<10} {L['score']:>4.2f} {L['confidence']:>5.2f} {C['score']:>4.2f} {C['confidence']:>5.2f} "
              f"{L['valid_mass']:>4.2f}/{C['valid_mass']:.2f} {res['ms']:>6}  {_dist(L['distribution']):<19} "
              f"{_dist(C['distribution']):<19}")
        print(f"{'':<10} L: {L['label']!r}\n{'':<10} C: {C['label']!r}")
        provider = res["provider"]
    if failed < len(paths):
        print(f"provider: {provider}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv[1:])))
