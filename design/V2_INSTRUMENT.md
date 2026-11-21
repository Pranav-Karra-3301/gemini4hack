# Coach v2 — "Instrument" direction (Gemini blue)

Supersedes the v1 guidance UI (arrows, rings, intent chips, captions). Source of truth for Paper
pages "v2 · Camera (iPhone)" and "v2 · Studio (Mac)" and the Unicorn phone demos.

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

## Mac — CoachStudio (1440 × 900). No camera controls.

- **Stage**: the selected shot, depth-enabled (subtle 3D tilt), max ~1000 × 680, centred-left.
  Where Gemini is working, a soft blue relight region (depth-masked) and the one focus point.
- **Slider column** (right, w 280, hairline rows): `EXPOSURE, CONTRAST, HIGHLIGHTS, SHADOWS, TEMP,
  TINT`. Each: mono label, 20px numeral, a tick ruler with a thumb. The one Gemini is moving: blue
  thumb + blue numeral; others at 45%.
- **Filmstrip** (bottom): shots synced from the iPhone, 56px thumbs radius 10; the newest has a blue
  dot. Top-left wordmark `coach studio`; top-right a blue dot + `IPHONE` mono 9px.
- **Opening (Mac)**: light shader + the disc centred as an import/"+" target; wordmark; one mono
  line `DROP A PHOTO` at 50%.

---

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
   value settles. This replaces the "2px blue top bar". Same treatment on Mac slider rows.
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

### Mac
- The slider row being changed gets the iridescent inner border glow (rule 3).
- A red mic button (rule 2) sits bottom-right of the stage. The opening uses the glass orb (rule 1).

---

## v2.2 changes (user feedback, 2026-11-21) — OVERRIDE anything above

1. **Mic is a wide capsule, not a circle.** Red glass capsule, radius full. iPhone 112 × 56 centred at
   (65.5, 790) in Row 3's left third; Mac 140 × 56 bottom-right of the stage. Off: centred white mic
   glyph (22px), calm deep red. Listening: glyph slides to the left end, a live 9–12 bar waveform
   fills the rest of the capsule, bright red with a pulsing red inner border glow. Tap to toggle,
   hold to talk. Mac shortcut: hold Space.
2. **Mac opening = "the Pad"** (the orb-only opening is rejected). A frosted-acrylic light pad,
   like an artist's light table, floating in the void in 3/4 perspective. It is lit from inside
   (soft blue-white subsurface glow, brightest at the edges) and by the studio key light from the
   upper right, with a soft contact shadow below. On it lie the 3–5 most recent shots from the
   iPhone as thin prints, each slightly lifted in relief by its depth map. The newest print has just
   arrived: a soft blue edge glow on that print is the one focal point. The cursor tilts the pad
   gently (parallax). Dropping a photo anywhere on the pad imports it; hovering the pad brightens
   its edge, and only then does a mono `DROP TO IMPORT` hint fade in. Persistent text is only the
   wordmark (top-left) and a blue dot + `IPHONE` (top-right). No orb on Mac.
3. **Editor 3D view ("Pad 3D").** In the Studio editor the stage can flip into 3D: the current shot
   becomes a depth-relief plate resting on the pad, orbitable by dragging, with faint iso-depth
   contour lines on the relief. Gemini's relight region glows on the relief itself. The slider
   column stays, and the row being changed keeps the iridescent inner glow.

## Craft rules (clean · textured · good UX)
- **One light.** Every screen is lit by the same key light from the upper right, so highlights, rims
  and shadows agree across iPhone, Mac and the shaders.
- **Three surfaces only**: void (`#04060C`), panel (`#070A14`), glass. One hairline weight (1px at
  12%). Radii: 30 (viewfinder), 16 (stage/prints), 12 (thumbs), full (capsules, orb).
- **Texture is material, not decoration**: 2–3% animated film grain on every dark surface, frosted
  acrylic for the pad, smoked glass for the orb and mic, and a thin-film sheen only for changing values.
- **One primary action per screen**: the orb (iPhone) and the pad (Mac). Everything else is secondary
  and quieter.
- **State is shown with light, not words**: the edge glow shows direction, the inner glow shows a
  value changing, the blue edge on a print shows something new.
- **Gemini is interruptible**: touching a glowing cell or slider takes control back. ⌘Z (Mac) or
  shaking the phone undoes Gemini's last move. Gemini never changes two things at once.

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
4. **Mac opening = "Latest shot, in depth"** (no orb, no pad):
   - The newest synced iPhone shot fills the editor's stage frame (radius 16) as a slow depth-parallax
     hero, revealed once by the same depth-scan sweep used on iPhone.
   - The filmstrip of recent shots sits below; wordmark top-left, blue dot + `IPHONE` top-right.
   - The whole window is a drop target: on drag-over, the stage dims and a 1px dashed frost frame with
     `DROP TO IMPORT` appears.
   - Clicking the stage or pressing ⏎ starts editing: the slider column slides in from the right.
   - The opening is the editor without its sliders, so there's one layout and one focal point.
5. **Editor 3D view (no pad):** the shot as a depth-relief plate floating over the void with a soft
   contact shadow, faint iso-depth contours and Gemini's relight on the subject. Same slider column. A
   small segmented toggle `2D | 3D` (mono 9px, hairline) sits top-right of the stage.
6. **Studio · c "Shot arrives" = "Analyzing a new shot"** (no tilt, no empty space):
   - Same layout as a (stage + slider column + filmstrip).
   - The new thumbnail slides into the filmstrip's next slot (blue dot) and the shot takes the stage
     flat, then the depth-scan sweep runs across it.
   - Under the stage, three tiny mono steps light up in order: `DEPTH · SUBJECTS · LIGHT`, each with a
     check when done.
   - Slider rows are disarmed (ticks at 25%, values "—") until analysis finishes. Then the row Gemini
     will change first gets the iridescent glow, which hands off to state a.

---

## Brand (2026-11-21, in progress)

- Working names: family **Coach**; iPhone app **Coach Cam**; Mac app **Coach Studio** (matching
  the native targets CoachCam / CoachStudio). Name alternatives are explored on the Paper page
  "Brand · names, marks, app icons".
- Mark idea, from the product's own UI language: a rounded viewfinder frame with ONE edge lit in
  Gemini blue (the coach telling you which way to go) and a small debossed "+" (the shutter / focus).
  The Mac variant adds a depth contour or the iridescent thin-film sheen.
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

## v3 Mac Studio — "Magic" (user, 2026-11-21): cleaner inputs, near-zero text, magical shaders, NOT vintage

Rejected: the "v3 · Studio (Mac) · Pro" inspector layout (15 labelled sliders, histogram, lesson chips,
transcript, text toolbar), plus tick rulers and engraved/brass looks in the product UI.

- **The photo is the interface.** The stage fills the window (16px margins, radius 16). No inspector panel.
- **Gemini teaches on the photo itself.** Each lesson step is shown as LIGHT where it acts. For example,
  "subject light" is a soft, depth-aware light pool that blooms onto the faces, with a single floating
  value chip (`+14 → +20`, Google Sans Flex 15px on a matte frosted chip) next to the subject. One
  floating control at a time.
- **Four controls, icons only**: a matte frosted pill dock bottom-centre with 4 icon buttons
  (Light · Colour · Depth · Look) + the red mic capsule. Picking one turns the whole photo into the
  input: drag horizontally anywhere to scrub, and the value appears near the cursor while you drag,
  then fades. The active icon gets the iridescent inner glow. No labels at rest; a tooltip on hover.
- **Lesson progress** = 4 small dots above the dock (the current one iridescent). Gemini speaks by voice;
  at most ONE short line of text appears above the dots while it talks, then fades.
- **Compare** = hold Space. A soft vertical band of light sweeps across the photo, revealing
  before / after (shader wipe), not a hard divider line.
- **Top bar**: back chevron and file name (13px, 60%) on the left. A 3-icon segmented switch
  (Photo · Depth · 3D) in the centre. Export icon on the right. Nothing else.
- **Filmstrip** hidden; it slides in from the left edge on hover or ⌘L.
- **Shaders**: depth-aware relight pool (uses the depth map so light wraps around the near subject),
  the iridescent glow on whatever is changing, the light-band compare wipe, the depth-scan sweep when a
  shot arrives, and the depth parallax in 3D.

## Brand (2026-11-21): keep the Brand A *aesthetic*, new name, new icons
- The user likes Brand A's celestial maximalist look: engraved star-chart linework, a sky gradient
  from deep navy to Gemini blue `#4C8DFF` to iris `#9A7CF6`, star-white, an iridescent thin-film halo
  and one amber star. They dislike its name (Pollux/Castor) and its seal-style icons.
- The aesthetic belongs to the **brand surfaces**: landing page, icons, launch film. The product UI stays
  modern and matte.
- Working name for the landing page: **Northlight**. North light is the soft, even light painters and
  photographers prize, and also the guiding star. It's a placeholder and easy to swap.
- Icons: NO seals, badges or round emblems, and nothing vintage (no brass or old engraving plates).
  Modern squircle and macOS-grid icons that carry the sky, linework and halo.

### v3 Mac Studio — "Light Desk" (OVERRIDES the v3 "Magic" dock/top-bar bullets above)
User: "an actual fader-looking UI… panels should show some depth or texture… I don't like the top
bar layout, the little segmented buttons, the controls on the right… this is Lightroom but 10%
better. It needs to be different."

- **Window = photo + console.** No top bar (just the traffic lights over the void and a 13px file name
  at 50% beside them), no segmented controls, no right inspector.
- **Stage**: the photo, large, centred in the upper ~68% of the window, radius 16, floating over the
  void with a soft contact shadow.
- **The Light Desk** (the bottom ~30%, full width, 16px margins): a physical console slab of matte
  bead-blasted dark anodised aluminium (`#12161F` → `#0C0F16`). It has fine grain, a soft top-edge
  highlight made by light falloff (no specular), and recessed wells shown by inner shadows. Modern
  hardware (Teenage Engineering / pro lighting desk), not vintage: no screws, brass or engraving.
  - **6 motorized fader channels**: KEY (subject light), FILL (shadows), SKY (highlights), WARM
    (temperature), DEPTH (background separation), GLOW (look strength). Each channel is a recessed slot
    (~150px travel) with a soft-touch matte fader cap (a rounded rectangle with a centre groove), a thin
    LED meter column beside it (blue segments, lit to the level), and an ICON scribble at the bottom
    (sun, half-moon, cloud, thermometer, layers, halo). No text labels at rest.
  - **Gemini moves a fader**: the cap glides on its own (motorized, 600–900ms ease-in-out), the slot
    glows from inside with the iridescent thin-film light, and the meter follows. The photo shows that
    change as light (KEY = a depth-aware light pool blooming onto the faces). Only one fader moves at a
    time.
  - **The user grabs a fader**: the cap lifts slightly (shadow grows), the value appears in a small
    LED readout above the cap (Geist Mono 11px, blue), and Gemini stops and yields.
  - **Scene memories** (= the lesson steps): 4 square illuminated hardware keys at the left of the
    desk, numbered by LED dots, not text. The current key glows blue; completed keys glow dim white.
  - **Mode**: a 3-position rotary knob at the right of the desk (Photo · Depth · 3D), with icon detents
    printed around it, replacing the segmented control.
  - **Mic**: the wide matte red capsule key at the far right. **Compare**: a spring-loaded key next to
    it (or hold Space), revealing before/after with a soft light-band wipe across the photo.
- **Filmstrip** stays hidden and slides in from the left edge on hover or ⌘L.
- Gemini speech: voice only. At most one short line fades in above the desk while it talks.
- Shaders: depth-aware relight pool, iridescent slot glow, LED meters, the light-band compare wipe,
  the depth scan when a shot arrives, and depth parallax in 3D.

### Light Desk — SIMPLIFIED (user: "don't overcomplicate… if Gemini is doing it, I need to see the changes, animated")
- Desk content: **4 faders only**: LIGHT (sun), SHADOWS (half-moon), WARMTH (thermometer), DEPTH (layers),
  plus the wide **red mic** key at the right. Nothing else on the desk.
- Removed: the scene-memory keys (lesson progress is now 4 tiny LED dots above the faders), the mode
  knob (3D is reached by ⌘3 or a double-click on the photo; no on-screen control) and the Compare key
  (hold Space).
- **Every Gemini change is a visible animation**: the fader glides (≈900ms ease-in-out) while the
  photo changes in sync (the light pool blooms, warmth shifts, background separates), with the slot's
  iridescent glow on during the move. One change at a time, about 400ms of rest between changes,
  so an audience can follow it. It does not need to be truly live; a scripted animation is fine.
