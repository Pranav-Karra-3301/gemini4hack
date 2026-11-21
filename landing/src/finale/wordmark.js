// Halftone wordmark: text is rasterised offscreen, sampled on a 45-degree dot lattice,
// and drawn as monochrome warm-white dots (#EDE8E0) whose size follows coverage. A slow band of light sweeps
// across it. Pauses offscreen; static under prefers-reduced-motion.

const FAMILY = '"Google Sans Flex", "Google Sans", system-ui, sans-serif';
const LEVELS = 7;
const BASE = [237, 232, 224, 0.62]; // #EDE8E0 at rest
const LIGHT = [255, 252, 246, 1]; // warm white under the light band
const SWEEP_S = 11; // seconds per light sweep
const FPS = 30;

const clamp01 = (v) => Math.min(1, Math.max(0, v));
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

const COLORS = Array.from({ length: LEVELS }, (_, i) => {
  const k = i / (LEVELS - 1);
  const c = BASE.map((b, j) => b + (LIGHT[j] - b) * k);
  return `rgb(${Math.round(c[0])} ${Math.round(c[1])} ${Math.round(c[2])} / ${c[3].toFixed(3)})`;
});

export function mountWordmark(canvas, { text = 'Heliocam' } = {}) {
  const ctx = canvas.getContext('2d');
  const host = canvas.parentElement;
  const motion = matchMedia('(prefers-reduced-motion: reduce)');
  let dots = new Float32Array(0); // x, y, rMax, u
  let count = 0;
  let cssW = 0;
  let cssH = 0;
  let dpr = 1;
  let raf = 0;
  let last = 0;
  let visible = false;
  let introAt = 0;
  let destroyed = false;
  let fontReady = false;

  function layout() {
    cssW = Math.round(host.clientWidth);
    if (!cssW) return;
    const size0 = 200;
    const m = document.createElement('canvas').getContext('2d');
    m.font = `700 ${size0}px ${FAMILY}`;
    m.letterSpacing = `${(-0.045 * size0).toFixed(2)}px`;
    const t0 = m.measureText(text);
    const w0 = t0.actualBoundingBoxLeft + t0.actualBoundingBoxRight;
    const spacing = Math.min(8, Math.max(3.5, (cssW / w0) * size0 * 0.033));
    const pad = Math.ceil(spacing * 1.5);
    const size = ((cssW - pad * 2) / w0) * size0;

    m.font = `700 ${size}px ${FAMILY}`;
    m.letterSpacing = `${(-0.045 * size).toFixed(2)}px`;
    const t = m.measureText(text);
    const asc = t.actualBoundingBoxAscent;
    const desc = Math.max(0, t.actualBoundingBoxDescent);
    cssH = Math.ceil(asc + desc + pad * 2);

    // Coverage mask at 1 CSS px, softened so dots shrink toward letter edges.
    const off = document.createElement('canvas');
    off.width = cssW;
    off.height = cssH;
    const o = off.getContext('2d', { willReadFrequently: true });
    o.font = m.font;
    o.letterSpacing = m.letterSpacing;
    o.filter = `blur(${(spacing * 0.32).toFixed(2)}px)`;
    o.fillStyle = '#fff';
    o.fillText(text, pad + t.actualBoundingBoxLeft, pad + asc);
    const data = o.getImageData(0, 0, cssW, cssH).data;

    const a = spacing / Math.SQRT2; // checkerboard of a square grid = 45-degree lattice
    const rMax = spacing * 0.5;
    const cols = Math.ceil(cssW / a);
    const rows = Math.ceil(cssH / a);
    const out = [];
    for (let n = 0; n <= rows; n++) {
      for (let mIdx = n & 1; mIdx <= cols; mIdx += 2) {
        const x = mIdx * a;
        const y = n * a;
        const xi = Math.min(cssW - 1, Math.round(x));
        const yi = Math.min(cssH - 1, Math.round(y));
        const cov = data[(yi * cssW + xi) * 4 + 3] / 255;
        if (cov < 0.05) continue;
        out.push(x, y, rMax * Math.sqrt(cov), (x + 0.4 * y) / cssW);
      }
    }
    dots = new Float32Array(out);
    count = out.length / 4;

    dpr = Math.min(2, window.devicePixelRatio || 1);
    canvas.width = Math.round(cssW * dpr);
    canvas.height = Math.round(cssH * dpr);
    canvas.style.height = `${cssH}px`;
  }

  function draw(sec) {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const still = motion.matches;
    const phase = still ? -9 : ((sec / SWEEP_S) % 1) * 1.9 - 0.45;
    const intro = still ? 1 : clamp01((performance.now() - introAt) / 2200);
    const paths = Array.from({ length: LEVELS }, () => new Path2D());
    for (let i = 0; i < count; i++) {
      const k = i * 4;
      const x = dots[k];
      const y = dots[k + 1];
      const u = dots[k + 3];
      let grow = 1;
      if (intro < 1) {
        grow = clamp01((intro * 1.5 - u) / 0.5);
        grow = grow * grow * (3 - 2 * grow);
        if (grow <= 0) continue;
      }
      const d = (u - phase) / 0.16;
      const band = Math.exp(-d * d);
      const r = dots[k + 2] * grow * (0.9 + 0.12 * band);
      if (r < 0.35) continue;
      const lvl = Math.min(LEVELS - 1, Math.round(band * (LEVELS - 1) * 0.9));
      const p = paths[lvl];
      p.moveTo(x + r, y);
      p.arc(x, y, r, 0, Math.PI * 2);
    }
    for (let l = 0; l < LEVELS; l++) {
      ctx.fillStyle = COLORS[l];
      ctx.fill(paths[l]);
    }
  }

  const t0 = performance.now();
  function frame(now) {
    raf = 0;
    if (!visible || destroyed || motion.matches) return;
    if (now - last >= 1000 / FPS - 2) {
      last = now;
      draw((now - t0) / 1000);
    }
    raf = requestAnimationFrame(frame);
  }

  function start() {
    if (raf || !fontReady || motion.matches) return;
    raf = requestAnimationFrame(frame);
  }
  function stop() {
    cancelAnimationFrame(raf);
    raf = 0;
  }

  const io = new IntersectionObserver(([e]) => {
    const was = visible;
    visible = e.isIntersecting;
    if (visible && !was && !introAt) introAt = performance.now();
    visible ? start() : stop();
  });
  let roRaf = 0;
  const ro = new ResizeObserver(() => {
    cancelAnimationFrame(roRaf);
    roRaf = requestAnimationFrame(() => {
      if (!fontReady || Math.round(host.clientWidth) === cssW) return;
      layout();
      draw((performance.now() - t0) / 1000);
    });
  });
  const onMotion = () => {
    if (motion.matches) {
      stop();
      draw(0);
    } else start();
  };

  (async () => {
    try {
      await Promise.race([document.fonts.load(`700 100px ${FAMILY}`, text), wait(3000)]);
    } catch {
      /* draw with the fallback face */
    }
    if (destroyed) return;
    fontReady = true;
    layout();
    draw(0);
    io.observe(canvas);
    ro.observe(host);
    motion.addEventListener('change', onMotion);
  })();

  return {
    destroy() {
      destroyed = true;
      stop();
      io.disconnect();
      ro.disconnect();
      motion.removeEventListener('change', onMotion);
    },
  };
}
