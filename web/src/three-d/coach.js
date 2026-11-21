// Endpoints for the 3D page (CONTRACT.md), with a localStorage cache for the paid calls
// (Argon regions, scores, reframe) keyed by sample name or a hash of the normalized JPEG.
import { createApi } from '../api.js';
import { decodeMasks } from '../masks.js';

const params = new URLSearchParams(location.search);
export const MOCK = params.has('mock');
const api = createApi({ mock: MOCK, fail: params.get('fail') || '' });
const PREFIX = 'lc3d:v1:';

function cacheGet(key) {
  try {
    const s = localStorage.getItem(PREFIX + key);
    return s ? JSON.parse(s) : null;
  } catch {
    return null;
  }
}

function cacheSet(key, value) {
  try {
    localStorage.setItem(PREFIX + key, JSON.stringify(value));
  } catch {
    /* full or blocked: fine, it's only a cache */
  }
}

/** 64-bit FNV-1a (two lanes) over the bytes, hex. Works without crypto.subtle (LAN http). */
export async function hashBlob(blob) {
  const b = new Uint8Array(await blob.arrayBuffer());
  let h1 = 0x811c9dc5;
  let h2 = 0x01000193 ^ b.length;
  for (let i = 0; i < b.length; i++) {
    h1 = Math.imul(h1 ^ b[i], 0x01000193);
    h2 = Math.imul(h2 ^ b[i], 0x5bd1e995);
  }
  return (h1 >>> 0).toString(16).padStart(8, '0') + (h2 >>> 0).toString(16).padStart(8, '0');
}

async function cached(kind, key, fetcher) {
  const hit = key && cacheGet(`${kind}:${key}`);
  if (hit) return hit;
  const value = await fetcher();
  if (key) cacheSet(`${kind}:${key}`, value);
  return value;
}

const clamp01 = (v) => Math.min(1, Math.max(0, Number(v) || 0));

function cleanRegions(json) {
  const list = Array.isArray(json?.regions) ? json.regions : [];
  return list.slice(0, 3).map((r, i) => {
    const b = r.box || {};
    const x = clamp01(b.x);
    const y = clamp01(b.y);
    return {
      id: String(r.id || `r${i + 1}`),
      tag: r.tag === 'remove' ? 'remove' : 'focus',
      note: String(r.note || '').trim(),
      box: { x, y, w: Math.min(1 - x, clamp01(b.w)), h: Math.min(1 - y, clamp01(b.h)) },
    };
  });
}

export async function regions(photo, key, signal) {
  const json = await cached('regions', key, () => api.regions(photo, signal));
  return cleanRegions(json);
}

export const score = (photo, key, signal) => cached('score', key, () => api.score(photo, signal));

/** -> { masks: Map(id -> { data RG, width, height }), missing: [ids] } */
export async function masks(photo, list, signal) {
  return decodeMasks(await api.masks(photo, list, signal), list);
}

async function postImage(path, photo, signal, fields = {}) {
  const body = new FormData();
  body.append('image', photo.blob, 'photo.jpg');
  for (const [k, v] of Object.entries(fields)) body.append(k, v);
  return fetch(path, { method: 'POST', body, signal });
}

/** SHARP splat of an upload. null when the endpoint isn't there (404); throws on other errors.
 *  onBytes(loaded, total) reports the download once the server has answered. */
export async function splat(photo, signal, onBytes) {
  if (MOCK) return null;
  const res = await postImage('/api/splat', photo, signal);
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`splat HTTP ${res.status}`);
  const H = (k) => Number(res.headers.get(k));
  const bytes = await readAll(res, onBytes);
  const width = H('X-Splat-Width');
  const height = H('X-Splat-Height');
  const focal = H('X-Splat-Focal-Px');
  return {
    bytes,
    intrinsics: width > 0 && height > 0 && focal > 0 ? { tanX: width / (2 * focal), tanY: height / (2 * focal) } : null,
    ms: H('X-Splat-Ms'),
    cache: res.headers.get('X-Splat-Cache') || '',
  };
}

async function readAll(res, onBytes) {
  const total = Number(res.headers.get('Content-Length')) || 0;
  if (!res.body || !total || !onBytes) return new Uint8Array(await res.arrayBuffer());
  const out = new Uint8Array(total);
  const reader = res.body.getReader();
  let n = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (n + value.length > out.length) return concatRest(out.subarray(0, n), value, reader);
    out.set(value, n);
    n += value.length;
    onBytes(n, total);
  }
  return n === total ? out : out.slice(0, n);
}

async function concatRest(head, value, reader) {
  const parts = [head, value];
  for (;;) {
    const { done, value: v } = await reader.read();
    if (done) break;
    parts.push(v);
  }
  const out = new Uint8Array(parts.reduce((a, p) => a + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

/** Suggested camera move, or null if the endpoint isn't there. The v2 reply also names who
 *  must stay in frame (`keep`) and the place-defining scenery (`scene`). */
export async function reframe(photo, list, key, signal) {
  if (MOCK) {
    return { move: { x_m: -0.35, y_m: 0, z_m: 0.25, yaw_deg: 7, pitch_deg: 0 }, note: 'Step left so the light falls across their faces', keep: ['left', 'centre', 'right'], scene: 'the sunset over the bay' };
  }
  const hit = key && cacheGet(`reframe2:${key}`);
  if (hit) return hit;
  const res = await postImage('/api/reframe', photo, signal, list?.length ? { regions: JSON.stringify(list) } : {});
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`reframe HTTP ${res.status}`);
  const json = await res.json();
  if (!json?.move) throw new Error('reframe: no move');
  if (key) cacheSet(`reframe2:${key}`, json);
  return json;
}
