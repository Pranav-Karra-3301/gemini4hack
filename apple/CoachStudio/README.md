# CoachStudio (Mac)

The Mac half of Coach. CoachStudio runs **Coach Core** (Depth Pro, SAM 2.1, SHARP and every
Gemini call that needs the key), shows the shot library as the iPhone syncs to it, and edits
shots with Paper-style sliders that Gemini can drive while it explains each move.
The API is described in `docs/CORE_API.md`. Shared code lives in `../CoachKit`
(CoachModels, CoachAPI, CoachLive, CoachEdit, CoachUI).

## Build and run

```sh
cd apple/CoachStudio
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project CoachStudio.xcodeproj -scheme CoachStudio -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Debug/CoachStudio.app
```

Requirements: macOS 15 or later. The app has no sandbox and the hardened runtime is off, because
it starts `uv`/Python as a child process. Its Info.plist includes the microphone, local-network
and Bonjour (`_coachcore._tcp`) usage strings, plus `NSAllowsLocalNetworking`. Ad-hoc signing is
enough on your own Mac. For a stable microphone permission, sign with your team.

## What it does

| Area | How |
|---|---|
| **Core** | On launch it calls `GET /api/health`. If Core answers, CoachStudio uses it and never stops it. Otherwise it starts `uv run --no-sync uvicorn app:app --host 0.0.0.0 --port 8787` in `server/` with `COACH_LAN=1` (and `COACH_PORT`), shows the output in **Core › Show Core Log** (⇧⌘L), and stops it when you quit: SIGINT, then SIGTERM, then SIGKILL. That also happens on `kill`/Ctrl-C. A status pill shows model warmth (`depth`/`segment` warm or cold) and the health round-trip time. |
| **Pairing** | ⇧⌘P (or the QR button) calls `GET /api/pair` and shows its `coach://pair?...` URL as a CoreImage QR code. If Core runs without LAN mode, the sheet explains why pairing won't work. |
| **Library** | `GET /api/shots`, kept live by `CoachClient.events()`. New iPhone shots slide in with an amber glow, and each one's stage dots (depth, score, regions, masks, suggest) fill in as Core works. Import with drag and drop (Finder files or image data) or ⌘O. Files are uploaded with `POST /api/shots`; HEIC and PNG are re-encoded to JPEG, and EXIF ISO, shutter, EV, device and date become `meta`. |
| **Editor** | The photo renders live through `CoachEdit.EditRenderer` into an `MTKView`, using `depth.png` and the subject's SAM mask. The right side holds CoachUI's `EditSliderPanel` with a subject picker. You also get region overlays (⌘R; Argon boxes, with the highlighted region's mask in amber), before/after (`\`), Save (⌘S, `PUT edit`) and Export JPEG (⌘E: full size from `original.jpg`). |
| **Coach me** (⌘K) | Plays Core's suggestion as a guided sequence. Each step glides its slider, highlights the slider and its region, and shows the "why" as a caption under the photo. You can step back and forth (⌘← / ⌘→), pause, replay, "Keep · Save" or "Undo all". With no goal on an untouched photo it uses the precomputed `suggest.json`, so it starts instantly. Type a goal ("moody", "make them pop") and it calls `POST edit/suggest` with the current values instead (about 5 s on gemini-4-hydrogen). |
| **Talk** (⌘T) | A Gemini Live session in edit mode. Core mints the ephemeral token with `mode: edit`, `shot_id` and the editor's current `values`/`subject`, so the shot's regions, scores, depth and plan are already in the prompt and no key lives in the app. Audio goes straight to Google. Gemini drives the sliders through `edit_step`, `set_sliders`, `select_region`, `compare`, `reset` and `save_edit`. Each answer carries the values actually applied, sent once the glide lands. You can also type requests in the dock. |
| **Details** (⌘I) | Capture settings from `meta`; Decision-1 scores with their 1–5 probability bars; the coach's notes (capture tips and region notes, which you can click to highlight); a false-colour depth preview (inverse depth); pipeline timings; and **3D**, which opens the web viewer (`web/3d.html`) in a `WKWebView` and passes it this shot's photo. |

## How it stays fast

- **Preview rendering is on demand.** The `MTKView` sleeps until the editor state changes; Observation tracks the slider values, glides, subject, depth and before/after. During a glide it runs at display rate, then pauses again. CPU time per frame was 0.2 to 1.9 ms; GPU time is CoachEdit's 2 to 3 ms at preview size.
- **CoachEdit's caches hit.** The photo, depth and mask are loaded once as fixed `CIImage` instances, and the preview is rendered at the size it's displayed. One Metal device and `CIContext` serve the whole app.
- **No redundant model calls.** "Coach me" reuses `suggest.json`. Assets come from an actor cache that shares in-flight downloads. Mask overlays are tinted once per region.
- **Live updates come from SSE.** The library reloads only on `hello`, which happens after a reconnect.

## How Gemini is used

- Live sessions use ephemeral tokens minted by Core, with the setup (model, prompt, tools and transcription) fixed inside the token. The API key stays on the Mac. See `docs/CORE_API.md` §2.
- **Tool answer scheduling.** `edit_step` and `set_sliders` answers use `WHEN_IDLE`. The edit prompt tells the coach to wait for each step's answer before the next, so a `SILENT` answer ended a lesson after one step (measured). `select_region` and `compare` answer `SILENT`.
- **Keeping Gemini in sync.** Moving a slider sends a debounced `[sliders] …` context message (the prompt's convention) so the coach builds on your edits. The same summary is re-sent after a reconnect, because a resumed gemini-3.8-live session loses its turns.
- The token provider reads the editor's state each time it mints, so a re-mint after a dropped connection starts from the current values.

## Settings and QA flags

Pass these as launch arguments (UserDefaults argument domain) or environment variables:

| Flag | Default | Meaning |
|---|---|---|
| `COACH_CORE_URL` / `-coreURL` | `http://127.0.0.1:8787` | Core to use or start. A non-default port is passed on as `--port` and `COACH_PORT`. |
| `COACH_SERVER_DIR` / `-serverDir` | `../../server` relative to the sources | Where `app.py` lives |
| `COACH_WEB_URL` / `-webURL` | `http://localhost:5320` | Vite server for the 3D viewer |

QA-only flags, all off by default:

- `-openShot <id|latest>`: open a shot's editor once the library loads.
- `-autoCoach YES`: run "Coach me" when the editor opens.
- `-coachGoal "…"`: the goal for that automatic "Coach me".
- `-talkText "…"`: start Talk and type this request once the session is live.
- `-talkMic NO`: Talk without the mic or speaker (no permission prompt).
- `-saveAfterGuide YES`: save when the automatic guide ends.
- `-exportTo /path.jpg`: export a JPEG when the automatic guide ends.
- `-open3D YES`: open the 3D sheet once the photo loads.
- `-showDetails YES`: open the details panel.
- `-showPairing YES`: open the pairing sheet on launch.
- `-snapshotDir /tmp/x` and `-snapshotEvery 0.7`: save PNGs of the app's own window while a guide or Talk runs, with no screen-recording permission needed. This also writes `depth_preview.png` and WebKit snapshots of the 3D page, and traces Talk events to stderr.

Example: run the guided edit against a test Core and record frames.

```sh
COACH_CORE_URL=http://127.0.0.1:8807 build/Build/Products/Debug/CoachStudio.app/Contents/MacOS/CoachStudio \
  -openShot latest -autoCoach YES -snapshotDir /tmp/studio -snapshotEvery 1
```

## Verified (2026-11-21)

These ran against a separate Core on port 8807 with a temporary library, plus the lead's Core on 8787 (read-only).

- **8787 already running:** no second Core was spawned (8 uvicorn processes before and after). The pill read "CORE · UP". That Core has no `/api/shots` yet, and the library says so.
- **Spawn path** (port 8817): health answered 2.7 s after launch (`COACH_WARMUP=0`). `/api/pair` returned the right port, and the QR decoded to `coach://pair?host=…&port=8817&token=<32 hex>`. On SIGTERM the child was gone 0.38 s later.
- **Library:** a shot uploaded by the API showed up through SSE with its stages running.
- **Coach me** from `suggest.json` played 7 steps, and the slider glides, why captions and r1/r3 region highlights showed in frames captured mid-sequence. With a typed goal, `edit/suggest` took 5.0 s and returned 8 steps.
- **Save and export:** the saved recipe round-tripped through `GET /api/shots/{id}`. Export took 278 ms for 1536×2048 (561 KB).
- **Talk** (typed request, no mic): live 0.47 s after the token request. The first `edit_step` came 0.72 s after the request was sent, and 4 slider moves landed within 2.2 s, followed by spoken output with transcripts.
- **3D:** the page loaded and took the photo. Core received `/api/score`, `/regions`, `/masks` and `/splat`, and the viewer switched to its scene view. Its WebGL frame isn't visible in the QA snapshots: the window was behind other windows, so WebKit paused drawing.

## Known issues

- Drag and drop wasn't exercised by automation; import via the API and the open panel path was.
- Microphone capture and echo cancellation on the Mac weren't tested by voice. Typed Talk was.
- `CoachEdit` blurs people outside the chosen subject mask when depth blur is on (a CoachEdit open issue). Choose a mask that covers the whole group.
- Region overlays are hidden when a recipe carries a crop. No crop UI yet.
- The web 3D viewer has no `?shot=` parameter. The app hands it the photo through its file input instead, retrying until the page has wired that input.
