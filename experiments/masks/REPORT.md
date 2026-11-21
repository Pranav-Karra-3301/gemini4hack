# Gemini masks + local edits (2026-11-21)

**Winner: Gemini targets (box + points) → SAM 2.1 → depth/edge refinement.**
1. gemini-4-hydrogen returns one tight box and 2–3 points per target item.
2. SAM 2.1 segments each target from the box and points together.
3. Depth Pro supplies the sky; an edge filter snaps mask edges to the photo.

**Plans:** Hydrogen with 2–5 layers plus global values, one-line why each. ~52 Gemini calls used.

| Approach | Result | Latency |
|---|---|---|
| Gemini native PNG masks | fake 1×1 images (argon), empty strings (hydrogen), timeouts (neon) | argon 77 s, neon >150 s |
| Gemini polygons | coarse (neon) or garbled; hydrogen flipped x/y between calls | neon 58 s |
| Boxes → SAM | leaks: the bench counted as foliage on img-1408 | — |
| Points → SAM | missed a small face on img-1457 | — |
| **Box + points → SAM + depth/edge** | clean; no visible halos (zoom check on img-2178) | hydrogen targets ~14 s (12–17, one 28 s outlier; argon 16–20 s), SAM 0.9–1.9 s, edge 0.6–1.1 s |
| Plan (hydrogen / neon) | nearly the same plans | 5–9 s / 10–17 s, so use hydrogen |

Prompt v1 made edits too faint; v2 makes each goal readable at a glance; v3 stops it from warming
blue skies, which greyed them on img-1491.

## Method
- Sky = Depth Pro pixels at 1e6–2e7 m, limited to Gemini's sky box.
- Sky, water, foliage and ground masks grow 3 px, then multiply by (1 − people mask), so they meet the people exactly.
- Feather 100 = 4% of the long side, and stays crisp near real image or depth edges.

## Proposed recipe `layers` (CORE_API.md §7)
`{"id", "target", "mask": {"source", "invert", "subtract": [], "feather": 0-100, "edge": "image|depth|none"}, "values": {exposure..clarity}, "why"}`
- `mask.source`: a semantic mask (people, faces, sky, water, foliage, ground, distraction, subject, background), one detected item (`t3`), or a `/api/regions` id (`r1`).
- Layers apply in order after the global values, at most 5.
- New endpoint: `POST /api/semantic-masks` returns PNGs in the `/api/masks` format.

## Prompts (in local_edits.py)
- `TARGETS_PROMPT`/`TARGETS_SCHEMA`: one entry per item, plus the subject ids.
- `PLAN_SYSTEM`: global values first, then 2–5 layers (big areas → subject → faces → distraction).
  - Gives typical slider sizes and one-line recipes for golden hour, moody, pop, and clean and natural.
  - Guards: skin; no warming blue skies; darken a big bright foreground by only 0.2–0.5 EV.

## Examples
- `out/edit_img-2178_make-them-pop_hydrogen_v2.jpg`
- `out/edit_img-1408_moody_hydrogen_v2.jpg`
- `out/edit_img-1016_make-it-golden-hour_hydrogen_v2.jpg`
- `out/edit_img-1457_clean-and-natural_hydrogen_v2.jpg`
- Mask comparisons: `out/b_compare_*`; native-mask attempts: `out/a_native_*`.
- End to end: "warm the faces, cool the sky, darken the distracting sign" on img-1931 took ~30 s and looks right (`out/smoke_img-1931.jpg`).

## Caveats
- `render.py` only approximates Core Image.
- Face masks often include hair.
- The target call is the bottleneck (~1.5–1.9k output tokens), so run it in the background pipeline after upload, not on demand.
- `get_semantic_masks` is synchronous: run it in a worker thread like `segment_regions`.

Code: `local_edits.py` (`plan_local_edits`, `get_semantic_masks`), `render.py`, `common.py`,
`seg_native.py`, `seg_compare.py`, `plan_edits.py`, `zoom.py`, `smoke.py`.
