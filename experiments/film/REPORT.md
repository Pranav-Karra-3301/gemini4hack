# Film looks designed per photo (Gemini 4 Neon / Hydrogen), 2026-11-21

**Verdict:** ship approach A. The model returns a structured look spec, which compiles to a 33³ LUT
plus an effects file (grain, halation, bloom, vignette). Generate the "fit" look automatically with
Hydrogen, and "bold" (or a user goal) on demand with Neon. Don't ship B (model-written shaders).

Contact sheet: `out/contact.jpg` (original | generic Portra | fit | bold | shader).

| | A: spec → LUT + effects | B: model-written GLSL |
|---|---|---|
| Quality | 10/10 tasteful; natural skin; no banding; mean change 5–11/255 | mean change 15–47/255; hazy, bleached skies; the red shirt in img-1931 went magenta |
| Fits the photo better than a generic look | 5/5 (generic Portra greys out the hazy img-1408 and the harsh-sun img-1931) | mostly hazy |
| Reliability | 40/40 valid (the compiler clamps everything) | 7/10 compile first time, 10/10 after ≤1 repair (all failures: a blank line before `#version`) |
| Latency (median) | Neon 18.8 s (p90 26 s), Hydrogen 9.9 s; LUT build 0.08 s; render 1.2 s at 1024 px | 22–27 s per attempt + ~9 s browser check |
| Portable | same LUT in Core Image (mean Δ 0.45/255) and WebGL (≤1/255) | WebGL only |

Neon is not "~6 s" for this task: it writes ~1.9k thinking + output tokens per look. Spend: 63 calls.

## What made the looks fit
- v1 was timid, so "fit" looked the same as generic.
- v2 added a film-stock menu with when-to-use notes. Every fit turned into the same Kodak Gold house look: fit LUTs differed across photos by 6.3/255, about as much as generic ones did (6.5).
- v3 puts a `read` field first in the schema (light, palette, what the photo needs, stocks considered) and bans the house look. Fit looks now differ across photos by 10.0/255, and bold by 17.6. The stocks chosen were Gold, Portra twice and Ektar. Part of the Gold bias is the sample set (5 sunny California coast photos).

## Compiler guards
- Curves are monotonic; per-channel curves stay within ±0.06 of identity.
- The channel mixer can't tint grays, and casts on grays are bounded.
- Skin hue can move at most 10° and can't be pushed further outside 8–42°.
- Saturation spikes are capped, and blue/aqua hue shifts are limited to ±10°.
- An identity spec compiles to an exact identity LUT.

## Integration plan
- **Core:** `POST /api/shots/{id}/looks` `{variant: "fit"|"bold", goal?}` → `{id, name, rationale, evokes, spec, effects, lut: ".../lut.cube", model, ms}`. Run "fit" in the background after `suggest`.
- **Recipe:** `"look": {"id", "strength"}`, applied after the sliders and before vignette, depth blur and grain.
- **CoachEdit:**
  - Use `CIColorCubeWithColorSpace` (sRGB, 33); for strength, lerp the LUT with identity on the CPU.
  - Halation = `CIGaussianBlur` on highlights, tinted, then added.
  - Bloom = `CIBloom`; vignette = `CIVignetteEffect`; grain = `CIRandomGenerator` + soft-light blend.
- **Web:** an RGB32F `texImage3D`.

Caveats: these are visual judgements on 5 similar photos, with no user test yet. The Core Image effects still need a visual match against the numpy reference. The generic baseline used the v2 prompt.

Code: `film.py` (`design_look`, `compile_lut`, `render`; prompt `SYSTEM`/`VARIANTS`, schema
`LOOK_SCHEMA`), `run.py`, `shader_harness.js`, `ci_check.swift`, `lut_webgl.js`, `out/luts/`.
