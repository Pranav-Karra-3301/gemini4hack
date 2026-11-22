// "In the app": real screens of the Heliocam iPhone app, each with the model that worked on it.
// Text-free (DESIGN_V5.md): the section title (TITLES.app); each screen gets only its name (at most
// three words) and a model chip in that model's light (hydrogen blue, decision cyan, neon violet,
// frost "on device" when no model ran), with what that model does after its id.
// Desktop (>= 900px): a scroll-pinned horizontal gallery. Vertical scroll drives a row of
// phones under one fixed warm spotlight; the centred phone is lit, its neighbours sit in shadow,
// and the caption under it crossfades. Mobile: a native swipe carousel.
// Screens (src, name, model) come from APP (config.js); each phone is the shared CSS iPhone
// (src/phone/), which shows the whole screenshot. The header copy, `what`, `tech`, `more` and
// `caption` fields are no longer rendered.
import { APP, MODELS, TITLES } from '../config.js';
import { phoneEl } from '../phone/phone.js';
import { sectionTitle } from '../title/title.js';
import { scrollToY } from '../scroll.js';
import './app.css';

const LABEL = TITLES.app;
const DESKTOP = '(min-width: 900px)';
const REDUCED = '(prefers-reduced-motion: reduce)';
const SHADOW = 0.45; // brightness of a phone in shadow
const SMALL = 0.86; // scale of a phone in shadow
const SPACING = 1.18; // centre-to-centre distance, in phone widths
const FOLLOW_MS = 90; // time constant of the progress easing toward the scroll position

const pct = (a, b) => `${((a / b) * 100).toFixed(4)}%`;

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

// Each model's own colour of light (DESIGN_V5.md); screens with no model ran on the phone.
// The chip shows the model's id, then its `role` (MODELS in config.js) behind a hairline.
const MODEL_LIGHT = { 'gemini-4-hydrogen': 'hydrogen', 'gemini-decision-1': 'decision', 'gemini-4-neon': 'neon' };
const ROLE = Object.fromEntries(Object.values(MODELS).map((m) => [m.id, m.role]));
const chipMarkup = (s) => {
  const kind = s.model ? MODEL_LIGHT[s.model] || 'hydrogen' : 'device';
  const role = s.model && ROLE[s.model] ? `<span class="app__role">${esc(ROLE[s.model])}</span>` : '';
  return `<span class="app__chip app__chip--${kind}"><i></i>${esc(s.model || 'on device')}${role}</span>`;
};

const captionMarkup = (s) => `<span class="app__name">${esc(s.name)}</span>${chipMarkup(s)}`;

const slideMarkup = (s, i) => `
  <figure class="app__slide" data-i="${i}">
    <div class="app__phone-slot"></div>
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
      <div class="app__track" data-lenis-prevent-horizontal>${screens.map(slideMarkup).join('')}</div>
      <div class="app__hud">
        <div class="app__caps">${screens
          .map((s, i) => `<div class="app__capx" data-i="${i}">${captionMarkup(s)}</div>`)
          .join('')}</div>
        <div class="app__rail" role="group" aria-label="${LABEL}">
          <span class="app__rail-line"><span class="app__rail-fill"></span></span>
          ${screens
            .map(
              (s, i) =>
                `<button class="app__tick" type="button" data-i="${i}" style="left:${pct(i, Math.max(1, screens.length - 1))}" aria-label="${esc(s.name)}"></button>`,
            )
            .join('')}
        </div>
      </div>
    </div>
  </div>`;

export function mountApp(el) {
  const screens = APP.screens;
  const n = screens.length;
  el.classList.add('app');
  el.innerHTML = markup(screens);
  el.querySelector('.app__stage').prepend(sectionTitle(TITLES.app, { className: 'app__label' }));
  el.querySelectorAll('.app__phone-slot').forEach((slot, i) =>
    slot.replaceWith(phoneEl({ src: screens[i].src, alt: screens[i].name, className: 'app__phone', lazy: true })),
  );

  const $ = (s) => el.querySelector(s);
  const pin = $('.app__pin');
  const stage = $('.app__stage');
  const hud = $('.app__hud');
  const title = $('.app__label');
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

  const read = () => {
    const r = pin.getBoundingClientRect();
    const s = -r.top;
    return {
      raw: clamp(s / geo.step - 0.5, 0, n - 1),
      top: window.scrollY + r.top,
    };
  };

  const measure = () => {
    if (!desktop) return;
    geo.vh = window.innerHeight;
    geo.w = phones[0].offsetWidth;
    geo.h = phones[0].offsetHeight;
    // centred between the title and the caption and rail, so neither touches the phones
    geo.cx = stage.clientWidth / 2;
    const top = title.offsetTop + title.offsetHeight + 24;
    const bottom = hud.offsetTop - 16;
    geo.cy = bottom - top >= geo.h ? (top + bottom) / 2 : Math.min((stage.clientHeight - hud.offsetHeight) / 2, stage.clientHeight / 2);
    geo.gap = geo.w * SPACING;
    geo.step = Math.max(1, (pin.offsetHeight - geo.vh) / n);
    const st = stage.style;
    st.setProperty('--cx', `${geo.cx.toFixed(1)}px`);
    st.setProperty('--cy', `${geo.cy.toFixed(1)}px`);
    st.setProperty('--pw', `${geo.w}px`);
    st.setProperty('--ph', `${geo.h}px`);
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
    let { raw } = read();
    if (reduced) {
      raw = Math.round(raw); // whole screens only: always a static, centred state
      p = raw;
    } else {
      p += (raw - p) * (1 - Math.exp(-dt / FOLLOW_MS));
      if (Math.abs(raw - p) < 0.0005) p = raw;
    }
    render();
    if (p !== raw) raf = requestAnimationFrame(frame);
    else last = 0;
  };

  const kick = () => {
    if (!raf && desktop && visible) raf = requestAnimationFrame(frame);
  };

  // The page never moves the window by itself: scroll drives the phones, and only a tick click
  // (a user action) scrolls the page.
  const onScroll = () => {
    if (!desktop || !visible) return;
    kick();
  };

  const onTick = (e) => {
    const t = e.target.closest('.app__tick');
    if (!t || !desktop) return;
    const { top } = read();
    scrollToY(Math.round(top + (Number(t.dataset.i) + 0.5) * geo.step));
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
      }
    },
    { rootMargin: '10% 0px' },
  );

  const passive = { passive: true };
  window.addEventListener('scroll', onScroll, passive);
  window.addEventListener('resize', onResize, passive);
  el.addEventListener('click', onTick);
  mqDesk.addEventListener('change', onMode);
  mqReduced.addEventListener('change', onReduced);
  io.observe(el);

  el.classList.toggle('is-reduced', reduced);
  setActive(0);
  onMode();
  // the title's height decides where the phones sit; measure again once its font is in
  document.fonts?.ready.then(() => el.isConnected && onResize());

  return {
    destroy() {
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
      io.disconnect();
      window.removeEventListener('scroll', onScroll, passive);
      window.removeEventListener('resize', onResize, passive);
      el.removeEventListener('click', onTick);
      mqDesk.removeEventListener('change', onMode);
      mqReduced.removeEventListener('change', onReduced);
      el.classList.remove('app', 'is-live', 'is-reduced');
      el.innerHTML = '';
    },
  };
}
