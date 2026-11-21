# Coach

A native iPhone camera whose Gemini Live coach turns the real manual dials while it talks, and a
Mac app that runs the heavy models (Depth Pro, SAM 2.1, SHARP) through **Coach Core** and edits
shots with sliders Gemini can drive and teach with.

- **Start here:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): components, data flows, latency
  and cost budget, security, how to run everything, known gaps.
- API: [`docs/CORE_API.md`](docs/CORE_API.md). Gemini usage and cost: [`docs/BEST_PRACTICES.md`](docs/BEST_PRACTICES.md).
- Apps: [`apple/CoachCam`](apple/CoachCam/README.md) (iPhone),
  [`apple/CoachStudio`](apple/CoachStudio/README.md) (Mac), shared package `apple/CoachKit`.
- Run: `./dev.sh` (this Mac), `./dev.sh lan` (pair an iPhone), `./phone.sh` (web camera over a tunnel).

## Web demo: lighting coach

Upload a photo. It appears flat, as points. Click it and it goes black, then pushes out along Z
from near to far as each depth arrives. The panel shows three coaching regions from Gemini 4
Argon (click a note to dim everything outside its box) and lighting/composition scores with
confidence, Decision-1 style.

```sh
./dev.sh          # API on :8787 + web on :5320 → open http://localhost:5320
```

Click a note to light only that object's points (from its mask); everything else goes dark.
Points sit at `D0·(d/P02)^g` along their camera rays (metric log depth), so deep scenes get more
relief; the footer's Depth slider sets `g` (saved), `?depth=` overrides it.

`?mock=1` runs the UI with no backend (and `&fail=depth,regions,score,masks` to test error states).

### Pieces

| Piece | What runs | Typical time |
|---|---|---|
| Depth (`server/depth.py`) | Apple Depth Pro 2 S, local on the Mac GPU (`mps/fp16`), returns a 512-px float32 map | ~0.2–0.5 s |
| Regions (`server/regions.py`) | `gemini-4-argon` via the Gemini API (OpenRouter fallback); boxes in Gemini's native `box_2d` 0–1000 format | 6–25 s, p50 9.5 s |
| Masks (`server/segment.py`) | SAM 2.1-large (MPS, fp16) prompted with each Argon box, trimmed by depth; a scattered group mask also takes the box's near depth layer | ~0.5–1.3 s |
| Scores (`server/decide.py`) | `gemini-decision-1` (Decisions API, both rubrics in one request), labels from `gemini-3.5-flash-lite`; OpenRouter emulation without a Gemini key | ~0.85 s |
| Web (`web/`) | Vite + three.js `Points` with a custom shader: flat print, reveal from black, orbit, in-shader box dim/outline | — |

API shapes are in `CONTRACT.md`. Keys live in `.env` (`GEMINI_API_KEY`, `OPENROUTER_API_KEY` for
fallbacks), never in the browser or the apps. A page load costs about $0.007 (one Argon call plus scoring).

Options (env): `REGIONS_MODEL`, `DECIDE_MODEL`, `DECIDE_LABEL_MODEL`, `DEPTH_PRECISION`, `DEPTH_DEVICE`.

### Checks

```sh
cd server
uv run python checks/depth_check.py   ../web/public/samples/img-1216.jpg   # → out/depth_*.png
uv run python checks/regions_check.py ../web/public/samples/img-1216.jpg   # → out/regions_*.jpg
uv run python checks/decide_check.py  ../web/public/samples/img-1216.jpg
```

Sample photos in `web/public/samples/` are from the wayback project.
Depth Pro 2 weights are under Apple's AMLR license (research use).

## Working in this repo

Read [CONTRIBUTING.md](CONTRIBUTING.md) before you contribute. The rules are the same for people and
agents: every task starts as a GitHub issue, all work happens in a worktree, and changes reach `main`
only through squash-merged PRs.

```sh
gh repo clone Pranav-Karra-3301/gemini4hack
cp .env.example .env    # then fill in the keys
```

Not in git: model weights (downloaded on first run), the SHARP `.spz` splats in `web/public/splats/`
(made by SHARP from the wayback checkout, see `docs/ARCHITECTURE.md` §5), and the generated Xcode projects (run `xcodegen generate`).
