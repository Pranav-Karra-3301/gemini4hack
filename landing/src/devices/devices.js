import './devices.css';

// iPhone: Apple's bezel PNG with the screen underneath, clipped to the exact screen rect
// measured in the image (design/landing/assets/iphone-frame.json).
// MacBook: a CSS/SVG frame (Apple's MacBook PNG licence forbids network redistribution).
// Everything is in percentages, so both devices scale with their host.
const FRAMES = {
  iphone: {
    src: '/assets/iphone-16-pro-frame.png',
    label: 'iPhone 16 Pro',
    w: 1350,
    h: 2760,
    screen: { x: 72, y: 69, w: 1206, h: 2622, r: [188, 188, 188, 188] }, // tl tr br bl
  },
};

const pct = (a, b) => `${((a / b) * 100).toFixed(4)}%`;

function mountFrame(container, kind) {
  const f = FRAMES[kind];
  const s = f.screen;
  const root = document.createElement('div');
  root.className = `dv dv--${kind}`;
  root.style.aspectRatio = `${f.w} / ${f.h}`;

  const screen = document.createElement('div');
  screen.className = 'dv__screen';
  Object.assign(screen.style, {
    left: pct(s.x, f.w),
    top: pct(s.y, f.h),
    width: pct(s.w, f.w),
    height: pct(s.h, f.h),
    // Elliptical percentages: x radii relative to width, y radii relative to height.
    borderRadius: `${s.r.map((r) => pct(r, s.w)).join(' ')} / ${s.r.map((r) => pct(r, s.h)).join(' ')}`,
  });

  const img = document.createElement('img');
  img.className = 'dv__frame';
  img.src = f.src;
  img.alt = '';
  img.decoding = 'async';
  img.draggable = false;
  img.setAttribute('aria-hidden', 'true');

  root.append(screen, img);
  root.setAttribute('role', 'img');
  root.setAttribute('aria-label', f.label);
  container.appendChild(root);
  return screen;
}

/** iPhone 16 Pro (Black Titanium). Fills the container width. Returns the screen element. */
export function mountIPhone(container) {
  return mountFrame(container, 'iphone');
}

let uid = 0;

// MacBook Pro 14 in device units: base deck 1716 wide; lid 1560x1049 at x 78; screen
// 1512x982 at (24, 24) inside the lid; base strip 57 tall. Root is 1716x1106.
const MB = { w: 1716, h: 1106, lid: { x: 78, w: 1560, h: 1049 }, screen: { x: 24, y: 24, w: 1512, h: 982, r: 20 } };

/** MacBook Pro 14 (Space Black), CSS frame. Fills the container width. Returns the screen element. */
export function mountMacBook(container) {
  const id = `dvmb${++uid}`;
  const { lid, screen: s } = MB;
  const root = document.createElement('div');
  root.className = 'dv dv--macbook';
  root.style.aspectRatio = `${MB.w} / ${MB.h}`;
  root.setAttribute('role', 'img');
  root.setAttribute('aria-label', 'MacBook Pro 14-inch');
  root.innerHTML = `
    <div class="dv-macbook__shadow" aria-hidden="true"></div>
    <div class="dv-macbook__lid" style="left:${pct(lid.x, MB.w)};width:${pct(lid.w, MB.w)};height:${pct(lid.h, MB.h)}">
      <div class="dv-macbook__bezel"></div>
      <div class="dv__screen dv-macbook__screen" style="left:${pct(s.x, lid.w)};top:${pct(s.y, lid.h)};width:${pct(s.w, lid.w)};height:${pct(s.h, lid.h)};border-radius:${pct(s.r, s.w)} ${pct(s.r, s.w)} 0 0 / ${pct(s.r, s.h)} ${pct(s.r, s.h)} 0 0"></div>
      <svg class="dv-macbook__notch" style="top:${pct(s.y - 1, lid.h)};width:${pct(212, lid.w)}" viewBox="0 0 212 33" aria-hidden="true">
        <path fill="#060607" d="M0 0H212V1Q206 1 206 7V25Q206 33 198 33H14Q6 33 6 25V7Q6 1 0 1Z"/>
        <circle cx="106" cy="15" r="4.2" fill="#0c0e13"/>
        <circle cx="106" cy="15" r="1.8" fill="#141823"/>
      </svg>
    </div>
    <svg class="dv-macbook__base" style="top:${pct(lid.h, MB.h)}" viewBox="0 0 1716 57" aria-hidden="true">
      <defs>
        <linearGradient id="${id}-body" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="54">
          <stop offset="0" stop-color="#121314"/>
          <stop offset="0.05" stop-color="#2e2f32"/>
          <stop offset="0.26" stop-color="#424347"/>
          <stop offset="0.295" stop-color="#4b4c50"/>
          <stop offset="0.325" stop-color="#2a2b2e"/>
          <stop offset="0.7" stop-color="#1f2022"/>
          <stop offset="1" stop-color="#151617"/>
        </linearGradient>
        <linearGradient id="${id}-side" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="1716" y2="0">
          <stop offset="0" stop-color="#000" stop-opacity="0.35"/>
          <stop offset="0.04" stop-color="#000" stop-opacity="0"/>
          <stop offset="0.96" stop-color="#000" stop-opacity="0"/>
          <stop offset="1" stop-color="#000" stop-opacity="0.35"/>
        </linearGradient>
        <linearGradient id="${id}-scoop" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#0f1011"/>
          <stop offset="0.6" stop-color="#1c1d1f"/>
          <stop offset="1" stop-color="#2b2c2f"/>
        </linearGradient>
      </defs>
      <rect x="108" y="50" width="76" height="6" rx="3" fill="#09090a"/>
      <rect x="1532" y="50" width="76" height="6" rx="3" fill="#09090a"/>
      <path fill="url(#${id}-body)" d="M80 0H1636C1672 0 1716 10 1716 20V34C1716 46 1704 54 1682 54H34C12 54 0 46 0 34V20C0 10 44 0 80 0Z"/>
      <path fill="url(#${id}-side)" d="M80 0H1636C1672 0 1716 10 1716 20V34C1716 46 1704 54 1682 54H34C12 54 0 46 0 34V20C0 10 44 0 80 0Z"/>
      <path fill="url(#${id}-scoop)" d="M724 15.5C758 15.5 768 27 800 27H916C948 27 958 15.5 992 15.5Z"/>
      <path fill="none" stroke="#fff" stroke-opacity="0.07" stroke-width="1" d="M724 16C758 16 768 27.5 800 27.5H916C948 27.5 958 16 992 16"/>
    </svg>`;
  container.appendChild(root);
  return root.querySelector('.dv-macbook__screen');
}
