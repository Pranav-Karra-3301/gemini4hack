# ``CoachLive``

Gemini Live on device: a WebSocket session over an ephemeral token, echo-cancelled mic in,
gapless speech out, paced camera frames, and tool calls that drive the camera dials and
editing sliders.

## Overview

Core mints the token (`POST /api/live/token`, docs/CORE_API.md §2) with the whole setup locked
in: model, prompt, tools, transcription, VAD, media resolution, compression, resumption. The
app never holds the API key, and audio/video go straight to Google without passing through Core.

```swift
let live = LiveSession()
let audio = LiveAudio()
audio.attach(to: live)                       // mic → live.sendAudio, speech → audio, barge-in flush
try await audio.start()
try await live.start(liveToken: { try await client.liveToken(.camera()) })

// Camera output queue, every frame (cheap: at most 1 fps and only changed frames are sent):
live.sendFrame(pixelBuffer: buffer, orientation: .right)

for await event in live.events {
    switch event {
    case .toolCall(let id, let name, let args):
        let applied = try await camera.apply(name, args)       // animate the dial
        try live.respond(to: id, name: name, encoding: applied) // .silent by default
    case .reconnected:
        live.sendContext("[state] \(camera.summary)")           // see "Resumption" below
    default: break
    }
}
```

### Threading

- ``LiveSession`` is a thread-safe class, not an actor: `sendAudio` and `sendFrame` are
  synchronous and non-blocking, so the audio tap and the camera queue call them directly and
  in order (unstructured `Task`s would not keep order). Events arrive in order on
  ``LiveSession/events``.
- ``LiveAudio`` is `@MainActor @Observable` for UI state (`outputLevel`, `inputLevel`,
  `isPlaying`, mute toggles); `enqueue` and `flush` are `nonisolated` and are called from the
  network task through ``LiveAudioOutput``, so speech never waits on the main thread.

### Gemini Live practices applied

- Audio in: 16 kHz mono PCM16 in 100 ms chunks (`audio/pcm;rate=16000`), from the
  voice-processing input (AEC, noise suppression) so Gemini doesn't hear itself.
- Video: JPEG ≤768 px long side, at most 1 fps, and only when a 16×16 luma thumbnail differs
  (mean > 2 % or > 4 % of cells changed). The 1080p luma diff costs ~0.2 ms; the JPEG encode
  (~6–9 ms) runs only for frames that are sent. Video is dropped first when the socket backs up.
- Tool results default to `SILENT`; use `WHEN_IDLE` when the coach should comment and
  `INTERRUPT` only for urgent results. Calls withdrawn by a barge-in arrive as
  ``LiveEvent/toolCallCancelled(ids:)``.
- Facts that shouldn't trigger a reply (a dial the user turned, slider values) go through
  ``LiveSession/sendContext(_:)`` (`clientContent`, `turnComplete: false`). It is a separate
  stream from realtime input: send it when state changes, not in the same breath as a question.
- On `interrupted` the session flushes queued speech at once; `audioStreamEnd` is sent when the
  mic is muted so server VAD closes the turn.
- WebSocket pings every 15 s detect dead sockets; failed control writes are re-sent on the
  next socket.

### Resumption (measured 2026-11-21, gemini-3.8-live)

The session keeps the latest `sessionResumptionUpdate.newHandle`. On `goAway` it waits for the
current answer to end (or until ~1.5 s before the deadline), then closes and resumes; on a drop
it resumes with backoff. If the server refuses, it mints a fresh token, then falls back to a new
session.

- A token minted with `uses: 1` refuses a second connection (close 1011 "Token has been used too
  many times"), contrary to the docs. The session learns this on the first refusal and mints
  before later reconnects (drop → live: 0.6–0.7 s the first time, 0.3–0.4 s after). Minting
  with `uses` ≥ 2 lets resumes reuse `ws_url`.
- The server sent a handle only at session start, so a resume is accepted but the turns so
  far are gone. After ``LiveEvent/reconnected(resumed:)`` re-send state with `sendContext`.

### Measured latency (integration test, Wi-Fi, 2026-11-21)

Token mint 0.1–0.2 s; start to `setupComplete` 0.44–0.60 s; text+frame to tool call
0.45–0.61 s; to first audio 1.0–1.3 s.

## Topics

### Session

- ``LiveSession``
- ``LiveCredential``
- ``LiveEvent``
- ``LiveStatus``
- ``LiveScheduling``
- ``LiveToolArgs``
- ``LiveError``

### Audio

- ``LiveAudio``
- ``LiveAudioOutput``
- ``LivePCM``

### Frames

- ``FrameThrottle``
- ``LumaThumbnail``
- ``LiveFrameEncoder``
- ``LiveFrameResult``
