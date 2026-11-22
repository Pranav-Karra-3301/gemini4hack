// 01 · Sees in 3D first. A real scene (IMG_1491) as a LiDAR point cloud that settles into the photo.
// Text-free (DESIGN_V5.md): the cloud is full-bleed and centred. The words are the section title
// (TITLES.lidar) top-left with a small "LiDAR · on device" chip under it, and the measured distances.
// One sticky 100svh stage inside a ~260svh section; scroll progress p drives three acts:
//   0.00-0.35  the scan: a dark stage, the emitter glow at the phone's lens, a dot lattice sweeps the
//              scene and points land where it hits, coloured by depth in Gemini blue; slow orbit.
//   0.35-0.65  distances: measured labels (read from the depth map) on the people, railing, rocks, sea.
//   0.65-1.00  into the photo: points take the photo's colours, the camera flies to the capture eye
//              and the cloud flattens onto the photo plane, which then shows the photograph itself.
//
//   import { mountLidar } from './lidar/lidar.js';
//   const { destroy } = mountLidar(sectionEl, copy); // copy.label: the chip under the title
import * as THREE from 'three';
import { TITLES } from '../config.js';
import { sectionTitle } from '../title/title.js';
import './lidar.css';

const BASE = (import.meta.env && import.meta.env.BASE_URL) || '/';
const SRC = {
  photo: `${BASE}showcase/img-1491.webp`,
  packed: `${BASE}showcase/img-1491_depth_packed.png`,
};

// ---- the data -----------------------------------------------------------------------------------
// Capture intrinsics of IMG_1491 (src/showcase/showcase.js MEMORY.frame): 2978 x 2234 px, f 2236.9 px.
const FRAME = { w: 2978, h: 2234, f: 2236.9 };
const TAN_Y = FRAME.h / 2 / FRAME.f; // 0.499 -> 53 deg vertical, 67 deg horizontal
// The packed map holds v = (ln far - ln z) / (ln far - ln near), near = 1, 16 bits in R (high) + G (low)
// (design/handoff/depth/make_depth.py:14-22). near/far are not stored; fitting v against the metric
// SHARP splat of the same photo (public/splats/img-1491.spz, ~107k splats) gives these, in metres.
const NEAR_M = 2.35;
const FAR_M = 151;
const SKY_V = 0.004; // sky is clipped to v = 0: LiDAR gets no return from it, so it has no points
const metres = (v) => FAR_M * Math.pow(NEAR_M / FAR_M, v);
// Display depth: metric up close (people vs railing), log-compressed far out so the sea stays in frame.
const displayZ = (m) => 2.35 + 2.4 * Math.log(1 + Math.max(0, m - 2.35) / 1.5);

const GRID = 3; // jittered grid step in depth-map px: 1600 x 1200 -> ~213k cells, ~170k after sky/edges
const EDGE_PX = 2; // depth discontinuity test distance (px) ...
const EDGE_REL = 0.045; // ... and the relative jump that marks a silhouette (dropped, like a real scan)
const LATTICE = { cols: 72, rows: 54 }; // the projected dot pattern
const DP = 2.9; // orbit pivot and the plane the cloud flattens onto (display units, just behind the people)

// Where the labels measure (photo uv, y down). The numbers come from the depth map at load time.
const SPOTS = [
  { name: 'People', u: 0.481, v: 0.49 },
  { name: 'Railing', u: 0.1, v: 0.643 },
  { name: 'Rocks', u: 0.875, v: 0.433 },
  { name: 'Sea', u: 0.4, v: 0.21 },
];

const INK = 0x05060b;
const COL = {
  near: new THREE.Color('#7FB2FF'),
  mid: new THREE.Color('#4C8DFF'),
  far: new THREE.Color('#2B2F96'),
  dot: new THREE.Color('#CFE0FF'),
};

// Camera keyframes (yaw / pitch in degrees around the pivot, distance in units of DP).
const KEYS = [
  { p: 0, yaw: 8, pitch: 23, dist: 2.0 },
  { p: 0.35, yaw: -4, pitch: 18, dist: 1.8 },
  { p: 0.65, yaw: -24, pitch: 13, dist: 1.6 },
];
const STEP_AT = [0, 0.35, 0.65];
const STILL = [0.31, 0.52, 1]; // reduced motion: one static frame per act
const LABEL = 'LiDAR · on device';
// On a phone the scene sits this much below the stage's centre, so the title above it stays clear.
const MOBILE_DROP = 0.06; // of the stage height

// ---- helpers ------------------------------------------------------------------------------------
const clamp = (x, a = 0, b = 1) => (x < a ? a : x > b ? b : x);
const ss = (a, b, x) => {
  const t = clamp((x - a) / (b - a));
  return t * t * (3 - 2 * t);
};
const remap = (x, a, b) => clamp((x - a) / (b - a));
const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
const lerp = (a, b, t) => a + (b - a) * t;
const D2R = Math.PI / 180;

function h(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

function mulberry32(a) {
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function fmtDistance(m) {
  if (m > 40) return 'far';
  return m < 10 ? `${m.toFixed(1)} m` : `${Math.round(m)} m`;
}

async function loadPhoto(src) {
  const img = new Image();
  img.decoding = 'async';
  img.src = src;
  await img.decode();
  const w = img.naturalWidth;
  const hgt = img.naturalHeight;
  const canvas = Object.assign(document.createElement('canvas'), { width: w, height: hgt });
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(img, 0, 0);
  return { canvas, w, h: hgt, px: ctx.getImageData(0, 0, w, hgt).data };
}

/** Packed PNG (R = high byte, G = low byte) -> Float32 log depth, exactly, with no colour management. */
async function loadPackedDepth(src) {
  const res = await fetch(src);
  if (!res.ok) throw new Error(`depth ${res.status}`);
  const bmp = await createImageBitmap(await res.blob(), { colorSpaceConversion: 'none', premultiplyAlpha: 'none' });
  const { width: w, height: hgt } = bmp;
  const c = Object.assign(document.createElement('canvas'), { width: w, height: hgt });
  const ctx = c.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(bmp, 0, 0);
  bmp.close?.();
  const px = ctx.getImageData(0, 0, w, hgt).data;
  const data = new Float32Array(w * hgt);
  for (let i = 0, j = 0; i < data.length; i++, j += 4) data[i] = (px[j] * 256 + px[j + 1]) / 65535;
  return { w, h: hgt, data };
}

// ---- geometry -----------------------------------------------------------------------------------
function buildScene(photo, depth) {
  const { w, h: hgt, data } = depth;
  const f = (FRAME.f / FRAME.w) * w; // focal in depth-map px
  // v is k / 65535, so a table makes the pow + log per lookup free.
  const lut = new Float32Array(65536);
  for (let k = 0; k < 65536; k++) lut[k] = displayZ(metres(k / 65535));
  const zAt = (x, y) => lut[Math.round(data[y * w + x] * 65535)];
  const sx = photo.w / w;
  const sy = photo.h / hgt;

  const cols = Math.floor(w / GRID);
  const rows = Math.floor(hgt / GRID);
  const max = cols * rows;
  const pos = new Float32Array(max * 3);
  const col = new Uint8Array(max * 3);
  const dat = new Float32Array(max * 4);
  const rnd = mulberry32(1491);
  let n = 0;
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      const x = (c + 0.1 + 0.8 * rnd()) * GRID;
      const y = (r + 0.1 + 0.8 * rnd()) * GRID;
      const ix = Math.min(w - 1, x | 0);
      const iy = Math.min(hgt - 1, y | 0);
      const v = data[iy * w + ix];
      if (v < SKY_V) continue;
      const z = zAt(ix, iy);
      const x0 = Math.max(0, ix - EDGE_PX);
      const x1 = Math.min(w - 1, ix + EDGE_PX);
      const y0 = Math.max(0, iy - EDGE_PX);
      const y1 = Math.min(hgt - 1, iy + EDGE_PX);
      const jump = Math.max(
        Math.abs(zAt(x0, iy) - z),
        Math.abs(zAt(x1, iy) - z),
        Math.abs(zAt(ix, y0) - z),
        Math.abs(zAt(ix, y1) - z),
      );
      if (jump > EDGE_REL * z) continue;
      const i3 = n * 3;
      pos[i3] = ((x - w / 2) / f) * z;
      pos[i3 + 1] = (-(y - hgt / 2) / f) * z;
      pos[i3 + 2] = -z;
      const pj = (Math.min(photo.h - 1, (y * sy) | 0) * photo.w + Math.min(photo.w - 1, (x * sx) | 0)) * 4;
      col[i3] = photo.px[pj];
      col[i3 + 1] = photo.px[pj + 1];
      col[i3 + 2] = photo.px[pj + 2];
      const i4 = n * 4;
      dat[i4] = x / w;
      dat[i4 + 1] = y / hgt;
      dat[i4 + 2] = v;
      dat[i4 + 3] = rnd();
      n++;
    }
  }
  const cloud = new THREE.BufferGeometry();
  cloud.setAttribute('position', new THREE.BufferAttribute(pos.slice(0, n * 3), 3));
  cloud.setAttribute('aColor', new THREE.BufferAttribute(col.slice(0, n * 3), 3, true));
  cloud.setAttribute('aData', new THREE.BufferAttribute(dat.slice(0, n * 4), 4));

  // The projected dot pattern: a regular lattice, exact cell centres, no jitter.
  const lp = [];
  const lu = [];
  for (let r = 0; r < LATTICE.rows; r++) {
    for (let c = 0; c < LATTICE.cols; c++) {
      const u = (c + 0.5) / LATTICE.cols;
      const vv = (r + 0.5) / LATTICE.rows;
      const ix = Math.min(w - 1, (u * w) | 0);
      const iy = Math.min(hgt - 1, (vv * hgt) | 0);
      if (data[iy * w + ix] < SKY_V) continue;
      const z = zAt(ix, iy) * 0.995; // a hair in front of the surface it lands on
      lp.push(((u * w - w / 2) / f) * z, (-(vv * hgt - hgt / 2) / f) * z, -z);
      lu.push(u);
    }
  }
  const lattice = new THREE.BufferGeometry();
  lattice.setAttribute('position', new THREE.Float32BufferAttribute(lp, 3));
  lattice.setAttribute('aU', new THREE.Float32BufferAttribute(lu, 1));

  // Measured distances at the label spots: the median of a small window of the depth map.
  const win = [];
  const anchors = SPOTS.map((s) => {
    win.length = 0;
    const cx = Math.round(s.u * w);
    const cy = Math.round(s.v * hgt);
    for (let y = cy - 6; y <= cy + 6; y++) for (let x = cx - 6; x <= cx + 6; x++) win.push(data[y * w + x]);
    win.sort((a, b) => a - b);
    const v = win[win.length >> 1];
    const m = metres(v);
    const z = displayZ(m);
    return {
      name: s.name,
      metres: m,
      text: fmtDistance(m),
      at: new THREE.Vector3(((s.u * w - w / 2) / f) * z, (-(s.v * hgt - hgt / 2) / f) * z, -z),
    };
  });

  return { cloud, count: n, lattice, anchors, ang: GRID / f, f, w, h: hgt };
}

// ---- shaders ------------------------------------------------------------------------------------
const CLOUD_VERT = /* glsl */ `
attribute vec3 aColor;   // photo colour (sRGB)
attribute vec4 aData;    // photo u, v (y down), log depth (near = 1), seed
uniform float uScan;     // sweep front, in photo u
uniform float uFlat, uFlatD, uColor, uGain, uK, uAng, uFocal, uAlpha, uFeather, uTime, uMotion, uFade;
uniform vec3 uNear, uMid, uFar;
varying vec3 vCol;
varying float vA;
void main() {
  float zd = -position.z;
  float zc = mix(zd, uFlatD, uFlat);
  vec4 mv = modelViewMatrix * vec4(position * (zc / zd), 1.0);
  gl_Position = projectionMatrix * mv;

  float s = uScan - aData.x;
  float lag = aData.w * 0.06;
  float on = smoothstep(lag, lag + 0.05, s);
  float band = exp(-s * s * 2200.0);
  float d = aData.z;
  vec3 photo = pow(aColor, vec3(2.2));
  float lum = dot(photo, vec3(0.2126, 0.7152, 0.0722));
  vec3 dc = mix(uFar, uMid, smoothstep(0.12, 0.8, d));
  dc = mix(dc, uNear, smoothstep(0.86, 1.0, d));
  dc *= mix(0.3, 1.0, d * d) * (0.45 + 1.2 * sqrt(lum));
  vCol = mix(dc, photo * uGain, uColor) + uNear * band * 1.4 * (1.0 - uColor);

  float tw = 1.0 + uMotion * 0.14 * sin(uTime * 2.1 + aData.w * 61.0);
  vec2 e = min(aData.xy, 1.0 - aData.xy);
  float fw = mix(0.06, uFeather, uColor); // soft scan edges: the cloud melts into the ink
  float edge = smoothstep(0.0, fw, e.x) * smoothstep(0.0, fw * 1.3333, e.y);
  float horizon = mix(smoothstep(0.0, 0.16, d), 1.0, uColor);
  vA = (uAlpha * on * tw + band * 0.45 * (1.0 - uColor)) * edge * horizon * uFade;

  float px = uK * uAng * zc * uFocal / max(-mv.z, 0.05);
  gl_PointSize = vA > 0.002 ? clamp(px * (0.8 + 0.4 * aData.w) * (1.0 + band * 0.8), 0.0, 40.0) : 0.0;
}`;

const SOFT_FRAG = /* glsl */ `
varying vec3 vCol;
varying float vA;
void main() {
  vec2 q = gl_PointCoord * 2.0 - 1.0;
  float r2 = dot(q, q);
  if (r2 > 1.0) discard;
  gl_FragColor = vec4(vCol, vA * exp(-r2 * 3.2) * (1.0 - r2));
  #include <colorspace_fragment>
}`;

const LATTICE_VERT = /* glsl */ `
attribute float aU;
uniform float uScan, uOn, uSize;
uniform vec3 uCol;
varying vec3 vCol;
varying float vA;
void main() {
  vec4 mv = modelViewMatrix * vec4(position, 1.0);
  gl_Position = projectionMatrix * mv;
  float s = uScan - aU;
  float flash = exp(-s * s * 1400.0);
  vA = uOn * smoothstep(-0.006, 0.0, s) * (0.34 + 0.66 * flash);
  vCol = uCol;
  gl_PointSize = vA > 0.002 ? uSize * (1.0 + 1.6 * flash) : 0.0;
}`;

const PHOTO_VERT = /* glsl */ `
varying vec2 vUv;
void main() {
  vUv = uv;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
}`;

const PHOTO_FRAG = /* glsl */ `
uniform sampler2D uMap;
uniform float uOpacity, uFeather;
varying vec2 vUv;
void main() {
  vec3 c = texture2D(uMap, vUv).rgb;
  vec2 e = min(vUv, 1.0 - vUv);
  float edge = smoothstep(0.0, uFeather, e.x) * smoothstep(0.0, uFeather * 1.3333, e.y);
  vec2 q = (vUv - 0.5) * vec2(1.0, 0.75) * 2.0;
  c *= 1.0 - 0.32 * smoothstep(0.35, 1.25, length(q));
  gl_FragColor = vec4(c, edge * uOpacity);
  #include <colorspace_fragment>
}`;

const BEAM_VERT = /* glsl */ `
attribute float aT; // 0 at the lens -> 1 at the end of the beam
varying float vT;
void main() {
  vT = aT;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
}`;

const BEAM_FRAG = /* glsl */ `
uniform float uOpacity;
uniform vec3 uCol;
varying float vT;
void main() {
  gl_FragColor = vec4(uCol, uOpacity * pow(1.0 - vT, 1.5) * smoothstep(0.0, 0.12, vT));
  #include <colorspace_fragment>
}`;

const MOTE_VERT = /* glsl */ `
attribute vec4 aM; // seed, speed, phase, size
uniform float uTime, uOn, uPx;
uniform vec3 uCol;
varying vec3 vCol;
varying float vA;
void main() {
  float t = uTime * aM.y;
  vec3 p = position + vec3(sin(t + aM.z), cos(t * 0.8 + aM.z * 1.7), sin(t * 0.6 + aM.z * 2.3)) * 0.05;
  vec4 mv = modelViewMatrix * vec4(p, 1.0);
  gl_Position = projectionMatrix * mv;
  vA = uOn * (0.3 + 0.7 * (0.5 + 0.5 * sin(uTime * (0.5 + aM.y) + aM.x * 40.0)));
  vCol = uCol;
  gl_PointSize = vA > 0.002 ? uPx * aM.w / max(-mv.z, 0.2) : 0.0;
}`;

const GLOW_VERT = /* glsl */ `
uniform float uSize;
void main() {
  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  gl_PointSize = uSize;
}`;

const GLOW_FRAG = /* glsl */ `
uniform float uOn;
uniform vec3 uCol;
void main() {
  vec2 q = gl_PointCoord * 2.0 - 1.0;
  float r2 = dot(q, q);
  if (r2 > 1.0) discard;
  float core = exp(-r2 * 90.0);
  float halo = exp(-r2 * 7.0) * (1.0 - r2);
  vec3 c = mix(uCol, vec3(1.0), core);
  gl_FragColor = vec4(c, uOn * (core + halo * 0.5));
  #include <colorspace_fragment>
}`;

// ---- the module ---------------------------------------------------------------------------------
export function mountLidar(el, copy = {}) {
  // DOM
  el.classList.add('ld');
  const sticky = h('div', 'ld__sticky');
  const canvas = h('canvas', 'ld__canvas');
  canvas.setAttribute('role', 'img');
  canvas.setAttribute(
    'aria-label',
    'A LiDAR point cloud of three friends on a coastal boardwalk: the people stand about 2.4 metres away, the railing behind them, the sea far behind. It settles into the photograph.',
  );
  const vignette = h('div', 'ld__vignette');
  const fade = h('div', 'ld__fade'); // the stage's top and bottom melt into the page ink
  const tagsEl = h('div', 'ld__tags');
  tagsEl.setAttribute('aria-hidden', 'true');
  // the section title, and under it what does the work: LiDAR, on the phone
  const head = h('div', 'ld__head');
  const label = h('p', 'ld__label');
  label.append(h('i', 'ld__label-dot'), h('span', '', copy.label || LABEL));
  head.append(sectionTitle(TITLES.lidar, { className: 'ld__title' }), label);
  sticky.append(canvas, vignette, fade, tagsEl, head);
  el.append(sticky);

  const motionMQ = matchMedia('(prefers-reduced-motion: reduce)');
  let reduced = motionMQ.matches;
  let destroyed = false;
  let visible = false;
  let raf = 0;
  let lastT = 0;
  let clock = 0;
  let cur = -1;
  let target = 0;
  let dirty = true;
  let W = 1;
  let H = 1;
  let dpr = 1;
  let mobile = false;

  function readProgress() {
    const r = el.getBoundingClientRect();
    const total = r.height - window.innerHeight;
    return total > 0 ? clamp(-r.top / total) : 0;
  }
  const stepOf = (p) => (p >= STEP_AT[2] ? 2 : p >= STEP_AT[1] ? 1 : 0);

  // three.js
  let renderer;
  try {
    renderer = new THREE.WebGLRenderer({ canvas, antialias: false, alpha: false, powerPreference: 'high-performance' });
  } catch (err) {
    console.error('[lidar] WebGL unavailable, showing the photo', err);
    el.classList.add('ld--fallback');
    const img = h('img', 'ld__fallback');
    img.alt = '';
    img.src = SRC.photo;
    sticky.insertBefore(img, vignette);
  }
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(50, 1, 0.05, 200);
  const pivot = new THREE.Vector3(0, 0, -DP);
  const tmp = new THREE.Vector3();
  if (renderer) renderer.setClearColor(INK, 1);

  const U = {
    uScan: { value: -1 },
    uFlat: { value: 0 },
    uFlatD: { value: DP },
    uColor: { value: 0 },
    uK: { value: 1.6 },
    uAng: { value: 0.0025 },
    uFocal: { value: 1000 },
    uAlpha: { value: 0.6 },
    uFeather: { value: 0.07 },
    uTime: { value: 0 },
    uMotion: { value: 1 },
    uGain: { value: 1 },
    uFade: { value: 1 },
    uNear: { value: COL.near },
    uMid: { value: COL.mid },
    uFar: { value: COL.far },
  };
  const additive = {
    transparent: true,
    depthTest: false,
    depthWrite: false,
    blending: THREE.AdditiveBlending,
  };
  const cloudMat = new THREE.ShaderMaterial({ uniforms: U, vertexShader: CLOUD_VERT, fragmentShader: SOFT_FRAG, ...additive });
  const latticeU = { uScan: U.uScan, uOn: { value: 0 }, uSize: { value: 4 }, uCol: { value: COL.dot } };
  const latticeMat = new THREE.ShaderMaterial({ uniforms: latticeU, vertexShader: LATTICE_VERT, fragmentShader: SOFT_FRAG, ...additive });
  const photoU = { uMap: { value: null }, uOpacity: { value: 0 }, uFeather: U.uFeather };
  const photoMat = new THREE.ShaderMaterial({
    uniforms: photoU,
    vertexShader: PHOTO_VERT,
    fragmentShader: PHOTO_FRAG,
    transparent: true,
    depthTest: false,
    depthWrite: false,
  });
  const beamU = { uOpacity: { value: 0 }, uCol: { value: COL.mid } };
  const beamMat = new THREE.ShaderMaterial({ uniforms: beamU, vertexShader: BEAM_VERT, fragmentShader: BEAM_FRAG, side: THREE.DoubleSide, ...additive });
  const glowU = { uOn: { value: 1 }, uSize: { value: 80 }, uCol: { value: COL.near } };
  const glowMat = new THREE.ShaderMaterial({ uniforms: glowU, vertexShader: GLOW_VERT, fragmentShader: GLOW_FRAG, ...additive });
  const frustumMat = new THREE.LineBasicMaterial({ vertexColors: true, opacity: 0, ...additive });

  // The emitter: the phone's lens at the capture eye (the origin).
  const glowGeo = new THREE.BufferGeometry();
  glowGeo.setAttribute('position', new THREE.Float32BufferAttribute([0, 0, 0], 3));
  const glow = new THREE.Points(glowGeo, glowMat);
  glow.frustumCulled = false;
  glow.renderOrder = 5;

  // The projector frustum: four faint edges from the lens.
  const FR = 2.3;
  const fx = FR * (FRAME.w / 2 / FRAME.f);
  const fy = FR * TAN_Y;
  const frustumGeo = new THREE.BufferGeometry();
  frustumGeo.setAttribute(
    'position',
    new THREE.Float32BufferAttribute([0, 0, 0, -fx, fy, -FR, 0, 0, 0, fx, fy, -FR, 0, 0, 0, fx, -fy, -FR, 0, 0, 0, -fx, -fy, -FR], 3),
  );
  const fc = [];
  for (let i = 0; i < 4; i++) fc.push(COL.near.r, COL.near.g, COL.near.b, 0, 0, 0);
  frustumGeo.setAttribute('color', new THREE.Float32BufferAttribute(fc, 3));
  const frustum = new THREE.LineSegments(frustumGeo, frustumMat);
  frustum.frustumCulled = false;

  // The beam: the projector's field of view as a soft volume of light from the lens.
  const beamGeo = new THREE.BufferGeometry();
  const bp = [];
  const bt = [];
  const corners = [-fx, fy, fx, fy, fx, -fy, -fx, -fy];
  for (let i = 0; i < 4; i++) {
    const j = (i + 1) % 4;
    bp.push(0, 0, 0, corners[i * 2], corners[i * 2 + 1], -FR, corners[j * 2], corners[j * 2 + 1], -FR);
    bt.push(0, 1, 1);
  }
  beamGeo.setAttribute('position', new THREE.Float32BufferAttribute(bp, 3));
  beamGeo.setAttribute('aT', new THREE.Float32BufferAttribute(bt, 1));
  const beam = new THREE.Mesh(beamGeo, beamMat);
  beam.frustumCulled = false;

  let cloud = null;
  let lattice = null;
  let photoMesh = null;
  let photoTex = null;
  let data = null;
  const tags = [];

  // Motes drifting in the beam.
  const MOTES = 260;
  const mp = new Float32Array(MOTES * 3);
  const mm = new Float32Array(MOTES * 4);
  const mr = mulberry32(7);
  for (let i = 0; i < MOTES; i++) {
    const z = 0.3 + Math.pow(mr(), 0.7) * (FR - 0.3);
    mp[i * 3] = (mr() * 2 - 1) * z * (FRAME.w / 2 / FRAME.f) * 0.95;
    mp[i * 3 + 1] = (mr() * 2 - 1) * z * TAN_Y * 0.95;
    mp[i * 3 + 2] = -z;
    mm.set([mr(), 0.15 + mr() * 0.35, mr() * 6.28, 0.6 + mr() * 1.2], i * 4);
  }
  const moteGeo = new THREE.BufferGeometry();
  moteGeo.setAttribute('position', new THREE.BufferAttribute(mp, 3));
  moteGeo.setAttribute('aM', new THREE.BufferAttribute(mm, 4));
  const moteU = { uTime: U.uTime, uOn: { value: 0 }, uPx: { value: 30 }, uCol: { value: COL.dot } };
  const moteMat = new THREE.ShaderMaterial({ uniforms: moteU, vertexShader: MOTE_VERT, fragmentShader: SOFT_FRAG, ...additive });
  const motes = new THREE.Points(moteGeo, moteMat);
  motes.frustumCulled = false;

  scene.add(beam, frustum, motes, glow);

  // ---- layout ---------------------------------------------------------------------------------
  // The scene is framed by a "photo rect" centred on the stage: nearly full-bleed on desktop, wider
  // than the screen on a phone. The camera keeps the photo's own intrinsics with the principal point
  // at that rect's centre, so the front view at the end shows the photo exactly filling it.
  let focalCss = 1;
  function layout() {
    const r = sticky.getBoundingClientRect();
    W = Math.max(1, Math.round(r.width));
    H = Math.max(1, Math.round(r.height));
    mobile = W < 768;
    dpr = Math.min(window.devicePixelRatio || 1, 1.75);
    const cx = W / 2;
    const cy = H * (mobile ? 0.5 + MOBILE_DROP : 0.5);
    // desktop: as tall as the stage allows (the edges feather out); phone: 1.4x the width, cropped
    const rh = mobile ? Math.min(H * 0.62, W * 1.4 * 0.75) : Math.min(H, W * 0.94 * 0.75);
    focalCss = rh / (2 * TAN_Y);
    const n = camera.near;
    camera.projectionMatrix.makePerspective(
      (-n * cx) / focalCss,
      (n * (W - cx)) / focalCss,
      (n * cy) / focalCss,
      (-n * (H - cy)) / focalCss,
      n,
      camera.far,
    );
    camera.projectionMatrixInverse.copy(camera.projectionMatrix).invert();
    U.uFocal.value = focalCss * dpr;
    glowU.uSize.value = (mobile ? 56 : 84) * dpr;
    latticeU.uSize.value = (mobile ? 3 : 3.6) * dpr;
    moteU.uPx.value = (mobile ? 12 : 16) * dpr;
    if (renderer) {
      renderer.setPixelRatio(dpr);
      renderer.setSize(W, H, false);
    }
    el.style.setProperty('--ld-lead', `${mobile ? 40 : 60}px`);
    target = readProgress();
    dirty = true;
  }

  // ---- per-frame state (pure function of p and time, written into preallocated objects) ----------
  const S = { yaw: 0, pitch: 0, dist: 1, py: 0, pz: -DP, fly: 0 };
  function cameraAt(p, t) {
    let a = KEYS[0];
    let b = KEYS[1];
    if (p >= KEYS[1].p) {
      a = KEYS[1];
      b = KEYS[2];
    }
    let yaw;
    let pitch;
    let dist;
    if (p < KEYS[2].p) {
      const k = remap(p, a.p, b.p);
      yaw = lerp(a.yaw, b.yaw, k);
      pitch = lerp(a.pitch, b.pitch, k);
      dist = lerp(a.dist, b.dist, k);
      S.fly = 0;
    } else {
      const k = ease(remap(p, 0.65, 0.93));
      const e = KEYS[2];
      yaw = lerp(e.yaw, 0, k);
      pitch = lerp(e.pitch, 0, k);
      dist = lerp(e.dist, 1, k);
      S.fly = k;
    }
    const drift = 1 - S.fly;
    S.yaw = (yaw + drift * 3.2 * Math.sin(t * 0.31)) * D2R;
    S.pitch = (pitch + drift * 1.2 * Math.sin(t * 0.23 + 1.3)) * D2R;
    S.dist = dist * DP * lerp(mobile ? 0.92 : 1, 1, S.fly);
    S.py = lerp(-0.35, 0, S.fly);
    S.pz = lerp(-3.6, -DP, S.fly);
  }

  function apply(p, t) {
    cameraAt(p, t);
    pivot.set(0, S.py, S.pz);
    const cp = Math.cos(S.pitch);
    camera.position.set(
      pivot.x + S.dist * Math.sin(S.yaw) * cp,
      pivot.y + S.dist * Math.sin(S.pitch),
      pivot.z + S.dist * Math.cos(S.yaw) * cp,
    );
    camera.lookAt(pivot);
    camera.updateMatrixWorld();

    const scan = remap(p, 0.03, 0.3);
    const front = -0.1 + 1.25 * scan;
    U.uScan.value = front;
    U.uTime.value = t;
    U.uMotion.value = reduced ? 0 : 1 - S.fly;
    const color = ease(remap(p, 0.66, 0.8));
    U.uColor.value = color;
    U.uFlat.value = ease(remap(p, 0.76, 0.95));
    U.uK.value = lerp(1.75, 2.1, color);
    U.uAlpha.value = lerp(0.78, 0.6, color);
    // the sprites cover ~45% of each grid cell at this size; lift the photo colours so the cloud
    // reaches the photo's brightness by the time the photo itself fades in
    U.uGain.value = lerp(1, 2.1, color);
    U.uFade.value = 1 - ss(0.96, 0.995, p);
    U.uFeather.value = mobile ? 0.06 : 0.12;
    latticeU.uOn.value = ss(0.0, 0.04, p) * (1 - ss(0.3, 0.42, p));
    photoU.uOpacity.value = ss(0.88, 0.975, p);

    const emit = 1 - ss(0.56, 0.7, p);
    glowU.uOn.value = emit * (0.75 + 0.25 * ss(0.0, 0.05, p));
    frustumMat.opacity = 0.45 * (1 - ss(0.3, 0.46, p)) * (0.5 + 0.5 * ss(0, 0.05, p));
    beamU.uOpacity.value = 0.16 * (1 - ss(0.3, 0.48, p)) * (0.4 + 0.6 * ss(0, 0.05, p));
    beam.visible = beamU.uOpacity.value > 0.001;
    moteU.uOn.value = 0.45 * (1 - ss(0.4, 0.6, p));
    motes.visible = moteU.uOn.value > 0.001;
    glow.visible = glowU.uOn.value > 0.001;
    frustum.visible = frustumMat.opacity > 0.001;
    if (lattice) lattice.visible = latticeU.uOn.value > 0.001;
    if (photoMesh) photoMesh.visible = photoU.uOpacity.value > 0.001;
    if (cloud) cloud.visible = U.uFade.value > 0.001;

    // labels: project each anchor; leader + number follow it on screen
    for (let i = 0; i < tags.length; i++) {
      const tg = tags[i];
      const o = ss(0.37 + i * 0.025, 0.43 + i * 0.025, p) * (1 - ss(0.63, 0.69, p));
      tmp.copy(tg.at).project(camera);
      const on = o > 0.001 && tmp.z < 1 && tmp.x > -1.1 && tmp.x < 1.1 && tmp.y > -1.1 && tmp.y < 1.1;
      if (!on) {
        if (tg.shown) {
          tg.el.style.opacity = '0';
          tg.shown = false;
        }
        continue;
      }
      tg.shown = true;
      const x = (tmp.x * 0.5 + 0.5) * W;
      const y = (-tmp.y * 0.5 + 0.5) * H;
      tg.el.style.transform = `translate3d(${x.toFixed(1)}px, ${y.toFixed(1)}px, 0)`;
      tg.el.style.opacity = o.toFixed(3);
      tg.lead.style.transform = `scaleY(${(0.2 + 0.8 * o).toFixed(3)})`;
    }
  }

  function render() {
    if (renderer) renderer.render(scene, camera);
  }

  // ---- loop -----------------------------------------------------------------------------------
  function frame(now) {
    raf = 0;
    if (destroyed || !visible) return;
    const dt = lastT ? Math.min(0.064, (now - lastT) / 1000) : 1 / 60;
    lastT = now;

    let p;
    if (reduced) {
      p = STILL[stepOf(target)];
      const changed = p !== cur;
      cur = p;
      if (changed || dirty) {
        apply(p, 0);
        render();
        dirty = false;
      }
      return; // reduced motion renders on scroll/resize only
    }
    clock += dt;
    if (cur < 0) cur = target;
    cur += (target - cur) * (1 - Math.pow(1 - 0.12, dt * 60));
    if (Math.abs(target - cur) < 1e-4) cur = target;
    p = cur;
    apply(p, clock);
    render();
    dirty = false;
    raf = requestAnimationFrame(frame);
  }

  function invalidate() {
    if (!raf && visible && !destroyed) raf = requestAnimationFrame(frame);
  }

  // Progress is read on scroll (and resize / visibility), not per frame.
  const onScroll = () => {
    target = readProgress();
    invalidate();
  };
  const onMotion = () => {
    reduced = motionMQ.matches;
    cur = -1;
    dirty = true;
    invalidate();
  };
  window.addEventListener('scroll', onScroll, { passive: true });
  motionMQ.addEventListener?.('change', onMotion);

  const ro = new ResizeObserver(() => {
    layout();
    invalidate();
  });
  ro.observe(sticky);
  document.fonts?.ready.then(() => {
    if (destroyed) return;
    layout();
    invalidate();
  });

  const io = new IntersectionObserver(
    ([entry]) => {
      visible = entry.isIntersecting;
      target = readProgress();
      if (visible) {
        lastT = 0;
        dirty = true;
        invalidate();
      } else if (raf) {
        cancelAnimationFrame(raf);
        raf = 0;
      }
    },
    { rootMargin: '80px 0px' },
  );
  io.observe(el);

  const onLost = (e) => e.preventDefault();
  canvas.addEventListener('webglcontextlost', onLost);

  layout();

  // ---- data -----------------------------------------------------------------------------------
  if (renderer) {
    Promise.all([loadPhoto(SRC.photo), loadPackedDepth(SRC.packed)])
      .then(([photo, depth]) => {
        if (destroyed) return;
        data = buildScene(photo, depth);
        U.uAng.value = data.ang;

        cloud = new THREE.Points(data.cloud, cloudMat);
        cloud.frustumCulled = false;
        cloud.renderOrder = 1;
        lattice = new THREE.Points(data.lattice, latticeMat);
        lattice.frustumCulled = false;
        lattice.renderOrder = 2;

        photoTex = new THREE.CanvasTexture(photo.canvas);
        photoTex.colorSpace = THREE.SRGBColorSpace;
        photoTex.anisotropy = Math.min(8, renderer.capabilities.getMaxAnisotropy());
        photoU.uMap.value = photoTex;
        const ph = 2 * DP * TAN_Y;
        photoMesh = new THREE.Mesh(new THREE.PlaneGeometry(ph * (FRAME.w / FRAME.h), ph), photoMat);
        photoMesh.position.z = -DP;
        photoMesh.renderOrder = 3;
        photoMesh.frustumCulled = false;
        scene.add(cloud, lattice, photoMesh);

        for (const a of data.anchors) {
          const t = h('div', 'ld-tag');
          const dot = h('i', 'ld-tag__dot');
          const lead = h('i', 'ld-tag__lead');
          const txt = h('span', 'ld-tag__text');
          txt.append(h('span', 'ld-tag__name', a.name), h('span', 'ld-tag__num', a.text));
          t.append(dot, lead, txt);
          tagsEl.append(t);
          tags.push({ el: t, lead, at: a.at, shown: false });
        }
        el.dataset.points = String(data.count);
        el.dataset.distances = data.anchors.map((a) => `${a.name}:${a.metres.toFixed(2)}`).join(',');
        el.classList.add('is-ready');
        dirty = true;
        invalidate();
      })
      .catch((err) => {
        console.error('[lidar] failed to load the scene data', err);
      });
  }

  return {
    destroy() {
      if (destroyed) return;
      destroyed = true;
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
      window.removeEventListener('scroll', onScroll);
      motionMQ.removeEventListener?.('change', onMotion);
      ro.disconnect();
      io.disconnect();
      canvas.removeEventListener('webglcontextlost', onLost);
      for (const g of [glowGeo, frustumGeo, beamGeo, moteGeo, data?.cloud, data?.lattice, photoMesh?.geometry]) g?.dispose();
      for (const m of [cloudMat, latticeMat, photoMat, beamMat, moteMat, glowMat, frustumMat]) m.dispose();
      photoTex?.dispose();
      scene.clear();
      if (renderer) {
        renderer.dispose();
        renderer.forceContextLoss();
      }
      sticky.remove();
      el.classList.remove('ld', 'ld--fallback', 'is-ready');
      el.style.removeProperty('--ld-lead');
      delete el.dataset.points;
      delete el.dataset.distances;
    },
  };
}
