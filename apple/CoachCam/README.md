# CoachCam (iPhone)

A native camera with a live Gemini coach. You see the real manual controls (ISO, shutter, EV,
focus, white balance and zoom) as dials, and when Gemini changes a setting you watch the dial
turn. Shots sync to Coach Core on your Mac. The API spec is `docs/CORE_API.md`.

## How it works

- **Camera** (`Camera/AVCaptureEngine.swift`). One `AVCaptureSession` on the back camera. It
  uses the triple or dual-wide virtual device when the phone has one, so the lens switches with
  zoom.
  - `set_camera` drives the hardware directly:
    - ISO and shutter: `setExposureModeCustom`, clamped to the active format.
    - EV: `setExposureTargetBias`.
    - Focus: `setFocusModeLocked` and the point of interest.
    - White balance: `setWhiteBalanceModeLocked` with gains computed from temperature and tint.
    - Zoom: a `ramp` of the display zoom (0.5 = ultra-wide).
    - Torch and flash.
  - Priority exposure: if only ISO or only shutter is manual, the other one follows the meter.
  - Mode presets:
    - `portrait`: depth on, about 2×, +0.3 EV.
    - `night`: a slower shutter, with ISO raised to make up.
    - `macro`: ultra-wide with near focus.
  - The tool response reports the clamped values the camera actually used. The dials read the
    device through KVO, at most 10 updates a second.
- **Coach** (`Coach/CoachSession.swift`). Core mints an ephemeral token
  (`POST /api/live/token`). The phone then talks to Gemini Live directly: mic in, voice out, and
  at most 1 frame a second, sent only when the picture changed.
  - Tools run in order:
    - `guide` shows the arrow.
    - `set_camera` moves the camera and the dials.
    - `set_intent` shows the intent chip.
    - `shot_ready` lights the glow.
    - `user_reaction` shows a wash.
    - `take_photo` takes and syncs a photo.
  - A `[tick]` check-in goes out every 4 s while nobody is talking, and only if the scene changed.
  - When you turn a dial yourself, Gemini gets that as silent context.
- **Sync** (`Sync/ShotOutbox.swift`). Each shot is saved to disk first, then uploaded with
  `POST /api/shots`. The upload includes the capture settings, intent and subject, and the
  coach's lines. Failed uploads retry with backoff, and again when the network comes back.
  Photos also go to the library as HEIF (with depth in portrait mode); you can turn this off in
  Settings.

## Build

```sh
cd apple/CoachCam
xcodegen generate
open CoachCam.xcodeproj
```

To build from the command line without signing:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project CoachCam.xcodeproj \
  -scheme CoachCam -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Run it on your iPhone with a free Apple ID

1. **Sign in to Xcode.** In Xcode > Settings > Accounts, add your Apple ID. A free account gets
   a "Personal Team".
2. **Choose the team.** Open `CoachCam.xcodeproj`, select the CoachCam target, then Signing &
   Capabilities. Leave "Automatically manage signing" on and pick your Personal Team.
   - If Xcode says the bundle ID is taken, change `dev.coach.cam` to something unique, like
     `dev.coach.cam.<yourname>`.
   - Running `xcodegen generate` again clears the team. To keep it, add
     `DEVELOPMENT_TEAM = <TEAMID>` to `apple/Local.xcconfig`, which is gitignored and included
     automatically.
3. **Connect the phone.** Plug it in with a cable, unlock it, and tap **Trust This Computer**.
4. **Turn on Developer Mode.** On the iPhone, go to Settings > Privacy & Security > Developer
   Mode, switch it on and restart. Confirm after the restart. The option only appears after
   Xcode has seen the phone once.
5. **Run.** Pick your iPhone as the run destination and press Run (⌘R).
6. **Trust the profile.** The first launch is blocked as an "Untrusted Developer". On the
   iPhone, go to Settings > General > VPN & Device Management, tap your Apple ID under
   Developer App, then tap **Trust**. Launch the app again.
7. **Allow access.** Grant Camera, Microphone and Local Network when asked. Photos asks the
   first time a shot is saved.
8. **Re-sign every 7 days.** Apps signed with a free account expire after 7 days. Plug the
   phone in and press Run again. Your data stays.

## Pair with the Mac

1. On the Mac, start Core in LAN mode so the phone can reach it. Either run `./dev.sh lan`, or
   use CoachStudio, which does this for you. Core then advertises `_coachcore._tcp` over
   Bonjour and creates a pairing token.
2. Show the pairing QR. CoachStudio has a "Pair iPhone" view for it. The QR comes from
   `GET /api/pair` and encodes `coach://pair?host=…&port=8787&token=…`.
3. Scan the QR, using any of these:
   - CoachCam's pairing sheet ("Scan the code on your Mac").
   - The iPhone's Camera app, which opens CoachCam through the `coach://` URL scheme.
   - Typing the address and the token in the sheet. Macs found over Bonjour fill in the
     address when you tap them.
4. The status pill reads **LIVE** once Core answers and the coach is connected. Tap the pill to
   pause or resume the coach.

The phone and the Mac must be on the same Wi-Fi. The token is stored in the Keychain. If the
Mac's IP changes, the app finds Core again over Bonjour and keeps the token. If Core refuses
the token (a new `.coach_token`), the pill reads **PAIR AGAIN**.

## Debug and QA

- **Simulator.** There is no camera there, so the app always uses the mock camera
  (`Camera/MockCaptureEngine.swift`). The mock is a sample photo that applies settings
  visually: exposure, white balance and zoom crop.
- **Mock camera on a device.** In Debug builds, pass `-mockCamera YES`.
- **Launch arguments (Debug builds):**
  - `-demoCoach YES`: plays a scripted coaching moment through the real tool path, without a
    network. Add `-demoLoop YES` to repeat it.
  - `-coreURL http://127.0.0.1:8787`: skips pairing. Add `-coreToken <t>` for a LAN Core.
  - `-coachPrompt "Make it warmer and take the photo"`: sends a typed turn once the coach is
    live. Use this to test without a mic.
  - `-coach.voice NO`: starts with the coach's voice muted.
- **Logs.** In Debug builds, `CoachCam[live]` lines show the connect time and each tool call
  in ms. Run with `xcrun simctl launch --console-pty booted dev.coach.cam …` to see them.

Measured in the simulator on 2026-11-21, with Core on the Mac and gemini-3.8-live:

| Step | Time |
|---|---|
| Token plus Live setup | 0.55–0.58 s |
| Typed request to `set_camera` + `take_photo` | 0.64–0.65 s |
| `[tick]` to tool calls | about 0.7 s |
| Upload | 201 |

## Known gaps

- Fonts fall back to SF Mono and SF Pro until Geist Mono and Inter Tight are bundled.
- Only the back camera is supported; there is no selfie mode yet.
- The app is portrait only. Photos and frames are still upright in landscape, via the rotation
  coordinator.
- Not yet tested on real hardware: AVFoundation control, depth capture, the QR scanner and
  echo-cancelled audio. The simulator covers the mock camera, Live, tools and sync.
