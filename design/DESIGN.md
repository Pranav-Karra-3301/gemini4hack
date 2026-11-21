# Coach — design spec (Coach Cam + 3D Coach)

Source of truth: Paper file "Coach – mockups (gemini4hack)", page "Coach – mockups"
(https://app.paper.design/file/01M7ZEJ61SXCRBKXGD08J87QCJ). PNGs (2x) are in `design/mocks/`.
All numbers below are CSS px at 1x and match the artboards.

---

## 1. What we took from the references

From VWFNDR MBL, Moment Pro Camera (I and II) and (Not Boring) Camera:

1. **The camera feels like hardware, not an app.** Controls have mass. Not Boring uses lit, clicky dials with haptics and sound on every detent. VWFNDR keeps exposure, focus and presets on the same panel as the shutter. We use one physical-looking shutter, glass buttons with an edge highlight, and haptic ticks on every coach action.
2. **Restraint and a full-bleed viewfinder.** Moment's Zen mode and VWFNDR's "intentional photography" keep the frame almost empty. Chrome only appears when it carries information. We show no panels and no paragraphs.
3. **Numbers in a mono face, read like instruments.** Shutter, ISO, EV and zoom sit in a tight mono readout, like a camera top-plate LCD. We use Geist Mono for every numeral and caps label, and Inter Tight for words.
4. **One accent colour, used with meaning.** None of the three apps uses colour for decoration. Our rule: **amber (safelight) means the coach is speaking or acting; paper-white means you.**
5. **Motion is physical and interruptible.** Dials snap to detents, settings roll like an odometer, transitions spring and can be grabbed mid-flight. Nothing fades in without a direction.

We took principles only. No assets, logos or layouts were copied.

## 2. Brief

- **Mood:** *darkroom*: developer-tray black, safelight amber, fibre-paper white, anodized graphite.
- **Rule:** amber = coach, white = user. Coach glyphs, coach captions, coach-set modes, the ready glow and focus markers are amber. User speech ("oh, that's good"), user-set modes and neutral controls are paper-white.
- **Icon-led:** each guidance state is one big glyph (arrow, rings, brackets) that is readable from arm's length. Text appears only as a short caption (voice on) or a one-line note (3D focus).
- **Touch targets:** at least 56px. The shutter is 84px. Top-bar buttons are 44px visual with a 56px hit area (`::before` inset -6px).

## 3. Tokens

```css
:root {
  /* colour */
  --ink: #08080A;                 /* ground, letterbox, 3D void */
  --graphite: #17171A;            /* solid surfaces, thumb placeholder */
  --paper: #F5F3EF;               /* primary text / icons (the user) */
  --paper-62: rgba(245,243,239,.62); /* inactive mode labels */
  --paper-55: rgba(245,243,239,.55); /* mono sub-labels */
  --paper-45: rgba(245,243,239,.45); /* caption: not-yet-spoken words */
  --safelight: #FFA53D;           /* THE accent: the coach */
  --safelight-hot: #FFD08A;       /* glow core, waveform peak */
  --safelight-grad: linear-gradient(180deg, #FFB65C 0%, #FFA53D 100%);       /* primary buttons */
  --safelight-orb: radial-gradient(circle at 50% 30%, #FFE3B8 0%, #FFC06A 42%, #FFA53D 100%); /* big round CTAs, ready shutter */
  --signal: #FF4D3D;              /* offline / error only */

  /* glass */
  --glass-fill: rgba(22,22,26,.46);
  --glass-fill-strong: rgba(22,22,26,.55); /* captions, notes, cards */
  --glass-fill-fallback: rgba(22,22,26,.78); /* when backdrop-filter unsupported */
  --glass-blur: blur(24px) saturate(1.4);
  --glass-edge: 1px solid rgba(255,255,255,.12);
  --glass-edge-coach: 1px solid rgba(255,165,61,.40); /* coach-authored cards/chips */

  /* shadows / glows */
  --shadow-control: 0 8px 28px rgba(0,0,0,.35);
  --shadow-card: 0 20px 50px rgba(0,0,0,.45);
  --shadow-photo: 0 24px 60px rgba(0,0,0,.5);
  --glow-dot: 0 0 10px rgba(255,165,61,.9);
  --glow-chip: 0 0 24px rgba(255,165,61,.25);
  --glow-ready: 0 0 0 8px rgba(255,165,61,.16), 0 0 36px 6px rgba(255,165,61,.55);
  --glow-voice: 0 0 0 6px rgba(255,165,61,.12), 0 0 22px rgba(255,165,61,.45);
  --glow-primary: inset 0 1px 0 rgba(255,255,255,.35), 0 12px 36px rgba(255,165,61,.35);
  --glyph-shadow: drop-shadow(0 2px 14px rgba(0,0,0,.5));   /* arrows, rings on photos */
  --bracket-glow: drop-shadow(0 0 10px rgba(255,165,61,.6));

  /* scrims */
  --scrim-top: linear-gradient(180deg, rgba(8,8,10,.55) 0%, rgba(8,8,10,0) 100%);           /* h 150 phone / 140 laptop */
  --scrim-bottom: linear-gradient(180deg, rgba(8,8,10,0) 0%, rgba(8,8,10,.6) 38%, rgba(8,8,10,.86) 100%); /* h 352 phone / 280 laptop */
  --void-vignette: radial-gradient(ellipse at 50% 48%, rgba(8,8,10,0) 40%, rgba(8,8,10,.6) 72%, rgba(8,8,10,.96) 100%); /* 3D */

  /* type */
  --font-sans: "Inter Tight", system-ui, sans-serif;
  --font-mono: "Geist Mono", ui-monospace, monospace;
  --text-label: 500 11px/1 var(--font-mono);  /* caps, letter-spacing .14–.16em */
  --text-mode: 500 12px/1 var(--font-mono);   /* caps, .14em */
  --text-readout: 500 12px/1 var(--font-mono);/* .02em, tabular */
  --text-numeral: 600 18px/1 var(--font-mono);/* score ring numerals */
  --text-chip: 600 17px/1 var(--font-sans);   /* -.01em */
  --text-caption: 500 19px/24px var(--font-sans); /* -.01em; laptop 22/28 */
  --text-note: 500 21px/27px var(--font-sans);    /* -.015em; phone 19/25 */
  --text-button: 600 19px/1 var(--font-sans);     /* primary 20–21px */
  --text-title: 600 40px/1 var(--font-sans);      /* -.025em; phone 34px */
  --text-hero: 600 30px/1 var(--font-sans);       /* "Tap to start", -.02em */
  --tracking-wordmark: .28em;                     /* "COACH CAM", "3D COACH" mono 12 */

  /* spacing (4pt) */
  --s-1: 4px; --s-2: 8px; --s-3: 12px; --s-4: 16px; --s-5: 24px; --s-6: 32px; --s-7: 48px;
  --edge-phone: 16px;  --edge-laptop: 32px;
  --safe-top-phone: 60px;  /* first HUD row y on 393×852 */

  /* radii */
  --r-sm: 12px; --r-md: 20px; --r-lg: 28px; --r-thumb: 16px; --r-sample: 18px; --r-full: 999px;

  /* control sizes */
  --hit-min: 56px;
  --shutter: 84px; --shutter-ring: 3px; --shutter-core: 68px;
  --side-btn: 56px;        /* last-shot thumb, voice toggle */
  --top-btn: 44px;         /* flip, back, new photo (56 hit) */
  --pill-h: 32px;          /* engine pill, readout */
  --chip-h: 44px;          /* intent chip */
  --cta-h: 64px;           /* Save/Share, phone Reframe */
  --cta-h-lg: 68px;        /* laptop Reframe / Keep this angle */
  --start-btn: 184px; --start-core: 136px;
  --upload-btn: 104px;

  /* motion */
  --ease-out: cubic-bezier(.22, 1, .36, 1);
  --ease-in: cubic-bezier(.55, 0, 1, .45);
  --ease-in-out: cubic-bezier(.65, 0, .35, 1);
  --ease-pop: cubic-bezier(.34, 1.56, .64, 1);   /* ~10% overshoot */
  --dur-instant: 90ms; --dur-fast: 160ms; --dur-base: 240ms; --dur-slow: 420ms;
  --dur-glide: 700ms; --dur-flight: 1400ms;
  /* JS springs (stiffness/damping/mass): snappy 520/34/1, pop 380/22/1, lift 220/26/1 */
}
```

Glass recipe used by all frosted controls:
`background: var(--glass-fill); backdrop-filter: var(--glass-blur); -webkit-backdrop-filter: var(--glass-blur); border: var(--glass-edge);`
Fallback: use `@supports not (backdrop-filter: blur(1px))` and set `background: var(--glass-fill-fallback)`.

## 4. Layouts

### 4.1 Coach Cam, phone (393×852, full-bleed, no status bar)
| Layer | Geometry |
|---|---|
| Viewfinder | `object-fit: cover`, inset 0 |
| Top scrim / bottom scrim | 0–150 / 500–852 |
| Top HUD row | top 60, left/right 16, h 44, `space-between`: engine pill · readout pill · flip (44) |
| Intent chip | top 120, centred |
| Guidance zone | y 120–600. Glyphs avoid faces (keep the upper-middle third for edge arrows) |
| Caption / reaction chip | top 560, centred, max-w 337 |
| Mode selector | top 636, centred row, gap 22 |
| Control row | top 700, left/right 36, h 84, `space-between`: last shot 56 · shutter 84 · voice 56 |

### 4.2 Coach Cam, laptop (1440×900)
Same components at the same sizes. HUD top 28, left/right 32. Mode selector top 732. Control row width 360, centred, top 784. Caption top 650, max-w 640, text 22/28. Top scrim h 140, bottom scrim from y 620. Keyboard: Space = shutter, V = voice, F = flip.

### 4.3 3D Coach, laptop (1440×900)
Splat canvas inset 0, with `--void-vignette` over it. Top bar: top 24, left/right 32 (back 44 + "3D COACH" wordmark; "+" new photo 44 at right). Score panel: right 32, top 96. Bottom bar: top 796, h 72; hint "DRAG · ORBIT" mono 11 at left; Reframe button centred.

### 4.4 3D Coach, phone (393×852)
Top bar: top 60, left/right 16. Score panel: right 16, top 116. Focus note: left/right 16, top 618. Reframe button centred, top 752 (h 64). Reframe preview: note at top 672, actions at top 752 (64 round "Original" plus a flex-1 primary button).

## 5. Components

**Shutter** (84): a 3px ring and a 5px gap around a 68px core.
- *Idle:* ring `--paper` at 95%. Core `radial-gradient(circle at 50% 30%, #FFF 0%, #ECE9E3 60%, #D9D5CE 100%)` with `inset 0 -2px 4px rgba(0,0,0,.12)`. Shadow `--shadow-control`.
- *Ready:* ring `--safelight`, core `--safelight-orb` with `inset 0 -2px 6px rgba(120,50,0,.25)`, shadow `--glow-ready`.
- *Pressed:* core scales to .90.
- *Busy* (saving): ring at 40% with a 2px safelight arc spinning, 900ms linear.
- *Disabled* (no camera): 40% opacity.

**Guidance arrow** (`move-left|right|up|down`, plus `tilt-*` and `pan-*` using the same glyph): SVG 180×120 with three chevrons, each 44×88. Stroke 11 (phone) or 14 (laptop, 180×240 up-variant), round caps and joins, `--safelight`. Chevron opacities are 1 / .55 / .22, offset 48px, with the brightest chevron at the leading edge. Filter `--glyph-shadow`. Place it 24px from the edge it points to. Vertical arrows are centred horizontally, top 118 on laptop. Pair it with an **edge glow** on the same edge: a 6×380 bar (laptop 4×500) in `--safelight` with `box-shadow: 0 0 40px 14px rgba(255,165,61,.36)`, half off-canvas.

**Rings (get closer / step back):** three concentric circles centred on the subject's bounding box. Radii 108/138/166, strokes 5/3/2, opacities 1/.38/.16, `--safelight`, with `--glyph-shadow`. There are no tick marks: ticks read as a gun-sight.

**Ready brackets:** four 36px corner arcs with radius 12, stroke 4, `--safelight`, filter `--bracket-glow`. On phone, inset 20px from the frame edges between y 124 and y 600.

**Mode selector:** `PHOTO · PORTRAIT · NIGHT · MACRO`, `--text-mode` caps, gap 22. Inactive labels are `--paper-62`. Active is `--paper` when the user picked it, or `--safelight` when the coach picked it. A 4px dot sits 6px under the active label: paper or safelight, with `--glow-dot` when it is safelight.

**Readout pill:** h 32, padding 0 14, `--text-readout`, values separated by a `·` at 40% opacity. Show at most three values: zoom (`1×`), ISO (`ISO 125`) and either EV (`+0.3`) or aperture-look (`ƒ2.8`). A value the coach just changed shows in safelight for 600ms.

**Engine / status dot:** pill h 32, padding 0 12 0 10, 8px dot, label `LIVE` (mono 11, .14em).
- Dot colours: idle `--paper`; watching or thinking `--safelight` with `0 0 0 3px rgba(255,165,61,.22), --glow-dot`; offline `--signal` with the label `OFFLINE`.
- Long-press shows the engine name (`GEMINI LIVE`, `OPENROUTER`).

**Voice toggle** (56):
- *Off:* glass, 24px mic icon in paper.
- *On, listening:* fill `rgba(255,165,61,.16)`, 1.5px `--safelight` border, shadow `--glow-voice`, and six 3px bars at 4px height.
- *On, speaking:* the bars, gap 3 and radius 2, take heights of 6–26px from TTS band RMS. The centre-right bar uses `--safelight-hot`.

**Intent chip:** h 44, padding 0 18 0 6, gap 10, glass with `--glass-edge-coach` and `--glow-chip`. A 32px safelight disc holds a 22px ink glyph, followed by `--text-chip` text.
- Text is either "Portrait on" (when the coach switched mode) or the intent name.
- Glyph set: portrait (one bust), group (three busts), landscape (mountain), night (moon), macro (flower), food (fork), pet (paw).

**Caption** (voice on): glass `--glass-fill-strong`, radius 20, padding 12 18 12 14, an 8px safelight dot, `--text-caption`. Keep it to one line of 7 words or fewer. Words not yet spoken are `--paper-45`; spoken words are `--paper`.

**Reaction chip** (the user's voice, so it is white): glass, radius full, padding 10 16 10 12, an 18px paper waveform glyph, and the quote in italic `--text-chip` weight 500 with curly quotes.

**Last-shot thumb:** 56, radius 16, 2px paper border at 90%, `0 6px 18px rgba(0,0,0,.35)`.

**Review:**
- Photo card: left/right 12, top 60, h 580, radius 28, `--shadow-photo`.
- Close button: glass 44 at (24, 72).
- Meta row: top 660, mono 12 .08em at 60%, last item `COACHED` in safelight.
- Actions: top 704, h 64, gap 12, radius 20. Share is `rgba(245,243,239,.08)` with a .14 border. Save is primary: `--safelight-grad`, ink text, `--glow-primary`. Save sits on the right, under the thumb.

**Start:**
- Wordmark: mono 12 with .28em tracking at 70%, top 72.
- Start button: 184 glass with `0 0 80px rgba(255,165,61,.22)`, holding a 136 `--safelight-orb` core with a 56px ink aperture glyph. The whole control sits at top 300, gap 28.
- Label: "Tap to start" in `--text-hero`. Sub-label "CAMERA · MIC · COACH" in mono 11 .16em.
- Footer: "GEMINI · READY" with a 6px dot at top 780.
- Background: the camera preview at 55% opacity, blurred, under `radial-gradient(circle at 50% 46%, rgba(8,8,10,.15), rgba(8,8,10,.7) 70%, rgba(8,8,10,.92))`.

**Score ring** (68): this is a component, not a chart.
- Track: r 25, 4px stroke, paper 14%. Score arc: same circle in `--safelight`, round cap, starting at 12 o'clock, `dasharray = (score/5)·157 157`.
- Confidence: track r 31, 1.5px, paper 12%. Confidence arc: paper 60%, `dasharray = conf·195 195`.
- Centre: numeral in `--text-numeral` with one decimal.
- Under the ring: a 14px icon (sun = lighting, 3×3 grid = composition) and mono 11 confidence `72%`. During reframe this becomes the delta `+1.6` in safelight.
- Two rings sit in one glass panel: padding 14 18, gap 18, radius 20.

**Marker dot** (56 hit), placed at the object's projected 3D anchor:
- *Focus:* a 44px halo ring (1.5px `rgba(255,165,61,.6)`, `0 0 24px rgba(255,165,61,.35)`) around a 20px `--safelight` core with a 3px paper border and `0 2px 10px rgba(0,0,0,.4)`.
- *Remove:* a 32px disc of `rgba(8,8,10,.55)` with blur 12, a 2px paper border, and a 12×2.5 paper minus.
- No labels at rest. Hover or long-press shows the one-line note.
- Markers on objects behind other geometry drop to 50% opacity.

**Focus note:** glass `--glass-fill-strong` with `--glass-edge-coach`, radius 20, padding 18 20 20, gap 10. Contents: a `FOCUS` or `REMOVE` mono 11 .16em label in safelight (REMOVE in paper) with an 8px dot, then `--text-note` text of one sentence, 12 words or fewer. Laptop: 296 wide, 24px right of the object's screen bbox, clamped 32px from the viewport edges. Phone: left/right 16, top 618.

**Reframe button:** h 68 (phone 64), padding 0 32 0 24, gap 12, radius full, `--safelight-grad`, `--glow-primary`. A 26px ink "orbit + camera" icon, then "Reframe" in 21px weight 600 ink.

**Reframe preview:**
- Suggested-frame brackets: corners 56 (phone 40), radius 16 (12), stroke 4, `--bracket-glow`. Laptop frame 900×562 centred under the top bar; phone 345×400.
- Note pill: glass, 8px dot, 19px text.
- Actions: "Original" (glass, undo icon) and "Keep this angle" (primary, check icon).

**Upload / empty:**
- Background: `--ink` with `radial-gradient(ellipse at 50% 38%, rgba(255,165,61,.10), transparent 55%)`.
- Drop zone (laptop): 640×380, radius 28, `1.5px dashed rgba(245,243,239,.22)`, fill `rgba(245,243,239,.025)`. Contents: a 104 `--safelight-orb` upload button with a 40px ink icon, the title "Drop a photo" (phone: "Pick a photo", no drop zone), and the sub-label "IT BECOMES A SCENE YOU CAN WALK AROUND".
- Samples: label "OR TRY ONE", thumbs 112 (phone 107, 3×2 grid, gap 12), radius 18, `outline: 1px solid rgba(255,255,255,.1)` and `0 10px 28px rgba(0,0,0,.45)`. Hover or focus: `outline: 2px solid var(--safelight)` plus `0 0 0 5px rgba(255,165,61,.18)`.

## 6. Motion

Global: every animation is interruptible, and a new event retargets from the current value. Never queue animations. With `prefers-reduced-motion: reduce`, loops become static, travel becomes a 160ms crossfade, and the flight becomes a 200ms crossfade.

| Event | What animates | Timing |
|---|---|---|
| **Move arrow in** | glyph opacity 0→1 and translate 24px→0 along its direction; edge glow opacity 0→1 | 240ms `--ease-out` |
| Arrow idle | chevron "chase": opacity steps through 1/.55/.22 in sequence, stagger 120ms, period 900ms; whole glyph nudges 10px along its direction and back | 900ms `--ease-in-out`, infinite |
| Edge glow idle | opacity .6↔1 | 1800ms `--ease-in-out`, infinite |
| **Move arrow out** (target reached) | glyph travels a further 16px and fades to 0; glow fades | 160ms `--ease-in` / 240ms |
| Direction change | out (160ms) then in (240ms), no overlap | – |
| Guidance hysteresis | show only after the direction is stable for 400ms; keep it at least 1200ms; hide 300ms after on-target | logic |
| **Rings: get closer** | each ring scales 1.25→.85 while opacity goes 0→peak→0; 3 rings staggered 300ms (reverse scale for "step back") | 1200ms `--ease-in-out`, infinite |
| **Mode switch** (coach) | active dot slides to the new label (translateX); label colour crossfades; intent chip drops in (translateY -12→0, opacity) and holds 2000ms; viewfinder blurs 4px→0 over 120ms to hide the camera reconfiguring; changed readout numerals roll like an odometer (translateY 100%→0) and stay safelight for 600ms; haptic light | dot 420ms `--ease-pop`, chip in 240ms `--ease-pop` / out 160ms, numerals 240ms `--ease-out` |
| **Ready glow** | shutter ring and core crossfade to ready; `--glow-ready` grows from 0 with overshoot; brackets draw in (stroke-dashoffset 1→0) while sliding 8px→0 inward; haptic medium | ring 240ms, glow 420ms `--ease-pop`, brackets 420ms `--ease-out` |
| Ready idle | halo spread 6↔10px | 1600ms `--ease-in-out`, infinite |
| **Reaction wash: positive** ("oh that's good", laugh) | full-frame overlay `radial-gradient(ellipse at 50% 100%, rgba(255,165,61,.22), transparent 70%)`, opacity 0→1 for 160ms, hold 200ms, then →0 over 700ms; reaction chip pops (scale .92→1) and auto-dismisses after 1600ms; then triggers Ready | `--ease-out`, chip 240ms `--ease-pop` |
| **Reaction wash: negative** (sigh, "ugh") | overlay `rgba(8,8,10,.25)`, 160ms in / 500ms out; the current guidance glyph exits; the intent chip flips (rotateX 90°→0) to the new plan's glyph | 160 / 500ms; flip 240ms `--ease-out` |
| **Voice: speaking** | waveform bar heights = lerp(prev, bandRMS, .35) every frame; button border and ring fade in; caption enters (translateY 8→0, opacity); words go `--paper-45`→`--paper` on TTS word boundaries (fallback 330ms/word); caption exits 1200ms after speech ends | ring 160ms; caption 240ms `--ease-out`; exit 240ms |
| **Shutter press** | core scale 1→.9 on press, spring back on release; white flash overlay 0→.6→0; the captured frame shrinks into the last-shot thumb (FLIP) | 90ms `--ease-out`; release 240ms `--ease-pop`; flash 180ms; FLIP 420ms `--ease-in-out` |
| Review open | photo FLIPs from full-bleed to the card (radius 0→28); actions rise 16px→0 and fade in after a 120ms delay | 420ms `--ease-out`; 240ms |
| **3D focus** (tap marker) | other markers →.25 (160ms). Scene brightness 1→.3, saturation 1→.6, depth-of-field blur 0→6px. The focused object's splats move toward the camera by 6% of their distance and scale ×1.06, using spring 220/26 (it settles at ~700ms). A warm key light (`rgba(255,196,128,.13)` radial, centred on the object) fades in. The note enters after 280ms (translateX 12→0, or translateY on phone). Implement the darkening by depth, not as a 2D mask: splats outside the object's depth band dim in proportion to their distance from it. No outline, no cutout. | 560ms `--ease-in-out` (scene), 420ms (light), 240ms `--ease-out` (note) |
| 3D unfocus (tap empty space, Esc) | reverse | 420ms `--ease-in-out` |
| **Reframe flight** | markers fade out (160ms). The camera position follows an arc from the current pose to the target, with its apex raised by 4% of the scene radius; orientation uses slerp. The composition ring sweeps to its new value over the last 600ms with an odometer numeral. Brackets draw in at 80% progress (420ms). The note pill enters at the end (240ms). "Original" flies back. Dragging during the flight cancels it and keeps the current pose (no snap). | flight 1400ms `--ease-in-out`; back 900ms |
| Upload hover | drop-zone border →`rgba(255,165,61,.7)`, fill →`rgba(255,165,61,.06)`, upload button scale 1.04 | 160ms `--ease-out` |
| Upload processing → scene | a 2px safelight progress ring around the upload button with a mono % below it; on ready, splats fade in from near to far (sorted by depth) | 900ms `--ease-out` |

Haptics (where available): light on mode switch, numeral roll and marker tap; medium on Ready; rigid on shutter. On the web, Android uses `navigator.vibrate(10|16|24)`.

## 7. Accessibility
- Every guidance glyph has a matching `aria-live="polite"` string ("Move left", "Get closer", "Ready"), throttled to one per 1.5s.
- Captions mirror TTS in full in an offscreen live region.
- Text contrast: paper on glass over a scrim is at least 7:1. Mono labels at 55% or more over `--ink` meet 4.5:1. Don't place text directly on the photo without glass or a scrim.
- Hit areas are at least 56. Focus ring: `outline: 2px solid var(--safelight); outline-offset: 3px`.

## 8. Artboards → files (`design/mocks/`, 2x PNG)
| Artboard | File |
|---|---|
| Phone · Coach Cam · a Start | `cam-phone-a-start.png` |
| Phone · Coach Cam · b Move left | `cam-phone-b-move-left.png` |
| Phone · Coach Cam · c Get closer + Portrait | `cam-phone-c-closer-portrait.png` |
| Phone · Coach Cam · d Voice on | `cam-phone-d-voice-on.png` |
| Phone · Coach Cam · e Ready | `cam-phone-e-ready.png` |
| Phone · Coach Cam · f Review | `cam-phone-f-review.png` |
| Laptop · Coach Cam · Tilt up (arrow) | `cam-laptop-arrow-tilt-up.png` |
| Laptop · Coach Cam · Voice on | `cam-laptop-voice-on.png` |
| 3D Coach · Laptop · a Scene + markers | `3d-laptop-a-scene-markers.png` |
| 3D Coach · Laptop · b Focus | `3d-laptop-b-focus.png` |
| 3D Coach · Laptop · c Reframe preview | `3d-laptop-c-reframe.png` |
| 3D Coach · Laptop · d Upload | `3d-laptop-d-upload.png` |
| 3D Coach · Phone · a–d | `3d-phone-{a-scene-markers,b-focus,c-reframe,d-upload}.png` |

Notes:
- The laptop arrow state shows **tilt up** (less table, more sea) because that frame's subjects are already right-of-centre. The glyph and edge glow are the same component as "move left", rotated.
- Photos in the mockups are compressed copies of `web/public/samples/*`. The 3D reframe frame is a real orbit render from `/tmp/lc_qa`, including splat holes. The focus state is a 2D stand-in for the depth effect described in §6.
