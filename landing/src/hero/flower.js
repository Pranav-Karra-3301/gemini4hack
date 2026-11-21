// Procedural heliotrope (Heliotropium arborescens): floret, leaf and stem geometry plus the
// cluster layout. Everything here runs once at mount; nothing is allocated per frame.
import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';

export function makeRng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const clamp01 = (x) => Math.min(1, Math.max(0, x));
const smooth = (a, b, x) => {
  const t = clamp01((x - a) / (b - a));
  return t * t * (3 - 2 * t);
};

function gridIndex(rings, seg, offset, out) {
  for (let i = 0; i < rings - 1; i++) {
    for (let j = 0; j < seg; j++) {
      const a = offset + i * seg + j;
      const b = offset + (i + 1) * seg + j;
      const c = offset + (i + 1) * seg + ((j + 1) % seg);
      const d = offset + i * seg + ((j + 1) % seg);
      out.push(a, b, c, a, c, d);
    }
  }
}

/**
 * One floret, radius 1, facing +Z. The limb is five rounded, slightly ruffled lobes fused into a
 * short tube (going to -Z). `position`/`normal` hold the open flower; `aBud`/`aBudN` the same
 * vertices folded into a closed five-ridged bud, so the shader can morph per instance.
 */
export function floretGeometry() {
  const SEG = 35;
  const RINGS = [0, 0.06, 0.15, 0.27, 0.41, 0.56, 0.71, 0.85, 0.95, 1.0];
  const TUBE = [
    [0.13, -0.07],
    [0.11, -0.45],
    [0.085, -0.8],
  ];
  const TSEG = 8;
  const n = RINGS.length * SEG + TUBE.length * TSEG;
  const open = new Float32Array(n * 3);
  const bud = new Float32Array(n * 3);
  const rho = new Float32Array(n);
  const lobe = new Float32Array(n);
  let k = 0;
  for (let i = 0; i < RINGS.length; i++) {
    const p = RINGS[i];
    for (let j = 0; j < SEG; j++, k++) {
      const th = (j / SEG) * Math.PI * 2;
      const c = Math.abs(Math.cos(2.5 * th)); // 1 at a lobe centre, 0 at the notch
      const shape = 0.6 + 0.4 * Math.sqrt(c);
      const s = smooth(0.06, 0.32, p);
      const r = p * (1 - s + s * shape);
      const z =
        -0.2 * (1 - smooth(0, 0.22, p)) + // throat dips into the tube
        0.1 * p * p + // shallow cup
        0.055 * Math.sin(Math.PI * clamp01((p - 0.2) / 0.8)) * c * c + // each lobe slightly domed
        0.04 * p * p * p * Math.sin(th * 15 + 0.6); // ruffled rim
      open[k * 3] = r * Math.cos(th);
      open[k * 3 + 1] = r * Math.sin(th);
      open[k * 3 + 2] = z;
      const phi = p * Math.PI * 0.93;
      const tb = th + 0.5 * p; // buds are slightly twisted
      const rb = 0.36 * Math.sin(phi) * (0.8 + 0.2 * shape);
      bud[k * 3] = rb * Math.cos(tb);
      bud[k * 3 + 1] = rb * Math.sin(tb);
      bud[k * 3 + 2] = -0.2 + 0.47 * (1 - Math.cos(phi));
      rho[k] = p;
      lobe[k] = c;
    }
  }
  for (let i = 0; i < TUBE.length; i++) {
    const [r, z] = TUBE[i];
    for (let j = 0; j < TSEG; j++, k++) {
      const th = (j / TSEG) * Math.PI * 2;
      open[k * 3] = bud[k * 3] = r * Math.cos(th);
      open[k * 3 + 1] = bud[k * 3 + 1] = r * Math.sin(th);
      open[k * 3 + 2] = bud[k * 3 + 2] = z;
      rho[k] = -1;
      lobe[k] = 0;
    }
  }
  const idx = [];
  gridIndex(RINGS.length, SEG, 0, idx);
  gridIndex(TUBE.length, TSEG, RINGS.length * SEG, idx);

  const g = new THREE.BufferGeometry();
  g.setIndex(idx);
  g.setAttribute('position', new THREE.BufferAttribute(bud, 3));
  g.computeVertexNormals();
  const budN = g.getAttribute('normal').array.slice();
  g.setAttribute('position', new THREE.BufferAttribute(open, 3));
  g.computeVertexNormals();
  g.setAttribute('aBud', new THREE.BufferAttribute(bud, 3));
  g.setAttribute('aBudN', new THREE.BufferAttribute(budN, 3));
  g.setAttribute('aRho', new THREE.BufferAttribute(rho, 1));
  g.setAttribute('aLobe', new THREE.BufferAttribute(lobe, 1));
  return g;
}

/** Ovate leaf, length 1 along +Z, upper face +Y. Impressed lateral veins give the crinkle. */
export function leafGeometry() {
  const NU = 46;
  const NV = 16;
  const pos = [];
  const uv = [];
  for (let iu = 0; iu <= NU; iu++) {
    const u = iu / NU;
    const w = 0.4 * Math.pow(Math.sin(Math.PI * Math.pow(u, 0.72)), 0.82);
    for (let iv = 0; iv <= NV; iv++) {
      const v = (iv / NV) * 2 - 1;
      const av = Math.abs(v);
      const phase = u * 8.5 - av * 1.5;
      const fr = phase - Math.floor(phase);
      const quilt = 0.5 - 0.5 * Math.cos(fr * Math.PI * 2); // 0 on a vein, 1 between veins
      const env = Math.sin(Math.PI * u) * (1 - av * av * av);
      const y =
        0.024 * quilt * env -
        0.018 * Math.exp(-Math.pow((v * w) / 0.05, 2)) * env -
        0.11 * v * v * w -
        0.24 * u * u;
      pos.push(v * w, y, u);
      uv.push(u, v);
    }
  }
  const idx = [];
  const row = NV + 1;
  for (let iu = 0; iu < NU; iu++) {
    for (let iv = 0; iv < NV; iv++) {
      const a = iu * row + iv;
      idx.push(a, a + 1, a + row + 1, a, a + row + 1, a + row);
    }
  }
  const g = new THREE.BufferGeometry();
  g.setIndex(idx);
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
  g.computeVertexNormals();
  return g;
}

/**
 * Main stalk, the primary branches that carry the cymes, and a dark core that fills the dome so
 * the gaps between florets read as dense green, not as holes to the sky.
 */
export function stemGeometry(seed, { R = 1, H = 0.46 } = {}) {
  const rand = makeRng(seed);
  const parts = [];
  const stalk = new THREE.CatmullRomCurve3([
    new THREE.Vector3(0.08, -3.4, 0.12),
    new THREE.Vector3(0.03, -1.6, 0.05),
    new THREE.Vector3(0, -0.55, 0),
    new THREE.Vector3(0, -0.18, 0),
  ]);
  parts.push(new THREE.TubeGeometry(stalk, 24, 0.045, 7, false));
  for (let i = 0; i < 6; i++) {
    const a = (i / 6) * Math.PI * 2 + rand() * 0.5;
    const r = 0.42 + rand() * 0.2;
    const c = new THREE.CatmullRomCurve3([
      new THREE.Vector3(0, -0.22, 0),
      new THREE.Vector3(Math.cos(a) * r * 0.4, -0.12, Math.sin(a) * r * 0.4),
      new THREE.Vector3(Math.cos(a) * r, 0.02, Math.sin(a) * r),
    ]);
    parts.push(new THREE.TubeGeometry(c, 8, 0.022, 5, false));
  }
  const core = new THREE.SphereGeometry(1, 40, 16, 0, Math.PI * 2, 0, Math.PI * 0.5);
  core.scale(R * 0.82, H * 0.74, R * 0.82);
  parts.push(core);
  const g = mergeGeometries(parts);
  for (const p of parts) p.dispose();
  return g;
}

/**
 * Cluster layout: coiled scorpioid cymes radiating over a flattened dome, then a gap fill so the
 * dome reads as a dense head of florets. Returns plain arrays in cluster-local space (dome top +Y).
 */
export function buildCluster(seed, { floretR = 0.036, R = 1, H = 0.36, primaries = 6, grow = 1.42, fill2 = true } = {}) {
  const rand = makeRng(seed);
  const P = 2.6;
  // Superellipse profile (r/R)^P + (y/H)^2 = 1, from the top down slightly past the equator.
  const M = 320;
  const prof = [];
  let s = 0;
  let pr = 0;
  let py = 0;
  let sEq = 0;
  for (let i = 0; i <= M; i++) {
    const phi = Math.PI / 2 - ((Math.PI / 2 + 0.5) * i) / M;
    const r = R * Math.pow(Math.max(Math.cos(phi), 0), 2 / P);
    const y = H * Math.sin(phi);
    if (i) s += Math.hypot(r - pr, y - py);
    if (phi > 0) sEq = s;
    let nr = (P * Math.pow(r / R, P - 1)) / R;
    let ny = (2 * y) / (H * H);
    const l = Math.hypot(nr, ny) || 1;
    prof.push({ s, r, y, nr: nr / l, ny: ny / l });
    pr = r;
    py = y;
  }
  const sMax = s;
  const wob = [0.06 + rand() * 0.04, rand() * 6.28, 0.03 + rand() * 0.03, rand() * 6.28, rand() * 6.28, rand() * 6.28];
  const surf = (t, th, out) => {
    const ss = Math.min(t * sEq, sMax - 1e-6);
    let i = 1;
    while (i < prof.length - 1 && prof[i].s < ss) i++;
    const a = prof[i - 1];
    const b = prof[i];
    const f = (ss - a.s) / (b.s - a.s || 1);
    const r = a.r + (b.r - a.r) * f;
    const y = a.y + (b.y - a.y) * f;
    const nr = a.nr + (b.nr - a.nr) * f;
    const ny = a.ny + (b.ny - a.ny) * f;
    const c = Math.cos(th);
    const sn = Math.sin(th);
    // an irregular, lumpy head: sub-domes where the cyme groups bunch up
    const lump = 1 + wob[0] * Math.sin(2 * th + wob[1]) + wob[2] * Math.sin(5 * th + wob[3]);
    const bump = 1 + 0.13 * Math.sin(t * 7 + wob[4]) * Math.cos(th * 3 + wob[5]) * Math.min(1, t * 2);
    out.p.set(r * c * lump, y * bump * lump, r * sn * lump);
    out.n.set(nr * c, ny, nr * sn).normalize();
    return out;
  };

  const D = floretR * 2;
  const florets = [];
  // spatial hash for spacing checks
  const cell = D;
  const hash = new Map();
  const key = (x, y, z) => `${Math.floor(x / cell)},${Math.floor(y / cell)},${Math.floor(z / cell)}`;
  // true if a floret of footprint radius r at p would crowd an existing one
  const near = (p, r, k) => {
    const cx = Math.floor(p.x / cell);
    const cy = Math.floor(p.y / cell);
    const cz = Math.floor(p.z / cell);
    for (let x = cx - 1; x <= cx + 1; x++)
      for (let y = cy - 1; y <= cy + 1; y++)
        for (let z = cz - 1; z <= cz + 1; z++) {
          const list = hash.get(`${x},${y},${z}`);
          if (!list) continue;
          for (const f of list) {
            const m = (r + f.r) * k;
            if (f.p.distanceToSquared(p) < m * m) return true;
          }
        }
    return false;
  };
  const add = (f) => {
    florets.push(f);
    const k = key(f.p.x, f.p.y, f.p.z);
    if (!hash.has(k)) hash.set(k, []);
    hash.get(k).push(f);
  };

  const tmp = { p: new THREE.Vector3(), n: new THREE.Vector3() };
  const tmp2 = { p: new THREE.Vector3(), n: new THREE.Vector3() };
  const cymes = [];
  for (let i = 0; i < primaries; i++) {
    const a0 = (i / primaries) * Math.PI * 2 + (rand() - 0.5) * 0.5;
    const nc = 2 + (rand() < 0.55 ? 1 : 0);
    for (let j = 0; j < nc; j++) {
      cymes.push({
        a: a0 + (j - (nc - 1) / 2) * (1.0 / nc) + (rand() - 0.5) * 0.15,
        t0: 0.08 + rand() * 0.16,
        curl: rand() < 0.5 ? -1 : 1,
      });
    }
  }
  for (const cy of cymes) {
    const len = (1.16 - cy.t0) * (0.62 + 0.38 * rand());
    let x = Math.cos(cy.a) * cy.t0;
    let z = Math.sin(cy.a) * cy.t0;
    let hd = cy.a + (rand() - 0.5) * 0.35;
    const ds = 0.003;
    let acc = 0;
    let row = 0;
    let next = 0;
    for (let sArc = 0; sArc <= len; sArc += ds) {
      const q = sArc / len;
      const kq = cy.curl * (0.35 + 34 * Math.pow(q, 6)); // curvature climbs toward the tip: the coil
      hd += kq * ds;
      x += Math.cos(hd) * ds;
      z += Math.sin(hd) * ds;
      acc += ds;
      if (acc < next) continue;
      acc = 0;
      const size = (1 - 0.6 * smooth(0.55, 1.0, q)) * (0.9 + 0.2 * rand());
      next = D * 0.5 * size;
      const side = (row++ % 2 ? 1 : -1) * D * 0.47 * size * (1 - 0.7 * smooth(0.7, 1, q));
      const fx = x - Math.sin(hd) * side;
      const fz = z + Math.cos(hd) * side;
      const t = Math.hypot(fx, fz);
      const th = Math.atan2(fz, fx);
      surf(t, th, tmp);
      const open = 1 - smooth(0.6, 0.9, q + (rand() - 0.5) * 0.08);
      const lift = 0.006 + (1 - open) * 0.012;
      const p = tmp.p.clone().addScaledVector(tmp.n, lift);
      if (near(p, D * 0.5 * size, 0.85)) continue;
      // tilt the floret outward along the cyme and a little at random
      surf(Math.hypot(fx + Math.cos(hd) * 0.02, fz + Math.sin(hd) * 0.02), Math.atan2(fz + Math.sin(hd) * 0.02, fx + Math.cos(hd) * 0.02), tmp2);
      const fwd = tmp2.p.clone().sub(tmp.p).normalize();
      const face = tmp.n
        .clone()
        .addScaledVector(fwd, 0.18 + (1 - open) * 0.25)
        .add(new THREE.Vector3(rand() - 0.5, rand() - 0.5, rand() - 0.5).multiplyScalar(0.35))
        .normalize();
      add({
        p,
        face,
        domeN: tmp.n.clone(),
        r: D * 0.5 * size,
        scale: grow * floretR * size * (0.5 + 0.5 * open),
        open,
        var: clamp01(open * (0.25 + 0.55 * rand()) + 0.25 * (1 - q)),
        occ: (t > 1 ? 0.6 : 1) * (0.9 + 0.1 * rand()),
      });
    }
  }
  // gap fill: open florets nestled between the cymes, then smaller, deeper ones in what is left
  const NC = 3200;
  const golden = Math.PI * (3 - Math.sqrt(5));
  for (let i = 0; i < NC * (fill2 ? 2 : 1); i++) {
    const second = i >= NC;
    const j = second ? i - NC : i;
    const size = second ? 0.68 : 1;
    const t = 0.99 * Math.sqrt((j + 0.5) / NC);
    const th = j * golden + (second ? 1.3 : 0) + (rand() - 0.5) * 0.05;
    surf(t, th, tmp);
    const p = tmp.p.clone().addScaledVector(tmp.n, -0.004 - rand() * 0.012 - (second ? 0.012 : 0));
    if (near(p, D * 0.5 * size, 0.8)) continue;
    const face = tmp.n
      .clone()
      .add(new THREE.Vector3(rand() - 0.5, rand() - 0.5, rand() - 0.5).multiplyScalar(0.4))
      .normalize();
    add({
      p,
      face,
      domeN: tmp.n.clone(),
      r: D * 0.5 * size,
      scale: grow * floretR * size * (0.85 + 0.25 * rand()),
      open: 0.82 + 0.18 * rand(),
      var: 0.15 + 0.75 * rand(),
      occ: (second ? 0.6 : 0.74) + 0.14 * rand(),
    });
  }
  return florets;
}

/** Bake florets into instance arrays, optionally through a cluster transform. */
export function floretInstances(list, transform, seed) {
  const rand = makeRng(seed);
  const n = list.length;
  const mats = new Float32Array(n * 16);
  const open = new Float32Array(n);
  const vari = new Float32Array(n);
  const occ = new Float32Array(n);
  const sd = new Float32Array(n);
  const domeN = new Float32Array(n * 3);
  const m = new THREE.Matrix4();
  const q = new THREE.Quaternion();
  const roll = new THREE.Quaternion();
  const z = new THREE.Vector3(0, 0, 1);
  const sc = new THREE.Vector3();
  const tq = new THREE.Quaternion();
  const tp = new THREE.Vector3();
  const ts = new THREE.Vector3();
  if (transform) transform.decompose(tp, tq, ts);
  list.forEach((f, i) => {
    q.setFromUnitVectors(z, f.face);
    roll.setFromAxisAngle(z, rand() * Math.PI * 2);
    q.multiply(roll);
    sc.setScalar(f.scale);
    m.compose(f.p, q, sc);
    if (transform) m.premultiply(transform);
    m.toArray(mats, i * 16);
    open[i] = f.open;
    vari[i] = f.var;
    occ[i] = f.occ;
    sd[i] = rand();
    const dn = f.domeN.clone();
    if (transform) dn.applyQuaternion(tq);
    dn.toArray(domeN, i * 3);
  });
  return { n, mats, open, vari, occ, sd, domeN };
}

export function concatInstances(a, b) {
  const cat = (x, y) => {
    const out = new Float32Array(x.length + y.length);
    out.set(x);
    out.set(y, x.length);
    return out;
  };
  return {
    n: a.n + b.n,
    mats: cat(a.mats, b.mats),
    open: cat(a.open, b.open),
    vari: cat(a.vari, b.vari),
    occ: cat(a.occ, b.occ),
    sd: cat(a.sd, b.sd),
    domeN: cat(a.domeN, b.domeN),
  };
}

/** A whorl of leaves under a cluster. Returns { n, mats, vari }. */
export function leafInstances(seed, count, transform, { y = -0.32, len = [0.95, 1.45] } = {}) {
  const rand = makeRng(seed);
  const mats = new Float32Array(count * 16);
  const vari = new Float32Array(count);
  const m = new THREE.Matrix4();
  const e = new THREE.Euler();
  const q = new THREE.Quaternion();
  const p = new THREE.Vector3();
  const s = new THREE.Vector3();
  for (let i = 0; i < count; i++) {
    // alternate leaves spiralling down the stem (golden angle), larger and more drooped lower down
    const az = i * 2.39996 + 0.6 + (rand() - 0.5) * 0.7;
    const f = i / Math.max(1, count - 1);
    const towardCam = Math.max(0, Math.cos(az)); // +Z faces the camera
    const L = (len[0] + (len[1] - len[0]) * (0.35 * rand() + 0.65 * f)) * (1 - 0.25 * towardCam);
    p.set(Math.sin(az) * 0.07, y - f * 0.75 - rand() * 0.06, Math.cos(az) * 0.07);
    e.set(0.04 + rand() * 0.2 + f * 0.15 + towardCam * 0.22, az, (rand() - 0.5) * 0.7, 'YXZ');
    q.setFromEuler(e);
    s.set(L, L, L);
    m.compose(p, q, s);
    if (transform) m.premultiply(transform);
    m.toArray(mats, i * 16);
    vari[i] = rand();
  }
  return { n: count, mats, vari };
}
