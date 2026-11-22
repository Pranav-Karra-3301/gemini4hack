// Compare: Heliocam against other camera apps, as a split stage with no sentences. Left, a plain
// camera, grey and unlit. Right, the real Heliocam viewfinder lit by the Gemini light: the left
// edge pulses cyan once a second (gemini-decision-1) and the ISO dial rolls 800 → 400 by itself
// (gemini-4-hydrogen). Under the phones, four rows score who does each job.
//
//   const { destroy } = mountCompare(sectionEl);
//
// On scroll entry a light sweeps in from the left, passes behind the other phone and settles on
// Heliocam. Loops pause off screen; under prefers-reduced-motion it shows the lit end state.
import './compare.css';
import { phoneEl, phoneScreen } from '../phone/phone.js';

// The app screenshots are 860 × 1866. Every overlay below is placed in those pixels; the phone's
// screen box is exactly the screenshot (src/phone/), so they land where they were measured.
const SHOT = { w: 860, h: 1866 };
const SRC = { other: '/app/camera.webp', helio: '/app/camera-guide.webp' };
// The rounded viewfinder, measured on camera-guide.webp.
const VIEWFINDER = { x: 18, y: 18, w: 826, h: 1184, r: 64 };
// Everything under the viewfinder (the dial rows and the buttons) on the plain camera.
const CHROME_TOP = 1206;
// The ISO cell's value row: "200 400 800", the big value's digits centred at x 143.5, y 1324.1,
// the neighbours 101 px either side at 0.47 of its height.
const ISO = { patch: { x: 4, y: 1290, w: 279, h: 70 }, cx: 143.5, cy: 1324.1, step: 101, values: [200, 400, 800, 1600] };
const ISO_FROM = 800;
const ISO_TO = 400;
const ISO_LOOP = { roll: 900, hide: 5200, end: 5500 }; // ms
const SETTLE = 1900; // ms from scroll entry until the sweep has landed (matches compare.css)

const ROWS = [
  { key: 'Exposure', icon: 'exposure', other: 'You', chip: 'gemini-4-hydrogen', c: '#4C8DFF' },
  { key: 'Framing', icon: 'framing', other: 'You', chip: 'gemini-decision-1', c: '#6FE3FF' },
  { key: 'Depth', icon: 'depth', other: '—', chip: 'LiDAR + Depth Pro 2', c: '#EEF3FF' },
  { key: 'Looks', icon: 'looks', other: 'Filters', chip: 'gemini-4-neon writes Metal', c: '#9A7CF6' },
];

const ICONS = {
  exposure:
    '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2.2M12 19.3v2.2M2.5 12h2.2M19.3 12h2.2M5.3 5.3l1.6 1.6M17.1 17.1l1.6 1.6M5.3 18.7l1.6-1.6M17.1 6.9l1.6-1.6"/>',
  framing:
    '<path d="M4 8.5v-3A1.5 1.5 0 0 1 5.5 4h3M15.5 4h3A1.5 1.5 0 0 1 20 5.5v3M20 15.5v3a1.5 1.5 0 0 1-1.5 1.5h-3M8.5 20h-3A1.5 1.5 0 0 1 4 18.5v-3"/><path d="M9.5 12h5M12 9.5v5"/>',
  depth: '<path d="M12 3.5 21 8l-9 4.5L3 8z"/><path d="m3 12 9 4.5 9-4.5"/><path d="m3 16 9 4.5 9-4.5"/>',
  looks: '<circle cx="12" cy="8.5" r="4.5"/><circle cx="8.5" cy="14.5" r="4.5"/><circle cx="15.5" cy="14.5" r="4.5"/>',
};

const pct = (a, b) => `${((a / b) * 100).toFixed(4)}%`;

// A rect in screenshot pixels as % of the screen.
const rect = ({ x, y, w, h }) =>
  `left:${pct(x, SHOT.w)};top:${pct(y, SHOT.h)};width:${pct(w, SHOT.w)};height:${pct(h, SHOT.h)}`;

const VF_STYLE = `${rect(VIEWFINDER)};border-radius:${pct(VIEWFINDER.r, VIEWFINDER.w)} / ${pct(VIEWFINDER.r, VIEWFINDER.h)}`;

const isoSlot = (v, at) => Math.max(-2, Math.min(2, Math.log2(v / at)));

// A phone slot; mountCompare puts the real phone in it, with `screen` over its screenshot.
const phoneSlot = (side) => `<div class="cmp-slot" data-side="${side}"></div>`;

// The plain camera: the dial rows and buttons go under a dark panel with a generic shutter.
const OTHER_SCREEN = `
  <div class="cmp-plain" style="${rect({ x: 0, y: CHROME_TOP, w: SHOT.w, h: SHOT.h - CHROME_TOP })}" aria-hidden="true">
    <i class="cmp-plain__thumb"></i><i class="cmp-plain__shutter"></i><i class="cmp-plain__flip"></i>
  </div>
  <div class="cmp-cool" aria-hidden="true"></div>`;

const isoMarkup = () => {
  const { patch: P } = ISO;
  const values = ISO.values
    .map((v) => `<span class="cmp-iso__v" data-v="${v}" data-slot="${isoSlot(v, ISO_FROM)}">${v}</span>`)
    .join('');
  return `
  <div class="cmp-iso" style="${rect(P)};--ax:${ISO.cx - P.x};--ay:${ISO.cy - P.y};--step:${ISO.step}" aria-hidden="true">${values}</div>`;
};

const HELIO_SCREEN = `
  <div class="cmp-pulse" style="${VF_STYLE}" aria-hidden="true"></div>
  ${isoMarkup()}`;

const rowMarkup = (r, i) => `
  <li class="cmp__row" style="--i:${i};--c:${r.c}">
    <span class="cmp__a">${r.other}</span>
    <span class="cmp__k"><svg viewBox="0 0 24 24" aria-hidden="true">${ICONS[r.icon]}</svg>${r.key}</span>
    <span class="cmp__b"><span class="cmp__chip"><i></i>${r.chip}</span></span>
  </li>`;

const markup = () => `
  <div class="cmp__stage">
    <div class="cmp__side cmp__side--other">
      <p class="cmp__name cmp__name--other">Other camera apps</p>
      ${phoneSlot('other')}
    </div>
    <div class="cmp__side cmp__side--helio">
      <div class="cmp__light" aria-hidden="true"><i class="cmp__beam"></i><i class="cmp__pool"></i></div>
      <p class="cmp__name cmp__name--helio">Heliocam</p>
      ${phoneSlot('helio')}
    </div>
    <ul class="cmp__score">${ROWS.map(rowMarkup).join('')}</ul>
  </div>
  <div class="cmp__grain" aria-hidden="true"></div>`;

export function mountCompare(el) {
  if (!el) throw new Error('mountCompare: no element to mount into');
  const root = document.createElement('div');
  root.className = 'cmp';
  root.innerHTML = markup();
  for (const [side, overlay] of [['other', OTHER_SCREEN], ['helio', HELIO_SCREEN]]) {
    const phone = phoneEl({ src: SRC[side], alt: '', className: `cmp-phone cmp-phone--${side}` });
    phoneScreen(phone).insertAdjacentHTML('beforeend', overlay);
    root.querySelector(`.cmp-slot[data-side="${side}"]`).replaceWith(phone);
  }
  el.appendChild(root);

  const still = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const iso = root.querySelector('.cmp-iso');
  const isoValues = [...iso.querySelectorAll('.cmp-iso__v')];
  const timers = new Set();
  let lit = false;
  let visible = false;
  let playing = false;

  const later = (ms, fn) => {
    const t = setTimeout(() => {
      timers.delete(t);
      fn();
    }, ms);
    timers.add(t);
  };
  const clearTimers = () => {
    timers.forEach(clearTimeout);
    timers.clear();
  };

  const setIso = (at) => {
    for (const n of isoValues) n.dataset.slot = isoSlot(+n.dataset.v, at);
  };

  // One pass: snap to 800, roll to 400 (it lands blue, then cools to white), fade, repeat.
  const isoLoop = () => {
    iso.classList.add('is-snap');
    iso.classList.remove('is-set', 'is-hidden');
    setIso(ISO_FROM);
    void iso.offsetWidth;
    iso.classList.remove('is-snap');
    later(ISO_LOOP.roll, () => {
      setIso(ISO_TO);
      iso.classList.add('is-set');
    });
    later(ISO_LOOP.roll + 900, () => iso.classList.remove('is-set'));
    later(ISO_LOOP.hide, () => iso.classList.add('is-hidden'));
    later(ISO_LOOP.end, isoLoop);
  };

  const sync = () => {
    const next = lit && visible && !still;
    if (next === playing) return;
    playing = next;
    root.classList.toggle('is-playing', playing);
    clearTimers();
    if (!playing) return;
    later(lit === 'settled' ? 0 : SETTLE, () => {
      lit = 'settled';
      isoLoop();
    });
  };

  const light = () => {
    if (lit) return;
    lit = true;
    root.classList.add('is-lit');
    sync();
  };

  if (still) {
    root.classList.add('is-lit', 'is-still');
    setIso(ISO_TO);
    lit = 'settled';
  }

  // Lights once, when the phones are well into view.
  const trigger = new IntersectionObserver(
    (entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        light();
        trigger.disconnect();
      }
    },
    { rootMargin: '0px 0px -30% 0px' }
  );
  // Runs the loops only while any of it is on screen.
  const seen = new IntersectionObserver((entries) => {
    visible = entries[entries.length - 1].isIntersecting;
    sync();
  });
  if (!still) trigger.observe(root);
  seen.observe(root);

  return {
    destroy() {
      trigger.disconnect();
      seen.disconnect();
      clearTimers();
      root.remove();
    },
  };
}
