// Unicorn Studio backdrops: an exported scene JSON behind a section, driven by its variables.
// The same pattern as the Scout landing page (public/landing/scenes.live.js): the SDK is its own
// chunk and loads only when the first backdrop comes within a screen of the window; the page
// sets each scene's variables from scroll. Without WebGL2, or while the JSON hasn't been
// exported yet, the host keeps its CSS light. Under reduced motion the scene draws its finished
// frame and then holds still.
//
// API (node_modules/unicornstudio/dist/types.d.ts): mountScene(el, opts) -> handle; onLoad gets
// the scene, whose setVariable(name, value) and `paused` drive it.

// True when `src` is served as JSON. A scene not exported yet answers 204 in dev (vite.config.js)
// and the SPA's text/html in production, and both read as missing.
const sceneAvailable = (src) =>
  fetch(src, { method: 'HEAD', cache: 'no-cache' })
    .then((r) => r.ok && /json/i.test(r.headers.get('content-type') || ''))
    .catch(() => false);

// Keep each scene to about 2.4 million pixels a frame however big the screen.
const PIXELS = 2.4e6;
const HOLD_MS = 400;

export const reducedMotion = () => matchMedia('(prefers-reduced-motion: reduce)').matches;

let webgl2;
const hasWebGL2 = () => {
  if (webgl2 === undefined) {
    try {
      webgl2 = !!document.createElement('canvas').getContext('webgl2');
    } catch {
      webgl2 = false;
    }
  }
  return webgl2;
};

/**
 * Mounts the scene at `src` into `host` once it is near the viewport.
 * `vars` are the starting values; `still()` pauses the scene after each change (reduced motion);
 * `onReady(live)` runs once, when the scene is drawing (true) or the CSS light stays (false).
 * Returns { setVar(name, value), destroy() }. setVar is cheap to call every frame.
 */
export function mountBackdrop(host, src, { vars = {}, still = reducedMotion, onReady } = {}) {
  const pending = { ...vars };
  let scene = null;
  let handle = null;
  let mount = null;
  let dead = false;
  let hold = 0;
  let ready = false;
  const settle = (live) => {
    if (ready) return;
    ready = true;
    onReady?.(live);
  };

  const fallback = (why) => {
    host.classList.add('is-fallback');
    settle(false);
    if (why) console.warn(`[unicorn] ${src}: ${why}, keeping the CSS light`);
  };
  // Under reduced motion, render the frame the change asks for, then hold it.
  const holdStill = () => {
    if (!scene || !still()) return;
    scene.paused = false;
    clearTimeout(hold);
    hold = setTimeout(() => scene && (scene.paused = true), HOLD_MS);
  };

  const load = async () => {
    if (!hasWebGL2()) return fallback('no WebGL2');
    if (!(await sceneAvailable(src))) return fallback();
    const { mountScene } = await import('unicornstudio');
    if (dead) return;
    const dpi = Math.min(window.devicePixelRatio || 1, 1.25);
    const area = Math.max(1, host.clientWidth * host.clientHeight * dpi * dpi);
    mount = document.createElement('div');
    mount.className = 'backdrop__scene';
    host.append(mount);
    handle = mountScene(mount, {
      jsonFilePath: src,
      fps: 60,
      dpi,
      scale: Math.max(0.25, Math.min(1, Math.sqrt(PIXELS / area))),
      lazyLoad: false,
      altText: '',
      onLoad: (loaded) => {
        // Without WebGL2 the SDK hands back a stand-in with no variables.
        if (dead || typeof loaded.setVariables !== 'function') return fallback('no scene variables');
        scene = loaded;
        scene.setVariables(pending);
        host.classList.add('is-live');
        holdStill();
        settle(true);
      },
      onError: (err) => {
        fallback(`failed to load (${err?.message || err})`);
        mount?.remove();
      },
    });
  };

  const io = new IntersectionObserver(
    (entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      io.disconnect();
      load().catch((err) => fallback(String(err)));
    },
    { rootMargin: '100% 0px' },
  );
  io.observe(host);

  return {
    // Only sends a value the scene doesn't already have.
    setVar(name, value) {
      const v = Math.round(value * 1000) / 1000;
      if (pending[name] === v) return;
      pending[name] = v;
      if (!scene) return;
      scene.setVariable(name, v);
      holdStill();
    },
    destroy() {
      dead = true;
      io.disconnect();
      clearTimeout(hold);
      handle?.destroy();
      mount?.remove();
      scene = handle = mount = null;
      host.classList.remove('is-live', 'is-fallback');
    },
  };
}
