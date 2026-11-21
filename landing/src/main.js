import './style.css';
import { PRODUCT, CHAPTERS, PHONE, THESIS, HOOD } from './config.js';
import { ScenePlayer, StepTrack } from './scenes.js';

// Each section's module is a guarded dynamic import. A missing or broken module never breaks
// the build or the page: its section shows the plain copy instead.
const MODULES = {
  hero: import.meta.glob('./hero/*.js'),
  lidar: import.meta.glob('./lidar/*.js'),
  story: import.meta.glob('./story/*.js'),
  showcase: import.meta.glob('./showcase/*.js'),
  footer: import.meta.glob('./footer/*.js'),
};

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

const headMarkup = (ch) => `
    <p class="eyebrow">${pad(ch.n)} · ${ch.label}</p>
    <h2 class="h2">${ch.title}</h2>
    ${ch.lede ? `<p class="lede">${ch.lede}</p>` : ''}`;

const copyMarkup = (ch) => `
  <div class="col-text copy rv-group">
    ${headMarkup(ch)}
    ${ch.steps ? stepsMarkup(ch.steps) : ''}
  </div>`;

const MIC = `
  <button class="mic" type="button" aria-label="Talk to Heliocam">
    <svg class="mic__icon" viewBox="0 0 24 24" aria-hidden="true"><rect x="8.5" y="3" width="7" height="12" rx="3.5"/><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3"/></svg>
    <span class="mic__wave" aria-hidden="true">${'<i></i>'.repeat(17)}</span>
  </button>`;

function sectionMarkup(ch) {
  const side = `media-${ch.media || 'right'}`;
  switch (ch.kind) {
    case 'hero':
      return `
      <section class="section hero" id="${ch.id}">
        <div class="hero__stage" aria-hidden="true"></div>
        <div class="hero__scrim" aria-hidden="true"></div>
        <div class="container grid hero__grid">
          <div class="col-text hero__copy rv-group">
            <h1 class="display">${PRODUCT.name}</h1>
            <p class="lede hero__lede">${PRODUCT.line}</p>
            <p class="hero__sub">${PRODUCT.sub}</p>
            <ul class="hero__badges" aria-label="Runs on">${PRODUCT.badges.map((b) => `<li>${b}</li>`).join('')}</ul>
          </div>
        </div>
        <a class="hero__cue" href="#thesis" aria-label="Scroll down"><i></i></a>
      </section>`;
    case 'thesis':
      return `<section class="thesis-host" id="${ch.id}"></section>`;
    case 'lidar':
      return `<section class="lidar-host" id="${ch.id}" aria-label="${ch.copy.title}"></section>`;
    case 'coach':
      return `
      <section class="section section--phone section--coach ${side}" id="${ch.id}">
        <div class="coach-light" aria-hidden="true"></div>
        <div class="container grid">
          <div class="col-text copy rv-group">
            ${headMarkup(ch)}
            <div class="trace-host" data-trace>${stepsMarkup(ch.trace.map((l) => ({ text: l.text })))}</div>
          </div>
          <div class="col-media">${phoneMarkup()}</div>
        </div>
      </section>`;
    case 'showcase':
      // The module owns this section's layout once mounted.
      return `<section class="showcase-host" id="${ch.id}" aria-label="${ch.fallback.title}"></section>`;
    case 'voice':
      return `
      <section class="section section--voice ${side}" id="${ch.id}">
        <div class="voice-light" aria-hidden="true"></div>
        <div class="container grid">
          ${copyMarkup(ch)}
          <div class="col-media voice__stage rv-media">${MIC}</div>
        </div>
      </section>`;
    case 'hood':
      return `<section class="hood-host" id="${ch.id}"></section>`;
    case 'footer':
      return `<footer class="footer-host" id="${ch.id}"></footer>`;
  }
  return '';
}

$('#app').innerHTML = CHAPTERS.slice(0, -1).map(sectionMarkup).join('');
// The footer sits outside <main>, after it.
$('#app').insertAdjacentHTML('afterend', sectionMarkup(CHAPTERS.at(-1)));
const byId = (id) => document.getElementById(id);
const chapter = (kind) => CHAPTERS.find((c) => c.kind === kind);

/* ---------- scroll: parallax (--sp) and exit fade (--fade) per plain section ---------- */

// p: -1 as a section enters from below, 0 when centred, 1 once it has left at the top.
function sectionProgress(el, vh) {
  const r = el.getBoundingClientRect();
  if (r.bottom < -vh * 0.5 || r.top > vh * 1.5) return null;
  return Math.max(-1, Math.min(1, (vh / 2 - (r.top + r.height / 2)) / ((vh + r.height) / 2)));
}

const scrollers = [...document.querySelectorAll('.section')];
let scrollQueued = false;
function onScrollFrame() {
  scrollQueued = false;
  const vh = innerHeight;
  scrollers.forEach((section) => {
    const p = sectionProgress(section, vh);
    if (p === null) return;
    // Voice never fades: it must stay readable until it has fully left the screen.
    const fade = section.id === 'voice' ? 1 : 1 - Math.min(1, Math.max(0, (p - 0.4) / 0.55));
    section.style.setProperty('--sp', p.toFixed(4));
    section.style.setProperty('--fade', (fade * fade * (3 - 2 * fade)).toFixed(3));
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

/* ---------- modules ---------- */

async function loadExport(mods, dir, name) {
  const keys = Object.keys(mods)
    .filter((k) => !/demo|test|spec|worker/i.test(k))
    .sort((a, b) => Number(!a.endsWith(`/${dir}.js`)) - Number(!b.endsWith(`/${dir}.js`)));
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

// Mounts `name` from MODULES[group] into `el`. On failure, `fallback(el)` fills the section
// with plain copy so the page still reads top to bottom.
async function mountModule(el, group, name, args = [], fallback) {
  const mount = await loadExport(MODULES[group], group, name);
  try {
    if (!mount) throw new Error('module not found');
    await mount(el, ...args);
    el.classList.add('is-mounted');
  } catch (err) {
    console.warn(`[${group}] ${name} unavailable, showing plain copy:`, err);
    if (fallback) {
      fallback(el);
      el.querySelectorAll('.rv-group').forEach(revealGroup);
    }
  }
}

const plainSection = (inner) => (el) => {
  el.classList.add('section', 'section--plain');
  el.innerHTML = `<div class="container grid"><div class="col-text copy rv-group">${inner}</div></div>`;
};

// Hero: mount right away; it is the first thing on screen.
mountModule($('.hero__stage'), 'hero', 'mountHero');

whenNear(byId('thesis'), () => {
  mountModule(byId('thesis'), 'story', 'mountThesis', [], plainSection(`<h2 class="h2">${THESIS.line.join(' ')}</h2>`));
});

whenNear(byId('lidar'), () => {
  const ch = chapter('lidar');
  mountModule(byId('lidar'), 'lidar', 'mountLidar', [ch.copy], plainSection(headMarkup({ n: ch.n, ...ch.copy, label: ch.copy.label.replace(/^\d+ · /, '') })));
});

whenNear(byId('after'), () => {
  const ch = chapter('showcase');
  mountModule(byId('after'), 'showcase', 'mountShowcase', [{ chapters: [`${pad(ch.n)} · ${ch.fallback.label}`] }], plainSection(headMarkup({ n: ch.n, ...ch.fallback })));
});

whenNear(byId('hood'), () => {
  mountModule(byId('hood'), 'story', 'mountHood', [], plainSection(`<p class="eyebrow">${HOOD.label}</p><h2 class="h2">${HOOD.title}</h2><p class="lede">${HOOD.lede}</p>`));
});

whenNear(byId('footer'), () => {
  mountModule(byId('footer'), 'footer', 'mountFooter', [], (el) => {
    el.innerHTML = `<div class="container footer-plain"><p class="display">${PRODUCT.name}</p><p class="small">Built with Gemini 4 · © 2026</p></div>`;
  });
});

/* ---------- coach: phone viewfinder + Gemini's agent trace ---------- */

const VP = PHONE.viewport;
const DPR = () => Math.min(window.devicePixelRatio || 1, 2);

function setupCoach(ch) {
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

  // The trace module takes over the plain list once it loads; until then the list steps along.
  const host = $('[data-trace]', section);
  const steps = ch.trace.map((l, i) => ({ text: l.text, start: l.t, end: ch.trace[i + 1]?.t ?? ch.loop }));
  let track = new StepTrack($('.steps', host), steps);
  const proxy = { render: (t) => track.render(t), reset: () => track.reset() };
  loadExport(MODULES.story, 'story', 'AgentTrace').then((AgentTrace) => {
    if (!AgentTrace) return;
    try {
      host.replaceChildren();
      track = new AgentTrace(host, ch);
      host.classList.add('is-mounted');
    } catch (err) {
      console.warn('[story] AgentTrace failed, keeping the plain list', err);
    }
  });

  const player = new ScenePlayer(box, ch.phone, {
    track: proxy,
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
setupCoach(chapter('coach'));

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

  const ch = chapter('voice');
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
function revealGroup(g) {
  g.querySelectorAll('.display, .eyebrow, .h2, .h3, .lede, .step, .hero__sub, .hero__badges').forEach((el, i) => {
    el.classList.add('rv');
    el.style.setProperty('--i', i);
  });
  revealer.observe(g);
}
document.querySelectorAll('.rv-group').forEach(revealGroup);
document.querySelectorAll('.rv-media').forEach((el) => revealer.observe(el));
