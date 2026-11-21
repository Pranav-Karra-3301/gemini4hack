# Coach Cam: contract

A camera page (`web/cam.html`) that coaches you live: big arrows say where to move the
camera, it switches modes and settings for you, and with voice on it talks. It works with the
laptop webcam and in iPhone Safari (served over HTTPS). Three engines can drive the same UI:

| Engine | What it does | Models |
|---|---|---|
| `live` | Streams mic audio + 1 fps frames over a WebSocket; the model hears you, sees the frame, talks back, and calls tools that drive the HUD and settings | `gemini-3.8-live` (Gemini Live API) |
| `decide` | Fast loop (~1/s): frame (+ last few seconds of mic audio when you spoke) to Decision 1, which picks move / ready / mode / exposure / your reaction with probabilities. Slow loop (every ~5 s, or right after you finish speaking): 1–3 frames + audio clip to Gemini 4 Hydrogen, which works out intent, what you said, and one spoken tip. Voice via Gemini TTS | `gemini-decision-1`, `gemini-4-hydrogen` (or `gemini-4-neon`), `gemini-3.8-flash-lite-tts` |
| `mock` | Scripted events for UI work, no backend | none |

Pick with `?engine=live|decide|mock` (default `decide`; the UI also has a small switch).
`?debug=1` shows a latency/event overlay. Keys stay on the server (`.env`: `GEMINI_API_KEY`).

## Files and owners

```
web/cam.html, web/src/cam/{main,viewfinder,hud,capture,mock}.js, web/src/cam/cam.css   UI agent
web/src/cam/bus.js                                                                   lead (event list)
web/src/cam/{audio,live,decide}.js                                                   brains agent
server/cam.py, server/checks/cam_check.py                                            brains agent
```

`server/app.py` already includes `cam.router` (APIRouter) if `server/cam.py` exists.

## Bus (`web/src/cam/bus.js`)

`createBus()` → `{emit(type, detail), on(type, fn) → off}`. Event types and payloads are listed
at the top of `bus.js`; that list is the contract. Directions are camera moves in the RAW
(unmirrored) frame: `left` = pan/step the camera left so more of the raw frame's left side comes
in. The UI mirrors `left/right/rotate_*` when it shows a mirrored selfie preview.

## Engine interface

`live.js`, `decide.js` and `mock.js` each export `createEngine(ctx)` returning
`{ start(): Promise<void>, stop(): void, setVoice(on: boolean): void }`.

`ctx` (built by the UI in `main.js`):

```js
{
  bus,                                   // createBus()
  mic,                                   // from audio.js createMic(stream), or null if no mic
  grabFrame(maxSide = 768, quality = 0.7) // -> Promise<Blob|null>: JPEG of the RAW camera frame
                                          //    (not mirrored, no effects), long side <= maxSide
  getState(),                            // -> CamState (below), current values
  voice,                                 // initial voice on/off
}
```

`CamState`:

```js
{
  facing: 'user' | 'environment', mirrored: boolean,
  mode: 'photo' | 'portrait' | 'night' | 'macro',
  zoom: 1..5, exposure: -2..2 (EV), warmth: -1..1, iso: number|null, shutter: seconds|null,
  focus: {x, y} | null,                   // normalized 0..1, origin top-left, raw frame
  flash: 'off' | 'on' | 'auto',
  intent: string | null, subject: string | null,
  voice: boolean, engine: 'live' | 'decide' | 'mock',
  caps: { zoom, exposure, iso, shutter, focus, wb, torch }  // booleans: real hardware control available
}
```

Engines emit `settings` with any subset of `{mode, zoom, exposure, warmth, iso, shutter, focus,
flash}`. The UI applies each one with a real `MediaStreamTrack` constraint when
`getCapabilities()` offers it and otherwise emulates it in the viewfinder shader (exposure gain,
white balance, digital zoom crop, portrait background blur, night lift/denoise; ISO/shutter map
to exposure). Settings always animate.

## Audio (`web/src/cam/audio.js`, brains)

`createMic(stream)` → `Promise<Mic>`:

```js
{
  onChunk(fn),            // fn(Int16Array) ~every 100 ms, 16 kHz mono PCM16 (for Live)
  level(),                // current input level 0..1 (UI meter)
  speaking(),             // simple energy VAD: true while the user is talking
  lastSpeechEndedAt,      // performance.now() when the last utterance ended (0 = never)
  recentWav(seconds),     // Blob audio/wav of the last N s (16 kHz mono), or null if silent
  close(),
}
```

plus `createPlayer()` → `{ push(Int16Array|ArrayBuffer, rate = 24000), playWav(blob), flush(),
muted, playing(), onPlaying(fn) }` for coach audio (Live PCM at 24 kHz; TTS WAV).

## Server (`server/cam.py`, brains)

All under the token gate: when env `COACH_TOKEN` is set, requests need cookie
`coach_k=<token>`. The HTTP middleware in app.py covers HTTP routes; the WebSocket route checks
the cookie itself and closes with code 4401 when it's wrong.

### `WS /api/live?voice=1&facing=user|environment`
The server opens the upstream Live session (`LIVE_MODEL`, default `gemini-3.8-live`) and sends
the `setup` itself (system prompt, tools, `inputAudioTranscription`, `outputAudioTranscription`,
context window compression). The client never sends `setup`. Client → server frames are Gemini
Live client messages, forwarded as is: `realtimeInput` (`audio` PCM16 16 kHz base64,
mime `audio/pcm;rate=16000`; `video` JPEG base64, at most 1 fps; `text`), `toolResponse`,
`clientContent`. Server → client: every upstream message, as JSON text frames (`setupComplete`,
`serverContent`, `toolCall`, `toolCallCancellation`, `goAway`, ...), plus `{"error": "..."}`
before closing on failure.

Live tools (declared by the server; the client turns tool calls into bus events and answers
each with a `toolResponse`, `scheduling: "SILENT"` unless it wants the model to speak):

| Tool | Args | Bus event |
|---|---|---|
| `guide` | `direction` (a `MOVES` value), `strength` small/medium/large | `move` |
| `set_camera` | any of `mode, zoom, exposure, warmth, iso, shutter, focus_x, focus_y, flash` | `settings` |
| `set_intent` | `intent` (an `INTENTS` value), `subject` (≤4 words) | `intent` |
| `user_reaction` | `reaction` (a `REACTIONS` value), `heard` | `reaction` |
| `shot_ready` | `ready` boolean | `ready` (p = 0.9 / 0.1) |
| `take_photo` | `reason` | `capture` |

### `POST /api/cam/decide`
Multipart: `frame` (JPEG ≤768), `audio` (optional WAV, 16 kHz mono, ≤6 s), `state` (JSON string:
CamState + `{heard, wants}` from the last understand result). Response:

```json
{"answers": {"move": {...}, "ready": {...}, "intent": {...}, "mode": {...}, "exposure": {...},
             "reaction": {...}},
 "model": "gemini-decision-1", "ms": 820}
```

Each answer is the Decisions API answer object, passed through (`choice`/`probabilities`/
`confidence`, or `noul`/`confidence`). `move.choice` is a `MOVES` value, `intent.choice` an
`INTENTS` value, `mode.choice` a `MODES` value, `exposure.choice` one of `darker|ok|brighter`,
`reaction.choice` a `REACTIONS` value. `reaction` is only present when `audio` was sent.

### `POST /api/cam/understand`
Multipart: `frames` (1–3 JPEGs, repeated field), `audio` (optional WAV), `state` (JSON). Response:

```json
{"intent": "portrait", "subject": "friend by the window", "heard": "I want a portrait of my friend",
 "reaction": "neutral", "wants": "a soft portrait of the friend", "tip": "Turn her toward the window",
 "settings": {"mode": "portrait", "exposure": 0.3, "zoom": 1.5},
 "model": "gemini-4-hydrogen", "ms": 3700}
```

`tip` is at most 8 words, spoken when voice is on. `UNDERSTAND_MODEL` overrides the model.

### `POST /api/cam/say`
JSON `{"text": "...", "voice": "Kore"}` → `audio/wav`. `TTS_MODEL` (default
`gemini-3.8-flash-lite-tts`) and `TTS_VOICE` override.

## Additions made while building (2026-11-21)

- `WS /api/live` accepts `&resume=<handle>` (session resumption) and may send
  `{"sessionRotated": ...}` when it reconnects upstream on `goAway`. live.js sends a short
  check-in every ~4 s and a nudge when a user turn goes unanswered, because the model is often
  silent otherwise. Turns end after 0.6 s of silence.
- `/api/cam/decide` responses include `tokens`. `/api/cam/understand` also returns `selfie`
  (bool), `keep` (who must stay fully in frame) and `scene` (the place-defining background, or
  ""). Both are fed into the next decide `state` and into the Live session. Coaching rule
  everywhere: keep every person fully in frame, reveal more of the scene, and in a selfie
  suggest arm moves.
- audio.js also exports `unlockAudio()` (call it from the start tap, for iOS) and
  `audioContext()`; the mic has `speechStartedAt`; the player has `close()`.
- Env: `LIVE_MODEL`, `LIVE_VOICE`, `DECIDE_CAM_MODEL`, `UNDERSTAND_MODEL`,
  `UNDERSTAND_THINKING`, `TTS_MODEL`, `TTS_VOICE`. The WebSocket uses app.py's `token_ok`
  (only tunnel requests need the cookie).
- Dev-only lab page: `/lab/engines.html?engine=live|decide` logs every bus event.
- Default engine is `live` (fallback `decide`, then `mock`).

## Test fixtures

`/tmp/lc_qa/fixtures/`: `pan_1016.y4m`, `pan_1216.y4m` (640x480, 10 fps, 14 s, a slow pan across
a sample photo) and `speech.wav` (16 kHz, 23.6 s: "I want a nice portrait of my friend here",
a disappointed "Hmm, no. That's not it", then "Oh, that's good! Yeah, that one", with silence
between). Headless Chrome (playwright-core in /tmp/lc_qa, `command node`) with
`--use-fake-ui-for-media-stream --use-fake-device-for-media-stream
--use-file-for-fake-video-capture=<y4m> --use-file-for-fake-audio-capture=<wav>
--use-angle=metal --ignore-gpu-blocklist` feeds them in as the webcam and mic.
