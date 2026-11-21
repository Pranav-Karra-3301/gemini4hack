// Image normalization and the endpoints (see CONTRACT.md), plus an offline mock.
import { gridFor } from './points.js';
import { mockMasks } from './masks.js';

const MAX_SIDE = 1536;

/** EXIF-rotate, cap the long side at 1536, re-encode as JPEG. The result is what we show and send. */
export async function normalizeImage(input) {
  const src = await createImageBitmap(input, { imageOrientation: 'from-image' });
  const s = Math.min(1, MAX_SIDE / Math.max(src.width, src.height));
  const width = Math.round(src.width * s);
  const height = Math.round(src.height * s);
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext('2d');
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(src, 0, 0, width, height);
  src.close();
  const blob = await new Promise((ok, fail) =>
    canvas.toBlob((b) => (b ? ok(b) : fail(new Error('JPEG encode failed'))), 'image/jpeg', 0.9));
  const bitmap = await createImageBitmap(blob); // display exactly what the server sees
  return { blob, width, height, bitmap };
}

async function post(path, photo, signal, fields = {}) {
  const body = new FormData();
  body.append('image', photo.blob, 'photo.jpg');
  for (const [k, v] of Object.entries(fields)) body.append(k, v);
  let res;
  try {
    res = await fetch(path, { method: 'POST', body, signal });
  } catch (e) {
    if (e.name === 'AbortError') throw e;
    throw new Error('backend unreachable');
  }
  if (!res.ok) throw new Error(await errorText(res));
  return res;
}

async function errorText(res) {
  const text = await res.text().catch(() => '');
  try {
    const j = JSON.parse(text);
    if (j && j.error) return String(j.error);
    if (j && typeof j.detail === 'string') return `${j.detail} (HTTP ${res.status})`;
  } catch { /* not JSON */ }
  if (res.status >= 500 && !text) return `HTTP ${res.status} (is the backend running on :8787?)`;
  return text && text.length < 200 && !text.trimStart().startsWith('<') ? text : `HTTP ${res.status}`;
}

const num = (v) => (v == null || v === '' ? NaN : Number(v));

/** 2nd/98th percentile from a strided sample; fallback when headers are missing. */
function percentiles(data) {
  const step = Math.max(1, Math.floor(data.length / 20000));
  const s = [];
  for (let i = 0; i < data.length; i += step) if (data[i] > 0 && Number.isFinite(data[i])) s.push(data[i]);
  s.sort((a, b) => a - b);
  if (!s.length) return [1, 2];
  return [s[Math.floor(s.length * 0.02)], s[Math.min(s.length - 1, Math.floor(s.length * 0.98))]];
}

const real = {
  async depth(photo, signal) {
    const res = await post('/api/depth', photo, signal);
    const H = (k) => res.headers.get(k);
    const width = parseInt(H('X-Depth-Width'), 10);
    const height = parseInt(H('X-Depth-Height'), 10);
    const buf = await res.arrayBuffer();
    if (!(width > 0 && height > 0) || buf.byteLength !== width * height * 4) {
      throw new Error(`bad depth payload: ${buf.byteLength} bytes for ${width}×${height}`);
    }
    const data = new Float32Array(buf); // platform order; every browser platform is little-endian
    let p02 = num(H('X-Depth-P02'));
    let p98 = num(H('X-Depth-P98'));
    if (!(p02 > 0 && p98 > p02)) [p02, p98] = percentiles(data);
    return { data, width, height, p02, p98, inferMs: num(H('X-Infer-Ms')), device: H('X-Device') || '' };
  },
  regions: async (photo, signal) => (await post('/api/regions', photo, signal)).json(),
  score: async (photo, signal) => (await post('/api/score', photo, signal)).json(),
  /** regions: the cleaned regions array (ids match the cards). Returns the raw JSON. */
  masks: async (photo, regions, signal) =>
    (await post('/api/masks', photo, signal, { regions: JSON.stringify(regions) })).json(),
};

// ---------------- mock (?mock=1, optional &fail=depth,regions,score,masks) ----------------

const sleep = (ms, signal) => new Promise((ok, fail) => {
  const t = setTimeout(ok, ms);
  signal?.addEventListener('abort', () => { clearTimeout(t); fail(new DOMException('aborted', 'AbortError')); }, { once: true });
});

function rng(seed) {
  let s = seed >>> 0 || 1;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32);
}

function mockDepth(w, h) {
  // Far wall at the top easing to a nearer floor at the bottom, plus a rounded subject.
  const data = new Float32Array(w * h);
  for (let y = 0; y < h; y++) {
    const v = y / (h - 1);
    for (let x = 0; x < w; x++) {
      const uu = x / (w - 1);
      const bg = 3 + 7 * Math.pow(1 - v, 1.3);
      const head = Math.hypot((uu - 0.5) / 0.17, (v - 0.33) / 0.15);
      const body = Math.hypot((uu - 0.5) / 0.3, (v - 0.85) / 0.4);
      const r = Math.min(head, body);
      const t = Math.min(1, Math.max(0, (1.05 - r) / 0.12));
      const subject = 1.4 + 0.25 * r * r;
      data[y * w + x] = bg + (subject - bg) * t * t * (3 - 2 * t);
    }
  }
  return data;
}

function mockScore(rand, label) {
  const peak = 2 + Math.floor(rand() * 3); // 2..4
  const raw = [1, 2, 3, 4, 5].map((k) => Math.exp(-((k - peak - rand() * 0.8) ** 2) / 0.9) + 0.02);
  const sum = raw.reduce((a, b) => a + b, 0);
  const distribution = {};
  let score = 0;
  raw.forEach((p, i) => { distribution[i + 1] = +(p / sum).toFixed(3); score += (i + 1) * (p / sum); });
  const confidence = +(Math.max(...raw) / sum + 0.2).toFixed(2);
  return { score: +score.toFixed(2), scale: [1, 5], confidence: Math.min(0.95, confidence), distribution, label };
}

function makeMock(failList) {
  const fail = new Set(String(failList || '').split(',').filter(Boolean));
  const maybeFail = (name) => { if (fail.has(name)) throw new Error(`mock ${name} failure (from ?fail=)`); };
  return {
    async depth(photo, signal) {
      const t0 = performance.now();
      await sleep(700 + Math.random() * 500, signal);
      maybeFail('depth');
      const [width, height] = gridFor(photo.width, photo.height);
      const data = mockDepth(width, height);
      const [p02, p98] = percentiles(data);
      return { data, width, height, p02, p98, inferMs: Math.round(performance.now() - t0), device: 'mock' };
    },
    async regions(photo, signal) {
      await sleep(1800 + Math.random() * 900, signal);
      maybeFail('regions');
      const r = rng(photo.blob.size);
      const j = () => (r() - 0.5) * 0.06;
      return {
        regions: [
          { id: 'r1', tag: 'focus', box: { x: 0.34 + j(), y: 0.16 + j(), w: 0.32, h: 0.3 },
            note: 'Expose for the cheek highlight; the window light is the shot.' },
          { id: 'r2', tag: 'remove', box: { x: 0.7 + j(), y: 0.04 + j(), w: 0.26, h: 0.2 },
            note: 'Bright patch top right pulls the eye off the face; crop or darken it.' },
          { id: 'r3', tag: 'focus', box: { x: 0.06 + j(), y: 0.52 + j(), w: 0.3, h: 0.3 },
            note: 'Soft falloff on the shoulder; keep it, it gives the face shape.' },
        ],
        model: 'mock/gemini-4-argon',
        ms: 2300,
      };
    },
    async score(photo, signal) {
      await sleep(1300 + Math.random() * 700, signal);
      maybeFail('score');
      const r = rng(photo.blob.size * 7 + 3);
      return {
        provider: 'emulated:mock/decision-1',
        scores: {
          lighting: mockScore(r, 'Soft window light, slightly underexposed'),
          composition: mockScore(r, 'Subject a little centered; headroom is tight'),
        },
        ms: 1800,
      };
    },
    async masks(photo, regions, signal) {
      await sleep(800 + Math.random() * 500, signal);
      maybeFail('masks');
      return mockMasks(photo, regions);
    },
  };
}

export function createApi({ mock = false, fail = '' } = {}) {
  return mock ? makeMock(fail) : real;
}
