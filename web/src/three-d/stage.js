import * as THREE from 'three';
import { SparkRenderer, SplatMesh, unpackSplat } from '@sparkjsdev/spark';
import { makeFocusModifier, makeFocusUniforms } from './focusShader.js';
import { Spring, SpringV3, approach, bezier } from './motion.js';

// The 3D view. World = capture camera at the origin looking down -Z, +Y up. Splat files are in
// the capture camera's own frame (x right, y down, z forward); a half turn about X maps them in.
// Frames are drawn on demand: only while a spring, the reveal or the camera moves, or Spark
// finishes a re-sort (wayback's approach).

const FILE_TO_WORLD = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(1, 0, 0), Math.PI);
const PLANE_D = 4; // the flat photo's distance (m) until a splat exists
const MIN_FRAC = 0.66; // show at least this much of the photo on either axis...
const FILL_MIN = 0.82; // ...unless that would fill less than this much of the screen
const REVEAL_S = 2.6;
const FOCUS_OMEGA = 7.2; // ~0.8 s to settle, critically damped
export const LIFT = 0.09;
const PUSH = 0.075; // camera eases this fraction of the subject's depth toward it
const LOOK = 0.5; // ...and turns this much of the way to face it
const ZMAX = 1.3; // focus may zoom in this much to keep a turned view inside the photo
const ZOOM_MIN = 0.06; // ...and always zooms at least this much (a gentle push-in)
const OVERSCAN = 1.04; // base view sits this much inside the photo, room for parallax
const MIN_LOOK = THREE.MathUtils.degToRad(2.5);
const RF_STEP = 0.2; // reframe flight step cap, x the nearest content's distance
const RF_OUT = 1.4; // reframe flight, s (DESIGN.md: 1400ms ease-in-out)
const RF_BACK = 0.9; // ...and back to the original
const RF_APEX = 0.04; // the flight arcs up by this much of the scene radius
const easeInOut = bezier(0.65, 0, 0.35, 1);
const REDUCED = matchMedia('(prefers-reduced-motion: reduce)');

const blankMask = () => {
  const t = new THREE.DataTexture(new Uint8Array(4), 1, 1, THREE.RGBAFormat);
  t.needsUpdate = true;
  return t;
};

function makePlaneMaterial() {
  return new THREE.ShaderMaterial({
    transparent: true,
    depthWrite: false,
    uniforms: {
      map: { value: null },
      opacity: { value: 0 },
      mask: { value: blankMask() },
      hasMask: { value: 0 },
      w: { value: new THREE.Vector3() },
      a0: { value: new THREE.Vector2(0.5, 0.5) },
      a1: { value: new THREE.Vector2(0.5, 0.5) },
      a2: { value: new THREE.Vector2(0.5, 0.5) },
      aspect: { value: 1 },
    },
    vertexShader: /* glsl */ `
      varying vec2 vUv;
      void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`,
    // Flat fallback of the focus effect: same weights and mask, no depth to move.
    fragmentShader: /* glsl */ `
      uniform sampler2D map; uniform sampler2D mask; uniform float opacity; uniform float hasMask;
      uniform vec3 w; uniform vec2 a0; uniform vec2 a1; uniform vec2 a2; uniform float aspect;
      varying vec2 vUv;
      void main() {
        vec2 iuv = vec2(vUv.x, 1.0 - vUv.y);
        vec3 rgb = texture2D(map, iuv).rgb;
        vec3 m = hasMask > 0.5 ? texture2D(mask, iuv).rgb : vec3(0.0);
        vec3 sv = smoothstep(vec3(0.3), vec3(0.7), m) * w;
        float wsum = w.x + w.y + w.z;
        float F = clamp(wsum, 0.0, 1.0);
        float s = clamp(sv.x + sv.y + sv.z, 0.0, 1.0);
        float o = max(F - s, 0.0);
        vec2 anc = (a0 * w.x + a1 * w.y + a2 * w.z) / max(wsum, 1e-4);
        vec2 dd = (iuv - anc) * vec2(aspect, 1.0);
        float lvl = mix(0.04, 0.2, exp(-dot(dd, dd) / 0.08));
        float lum = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
        rgb = mix(rgb, mix(rgb, vec3(lum), 0.6) * lvl, o);
        rgb = mix(rgb, rgb * 1.12 + vec3(0.022, 0.016, 0.007), s);
        vec2 e = min(vUv, 1.0 - vUv);
        float edge = smoothstep(0.0, 0.02, min(e.x, e.y));
        gl_FragColor = vec4(rgb, opacity * edge);
      }`,
  });
}

export function createStage(canvas, { onFrame } = {}) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: false, powerPreference: 'high-performance' });
  const dpr = () => Math.min(window.devicePixelRatio || 1, 1.5);
  renderer.setPixelRatio(dpr());
  renderer.setSize(innerWidth, innerHeight, false);
  renderer.setClearColor(0x08080a, 1);

  let renderRequested = true;
  const requestRender = () => {
    renderRequested = true;
  };

  const scene = new THREE.Scene();
  scene.add(new SparkRenderer({ renderer, onDirty: requestRender }));
  const camera = new THREE.PerspectiveCamera(50, innerWidth / innerHeight, 0.01, 4000);

  // ---- the open photo ----
  const view = {
    token: 0,
    tanX: 0.5,
    tanY: 0.375,
    V: 0.4, // tan of the base view's vertical half-angle
    S: PLANE_D, // scene scale: median splat distance (or the plane's)
    near: PLANE_D, // distance of the nearest content (3rd percentile)
    mesh: null,
    u: null,
    count: 0,
    samples: null,
    revealT: -1, // < 0: not started; >= REVEAL_S: done
    regions: [], // { id, anchor (file coords), gate, uv }
    hasMask: 0,
  };
  const planeMat = makePlaneMaterial();
  const plane = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), planeMat);
  plane.visible = false;
  plane.renderOrder = -1;
  scene.add(plane);
  const planeO = new Spring(0, 9);

  // ---- focus (per-region weights) and camera ----
  const weights = [0, 1, 2].map(() => new Spring(0, FOCUS_OMEGA));
  // remove regions: dissolve weights (springs) and a highlight pulse that plays first
  const rWeights = [0, 1, 2].map(() => new Spring(0, FOCUS_OMEGA));
  const hl = [0, 1, 2].map(() => ({ t: -1, x: 0, hold: 0 })); // t: pulse clock (s), < 0 idle
  const REMOVE_DELAY = 0.32; // the dissolve starts as the pulse peaks
  const camF = new Spring(0, FOCUS_OMEGA);
  const camAnchor = new SpringV3(FOCUS_OMEGA);
  const dolly = new Spring(0, 6);
  // Reframe flight: a timed ease-in-out tween (retargets from wherever it is) with an arc.
  const fl = { x: 0, from: 0, to: 0, t: 0, dur: 0, lift: 0, lift0: 0, apex: 0 };
  const rf = { pos: new THREE.Vector3(), quat: new THREE.Quaternion(), yaw: 0, pitch: 0, Z: 1, scale: 1 };
  const flightCancelHandlers = [];
  const swipeHandlers = [];
  const pointer = new THREE.Vector2(); // target parallax, [-1, 1]
  const par = new THREE.Vector2();
  const look = { yaw: 0, pitch: 0, tyaw: 0, tpitch: 0, maxYaw: 0.1, maxPitch: 0.1 };
  let focusedIdx = -1;

  // ---- helpers ----
  const tmp2 = new THREE.Vector3();
  const qId = new THREE.Quaternion();
  const toWorld = (v, out) => out.set(v.x, -v.y, -v.z);

  function fitFov() {
    const a = camera.aspect;
    const cover = Math.min(view.tanY, view.tanX / a);
    const contain = Math.max(view.tanY, view.tanX / a);
    // Prefer filling the screen; when the photo's shape is far from the screen's, show more of
    // it, but always fill at least FILL_MIN of the screen (thin bars sit under the controls).
    view.V = THREE.MathUtils.clamp(MIN_FRAC * contain, cover / OVERSCAN, cover / FILL_MIN);
    camera.fov = THREE.MathUtils.radToDeg(2 * Math.atan(view.V));
    camera.updateProjectionMatrix();
    // Drag may look around as far as the photo reaches (a little more where it's cropped).
    const sl = slack(1);
    look.maxYaw = Math.max(MIN_LOOK, sl.yaw);
    look.maxPitch = Math.max(MIN_LOOK, sl.pitch);
  }

  function placePlane() {
    plane.position.set(0, 0, -PLANE_D);
    plane.scale.set(2 * PLANE_D * view.tanX, 2 * PLANE_D * view.tanY, 1);
    planeMat.uniforms.aspect.value = view.tanX / view.tanY;
  }

  function setIntrinsics(tanX, tanY) {
    view.tanX = tanX;
    view.tanY = tanY;
    if (view.u) {
      view.u.tanX.value = tanX;
      view.u.tanY.value = tanY;
    }
    placePlane();
    fitFov();
    requestRender();
  }

  function disposeMesh() {
    if (!view.mesh) return;
    scene.remove(view.mesh);
    view.mesh.dispose?.();
    view.mesh = null;
    view.u = null;
    view.samples = null;
    view.count = 0;
  }

  /** New photo: flat print up front, everything else reset. Returns a token for staleness checks. */
  function showPhoto(bitmap, intr) {
    view.token++;
    disposeMesh();
    clearRegions();
    view.revealT = -1;
    view.S = view.near = PLANE_D;
    const old = planeMat.uniforms.map.value;
    const tex = new THREE.Texture(bitmap);
    tex.flipY = false;
    tex.colorSpace = THREE.NoColorSpace; // raw sRGB in, raw out: matches the splats
    tex.minFilter = THREE.LinearFilter;
    tex.generateMipmaps = false;
    tex.needsUpdate = true;
    planeMat.uniforms.map.value = tex;
    old?.dispose();
    plane.visible = true;
    planeO.snap(0).set(1);
    setIntrinsics(intr.tanX, intr.tanY);
    resetCamera();
    return view.token;
  }

  function resetCamera() {
    camF.snap(0);
    camAnchor.snap(new THREE.Vector3(0, 0, -view.S));
    dolly.snap(0);
    reframeTo(0, { instant: true });
    look.yaw = look.pitch = look.tyaw = look.tpitch = 0;
    focusedIdx = -1;
    for (const w of weights) w.snap(0);
    for (const w of rWeights) w.snap(0);
  }

  // Read ~160k evenly spaced splats: depth range for the reveal, scene scale, and the
  // samples that place markers.
  function measure(mesh, count) {
    const step = Math.max(1, Math.floor(count / 160000));
    const n = Math.ceil(count / step);
    const s = { n: 0, z: new Float32Array(n), nx: new Float32Array(n), ny: new Float32Array(n), op: new Float32Array(n) };
    const dists = [];
    const add = (c, op) => {
      const k = s.n++;
      s.z[k] = c.z;
      s.nx[k] = c.z > 1e-4 ? c.x / c.z / view.tanX : 9;
      s.ny[k] = c.z > 1e-4 ? c.y / c.z / view.tanY : 9;
      s.op[k] = op;
      if (c.z > 1e-3) dists.push(c.length());
    };
    const packed = mesh.packedSplats?.packedArray;
    if (packed) for (let i = 0; i < count && s.n < n; i += step) {
      const p = unpackSplat(packed, i);
      add(p.center, p.opacity);
    } else mesh.forEachSplat((i, c, _s, _q, op) => i % step === 0 && s.n < n && add(c, op));
    dists.sort((a, b) => a - b);
    const at = (q) => Math.max(1e-3, dists[Math.floor(dists.length * q)] || 1);
    return { samples: s, logNear: Math.log(at(0.03)), logFar: Math.log(at(0.97)), median: at(0.5) };
  }

  /** Load a splat for the current photo. source: { url } or { fileBytes, fileName }. */
  async function loadSplat(source, token) {
    const mesh = new SplatMesh({ ...source });
    mesh.quaternion.copy(FILE_TO_WORLD);
    mesh.visible = false;
    scene.add(mesh);
    try {
      await mesh.initialized;
    } catch (err) {
      scene.remove(mesh);
      throw err;
    }
    if (token !== view.token) {
      scene.remove(mesh);
      mesh.dispose?.();
      return false;
    }
    disposeMesh();
    const u = makeFocusUniforms(planeMat.uniforms.mask.value);
    u.tanX.value = view.tanX;
    u.tanY.value = view.tanY;
    u.front.value = -10;
    mesh.objectModifier = makeFocusModifier(u);
    mesh.updateGenerator();
    view.mesh = mesh;
    view.u = u;
    view.count = mesh.packedSplats?.numSplats ?? mesh.splats?.getNumSplats?.() ?? 0;
    const m = measure(mesh, view.count);
    view.samples = m.samples;
    u.logNear.value = m.logNear;
    u.logFar.value = Math.max(m.logNear + 0.5, m.logFar);
    view.S = m.median;
    view.near = Math.exp(m.logNear);
    camAnchor.snap(new THREE.Vector3(0, 0, -view.S));
    syncFocusUniforms();
    mesh.updateVersion();
    return true;
  }

  /** Photo dims, then depth sweeps in from the dark, near to far. */
  function reveal() {
    if (!view.mesh) return;
    view.mesh.visible = true;
    planeO.set(0);
    view.revealT = -0.25;
  }

  // ---- regions ----
  function clearRegions() {
    view.regions = [];
    view.hasMask = 0;
    planeMat.uniforms.hasMask.value = 0;
    for (const w of weights) w.snap(0);
    for (const w of rWeights) w.snap(0);
    for (const h of hl) (h.t = -1), (h.x = 0), (h.hold = 0);
    camF.snap(0);
    focusedIdx = -1;
  }

  function setRegions(list, maskTex) {
    view.regions = list;
    const old = planeMat.uniforms.mask.value;
    planeMat.uniforms.mask.value = maskTex;
    if (old !== maskTex) old?.dispose();
    view.hasMask = 1;
    planeMat.uniforms.hasMask.value = 1;
    list.forEach((r, i) => {
      if (i < 3) planeMat.uniforms[`a${i}`].value.set(r.uv[0], r.uv[1]);
    });
    if (view.u) view.u.mask.value = maskTex;
    syncFocusUniforms();
    requestRender();
  }

  /** Focus region `idx` (-1 = none) at `amount` (1 = tap, ~0.35 = hover preview); the camera
   *  eases toward it by `camAmount`. Springs keep velocity, so any call interrupts cleanly. */
  // A remove region gets its own treatment: the scene stays lit, the distraction pulses once,
  // then dissolves. Hover (amount < 1) only highlights it.
  function focus(idx, amount = 1, camAmount = amount) {
    const isRemove = (i) => view.regions[i]?.tag === 'remove';
    weights.forEach((w, i) => w.set(i === idx && !isRemove(i) ? amount : 0));
    rWeights.forEach((w, i) => {
      if (i !== idx || !isRemove(i)) return w.set(0);
      if (amount >= 1 && hl[i].t < 0 && w.target < 1) hl[i].t = REDUCED.matches ? REMOVE_DELAY : 0;
    });
    hl.forEach((h, i) => {
      h.hold = i === idx && isRemove(i) && amount < 1 ? amount : 0;
      if (i !== idx) h.t = -1;
    });
    if (idx >= 0 && isRemove(idx)) camAmount *= 0.6;
    if (idx >= 0 && camAmount > 0) {
      focusedIdx = idx;
      camF.set(camAmount);
    } else {
      focusedIdx = -1;
      camF.set(0);
    }
  }

  function syncFocusUniforms() {
    const u = view.u;
    if (!u) return;
    u.hasMask.value = view.hasMask;
    view.regions.forEach((r, i) => {
      if (i > 2) return;
      u[`anc${i}`].value.copy(r.anchor);
      u[`gate${i}`].value.copy(r.gate);
    });
  }

  /** Anchor of region i in world coords, following its lift. */
  function anchorWorld(i, out) {
    const r = view.regions[i];
    if (!r) return out.set(0, 0, -view.S);
    const k = view.mesh && view.u ? 1 - LIFT * weights[i].x : 1;
    return toWorld(tmp2.copy(r.anchor).multiplyScalar(k), out);
  }

  // ---- reframe ----
  // The suggested step in the capture frame (x right, y down, z forward; yaw right, pitch up).
  // A one-photo splat only holds up for small moves, so the flight keeps the direction and
  // the turn but scales the step to <= RF_STEP x the nearest content's distance; the note
  // carries the full instruction.
  function poseFor(move, k, zf = 1) {
    rf.pos.set(move.x_m || 0, -(move.y_m || 0), -(move.z_m || 0));
    const len = rf.pos.length();
    const cap = RF_STEP * view.near;
    if (len > cap) rf.pos.multiplyScalar(cap / len);
    rf.pos.multiplyScalar(k);
    rf.yaw = THREE.MathUtils.degToRad(move.yaw_deg || 0) * k;
    rf.pitch = THREE.MathUtils.degToRad(move.pitch_deg || 0) * k;
    rf.quat.setFromEuler(new THREE.Euler(rf.pitch, -rf.yaw, 0, 'YXZ'));
    // Zoom that keeps the turned (and sideways-stepped) view inside the photo.
    const side = Math.hypot(rf.pos.x, rf.pos.y) / (1.5 * view.near);
    // Relative to the base view, which may already show bars (a portrait photo on a laptop).
    const z = zoomFor(Math.abs(rf.yaw) + Math.atan(side), Math.abs(rf.pitch) + Math.atan(side * 0.5));
    rf.Z = 1 + (THREE.MathUtils.clamp(z / zoomFor(0, 0), 1, ZMAX) - 1) * zf;
    rf.scale = k;
  }

  // Foreground content (the people, in a selfie or a group shot) in the upper three quarters of
  // the base view must stay on screen after the move. Uses at most half the edge-hiding zoom,
  // then none, then shrinks the move, until >= 92% does.
  const qInv = new THREE.Quaternion();
  const pv = new THREE.Vector3();
  function keptFraction(pts, frame) {
    const tv = view.V / Math.max(1, rf.Z);
    const tx = camera.aspect * tv;
    qInv.copy(rf.quat).invert();
    let inside = 0;
    for (const p of pts) {
      pv.copy(p).sub(rf.pos).applyQuaternion(qInv);
      if (pv.z > -1e-3) continue;
      const x = pv.x / -pv.z / tx;
      const y = pv.y / -pv.z / tv;
      if (x >= frame.x0 && x <= frame.x1 && y >= frame.y0 && y <= frame.y1) inside++;
    }
    return inside / Math.max(1, pts.length);
  }
  function foreground(frame) {
    const sm = view.samples;
    if (!sm || !sm.n) return [];
    const zs = [];
    for (let k = 0; k < sm.n; k += 7) if (sm.z[k] > 0 && sm.op[k] > 0.3) zs.push(sm.z[k]);
    zs.sort((a, b) => a - b);
    const zMax = 2.4 * (zs[Math.floor(zs.length * 0.1)] || view.near);
    const tv = view.V;
    const tx = camera.aspect * tv;
    const pts = [];
    const stride = Math.max(1, Math.floor(sm.n / 30000));
    for (let k = 0; k < sm.n; k += stride) {
      const z = sm.z[k];
      if (!(z > 0) || z > zMax || sm.op[k] < 0.3) continue;
      const x = (sm.nx[k] * view.tanX) / tx; // base view: eye at the origin, looking down -z
      const y = (-sm.ny[k] * view.tanY) / tv;
      // Heads and shoulders matter; the bottom quarter (bodies already cut by the frame) less so.
      if (x < frame.x0 || x > frame.x1 || y < -0.5 || y > frame.y1) continue;
      pts.push(new THREE.Vector3(sm.nx[k] * view.tanX * z, -sm.ny[k] * view.tanY * z, -z));
    }
    return pts;
  }
  /** Prepare the flight for `move`, keeping the people on screen. Returns the move's scale. */
  function setReframe(move, frame = { x0: -0.97, x1: 0.97, y0: -0.97, y1: 0.97 }) {
    if (!move) return 1;
    const pts = foreground(frame);
    let best = null;
    search: for (let k = 1; k > 0.29; k -= 0.15) {
      for (const zf of [0.5, 0]) {
        poseFor(move, k, zf);
        const kept = pts.length < 50 ? 1 : keptFraction(pts, frame);
        if (!best || kept > best.kept + 0.01) best = { k, zf, kept };
        if (kept >= 0.92) {
          best = { k, zf, kept };
          break search;
        }
      }
    }
    poseFor(move, best.k, best.zf);
    rf.info = { n: pts.length, kept: +best.kept.toFixed(3), scale: +rf.scale.toFixed(2), zf: best.zf, Z: +rf.Z.toFixed(3), S: +view.S.toFixed(2), near: +view.near.toFixed(2) };
    fl.apex = Math.min(RF_APEX * view.S, 0.6 * rf.pos.length() + 0.01);
    return rf.scale;
  }
  function reframeTo(k, { instant = false } = {}) {
    if (instant || REDUCED.matches) {
      fl.x = fl.from = fl.to = k;
      fl.t = fl.dur = 0;
      fl.lift = fl.lift0 = 0;
      requestRender();
      return;
    }
    if (k === fl.to && fl.t < fl.dur) return;
    fl.from = fl.x;
    fl.to = k;
    fl.t = 0;
    fl.lift0 = fl.lift;
    fl.dur = k === fl.x ? 0 : k > fl.x ? RF_OUT : RF_BACK;
    requestRender();
  }
  function stepFlight(dt) {
    if (fl.t >= fl.dur) return false;
    fl.t = Math.min(fl.dur, fl.t + dt);
    const p = fl.t / fl.dur;
    const e = easeInOut(p);
    fl.x = fl.from + (fl.to - fl.from) * e;
    fl.lift = fl.lift0 * (1 - e) + fl.apex * Math.sin(Math.PI * p);
    return true;
  }
  // Dragging during the flight cancels it and keeps the current pose (no snap).
  function cancelFlight() {
    if (fl.t >= fl.dur) return;
    fl.to = fl.x;
    fl.dur = fl.t = 0;
    for (const fn of flightCancelHandlers) fn(fl.x);
  }

  // ---- camera rig ----
  const A = new THREE.Vector3();
  const eye = new THREE.Vector3();
  const qLook = new THREE.Quaternion();
  const eLook = new THREE.Euler(0, 0, 0, 'YXZ');
  const qRf = new THREE.Quaternion();

  // How far the camera may turn (yaw, pitch) at zoom Z before the photo's edge shows.
  const slack = (Z) => ({
    yaw: Math.atan(view.tanX) - Math.atan((camera.aspect * view.V) / Z),
    pitch: Math.atan(view.tanY) - Math.atan(view.V / Z),
  });

  // Zoom (1..ZMAX) at which a view turned by (yaw, pitch) still sits inside the photo.
  function zoomFor(yaw, pitch) {
    const needX = (camera.aspect * view.V) / Math.tan(Math.max(0.05, Math.atan(view.tanX) - Math.abs(yaw)));
    const needY = view.V / Math.tan(Math.max(0.05, Math.atan(view.tanY) - Math.abs(pitch)));
    return THREE.MathUtils.clamp(Math.max(needX, needY), 1, ZMAX);
  }

  // Face a subject at angles (ay, ap): turn LOOK of the way, zooming in just enough (<= ZMAX)
  // that the turned view stays inside the photo.
  function framing(ay, ap) {
    let yaw = LOOK * ay;
    let pitch = LOOK * ap;
    const Z = Math.max(1 + ZOOM_MIN, zoomFor(yaw, pitch));
    const sl = slack(Z);
    yaw = THREE.MathUtils.clamp(yaw, -Math.max(0, sl.yaw), Math.max(0, sl.yaw));
    pitch = THREE.MathUtils.clamp(pitch, -Math.max(0, sl.pitch), Math.max(0, sl.pitch));
    return { Z, yaw, pitch };
  }

  function updateCamera(dt) {
    let moving = false;
    if (focusedIdx >= 0) {
      anchorWorld(focusedIdx, A);
      camAnchor.set(A);
    }
    moving = camF.step(dt) || moving;
    moving = camAnchor.step(dt) || moving;
    moving = dolly.step(dt) || moving;
    moving = stepFlight(dt) || moving;
    const px = approach(par.x, pointer.x, 3.2, dt);
    const py = approach(par.y, pointer.y, 3.2, dt);
    if (px !== par.x || py !== par.y) moving = true;
    par.set(px, py);
    const ny = approach(look.yaw, look.tyaw, 10, dt);
    const np = approach(look.pitch, look.tpitch, 10, dt);
    if (ny !== look.yaw || np !== look.pitch) moving = true;
    look.yaw = ny;
    look.pitch = np;

    const F = Math.max(0, camF.x);
    camAnchor.read(A);
    const dA = Math.max(A.length(), 1e-3);
    // Far subjects (sky, a distant hill) count as only a little farther than the scene's
    // middle, and the push never gets near the closest content: the camera stays a viewer.
    const reach = Math.min(dA, 1.6 * view.S);
    const depth = THREE.MathUtils.lerp(view.S, reach, Math.min(1, F));
    const push = Math.min(PUSH * reach, 0.3 * view.near) * F;
    const fr = framing(Math.atan2(A.x, -A.z), Math.atan2(A.y, -A.z));
    // Parallax: a small sideways step, sized to the near content, turning back toward the
    // pivot (the scene's middle, or the subject when focused) so the pivot holds still.
    const amp = 0.05 * Math.sqrt(view.near * view.S);
    const ox = par.x * amp;
    const oy = par.y * amp * 0.66;
    eye.copy(A).multiplyScalar(push / dA);
    eye.x += ox;
    eye.y += oy;
    eye.z -= dolly.x;
    const yaw = fr.yaw * F + look.yaw - Math.atan(ox / depth);
    const pitch = fr.pitch * F + look.pitch - Math.atan(oy / depth);
    eLook.set(pitch, -yaw, 0);
    qLook.setFromEuler(eLook);
    const zoom = Math.max(1 + (fr.Z - 1) * F, 1 + (rf.Z - 1) * fl.x);
    const fov = THREE.MathUtils.radToDeg(2 * Math.atan(view.V / zoom));
    if (Math.abs(fov - camera.fov) > 1e-4) {
      camera.fov = fov;
      camera.updateProjectionMatrix();
      moving = true;
    }
    // Reframe: the whole rig moves by the suggested step, in the capture frame.
    const k = fl.x;
    if (k !== 0 || fl.lift !== 0) {
      qRf.slerpQuaternions(qId, rf.quat, k);
      camera.position.copy(eye).applyQuaternion(qRf).addScaledVector(rf.pos, k);
      camera.position.y += fl.lift;
      camera.quaternion.copy(qRf).multiply(qLook);
    } else {
      camera.position.copy(eye);
      camera.quaternion.copy(qLook);
    }
    return moving;
  }

  // ---- input: parallax, drag look, dolly, gyro ----
  let lastPointerAt = 0;
  window.addEventListener('pointermove', (e) => {
    if (e.pointerType !== 'mouse') return;
    lastPointerAt = performance.now();
    pointer.set((e.clientX / innerWidth) * 2 - 1, -((e.clientY / innerHeight) * 2 - 1));
  });
  document.addEventListener('pointerleave', () => pointer.set(0, 0));

  const touches = new Map();
  let drag = null;
  let pinch = null;
  const onTapHandlers = [];
  canvas.addEventListener('pointerdown', (e) => {
    canvas.setPointerCapture?.(e.pointerId);
    touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
    askGyro();
    if (touches.size === 2) {
      const [a, b] = [...touches.values()];
      pinch = { d: Math.hypot(a.x - b.x, a.y - b.y), dolly: dolly.target };
      drag = null;
    } else if (touches.size === 1) {
      drag = { x: e.clientX, y: e.clientY, lx: e.clientX, ly: e.clientY, t: performance.now(), moved: false, yaw0: look.tyaw, pitch0: look.tpitch };
    }
  });
  canvas.addEventListener('pointermove', (e) => {
    if (!touches.has(e.pointerId)) return;
    touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pinch && touches.size === 2) {
      const [a, b] = [...touches.values()];
      const d = Math.hypot(a.x - b.x, a.y - b.y);
      setDolly(pinch.dolly + (d / Math.max(pinch.d, 1) - 1) * 0.35 * view.S);
      return;
    }
    if (!drag) return;
    if (!drag.moved && Math.hypot(e.clientX - drag.x, e.clientY - drag.y) > 6) {
      drag.moved = true;
      cancelFlight();
    }
    if (!drag.moved) return;
    const k = (camera.fov * Math.PI) / 180 / innerHeight; // radians per pixel
    look.tyaw = THREE.MathUtils.clamp(look.tyaw - (e.clientX - drag.lx) * k * 0.6, -look.maxYaw, look.maxYaw);
    look.tpitch = THREE.MathUtils.clamp(look.tpitch + (e.clientY - drag.ly) * k * 0.6, -look.maxPitch, look.maxPitch);
    drag.lx = e.clientX;
    drag.ly = e.clientY;
    canvas.classList.add('dragging');
  });
  const endPointer = (e) => {
    touches.delete(e.pointerId);
    canvas.classList.remove('dragging');
    if (touches.size < 2) pinch = null;
    if (drag && !drag.moved && performance.now() - drag.t < 450 && e.type === 'pointerup') {
      for (const fn of onTapHandlers) fn(e);
    }
    // A quick horizontal flick is a swipe (next/previous step), not a look: undo its turn.
    if (drag && drag.moved && e.type === 'pointerup') {
      const dx = e.clientX - drag.x;
      const dy = e.clientY - drag.y;
      if (performance.now() - drag.t < 340 && Math.abs(dx) > 48 && Math.abs(dx) > 1.4 * Math.abs(dy)) {
        look.tyaw = drag.yaw0;
        look.tpitch = drag.pitch0;
        for (const fn of swipeHandlers) fn(dx < 0 ? 1 : -1);
      }
    }
    drag = null;
  };
  canvas.addEventListener('pointerup', endPointer);
  canvas.addEventListener('pointercancel', endPointer);
  canvas.addEventListener(
    'wheel',
    (e) => {
      e.preventDefault();
      const d = e.deltaY * (e.deltaMode === 1 ? 16 : 1);
      setDolly(dolly.target - d * 0.0012 * view.S);
    },
    { passive: false },
  );
  function setDolly(v) {
    dolly.set(THREE.MathUtils.clamp(v, -0.12 * view.S, 0.22 * view.S));
  }

  let gyroAsked = false;
  let gyro0 = null;
  function askGyro() {
    if (gyroAsked) return;
    gyroAsked = true;
    const DOE = window.DeviceOrientationEvent;
    if (DOE && typeof DOE.requestPermission === 'function') DOE.requestPermission().catch(() => {});
  }
  window.addEventListener('deviceorientation', (e) => {
    if (e.beta == null || e.gamma == null) return;
    if (performance.now() - lastPointerAt < 2000) return;
    if (!gyro0) gyro0 = { b: e.beta, g: e.gamma };
    // Slowly re-centre so holding the phone at a new angle becomes neutral.
    gyro0.b += (e.beta - gyro0.b) * 0.004;
    gyro0.g += (e.gamma - gyro0.g) * 0.004;
    pointer.set(
      THREE.MathUtils.clamp((e.gamma - gyro0.g) / 14, -1, 1),
      THREE.MathUtils.clamp((e.beta - gyro0.b) / 14, -1, 1),
    );
  });

  window.addEventListener('resize', () => {
    camera.aspect = innerWidth / innerHeight;
    renderer.setPixelRatio(dpr());
    renderer.setSize(innerWidth, innerHeight, false);
    fitFov();
    requestRender();
  });

  // ---- frame loop ----
  const timer = new THREE.Timer();
  const lastCam = new THREE.Matrix4();
  let lastSig = '';
  const stats = { renders: 0, frames: [], regen: 0, why: {} };
  const why = (k) => (stats.why[k] = (stats.why[k] || 0) + 1);

  function cameraMoved() {
    const a = camera.matrixWorld.elements;
    const b = lastCam.elements;
    let moved = false;
    for (let i = 0; i < 16 && !moved; i++) moved = Math.abs(a[i] - b[i]) > 1e-7;
    if (moved) lastCam.copy(camera.matrixWorld);
    return moved;
  }

  renderer.setAnimationLoop((now) => {
    timer.update(now);
    const dt = Math.min(timer.getDelta(), 1 / 20);
    let dirty = false;

    for (const w of weights) if (w.step(dt)) (dirty = true), why('w');
    for (let i = 0; i < 3; i++) {
      const h = hl[i];
      if (h.t >= 0) {
        h.t += dt;
        if (h.t >= REMOVE_DELAY && rWeights[i].target < 1) rWeights[i].set(1);
        // pulse: up in 0.25 s, then eases away by 0.95 s
        const t = h.t;
        h.x = REDUCED.matches ? 0 : t < 0.25 ? Math.sin((t / 0.25) * Math.PI * 0.5) : Math.max(0, 1 - (t - 0.25) / 0.7) ** 2;
        if (t > 0.95) (h.t = -1), (h.x = 0);
        dirty = true;
      } else {
        const nx = approach(h.x, h.hold, 10, dt);
        if (nx !== h.x) (h.x = nx), (dirty = true);
      }
      if (rWeights[i].step(dt)) dirty = true;
    }
    if (updateCamera(dt)) (dirty = true), why('cam');
    if (planeO.step(dt)) (dirty = true), why('plane');
    planeMat.uniforms.opacity.value = planeO.x;
    plane.visible = planeO.x > 0.002;
    planeMat.uniforms.w.value.set(weights[0].x, weights[1].x, weights[2].x);

    const u = view.u;
    if (u && view.mesh) {
      if (view.revealT > -1 && view.revealT < REVEAL_S) {
        view.revealT += dt;
        const t = Math.max(0, view.revealT);
        u.front.value = view.revealT >= REVEAL_S ? 10 : -0.1 + (t / REVEAL_S) * (1.1 + 4 * u.band.value);
        dirty = true;
      }
      u.w.value.set(weights[0].x, weights[1].x, weights[2].x);
      u.rw.value.set(rWeights[0].x, rWeights[1].x, rWeights[2].x);
      u.rh.value.set(hl[0].x, hl[1].x, hl[2].x);
      const sig = `${u.front.value}|${u.w.value.x}|${u.w.value.y}|${u.w.value.z}|${u.rw.value.x}|${u.rw.value.y}|${u.rw.value.z}|${u.rh.value.x}|${u.rh.value.y}|${u.rh.value.z}|${u.hasMask.value}|${u.fade.value}`;
      if (sig !== lastSig) {
        lastSig = sig;
        view.mesh.updateVersion();
        stats.regen++;
        dirty = true;
      }
    }

    camera.updateMatrixWorld();
    if (cameraMoved()) (dirty = true), why('moved');
    if (renderRequested) why('spark');
    if (dirty || renderRequested) {
      renderRequested = false;
      renderer.render(scene, camera);
      stats.renders++;
      stats.frames.push(now);
      if (stats.frames.length > 240) stats.frames.shift();
      onFrame?.();
    }
  });

  /** Screen positions of the region anchors (CSS px), with visibility. */
  const proj = new THREE.Vector3();
  function projectRegions() {
    return view.regions.map((r, i) => {
      anchorWorld(i, proj);
      proj.project(camera);
      const visible = proj.z < 1; // off-crop markers get pinned to the edge by the HUD
      return { x: (proj.x * 0.5 + 0.5) * innerWidth, y: (-proj.y * 0.5 + 0.5) * innerHeight, visible };
    });
  }

  /** Screen box (CSS px) of region i's photo box, placed at its depth (follows its lift). */
  const bp = new THREE.Vector3();
  function projectBox(i) {
    const r = view.regions[i];
    if (!r?.box) return null;
    const k = view.mesh && view.u ? 1 - LIFT * weights[i].x : 1;
    const d = (r.anchor?.z || view.S) * k;
    const b = r.box;
    let l = Infinity, t = Infinity, rr = -Infinity, bb = -Infinity;
    for (const [u, v] of [[b.x, b.y], [b.x + b.w, b.y], [b.x, b.y + b.h], [b.x + b.w, b.y + b.h]]) {
      toWorld(bp.set((2 * u - 1) * view.tanX * d, (2 * v - 1) * view.tanY * d, d), bp);
      bp.project(camera);
      const x = (bp.x * 0.5 + 0.5) * innerWidth;
      const y = (-bp.y * 0.5 + 0.5) * innerHeight;
      l = Math.min(l, x); rr = Math.max(rr, x); t = Math.min(t, y); bb = Math.max(bb, y);
    }
    return { l, t, r: rr, b: bb };
  }

  return {
    renderer,
    camera,
    view,
    stats,
    requestRender,
    showPhoto,
    setIntrinsics,
    loadSplat,
    reveal,
    get revealed() {
      return view.revealT >= REVEAL_S;
    },
    setRegions,
    clearRegions,
    focus,
    setReframe,
    reframeTo,
    get reframeK() {
      return fl.to;
    },
    get rfInfo() {
      return rf.info;
    },
    get reframeX() {
      return fl.x;
    },
    get flying() {
      return fl.t < fl.dur;
    },
    projectBox,
    onFlightCancel: (fn) => flightCancelHandlers.push(fn),
    onSwipe: (fn) => swipeHandlers.push(fn),
    projectRegions,
    onTap: (fn) => onTapHandlers.push(fn),
    planeD: PLANE_D,
  };
}
