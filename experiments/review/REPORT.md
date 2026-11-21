# Instant post-capture review: pipeline comparison (2026-11-21)

**Test set:** 13 shots in `set/` with phone-style contexts in `set/cases.json` (built by `make_set.py`).
Eight are the samples. Five are derived: heads cut at 2x, a coast rolled 6° with no people, a dark centred portrait at EV −1.7, food cut at the bottom, and a sign cut on the right.

**How it was run:** two runs through `bench.py`: run 1 with prompt v1, run 2 with prompt v2 and selfies mirrored. Everything is logged to `results.jsonl`; 148 calls in total.

**Scoring:** every output scored 1–5 by eye against the image and its context (`grades.json`). Latency is from the Mac, streamed; "first" is when the first suggestion object is complete.

| Pipeline | n | First p50/p95 | Total p50/p95 | Quality run1/run2 | Verdict right |
|---|---|---|---|---|---|
| Decision 1 alone (image low, 4 questions, calibrated) | 26 | 0.59/1.06 s | same | 2.8/2.8 | 12/13 |
| hydrogen, thinking low, media LOW | 26 | 5.06/6.64 s | 5.24/6.93 s | 4.6/4.7 | 10, 13/13 |
| hydrogen, media MEDIUM | 13 | 4.44/5.99 s | 4.75/6.28 s | 4.5 | 12/13 |
| neon, low, LOW (2 calls took over 10 s) | 11 | 9.07/9.57 s | 9.40/10.2 s | 4.5 | 10/11 |
| 3.8-flash, low (rejects minimal) | 26 | 2.66/5.52 s | 3.37/6.15 s | 3.5/3.7 | 10, 9/13 |
| 3.5-flash, minimal | 6 | 1.55/2.05 s | 1.74/2.27 s | 2.5 | 5/6 |
| 3.5-flash-lite, minimal, MEDIUM | 26 | 1.05/1.36 s | 1.15/1.48 s | 3.4/2.9 | 11, 10/13 |
| **Decision 1 ∥ Flash-Lite** | 26 | verdict 0.59 s, wording 1.05/1.36 s | 1.15/1.48 s | Flash-Lite's | 13, 12/13 |
| final `review.py`, prompt v3, real parallel run, 4 hardest shots | 4 | verdict 0.38–0.48 s, wording 0.84–0.94 s | 0.92–1.07 s | 3.75 (v1 3.0, v2 1.5 on the same 4) | 4/4 |

## Findings
- **Hydrogen is the best coach but can't reach 2.5 s.** It caught the walker in the tunnel, the 3° horizons, the clipped shoes and the EV −1.7. At `low` it still spends 530–610 thought tokens. `thinkingBudget: 128` is ignored (762 thought tokens, 7.6 s). MEDIUM is no better than LOW.
- **Neon** matches Hydrogen's quality at twice the time.
- **3.8 Flash** has a long tail and suggests "rotate counter-clockwise" on level horizons.
- **Decision 1's raw verdict says keeper on 10 of 13 shots.** Requiring keeper ≥ 0.6 and retake ≥ 0.45 fixes that. It names a move with p ≥ 0.25 on only 5/13 shots, 4 of them right. Its horizon and rotate answers were wrong on every tilted shot, so the app never shows a rotation from it.
- **v2 hurt Flash-Lite.** Its checklist and a `seen` field filled before the suggestions made it invent problems and reverse directions. v3 drops both and adds a which-way table (cut at the top → tilt up or step back, never down) plus "only name problems you can clearly see".
- **Selfies must be reviewed mirrored.** iOS saves them unmirrored but they were framed on a mirrored preview, so left/right and clockwise flip.
- **Implicit caching never hit:** prompts are 1.4–1.9k tokens and `cached` was 0.

## Recommendation: Decision 1 ∥ gemini-3.5-flash-lite, streamed (`review.py`)

At the shutter, the phone posts a 1024 px JPEG and its context to Core (proposed `POST /api/review`, answered as SSE). Core mirrors selfies and starts both calls at once. Times as the phone sees them (plus ~0.1–0.2 s of upload):

1. **~0.6 s `decision`:** verdict chip, plus one templated card with an arrow when Decision 1 is confident.
2. **~1.1 s `suggestion`** (p95 ~1.6 s): card 1 with the specific wording. Speak `speak` with on-device AVSpeechSynthesizer, because `/api/cam/say` takes ~2.3 s.
3. **~1.2 s `final`:** cards 2–3 and the "what's working" line. The verdict becomes retake if Decision 1 says retake; otherwise the Flash verdict stands. If Flash fails or passes its 4 s timeout, the Decision 1 card stays.
4. **Optional ~5 s `refined`:** with `refine_model="gemini-4-hydrogen"` (media LOW), swap a card only if `changed`; also save it as the shot's `suggest`.

**Parameters**
- Flash-Lite: thinkingLevel minimal, mediaResolution MEDIUM, temperature 0.4, responseSchema, `streamGenerateContent?alt=sse`.
- Decision 1: one request with 4 questions (verdict, next move from an 18-option menu, size, working), image low.

**Prompt and schema:** `review.SYSTEM` (static) first, then the image, then `context_text(ctx)` last. The context covers intent, subject, keep, scene, heard, coach and settings. `review.SCHEMA`:
`{verdict: keeper|almost|retake, suggestions[1..3]: {action ≤8w, why ≤10w, kind: move|angle|light|timing|setting|subject, direction: left|right|up|down|closer|back|rotate_left|rotate_right|none, priority}, working ≤10w}`.
`normalize()` enforces the word caps and enums.

**Cost:** about $0.0009 per shot, or about $0.009 with the refine.

**Caveat:** Flash-Lite still misses subtle issues (passers-by, small tilts). v3 was checked on only 4 shots; before shipping, re-run `bench.py` on all 13 plus ~10 real phone shots.

Code: `review.py` (`review_shot`, `review_shot_stream`), `bench.py`, `validate.py`, `make_set.py`.
