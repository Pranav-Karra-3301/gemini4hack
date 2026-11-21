# Coach v2 — "Instrument" direction (Gemini blue)

Supersedes the v1 guidance UI (arrows, rings, intent chips, captions). Source of truth for Paper
page "v2 · Camera (iPhone)" and the Unicorn phone demos.

## Principles (inspired by VWFNDR MBL and dial-style pro cameras; nothing copied)

1. **One focus point per screen.** Exactly one thing is lit at a time: the Gemini focus point, the
   dial Gemini is turning, the depth sweep, or the shutter disc. Everything else is quiet.
2. **Almost no text.** No sentences, captions, chips, or suggestions on screen. Gemini talks by
   voice; on screen it only *moves things*. Text is limited to numerals and 9–10px mono labels.
3. **Instruments, not app chrome.** Controls live in a hairline grid under the viewfinder, not
   floating over the photo. Values are big numerals; neighbouring values are ghosted like a drum
   you can spin. A tick ruler for focus.
4. **Blue = Gemini acting. Frost = you.** A value Gemini is setting turns blue and rolls; the
   rest stay frost. The focus point and the depth sweep are blue.
5. **Texture.** Fine film grain on dark surfaces (2–4%), hairlines, a lit lens-like shutter disc.
   One saturated colour moment per screen: the disc (blue → iris).

## Tokens

| Role | Value |
|---|---|
| ground (void) | `#04060C` + grain 3% |
| panel | `#070A14` |
| hairline | `rgba(180,206,255,.12)` |
| frost (user, numerals) | `#EEF3FF` |
| label | frost 45% |
| ghost value | frost 18–22% |
| gemini (coach) | `#4C8DFF` |
| gemini-hot (glow core) | `#B4CEFF` |
| iris (gradient tail only) | `#9A7CF6` |
| signal (error only) | `#FF5A5F` |
| disc fill | `radial-gradient(circle at 34% 28%, #E4EEFF 0%, #9CC0FF 22%, #4C8DFF 55%, #5F6FF4 80%, #9A7CF6 100%)` |
| disc inner | `inset 0 -8px 18px rgba(12,18,70,.45), inset 0 2px 2px rgba(255,255,255,.5)` |
| disc ready glow | `0 0 0 10px rgba(76,141,255,.14), 0 0 64px rgba(76,141,255,.55)` |
| focus point glow | `drop-shadow(0 0 10px rgba(76,141,255,.9))` |

Type: numerals **Google Sans Flex** 500, `-0.02em`, tabular (cell values 34px, ruler value 22px).
Labels **Geist Mono** 500, 9–10px caps, `+0.14em`. Wordmark "coach" Google Sans Flex 500 17px.

Motion: ease-out `cubic-bezier(.2,.8,.2,1)`, ease-pop `cubic-bezier(.34,1.56,.64,1)`;
160 / 240 / 420 / 900 ms. Drum roll 240ms per detent. Interruptible, never queued.

## iPhone (393 × 852)

- **Viewfinder**: x 8, y 8, 377 × 584, radius 30, photo `cover`, soft inner vignette. Inside, top-left:
  a 6px blue dot (Gemini live). Bottom-right: `4:3` mono 9px at 55%. Nothing else.
- **Instrument panel** y 600 → 852, background panel + grain, 1px hairline grid:
  - Row 1 (h 96): three drum cells `ISO | SS | EV`. Label top-left (12px inset). Value 34px centred,
    ghost neighbours left/right clipped by the cell edges.
  - Row 2 (h 156): left (2 cols) **focus ruler**: ticks every 6px, major every 30px, one bright
    centre tick; value `1.2 m` 22px above; tiny `0.3 · 1 · ∞` marks. Right (1 col): **shutter disc**
    116px with a 22px × 2px void "+" crosshair.
- **Gemini focus point**: one 28px "+" (1.5px strokes) in gemini-hot with the blue glow, placed where
  the subject should be. The user moves the phone until the subject sits under it. On alignment it
  contracts to an 8px dot (240ms ease-pop) and the disc gets the ready glow.
- **Gemini turning a dial**: the cell's value + ghosts roll one detent at a time, value in gemini blue,
  a 2px blue bar along the cell's top edge. One cell at a time.
- **Voice**: no captions. While Gemini speaks, the disc's glow breathes with the voice level.

### States
a. Watching (idle) · b. Gemini adjusting (ISO rolls 800 → 200; focus point glides in) ·
c. Aligned / ready (dot + disc glow) · d. Captured → **depth scan** · e. Depth ready.

**d. Depth scan** (Depth Pro runs right after the shutter): the frame freezes; a thin iso-depth
contour (1.5px gemini-hot + glow) sweeps from the nearest object to the far background; passed
areas get a faint blue depth tint, nearer = brighter. Panel dims to 30%; the disc wears a 2px blue
progress arc. ~0.4–1.0 s real time; the animation can run 1.6 s.
**e. Depth ready**: the photo lifts into a gentle 3D tilt (parallax layers by depth), one blue focus
point on the subject. Panel shows a single tilt ruler and the disc becomes a check. ≤ 2 text items.

**Opening (iPhone)**: void + the Unicorn key-light shader. Wordmark `coach` top-centre; the disc
centred in the lower third as the only object (tap = start). Blue live dot. Nothing else.

## v2.1 changes (user feedback, 2026-11-21) — these OVERRIDE anything above

1. **Shutter orb, redone as a glass lens element** (the flat blue gradient ball is rejected).
   A sphere of smoked optical glass (base `#070B16`), not a gradient disc. Inside it, a slow
   refracted caustic swirl of Gemini light (blue `#4C8DFF` → iris `#9A7CF6`, thin hot `#B4CEFF`
   filaments) that pools toward the lower half like light inside a lens. A thin bright Fresnel rim,
   brightest lower-right where the inner light exits; one crisp small elliptical specular upper-left
   plus a soft secondary reflection lower-right; a faint chromatic fringe at the rim (≤0.5px). A
   22 × 1.5px "+" etched on the surface in frost 80%. Idle: swirl ~8s/lap. Ready: inner light
   brightens, swirl quickens slightly, soft outer halo. Pressed: compresses to .94 with a white
   flash inside. While Gemini speaks, the inner light pulses with the voice level.
   (Alternative to show next to it: a non-orb "machined ring" shutter — matte frost ring + solid
   inner disc, no gradient.)
2. **Red mic button** — talk to Gemini. 60px, same glass material family as the orb but red
   (`--voice` `#FF4545`, deep `#B3161C`), white 22px mic glyph. Off: deep red, calm. Listening:
   bright red, a red inner border glow that pulses, the glyph becomes a 5-bar live waveform.
3. **Changing values glow from inside their box.** Any value that is changing (Gemini or the user
   moving it) gets an **inner border glow** around the inside edge of its cell: an iridescent
   thin-film spectrum (`#7AA7FF → #B48CFF → #FF8FCF → #FFC27A → #8CF5D2 → #7AA7FF`, pastel, not
   neon) flowing around the border (~2.4 s per lap), falloff ~12px inward, ~70% at the edge. The
   numeral rolls like a drum and takes a faint iridescent tint. Glow fades out over 420ms when the
   value settles. This replaces the "2px blue top bar".
4. **No arrows — the viewfinder border is the guide.** The viewfinder's own rounded border glows
   on the side you should tilt/move toward: inner edge glow in Gemini blue (hot `#B4CEFF` at the very
   edge, `#4C8DFF` falloff ~40px inward, slight bleed onto the bezel), intensity ∝ how far off you
   are, with a slow shimmer travelling along that edge. Two directions → two edges with a hot
   corner. Roll/level → opposite corners. Getting closer dims it; on target the whole border gives
   one soft full-perimeter pulse and fades (= ready). The "+" focus point is no longer used for
   guidance (only for tap-to-focus).

### iPhone panel layout v2.1 (y 600 → 852)
- Row 1 `y 600–684` (h 84): drum cells `ISO | SS | EV`, values 30px.
- Ruler strip `y 684–728` (h 44): focus ruler full width, value `1.2 m` at the right end.
- Row 3 `y 728–852` (h 124): **red mic 60px** centred in the left third · **glass orb 104px** centred ·
  last-shot thumb 50px (radius 12) centred in the right third.

## v2.2 changes (user feedback, 2026-11-21) — OVERRIDE anything above

1. **Mic is a wide capsule, not a circle.** Red glass capsule, radius full. iPhone 112 × 56 centred at
   (65.5, 790) in Row 3's left third. Off: centred white mic
   glyph (22px), calm deep red. Listening: glyph slides to the left end, a live 9–12 bar waveform
   fills the rest of the capsule, bright red with a pulsing red inner border glow. Tap to toggle,
   hold to talk.
## Craft rules (clean · textured · good UX)
- **One light.** Every screen is lit by the same key light from the upper right, so highlights, rims
  and shadows agree across the iPhone screens and the shaders.
- **Three surfaces only**: void (`#04060C`), panel (`#070A14`), glass. One hairline weight (1px at
  12%). Radii: 30 (viewfinder), 16 (stage/prints), 12 (thumbs), full (capsules, orb).
- **Texture is material, not decoration**: 2–3% animated film grain on every dark surface, frosted
  acrylic for the pad, smoked glass for the orb and mic, and a thin-film sheen only for changing values.
- **One primary action per screen**: the shutter. Everything else is secondary
  and quieter.
- **State is shown with light, not words**: the edge glow shows direction, the inner glow shows a
  value changing, the blue edge on a print shows something new.
- **Gemini is interruptible**: touching a glowing cell or slider takes control back. Shaking the phone
  undoes Gemini's last move. Gemini never changes two things at once.

---

## v2.3 — MATTE everything (user: "I don't like the shininess or the glossiness") — OVERRIDES all above

- **No gloss anywhere.** No specular highlights, no glossy reflections, no glass shine, no Fresnel
  rim highlights, no wet or chrome looks, no bevel glints. Light is soft and diffused.
- **Materials:** matte soft-touch (like a rubberised camera grip), frosted/milky diffusers, and
  bead-blasted anodised metal, all with fine grain. Shading comes only from broad, soft form light
  (the upper-right key) and soft ambient occlusion, never from highlights.
- **Shutter orb → "frosted lantern":** a matte, milky sphere lit from inside like a paper lantern
  or frosted bulb. A soft blue → iris glow diffuses through it, brightest low and to the left, away
  from the key light. No specular, no rim glint, no refraction swirl lines. Fine grain and a very
  faint subsurface noise. The "+" is a matte debossed mark. Ready = the inner glow brightens and a
  soft halo blooms (diffuse, no sparkle). The matte "machined ring" (bead-blasted, no brushing
  sheen) remains the non-orb alternative.
- **Mic capsule → matte red soft-touch:** solid red (`#E5484D`, deep `#A3161B`), flat, with only a
  subtle soft form shade and grain; white matte glyph and waveform. Listening = a brighter red and a
  soft diffuse red inner glow, not a shine.
- **Pad:** frosted, satin-matte acrylic that glows from inside, with a soft bevel shown by light
  falloff only (no specular edge line). Prints are matte paper.
- Glows (edge guide, iridescent value glow, relight) stay, but read as diffuse light, never as
  reflective sheen.

---

## v2.4 (user feedback, 2026-11-21) — OVERRIDES all above

1. **Paired keys (shutter + mic share one geometry).** Row 3 (`y 728–852`) holds two capsules with the
   SAME height (72) and radius (36), centred on y 790, with equal outer padding 16 and a gap of 12:
   - Mic capsule `x 16–136` (120 × 72): matte red soft-touch, glyph + waveform when listening.
   - Shutter capsule `x 148–377` (229 × 72): the frosted-lantern material (Components "Orb A")
     stretched into a capsule. Matte, glowing from inside, with a debossed "+" centred. Ready makes
     the inner glow brighter and adds a soft halo; press compresses it to .96.
   - The last-shot thumbnail moves INTO the viewfinder's bottom-left corner: 40 × 40, radius 10, inset
     12 (x 20, y 540), 1px frost 30% border. "4:3" stays bottom-right.
   - No orb anywhere.
2. **Drums scroll naturally.** ISO / SS / EV are horizontal wheels. Values sit on one continuous strip,
   66px apart. Cylindrical falloff: the centre value is at scale 1 and opacity 1; ±1 detent at scale
   .78 and opacity .32; ±2 at .6 and .12. A soft 18px fade mask at each cell edge means no glyph is
   ever hard-clipped mid-character and ghosts never meet across a divider. Motion: drag with momentum,
   snap to a detent with a slight overshoot (spring stiffness 300, damping 28), a slight horizontal
   motion blur while moving, and a light haptic per detent. Gemini's changes use the same physics, one
   detent per 240ms, with the iridescent inner glow while changing. Use the hyphen-minus "-" for
   negative EV (the "−" glyph doesn't render in Unicorn).
3. **iPhone opening = "camera wakes up"** (no orb, no splash button, zero taps):
   - 0–300ms: void. A faint "coach" wordmark breathes in, then out.
   - 300–900ms: the viewfinder opens from a 6-blade matte aperture iris, revealing the live view.
   - 500–1100ms: the panel hairlines draw left → right, the drums roll in from blank to their current
     values (drum physics), and the mic and shutter keys rise 12px and fade in.
   - 1100–1700ms: one blue edge-light sweep travels once around the viewfinder border (Gemini online),
     ending as the 6px live dot.
   - Then you're in the camera, ready to shoot.
---

## Brand (2026-11-21, in progress)

- Working names: family **Coach**; iPhone app **Coach Cam** (the native
  target CoachCam). Name alternatives are explored on the Paper page
  "Brand · names, marks, app icons".
- Mark idea, from the product's own UI language: a rounded viewfinder frame with ONE edge lit in
  Gemini blue (the coach telling you which way to go) and a small debossed "+" (the shutter / focus).
- Same rules as the UI: matte, grain, one key light from the upper right, Gemini blue `#4C8DFF`
  as the single colour moment, iris only as a gradient tail. Don't use Google's Gemini sparkle or
  logo — only the colour.

### v2.5 drum refinement (overrides v2.4 item 2 numbers)
At rest, the neighbouring values are WHOLE numerals and never cut. ±1 sits at scale .5 (≈15px) and
opacity .35; ±2 is hidden. Spacing is chosen per drum so the neighbours never touch the centre
value (ISO ≈46px, SS ≈56px with "1/" set smaller, EV ≈46px). In motion, values scale .5→1 as they
reach the centre (cylindrical), with the momentum / overshoot / haptic rules from v2.4. Soft edge
fades only matter mid-scroll.

---

## Brand (2026-11-21): keep the Brand A *aesthetic*, new name, new icons
- The user likes Brand A's celestial maximalist look: engraved star-chart linework, a sky gradient
  from deep navy to Gemini blue `#4C8DFF` to iris `#9A7CF6`, star-white, an iridescent thin-film halo
  and one amber star. They dislike its name (Pollux/Castor) and its seal-style icons.
- The aesthetic belongs to the **brand surfaces**: landing page, icons, launch film. The product UI stays
  modern and matte.
- Working name for the landing page: **Northlight**. North light is the soft, even light painters and
  photographers prize, and also the guiding star. It's a placeholder and easy to swap.
- Icons: NO seals, badges or round emblems, and nothing vintage (no brass or old engraving plates).
  Modern iOS squircle icons that carry the sky, linework and halo.
