import './style.css';
import { PRODUCT, CHAPTERS, SCENES, ART, PHONE } from './config.js';
import { LazyScene, ScenePlayer, StepTrack } from './scenes.js';

// Sections owned by other agents: guarded dynamic imports. Globs resolve to {} until the
// files exist, so a missing or broken module never breaks the build or the page.
const showcaseModules = import.meta.glob('./showcase/*.js');
const macModules = import.meta.glob('./mac/*.js');
const finaleModules = import.meta.glob('./finale/*.js');

const $ = (sel, root = document) => root.querySelector(sel);
const pad = (n) => String(n).padStart(2, '0');
const pct = (a, b) => `${((a / b) * 100).toFixed(4)}%`;

document.title = `${PRODUCT.name}: ${PRODUCT.line.replace(/\.$/, '').replace(/^A /, 'a ')}`;

/* ---------- markup ---------- */

// The screen rect of the bezel PNG, in % of the frame, so the scene is clipped exactly.
const { frame: F, screen: S } = PHONE;
const SCREEN_STYLE = [
  `left:${pct(S.x, F.w)}`,
  `top:${pct(S.y, F.h)}`,
  `width:${pct(S.w, F.w)}`,
  `height:${pct(S.h, F.h)}`,
  `border-radius:${pct(S.r, S.w)} / ${pct(S.r, S.h)}`,
].join(';');

const phoneMarkup = () => `
  <div class="phone-wrap rv-media">
    <figure class="phone" style="aspect-ratio:${F.w} / ${F.h}">
      <div class="phone__screen" style="${SCREEN_STYLE}">
        <div class="phone__box" style="width:${PHONE.viewport.w}px;height:${PHONE.viewport.h}px" aria-hidden="true"></div>
      </div>
      <img class="phone__bezel" src="${PHONE.bezel}" alt="" draggable="false" decoding="async" />
    </figure>
  </div>`;

const stepsMarkup = (steps) =>
  `<ol class="steps">${steps
    .map((s, i) => `<li class="step"><span class="step__num">${pad(i + 1)}</span><span class="step__text">${s.text}</span></li>`)
    .join('')}</ol>`;

const copyMarkup = (ch) => `
  <div class="col-text copy rv-group">
    <p class="eyebrow">${pad(ch.n)} · ${ch.label}</p>
    <h2 class="h2">${ch.title}</h2>
    ${ch.lede ? `<p class="lede">${ch.lede}</p>` : ''}
    ${ch.steps ? stepsMarkup(ch.steps) : ''}
  </div>`;

const MIC = `
  <button class="mic" type="button" aria-label="Hold to talk">
    <svg class="mic__icon" viewBox="0 0 24 24" aria-hidden="true"><rect x="8.5" y="3" width="7" height="12" rx="3.5"/><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3"/></svg>
    <span class="mic__wave" aria-hidden="true">${'<i></i>'.repeat(17)}</span>
  </button>`;

const artMarkup = (id) => (ART[id] ? `<div class="art-img" style="background-image:url('${ART[id]}')"></div>` : '');

function sectionMarkup(ch) {
  const side = `media-${ch.media || 'right'}`;
  switch (ch.kind) {
    case 'hero':
      return `
      <section class="section hero" id="${ch.id}">
        <div class="fx fx--hero" aria-hidden="true"></div>
        <div class="hero__scrim" aria-hidden="true"></div>
        <div class="container grid hero__grid">
          <div class="col-text hero__copy rv-group">
            <h1 class="display">${PRODUCT.name}</h1>
            <p class="lede hero__lede">${PRODUCT.line}</p>
            <p class="eyebrow hero__powered">${PRODUCT.poweredBy}</p>
          </div>
          <div class="col-media hero__media">${phoneMarkup()}</div>
        </div>
      </section>`;
    case 'phone':
      return `
      <section class="section section--phone ${side}" id="${ch.id}">
        <div class="fx fx--art fx--${ch.id}" aria-hidden="true">${artMarkup(ch.id)}</div>
        <div class="container grid">
          ${copyMarkup(ch)}
          <div class="col-media">${phoneMarkup()}</div>
        </div>
      </section>`;
    case 'showcase':
      // The module owns this section's layout once mounted.
      return `<section class="showcase-host" id="${ch.id}" aria-label="Sees in depth, edits with you"></section>`;
    case 'mac':
      return `
      <section class="section section--mac ${side}" id="${ch.id}">
        <div class="mac-glow" aria-hidden="true"></div>
        <div class="container grid">
          ${copyMarkup(ch)}
          <div class="col-media mac-stage rv-media" data-mac-stage></div>
        </div>
      </section>`;
    case 'voice':
      return `
      <section class="section section--voice ${side}" id="${ch.id}">
        <div class="fx fx--art fx--voice" aria-hidden="true">${artMarkup(ch.id)}</div>
        <div class="container grid">
          ${copyMarkup(ch)}
          <div class="col-media voice__stage rv-media">${MIC}</div>
        </div>
      </section>`;
    case 'finale':
      return `<section class="finale" id="${ch.id}"></section>`;
  }
  return '';
}

$('#app').innerHTML = CHAPTERS.map(sectionMarkup).join('');
const byId = (id) => document.getElementById(id);

/* ---------- full-bleed scenes ---------- */

const scrollers = []; // { section, scene? }
const sceneFor = { top: SCENES.hero };
CHAPTERS.forEach((ch) => {
  const section = byId(ch.id);
  if (!section || ch.kind === 'finale' || ch.kind === 'showcase') return;
  const fx = $('.fx', section);
  const scene = fx && sceneFor[ch.id] ? new LazyScene(fx, sceneFor[ch.id], { margin: '10% 0px' }) : null;
  scrollers.push({ section, scene });
});

/* ---------- scroll: parallax (--sp) and exit fade (--fade) per section ---------- */

// p: -1 as a section enters from below, 0 when centred, 1 once it has left at the top.
function sectionProgress(el, vh) {
  const r = el.getBoundingClientRect();
  if (r.bottom < -vh * 0.5 || r.top > vh * 1.5) return null;
  return Math.max(-1, Math.min(1, (vh / 2 - (r.top + r.height / 2)) / ((vh + r.height) / 2)));
}

let scrollQueued = false;
function onScrollFrame() {
  scrollQueued = false;
  const vh = innerHeight;
  scrollers.forEach(({ section, scene }) => {
    const p = sectionProgress(section, vh);
    if (p === null) return;
    // Voice never fades: it must stay readable until it has fully left the screen.
    const fade = section.id === 'voice' ? 1 : 1 - Math.min(1, Math.max(0, (p - 0.4) / 0.55));
    section.style.setProperty('--sp', p.toFixed(4));
    section.style.setProperty('--fade', (fade * fade * (3 - 2 * fade)).toFixed(3));
    scene?.setScroll((p + 1) / 2);
  });
}
const queueScroll = () => {
  if (scrollQueued) return;
  scrollQueued = true;
  requestAnimationFrame(onScrollFrame);
};
addEventListener('scroll', queueScroll, { passive: true });
addEventListener('resize', queueScroll);
onScrollFrame();

/* ---------- phone screens: scenes laid out at design size, scaled into the bezel ---------- */

const VP = PHONE.viewport;
const DPR = () => Math.min(window.devicePixelRatio || 1, 2);

function setupPhone(ch) {
  const section = byId(ch.id);
  const screen = $('.phone__screen', section);
  const box = $('.phone__box', screen);
  let s = 1;
  // Cover-fit the 393 x 852 box into the screen rect (aspects differ by < 0.3%).
  new ResizeObserver(() => {
    const w = screen.clientWidth;
    const h = screen.clientHeight;
    if (!w || !h) return;
    s = Math.max(w / VP.w, h / VP.h);
    box.style.transform = `translate(${((w - VP.w * s) / 2).toFixed(2)}px, ${((h - VP.h * s) / 2).toFixed(2)}px) scale(${s.toFixed(5)})`;
  }).observe(screen);

  const list = $('.steps', section);
  const track = list && ch.steps ? new StepTrack(list, ch.steps) : null;
  const player = new ScenePlayer(box, ch.phone, {
    track,
    loop: ch.loop || 0,
    // Render at the on-screen pixel density of the scaled box, never below 1.5.
    options: () => ({ dpi: Math.min(3, Math.max(1.5, s * DPR() * 1.25)), scale: 1 }),
  });

  // Mount when the phone is on screen, destroy when it leaves, replay on re-entry.
  let playing = false;
  new IntersectionObserver(
    ([e]) => {
      if (e.isIntersecting && e.intersectionRatio >= 0.2 && !playing) {
        playing = true;
        player.play();
      } else if (!e.isIntersecting && playing) {
        playing = false;
        player.stop();
      }
    },
    { threshold: [0, 0.2] },
  ).observe(screen);
}

CHAPTERS.forEach((ch) => ch.phone && setupPhone(ch));

/* ---------- optional modules owned by other agents ---------- */

async function loadExport(mods, dir, name) {
  const rank = (k) => (k.endsWith('/index.js') ? 0 : k.endsWith(`/${dir}.js`) ? 1 : 2);
  const keys = Object.keys(mods)
    .filter((k) => !/demo|test|spec|worker/i.test(k))
    .sort((a, b) => rank(a) - rank(b));
  for (const k of keys) {
    try {
      const m = await mods[k]();
      if (typeof m[name] === 'function') return m[name];
    } catch (err) {
      console.warn(`[${dir}] ${k} failed to load`, err);
    }
  }
  return null;
}

// Runs `fn` once, when `el` comes within ~1.5 viewports.
function whenNear(el, fn) {
  const io = new IntersectionObserver(
    ([e]) => {
      if (!e.isIntersecting) return;
      io.disconnect();
      fn();
    },
    { rootMargin: '150% 0px' },
  );
  io.observe(el);
}

// Mac: the module renders into the media column. Steps follow its lesson dots once it is
// mounted, `heliocam:step` ({ index }) / `heliocam:time` ({ t }) events dispatched on the
// stage, or a <video> inside it; a looping clock stands in before any of those exist.
function setupMac() {
  const ch = CHAPTERS.find((c) => c.kind === 'mac');
  const section = ch && byId(ch.id);
  if (!section) return;
  const stage = $('[data-mac-stage]', section);
  const track = new StepTrack($('.steps', section), ch.steps);
  let driven = false;
  let visible = false;
  let raf = 0;
  let t0 = 0;
  stage.addEventListener('heliocam:step', (e) => {
    if (!Number.isInteger(e.detail?.index)) return;
    driven = true;
    track.setIndex(e.detail.index);
  });
  stage.addEventListener('heliocam:time', (e) => {
    if (!Number.isFinite(e.detail?.t)) return;
    driven = true;
    track.render(e.detail.t);
  });
  const tick = (now) => {
    if (!visible) return;
    if (!driven) {
      const v = $('video', stage);
      track.render(v && v.readyState >= 2 && !v.paused ? v.currentTime : ((now - t0) / 1000) % ch.loop);
    }
    raf = requestAnimationFrame(tick);
  };
  new IntersectionObserver(([e]) => {
    visible = e.isIntersecting;
    cancelAnimationFrame(raf);
    if (visible) {
      t0 = performance.now();
      raf = requestAnimationFrame(tick);
    } else if (!driven) track.reset();
  }, { threshold: 0.2 }).observe(section);

  whenNear(section, async () => {
    const mount = await loadExport(macModules, 'mac', 'mountMacSection');
    if (!mount) {
      console.info('[mac] module not there yet, showing the empty stage');
      return;
    }
    try {
      await mount(stage);
      section.classList.add('is-mounted');
      // The module's lesson dots (one intro dot + one per step) become the step clock.
      const syncDots = () => {
        const dots = [...stage.querySelectorAll('.hm__dots i')];
        const on = dots.findIndex((d) => d.classList.contains('is-on'));
        if (on < 0) return;
        driven = true;
        track.setIndex(dots.length === ch.steps.length + 1 ? on - 1 : on);
      };
      new MutationObserver(syncDots).observe(stage, { subtree: true, attributes: true, attributeFilter: ['class'] });
      syncDots();
    } catch (err) {
      console.warn('[mac] mountMacSection failed', err);
    }
  });
}

function setupFinale() {
  const section = byId('finale');
  if (!section) return;
  whenNear(section, async () => {
    const mount = await loadExport(finaleModules, 'finale', 'mountFinale');
    try {
      if (!mount) throw new Error('module not there yet');
      await mount(section);
      section.classList.add('is-mounted');
    } catch (err) {
      console.info('[finale] placeholder in use:', err.message);
      section.classList.add('finale--placeholder');
      section.innerHTML = `<div class="container"><p class="display">${PRODUCT.poweredBy}</p></div>`;
    }
  });
}

// Showcase: "Sees in depth" + "Edits with you" (src/showcase/). The module owns the section;
// if it is missing or throws, a plain chapter with the same copy stands in.
function setupShowcase() {
  const ch = CHAPTERS.find((c) => c.kind === 'showcase');
  const section = ch && byId(ch.id);
  if (!section) return;
  whenNear(section, async () => {
    const mount = await loadExport(showcaseModules, 'showcase', 'mountShowcase');
    try {
      if (!mount) throw new Error('module not there yet');
      await mount(section);
      section.classList.add('is-mounted');
    } catch (err) {
      console.info('[showcase] placeholder in use:', err.message);
      section.replaceChildren();
      section.classList.add('section', 'showcase-host--placeholder');
      section.innerHTML = `<div class="container grid">${copyMarkup({ n: ch.n, ...ch.fallback })}</div>`;
      const g = $('.rv-group', section);
      g.querySelectorAll('.eyebrow, .h2, .lede').forEach((el, i) => {
        el.classList.add('rv');
        el.style.setProperty('--i', i);
      });
      revealer.observe(g);
    }
  });
}

setupShowcase();
setupMac();
setupFinale();

/* ---------- voice: mic capsule + steps on a loop while in view ---------- */

const mic = $('.mic');
if (mic) {
  let held = false;
  const sync = (auto) => mic.classList.toggle('is-listening', held || auto);
  mic.addEventListener('pointerdown', () => ((held = true), sync(false)));
  ['pointerup', 'pointerleave', 'pointercancel'].forEach((ev) =>
    mic.addEventListener(ev, () => ((held = false), sync(false))),
  );
  const bars = mic.querySelectorAll('.mic__wave i');
  bars.forEach((b, i) => {
    b.style.setProperty('--i', i);
    b.style.setProperty('--amp', (0.28 + 0.62 * Math.sin((Math.PI * (i + 0.5)) / bars.length)).toFixed(2));
  });

  const ch = CHAPTERS.find((c) => c.kind === 'voice');
  const section = byId(ch.id);
  const list = $('.steps', section);
  const track = list && ch.steps ? new StepTrack(list, ch.steps) : null;
  let raf = 0;
  let t0 = 0;
  const tick = (now) => {
    const t = ((now - t0) / 1000) % ch.loop;
    track?.render(t);
    if (ch.listen) sync(t >= ch.listen[0] && t < ch.listen[1]);
    raf = requestAnimationFrame(tick);
  };
  new IntersectionObserver(
    ([e]) => {
      cancelAnimationFrame(raf);
      if (e.isIntersecting) {
        t0 = performance.now();
        raf = requestAnimationFrame(tick);
      } else {
        track?.reset();
        sync(false);
      }
    },
    { threshold: 0.35 },
  ).observe(section);
}

/* ---------- scroll reveal: opacity + 16px rise, staggered ---------- */

document.querySelectorAll('.rv-group').forEach((g) => {
  g.querySelectorAll('.display, .eyebrow, .h2, .h3, .lede, .step').forEach((el, i) => {
    el.classList.add('rv');
    el.style.setProperty('--i', i);
  });
});

// Reveal on entry; reset only once a group drops back below the fold, so scrolling up
// never blanks what you just read but scrolling down again replays the motion.
const revealer = new IntersectionObserver(
  (entries) =>
    entries.forEach((e) => {
      if (e.isIntersecting) e.target.classList.add('is-in');
      else if (e.boundingClientRect.top > 0) e.target.classList.remove('is-in');
    }),
  { threshold: 0.12, rootMargin: '0px 0px -6% 0px' },
);
document.querySelectorAll('.rv-group, .rv-media').forEach((el) => revealer.observe(el));
