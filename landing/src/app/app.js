// "In the app": real screens of the Heliocam iPhone app, each with what Gemini did on it.
// Desktop (>= 900px): a scroll-pinned horizontal gallery. Vertical scroll drives a row of
// phones under one fixed warm spotlight; the centred phone is lit, its neighbours sit in shadow,
// and a caption in the text column crossfades to it. Mobile: a native swipe carousel.
// All copy and image paths come from APP (config.js); the phone geometry from PHONE.
import { APP, PHONE } from '../config.js';
import './app.css';

const DESKTOP = '(min-width: 900px)';
const REDUCED = '(prefers-reduced-motion: reduce)';
const SHADOW = 0.45; // brightness of a phone in shadow
const SMALL = 0.86; // scale of a phone in shadow
const SPACING = 1.18; // centre-to-centre distance, in phone widths
const IDLE_MS = 150; // quiet time before the gallery settles on the nearest phone
const FOLLOW_MS = 90; // time constant of the progress easing toward the scroll position
const SNAP_MS = 140; // time constant of the settle

const { frame: F, screen: S } = PHONE;
const pct = (a, b) => `${((a / b) * 100).toFixed(4)}%`;
const SCREEN_STYLE = [
  `left:${pct(S.x, F.w)}`,
  `top:${pct(S.y, F.h)}`,
  `width:${pct(S.w, F.w)}`,
  `height:${pct(S.h, F.h)}`,
  `border-radius:${pct(S.r, S.w)} / ${pct(S.r, S.h)}`,
].join(';');

const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ESC[c]);
const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
const smooth = (t) => t * t * (3 - 2 * t);

// Dust in the beam: x (% of the beam box), horizontal drift (px), duration and delay (s).
const MOTES = [
  [44, 10, 15, 0], [52, -8, 18, 3.5], [48, 14, 21, 7], [57, -12, 16, 10.5],
  [40, 6, 19, 2], [55, 9, 23, 13], [46, -10, 17, 5.5], [60, -6, 20, 9],
  [50, 12, 22, 15], [43, -4, 18, 11.5], [53, 7, 16, 1], [47, -9, 24, 17],
];

const chipsMarkup = (s) => {
  const model = s.model ? `<li class="app__chip app__chip--model">${esc(s.model)}</li>` : '';
  const tech = (s.tech ? s.tech.split(' · ') : [])
    .map((t) => `<li class="app__chip">${esc(t.trim())}</li>`)
    .join('');
  return model || tech ? `<ul class="app__chips">${model}${tech}</ul>` : '';
};

const captionMarkup = (s) => `
  <h3 class="h3 app__name">${esc(s.name)}</h3>
  <p class="app__what">${esc(s.what)}</p>
  ${chipsMarkup(s)}`;

const slideMarkup = (s, i) => `
  <figure class="app__slide" data-i="${i}">
    <div class="app__phone" style="aspect-ratio:${F.w} / ${F.h}">
      <div class="app__screen" style="${SCREEN_STYLE}">
        <img class="app__shot" src="${esc(s.src)}" alt="${esc(s.name)}" loading="lazy" decoding="async" draggable="false" />
      </div>
      <img class="app__bezel" src="${esc(PHONE.bezel)}" alt="" loading="lazy" decoding="async" draggable="false" />
    </div>
    <figcaption class="app__cap">${captionMarkup(s)}</figcaption>
  </figure>`;

const markup = (screens) => `
  <div class="app__pin" style="--n:${screens.length}">
    <div class="app__stage">
      <div class="app__light" aria-hidden="true">
        <i class="app__beam"></i>
        <i class="app__pool"></i>
        <i class="app__lamp"></i>
        <span class="app__motes">${MOTES.map(
          ([x, dx, d, t]) => `<i style="--x:${x}%;--dx:${dx}px;--d:${d}s;--t:-${t}s"></i>`,
        ).join('')}</span>
      </div>
      <div class="container grid app__grid">
        <div class="col-text copy app__copy">
          <p class="eyebrow">${esc(APP.label)}</p>
          <h2 class="h2">${esc(APP.title)}</h2>
          <p class="lede">${esc(APP.lede)}</p>
          <div class="app__caps">${screens
            .map((s, i) => `<div class="app__capx" data-i="${i}">${captionMarkup(s)}</div>`)
            .join('')}</div>
          <div class="app__rail" role="group" aria-label="${esc(APP.label)}">
            <span class="app__rail-line"><span class="app__rail-fill"></span></span>
            ${screens
              .map(
                (s, i) =>
                  `<button class="app__tick" type="button" data-i="${i}" style="left:${pct(i, Math.max(1, screens.length - 1))}" aria-label="${esc(s.name)}"></button>`,
              )
              .join('')}
          </div>
        </div>
        <div class="app__media" aria-hidden="true"></div>
      </div>
      <div class="app__track">${screens.map(slideMarkup).join('')}</div>
    </div>
  </div>
  <div class="container app__more">
    ${APP.moreLabel ? `<p class="eyebrow app__more-label">${esc(APP.moreLabel)}</p>` : ''}
    <ul class="app__more-list">${(APP.more || []).map((m) => `<li>${esc(m)}</li>`).join('')}</ul>
    ${APP.caption ? `<p class="small app__credit">${esc(APP.caption)}</p>` : ''}
  </div>`;

export function mountApp(el) {
  const screens = APP.screens;
  const n = screens.length;
  el.classList.add('app');
  el.innerHTML = markup(screens);

  const $ = (s) => el.querySelector(s);
  const pin = $('.app__pin');
  const stage = $('.app__stage');
  const textCol = $('.app__copy');
  const media = $('.app__media');
  const fill = $('.app__rail-fill');
  const slides = [...el.querySelectorAll('.app__slide')];
  const phones = slides.map((s) => s.querySelector('.app__phone'));
  const caps = [...el.querySelectorAll('.app__capx')];
  const ticks = [...el.querySelectorAll('.app__tick')];
  const cache = slides.map(() => ({ t: '', lit: -1, hidden: false }));

  const mqDesk = matchMedia(DESKTOP);
  const mqReduced = matchMedia(REDUCED);
  let desktop = mqDesk.matches;
  let reduced = mqReduced.matches;
  let visible = false;
  let raf = 0;
  let last = 0;
  let p = 0; // displayed progress, in screens (0..n-1)
  let active = -1;
  const geo = { cx: 0, cy: 0, w: 0, h: 0, gap: 0, vh: 0, step: 1 };

  // Settle state. The settle scrolls the window itself, so the page and the gallery agree.
  let snapping = false;
  let snapY = 0;
  let snapTo = 0;
  let idleTimer = 0;
  let touching = false;

  const read = () => {
    const r = pin.getBoundingClientRect();
    const s = -r.top;
    return {
      s,
      raw: clamp(s / geo.step - 0.5, 0, n - 1),
      pinned: r.top <= 0 && r.bottom >= geo.vh,
      top: window.scrollY + r.top,
    };
  };

  const measure = () => {
    if (!desktop) return;
    const sr = stage.getBoundingClientRect();
    const mr = media.getBoundingClientRect();
    const tr = textCol.getBoundingClientRect();
    geo.vh = window.innerHeight;
    geo.w = phones[0].offsetWidth;
    geo.h = phones[0].offsetHeight;
    geo.cx = mr.left + mr.width / 2 - sr.left;
    geo.cy = stage.clientHeight / 2 + geo.vh * 0.02;
    geo.gap = geo.w * SPACING;
    geo.step = Math.max(1, (pin.offsetHeight - geo.vh) / n);
    const st = stage.style;
    st.setProperty('--cx', `${geo.cx.toFixed(1)}px`);
    st.setProperty('--cy', `${geo.cy.toFixed(1)}px`);
    st.setProperty('--pw', `${geo.w}px`);
    st.setProperty('--ph', `${geo.h}px`);
    // Phones fade into the dark before they reach the text.
    st.setProperty('--fade-a', `${Math.round(tr.right - sr.left)}px`);
    st.setProperty('--fade-b', `${Math.round(mr.left - sr.left + 120)}px`);
    for (const c of cache) c.t = '';
  };

  const setActive = (k) => {
    if (k === active) return;
    if (active >= 0) {
      caps[active].classList.remove('is-on');
      ticks[active].classList.remove('is-on');
      ticks[active].removeAttribute('aria-current');
    }
    active = k;
    caps[k].classList.add('is-on');
    ticks[k].classList.add('is-on');
    ticks[k].setAttribute('aria-current', 'true');
    ticks.forEach((t, i) => t.classList.toggle('is-past', i < k));
  };

  const render = () => {
    for (let i = 0; i < n; i++) {
      const c = cache[i];
      const st = slides[i].style;
      const d = i - p;
      const ad = Math.abs(d);
      if (ad > 3.2) {
        if (!c.hidden) {
          st.visibility = 'hidden';
          c.hidden = true;
        }
        continue;
      }
      if (c.hidden) {
        st.visibility = '';
        c.hidden = false;
      }
      const lit = ad < 1 ? smooth(1 - ad) : 0;
      const sc = SMALL + (1 - SMALL) * lit;
      const x = geo.cx + d * geo.gap - geo.w / 2;
      const y = geo.cy - geo.h / 2;
      const t = `translate3d(${x.toFixed(1)}px,${y.toFixed(1)}px,0) scale(${sc.toFixed(4)})`;
      if (t !== c.t) {
        st.transform = t;
        c.t = t;
      }
      const l = Math.round(lit * 1000) / 1000;
      if (l !== c.lit) {
        st.setProperty('--lit', l);
        st.zIndex = String(Math.round(l * 10));
        c.lit = l;
      }
    }
    fill.style.transform = `scaleX(${(n > 1 ? p / (n - 1) : 1).toFixed(4)})`;
    setActive(clamp(Math.round(p), 0, n - 1));
  };

  const frame = (now) => {
    raf = 0;
    if (!desktop) return;
    const dt = last ? Math.min(64, now - last) : 16;
    last = now;
    if (snapping) {
      const k = 1 - Math.exp(-dt / SNAP_MS);
      snapY += (snapTo - snapY) * k;
      if (Math.abs(snapTo - snapY) < 0.75) {
        snapY = snapTo;
        snapping = false;
      }
      window.scrollTo({ top: snapY, behavior: 'instant' });
    }
    let { raw } = read();
    if (reduced) {
      raw = Math.round(raw); // whole screens only: always a static, centred state
      p = raw;
    } else {
      p += (raw - p) * (1 - Math.exp(-dt / FOLLOW_MS));
      if (Math.abs(raw - p) < 0.0005) p = raw;
    }
    render();
    if (snapping || p !== raw) raf = requestAnimationFrame(frame);
    else last = 0;
  };

  const kick = () => {
    if (!raf && desktop && visible) raf = requestAnimationFrame(frame);
  };

  const trySnap = () => {
    if (!desktop || reduced || touching || !visible || snapping) return;
    const { raw, pinned, s } = read();
    if (!pinned) return;
    const k = Math.round(raw);
    if (Math.abs(raw - k) < 0.003) return;
    snapY = window.scrollY;
    snapTo = Math.round(snapY + ((k + 0.5) * geo.step - s));
    snapping = true;
    kick();
  };

  const noteInput = () => {
    clearTimeout(idleTimer);
    idleTimer = setTimeout(trySnap, IDLE_MS);
  };

  // Anything the user does cancels a settle in progress.
  const onUser = () => {
    snapping = false;
    if (desktop) noteInput();
  };
  const onTouchStart = () => {
    touching = true;
    onUser();
  };
  const onTouchEnd = () => {
    touching = false;
    onUser();
  };
  const onScroll = () => {
    if (!desktop || !visible) return;
    if (snapping) {
      if (Math.abs(window.scrollY - snapY) <= 2) return kick(); // our own settle
      snapping = false;
    }
    noteInput();
    kick();
  };

  const onTick = (e) => {
    const t = e.target.closest('.app__tick');
    if (!t || !desktop) return;
    snapping = false;
    const { top } = read();
    window.scrollTo({
      top: Math.round(top + (Number(t.dataset.i) + 0.5) * geo.step),
      behavior: reduced ? 'instant' : 'smooth',
    });
  };

  const clearDesktop = () => {
    for (let i = 0; i < n; i++) {
      const st = slides[i].style;
      st.transform = '';
      st.visibility = '';
      st.zIndex = '';
      st.removeProperty('--lit');
      cache[i] = { t: '', lit: -1, hidden: false };
    }
  };

  const onMode = () => {
    desktop = mqDesk.matches;
    snapping = false;
    if (desktop) {
      measure();
      p = read().raw;
      render();
    } else {
      clearDesktop();
    }
  };
  const onReduced = () => {
    reduced = mqReduced.matches;
    el.classList.toggle('is-reduced', reduced);
    if (reduced) snapping = false;
    kick();
  };
  const onResize = () => {
    if (!desktop) return;
    measure();
    p = read().raw;
    render();
  };

  const io = new IntersectionObserver(
    ([entry]) => {
      visible = entry.isIntersecting;
      el.classList.toggle('is-live', visible);
      if (visible) kick();
      else {
        if (raf) cancelAnimationFrame(raf);
        raf = 0;
        last = 0;
        snapping = false;
      }
    },
    { rootMargin: '10% 0px' },
  );

  const passive = { passive: true };
  window.addEventListener('scroll', onScroll, passive);
  window.addEventListener('resize', onResize, passive);
  window.addEventListener('wheel', onUser, passive);
  window.addEventListener('keydown', onUser, passive);
  window.addEventListener('pointerdown', onUser, passive);
  window.addEventListener('touchstart', onTouchStart, passive);
  window.addEventListener('touchend', onTouchEnd, passive);
  window.addEventListener('touchcancel', onTouchEnd, passive);
  el.addEventListener('click', onTick);
  mqDesk.addEventListener('change', onMode);
  mqReduced.addEventListener('change', onReduced);
  io.observe(el);

  el.classList.toggle('is-reduced', reduced);
  setActive(0);
  onMode();

  return {
    destroy() {
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
      clearTimeout(idleTimer);
      io.disconnect();
      window.removeEventListener('scroll', onScroll, passive);
      window.removeEventListener('resize', onResize, passive);
      window.removeEventListener('wheel', onUser, passive);
      window.removeEventListener('keydown', onUser, passive);
      window.removeEventListener('pointerdown', onUser, passive);
      window.removeEventListener('touchstart', onTouchStart, passive);
      window.removeEventListener('touchend', onTouchEnd, passive);
      window.removeEventListener('touchcancel', onTouchEnd, passive);
      el.removeEventListener('click', onTick);
      mqDesk.removeEventListener('change', onMode);
      mqReduced.removeEventListener('change', onReduced);
      el.classList.remove('app', 'is-live', 'is-reduced');
      el.innerHTML = '';
    },
  };
}
