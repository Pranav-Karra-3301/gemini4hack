# Coach Core API (v1)

The Mac runs **Coach Core** (the FastAPI server in `server/`, port 8787): Depth Pro, SAM 2.1,
SHARP, the shot library, and every Gemini call that needs the API key. The **iPhone app**
(CoachCam) shoots with live coaching and syncs shots to the Mac. The **Mac app** (CoachStudio)
runs Core, shows the library, and edits shots with sliders that Gemini can drive. The web pages
(`web/`) are demos on the same API. Older endpoint specs: `CONTRACT.md` (depth, regions, masks,
score, splat, reframe) and `CAM_CONTRACT.md` (web camera engines). This file covers everything
new and is the source of truth for the apps. System overview, data flows, latency/cost budget
and security model: `docs/ARCHITECTURE.md`.

Errors: non-2xx with JSON `{"error": "..."}`. Times are ISO 8601 UTC. All JSON is UTF-8.

## 1. Reaching Core

| Client | How | Auth |
|---|---|---|
| Mac app, browser on the Mac | `http://127.0.0.1:8787` | none (loopback) |
| iPhone on the same Wi-Fi | Bonjour `_coachcore._tcp` (TXT `v=1`), or the pairing QR | `Authorization: Bearer <token>` |
| Anything through `phone.sh`'s Cloudflare tunnel | the printed URL | cookie `coach_k=<token>` (or Bearer) |

- LAN mode: Core binds `0.0.0.0` when started with `COACH_LAN=1` (the Mac app and `./dev.sh lan`
  do this) and then advertises Bonjour via `dns-sd -R "Coach Core (<hostname>)" _coachcore._tcp local 8787 v=1`
  for as long as it runs.
- The token is `server/.coach_token` (created on first LAN start, 32 hex chars, chmod 600) or env
  `COACH_TOKEN`; it is re-read per request, so replacing the file rotates it without a restart.
  Every request (any path, HTTP and WebSocket) needs it unless it comes from the Mac itself:
  straight from loopback, or through the local Vite proxy (loopback peer, every
  `x-forwarded-for` hop loopback). A non-loopback peer, a LAN client through the Vite proxy
  (including the Mac's own browser on Vite's LAN address), or any request carrying
  `cf-connecting-ip` or `forwarded` (the tunnel) must send it. Missing or wrong → 401 `{"error": ...}`, or WebSocket
  close 1008.
- `GET /api/pair` (loopback only; 403 otherwise, 409 if LAN mode is off, 503 if no token or LAN
  address yet): `{"host": "192.168.1.20", "port": 8787, "token": "...", "name": "Coach Core (<hostname>)",
  "url": "coach://pair?host=192.168.1.20&port=8787&token=..."}`. The Mac app shows `url` as a QR
  code; the iPhone scans it (or the user types host + token). Env `COACH_LAN_HOST` overrides `host`.
- `GET /api/health`: `{"ok": true, "version": 1, "lan": true, "port": 8787, "models": {"depth":
  "warm"|"cold", "segment": "warm"|"cold"|"error", "live": "gemini-3.8-live"}}`.

## 2. Live coaching: ephemeral tokens (no media goes through Core)

Clients talk to the Gemini Live API **directly** with a short-lived token that Core mints with
the whole session setup locked inside it (model, system prompt, tools, transcription, VAD,
media resolution, compression, resumption). The API key never leaves the Mac, and audio/video
never take the extra hop.

`POST /api/live/token` JSON:
```json
{"mode": "camera", "voice": true, "facing": "back", "shot_id": null, "context": "",
 "values": null, "subject": null}
```
- `mode`: `camera` (iPhone shooting) or `edit` (Mac editing a shot; needs `shot_id`; Core bakes
  the shot's regions, scores, depth summary, suggested plan and current slider values into the
  system prompt). `values`/`subject` (edit mode, optional) are the editor's current state; they
  default to the shot's saved edit.
- Response:
```json
{"token": "auth_tokens/...", "model": "gemini-3.8-live",
 "ws_url": "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained?access_token=...",
 "setup": {"sessionResumption": {}}, "mode": "camera",
 "expire_time": "...", "new_session_expire_time": "...", "ms": 150}
```
- Verified 2026-11-21: mint `POST https://generativelanguage.googleapis.com/v1beta/auth_tokens`
  (header `x-goog-api-key`) with body `{"uses": 1, "expireTime", "newSessionExpireTime",
  "bidiGenerateContentSetup": {"model": "models/gemini-3.8-live", "generationConfig": {...},
  "systemInstruction": ..., "tools": [...], ...}, "fieldMask": "model,generationConfig,..."}` →
  `{"name": "auth_tokens/..."}` in 0.1–0.27 s. `expireTime` is now + 30 min (env
  `LIVE_TOKEN_TTL_MIN`), `newSessionExpireTime` now + 120 s (env `LIVE_TOKEN_START_S`): open the
  first session within 2 minutes of minting. (The docs' `liveConnectConstraints` is the SDK name;
  REST wants `bidiGenerateContentSetup`.) `fieldMask` lists every setup field except
  `sessionResumption` (`live_setup.token_constraints`): without a mask the server ignores the
  client's setup message, so a resumption handle is dropped and the reconnect counts as a second
  use (closed with 1011 "Token has been used too many times").
  Client connects to `ws_url`, sends `{"setup": <response.setup>}` = `{"setup":
  {"sessionResumption": {}}}` (without it no resumption handles arrive), gets `setupComplete`
  (~0.3 s), then streams. The first tool call came back in 0.4–0.8 s.
- Client → Gemini: `realtimeInput.audio` (PCM16 mono 16 kHz, base64, `audio/pcm;rate=16000`,
  20–40 ms chunks per the Live best practices; CoachLive sends 40 ms), `realtimeInput.video`
  (JPEG ≤768 px long side, at most 1 fps, and only when the frame changed), `toolResponse`.
  Gemini → client: `serverContent` (24 kHz PCM16 audio, transcriptions, `interrupted`,
  `turnComplete`), `toolCall`, `toolCallCancellation`, `sessionResumptionUpdate`, `goAway`.
- Cost: Live bills every turn (each utterance, `[tick]` text or `WHEN_IDLE` tool answer) for the
  whole context window. A frame costs ~165 tokens at any size from 384 to 1024 px, so 1 fps adds
  ~9.9k tokens/min. The window is capped at 16k tokens and slides back to 8k
  (`LIVE_CWC_TRIGGER`/`LIVE_CWC_TARGET`), so check-ins every 4 s bill ~180k input tokens/min.
  Send frames only when the picture changed and keep check-ins rare. Measurements:
  `docs/BEST_PRACTICES.md` §3.
- Reconnect: keep the last `sessionResumptionUpdate.newHandle`; on `goAway` or a drop, reconnect
  to the same `ws_url` (valid until `expire_time`, even with `uses: 1`) and send
  `{"setup": {"sessionResumption": {"handle": "<handle>"}}}`: the conversation continues
  (setupComplete ~0.3 s; verified by `server/checks/live_token_check.py`). A fresh session on a
  used token is rejected, so after `expire_time` (or if resuming fails) mint a new token; a new
  token resumes an old handle too.
- Tool responses: `{"toolResponse": {"functionResponses": [{"id", "name", "response":
  {"ok": true, "applied": {...}}, "scheduling": "SILENT"}]}}`. Use `WHEN_IDLE` when the coach
  should comment on the result.
- `WS /api/live` (the existing proxy, `CAM_CONTRACT.md`) stays as a fallback for browsers and for
  networks that can't reach Google directly. It uses the same setup builder.

### Camera-mode tools (`mode: camera`)

| Tool | Args | Client does |
|---|---|---|
| `guide` | `direction` left/right/up/down/closer/back/rotate_left/rotate_right/hold, `strength` small/medium/large | big arrow in the viewfinder |
| `set_camera` | any of: `mode` photo/portrait/night/macro; `lens` ultrawide/wide/tele; `zoom` 0.5–10 (device zoom factor); `iso` number or "auto"; `shutter` seconds (e.g. 0.008) or "auto"; `ev` −3..3; `focus` 0..1 lens position or "auto"; `focus_x`,`focus_y` 0..1 (point of interest, raw frame); `wb_kelvin` 2500–9000 or "auto"; `tint` −50..50; `flash` off/on/auto; `torch` bool; `why` ≤8 words | applies with AVFoundation, ANIMATES the matching dial to the new value, answers with the clamped values it actually applied |
| `set_intent` | `intent` portrait/group/landscape/object/food/street/document/other, `subject` ≤4 words | intent chip |
| `user_reaction` | `reaction` pleased/disappointed/neutral, `heard` | reaction wash |
| `shot_ready` | `ready` bool | shutter glow |
| `take_photo` | `reason` | captures and syncs to the Mac |

Coaching rules baked into the prompt: directions are camera moves in the raw (unmirrored) frame;
keep every person fully in frame; reveal more of the place-defining scenery; in a selfie, moves
are arm moves; speak rarely and briefly; react to the user's voice (sighs, "oh that's good");
change settings yourself and say why in a few words.

### Edit-mode tools (`mode: edit`)

| Tool | Args | Client does |
|---|---|---|
| `edit_step` | `slider` (a slider name, §4), `value`, `why` ≤12 words, `region` (region id or null) | one step of a guided edit: animates that slider to `value` (~600 ms), shows `why` as the caption, highlights `region`; answers when the animation finishes |
| `set_sliders` | `values` {slider: value, ...}, `why` | applies several at once (animated) |
| `select_region` | `region` id or null | highlights a region (mask) |
| `compare` | `show` before/after | before/after toggle |
| `reset` | none | back to the original |
| `save_edit` | none | `PUT /api/shots/{id}/edit` |

Edit-mode prompt: Gemini is a photo editor teaching as it goes. It explains each move in one
short sentence, edits in a sensible order (white balance and exposure, then tone, then color,
then local, then vignette and crop), and takes requests like "make it warmer" or "make them pop".

## 3. Shot library and sync

Storage: `server/library/<id>/` (gitignored) with `original.jpg` (as uploaded, up to 4032 px),
`image.jpg` (EXIF-upright, long side 1536: what every model sees), `thumb.jpg` (400 px),
`depth.png`, `regions.json`, `masks/<rid>.png`, `score.json`, `suggest.json`, `splat.spz`,
`shot.json` (the record). `id` is time-sortable: `YYYYMMDD-HHMMSS-xxxx`.

`POST /api/shots` multipart: `image` (JPEG), `meta` (JSON string, all optional):
```json
{"source": "iphone", "device": "iPhone 17 Pro", "taken_at": "...", "iso": 64, "shutter": 0.004,
 "ev": 0.0, "wb_kelvin": 5200, "tint": 0, "lens": "wide", "zoom": 1.0, "mode": "portrait",
 "focus": 0.42, "facing": "back", "intent": "portrait", "subject": "friend by the window",
 "keep": ["friend"], "scene": "", "coach": ["Turn her toward the window"]}
```
→ 201 with the shot record (~0.1 s). Errors: 400 (no or empty `image`, bad `meta`; `meta` must be
a JSON object under 16 KB), 413 (over 60 MB). Core then processes in the background, newest shot
first, in three phases: (depth ∥ score ∥ regions) → masks → suggest. Score and regions don't need
depth, so they overlap Depth Pro. GPU stages (Depth Pro, SAM, SHARP) share one lock. Unfinished
stages resume after a restart. SHARP splats only on request: `POST /api/shots/{id}/splat` → 202
with the record (heavy: 7–12 s and ~9 GB, one at a time; already done → 200).

Only one Core process processes a library (`flock` on `library/.lock`, env `COACH_LIBRARY` moves
the root). A second process serves the same library read-only: uploads are stored but not
processed (`hello.processing: false`).

Shot record (`GET /api/shots/{id}`):
```json
{"id": "20261121-143005-a1b2", "created": "...", "updated": "...", "width": 4032, "height": 3024,
 "meta": {...},
 "assets": {
   "image":   {"status": "done", "url": "/api/shots/<id>/image.jpg"},
   "original":{"status": "done", "url": "/api/shots/<id>/original.jpg"},
   "thumb":   {"status": "done", "url": "/api/shots/<id>/thumb.jpg"},
   "depth":   {"status": "done", "url": "/api/shots/<id>/depth.png", "ms": 560,
               "meta": {"width": 512, "height": 384, "p02": 0.8, "p98": 14.2, "median": 2.4,
                        "far_frac": 0.12, "focal_px": 1100.0, "focal_source": "exif", "units": "mm"}},
   "regions": {"status": "done", "url": "/api/shots/<id>/regions.json", "count": 3, "ms": 9600},
   "masks":   {"status": "done", "urls": {"r1": "/api/shots/<id>/masks/r1.png"},
               "meta": {"r1": {"area": 0.18, "source": "sam2.1+depth", "width": 1024, "height": 768, "depth_m": 2.1}},
               "model": "facebook/sam2.1-hiera-large", "ms": 1600},
   "score":   {"status": "running"},
   "suggest": {"status": "pending"},
   "splat":   {"status": "none"}
 },
 "edit": null}
```
`status`: none | pending | running | done | error (with `"error": "..."`). Every `done` asset also
carries `ms` (stage wall time). Stage extras: `score.summary` `{lighting: 1–5, composition: 1–5}`,
`regions.count`, `masks.meta` (per region: area fraction, mask source `sam2.1`, `sam2.1+depth`,
`box+depth`, `box` or `empty`, size, median depth in metres), `masks.model`, `suggest.summary`. Other modules add `review`, `looks` and `semantic`
assets (§5–§7). `depth.png` is a 16-bit grayscale PNG of depth in millimetres (0 = unknown, capped
at 65535); `depth.meta.median` is the median depth in metres, `far_frac` the share of pixels at
the cap. `regions.json`, `score.json` use the `/api/regions` and `/api/score` shapes. Asset files
are served at `GET /api/shots/{id}/<file>` and `/masks/<rid>.png` (404 until ready).

- `GET /api/shots?limit=50&before=<id>` → `{"shots": [record, ...]}`, newest first (`limit`
  1–500).
- `DELETE /api/shots/{id}` → 204.
- `PUT /api/shots/{id}/edit` JSON recipe (§4) → the record. Core clamps `values` to §4, checks
  `subject` is a region id or null, clamps `crop` (x, y, w, h in 0..1, `angle` ±45°) and adds
  `"updated"`. 400 on a bad recipe or an unknown slider. `GET` returns it inside the record as
  `edit`. As built today it stores only `version`, `values`, `subject` and `crop` (§8).
- `GET /api/events` → Server-Sent Events, starting with `retry: 2000` and `event: hello` (once)
  `{"version": 1, "time", "shots": <count>, "newest": <id>|null, "processing": bool}`, then
  `event: shot` with `data: <shot record JSON>` whenever a shot is created, an asset changes
  status, or an edit is saved, and `event: shot_deleted` with `data: {"id": ...}`. A comment
  line `: ping` every 15 s. Clients reload the list on `hello` (it follows every reconnect).

## 4. Edits

The recipe is portable: it is meant to render the same on the iPhone and the Mac through one Core
Image pipeline (`CoachEdit` in `apple/CoachKit`, which builds for both; today only CoachStudio
uses it). Sliders (name: range, default, what it does):

| slider | range | default | meaning |
|---|---|---|---|
| `exposure` | −3..3 EV | 0 | overall brightness |
| `contrast` | −100..100 | 0 | global contrast |
| `highlights` | −100..100 | 0 | bright tones |
| `shadows` | −100..100 | 0 | dark tones |
| `whites` | −100..100 | 0 | white point |
| `blacks` | −100..100 | 0 | black point |
| `warmth` | −100..100 | 0 | white balance, cooler ↔ warmer |
| `tint` | −100..100 | 0 | green ↔ magenta |
| `vibrance` | −100..100 | 0 | muted colors only |
| `saturation` | −100..100 | 0 | all colors |
| `clarity` | −100..100 | 0 | local contrast (midtone detail) |
| `vignette` | −100..100 | 0 | negative darkens the edges |
| `subject_light` | −100..100 | 0 | brightness inside the subject mask |
| `background_light` | −100..100 | 0 | brightness outside the subject mask |
| `depth_blur` | 0..100 | 0 | lens blur from the depth map, focused at `focus_depth` |
| `focus_depth` | meters or null | null | null = the subject's median depth |

Recipe:
```json
{"version": 1, "values": {"exposure": 0.3, "warmth": 12, "depth_blur": 35},
 "subject": "r1", "crop": {"x": 0, "y": 0, "w": 1, "h": 1, "angle": 0}}
```
Missing values mean default. `subject` is the region whose mask drives `subject_light`,
`background_light` and the default `focus_depth`.

`POST /api/shots/{id}/edit/suggest` JSON `{"values": {...current}, "goal": "optional user words"}`
→
```json
{"summary": "Warm it up and let the subject glow",
 "steps": [{"slider": "exposure", "value": 0.3, "why": "Lift the underexposed faces", "region": null},
           {"slider": "warmth", "value": 15, "why": "Bring back the sunset color", "region": null},
           {"slider": "subject_light", "value": 20, "why": "Make the group the brightest thing", "region": "r1"}],
 "values": {"exposure": 0.3, "warmth": 15, "subject_light": 20}, "subject": "r1",
 "model": "gemini-4-hydrogen", "ms": 4200, "goal": null,
 "usage": {"prompt": 1650, "cached": 0, "output": 310, "thoughts": 420}, "cached": false}
```
3–8 steps, in editing order. Core runs this once automatically after masks (saved as
`suggest.json`) and on demand with a `goal` or current `values`. A request with neither returns
the saved `suggest.json` with `"cached": true` (~5 ms); identical requests share one Gemini call
and are cached in memory (`"cached": true`). Fresh calls take 4.7–9 s (env `SUGGEST_MODEL`,
default gemini-4-hydrogen). 400 on bad `values`, 502 if Gemini fails.

## 5. Instant review (post-capture)

`POST /api/review` multipart: `image` (JPEG, long side ≤1024; the phone sends it right after the
shutter, before the full upload) and `context` (JSON string: intent, subject, keep, scene, heard,
coach lines, capture settings, `facing`, optional `shot_id`). Response: `text/event-stream`:
- `event: decision` (~0.6 s): `{"verdict": "keeper|almost|retake", "p": {...}, "card": {...}|null}`
  from Gemini Decision 1 (keeper ≥ 0.6, retake ≥ 0.45 thresholds; rotation advice is never shown
  from Decision 1).
- `event: suggestion` (~1.1 s): one card `{action ≤8 words, why ≤10 words, kind
  move|angle|light|timing|setting|subject, direction left|right|up|down|closer|back|rotate_left|rotate_right|none,
  priority, speak}` (gemini-3.5-flash-lite, streamed).
- `event: final` (~1.2 s): `{"verdict", "suggestions": [1..3 cards], "working": "≤10 words"}`.
- `event: refined` (optional, ~5 s, gemini-4-hydrogen): same shape plus `changed: bool`; only
  replace cards when `changed`.
- `event: done`.
Selfies (`facing: front`) are mirrored before review so left/right match what the user saw. When
`shot_id` is given (or, once wired (§8), the full upload arrives later with the same `review_id`), the final review
is saved as `review.json` in the shot and appears as `assets.review`. Speak `speak` on-device
(AVSpeechSynthesizer); it's faster than `/api/cam/say`. Details: experiments/review/REPORT.md.

## 6. Looks (film emulation designed per photo)

`POST /api/shots/{id}/looks` JSON `{"variant": "fit"|"bold", "goal": "optional"}` →
```json
{"id": "look-fit-1", "name": "Coastal Gold", "evokes": "Kodak Gold 200",
 "rationale": "Warm the late sun, soften the highlight roll-off",
 "lut": "/api/shots/<id>/looks/look-fit-1/lut.cube", "size": 33,
 "effects": {"grain": {"amount": 0.18, "size": 1.2, "roughness": 0.5},
             "halation": {"amount": 0.2, "threshold": 0.82, "radius": 0.012, "tint": [1, 0.45, 0.25]},
             "bloom": {"amount": 0.1, "radius": 0.02}, "vignette": {"amount": -0.15}},
 "spec": {...}, "model": "gemini-4-hydrogen", "ms": 9900}
```
`GET /api/shots/{id}/looks` lists them. The "fit" look is meant to run automatically after `suggest`, in
the background (Hydrogen, ~10 s; not wired yet, §8); "bold" or a `goal` is on demand (Neon, ~19 s). The LUT is a 33³
`.cube` (sRGB in/out). Recipe gains `"look": {"id": "look-fit-1", "strength": 0.6}`, applied after
the global sliders and before vignette, depth blur and grain. Details: experiments/film/REPORT.md.

## 7. Local layers (Gemini masks)

Implemented in `server/semantic.py` (check: `server/checks/semantic_check.py`); research in
experiments/masks/REPORT.md. Gemini (gemini-4-hydrogen) names the edit targets with one tight box
and 2–3 points each, SAM 2.1 cuts them from box + points together, Depth Pro gives the sky, and a
guided filter snaps every edge to the photo. Depth also cuts leaks across depth steps (the grass
in front of the sea).

### Semantic masks

Mask names: unions `people`, `faces`, `sky`, `water`, `foliage`, `ground`, `buildings`, `objects`,
`distraction` (only those found), `subject` (Gemini's subject items, else the people) and
`background` (1 − subject; its soft edge follows the depth step), plus one mask per detected item
`t1`, `t2`, …. Sky, water, foliage, ground and buildings are the exact complement of the people
matte where they meet. Masks are soft 8-bit grayscale PNGs over the whole image (long side 1024),
the `/api/masks` format.

`POST /api/shots/{id}/semantic` (optional JSON `{"labels": [...], "force": false}`; `?wait=false`
returns 202 with the record right away) computes and stores `library/<id>/semantic/semantic.json`
and `<name>.png`, and answers with `semantic.json` plus `"cached": bool`:
```json
{"version": 1, "created": "...",
 "masks": {"sky": {"url": "/api/shots/<id>/semantic/sky.png", "width": 1024, "height": 768,
                   "area": 0.31, "source": "union", "label": "sky", "kind": "sky", "ids": ["t5"]},
           "t1": {"url": "...", "area": 0.08, "source": "sam2.1", "label": "man in red shirt",
                  "kind": "person", "ids": ["t1"]}},
 "targets": [{"id": "t1", "label": "man in red shirt", "kind": "person",
              "box": {"x": 0.31, "y": 0.22, "w": 0.18, "h": 0.6},
              "box_2d": [220, 310, 820, 490], "points": [[400, 400]], "neg_points": []}],
 "subject": ["t1"], "labels": ["people", "faces", "sky", "water", "foliage", "ground", "distraction"],
 "model": "gemini-4-hydrogen", "segmenter": "facebook/sam2.1-hiera-large",
 "timing": {"gemini": 10500, "gpu_wait": 0, "depth": 0, "sam": 900, "refine": 800, "encode": 50}}
```
- `kind`: person, face, sky, water, foliage, ground, building, object, distraction for items; the
  union name for unions; `subject`/`background`. `source`: `sam2.1`, `sam2.1+depth` (sky from depth,
  or a leak cut at a depth step), `depth+box` (sky from depth alone), `box+depth` (SAM
  unavailable), `union`, `1-subject+depth`.
- `labels` (default above) are the words Gemini looks for; `box_2d`/`points` are Gemini's raw
  `[y, x]` 0–1000 prompts, `box` is normalized like `/api/regions`.
- Record: `assets.semantic = {"status", "url": ".../semantic/semantic.json", "urls": {name: png
  url}, "meta": {name: {kind, label, area}}, "subject": [...], "model", "ms"}`, broadcast on
  `/api/events` like every asset. `GET /api/shots/{id}/semantic/{semantic.json|<name>.png}`.
- The Gemini target call is the slow part (10–14 s); it is cached per image sha1 + labels (memory
  and `server/cache/semantic/`), so a recompute is ~1.6–3 s (SAM ~0.9 s under the shared GPU
  lock, CPU refinement ~0.8 s) and a stored result returns in ms. Core is meant to run it in the
  background after `masks` (not wired yet, §8); `edit/local` computes it first if it is missing (or waits for the running one).
- `POST /api/semantic-masks` multipart `image` (JPEG) + `labels` (optional JSON list of strings)
  → the same object without storage: `{"masks": {name: {"png": "data:image/png;base64,...",
  "width", "height", "area", "source", "label", "kind", "ids"}}, "targets", "subject", "labels",
  "model", "segmenter", "cached", "timing", "ms"}`.

### Local edit plan

`POST /api/shots/{id}/edit/local` JSON `{"goal": "make them pop", "values": {...current global},
"subject": "r1" (optional)}` →
```json
{"summary": "Brighten the couple, calm the background",
 "why": "A light warm base so the subject layer reads",
 "values": {"warmth": 8, "exposure": 0.1, "contrast": 8},
 "layers": [{"id": "l1", "target": "background",
             "mask": {"source": "background", "invert": false, "subtract": ["sky"], "feather": 30, "edge": "depth"},
             "values": {"exposure": -0.25, "saturation": -12}, "why": "Darken the busy street so they stand out"},
            {"id": "l2", "target": "the couple",
             "mask": {"source": "subject", "invert": false, "subtract": [], "feather": 5, "edge": "image"},
             "values": {"exposure": 0.35, "clarity": 15, "vibrance": 15}, "why": "Lift and sharpen the couple"}],
 "subject": "r1", "model": "gemini-4-hydrogen", "ms": 6000, "semantic_ms": 3, "cached": false}
```
- `values` is the complete new global slider set: the request's values with Gemini's changes
  applied (a slider Gemini does not mention keeps its value), clamped to §4.
- `layers`: 1–5, in application order; only mask names that exist for the shot; values clamped
  to §4 ranges; empty layers dropped. `subject` is the recipe's subject region (request, saved
  edit, else the default focus region), unchanged by the plan.
- Identical requests (same shot, masks, values, goal) are cached; 5–10 s otherwise.

### Recipe `layers`

The recipe (§4) gains `"layers": [layer, ...]` (at most 5):

| field | type | meaning |
|---|---|---|
| `id` | string `[A-Za-z0-9_-]{1,32}`, unique | `l1`, `l2`, … |
| `target` | string ≤60 | what the layer edits, for the UI |
| `mask.source` | mask name | a semantic mask (`assets.semantic.urls`) or a region id (`r1`, `assets.masks.urls`) |
| `mask.invert` | bool | use 1 − mask |
| `mask.subtract` | mask names, ≤4 | multiply by (1 − each), e.g. background minus sky |
| `mask.feather` | 0..100 | blur radius; 100 = 4% of the image's long side; 0 = the mask as is |
| `mask.edge` | `image` \| `depth` \| `none` | feather that stays crisp at photo edges (`image`) or depth steps (`depth`), or a plain blur (`none`) |
| `values` | §4 sliders `exposure`..`clarity` (no vignette, subject/background light, depth blur) | relative adjustments inside the mask; 0 = no change |
| `why` | string | one sentence for the UI |

Alpha = mask (inverted if `invert`) × Π(1 − subtract), then feathered. Render order: global
sliders (and `subject_light`/`background_light`), then each layer in order as
`out = out·(1 − α) + adjust(out, layer.values)·α`, then the look, vignette, depth blur and grain.
Validation for `PUT /api/shots/{id}/edit`: `semantic.clean_layers(layers)` (strict: 400 on a
malformed layer, unknown slider or more than 5 layers).

## 8. Other endpoints, and what is wired today

Also served by Core (shapes in `CONTRACT.md` and `CAM_CONTRACT.md`): `POST /api/depth`,
`/api/regions`, `/api/masks`, `/api/score` (stateless versions of the pipeline stages),
`/api/splat` and `/api/reframe` (3D page), `WS /api/live` (browser Live proxy, same setup builder
as §2), `POST /api/cam/decide`, `/api/cam/understand`, `/api/cam/say` (web camera engines).
`GET /api/stats` returns per-model and per-tag call counts, p50/p95 latency, tokens and estimated
cost since start (`DELETE /api/stats` resets them); every Gemini REST call goes through
`server/gemini.py`, which records it.

Status as of 2026-11-21 (check `server/shots.py` before relying on these):

| Spec | Built | Not wired yet |
|---|---|---|
| §5 review | `POST /api/review`; saved to the shot when the context has `shot_id` | the upload doesn't call `review.attach`, so a later upload with `review_id` doesn't claim the review; `refined` only with context `refine: true` or env `REVIEW_REFINE=1` |
| §6 looks | `POST`/`GET /looks`, LUT and preview routes; CoachModels/CoachEdit decode and render `look` | the pipeline doesn't call `looks.ensure_fit_look`, so no automatic "fit" look; `PUT edit` drops `look` |
| §7 layers | `/api/semantic-masks`, `/semantic`, `/edit/local`, `semantic.clean_layers` | the pipeline doesn't call `semantic.ensure_semantic`; `PUT edit` drops `layers` (no `clean_layers` validation yet); no Swift client or renderer for layers |
| apps | CoachCam: §1–§3 (pair, live token, upload). CoachStudio: §1–§4 | neither app calls §5–§7 yet |
