import './style.css';
import { PRODUCT, CHAPTERS, SCENES, GEMINI, TITLES } from './config.js';
import { mountBackdrop, reducedMotion } from './unicorn.js';
import { sectionTitle } from './title/title.js';
import { mountLive } from './live/live.js';
import { startSmoothScroll, scrollToY } from './scroll.js';

// Each section's module is a guarded import. A missing or broken module never breaks the build or
// the page: its section shows its title instead. The heavy ones (WebGL, data) load when near, into
// hosts that already hold their final height (style.css). Compare and the app gallery are plain DOM
// whose height follows their content, so they are bundled (eager) and mount before the first paint.
const MODULES = {
  hero: import.meta.glob('./hero/*.js'),
  lidar: import.meta.glob('./lidar/*.js'),
  compare: import.meta.glob('./compare/*.js', { eager: true }),
  showcase: import.meta.glob('./showcase/*.js'),
  looks: import.meta.glob('./looks/*.js'),
  app: import.meta.glob('./app/*.js', { eager: true }),
  footer: import.meta.glob('./footer/*.js'),
};

const $ = (sel, root = document) => root.querySelector(sel);
const clamp = (v) => Math.max(0, Math.min(1, v));
const smooth = (t) => t * t * (3 - 2 * t);
const easeOut = (t) => 1 - (1 - t) * (1 - t);
const still = reducedMotion();

document.title = `${PRODUCT.name}: ${PRODUCT.line.replace(/\.$/, '')}`;

/* ---------- markup ---------- */

// The Gemini sparkle: a four-point star with concave sides, blue into violet.
const sparkle = (id) => `
  <svg class="sparkle" viewBox="0 0 24 24" aria-hidden="true">
    <defs><linearGradient id="${id}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#4C8DFF"/><stop offset="1" stop-color="#9A7CF6"/></linearGradient></defs>
    <path fill="url(#${id})" d="M12 0C12.6 6.4 17.6 11.4 24 12C17.6 12.6 12.6 17.6 12 24C11.4 17.6 6.4 12.6 0 12C6.4 11.4 11.4 6.4 12 0Z"/>
  </svg>`;

function sectionMarkup(ch) {
  switch (ch.kind) {
    case 'hero':
      // src/hero/ mountHero(el) owns this section; heroFallback() fills it until that module exists.
      return `<section class="hero" id="${ch.id}"></section>`;
    case 'gemini':
      return `
      <section class="gemini" id="${ch.id}" aria-label="${GEMINI.label}">
        <div class="gemini__stage">
          <div class="backdrop gemini__backdrop" aria-hidden="true"><div class="backdrop__css gemini__light"><i class="gemini__line"></i></div></div>
          <p class="gemini__brand">${sparkle('sparkle-gemini')}<span>${GEMINI.label}</span></p>
          <ul class="gemini__models">
            ${GEMINI.models.map((m) => `<li class="gemini__model" style="--c:${m.color}"><span class="gemini__id">${m.id}</span><span class="gemini__role">${m.role}</span><i></i></li>`).join('')}
          </ul>
        </div>
      </section>`;
    case 'lidar':
      return `<section class="lidar-host" id="${ch.id}" aria-label="${TITLES.lidar}"></section>`;
    case 'live':
      return `<section class="live" id="${ch.id}" aria-label="Live"></section>`;
    case 'compare':
      return `<section class="compare-host" id="${ch.id}"></section>`;
    case 'showcase':
      return `<section class="showcase-host" id="${ch.id}" aria-label="${TITLES.after}"></section>`;
    case 'looks':
      return `<section class="looks-host" id="${ch.id}" aria-label="${TITLES.looks}"></section>`;
    case 'app':
      return `<section class="app-host" id="${ch.id}" aria-label="${TITLES.app}"></section>`;
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

/* ---------- hero: src/hero/ mountHero(el) once it exists, else the wordmark over v5-hero ---------- */

const hero = byId('top');
let renderHero = null; // set by the fallback: the iris closes a little as you scroll away

// The fallback hero: an iris opens on the sparkle on load, with the wordmark and tagline under it.
function heroFallback(el) {
  el.classList.add('hero--fallback');
  el.innerHTML = `
    <div class="backdrop hero__backdrop" aria-hidden="true"><div class="backdrop__css hero__light"><i></i>${sparkle('sparkle-hero')}</div></div>
    <div class="hero__title">
      <h1 class="hero__mark">${PRODUCT.name}</h1>
      <p class="hero__line">${PRODUCT.line}</p>
    </div>`;
  let intro = still ? 1 : 0;
  let introStart = 0;
  let scene = null;
  const render = () => {
    const away = still ? 0 : smooth(clamp(scrollY / Math.max(1, el.offsetHeight)));
    const open = intro * (1 - 0.4 * away);
    scene?.setVar('open', open);
    el.style.setProperty('--open', open.toFixed(3));
  };
  const frame = (now) => {
    introStart ||= now;
    intro = easeOut(clamp((now - introStart) / 2500));
    render();
    if (intro < 1) requestAnimationFrame(frame);
    else renderHero = render;
  };
  // The iris opens once there is something to see: the scene drawing, or its CSS light.
  let queued = false;
  const start = () => {
    if (queued) return;
    queued = true;
    if (still) {
      render();
      renderHero = render;
    } else requestAnimationFrame(frame);
  };
  scene = mountBackdrop($('.hero__backdrop', el), SCENES.hero, { vars: { open: intro }, onReady: start });
  setTimeout(start, 2000);
}

// Mounted right away (not when near): it is the first screen.
if (Object.keys(MODULES.hero).length) mountModule(hero, 'hero', 'mountHero', [], heroFallback);
else heroFallback(hero);

/* ---------- Gemini 4: the line draws, the "4" lights, then each model along the line ---------- */

const gemini = byId('gemini');
const geminiScene = mountBackdrop($('.gemini__backdrop', gemini), SCENES.gemini, { vars: { lit: still ? 1 : 0 } });
const geminiChips = [...gemini.querySelectorAll('.gemini__models li')];
function renderGemini(vh) {
  const r = gemini.getBoundingClientRect();
  if (r.bottom < -vh * 0.2 || r.top > vh * 1.2) return;
  // 0 once the stage is mostly on screen, 1 just before the pin lets go.
  const held = r.height - vh;
  const lit = still ? 1 : clamp((vh * 0.2 - r.top) / (vh * 0.2 + held * 0.9));
  geminiScene.setVar('lit', lit);
  gemini.style.setProperty('--lit', lit.toFixed(3));
  geminiChips.forEach((li, i) => li.classList.toggle('is-on', lit >= 0.5 + i * 0.1));
}

/* ---------- scroll ---------- */

let scrollQueued = false;
function onScrollFrame() {
  scrollQueued = false;
  renderHero?.();
  renderGemini(innerHeight);
}
const queueScroll = () => {
  if (scrollQueued) return;
  scrollQueued = true;
  requestAnimationFrame(onScrollFrame);
};
addEventListener('scroll', queueScroll, { passive: true });
addEventListener('resize', queueScroll);
onScrollFrame();

/* ---------- live loop ---------- */

try {
  mountLive(byId('live'));
} catch (err) {
  console.error('[live] failed to mount', err);
}

/* ---------- modules ---------- */

async function loadExport(mods, dir, name) {
  const keys = Object.keys(mods)
    .filter((k) => !/demo|test|spec|worker/i.test(k))
    .sort((a, b) => Number(!a.endsWith(`/${dir}.js`)) - Number(!b.endsWith(`/${dir}.js`)));
  for (const k of keys) {
    try {
      const m = typeof mods[k] === 'function' ? await mods[k]() : mods[k];
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

// Mounts `name` from MODULES[group] into `el`. On failure, `fallback(el)` fills the section.
// A group with no files yet (a module still being built) is skipped quietly.
async function mountModule(el, group, name, args = [], fallback) {
  if (!Object.keys(MODULES[group]).length) return;
  const mount = await loadExport(MODULES[group], group, name);
  try {
    if (!mount) throw new Error('module not found');
    await mount(el, ...args);
    el.classList.add('is-mounted');
  } catch (err) {
    console.warn(`[${group}] ${name} unavailable:`, err);
    fallback?.(el);
  }
}

// A section whose module fails keeps its title.
const titleOnly = (text) => (el) => {
  const box = document.createElement('div');
  box.className = 'container';
  box.append(sectionTitle(text));
  el.classList.add('section--plain');
  el.replaceChildren(box);
};

whenNear(byId('lidar'), () => {
  mountModule(byId('lidar'), 'lidar', 'mountLidar', [chapter('lidar').copy], titleOnly(TITLES.lidar));
});

mountModule(byId('compare'), 'compare', 'mountCompare');

whenNear(byId('after'), () => mountModule(byId('after'), 'showcase', 'mountShowcase', [], titleOnly(TITLES.after)));

whenNear(byId('looks'), () => {
  mountModule(byId('looks'), 'looks', 'mountLooks', [chapter('looks')], titleOnly(TITLES.looks));
});

mountModule(byId('in-app'), 'app', 'mountApp', [], titleOnly(TITLES.app));

whenNear(byId('footer'), () => {
  mountModule(byId('footer'), 'footer', 'mountFooter', [], (el) => {
    el.innerHTML = `<div class="container footer-plain"><p class="display">${PRODUCT.name}</p></div>`;
  });
});

/* ---------- smooth scrolling (src/scroll.js); in-page links glide there through it ---------- */

startSmoothScroll();
document.addEventListener('click', (e) => {
  const link = e.target.closest?.('a[href^="#"]');
  const target = link && link.hash.length > 1 && document.getElementById(decodeURIComponent(link.hash.slice(1)));
  if (!target) return;
  e.preventDefault();
  scrollToY(target.getBoundingClientRect().top + scrollY);
});
