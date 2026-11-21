# Components scene: shader handoff

Source: Unicorn Studio design "Coach · App (opening + screens)" (tnSSqosm21XZRE7MpkKT), scene "Components" (canvas 613d5aa3-08c1-4527-b228-226844be552b, artboard 1200x1140). This is a read-only export from 2026-11-21.
Full project JSON: `../../unicorn/components/components.json`. It holds 42 layers: a background gradient, 20 custom shape treatments, 20 text layers on the stock text renderer, and a library Grain post effect.

## Files in each folder

| file | what it is |
|---|---|
| `pass0.frag` | Readable treatment source, a `shadeShape(ShapeSample)` with named `uAi*` uniforms. It does not compile on its own (see porting notes). |
| `pass0.compiled.frag` | Full GLSL ES 3.00 shader exactly as the engine runs it. Control values, opacity and border radius are baked in as literals, and unused helpers are removed. |
| `pass0.vert` | Engine vertex shader: a full quad that passes `vTextureCoord` through. It is the same for every layer. |
| `meta.json` | Layer id, frame (position, size, anchor), fill, border radius, every control (uniform, value, min, max, step), textures, and animations (none). |

`_assets/google-sans-flex-500-atlas.webp` is the MSDF font atlas the drums use.

## Time base (applies to every animated shader)

The engine's `uTime` advances **60 × Speed units per second**. Every layer has Speed 0.5, so `uTime = 30 × seconds`. The timings below assume Speed 0.5.

## Table

| # / slug | UI element | key uniforms (name → meaning, range, default) | animated (uTime) and timings | inputs | porting notes |
|---|---|---|---|---|---|
| 01 orb-lantern | Orb A, a frosted-lantern capture orb. 160px circle, centre (0.14167·W, 230). | uAiScale → radius ×, 0.5–1.5, 1 · uAiGlow → Ready, 0–1, 0.35 · uAiVoice → voice pulse, 0–1, 0 · uAiPress → press (shrinks 6%, brightens), 0–1, 0 · uAiLightAngle → key-light direction in turns, 0–1, 0.875 · uAiSwirl → inner drift speed, 0–1, 0.5 · uAiCross → debossed plus opacity, 0–1, 1 · uAiGrain → grain, 0–1, 0.5 | Inner light field rotates at `uTime·0.0262·mix(.25,1.75,swirl)·0.6`, about 0.47 rad/s at default. Voice pulse is `sin(uTime·0.21)`, a period of about 1.0 s. | uTime only | Halo reaches 1.1R outside the disc, so give the view about 10% padding beyond the circle. |
| 02 orb-eclipse | Orb B, a dark eclipse sphere with a blue-violet corona. 160px, centre (0.34167·W, 230). | uAiScale 0.5–1.5, 1 · uAiGlow Ready 0–1, 0.6 · uAiPress 0–1, 0 · uAiLightAngle 0–1, 0.875 · uAiFlow → corona drift speed, 0–1, 0.5 · uAiFilm → corona strength, 0–1, 0.65 · uAiCross 0–1, 1 | Corona drift: `time = uTime·0.0262·mix(.2,1.6,flow)` (about 0.71/s), with `sin(a·3+time·1.3)·sin(a·2−time·0.7)` around the rim. | uTime | `filmSpectrum`/`filmThickness` are in the source but unused (dead code). Corona reaches 1.2R. |
| 03 shutter-ring | Shutter C, a bead-blasted frost ring around a dark disc with a plus. 160px, centre (0.54167·W, 230). | uAiScale 0.5–1.5, 1 · uAiGlow → groove glows blue, 0–1, 0 · uAiPress → disc sinks 5% and darkens, 0–1, 0 · uAiLightAngle 0–1, 0.875 · uAiBrush → bead-blast grain, 0–1, 0.55 · uAiCross 0–1, 1 | Static (no uTime). | none | Ring inner edge is at 0.845R and the disc at 0.79R. `lineNoise`/`hashP` are unused. |
| 04 mic-capsule-56 | Red soft-touch mic capsule, 112x56, idle. Variant 16 is the listening state. | uAiListen → listening (brighter, glyph slides left, waveform), 0–1, 0 · uAiLevel → voice level for bar heights and glow, 0–1, 0.6 · uAiPress → 5% compress, 0–1, 0 · uAiLightAngle 0–1, 0.875 | Glow breath is `sin(uTime·0.2)`, a period of about 1.05 s. Waveform: 10 bars, `t = uTime·0.1` (3/s), heights `|sin(t·3.1+i·1.37)·sin(t·1.9+i·0.71+1)|`. | uTime | Mic glyph and bars are SDFs inside the shader, so no textures are needed. Fill #B3161C is not used: colours are hardcoded (deep #A3161B, red #E5484D). `lightField` is unused. |
| 05 cell-iridescent-glow | Dark instrument cell, 130x84, with a pastel thin-film glow flowing around the inside edge while a value changes. Variant 19 is idle (Intensity 0). | uAiIntensity → glow amount (drive 0→1 while the value changes, then fade back), 0–1, 1 · uAiReach → inward falloff (6–20px), 0–1, 0.43 · uAiLapSpeed → lap speed, 0–1, 0.5 | One lap every 2.4 s (`lap = uTime·0.01389·mix(.4,1.6,lapSpeed)`). The spectrum repeats twice per lap. Shimmer is `sin(s·3τ − lap·1.7τ)`. | uTime | Uses `shapeSample.fillColor` (#070A14) and `signedDistance`. A 1px hairline at 12% of #B4CEFF is drawn inside the edge. |
| 06 viewfinder-edge-guide | Viewfinder, 300x460, radius 0.2·min(half-size). Its border glows Gemini blue on the side the camera should move toward. | uAiDirection → enum 0 L, 1 R, 2 Up, 3 Down, 4 UL, 5 UR, 6 DL, 7 DR, 8 roll TL+BR, 9 roll TR+BL; default 0 · uAiStrength → guide glow, 0–1, 0.85 · uAiPulse → whole-border ready pulse (drive it from the app), 0–1, 0 · uAiShimmer → travelling shimmer, 0–1, 0.7 | Shimmer band travels at `s·3 − uTime·0.0262·0.35`, one band pass about every 3.6 s. Ripple is `sin(s·7τ − time·1.6)`. | uTime, uBorderRadius | `uBorderRadius` comes from the engine (0.2 here). Glow bleeds about 18px outside the box, so pad the view. Up means −y (y-down space). |
| 07 keys-panel | Dark matte panel, 393x124, behind the keys row. Variant 20 is a duplicate for row 2. | uAiGrain → grain, 0–1, 0.5 · uAiHairline → top 1px frost hairline, 0–1, 1 | Static (no uTime). | none | Fill #070A14. |
| 08 key-mic | Keys-row mic key, 120x72, idle. Variant 17 is listening. | Same as 04 (mic-capsule) | Same as 04 | uTime | Same shader as 04 at a different size. Everything scales from `rad = min(halfW, halfH)`. |
| 09 key-shutter-lantern | Keys-row shutter key, 229x72 capsule, frosted lantern. Variant 18 has Ready 1. | uAiGlow Ready 0–1, 0.35 · uAiVoice 0–1, 0 · uAiPress → compresses to 0.96, 0–1, 0 · uAiLightAngle 0–1, 0.875 · uAiSwirl 0–1, 0.5 · uAiCross 0–1, 1 · uAiGrain 0–1, 0.75 | Same as 01 (drift about 0.47 rad/s, voice `sin(uTime·0.21)`) | uTime | Orb A's material mapped onto a capsule. The long axis is compressed into "lantern space". |
| 10 drum-iso | ISO number wheel, 131x84 (text "100 200 400 800 1600 3200", Value 3 = 800, Demo on). | uAiValue → detent index (fractional values scroll smoothly; animate this natively), 0–10, 3 · uAiBlur → manual motion blur, 0–1, 0 · uAiSize → em px, 12–60, 30 · uAiSpacing → px per detent, 30–120, 46 · uAiFade → edge fade px, 0–40, 18 · uAiTextY → baseline centre as a fraction of height, 0–1, 0.6 · uAiPrefix → scale of chars up to and including "/", 0–1, 0.6 · uAiDemo 0/1, 1 | Demo loop is 3.6 s: two detents down at 0.60 s and 0.84 s (240 ms each, back-ease overshoot c1=1.2), hold, two up at 2.10 s and 2.34 s. Blur follows speed: `B = max(blur, speed/17.5)·2.8`. Rest state: ±1 neighbours at scale 0.5 and opacity 0.35, ±2 hidden. | uTime, uFontAtlas, uFontMetrics, uTextCodes | See the drum notes below. Fill #EEF3FF is the glyph colour. |
| 11 drum-ss | Shutter-speed wheel ("1/60 1/125 1/250 1/500", Value 1 = 1/125, spacing 47, Demo off). | Same as 10 | None while Demo is 0 | Same as 10 | "1/" is drawn at the Prefix scale (0.6). |
| 12 drum-ev | EV wheel ("-0.7 -0.3 0.0 +0.3 +0.7", Value 2 = 0.0, Demo off). | Same as 10 | None while Demo is 0 | Same as 10 | |
| 13 drum-cell-iso | Cell behind the ISO drum (at the same frame as 10). | 05's uniforms + uAiDemo 0/1, 1; Intensity 0 | Demo glow is synced to the drum demo: ramps up 0.52→0.68 s and fades 1.1→1.6 s, then up 2.02→2.18 s and fades 2.6→3.1 s, in a 3.6 s loop. Also the 2.4 s lap. | uTime | Natively, drive Intensity from the drum's scroll state and drop the demo. |
| 14 drum-cell-ss | Cell behind the SS drum. | Same as 05; Intensity 0 | 2.4 s lap, visible only when Intensity > 0 | uTime | |
| 15 drum-cell-ev | Cell behind the EV drum. | Same as 05; Intensity 0 | Same | uTime | |
| 16 mic-capsule-56-listening | 04 in the listening state (Listen 1, Level 0.7). | | | | Reference for the listening look. |
| 17 key-mic-listening | 08 in the listening state (row 2). | | | | |
| 18 key-shutter-lantern-ready | 09 with Ready 1 (row 2). | | | | |
| 19 cell-iridescent-glow-idle | 05 with Intensity 0. | | | | |
| 20 keys-panel-2 | Duplicate of 07 for row 2. | | | | |

No layer has Events-tab animations (appear, hover, scroll and mousemove are all empty), and Track mouse is 0 everywhere. All motion comes from uTime, and all state changes are uniform values your app should tween: Ready, Press, Voice, Listening, Level, Value, Direction, Pulse and Intensity.

Layers not exported as treatments: the background `gradient` (#04060C) and the `grain` post effect (ad51a6d4) are library effects, so their readable sources are private. Their compiled shaders are in components.json. The 20 text layers use the stock MSDF text renderer with no custom treatment.

## Porting notes

- **Shape-treatment API.** `pass0.frag` defines only `shadeShape(ShapeSample s)`. The engine supplies the rest (see the top of `pass0.compiled.frag`):
  - `struct ShapeSample { float signedDistance; float coverage; vec2 localPosition; vec2 elementSize; vec3 fillColor; vec2 mousePosition; }`
  - the helpers `sdBox`, `sdRoundedBox(p, halfSize, radius)`, `rotate2D` and `TAU`/`PI`
  - `uFillAlpha` (layer opacity, 1) and `uBorderRadius` (0..1 fraction of min half-size)
- **Return value.** `shadeShape` returns **premultiplied** RGBA. Several shaders draw outside the box (halos and coronas), and the engine evaluates them over the whole canvas quad. In a native view, render each element into a padded transparent layer with premultiplied alpha.
- **Coordinates.** `localPosition` is in pixels from the element's **top-left with y down**. `signedDistance` is **positive inside** the shape, `coverage` is the engine's anti-aliased fill mask, and `elementSize` is in px.
  - The light angle is in turns: `L = (cos, sin)(angle·τ)`, so 0.875 points up-right in y-down space. Every element is lit from the upper right.
  - The shaders use `fwidth` for anti-aliasing and `gl_FragCoord` for debanding, so render at device scale; the design runs at dpi 1.5.
- **Frames.** `left` below 1 is relative (fraction of the 1200px width); values above 1 are fixed px. All anchors are centre, so `left`/`top` give the element's centre.
- **Compositing wrapper.** The compiled shader samples `uBgTexture` (the layers below) and composites with normal blending. Drop this natively and let the view system composite.
- **Drums and text textures.**
  - `uTextCodes` is a 256x1 texture with the Text control's ASCII codes in R. Spaces separate detent values, and 0 ends the string.
  - `uFontMetrics` is an engine-generated 95x10 data texture for the atlas (layout in meta.json and in `metricValue`/`glyphPlane`/`glyphAtlasUv`/`atlasHeader`).
  - `uFontAtlas` is the MSDF atlas, in `_assets`.
  - The metrics PNG is not saved (it is an inline data URL from get_effect_context). A native port is probably simpler with platform text (Google Sans Flex 500) and the same layout rules: scale 1→0.5 and opacity 1→0.35 over one detent, hidden at two detents, spacing in px per detent, edge fade on values beyond ±1, horizontal streak blur scaled by scroll speed, a shared baseline from the "0" glyph's optical centre, and prefix chars up to "/" scaled by uAiPrefix.
- **Shared look constants.** blue #4C8DFF (0.298, 0.553, 1.0), iris #9A7CF6 (0.604, 0.486, 0.965), frost #EEF3FF, hot #B4CEFF. Grain is `randFibo(floor(localPosition))`, a per-pixel hash that is static (it does not move with time).
- The `blend()` placeholder does not appear: none of these treatments use shared blend helpers, so the sources are complete apart from the engine prelude above.
