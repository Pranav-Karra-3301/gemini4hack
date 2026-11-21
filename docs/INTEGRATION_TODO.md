# Integration hooks to wire once the build workflow releases shots.py

Collected from the parallel builders (2026-11-21).

## shots.py
- [ ] Public `set_asset(sid, name, entry)` (save + broadcast). review.py, looks.py and semantic.py
      call the private `shots._set` for now.
- [ ] `FILES`: add `review.json` (review.py patches it in at import time today).
- [ ] `create_shot`: call `review.attach(rec["id"], meta.get("review_id"))` so a review streamed
      before the full upload is saved into the shot.
- [ ] `_clean_recipe`: keep `look`, and keep `layers` via `semantic.clean_layers(body.get("layers"))`.
- [ ] Restart: re-queue a `semantic` asset left `running` (like the other stages).
- [ ] Pipeline: after `suggest`, `asyncio.create_task(looks.ensure_fit_look(sid))`; after
      `masks`, `semantic.ensure_semantic(sid)` (GPU-serialized).
- [x] Router order: specific routers before shots' catch-all `GET /api/shots/{sid}/{name}`
      (done in app.py).

## Apps
- [ ] CoachCam → v2 Camera design: CoachUI `InstrumentDrums`, `FocusRuler`, `CoachKeys`,
      `EdgeGlow`, `TapFocusMark`, `GrainOverlay` replace the first-pass dials/arrows.
- [ ] CoachCam: call `POST /api/review` (SSE) at the shutter; show verdict + cards; speak `speak`
      with AVSpeechSynthesizer; pass `review_id` in the shot upload meta.
- [ ] CoachStudio → v3 Pro design (Paper page "v3 · Studio (Mac) · Pro", design/mocks/studio-v3/).
- [ ] CoachStudio: looks browser (`/looks`), local layers (`/semantic`, `/edit/local`), review
      and coaching timeline in details.
- [ ] CoachEdit: `layers` rendering (after the looks change lands).
- [ ] Signing: `apple/Local.xcconfig` (DEVELOPMENT_TEAM) for device builds; install with
      `xcrun devicectl device install app --device <udid> <app>`.
