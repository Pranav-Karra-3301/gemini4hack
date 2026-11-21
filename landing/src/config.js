// Single source of truth for names, media paths, copy and step timings.
// Rename the product here and the whole page follows.
//
// Every technical claim on the page comes from the iPhone app's code (issue #41, branch
// feat/41-iphone-standalone). Keep it that way: if the app changes, change the copy here.
export const PRODUCT = {
  name: 'Heliocam',
  line: 'A camera that turns you toward the light.',
  sub: 'An iPhone camera with a Gemini 4 agent inside. It moves the real controls, tells you where to stand and measures every shot in 3D.',
  badges: ['iPhone', 'LiDAR', 'Gemini 4'],
  poweredBy: 'Powered by Gemini 4',
};

// Exported Unicorn Studio scenes (landing/public/scenes/). Only these mount.
export const SCENES = {
  viewfinder: '/scenes/phone-viewfinder.json',
};

// iPhone 16 Pro bezel (design/landing/assets/iphone-frame.json). Phone scenes are laid out
// in a `viewport`-sized box (their design size), then CSS-scaled and clipped to `screen`.
export const PHONE = {
  bezel: '/assets/iphone-16-pro-frame.png',
  frame: { w: 1350, h: 2760 },
  screen: { x: 72, y: 69, w: 1206, h: 2622, r: 188 },
  viewport: { w: 393, h: 852 },
};

// The hero: the thesis. The hackathon bars image analysis apps; this is why Heliocam isn't one.
export const THESIS = {
  line: ['Image analysis describes a picture.', 'Heliocam takes one.'],
  rows: [
    { k: 'When', a: 'After the photo exists', b: 'Before the shutter fires' },
    { k: 'Input', a: 'A finished picture', b: 'A live camera, its controls and you' },
    { k: 'Output', a: 'Words about pixels', b: 'Function calls to the sensor and lens, and moves for you to make' },
  ],
  labels: { a: 'Image analysis', b: 'Heliocam' },
};

// Sections in page order (DESIGN_V4.md "Page structure"). `n` is the chapter number.
// `media` alternates sides; text always shares one left edge.
export const CHAPTERS = [
  { id: 'top', kind: 'hero' },
  {
    // src/lidar/ mountLidar(el, copy): a real scene as points, settling into the photo.
    id: 'lidar',
    kind: 'lidar',
    n: 1,
    copy: {
      label: '01 · Sees in 3D',
      title: 'Every shot, measured in 3D.',
      lede: 'The LiDAR scanner measures the scene in metres on the phone, and Gemini gets the distance to your subject in every turn.',
      steps: [
        { title: 'LiDAR', text: 'A grid of infrared dots lands on every surface.' },
        { title: 'Distance, live', text: 'The depth stream runs about 15 times a second. The distance at your subject goes to Gemini as subject_m.' },
        { title: 'Depth Pro 2', text: 'After the shot, Apple’s Depth Pro 2 S gives every pixel a metric depth on the Neural Engine.' },
      ],
      caption: 'Sample scene: IMG_1491 · depth shown as points',
    },
  },
  {
    // The phone viewfinder demo plus Gemini's live agent trace (src/story/trace.js).
    id: 'coach',
    kind: 'coach',
    n: 2,
    phone: [{ src: SCENES.viewfinder }],
    media: 'left',
    label: 'Coaches you live',
    title: 'Gemini drives the camera.',
    lede: 'Two loops run at once. Gemini 4 reasons and turns the real dials. Gemini Decision answers every second: move, or that’s it.',
    loop: 6.2,
    // Synced to the viewfinder scene: ISO rolls 800 → 200 at 0.9 s, the left edge glows at 1.9 s.
    trace: [
      { t: 0.0, dir: 'in', text: 'frame · 512 px + state', meta: 'ISO 800 · 1/125 · EV −0.3 · subject_m 1.2 (LiDAR)' },
      { t: 0.35, dir: 'think', text: 'gemini-4-hydrogen', meta: 'agent loop · thinking low' },
      { t: 0.9, dir: 'call', text: 'set_camera({ iso: 200, why: "faces are already bright" })' },
      { t: 1.35, dir: 'in', text: 'functionResponse', meta: '{ iso: 200 } · clamped to what this iPhone supports' },
      { t: 1.9, dir: 'call', text: 'decide({ move: "left", p: 0.82 })', meta: 'gemini-decision-1 · the left edge glows' },
      { t: 3.6, dir: 'call', text: 'decide({ ready: "yes", p: 0.91 })', meta: 'gemini-decision-1 · “That’s it.”' },
    ],
    traceLabel: 'Agent trace · live',
    traceNote: 'Replayed faster than real time. A Gemini 4 turn takes 1.6–5 s; a Decision call 0.4–1 s.',
  },
  {
    // src/showcase/ mountShowcase(el, opts): the same shot from 01, after the shutter.
    id: 'after',
    kind: 'showcase',
    n: 3,
    fallback: {
      label: 'After the shot',
      title: 'Light by distance.',
      lede: 'Depth turns the edit into lighting: near and far get their own light.',
    },
  },
  {
    // src/looks/ mountLooks(el, chapter): Neon writes a Metal shader live; real preset code.
    id: 'looks',
    kind: 'looks',
    n: 4,
    label: 'Looks',
    title: 'Gemini writes the shader.',
    lede: 'Say a look. Gemini 4 Neon writes a Metal shader for it, the phone compiles it on the GPU, and the photo changes live.',
    steps: [
      { title: 'Say it', text: '“Kodachrome 400 slide film”' },
      { title: 'Neon writes Metal', text: 'The code streams onto the photo as it’s written.' },
      { title: 'Compiled on the phone', text: 'If it doesn’t compile, the error goes back to Neon to fix.' },
      { title: 'Live', text: 'The new look fades in over 0.7 s.' },
    ],
    tech: 'gemini-4-neon · streamGenerateContent · thinkingLevel low · MTLDevice.makeLibrary(source:)',
    note: 'Replayed faster than real time. Writing a look takes about 18 s.',
  },
  {
    id: 'voice',
    kind: 'voice',
    n: 5,
    media: 'left',
    label: 'Just talk to it',
    title: 'Say what you want.',
    lede: 'Your words are transcribed on the phone, and a clip of your voice goes to Gemini too. It answers in a calm voice.',
    loop: 7.5,
    listen: [0.3, 2.3],
    steps: [
      { text: '“Get the wall behind the can”', start: 0.3, end: 2.6 },
      { text: 'Gemini plans the move', start: 2.6, end: 4.8 },
      { text: '“Lower the phone. Hold.”', start: 4.8, end: 7.5 },
    ],
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
