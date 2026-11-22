// Smooth, natural scrolling, set up as on the Scout landing page. Lenis smooths the wheel and
// trackpad without taking scrolling over: no snapping, no glides you did not ask for. Touch stays
// native, and prefers-reduced-motion turns it off. Lenis drives the real window scroll, so scrollY
// and scroll events are as before: every section still reads where the page is.
import Lenis from './vendor/lenis.mjs';
import { reducedMotion } from './unicorn.js';

let lenis = null;

// Called once by main.js. Modules never start it, so each one's demo.html keeps native scrolling.
export function startSmoothScroll() {
  if (lenis || reducedMotion()) return lenis;
  lenis = new Lenis({ lerp: 0.11, wheelMultiplier: 0.9, smoothWheel: true, anchors: false });
  const frame = (time) => {
    lenis.raf(time);
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
  return lenis;
}

// Moves the page to `top` (px). Only for user actions such as a click: the page never moves by itself.
export function scrollToY(top, done) {
  if (!lenis) {
    window.scrollTo({ top, behavior: reducedMotion() ? 'instant' : 'smooth' });
    done?.();
    return;
  }
  lenis.scrollTo(top, { duration: 1.1, easing: (t) => 1 - Math.pow(1 - t, 4), onComplete: () => done?.() });
}
