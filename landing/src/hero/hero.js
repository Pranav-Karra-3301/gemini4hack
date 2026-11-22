// The hero: a camera iris (Unicorn scene v5-hero) opens on the Gemini sparkle, then the shutter
// fires. Text-free (DESIGN_V5.md): only the wordmark and the tagline, set over the calm lower part
// of the scene, below the lens barrel.
//
// mountHero(section) builds the whole hero inside <section class="hero"> and returns
// { destroy(), fire() }. The scene's variables (see public/scenes/v5-hero.json):
//   open  0 pinhole -> 1 wide open; each blade swings on its pin, so the opening turns as it widens
//   fire  0 -> 1 fires the shutter: shut by 0.35, held, reopened by 1, with a flash through the seams
// Choreography: on load `open` runs 0 -> 1 over 2.2 s (ease-out, the blades rebound a hair off
// their stop), and the type rises in after it. The shutter fires 1 s after that, then every 7 s
// while the hero is on screen, and on a click or tap. Scrolling away eases the iris to 0.55.
// Under reduced motion the iris stays open and never fires. Without WebGL2 or the scene JSON,
// a CSS light stands in (src/unicorn.js adds .is-fallback) and the type still shows.
import { mountBackdrop, reducedMotion } from '../unicorn.js';
import { PRODUCT } from '../config.js';
import './hero.css';

const SRC = '/scenes/v5-hero.json';
const OPEN_MS = 2200; // the iris opening on load
const TYPE_AT_MS = 900; // the type starts rising once the iris is mostly open
const FIRE_MS = 500; // one shutter firing: the scene snaps shut fast and reopens slower
const FIRST_FIRE_MS = 1000; // after the iris settles
const EVERY_MS = 7000; // repeat while the hero is visible
const AWAY_OPEN = 0.55; // how far the iris closes as the hero scrolls away
const KICK_PX = 1.5; // the wordmark's nudge when the shutter fires
const START_ANYWAY_MS = 2500; // a scene that is slow to load doesn't hold the type back

const clamp = (v, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, v));
const smooth = (t) => t * t * (3 - 2 * t);

// Ease-out with a small overshoot (easeOutBack, about 3 %). The blades can't open past their stop,
// so the overshoot is mirrored into a short rebound below 1, like a shutter hitting its stop.
const openCurve = (t) => {
  if (t >= 1) return 1;
  const s = 0.9;
  const u = t - 1;
  const v = 1 + (s + 1) * u * u * u + s * u * u;
  return v > 1 ? 2 - v : v;
};

// The scene's own closing curve, for the CSS light and the wordmark kick.
const shutOf = (f) => Math.min(smooth(clamp(f / 0.35)), 1 - smooth(clamp((f - 0.5) / 0.5)));

export function mountHero(section) {
  const still = reducedMotion();
  section.classList.add('hero--iris');
  section.innerHTML = `
    <div class="backdrop hero__backdrop" aria-hidden="true"><div class="backdrop__css hero__light"><i></i></div></div>
    <div class="hero__type">
      <h1 class="hero__mark">${PRODUCT.name}</h1>
      <p class="hero__line">${PRODUCT.line}</p>
    </div>`;
  const mark = section.querySelector('.hero__mark');
  const host = section.querySelector('.hero__backdrop');

  let raf = 0;
  let visible = true;
  let introStart = 0; // 0 until the iris starts opening
  let intro = still ? 1 : 0;
  let introDone = still;
  let typeIn = false;
  let fireStart = 0; // 0 while the shutter is at rest
  let fireTimer = 0;
  let startTimer = 0;

  const showType = () => {
    if (typeIn) return;
    typeIn = true;
    section.classList.add('is-in');
  };

  // Sets the scene and the CSS light from the intro, the scroll position and the firing.
  const apply = (f) => {
    const r = section.getBoundingClientRect();
    const away = still ? 0 : smooth(clamp(-r.top / Math.max(1, r.height)));
    const open = (still ? 1 : openCurve(intro)) * (1 - (1 - AWAY_OPEN) * away);
    scene.setVar('open', open);
    scene.setVar('fire', f);
    section.style.setProperty('--open', open.toFixed(3));
    section.style.setProperty('--shut', shutOf(f).toFixed(3));
    const nudge = f > 0.2 && f < 0.6 ? Math.sin(Math.PI * ((f - 0.2) / 0.4)) * KICK_PX : 0;
    mark.style.setProperty('--kick', `${nudge.toFixed(2)}px`);
  };

  const tick = (now) => {
    raf = 0;
    let busy = false;
    if (introStart && !introDone) {
      intro = clamp((now - introStart) / OPEN_MS);
      if (now - introStart >= TYPE_AT_MS) showType();
      if (intro >= 1) {
        introDone = true;
        schedule(FIRST_FIRE_MS);
      } else busy = true;
    }
    let f = 0;
    if (fireStart) {
      f = (now - fireStart) / FIRE_MS;
      if (f >= 1) {
        f = 0;
        fireStart = 0;
      } else busy = true;
    }
    apply(f);
    if (busy && visible) raf = requestAnimationFrame(tick);
  };
  const kick = () => {
    if (!raf && visible) raf = requestAnimationFrame(tick);
  };

  const fire = () => {
    if (still || !introDone || !visible) return;
    if (!fireStart && !document.hidden) {
      fireStart = performance.now();
      kick();
    }
    schedule(EVERY_MS);
  };
  // One pending firing at a time, and none while the hero is off screen.
  function schedule(ms) {
    clearTimeout(fireTimer);
    fireTimer = 0;
    if (still || !visible) return;
    fireTimer = setTimeout(fire, ms);
  }

  const start = () => {
    clearTimeout(startTimer);
    if (introStart || still) return;
    introStart = performance.now();
    kick();
  };

  const scene = mountBackdrop(host, SRC, {
    vars: { open: still ? 1 : 0, fire: 0 },
    // The iris opens once there is something to see: the scene drawing, or its CSS light.
    onReady: start,
  });
  if (still) {
    showType();
    apply(0);
  } else startTimer = setTimeout(start, START_ANYWAY_MS);

  const onClick = () => fire();
  const onScroll = () => kick();
  const io = new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    if (visible) {
      kick();
      if (introDone) schedule(EVERY_MS);
    } else {
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
      clearTimeout(fireTimer);
      fireTimer = 0;
      if (fireStart) {
        fireStart = 0;
        apply(0);
      }
    }
  });

  section.addEventListener('click', onClick);
  window.addEventListener('scroll', onScroll, { passive: true });
  io.observe(section);

  return {
    fire,
    destroy() {
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
      clearTimeout(fireTimer);
      clearTimeout(startTimer);
      io.disconnect();
      section.removeEventListener('click', onClick);
      window.removeEventListener('scroll', onScroll);
      scene.destroy();
      section.classList.remove('hero--iris', 'is-in');
      section.style.removeProperty('--open');
      section.style.removeProperty('--shut');
      section.innerHTML = '';
    },
  };
}
