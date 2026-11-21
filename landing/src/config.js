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

// The thesis right under the hero. The hackathon bars image analysis apps; this is why
// Heliocam isn't one.
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
  { id: 'thesis', kind: 'thesis' },
  {
    // src/lidar/ mountLidar(el, copy): a real scene as points, settling into the photo.
    id: 'lidar',
    kind: 'lidar',
    n: 1,
    copy: {
      label: '01 · Sees in 3D',
      title: 'Every shot, measured in 3D.',
      lede: 'The LiDAR scanner records metric depth with every photo, on the phone.',
      steps: [
        { title: 'LiDAR', text: 'A grid of infrared dots lands on every surface.' },
        { title: 'Distance', text: 'Each point gets a distance in metres, in 32-bit float.' },
        { title: 'Kept with the shot', text: 'The depth is saved inside the photo, ready for the edit.' },
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
    lede: 'An agent loop on Gemini 4 watches the frame and turns the real dials: ISO, shutter, focus, white balance, zoom.',
    loop: 6.2,
    // Synced to the viewfinder scene: ISO rolls 800 → 200 at 0.9 s, the left edge glows at 1.9 s.
    trace: [
      { t: 0.0, dir: 'in', text: 'frame · 512 px', meta: 'ISO 800 · 1/125 · EV −0.3 · group of four, backlit' },
      { t: 0.35, dir: 'think', text: 'gemini-4-hydrogen', meta: 'thinking · low' },
      { t: 0.9, dir: 'call', text: 'set_camera({ iso: 200, why: "faces are already bright" })' },
      { t: 1.35, dir: 'in', text: 'functionResponse', meta: '{ iso: 200 } · clamped to what this iPhone supports' },
      { t: 1.9, dir: 'call', text: 'guide({ direction: "left", strength: 0.6 })' },
      { t: 3.6, dir: 'call', text: 'shot_ready({ reason: "sun behind, faces even" })' },
    ],
    traceNote: 'Replayed faster than real time. One model call takes about 3.7 s.',
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
    id: 'voice',
    kind: 'voice',
    n: 4,
    media: 'left',
    label: 'Just talk to it',
    title: 'Say what you want.',
    lede: 'Speech is transcribed on the phone and goes into Gemini’s next turn. It answers out loud.',
    loop: 7.5,
    listen: [0.3, 2.3],
    steps: [
      { text: '“Get the wall behind the can”', start: 0.3, end: 2.6 },
      { text: 'Gemini plans the move', start: 2.6, end: 4.8 },
      { text: '“Lower the phone. Hold.”', start: 4.8, end: 7.5 },
    ],
  },
  { id: 'hood', kind: 'hood' },
  { id: 'footer', kind: 'footer' },
];

// "Under the hood": each stage of the app, what runs on the phone and what Gemini does.
// `lane` is where the work happens; `status` marks what isn't on the phone yet.
export const HOOD = {
  label: 'Under the hood',
  title: 'What Gemini does at each step.',
  lede: 'Two lanes: the phone senses and acts, Gemini reasons and calls tools. Model ids are the real ones.',
  stages: [
    {
      name: 'Frame and state',
      lane: 'phone',
      what: 'A ~512 px JPEG at most every 0.4 s, plus one line of state: mode, ISO, shutter, EV, focus, white balance, the subject and anything you said.',
      tech: 'AVCaptureSession · MEDIA_RESOLUTION_LOW',
    },
    {
      name: 'The agent loop',
      lane: 'gemini',
      what: 'Gemini looks, then calls tools. Each tool result goes back as a functionResponse, up to three calls per frame, with the last two exchanges kept as memory.',
      tech: 'gemini-4-hydrogen · generateContent + function calling · thinkingLevel low · ~3.7 s per call',
    },
    {
      name: 'Camera control',
      lane: 'phone',
      what: 'set_camera turns the real hardware: exposure duration and ISO, lens position, white-balance gains from kelvin and tint, a zoom ramp, the torch. The values the device accepted go back to Gemini.',
      tech: 'AVCaptureDevice · setExposureModeCustom · setFocusModeLocked · setWhiteBalanceModeLocked',
    },
    {
      name: 'Directions',
      lane: 'gemini',
      what: 'guide() asks you to move: left, right, up, down, closer, back, rotate or hold. The viewfinder edge glows that way and the phone says it out loud.',
      tech: 'guide(direction, strength) · AVSpeechSynthesizer',
    },
    {
      name: 'Capture and depth',
      lane: 'phone',
      what: 'When the shot is ready, the photo is taken with metric LiDAR depth and saved with it as 16-bit millimetres.',
      tech: 'builtInLiDARDepthCamera · DepthFloat32 · HEIC',
    },
    {
      name: 'Finer depth',
      lane: 'phone',
      what: 'Apple’s Depth Pro 2 refines edges on the Neural Engine.',
      tech: 'Core ML depthpro2-s · 854 × 480',
      status: 'in progress',
    },
    {
      name: 'Edit for Me',
      lane: 'gemini',
      what: 'Gemini plans light layers from the photo, its depth and each mask’s distance in metres, renders them, looks at the render and fixes it once.',
      tech: 'gemini-4-neon plans · gemini-4-hydrogen critiques · ≤ 3 layers',
      status: 'moving to the phone',
    },
    {
      name: 'Voice',
      lane: 'phone',
      what: 'Speech is recognised on the phone. After a 1.2 s pause it goes into Gemini’s next turn as what you said.',
      tech: 'SFSpeechRecognizer · on-device only',
    },
  ],
};
