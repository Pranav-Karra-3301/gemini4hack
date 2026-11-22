// Single source of truth for names, media paths, labels and the models' colours.
// Rename the product here and the whole page follows.
//
// The page is text-free (DESIGN_V5.md "Text rules"): the wordmark, the tagline, model ids,
// tool-call chips and one spoken quote. Every technical claim comes from the iPhone app's code
// (issue #41, branch feat/41-iphone-standalone). If the app changes, change it here.
export const PRODUCT = {
  name: 'Heliocam',
  line: 'Gemini inside the camera.',
};

// Exported Unicorn Studio scenes (landing/public/scenes/). A missing file keeps the CSS light.
export const SCENES = {
  hero: '/scenes/v5-hero.json', // variable `open` 0-1: the iris opens on the sparkle
  gemini: '/scenes/v5-gemini.json', // variable `lit` 0-1: the line draws by ~0.4, then the "4" lights
  model: '/scenes/v5-model.json', // variable `model`: 0 hydrogen, 1 decision, 2 voice
};

// Each model is its own colour of Gemini's light (DESIGN_V5.md "Lead").
// `role` is what the model does in the app, in at most three words, shown next to its id.
export const MODELS = {
  hydrogen: { id: 'gemini-4-hydrogen', color: '#4C8DFF', role: 'Runs the camera' },
  decision: { id: 'gemini-decision-1', color: '#6FE3FF', role: 'Picks the move' },
  neon: { id: 'gemini-4-neon', color: '#9A7CF6', role: 'Edits and writes looks' },
  voice: { id: 'gemini-3.8-flash-tts', color: '#FFC37A', role: 'Talks to you' },
};

// One big, clean title per section (src/title.js): what the section shows, in 2-3 words.
export const TITLES = {
  lidar: 'Sees in 3D.',
  live: 'Live suggestions.',
  after: 'Lights by depth.',
  looks: 'Writes the look.',
  app: 'The real app.',
};

// The real screenshots in public/app/ come from the iPhone 15 Pro simulator: 1178 x 2556 px,
// 393 x 852 pt. `radius` is that display's corner radius in pt (55), so a phone drawn at any
// size rounds the screenshot exactly as the device does, with nothing cropped.
export const SCREEN = { w: 1178, h: 2556, pt: { w: 393, h: 852 }, radius: 55 };

// iPhone 16 Pro bezel (design/landing/assets/iphone-frame.json). Phone scenes are laid out
// in a `viewport`-sized box (their design size), then CSS-scaled and clipped to `screen`.
export const PHONE = {
  bezel: '/assets/iphone-16-pro-frame.png',
  frame: { w: 1350, h: 2760 },
  screen: { x: 72, y: 69, w: 1206, h: 2622, r: 188 },
  viewport: { w: 393, h: 852 },
};

// "Gemini 4": the key-art section right after the hero, its models in order along the line.
export const GEMINI = {
  label: 'Gemini 4',
  models: [MODELS.hydrogen, MODELS.decision, MODELS.neon, MODELS.voice],
};

// The live loop (src/live/): one phone, three models, one beat each as you scroll.
// Regions are in % of the real screenshot (860 x 1867), measured from the image.
export const LIVE = {
  screens: { camera: '/app/camera.webp', guide: '/app/camera-guide.webp' },
  regions: {
    dials: { top: 65.4, height: 9.4 }, // the ISO / SS / EV row
    viewfinder: { top: 1.1, height: 63.2 }, // the photo, whose left edge pulses
  },
  beats: [
    { model: MODELS.hydrogen, screen: 'camera', call: 'set_camera', args: 'iso 400 · 1/125' },
    { model: MODELS.decision, screen: 'guide', call: 'move ←', args: 'every 1 s' },
    { model: MODELS.voice, screen: 'guide', quote: 'That’s it. Take it.' },
  ],
};

// Sections in page order (DESIGN_V5.md "Page beats"). Labels are at most three words.
export const CHAPTERS = [
  { id: 'top', kind: 'hero' },
  { id: 'gemini', kind: 'gemini' },
  // src/lidar/ mountLidar(el, copy): a real scene as points, settling into the photo.
  { id: 'lidar', kind: 'lidar', copy: { label: 'LiDAR · on device' } },
  { id: 'live', kind: 'live' },
  // src/compare/ mountCompare(el): Heliocam against other camera apps.
  { id: 'compare', kind: 'compare' },
  // src/showcase/ mountShowcase(el, opts): the same shot from LiDAR, after the shutter.
  { id: 'after', kind: 'showcase', label: 'The shot' },
  {
    // src/looks/ mountLooks(el, chapter): Neon writes a Metal shader live; real preset code.
    // steps[0] is the look that is asked for.
    id: 'looks',
    kind: 'looks',
    n: 4,
    label: 'Looks',
    steps: [{ text: '“Kodachrome 400 slide film”' }],
    tech: MODELS.neon.id,
  },
  { id: 'in-app', kind: 'app' },
  { id: 'footer', kind: 'footer' },
];

// "In the app": real screens from the iPhone app (iOS Simulator, the app's own -demoCoach mode
// and real Gemini calls), each with what Gemini did on it. Source: PRs #42-#49.
export const APP = {
  label: 'In the app',
  title: 'This is the app.',
  lede: 'Real screens from the Heliocam iPhone app, and what Gemini did on each one.',
  screens: [
    {
      src: '/app/camera.webp',
      name: 'The camera agent',
      what: 'Gemini watched the frame and set ISO 400 and 1/125 itself. The drums rolled; nobody touched them.',
      model: 'gemini-4-hydrogen',
      tech: 'set_camera · guide · shot_ready · up to 3 calls per frame',
    },
    {
      src: '/app/camera-guide.webp',
      name: 'Step left',
      what: 'About once a second, Decision answers which way to move. The edge of the viewfinder glows that way.',
      model: 'gemini-decision-1',
      tech: 'move · ready · 0.4–1 s',
    },
    {
      src: '/app/roll.webp',
      name: 'The roll',
      what: 'Every shot lands here and in Photos, with metric depth for every pixel.',
      tech: 'HEIF · Core ML depthpro2-s',
    },
    {
      src: '/app/viewer-depth.webp',
      name: 'Depth map',
      what: 'Near is bright. Depth Pro 2 S runs on the Neural Engine, with LiDAR as the fallback.',
      tech: '854 × 480 · metres',
    },
    {
      src: '/app/viewer-3d.webp',
      name: '3D',
      what: 'The photo and its depth as about 250k soft splats you orbit with a finger.',
      tech: 'Metal',
    },
    {
      src: '/app/viewer-layers.webp',
      name: 'Layers',
      what: 'The scene sliced into slabs by distance.',
      tech: 'SceneKit',
    },
    {
      src: '/app/edit-for-me.webp',
      name: 'Edit for Me',
      what: 'Gemini looked at the shot and played four fader moves: exposure −0.35, contrast +18, warmth +18, vibrance +24.',
      model: 'gemini-4-neon',
      tech: 'JSON schema · steps[slider, value, why] · ~6.6 s',
    },
    {
      src: '/app/looks-code.webp',
      name: 'Looks, being written',
      what: 'Neon writing a Kodachrome shader in Metal, streamed over the photo as it types.',
      model: 'gemini-4-neon',
      tech: 'streamGenerateContent · makeLibrary(source:)',
    },
    {
      src: '/app/looks.webp',
      name: 'Looks, live',
      what: 'Compiled on the phone and faded in over 0.7 s.',
      model: 'gemini-4-neon',
      tech: 'MTKView · Metal',
    },
  ],
  moreLabel: 'Also in the app',
  more: [
    'Live hint: “A little left, off the pole”',
    'A ghost frame where the subject should land',
    'Live LiDAR depth tile, about 15 fps',
    'Zoom dial with detents at 0.5, 1 and 2',
    'Calm voice: gemini-3.8-flash-tts, Umbriel',
    'Hold to talk: Decision moves a fader in about a second',
    'Detail zoom up to 6×',
  ],
  caption: 'Screens from the iOS Simulator, using the app’s demo mode and live Gemini calls.',
};
