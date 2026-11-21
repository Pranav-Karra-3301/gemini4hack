# Heliocam landing v4: iPhone only, LiDAR first, grand light

The Mac app is gone. Heliocam is one iPhone app: a Gemini 4 agent inside the camera that reads the scene in 3D
(LiDAR, on device), moves the real camera controls and tells you where to stand. Type tokens and the grid still
come from `DESIGN_TYPE.md`. This file overrides its palette and page structure.

## The message

**Image analysis describes a picture. Heliocam takes one.** This hackathon bars image analysis and processing
apps, so every section shows Gemini **acting** on a **3D scene**: function calls that turn real camera hardware,
directions to the photographer, an agent loop that runs before the photo exists. Pixels in, pixels out must
never be the story. Lead with depth and points, not a flat 2D photo.

## Palette (dark, lit, never white)

| Role | Value |
|---|---|
| Ground (page) | night ink `#05060B` |
| Deep sky | indigo `#0B1030` → horizon `#1B2A66` |
| Sunlight (the light source) | core `#FFF4E0`, warm `#FFC37A`, ember `#FF8A3D` |
| Heliotrope petals (the only violet) | shadow `#3B2A8C`, body `#6E4BD8`, lit `#9A7CF6`, rim `#C9B8FF`; floret eye `#F6E7B0` |
| Gemini blue (only what the AI or the sensor does: LiDAR dots, tool calls, boxes) | `#4C8DFF`, glow `#7FB2FF` |
| Text | frost `#EEF3FF`, muted `rgba(238,243,255,.68)`, faint `.45` |
| Mic | red `#E5484D`, only on the mic |

Retired: the big white halftone dot fields (the user found the page "too white" and the halftone flowers didn't
read as flowers). Grain is fine as a faint texture (≤ 4% opacity).

## Light

- Every section has **one visible light source** that lights its content: the sun, the LiDAR emitter, a screen.
  Light is additive and atmospheric: god rays, soft bloom, motes drifting in the beams.
- Matte and diffuse, never glossy: no specular highlights, chrome or wet looks. Petals glow with
  translucency (light through them), not shine.
- Grand means scale and slowness: big type, full-bleed WebGL, slow eased camera moves, deep vignettes.

## Motion and performance

- Modules pause when off screen (IntersectionObserver) and render one still frame under
  `prefers-reduced-motion: reduce`.
- Device pixel ratio capped at 1.75. Aim for 60 fps on an M1 laptop. No per-frame allocations.
- Every module exports `mountX(el) → { destroy() }`, owns its resize, and has a `demo.html` beside it for
  isolated work (served by Vite at `/src/<module>/demo.html`).

## Type additions

- `Google Sans Code` is allowed **only** inside code-like chips: function calls, JSON, model ids, numbers
  in traces. Everything else stays Google Sans Flex.

## Page structure (v4)

0. **Hero**: a detailed 3D heliotrope that assembles out of LiDAR points and turns toward a sun you move.
1. **Not image analysis**: the thesis line, with three contrasts.
2. **01 Sees in 3D first**: a real scene as a LiDAR point cloud that settles into the photo.
3. **02 Coaches you live**: the phone viewfinder with a live agent trace of Gemini's function calls.
4. **03 Depth and regions**: what happens the moment you shoot.
5. **04 Edits with you**: the edit → render → look → fix loop, on the phone.
6. **05 Just talk**: voice.
7. **Under the hood**: each stage, what runs on device and what Gemini does, with real model ids.
8. **Footer**: an animated sunrise over a heliotrope field, the wordmark in raking light.
