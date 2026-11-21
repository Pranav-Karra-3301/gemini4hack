// Single source of truth for names, media paths and step timings.
// Rename the product here and the whole page follows.
export const PRODUCT = {
  name: 'Heliocam',
  studio: 'Heliocam Studio',
  line: 'A camera that turns you toward the light.',
  poweredBy: 'Powered by Gemini 4',
};

// Exported Unicorn Studio scenes (landing/public/scenes/). Only these mount.
export const SCENES = {
  hero: '/scenes/hero-heliotrope.json',
  wake: '/scenes/phone-wake.json',
  viewfinder: '/scenes/phone-viewfinder.json',
};

// Static dithered art (landing/public/assets/).
export const ART = {
  coach: '/assets/heliotrope-deep-dark.webp',
  voice: '/assets/heliotrope-dome-dark.webp',
};

// iPhone 16 Pro bezel (design/landing/assets/iphone-frame.json). Phone scenes are laid out
// in a `viewport`-sized box (their design size), then CSS-scaled and clipped to `screen`.
export const PHONE = {
  bezel: '/assets/iphone-16-pro-frame.png',
  frame: { w: 1350, h: 2760 },
  screen: { x: 72, y: 69, w: 1206, h: 2622, r: 188 },
  viewport: { w: 393, h: 852 },
};

// Sections in page order (DESIGN_TYPE.md "Page structure (v3)"). `n` is the chapter number in
// the eyebrow; the showcase module owns chapters 02 (Sees in depth) and 03 (Edits with you).
// `media` alternates sides; text always shares one left edge.
// `phone` scenes play in order (`duration` s before the next one mounts); the last one
// drives the steps, timed in seconds since it loaded, and replays every `loop` seconds.
// Every entry into view replays from the start.
export const CHAPTERS = [
  { id: 'top', kind: 'hero', phone: [{ src: SCENES.wake, duration: 2.2 }, { src: SCENES.viewfinder }] },
  {
    id: 'coach',
    kind: 'phone',
    n: 1,
    phone: [{ src: SCENES.viewfinder }],
    media: 'left',
    label: 'Live coaching',
    title: 'It coaches you live.',
    lede: 'Gemini watches the frame and sets the exposure for you.',
    loop: 6.2,
    steps: [
      { text: 'Gemini reads the light', start: 0, end: 0.9 },
      { text: 'ISO rolls 800 → 200', start: 0.9, end: 1.9 },
      { text: 'The edge glows: step left', start: 1.9, end: 5.2 },
    ],
  },
  {
    // src/showcase/ mountShowcase(el): "Sees in depth" + "Edits with you", real data.
    id: 'depth-edit',
    kind: 'showcase',
    n: 2,
    // Shown only if the module is missing.
    fallback: {
      label: 'Sees in depth',
      title: 'Depth, the moment you shoot.',
      lede: 'Every shot carries a depth map. Gemini edits with it.',
    },
  },
  {
    id: 'mac',
    kind: 'mac',
    n: 4,
    media: 'right',
    label: 'Heliocam Studio',
    title: 'Your Mac is the darkroom.',
    lede: 'Gemini relights your shots in 3D. Every fader stays yours.',
    // Mirrors src/mac/mac.js (LOOP 9, STEPS); once mounted, its lesson dots drive the steps.
    loop: 9,
    steps: [
      { text: 'Gemini lifts the faces', start: 0.7, end: 2.5 },
      { text: 'Warms the light', start: 2.5, end: 4.3 },
      { text: 'Separates the background', start: 4.3, end: 6.7 },
      { text: 'Grab a fader anytime', start: 6.7, end: 9 },
    ],
  },
  {
    id: 'voice',
    kind: 'voice',
    n: 5,
    media: 'left',
    label: 'Voice',
    title: 'Just talk to it.',
    lede: 'Hold to talk. It listens, then shows you.',
    // The mic listens during the first step; the loop replays while the section is in view.
    loop: 7.5,
    listen: [0.3, 2.3],
    steps: [
      { text: '“Make it warmer”', start: 0.3, end: 2.6 },
      { text: 'Gemini finds the light', start: 2.6, end: 4.8 },
      { text: 'The faders move for you', start: 4.8, end: 7.5 },
    ],
  },
  { id: 'finale', kind: 'finale' },
];

// Ink: the one page colour every section fades into.
export const INK = '#070910';
