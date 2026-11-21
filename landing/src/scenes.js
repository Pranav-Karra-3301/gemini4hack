// Unicorn Studio scenes loaded from local exported JSON files, plus the small media
// helpers the page uses (asset availability, step tracks synced to a clock).
// API: mountScene(element, { jsonFilePath }) from the `unicornstudio` package.
import { mountScene } from 'unicornstudio';

const availability = new Map();
const RECHECK_MS = 4000;

/**
 * True when `src` exists and is served with a content-type matching `type` (missing files
 * fall back to index.html in dev). Hits are cached; misses are re-checked after a few
 * seconds, so media another agent drops in later is picked up on the next entry.
 */
export function assetAvailable(src, type = /json/i) {
  if (!src) return Promise.resolve(false);
  const hit = availability.get(src);
  if (hit && (hit.ok !== false || Date.now() - hit.at < RECHECK_MS)) return hit.p;
  const entry = { at: Date.now(), ok: undefined, p: null };
  entry.p = fetch(src, { method: 'HEAD', cache: 'no-cache' })
    .then((r) => r.ok && type.test(r.headers.get('content-type') || ''))
    .catch(() => false)
    .then((ok) => {
      entry.ok = ok;
      if (!ok && !hit) console.info(`[media] ${src} not there yet, keeping the dark fallback`);
      return ok;
    });
  availability.set(src, entry);
  return entry.p;
}

/** Drops a cached result, e.g. after a file failed to decode. */
export const forgetAsset = (src) => availability.delete(src);

export const sceneAvailable = (src) => assetAvailable(src, /json/i);

const LOAD_TIMEOUT = 15000;

/** Mounts one scene into a fresh child of `host`. Resolves { handle, el } or null on error. */
function mountInto(host, src, extra = {}) {
  const el = document.createElement('div');
  el.className = 'scene-mount';
  host.appendChild(el);
  return new Promise((resolve) => {
    let handle;
    let settled = false;
    const done = (ok) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (ok) {
        // The host may have been laid out after the SDK measured it.
        requestAnimationFrame(() => handle?.scene?.resize?.());
        resolve({ handle, el });
      } else {
        handle?.destroy();
        el.remove();
        resolve(null);
      }
    };
    const timer = setTimeout(() => {
      console.warn(`[scenes] ${src} timed out`);
      done(false);
    }, LOAD_TIMEOUT);
    handle = mountScene(el, {
      jsonFilePath: src,
      lazyLoad: false,
      ...extra,
      onLoad: () => done(true),
      onError: (err) => {
        console.warn(`[scenes] ${src} failed`, err);
        done(false);
      },
    });
  });
}

function destroyMounted(m) {
  if (!m) return;
  m.handle.destroy();
  m.el.remove();
}

const resizer = new ResizeObserver((entries) => {
  entries.forEach((e) => e.target.__scene?.handle?.scene?.resize?.());
});

/**
 * A full-bleed scene that mounts when its host nears the viewport and is destroyed once
 * it leaves. Missing scenes leave the host empty (the section stays plain ink).
 */
export class LazyScene {
  constructor(host, src, { margin = '20% 0px' } = {}) {
    this.host = host;
    this.src = src;
    this.token = 0;
    this.current = null;
    new IntersectionObserver(([e]) => (e.isIntersecting ? this.mount() : this.unmount()), {
      rootMargin: margin,
    }).observe(host);
  }

  async mount() {
    const token = ++this.token;
    if (!(await sceneAvailable(this.src)) || token !== this.token) return;
    const next = await mountInto(this.host, this.src);
    if (token !== this.token) return destroyMounted(next);
    if (!next) return;
    this.current = next;
    this.host.__scene = next;
    const defs = next.handle.scene?.getVariableDefinitions?.() || [];
    this.vars = new Set(defs.map((d) => d.name));
    if (this.lastScroll !== undefined) this.setScroll(this.lastScroll);
    resizer.observe(this.host);
    requestAnimationFrame(() => next.el.classList.add('is-in'));
    this.host.classList.add('is-live');
  }

  /** Feeds 0..1 section progress to scenes that publish a `scrollProgress` variable. */
  setScroll(v) {
    this.lastScroll = v;
    if (this.vars?.has('scrollProgress')) this.current?.handle.scene?.setVariable?.('scrollProgress', v);
  }

  unmount() {
    this.token++;
    if (!this.current) return;
    const prev = this.current;
    this.current = null;
    this.host.__scene = null;
    resizer.unobserve(this.host);
    this.host.classList.remove('is-live');
    destroyMounted(prev);
  }
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Plays a phone's scene sequence inside a fixed design-size box. Items mount in order,
 * each held `duration` s; the last one starts the step clock (seconds since it loaded)
 * and, with `loop`, re-mounts after `loop` s with a crossfade. play() restarts from the
 * top (call it on every entry); stop() destroys everything (call it on exit).
 */
export class ScenePlayer {
  constructor(box, sequence, { track, loop = 0, options = () => ({}) } = {}) {
    this.box = box;
    this.sequence = sequence;
    this.track = track;
    this.loop = loop;
    this.options = options;
    this.token = 0;
    this.current = null;
    this.raf = 0;
  }

  async play({ keep = false } = {}) {
    cancelAnimationFrame(this.raf);
    const token = ++this.token;
    if (!keep) this.clear();
    const found = await Promise.all(this.sequence.map((it) => sceneAvailable(it.src)));
    const items = this.sequence.filter((_, i) => found[i]);
    if (token !== this.token) return;
    for (let i = 0; i < items.length; i++) {
      const next = await mountInto(this.box, items[i].src, this.options());
      if (token !== this.token) return destroyMounted(next);
      if (next) this.swap(next);
      if (i < items.length - 1 && next) {
        await wait((items[i].duration ?? 2.4) * 1000);
        if (token !== this.token) return;
      }
    }
    this.startClock(token);
  }

  // Steps follow elapsed time; a missing scene still runs the clock so the copy moves.
  startClock(token) {
    if (!this.track && !this.loop) return;
    this.track?.reset();
    const t0 = performance.now();
    const tick = (now) => {
      if (token !== this.token) return;
      const t = (now - t0) / 1000;
      this.track?.render(t);
      if (this.loop && t >= this.loop) return this.play({ keep: true });
      this.raf = requestAnimationFrame(tick);
    };
    this.raf = requestAnimationFrame(tick);
  }

  // The new scene fades in over the old one, then the old one is destroyed.
  swap(next) {
    const prev = this.current;
    this.current = next;
    this.box.classList.add('is-live');
    requestAnimationFrame(() => next.el.classList.add('is-in'));
    if (prev) setTimeout(() => destroyMounted(prev), 500);
  }

  clear() {
    destroyMounted(this.current);
    this.current = null;
    this.box.replaceChildren();
    this.box.classList.remove('is-live');
    this.track?.reset();
  }

  stop() {
    this.token++;
    cancelAnimationFrame(this.raf);
    this.clear();
  }
}

/**
 * Marks the step whose start time has passed as active (the latest one wins), earlier
 * ones as done. Times are seconds; fit() compresses them into a shorter video.
 */
export class StepTrack {
  constructor(list, steps) {
    this.items = [...list.querySelectorAll('.step')];
    this.base = steps;
    this.steps = steps;
    this.active = -2;
  }
  fit(duration) {
    const end = this.base.at(-1).end;
    const k = Number.isFinite(duration) && duration > 0 && duration < end ? duration / end : 1;
    this.steps = this.base.map((s) => ({ start: s.start * k, end: s.end * k }));
  }
  render(t) {
    let idx = -1;
    this.steps.forEach((s, i) => {
      if (t >= s.start) idx = i;
    });
    this.setIndex(idx);
  }
  setIndex(idx) {
    if (idx === this.active) return;
    this.active = idx;
    this.items.forEach((el, i) => {
      el.classList.toggle('is-active', i === idx);
      el.classList.toggle('is-done', i < idx);
      if (i === idx) el.setAttribute('aria-current', 'step');
      else el.removeAttribute('aria-current');
    });
  }
  reset() {
    this.setIndex(-1);
  }
}
