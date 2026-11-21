# Design handoff: iPhone camera coach (2026-11-21)

This is the final word for implementation. `design/V2_INSTRUMENT.md` is the decision log (v2 → v2.5 → v3);
where they disagree, **this file wins**.

## Where everything is

| What | Where |
|---|---|
| Paper file | https://app.paper.design/file/01M7ZEJ61SXCRBKXGD08J87QCJ |
| iPhone screens (final) | Paper page **v2 · Camera (iPhone)** `p-5-1`: sheet `1U7-1`, a `200-1`, b `243-1`, c `26H-1`, d `29L-1`, e `2EF-1`, wake frames `3DL-0` `3OF-0` `3MV-0` `3DS-0` |
| Brand (working name Northlight) | Paper page **Brand · Northlight (celestial) · landing + icons** `p-E-0` |
| PNG exports (2x) | `mocks/iphone/*.png`, index in `mocks/INDEX.md` |
| Unicorn designs | **Coach · App** `tnSSqosm21XZRE7MpkKT` (Components scene `613d5aa3-…`) · **Coach · Phone demos** `wWuYcqLxDoR3kCFHxTnM` (wake `f31374c8-…`, viewfinder `784d33c6-…`, depth scan `1449c3da-…`, plus a timeline) · **Coach · Light Lab** `ssbuNpC8g8ktDUQhZmU8` (4 light backgrounds) |
| Shader source + controls | `shaders/<design>/NN-slug/{pass0.frag, pass0.compiled.frag, pass0.vert, meta.json}` plus `shaders/<design>/MANIFEST.md` |
| Unicorn project JSON | `unicorn/<design>/*.json`. These load directly in the Unicorn web runtime (`data-us-project-src`). |
| High-res depth | `depth/img-1491_*`, `depth/img-1216_*` (2048 px; 16-bit gray + packed RGB + preview); regenerate with `depth/make_depth.py` |

## Global rules
- **Matte only.** No specular highlights, gloss, chrome or wet looks. Fine animated grain (2–3%) on every dark
  surface. One key light from the upper right on every screen.
- **Colour.** Void `#04060C`, panel `#070A14`, frost `#EEF3FF` (the user), Gemini blue `#4C8DFF` (Gemini acting),
  hot `#B4CEFF`, iris `#9A7CF6` (gradient tail only), mic red `#E5484D` / `#A3161B`. Thin-film iridescence
  `#7AA7FF → #B48CFF → #FF8FCF → #FFC27A → #8CF5D2` means **"this value is changing right now."**
- **Type.** Numerals and words: Google Sans Flex 500. Labels: Geist Mono 500, 9–11px caps, +0.14em.
- **Almost no text.** Gemini talks by voice. It shows guidance by moving things, never with chips, arrows or
  captions.
- **One focal point at a time.** Gemini changes one thing at a time, visibly, about 900ms per change.
- **Interruptible.** Touching a control Gemini is moving takes over; Gemini yields. ⌘Z or a shake undoes
  Gemini's last change.

## iPhone camera (393 × 852 design frame; scale to device)
- **Viewfinder** x 8, y 8, 377×584, radius 30. Inside it: a 6px live dot top-left, `4:3` bottom-right (mono 9px
  55%), and the last-shot thumbnail 40×40 radius 10 at (20, 540) with a 1px frost 30% border.
- **Guidance = the viewfinder's own border** (shader `06-viewfinder-edge-guide`). A Gemini-blue inner edge glow on
  the side to move or tilt toward, with strength ∝ error and a shimmer travelling along the edge. Two edges plus
  a corner for diagonals; opposite corners for roll. On target: one full-perimeter pulse.
- **Row 1** y 600–684: drums ISO | SS | EV, 131px cells, hairlines `rgba(180,206,255,.12)`. Value 30px centred;
  ±1 neighbours are WHOLE numerals at ~15px and 35% (never clipped); ±2 hidden. Momentum + snap with overshoot
  (spring 300/28), a haptic per detent. While a value changes (Gemini or the user), the cell wears the
  iridescent inner glow (`05-cell-iridescent-glow`), which fades out over 420ms. Native recommendation: build
  the drums as SwiftUI views (horizontal snapping scroll + scale/opacity by distance); the Unicorn drum shaders
  (`10–15`) are the visual reference.
- **Ruler** y 684–728: ticks every 6px, majors every 30px, a bright centre tick, value `1.2 m` at the right.
- **Keys** centred on y 790, same height 72 and radius 36: mic `x 16–136` (`08-key-mic`, matte red;
  listening = glyph left + live waveform + red inner glow) and shutter `x 148–377` (`09-key-shutter-lantern`,
  frosted lantern: milky inner glow brightest low-left, debossed "+"; Ready = brighter + diffuse halo;
  press = 0.96).
- **Capture → depth**: the frame freezes, a white flash 0→.6→0 over 180ms, then the depth scan. A thin
  `#B4CEFF` contour with a blue glow sweeps near→far over ~1.6s, passed areas get a faint blue tint, and the
  panel sits at 30% except the shutter (progress). Then the photo lifts into a gentle depth parallax, the
  border pulses once, and the shutter shows the debossed check.
- **Opening = camera wakes up** (zero taps):
  - 0–450ms: "wordmark" at 40%, in and out.
  - 300–900ms: 6-blade matte aperture iris opens.
  - 500–1000ms: hairlines draw.
  - 560–1120ms: drums roll in.
  - 700 / 780 / 860ms: mic, shutter and thumbnail rise 12px and fade in.
  - 1100–1660ms: one blue sweep around the border becomes the live dot.

## Shader index
- `shaders/components/MANIFEST.md`: 20 UI component treatments (orb variants, mic/shutter keys, cell glow,
  edge guide, drums).
- `shaders/phone-demos/MANIFEST.md`: depth scan, edge guide (scene), iris, wake sweep. *(export pending)*
- `shaders/light-lab/MANIFEST.md`: 4 background light shaders (key light, softbox array, caustics,
  flare + bokeh). *(export pending)*

### Porting Unicorn GLSL to Apple platforms
- Unicorn shaders are GLSL ES 3.00. `pass0.compiled.frag` is the exact running shader, with control values
  baked in as literals. `pass0.frag` is the readable `shadeShape(ShapeSample)` source with named `uAi*`
  uniforms: port from this one and keep the uniform names as Swift parameters.
- **Time base:** `uTime` = 60 × Speed per second; every layer uses Speed 0.5, so `uTime = 30 × seconds`.
- **Shape treatments** (keys, glows, edge guide) map to SwiftUI `Shape` + `.layerEffect` / `.colorEffect`
  with `[[stitchable]]` Metal functions (pass size, time and controls as `float` args), driven by
  `TimelineView(.animation)`.
- **Full-frame / depth effects** (depth scan, relight, relief, parallax) map to an `MTKView` or a SwiftUI
  `.layerEffect` on the image with the depth as a second `Shader.Argument.image`. Use the 16-bit gray depth
  (`R16Unorm`) natively; the packed RGB version exists only for WebGL.
- **GLSL → MSL:** `vecN→floatN`, `texture(s,uv)→t.sample(s,uv)`, `mod→fmod` (watch negatives), and flip v
  (GL's UV origin is bottom-left, Metal's is top-left).
- **Fast path** for the opening and onboarding: the Unicorn JSON in `unicorn/` runs as-is in a `WKWebView`
  with the Unicorn runtime. Use it only where a native port isn't worth it yet.

## Brand (in progress)
The user liked the **celestial maximalist aesthetic**: engraved star-chart linework, a navy → blue → iris sky,
an iridescent halo, one amber star. They rejected its name, its seal icons, and everything vintage. The
working name is **Northlight**. The landing page and icons are on
Paper `p-E-0`. Brand surfaces may be maximalist; the product UI stays quiet and matte.
