# Teammate setup: run CoachStudio (Mac) and test it

About 20 minutes, most of it downloads. You'll end up with Core (the local AI server) and the
CoachStudio Mac app running on your Mac, editing photos with Gemini.

## What you need

- An Apple silicon Mac (M1 or later) on macOS 15+, 16 GB RAM (32 GB if you want 3D), ~15 GB free.
- Xcode from the App Store. Open it once to accept the license and install components.
- Homebrew, then: `brew install uv xcodegen gh`
- Access to this repo. Ask Pranav to add you. Then `gh auth login`.
- A Gemini API key: make your own at https://aistudio.google.com/apikey, or ask Pranav for the
  team key over a private channel. Never paste it in an issue, PR or commit.

## 1. Get the code and your key

```sh
gh repo clone Pranav-Karra-3301/gemini4hack && cd gemini4hack
cp .env.example .env      # then put your key after GEMINI_API_KEY=
```

## 2. Start Core once by hand (downloads the models)

```sh
cd server
uv sync                                        # Python 3.12 + PyTorch etc., a few minutes
uv run --no-sync uvicorn app:app --port 8787   # first start downloads Depth Pro 2 and SAM 2.1
```

Wait for `Application startup complete`, check `curl localhost:8787/api/health` says `"ok": true`,
then stop it with Ctrl-C. The Mac app starts Core itself from now on.

## 3. Build and open CoachStudio

```sh
cd ../apple/CoachStudio
xcodegen generate
open CoachStudio.xcodeproj
```

In Xcode, pick the **CoachStudio** scheme and **My Mac**, then Run (⌘R). If Xcode asks about
signing, open the target's *Signing & Capabilities* and choose your Personal Team or "Sign to Run
Locally". The app finds `server/` in your checkout, starts Core (≈30–60 s the first time) and shows
the library. Allow the microphone when asked, because Talk uses it.

No Xcode window needed? This builds and opens it from the terminal instead:

```sh
xcodebuild -project CoachStudio.xcodeproj -scheme CoachStudio -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build && open build/Build/Products/Debug/CoachStudio.app
```

## 4. What to test

1. Drag a few photos onto the library, or use Import Photos… (⌘O). Any JPEGs work, and
   `web/public/samples/` has some. Each one gets depth, scores, regions, masks and an edit
   suggestion over ~20 s. Watch the stages fill in.
2. Open a shot. **Coach me** plays Gemini's edit step by step, moving the sliders with a reason
   for each.
3. **Talk**: "make it warmer", "teach me how to make them pop", "darken the background". Gemini
   answers and moves the sliders.
4. Coming with the v3 redesign (design: Paper page "v3 · Studio (Mac) · Pro"): Masks and Looks
   tabs, with Gemini's local masks (sky, faces…) and a film look designed for each photo, plus
   voice for masks ("darken the pavement").

Report what feels off as a GitHub issue (screenshots welcome) or tell Pranav.

## Optional

- **iPhone camera app (CoachCam):** see `apple/CoachCam/README.md`. It needs your Apple ID in Xcode,
  your phone plugged in with Developer Mode on, and `DEVELOPMENT_TEAM` in `apple/Local.xcconfig`.
  Pair it with the QR from CoachStudio (Core must be in LAN mode: CoachStudio does that, or run
  `./dev.sh lan`). The phone and Mac need the same Wi-Fi.
- **3D (SHARP splats):** needs a separate MLX setup (see `docs/ARCHITECTURE.md` §5). Skip it for
  testing; everything else works without it.
- **Web demos:** `./dev.sh`, then http://localhost:5320.

## Staying up to date

```sh
git pull
(cd server && uv sync)
(cd apple/CoachStudio && xcodegen generate)   # then Run again
```

## If something's wrong

| Symptom | Fix |
|---|---|
| "uv not found" in the app | `brew install uv`. The app looks on PATH and in /opt/homebrew/bin. |
| Core won't start, port in use | Something else is on 8787: quit it, or stop an old Core (`lsof -i :8787`). |
| Analysis errors mentioning 401/403 | The key in `.env` is missing or wrong. Restart the app after fixing it. |
| First photo takes minutes | Models are still downloading or loading; later photos take ~20 s. |
| Talk does nothing | System Settings › Privacy & Security › Microphone: allow CoachStudio. |
| App can't find `server/` | Launch with `COACH_SERVER_DIR=/path/to/gemini4hack/server`. |
