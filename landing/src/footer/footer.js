// Footer: the page ends at dawn. A Unicorn Studio sunrise (/scenes/v5-footer.json) fills the footer and
// its `rise` variable is scrubbed from scroll: 0 when the footer's top meets the bottom of the window,
// 1 when the footer is fully in view. The "Heliocam" wordmark sits big and solid in the clean sky above
// the horizon, frost turning to warm white as the sun comes up, and rises into place with the same
// scroll. The credits row sits on the dark foreground. Without WebGL2, or before the scene is exported,
// a CSS dawn takes the scene's place (src/unicorn.js adds .is-fallback) and follows the same `rise`.
// Under reduced motion the sun is up and the wordmark is shown, with nothing tied to scroll.
// Usage: const { destroy } = mountFooter(document.querySelector('footer'));
import './footer.css';
import { PRODUCT } from '../config.js';
import { mountBackdrop, reducedMotion } from '../unicorn.js';

const SCENE = '/scenes/v5-footer.json'; // variable `rise`: 0 pre-dawn, 1 the sun two-thirds up
const ICON = '/assets/ios-AppIcon-1024.png';
// The wordmark's entrance, in shares of the scroll: it is fully opaque while still low in the window,
// so it never reads as a grey ghost, and finishes its 18 px lift as the footer settles.
const SHOW_FROM = 0.28;
const FADE_SPAN = 0.32;
const LIFT_SPAN = 0.5;

const clamp = (v) => Math.max(0, Math.min(1, v));
const easeOut = (t) => 1 - (1 - t) * (1 - t);
const smooth = (t) => t * t * (3 - 2 * t);

const markup = (name) => `
  <div class="footer__sky" aria-hidden="true">
    <div class="footer__dawn">
      <div class="footer__halo"></div>
      <div class="footer__sun"></div>
      <div class="footer__ground"></div>
      <div class="footer__grain"></div>
    </div>
  </div>
  <p class="footer__word" translate="no">${name}</p>
  <div class="footer__credits">
    <div class="footer__app">
      <img class="footer__icon" src="${ICON}" alt="" width="36" height="36" decoding="async" loading="lazy" />
      <span>${name} for iPhone</span>
    </div>
    <p class="footer__note">Built with Gemini 4 &middot; &copy; 2026</p>
  </div>`;

export function mountFooter(el) {
  const still = reducedMotion();
  el.classList.add('footer');
  el.innerHTML = markup(PRODUCT.name);

  const backdrop = mountBackdrop(el.querySelector('.footer__sky'), SCENE, { vars: { rise: still ? 1 : 0 } });

  // t is the linear scroll progress; the scene and the CSS dawn get it eased, the wordmark its own window.
  const apply = (t) => {
    const rise = easeOut(t);
    backdrop.setVar('rise', rise);
    el.style.setProperty('--rise', rise.toFixed(3));
    el.style.setProperty('--show', smooth(clamp((t - SHOW_FROM) / FADE_SPAN)).toFixed(3));
    el.style.setProperty('--lift', (1 - smooth(clamp((t - SHOW_FROM) / LIFT_SPAN))).toFixed(3));
  };

  if (still) {
    apply(1);
    return {
      destroy() {
        backdrop.destroy();
        reset(el);
      },
    };
  }

  let raf = 0;
  let near = false;
  const measure = () => {
    raf = 0;
    const r = el.getBoundingClientRect();
    apply(clamp((innerHeight - r.top) / Math.max(1, r.height)));
  };
  const schedule = () => {
    if (near && !raf) raf = requestAnimationFrame(measure);
  };
  // Only measure while the footer is within a screen of the window.
  const io = new IntersectionObserver(
    ([e]) => {
      near = e.isIntersecting;
      if (near) schedule();
      else apply(0);
    },
    { rootMargin: '100% 0px' },
  );
  io.observe(el);
  addEventListener('scroll', schedule, { passive: true });
  addEventListener('resize', schedule);
  apply(0);

  return {
    destroy() {
      io.disconnect();
      removeEventListener('scroll', schedule);
      removeEventListener('resize', schedule);
      cancelAnimationFrame(raf);
      backdrop.destroy();
      reset(el);
    },
  };
}

function reset(el) {
  el.replaceChildren();
  el.classList.remove('footer');
  el.style.removeProperty('--rise');
  el.style.removeProperty('--show');
  el.style.removeProperty('--lift');
}
