// Object masks from /api/masks: decode the PNG data URLs to an RG byte grid the viewer
// uploads as a texture (r = mask, g = a small blur of it, which the shader uses for the rim).
// Plus a mock that draws soft blobs inside each box, for ?mock=1.

const MAX_SIDE = 1024;

/** Separable box blur, `iters` passes (2 is close to a gaussian), clamped edges. */
function blur(src, w, h, r, iters = 2) {
  let a = Float32Array.from(src);
  const b = new Float32Array(w * h);
  const inv = 1 / (2 * r + 1);
  for (let it = 0; it < iters; it++) {
    for (let y = 0; y < h; y++) {
      const o = y * w;
      let s = 0;
      for (let x = -r; x <= r; x++) s += a[o + Math.min(Math.max(x, 0), w - 1)];
      for (let x = 0; x < w; x++) {
        b[o + x] = s * inv;
        s += a[o + Math.min(x + r + 1, w - 1)] - a[o + Math.max(x - r, 0)];
      }
    }
    for (let x = 0; x < w; x++) {
      let s = 0;
      for (let y = -r; y <= r; y++) s += b[Math.min(Math.max(y, 0), h - 1) * w + x];
      for (let y = 0; y < h; y++) {
        a[y * w + x] = s * inv;
        s += b[Math.min(y + r + 1, h - 1) * w + x] - b[Math.max(y - r, 0) * w + x];
      }
    }
  }
  return a;
}

/** One mask PNG (data URL) -> { data: Uint8Array RG, width, height }. Top-left origin kept. */
export async function decodeMask(png) {
  const blob = await (await fetch(png)).blob();
  const bmp = await createImageBitmap(blob, { colorSpaceConversion: 'none', premultiplyAlpha: 'none' });
  const s = Math.min(1, MAX_SIDE / Math.max(bmp.width, bmp.height));
  const width = Math.max(1, Math.round(bmp.width * s));
  const height = Math.max(1, Math.round(bmp.height * s));
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(bmp, 0, 0, width, height);
  bmp.close();
  const px = ctx.getImageData(0, 0, width, height).data;
  // Grey PNGs decode to r = g = b; a white-on-transparent mask carries it in alpha.
  const m = new Uint8Array(width * height);
  for (let i = 0; i < m.length; i++) m[i] = Math.round((px[i * 4] * px[i * 4 + 3]) / 255);
  const soft = blur(m, width, height, Math.max(1, Math.round((3 * Math.max(width, height)) / 1024)));
  const data = new Uint8Array(width * height * 2);
  for (let i = 0; i < m.length; i++) { data[i * 2] = m[i]; data[i * 2 + 1] = Math.round(soft[i]); }
  return { data, width, height };
}

/**
 * /api/masks JSON -> { masks: Map(id -> decoded), meta, missing: [ids] }.
 * A region whose PNG is absent or won't decode is listed in `missing` and keeps its box.
 */
export async function decodeMasks(json, regions) {
  const src = json?.masks || {};
  const masks = new Map();
  const missing = [];
  await Promise.all(regions.map(async (r) => {
    const e = src[r.id];
    if (!e?.png) { missing.push(r.id); return; }
    try {
      masks.set(r.id, { ...(await decodeMask(e.png)), area: Number(e.area), source: String(e.source || '') });
    } catch (err) {
      console.warn(`mask ${r.id} did not decode`, err);
      missing.push(r.id);
    }
  }));
  if (regions.length && !masks.size) throw new Error('no usable masks in the response');
  return { masks, missing, model: json?.model, ms: json?.ms };
}

/** Mock: a soft blob (two overlapping ellipses) inside each box, as PNG data URLs. */
export function mockMasks(photo, regions) {
  const s = MAX_SIDE / Math.max(photo.width, photo.height);
  const W = Math.round(photo.width * s);
  const H = Math.round(photo.height * s);
  const masks = {};
  for (const r of regions) {
    const c = document.createElement('canvas');
    c.width = W;
    c.height = H;
    const ctx = c.getContext('2d');
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, W, H);
    ctx.filter = `blur(${Math.round(W / 300)}px)`;
    ctx.fillStyle = '#fff';
    const { x, y, w, h } = r.box;
    const cx = (x + w / 2) * W;
    const cy = (y + h / 2) * H;
    ctx.beginPath();
    ctx.ellipse(cx, cy + h * H * 0.06, w * W * 0.4, h * H * 0.36, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.beginPath();
    ctx.ellipse(cx - w * W * 0.12, cy - h * H * 0.2, w * W * 0.2, h * H * 0.2, 0, 0, Math.PI * 2);
    ctx.fill();
    masks[r.id] = { png: c.toDataURL('image/png'), width: W, height: H,
      area: +((Math.PI * 0.4 * 0.36 * w * h) + 0.01).toFixed(3), source: 'mock-ellipse' };
  }
  return { masks, model: 'mock/ellipse', ms: 640 };
}
