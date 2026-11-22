// One iPhone for the whole page, drawn in CSS around a real app screenshot.
//
//   const el = phoneEl({ src: '/app/camera.webp', alt: 'The camera', className: 'live__phone' });
//   phoneScreen(el).append(overlay);   // the screen box is exactly the screenshot: place overlays in %
//   swapScreen(el, '/app/camera-guide.webp');   // crossfade to another screenshot
//
// The screen has the screenshot's own aspect (SCREEN in config.js: 1178 x 2556, the iPhone 15 Pro
// simulator) and its real corner radius (55 of 393 pt), so the whole screenshot shows, rounded
// exactly as the device rounds it, with nothing cropped. Around it: a thin near-black bezel, a
// graphite titanium edge, small side buttons and a Dynamic Island (the simulator captures have none).
// Size it from CSS: give the element a height (or a width) and the other follows from its aspect.
import { PHONE_GEO } from './geometry.js';
import './phone.css';

export { PHONE_GEO };
const { aspect, radius, bezel } = PHONE_GEO;

const { frame: FR } = PHONE_GEO;
const pc = (v) => `${(v * 100).toFixed(4)}%`;

/** The screen's box in % of the whole phone (left, top, width, height). */
export const SCREEN_IN_FRAME = {
  left: (bezel / FR.w) * 100,
  top: (bezel / FR.h) * 100,
  width: (1 / FR.w) * 100,
  height: (1 / aspect / FR.h) * 100,
};

/** A point of the screenshot (x, y in % of the screenshot) as % of the whole phone. */
export const toFrame = (x, y) => ({
  x: SCREEN_IN_FRAME.left + (x / 100) * SCREEN_IN_FRAME.width,
  y: SCREEN_IN_FRAME.top + (y / 100) * SCREEN_IN_FRAME.height,
});

const FRAME_STYLE = [
  `aspect-ratio:${FR.w.toFixed(5)} / ${FR.h.toFixed(5)}`,
  `border-radius:${pc(PHONE_GEO.outerRadius / FR.w)} / ${pc(PHONE_GEO.outerRadius / FR.h)}`,
].join(';');

const SCREEN_STYLE = [
  `left:${SCREEN_IN_FRAME.left.toFixed(4)}%`,
  `top:${SCREEN_IN_FRAME.top.toFixed(4)}%`,
  `width:${SCREEN_IN_FRAME.width.toFixed(4)}%`,
  `height:${SCREEN_IN_FRAME.height.toFixed(4)}%`,
  `border-radius:${pc(radius)} / ${pc(radius * aspect)}`,
].join(';');

// The island sits on the glass, in % of the phone, so screen filters and overlays never touch it.
const { island: IS } = PHONE_GEO;
const ISLAND_STYLE = [
  `left:${pc((bezel + (1 - IS.w) / 2) / FR.w)}`,
  `top:${pc((bezel + IS.top) / FR.h)}`,
  `width:${pc(IS.w / FR.w)}`,
  `height:${pc(IS.h / FR.h)}`,
].join(';');


const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ESC[c]);

const shotMarkup = (src, alt, lazy) =>
  `<img class="iphone__shot" src="${esc(src)}" alt="${esc(alt)}" decoding="async"${lazy ? ' loading="lazy"' : ''} draggable="false" />`;

/**
 * A phone showing one screenshot, whole. Returns the root element (a <figure>).
 * @param {{ src: string, alt?: string, className?: string, lazy?: boolean }} opts
 */
export function phoneEl({ src, alt = '', className = '', lazy = false } = {}) {
  if (!src) throw new Error('phoneEl: a screenshot `src` is required');
  const el = document.createElement('figure');
  el.className = `iphone ${className}`.trim();
  el.setAttribute('style', FRAME_STYLE);
  el.innerHTML = `
    ${PHONE_GEO.buttons.map(([s, t, h]) => `<i class="iphone__btn iphone__btn--${s}" style="top:${t}%;height:${h}%" aria-hidden="true"></i>`).join('')}
    <div class="iphone__screen" style="${SCREEN_STYLE}">${shotMarkup(src, alt, lazy)}</div>
    <i class="iphone__edge" aria-hidden="true"></i>
    <i class="iphone__island" style="${ISLAND_STYLE}" aria-hidden="true"></i>`;
  return el;
}

/** The screen box of a phone: exactly the screenshot, so overlays placed in % of it line up. */
export function phoneScreen(el) {
  const screen = el?.querySelector(':scope > .iphone__screen');
  if (!screen) throw new Error('phoneScreen: not a phone made by phoneEl()');
  return screen;
}

/**
 * Crossfades the phone to another screenshot. The newest call wins; overlays stay on top.
 * Resolves once the new screenshot is fully shown.
 */
export function swapScreen(el, src, { ms = 600 } = {}) {
  const screen = phoneScreen(el);
  const shots = screen.querySelectorAll(':scope > .iphone__shot');
  const top = shots[shots.length - 1];
  if (top && top.getAttribute('src') === src) return Promise.resolve();
  const still = ms <= 0 || matchMedia('(prefers-reduced-motion: reduce)').matches;
  const tpl = document.createElement('template');
  tpl.innerHTML = shotMarkup(src, top ? top.alt : '', false);
  const img = tpl.content.firstElementChild;
  img.style.opacity = '0';
  if (top) top.after(img);
  else screen.prepend(img);

  const dropBelow = () => {
    for (const s of screen.querySelectorAll(':scope > .iphone__shot')) {
      if (s === img) break;
      s.remove();
    }
  };
  return img
    .decode()
    .catch(() => console.error(`[phone] Could not decode ${src}; showing it as it loads.`))
    .then(
      () =>
        new Promise((resolve) => {
          if (!img.isConnected) return resolve();
          if (still) {
            img.style.opacity = '1';
            dropBelow();
            return resolve();
          }
          img.style.transition = `opacity ${ms}ms var(--ease, ease)`;
          void img.offsetWidth;
          img.style.opacity = '1';
          setTimeout(() => {
            if (img.isConnected) dropBelow();
            resolve();
          }, ms + 40);
        }),
    );
}
