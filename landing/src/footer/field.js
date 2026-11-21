// Procedural heliotrope field and wordmark height map for the footer. Both are drawn once per layout into
// "data" canvases that the shaders read, never shown directly.
//   Field layer (opaque black canvas, so channels stay exact): R = floret bump height,
//   G = silhouette coverage, B = floret mask (1 on florets, 0 on leaves and stems).
//   Wordmark: R = sharp coverage, G = narrow blur (crisp bevel), B = wide blur (soft rounding).

const C_STEM = 'rgb(12,255,0)';
const C_FOLIAGE = 'rgb(18,255,0)';
const C_LEAF = 'rgb(34,255,0)';
const C_VEIN = 'rgb(92,255,0)';
const C_DOME = 'rgb(36,255,170)';

/** Small seeded PRNG (mulberry32) so the field is the same on every load. */
export function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function makeCanvas(w, h) {
  const c = document.createElement('canvas');
  c.width = Math.max(1, Math.ceil(w));
  c.height = Math.max(1, Math.ceil(h));
  return c;
}

/** Floret sprites in device px: five lobes (or a dot when tiny) with a domed bump in R. */
function floretSprites(d, rand) {
  const size = Math.ceil(d) + 2;
  const lobed = d >= 6;
  const out = [];
  for (let k = 0; k < 4; k++) {
    const c = makeCanvas(size, size);
    const x = c.getContext('2d');
    const m = size / 2;
    const r = d / 2;
    const g = x.createRadialGradient(m, m, 0, m, m, r);
    g.addColorStop(0, 'rgb(255,255,255)');
    g.addColorStop(0.55, 'rgb(175,255,255)');
    g.addColorStop(1, 'rgb(64,255,255)');
    x.fillStyle = g;
    x.beginPath();
    if (lobed) {
      const rot = rand() * Math.PI * 2;
      const lr = r * 0.47;
      for (let i = 0; i < 5; i++) {
        const a = rot + (i * Math.PI * 2) / 5;
        const cx = m + Math.cos(a) * (r - lr);
        const cy = m + Math.sin(a) * (r - lr);
        x.moveTo(cx + lr, cy);
        x.arc(cx, cy, lr, 0, Math.PI * 2);
      }
      x.fill();
      // the tube opening: a small dip in the middle, so each floret reads as a tiny flower under rim light
      x.fillStyle = 'rgb(120,255,255)';
      x.beginPath();
      x.arc(m, m, r * 0.17, 0, Math.PI * 2);
      x.fill();
    } else {
      x.arc(m, m, r, 0, Math.PI * 2);
      x.fill();
    }
    out.push(c);
  }
  return out;
}

function leaf(ctx, x, y, ang, len, wid) {
  const c = Math.cos(ang);
  const s = Math.sin(ang);
  const px = (u, v) => x + c * u - s * v;
  const py = (u, v) => y + s * u + c * v;
  ctx.fillStyle = C_LEAF;
  ctx.beginPath();
  ctx.moveTo(x, y);
  ctx.bezierCurveTo(px(len * 0.2, wid * 0.62), py(len * 0.2, wid * 0.62), px(len * 0.72, wid * 0.52), py(len * 0.72, wid * 0.52), px(len, 0), py(len, 0));
  ctx.bezierCurveTo(px(len * 0.72, -wid * 0.46), py(len * 0.72, -wid * 0.46), px(len * 0.2, -wid * 0.6), py(len * 0.2, -wid * 0.6), x, y);
  ctx.fill();
  ctx.strokeStyle = C_VEIN;
  ctx.lineWidth = Math.max(0.5, wid * 0.07);
  ctx.beginPath();
  ctx.moveTo(x, y);
  ctx.quadraticCurveTo(px(len * 0.5, wid * 0.06), py(len * 0.5, wid * 0.06), px(len * 0.9, 0), py(len * 0.9, 0));
  ctx.stroke();
}

function stem(ctx, x0, y0, x1, y1, w, bend) {
  ctx.strokeStyle = C_STEM;
  ctx.lineWidth = w;
  ctx.lineCap = 'round';
  ctx.beginPath();
  ctx.moveTo(x0, y0);
  ctx.quadraticCurveTo(x0 + (x1 - x0) * 0.25 + bend, (y0 + y1) * 0.5, x1, y1);
  ctx.stroke();
}

/** One flower head: a lumpy dome of sub-clusters packed with florets. */
function head(ctx, x, y, R, rand, spr, sprCss) {
  const h = R * (0.62 + rand() * 0.14);
  const n = 6 + ((rand() * 4) | 0);
  const subs = [];
  for (let j = 0; j < n; j++) {
    const t = j / (n - 1);
    const a = Math.PI * (1.02 + 0.96 * t) + (rand() - 0.5) * 0.2;
    const rr = R * (0.3 + rand() * 0.16);
    subs.push(x + Math.cos(a) * (R - rr * 0.9), y + Math.sin(a) * (h - rr * 0.5), rr);
  }
  subs.push(x + (rand() - 0.5) * R * 0.4, y - h * 0.55, R * 0.42);
  subs.push(x + (rand() - 0.5) * R * 0.5, y - h * 0.2, R * 0.5);

  ctx.fillStyle = C_DOME;
  ctx.beginPath();
  ctx.ellipse(x, y, R * 0.96, h * 0.9, 0, Math.PI, Math.PI * 2);
  ctx.ellipse(x, y, R * 0.96, h * 0.34, 0, 0, Math.PI);
  ctx.fill();
  for (let k = 0; k < subs.length; k += 3) {
    ctx.beginPath();
    ctx.ellipse(subs[k], subs[k + 1], subs[k + 2], subs[k + 2] * 0.84, 0, 0, Math.PI * 2);
    ctx.fill();
  }

  const fr = sprCss * 0.5;
  const sp = fr * 1.5;
  const inside = (px, py) => {
    if (((px - x) / (R * 0.96)) ** 2 + ((py - y) / (h * 0.9)) ** 2 < 1 && py <= y + h * 0.25) return true;
    for (let k = 0; k < subs.length; k += 3) {
      const dx = (px - subs[k]) / subs[k + 2];
      const dy = (py - subs[k + 1]) / (subs[k + 2] * 0.84);
      if (dx * dx + dy * dy < 1) return true;
    }
    return false;
  };
  const dot = (px, py, k) => {
    const s = sprCss * k * (0.8 + rand() * 0.45);
    ctx.drawImage(spr[(rand() * spr.length) | 0], px - s / 2, py - s / 2, s, s);
  };
  // interior florets first, then the ones on each sub-cluster's crown, which make the bumpy outline
  const count = Math.ceil(((Math.PI * R * h * 0.8) / (sp * sp)) * 1.5);
  for (let i = 0; i < count; i++) {
    const px = x + (rand() * 2 - 1) * R;
    const py = y + h * 0.3 - rand() * h * 1.35;
    if (inside(px, py)) dot(px, py, 1);
  }
  for (let k = 0; k < subs.length; k += 3) {
    const sx = subs[k];
    const sy = subs[k + 1];
    const sr = subs[k + 2];
    const steps = Math.max(5, Math.ceil((Math.PI * sr) / (sp * 0.9)));
    for (let i = 0; i <= steps; i++) {
      const a = Math.PI * (1.02 + (0.96 * i) / steps) + (rand() - 0.5) * 0.08;
      dot(sx + Math.cos(a) * sr * 0.98, sy + Math.sin(a) * sr * 0.84, 1.05);
    }
  }
}

/** A heliotrope bush: a mound of heads over a skirt of broad leaves; stems mostly hidden. */
function bush(ctx, rand, spr, sprCss, x, y, R, baseY, o) {
  const heads = [x, y, R];
  const extra = o.heads[0] + ((rand() * (o.heads[1] - o.heads[0] + 1)) | 0);
  for (let i = 0; i < extra; i++) {
    const side = i % 2 ? -1 : 1;
    const ring = 1 + (i >> 1);
    heads.push(
      x + side * R * (0.75 + rand() * 0.55) * ring,
      y + R * (0.2 + rand() * 0.45) * ring,
      R * (0.62 + rand() * 0.25) / Math.sqrt(ring),
    );
  }
  const w = Math.max(0.8, R * 0.07);
  for (let k = 0; k < heads.length; k += 3) {
    stem(ctx, heads[k], heads[k + 1], x + (heads[k] - x) * 0.4, baseY, w * (heads[k + 2] / R), (rand() - 0.5) * R * 0.4);
  }
  // leaves behind and below the heads, angled out and a little down
  const nl = o.leaves + ((rand() * 3) | 0);
  for (let i = 0; i < nl; i++) {
    const side = i % 2 ? -1 : 1;
    const t = rand();
    const lx = x + side * R * (0.2 + t * 1.2);
    const ly = y + R * (0.35 + rand() * 0.55);
    const ang = side > 0 ? -0.15 + rand() * 0.75 : Math.PI + 0.15 - rand() * 0.75;
    const len = R * (0.95 + rand() * 0.6);
    leaf(ctx, lx, ly, ang, len, len * (0.5 + rand() * 0.12));
  }
  // a leafy mound under the heads, so the bush never reads as a head on a bare stalk
  if (o.leafTo) {
    ctx.fillStyle = C_FOLIAGE;
    ctx.beginPath();
    ctx.moveTo(x - R * 1.3, o.leafTo + R);
    ctx.quadraticCurveTo(x - R * 1.2, y + R * 0.7, x - R * 0.55, y + R * 0.4);
    ctx.lineTo(x + R * 0.55, y + R * 0.4);
    ctx.quadraticCurveTo(x + R * 1.2, y + R * 0.7, x + R * 1.3, o.leafTo + R);
    ctx.closePath();
    ctx.fill();
    let side = rand() < 0.5 ? -1 : 1;
    for (let ly = y + R * 1.1; ly < o.leafTo; ly += R * (0.45 + rand() * 0.25)) {
      const len = R * (0.75 + rand() * 0.45);
      const ang = side > 0 ? -0.1 + rand() * 0.7 : Math.PI + 0.1 - rand() * 0.7;
      leaf(ctx, x + side * R * (0.55 + rand() * 0.45), ly, ang, len, len * 0.52);
      side = -side;
    }
  }
  // heads from the back (highest) to the front
  const order = [];
  for (let k = 0; k < heads.length; k += 3) order.push(k);
  order.sort((a, b) => heads[a + 1] - heads[b + 1]);
  for (const k of order) head(ctx, heads[k], heads[k + 1], heads[k + 2], rand, spr, sprCss);
  // a couple of leaves in front of the lowest heads
  for (let i = 0; i < o.front; i++) {
    const side = rand() < 0.5 ? -1 : 1;
    const len = R * (0.8 + rand() * 0.5);
    leaf(ctx, x + side * R * (0.3 + rand() * 0.9), y + R * (0.75 + rand() * 0.4), side > 0 ? 0.1 + rand() * 0.6 : Math.PI - 0.1 - rand() * 0.6, len, len * 0.5);
  }
}

/** A foliage mass whose top edge is lumpy leaves, never a straight line. */
function foliage(ctx, rand, x0, x1, top, bottom, R) {
  ctx.fillStyle = C_FOLIAGE;
  ctx.fillRect(x0, top + R * 0.7, x1 - x0, bottom - top);
  for (let x = x0; x < x1; x += R * (0.45 + rand() * 0.35)) {
    const r = R * (0.5 + rand() * 0.45);
    ctx.fillStyle = C_FOLIAGE;
    ctx.beginPath();
    ctx.ellipse(x, top + R * 0.75, r, r * 0.8, 0, 0, Math.PI * 2);
    ctx.fill();
    const len = R * (0.8 + rand() * 0.6);
    leaf(ctx, x, top + R * (0.5 + rand() * 0.5), -Math.PI / 2 + (rand() - 0.5) * 2.6, len, len * 0.5);
  }
}

function layerCanvas(x, y, w, h, dpr) {
  const canvas = makeCanvas(w * dpr, h * dpr);
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.setTransform(dpr, 0, 0, dpr, -x * dpr, -y * dpr);
  return { canvas, ctx, x, y, w, h };
}

/**
 * Three parallax layers of heliotrope silhouettes in scene CSS px.
 * `L` = { hz (horizon y), margin (horizontal overscan for parallax) }.
 */
export function buildField(W, H, dpr, L) {
  const U = Math.max(Math.min(W, H * 1.5), 620) / 1000;
  const { hz, margin: m } = L;
  const x0 = -m;
  const x1 = W + m;
  const wave = (x, ph) => Math.sin((x / W) * 7.1 + ph) * 0.6 + Math.sin((x / W) * 17.3 + ph * 2.1) * 0.4;
  const layers = [];

  // back: a dense, continuous horizon of small heads, no stems showing
  {
    const rand = rng(11);
    const R0 = 15 * U;
    const top = hz - R0 * 3;
    const ly = layerCanvas(x0, top, x1 - x0, H - top, dpr);
    const { ctx } = ly;
    const sprCss = Math.max(1.5, R0 * 0.15);
    const spr = floretSprites(sprCss * dpr, rand);
    foliage(ctx, rand, x0, x1, hz + R0 * 0.2, H, R0);
    for (let row = 0; row < 2; row++) {
      let x = x0 + rand() * R0;
      while (x < x1) {
        const R = R0 * (0.7 + rand() * 0.6) * (row ? 0.95 : 1);
        const y = hz + row * R0 * 0.6 + wave(x, 0.7) * R0 * 0.8 + (rand() - 0.5) * R0 * 0.5;
        head(ctx, x, y, R, rand, spr, sprCss);
        if (rand() < 0.5) leaf(ctx, x + R * 0.6, y + R * 0.4, (rand() - 0.5) * 0.8, R * 1.1, R * 0.55);
        x += R * (1.05 + rand() * 0.6);
      }
    }
    layers.push(ly);
  }

  // mid: bushes rising and falling across the field over a leafy mass
  {
    const rand = rng(23);
    const R0 = 34 * U;
    const top = hz - R0 * 2.8;
    const ly = layerCanvas(x0, top, x1 - x0, H - top, dpr);
    const { ctx } = ly;
    const sprCss = Math.max(2.1, R0 * 0.14);
    const spr = floretSprites(sprCss * dpr, rand);
    const leafTo = hz + H * 0.042 + R0 * 0.5;
    foliage(ctx, rand, x0, x1, leafTo, H, R0);
    let x = x0 + rand() * R0;
    while (x < x1) {
      const R = R0 * (0.75 + rand() * 0.5);
      const y = hz + H * 0.045 + wave(x, 2.3) * H * 0.03 + (rand() - 0.5) * R0 * 1.1;
      bush(ctx, rand, spr, sprCss, x, y, R, H, { heads: [2, 4], leaves: 5, front: 1, leafTo });
      x += R * (1.7 + rand() * 1.8);
    }
    layers.push(ly);
  }

  // front: big, near-black bushes that frame the scene, tall at the edges and low in the middle
  {
    const rand = rng(37);
    const R0 = 58 * U;
    const top = H * 0.48 - R0;
    const ly = layerCanvas(x0, top, x1 - x0, H - top, dpr);
    const { ctx } = ly;
    const sprCss = Math.max(3, R0 * 0.12);
    const spr = floretSprites(sprCss * dpr, rand);
    const xs = [-0.02, 0.1, 0.21, 0.36, 0.5, 0.64, 0.79, 0.9, 1.02];
    for (let i = 0; i < xs.length; i++) {
      const xn = xs[i] + (rand() - 0.5) * 0.03;
      const e = Math.min(1, Math.abs(xn * 2 - 1));
      const R = R0 * (0.8 + rand() * 0.3) * (0.65 + 0.5 * e);
      const y = H * (0.97 - 0.32 * Math.pow(e, 1.7)) + (rand() - 0.5) * R0 * 0.3;
      bush(ctx, rand, spr, sprCss, xn * W, y, R, H + R0, { heads: [1, 3], leaves: 5, front: 2 });
    }
    ctx.fillStyle = C_FOLIAGE;
    ctx.fillRect(x0, H * 0.985, x1 - x0, H);
    layers.push(ly);
  }
  return layers;
}

/**
 * Wordmark height map, `targetW` CSS px wide (ink bounds). Returns the data canvas plus its CSS size and the
 * two blur sigmas in device px (the shader scales its bevel normals by them).
 */
export function buildWordmark(text, family, targetW, dpr) {
  const m = makeCanvas(8, 8).getContext('2d');
  const setFont = (ctx, px) => {
    ctx.font = `700 ${px}px ${family}`;
    if ('letterSpacing' in ctx) ctx.letterSpacing = `${(-0.045 * px).toFixed(2)}px`;
  };
  setFont(m, 200);
  const t0 = m.measureText(text);
  const size = (targetW / (t0.actualBoundingBoxLeft + t0.actualBoundingBoxRight)) * 200;
  const sd = size * dpr;
  setFont(m, sd);
  const t = m.measureText(text);
  const pad = Math.ceil(size * 0.16);
  const wCss = (t.actualBoundingBoxLeft + t.actualBoundingBoxRight) / dpr + pad * 2;
  const hCss = (t.actualBoundingBoxAscent + Math.max(0, t.actualBoundingBoxDescent)) / dpr + pad * 2;
  const cw = Math.ceil(wCss * dpr);
  const ch = Math.ceil(hCss * dpr);
  const ox = pad * dpr + t.actualBoundingBoxLeft;
  const oy = pad * dpr + t.actualBoundingBoxAscent;
  const blur1 = Math.max(2, size * 0.02 * dpr);
  const blur2 = Math.max(6, size * 0.11 * dpr);

  const pass = (blur) => {
    const c = makeCanvas(cw, ch);
    const x = c.getContext('2d', { willReadFrequently: true });
    x.fillStyle = '#000';
    x.fillRect(0, 0, cw, ch);
    setFont(x, sd);
    x.fillStyle = '#fff';
    if (blur > 0) {
      // draw off canvas and keep only the blurred shadow (shadowBlur is device px and widely supported)
      x.shadowColor = '#fff';
      x.shadowBlur = blur;
      x.shadowOffsetX = cw * 2;
      x.fillText(text, ox - cw * 2, oy);
    } else {
      x.fillText(text, ox, oy);
    }
    return x.getImageData(0, 0, cw, ch).data;
  };
  const a = pass(0);
  const b1 = pass(blur1);
  const b2 = pass(blur2);
  const canvas = makeCanvas(cw, ch);
  const octx = canvas.getContext('2d');
  const img = octx.createImageData(cw, ch);
  const d = img.data;
  for (let i = 0; i < d.length; i += 4) {
    d[i] = a[i];
    d[i + 1] = b1[i];
    d[i + 2] = b2[i];
    d[i + 3] = 255;
  }
  octx.putImageData(img, 0, 0);
  return { canvas, w: wCss, h: hCss, size, sigma1: blur1 / 2, sigma2: blur2 / 2 };
}
