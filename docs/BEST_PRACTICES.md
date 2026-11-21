# Gemini calls in Coach: what we do, why, and what it costs

This page covers every Gemini call the system makes: Core (the Mac server) and the Live sessions
that CoachCam, CoachStudio and the web client open. Each section says what we do, links the
official doc behind it, and gives the numbers we measured on 2026-11-21. §7 is the ranked list of
what is still open.
Code: `server/gemini.py` (the shared client), `server/live_setup.py` (the Live setup), `server/stats.py`
(`GET /api/stats`), `server/checks/bench.py` (latency bench),
`apple/CoachKit/Sources/CoachLive` (the Swift Live client).

## 1. One client for every REST call (`server/gemini.py`)

| What | Why |
|---|---|
| One pooled `httpx.AsyncClient` per event loop (keep-alive, 5 s connect, 60 s read, 64 conns) | Saves the DNS and TLS handshake on every call after the first. Measured: a cold request takes 79–141 ms and a warm one 54–78 ms. `app.py` warms it in the background at startup and closes it at shutdown. HTTP/2 turns on by itself if the `h2` package is installed (it isn't today). |
| Retries on 429/500/502/503/504 and network errors: exponential backoff with jitter (0.5 s, 1 s, … max 8 s), honours `Retry-After` and `google.rpc.RetryInfo.retryDelay`, all inside one total deadline per call. Other 4xx errors fail at once. | [Rate limits](https://ai.google.dev/gemini-api/docs/rate-limits). If the server asks for a wait longer than the deadline allows, the call fails at once instead of sleeping. Calls whose answer is useless if late pass `attempts=`: score labels use 1, and the 1 Hz cam decide uses 2 within a 6 s deadline. |
| One structured log line per call, e.g. `INFO: coach.gemini call tag=regions model=gemini-4-argon status=200 ms=9457 in=1726 out=243 thought=0 cached=0 retries=0 kb=244` | uvicorn only sets up its own loggers, so `coach.gemini` gets a stderr handler in the same format. Set `GEMINI_LOG=0` to silence it. |
| In-memory stats per (model, tag): p50/p95/mean/max over the last 500 calls, errors, invalid replies, retries, input/output/thought/cached tokens, KB sent, estimated USD. `GET /api/stats` returns them; `DELETE /api/stats` resets them. | [Pricing](https://ai.google.dev/gemini-api/docs/pricing). Prices are for the standard paid tier as of 2026-11-21. Argon and Carbon double on 2026-12-01. OpenRouter fallbacks are logged as `openrouter:<model>` (tokens only, no cost). Live sessions are not in these stats, because their tokens are billed on the client's socket (§3). |
| `generate()` / `generate_json()` | Puts the system prompt in `systemInstruction`, ahead of the per-call content. Sets `thinkingLevel` (default `low`) and `mediaResolution`. Picks `responseSchema` for OpenAPI-style uppercase schemas and `responseJsonSchema` for JSON Schema. Drops thought parts. Raises `GeminiError` on empty or non-JSON replies and counts them as `invalid`. |
| `image_part(data, mime, resolution=)` | Per-part media resolution. Checked on generateContent REST: `low` = 308 input tokens and `high` = 1106 for the same image. |
| `prepare_jpeg(data, long_side)` | EXIF-upright, JPEG draft-mode decode, then LANCZOS resize. A 4032 px photo now takes 59 ms to reach 1024 px instead of 148 ms. `regions.py` runs it off the event loop. |
| `decisions()`, `tts()` (returns WAV), `mint_live_token(setup, field_mask=)` | One code path, so these calls get the same retries and stats. |

Migration (done 2026-11-21, verify-core): every Gemini HTTP call in Core goes through
`gemini.py`. Tags: `regions`, `score`/labels, `reframe`, `cam_decide`, `cam_understand`, `cam_say`
(the TTS LRU cache stays in front), `live_token`, `suggest`, plus `live_proxy_connect` (the
`WS /api/live` proxy's connect-to-setupComplete time). Bench p50 (n=3): decide_cam 389 → 338 ms,
live (mint + setup + first tool) 531 → 410 ms; understand, say and score stayed within ±1%.

**Keys.** Only Core reads `GEMINI_API_KEY` and `OPENROUTER_API_KEY` (from `../.env`). Clients get a
short-lived Live token (§3) and never see a key. A grep of `web/src` and `apple/` finds the key
name only in the opt-in Swift integration test, which reads it from the environment.

## 2. Each REST call path

Bench: `checks/bench.py`, n=3, sequential, on a private instance (:8795), with a 1536 px photo and
a 768 px camera frame. Latency is wall time measured on the client.

| Path | Model, settings | Tokens and cost per call | p50 / p95 before | p50 / p95 after |
|---|---|---|---|---|
| `/api/regions` | gemini-4-argon, thinking `low`, media `high` (explicit), 1024 px, JSON Schema | 1726 in, ~243 out, 0 thought, ≈ $0.006 | 12.4 s / 24.4 s | 9.5 s / 13.9 s |
| `/api/score` | gemini-decision-1 (both rubrics in one request, image `medium`) running alongside labels | 1088 in, $0.0001, plus labels 602 in, $0.0003 | 1.04 s / 1.64 s | 0.84 s / 1.05 s |
| ↳ labels | before: OpenRouter nemotron (0.48–0.86 s). After: gemini-3.5-flash-lite, thinking `minimal`, media `medium`, one attempt | 602 in, 36 out | – | 0.79 s / 1.0 s (server) |
| `/api/reframe` (Gemini call only) | gemini-4-hydrogen, `low`, media `medium`, 1024 px, OpenAPI schema | ~1.2k in, plus thought | 5.6 s / 6.9 s | 6.5 s / 7.1 s |
| `/api/cam/decide` | gemini-decision-1, 5 questions, frame `low`; 6 s deadline, 2 attempts (it was 15 s and 3 attempts) | 1542 in (1.8–1.9k with voice), $0.00015–0.0002 | 0.53 s / 0.75 s | 0.39 s / 0.52 s |
| `/api/cam/understand` | gemini-4-hydrogen, `low`, media `low` | 2.2–2.6k in, 165–179 out, 350–530 thought, ≈ $0.007–0.009 | 4.0 s / 4.5 s | 4.7 s / 5.6 s |
| `/api/cam/say` | gemini-3.8-flash-lite-tts, LRU cache of 128 | – | 2.28 s / 2.34 s | 2.38 s / 2.41 s (cached: 15 ms) |
| `/api/suggest` (edit plan) | gemini-4-hydrogen, `low`, media `medium`, 1024 px, JSON Schema, in-flight dedupe and cache | – | – | 4.7–8 s |
| Live: mint, setup, first tool call | `/api/live/token`, then the WebSocket | – | – | mint 110–210 ms, setupComplete 188–410 ms, first `toolCall` 0.41–0.67 s |

How to read this: at n=3 the paths nobody changed moved by −26% to +18% between runs, so that
is the noise floor. Gemini's own queueing dominates: argon regions took 6–25 s on the same image.

## 3. Live API (`live_setup.py`, `live_token.py`, CoachLive)

| Setting | Value | Why / doc |
|---|---|---|
| Model, output | `gemini-3.8-live`, `responseModalities: ["AUDIO"]`, both transcriptions | This model only outputs audio, so captions come from `outputAudioTranscription`. Transcripts are billed as text output on top of the audio ([best practices § pricing](https://ai.google.dev/gemini-api/docs/live-api/best-practices)). |
| Thinking, proactivity, affective dialog | omitted | On gemini-3.8-live, `thinkingLevel` must be omitted, proactive audio is always on (setting it to `false` is an error) and affective dialog was removed ([capabilities](https://ai.google.dev/gemini-api/docs/live-api/capabilities)). |
| Tools | no `behavior` set; tool answers carry `scheduling` | NON_BLOCKING is the default on 3.8 Live. `scheduling` is a top-level `FunctionResponse` field and defaults to WHEN_IDLE. Camera tools answer SILENT unless the coach should comment. Slider tools answer WHEN_IDLE, because SILENT stopped a guided edit after one step. |
| Media resolution | `MEDIA_RESOLUTION_LOW` | Measured: a frame costs **~165 tokens at LOW**, the same at MEDIUM, and ~540 at HIGH. Frames of 384, 512, 768 and 1024 px all cost the same, so pixel size only changes the upload. |
| Turn coverage | default (`TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO`) | Every frame sent goes into the context. Silence does not. |
| VAD | automatic, `END_SENSITIVITY_HIGH`, `silenceDurationMs: 600` | The default sometimes merged several utterances into one 20 s turn. Clients send `audioStreamEnd` when the mic pauses. |
| Compression | `triggerTokens 16000`, `slidingWindow.targetTokens 8000`; env `LIVE_CWC_TRIGGER`/`LIVE_CWC_TARGET` (it was 24k/12k) | Audio+video sessions stop at ~2 min without compression. **Live bills every turn for the whole context window**, so the window size is the cost lever. A test with a 10k/5k window compressed twice in 80 s and kept the system prompt. Tick→first reply stayed at 0.52–0.93 s, with no spike on the turns that compressed. 16k/8k bills ~12k tokens per turn on average instead of ~18k (−33%). |
| Ephemeral token | `uses: 1`; `expireTime` 30 min; `newSessionExpireTime` 120 s (`LIVE_TOKEN_START_S`); `fieldMask` = every setup field except `sessionResumption` | [Ephemeral tokens](https://ai.google.dev/gemini-api/docs/live-api/ephemeral-tokens). Without a mask the server ignores the client's setup, so resumption breaks and a reconnect counts as a second use. `uses` ≥ 2 is not needed. |
| Resumption | first setup: `{"setup":{"sessionResumption":{}}}`; reconnect: `{"handle": h}` inside it | **Fixed in this review.** CoachLive sent `{"setup":{}}`, so with Core's tokens no handles arrived. Every ~10 min connection reset then lost the conversation and needed a new token. Its integration test minted without a mask, which hid the bug. Now, with Core-style tokens: one mint, and two forced drops each resumed on the same token in 0.36–0.49 s. The model still knew a code word from before both drops. Handles are valid for 2 h. |
| goAway | CoachLive waits for the turn to end (or `timeLeft` − 1.5 s), then resumes | [Session management](https://ai.google.dev/gemini-api/docs/live-api/session-management). The web proxy (`cam.py`) rotates at once (§7). |
| Audio in | 16 kHz mono PCM16, **40 ms chunks** (it was 100 ms) | The best practices ask for 20–40 ms chunks; 100 ms chunks delay server VAD by up to 60 ms. CoachLive's backlog limit is now 100 chunks, which is still 4 s. |
| Video in | JPEG ≤768 px, quality 0.6, ≤1 fps. CoachLive sends a frame only when a 16×16 luma thumbnail changed | Static scenes add almost nothing to the context. The web client has no change gate (§7). |
| Barge-in | flush queued playback on `interrupted` | Required by the best practices. |
| Keys | the apps' only credential is the token | The WS proxy (`/api/live`) keeps the key on the server for browsers. |

### Live tokens per minute

Measured 2026-11-21 with the real camera setup (§6).

- **Fixed cost.** The camera prompt plus tools is **2.8k tokens**, billed on every turn. Edit mode's is ~1.7k.
- **Growth.** A frame is ~165 tokens, so at 1 fps the context grows **~9.9k tokens/min**. Each
  `[tick]` adds ~35 text tokens, and user speech adds 25 tokens/s.
- **Active framing.** With a frame every second and a tick every 4 s, the billed prompt per turn
  rose from 3.9k to 15.4k over the first minute, and that minute billed **146k input tokens**. iOS
  does this while the picture keeps changing; the web client always does. Steady state at 16k/8k
  is ~15 turns × ~12k = **~180k input tokens/min, ≈ $0.17/min (~$10/h)**. The old 24k/12k window
  would have billed ~270k tokens/min, ≈ $0.26/min.
- **Static scene on iOS** (no new frames, a tick every 12 s): ~5 turns × 3–5k ≈ 15–25k tokens/min ≈ $0.02/min.
- **Model speech** is billed as audio output at $12/M, 25 tokens/s, so 10 s of speech per minute costs ~$0.003.
- **Mic.** Proactive audio bills mic input the whole time the socket listens: 1.5k tokens/min ≈ $0.0045/min.
- **Edit mode** (Studio "Talk") sends no video. A turn is 2–5k tokens and happens only when the
  user asks, so it costs well under $0.01/min.
- **Spend limit.** Tier 1 allows **$10 per 10 min** per project
  ([rate limits](https://ai.google.dev/gemini-api/docs/rate-limits)), so about 5 iPhones framing
  at once would hit it.

### Decide engine (web fallback) per minute

- `/api/cam/decide` at ~1 Hz: 60 calls × ~1.6–1.9k tokens ≈ 100–115k tokens/min. At $0.10/M that is
  ≈ $0.01/min, well inside Tier 1's 1M tokens/min for Decisions.
- `/api/cam/understand` every 5 s: 12 calls × ≈ $0.009 ≈ **$0.11/min**, 90% of this engine's cost.
  The web live engine's scene check calls it every 8 s (≈ $0.07/min).
- Total ≈ $0.12/min (~$7/h). With understand on Flash-Lite it would be ≈ $0.02/min (§7).

## 4. Audit of the REST calls against the docs

- **Thinking** ([thinking](https://ai.google.dev/gemini-api/docs/thinking)): Gemini 4 supports
  `low`/`medium`/`high`(/`xhigh`) and rejects `minimal`. The default is `medium` on argon/carbon
  and `high` on neon/hydrogen, so we always send `low`. At `low`, argon used 0 thought tokens on
  regions, while hydrogen still used 350–870. Flash-Lite 3.5 accepts `minimal`. To save tokens,
  lower `thinking_level`. Don't cap `maxOutputTokens`: that truncates the answer and still bills
  the thinking.
- **Media resolution** ([media-resolution](https://ai.google.dev/gemini-api/docs/media-resolution)):
  Gemini 4 bills an image by its resolution budget (low 280, medium 560, high/default 1120
  tokens), not by pixels. Regions uses `high`, which the docs recommend for images. Reframe and
  suggest use `medium`. Camera frames and decide use `low`.
- **Structured output** ([structured-output](https://ai.google.dev/gemini-api/docs/structured-output)):
  every JSON call uses a schema. Validation and clamping stay in our code (`_normalize`, `_clamp_move`).
  A bad answer gets one more try (regions, suggest), on top of gemini.py's HTTP retries. The worst
  case is regions: 3 HTTP attempts within 60 s, then one OpenRouter attempt.
- **Decisions** (Gemini Decision 1 guide): one request per input, with every question about that
  input. The input is billed once per request. There is no caching and no Batch API, and output
  tokens are always 0.
- **Implicit caching** ([caching](https://ai.google.dev/gemini-api/docs/caching)): Gemini 4 and
  3.8 need a prefix of at least **4,096 tokens**. Our calls are 0.6k–2.6k tokens, so they never
  hit (`cached=0` everywhere). Explicit caching isn't available on Gemini 4. Don't pad prompts to
  reach the minimum. Keeping system instructions byte-stable and first costs nothing, so keep doing it.
- **Concurrency**: the shot pipeline is one worker with at most 2 Gemini calls in flight, and
  suggest dedupes calls already in flight. Client loops keep one request in flight. The HTTP pool
  caps at 64 connections.
- **Batch / Flex** ([batch-mode](https://ai.google.dev/gemini-api/docs/batch-mode)): both cost
  50% less. Neither fits a path where the user waits. Both fit re-processing the library after a
  prompt change, and eval runs.

## 5. Experiments that didn't ship (so nobody re-runs them blind)

| Idea | Measured | Verdict |
|---|---|---|
| Regions on argon `medium` | 6.7–8.5 s vs 7.5–10.4 s, 1202 vs 1726 tokens | Risks box precision, and the gain is within noise. Kept `high`. |
| Regions on hydrogen `medium` | 5.4–7.6 s, plus 460–870 thought tokens (≈ $0.010 vs $0.006) | After 2026-12-01 argon rises to ≈ $0.012/call and hydrogen stays ≈ $0.0085. Re-evaluate then, with a box-quality check. |
| Reframe on gemini-3.5-flash-lite | 1.04–1.12 s vs 5.6–7 s | Its advice contradicted the prompt's "reveal the scenery" rule. Not adopted; needs an eval set. |
| Labels on gemini-4-hydrogen `low` | 4.8–5.3 s | Misses the 1.5 s grace window. Flash-Lite 1.05–1.25 s fits. |
| Smaller Live frames (384/512 px) | ~165 tokens/frame, the same as 768/1024 px | No token saving, only a smaller upload. Kept 768 px. |
| Live compression at 10k/5k | no latency spike, but it keeps only ~8 frames plus a few turns | Too forgetful. Shipped 16k/8k. |

## 6. How to re-measure

- REST latency: run `checks/bench.py -n 10` before changing any model default. At n=3 the noise is ±25%.
- Live tokens: run `server/checks/live_cost.py <seconds> <tick_s> <images…>`. It streams
  frames and `[tick]`s with the real camera setup and prints `usageMetadata` for each turn. Use
  `FRAME_PX`, `MEDIA_RES` and `CWC=trigger,target` to compare settings. A 60 s run costs a few cents.
- Live end to end:
  - `checks/live_token_check.py` covers tokens, resumption and edit mode.
  - `checks/cam_check.py` covers the WS proxy.
  - `COACH_LIVE_IT=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CoachLive`
    runs the Swift client against Gemini. It needs `GEMINI_API_KEY` in the environment.

## 7. Open, ranked by impact

1. **Check-ins multiply Live cost.** Each `[tick]` (and each WHEN_IDLE tool answer) bills the
   whole window, ~12k tokens. iOS ticks every 4 s while frames change and every 12 s otherwise;
   the web client ticks every 4 s regardless. Ticking every 6–8 s while framing saves 33–50% of
   Live input, and so does skipping ticks while the user is still following the last arrow. Both
   need a UX check on a phone, because the arrows would update less often.
2. **Web live client** (`web/src/cam/live.js`): add CoachLive's luma change gate before sending a
   frame. Today it sends every frame, so even a static scene adds ~9.9k tokens/min. Also send a
   tick only after a new frame, as iOS does.
3. **Move `/api/cam/understand` to `gemini-3.5-flash-lite` with thinking `minimal`** (env
   `UNDERSTAND_MODEL`, `UNDERSTAND_THINKING`). It measured 0.94–1.43 s vs ~4 s and ≈ $0.0009 vs
   $0.009 per call, which cuts the decide engine's cost by ~80%. Check `heard`/`reaction` on real
   voice clips first.
4. **Budget guard for Tier 1's $10 per 10 min.** Cap concurrent Live tokens in `live_token.py`.
   CoachLive ignores `usageMetadata` today; parse it so the apps can log tokens per session and
   Core can show them in `/api/stats`.
5. **shots.py pipeline:** suggest waits for masks only to read mask areas and depths for its notes
   and subject pick. On the E2E run the critical path was regions 9.6 s → masks 3.8 s → suggest
   9.2 s, all done 22.7 s after upload. Starting suggest right after regions, with the subject from
   the first focus region, would save the masks time but may pick the subject less well.
6. **Trim the camera prompt.** Its 2.8k tokens are billed every turn; cutting 30% saves ~7% of Live input.
7. **WS proxy goAway** (`cam.py`) rotates the upstream at once and can cut a sentence short. Wait
   for `turnComplete` or `timeLeft` − 1.5 s, as CoachLive does. The web reconnect loop also never
   gives up (its backoff is capped at 10 s).
8. **2026-12-01 price change:** argon (regions) doubles. Re-run the hydrogen `medium` regions
   experiment, with a box-quality check.
9. **Batch/Flex** at 50% off for any "re-analyse the library" action and for eval runs. Keep
   per-shot sync on the standard tier.
10. **First run on a real iPhone:** 40 ms mic chunks with voice processing, and the frame gate under
    real sensor noise, haven't been tried on a device. Watch for `sendAudio` drops (the backlog
    limit is 100 chunks).
