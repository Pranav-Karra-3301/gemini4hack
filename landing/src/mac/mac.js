import './mac.css';
import { mountMacBook } from '../devices/devices.js';
import { createSplatStage } from './splatStage.js';

// Heliocam Studio on a MacBook Pro 14: the splat stage above, the light desk below.
// A ~9 s loop (only while on screen): People rises and the near subject lifts, Warmth warms the
// scene, Depth dims and softens the far field, then everything eases back. Lesson dots follow.

const LOOP = 9; // s
const REST = { people: 0.34, background: 0.52, light: 0.6, warmth: 0.4, depth: 0.32 };
const UP = { people: 0.86, warmth: 0.76, depth: 0.82 };
// [time s, value] keys per moving channel; gliding (smootherstep) between keys.
const KEYS = {
  people: [[0, REST.people], [0.7, REST.people], [1.6, UP.people], [6.7, UP.people], [7.8, REST.people]],
  warmth: [[0, REST.warmth], [2.5, REST.warmth], [3.4, UP.warmth], [6.8, UP.warmth], [7.9, REST.warmth]],
  depth: [[0, REST.depth], [4.3, REST.depth], [5.2, UP.depth], [6.9, UP.depth], [8.0, REST.depth]],
};
const STEPS = [0.7, 2.5, 4.3, 6.7]; // lesson dot advances
const REDUCED_T = 2.0; // the still frame shown with reduced motion: People up

const smooth = (t) => t * t * t * (t * (t * 6 - 15) + 10);
function sample(keys, t) {
  if (t <= keys[0][0]) return keys[0][1];
  for (let i = 1; i < keys.length; i++) {
    const [t1, v1] = keys[i];
    if (t <= t1) {
      const [t0, v0] = keys[i - 1];
      return v0 + (v1 - v0) * smooth((t - t0) / Math.max(1e-6, t1 - t0));
    }
  }
  return keys[keys.length - 1][1];
}
const amount = (key, v) => Math.min(1, Math.max(0, (v - REST[key]) / (UP[key] - REST[key])));

let uid = 0;

// Tiny greyscale mask thumbnails (what each channel selects), 64x40.
const PEOPLE = (fill) => `<g fill="${fill}">
  <circle cx="20" cy="17" r="5.6"/><path d="M8.5 40c0-7.8 5.2-12.6 11.5-12.6S31.5 32.2 31.5 40z"/>
  <circle cx="33.5" cy="13.8" r="6.2"/><path d="M21 40c0-8.8 5.7-14 12.5-14S46 31.2 46 40z"/>
  <circle cx="46.5" cy="18" r="5.2"/><path d="M36 40c0-7.2 4.7-11.6 10.5-11.6S57 32.8 57 40z"/></g>`;
function mask(kind, id) {
  const g = `${id}-${kind}`;
  switch (kind) {
    case 'people':
      return `<rect width="64" height="40" fill="#0a0a0a"/>${PEOPLE('#e9e9e9')}`;
    case 'background':
      return `<rect width="64" height="40" fill="#d9d9d9"/>${PEOPLE('#0c0c0c')}`;
    case 'light':
      return `<defs><radialGradient id="${g}" cx="0.3" cy="0.15" r="0.95"><stop offset="0" stop-color="#f2f2f2"/><stop offset="0.55" stop-color="#5a5a5a"/><stop offset="1" stop-color="#0a0a0a"/></radialGradient></defs>
        <rect width="64" height="40" fill="url(#${g})"/>${PEOPLE('rgba(255,255,255,0.18)')}`;
    case 'warmth':
      return `<defs><linearGradient id="${g}" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#262626"/><stop offset="1" stop-color="#cfcfcf"/></linearGradient></defs>
        <rect width="64" height="40" fill="url(#${g})"/>${PEOPLE('rgba(255,255,255,0.22)')}`;
    case 'depth':
      return `<defs><linearGradient id="${g}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#101010"/><stop offset="1" stop-color="#7a7a7a"/></linearGradient></defs>
        <rect width="64" height="40" fill="url(#${g})"/>${PEOPLE('#f0f0f0')}`;
    default:
      return '';
  }
}

const ICONS = {
  people: '<circle cx="9" cy="8.5" r="3.1"/><path d="M3.6 19.2c.6-3.3 2.8-5.3 5.4-5.3s4.8 2 5.4 5.3"/><circle cx="16.6" cy="9.6" r="2.5"/><path d="M15.9 14.2c2.3 0 4 1.6 4.5 4.4"/>',
  background: '<rect x="3.5" y="5" width="17" height="14" rx="2.6"/><path d="M3.9 16.2l4.5-4.5 3.6 3.6 2.6-2.6 5.5 5.3"/><circle cx="15.6" cy="9.2" r="1.4"/>',
  light: '<circle cx="12" cy="12" r="3.5"/><path d="M12 3.6v2M12 18.4v2M3.6 12h2M18.4 12h2M6.1 6.1l1.4 1.4M16.5 16.5l1.4 1.4M6.1 17.9l1.4-1.4M16.5 7.5l1.4-1.4"/>',
  warmth: '<path d="M10 14.1V5.6a2 2 0 1 1 4 0v8.5a3.8 3.8 0 1 1-4 0z"/><path d="M12 9.2v6.4"/>',
  depth: '<path d="M12 4.2l8.4 4.4L12 13 3.6 8.6z"/><path d="M3.6 12.4L12 16.8l8.4-4.4"/><path d="M3.6 16L12 20.4l8.4-4.4"/>',
};
const CHANNELS = ['people', 'background', 'light', 'warmth', 'depth'];
const svg = (inner, cls, vb = '0 0 24 24') =>
  `<svg class="${cls}" viewBox="${vb}" aria-hidden="true" focusable="false">${inner}</svg>`;

function template(id) {
  const channels = CHANNELS.map(
    (k) => `
    <div class="hm-ch hm-ch--${k}" data-ch="${k}" style="--v:${REST[k]};--a:0">
      <div class="hm-ch__chip">${svg(mask(k, id), 'hm-ch__mask', '0 0 64 40')}</div>
      <div class="hm-ch__body">
        <div class="hm-ch__slot">
          <div class="hm-ch__glow"></div>
          <div class="hm-ch__cap"></div>
        </div>
        <div class="hm-ch__meter"><i></i></div>
      </div>
      ${svg(ICONS[k], 'hm-ch__icon')}
    </div>`,
  ).join('');
  return `
    <div class="hm__stage"><div class="hm__vignette"></div></div>
    <div class="hm__dots" aria-hidden="true">${'<i></i>'.repeat(STEPS.length + 1)}</div>
    <div class="hm__desk">
      ${channels}
      <div class="hm__micwell"><div class="hm__mic">${svg(
        '<rect x="9" y="3.6" width="6" height="10.8" rx="3"/><path d="M6.1 11.4a5.9 5.9 0 0 0 11.8 0M12 17.3v3.1"/>',
        'hm__micicon',
      )}</div></div>
    </div>`;
}

/**
 * Mounts the Mac section into el. opts: { splatUrl }. Returns { destroy }.
 * The splat starts loading when the section nears the viewport; rendering runs only while visible.
 */
export async function mountMacSection(el, opts = {}) {
  const id = `hm${++uid}`;
  const wrap = document.createElement('div');
  wrap.className = 'hm-device';
  el.appendChild(wrap);
  const screen = mountMacBook(wrap);
  const root = document.createElement('div');
  root.className = 'hm';
  root.innerHTML = template(id);
  screen.appendChild(root);

  const stageEl = root.querySelector('.hm__stage');
  const chEls = Object.fromEntries([...root.querySelectorAll('.hm-ch')].map((n) => [n.dataset.ch, n]));
  const dots = [...root.querySelectorAll('.hm__dots i')];

  const mq = window.matchMedia?.('(prefers-reduced-motion: reduce)');
  let reduced = !!mq?.matches;
  root.classList.toggle('is-reduced', reduced);

  const url = opts.splatUrl ?? `${import.meta.env?.BASE_URL ?? '/'}splats/img-1216.spz`;
  const stage = createSplatStage(stageEl, {
    url,
    reduced,
    onReady: () => root.classList.add('is-ready'),
  });

  // ---- timeline ----
  let t = reduced ? REDUCED_T : 0;
  const last = {};
  let lastDot = -1;
  function applyTimeline(time) {
    const fx = { people: 0, warmth: 0, depth: 0 };
    for (const k of CHANNELS) {
      const v = KEYS[k] ? sample(KEYS[k], time) : REST[k];
      const a = KEYS[k] ? amount(k, v) : 0;
      if (KEYS[k]) fx[k] = a;
      const sig = `${v.toFixed(4)}|${a.toFixed(3)}`;
      if (last[k] !== sig) {
        last[k] = sig;
        chEls[k].style.setProperty('--v', v.toFixed(4));
        chEls[k].style.setProperty('--a', a.toFixed(3));
      }
    }
    let dot = 0;
    for (const s of STEPS) if (time >= s) dot++;
    if (dot !== lastDot) {
      lastDot = dot;
      dots.forEach((d, i) => {
        d.classList.toggle('is-on', i === dot);
        d.classList.toggle('is-done', i < dot);
      });
    }
    return fx;
  }

  // ---- loop, only while visible ----
  let raf = 0;
  let prev = 0;
  let clock = 0; // camera time
  function frame(now) {
    raf = requestAnimationFrame(frame);
    const dt = prev ? Math.min(0.05, (now - prev) / 1000) : 1 / 60;
    prev = now;
    if (!reduced) {
      t = (t + dt) % LOOP;
      clock += dt;
    }
    const fx = applyTimeline(reduced ? REDUCED_T : t);
    stage.update(dt, clock, fx);
  }
  function start() {
    if (!raf) {
      prev = 0;
      raf = requestAnimationFrame(frame);
    }
  }
  function stop() {
    if (raf) cancelAnimationFrame(raf);
    raf = 0;
  }

  const loadIo = new IntersectionObserver(
    (entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        stage.load();
        loadIo.disconnect();
      }
    },
    { rootMargin: '600px 0px' },
  );
  loadIo.observe(wrap);
  const runIo = new IntersectionObserver((entries) => {
    const e = entries[entries.length - 1];
    if (e.isIntersecting) start();
    else stop();
  });
  runIo.observe(wrap);

  const onMq = () => {
    reduced = !!mq.matches;
    root.classList.toggle('is-reduced', reduced);
    stage.setReduced(reduced);
    t = reduced ? REDUCED_T : 0;
  };
  mq?.addEventListener?.('change', onMq);

  applyTimeline(t);

  return {
    stage,
    destroy() {
      stop();
      loadIo.disconnect();
      runIo.disconnect();
      mq?.removeEventListener?.('change', onMq);
      stage.destroy();
      wrap.remove();
    },
  };
}
