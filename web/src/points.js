// The photo as a grid of points. Flat it reads as the photo; a click sweeps a front
// through depth (near -> far) and each point leaves the print along its camera ray.
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

const FOV = 30;          // degrees, vertical
const FILL = 0.92;       // fraction of the viewport the photo fills (contain fit)
const OVERFILL = 1.35;   // points overlap a little so tilted views stay dense
const GRID_LONG = 512;   // long side of the depth/point grid
const BAND = 0.14;       // width of the reveal front, in normalized log depth
const SWEEP = 1.8;       // seconds for the front to go near -> far
const FAR_EXT = 1.25;    // sky and anything past p98 park a little behind p98
const FOCUS_MS = 0.35;   // ease for the region focus in/out and crossfades
export const DEFAULT_GAMMA = 0.25;

export const TAG_RGB = { remove: [1.0, 0.42, 0.33], focus: [0.95, 0.73, 0.34] };

const vertexShader = /* glsl */ `
  attribute float aDepth;          // log(d / p02) / log(far / p02): 0 = p02 (the print) ... 1 = far end
  uniform vec3 uEye;               // the start-view camera: rays fan out from here
  uniform float uFront, uBand, uFade, uLift, uGamma, uLogSpan, uCell, uProj;
  varying vec2 vUv;
  varying float vVis, vPx, vGlow;

  void main() {
    // e: 0 until the front (sweeping in log depth) reaches this point, 1 once a band past it.
    float e = clamp((uFront - aDepth) / uBand, 0.0, 1.0);
    float move = e * e * e * (e * (e * 6.0 - 15.0) + 10.0);
    // Distance along the ray in units of the print distance D0: (d / p02)^g. k = 1 is the print.
    float k = exp(uGamma * uLogSpan * aDepth * move * uLift);
    vec3 p = uEye + (position - uEye) * k;
    vec4 mv = modelViewMatrix * vec4(p, 1.0);
    gl_Position = projectionMatrix * mv;
    // World size scales with k too, so from the start view every point keeps its
    // footprint: flat or deep, the photo stays registered and gap-free.
    vPx = max(uCell * k * uProj / -mv.z, 1.0);
    gl_PointSize = vPx;
    vUv = uv;
    vVis = mix(1.0 - uFade, 1.0, smoothstep(0.0, 1.0, e));
    vGlow = uFade * e * (1.0 - e) * 4.0;
  }
`;

const fragmentShader = /* glsl */ `
  uniform sampler2D uMap;
  uniform vec2 uCellUv;            // uv span of one point sprite
  uniform float uExposure;
  // Active focus: two slots so one object can crossfade into the next (uSwap 0 -> slot 0, 1 -> slot 1).
  // Each slot is a mask (r = mask, g = blurred mask for the rim) or, without one, a box.
  uniform float uDim, uSwap, uHover;
  uniform sampler2D uMask0, uMask1, uMaskH;
  uniform vec4 uBox0, uBox1, uBoxH;  // (x, y, w, h), uv, top-left origin
  uniform float uHas0, uHas1, uHasH; // 1 = mask, 0 = box fallback
  uniform vec3 uCol0, uCol1, uColH;
  varying vec2 vUv;
  varying float vVis, vPx, vGlow;

  const float MASK_LEVEL = 0.065;  // brightness outside a mask: the rest goes dark
  const float BOX_LEVEL = 0.2;     // brightness outside a box (fallback)
  const float HOVER_LEVEL = 0.55;  // hover preview

  // Signed distance to a box, in screen pixels of this sprite (negative inside).
  float boxSdf(vec4 b, vec2 uv, vec2 uvPerPx) {
    vec2 q = abs(uv - (b.xy + 0.5 * b.zw)) / uvPerPx - 0.5 * b.zw / uvPerPx;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
  }
  float edgeLine(float d, float w) { return 1.0 - smoothstep(0.5 * w - 0.6, 0.5 * w + 0.6, abs(d)); }

  // x = outside (0 in the object .. 1 out), y = rim strength, z = 1 if from a mask.
  vec3 sel(sampler2D m, vec4 box, float has, vec2 uv, vec2 uvPerPx) {
    if (has > 0.5) {
      vec2 s = texture2D(m, uv).rg;
      float outside = 1.0 - smoothstep(0.3, 0.7, s.r);
      float line = 1.0 - smoothstep(0.06, 0.24, abs(s.g - 0.5));   // thin band on the edge
      float halo = smoothstep(0.0, 0.5, s.g) * outside;            // soft glow just outside
      return vec3(outside, max(line, 0.45 * halo * halo), 1.0);
    }
    float d = boxSdf(box, uv, uvPerPx);
    return vec3(smoothstep(-0.6, 0.6, d), edgeLine(d, 2.0), 0.0);
  }

  void main() {
    // Sample the photo per fragment across the sprite, not once per point: flat, the
    // overlapping sprites all agree, so the print renders at full texture detail.
    vec2 uv = vUv + (gl_PointCoord - 0.5) * uCellUv;
    vec3 col = texture2D(uMap, uv).rgb;
    vec2 uvPerPx = uCellUv / vPx;

    float shade = 1.0, grey = 0.0;
    vec4 rimA = vec4(0.0), rimB = vec4(0.0), rimH = vec4(0.0);  // rgb = colour, a = strength

    if (uDim > 0.001) {
      vec3 a = uSwap < 0.999 ? sel(uMask0, uBox0, uHas0, uv, uvPerPx) : vec3(0.0);
      vec3 b = uSwap > 0.001 ? sel(uMask1, uBox1, uHas1, uv, uvPerPx) : vec3(0.0);
      float sa = mix(1.0, mix(BOX_LEVEL, MASK_LEVEL, a.z), a.x);
      float sb = mix(1.0, mix(BOX_LEVEL, MASK_LEVEL, b.z), b.x);
      shade = mix(1.0, mix(sa, sb, uSwap), uDim);
      grey = 0.45 * uDim * mix(a.x * a.z, b.x * b.z, uSwap);
      rimA = vec4(uCol0, a.y * uDim * (1.0 - uSwap));
      rimB = vec4(uCol1, b.y * uDim * uSwap);
    }
    if (uHover > 0.001) {
      vec3 hv = sel(uMaskH, uBoxH, uHasH, uv, uvPerPx);
      // Nothing active: the rest drops to a preview level. Something active: lift the
      // hovered object out of the dark instead, so the preview reads either way.
      shade *= mix(1.0, HOVER_LEVEL, hv.x * hv.z * uHover * (1.0 - uDim));
      shade = max(shade, (1.0 - hv.x) * hv.z * uHover * uDim * 0.5);
      rimH = vec4(uColH, hv.y * uHover * mix(0.85, 0.7, hv.z));
    }

    col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))), grey);
    col = col * shade * vVis * uExposure + vec3(1.0, 0.5, 0.36) * vGlow * 0.14;
    col = mix(col, rimH.rgb, rimH.a * vVis);
    col = mix(col, rimA.rgb, rimA.a * vVis);
    col = mix(col, rimB.rgb, rimB.a * vVis);
    gl_FragColor = vec4(col, 1.0);
  }
`;

// Metric log depth along the ray: 0 at p02 (the print), 1 at p98 * FAR_EXT (the far end).
// Sky (Depth Pro returns ~1e7 m there) and invalid values clamp to the far end. The
// reveal front sweeps in this space and distance is D0 * exp(g * span * s) = D0 * (d / p02)^g,
// so a deep scene (p98/p02 ~ 500) opens to ~5x D0 and a shallow one (~3) to ~1.4x.
export function logDepth(src, p02, p98, out) {
  const near = Math.max(p02, 1e-3);
  const far = Math.max(p98, near * 1.01) * FAR_EXT;
  const span = Math.log(far / near);
  for (let i = 0; i < out.length; i++) {
    const d = src[i];
    if (!(d > 0) || !Number.isFinite(d)) { out[i] = 1; continue; }
    const s = Math.log(d / near) / span;
    out[i] = s > 0 ? (s < 1 ? s : 1) : 0;
  }
  return span;
}

export function gridFor(w, h) {
  const long = Math.min(GRID_LONG, Math.max(w, h));
  return w >= h ? [long, Math.max(1, Math.round((long * h) / w))] : [Math.max(1, Math.round((long * w) / h)), long];
}

const easeInOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
const easeOut = (t) => 1 - Math.pow(1 - t, 3);
const linear = (t) => t;
const clamp = (x, a, b) => Math.max(a, Math.min(b, x));

/** A decoded mask -> RG texture (r = mask, g = blurred). uv (0,0) = top-left, like the photo. */
function maskTexture(m) {
  const tex = new THREE.DataTexture(m.data, m.width, m.height, THREE.RGFormat, THREE.UnsignedByteType);
  tex.flipY = false;
  tex.unpackAlignment = 1;
  tex.colorSpace = THREE.NoColorSpace;
  tex.magFilter = THREE.LinearFilter;
  tex.minFilter = THREE.LinearFilter;
  tex.generateMipmaps = false;
  tex.needsUpdate = true;
  return tex;
}

export function createViewer(container, canvas, opts = {}) {
  let gamma = Number.isFinite(opts.gamma) ? Math.max(0, opts.gamma) : DEFAULT_GAMMA;

  const renderer = new THREE.WebGLRenderer({ canvas, antialias: false, powerPreference: 'high-performance' });
  renderer.setClearColor(0x0b0a09, 1);
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(FOV, 1, 0.05, 2000);
  const controls = new OrbitControls(camera, canvas);
  Object.assign(controls, {
    enabled: false, enableDamping: true, dampingFactor: 0.08, enablePan: false,
    rotateSpeed: 0.5, zoomSpeed: 0.6,
  });

  const blank = new THREE.DataTexture(new Uint8Array([0, 0, 0, 0]), 1, 1, THREE.RGFormat);
  blank.needsUpdate = true;
  const v4 = () => new THREE.Vector4(0, 0, 0, 0);
  const v3 = () => new THREE.Vector3(1, 1, 1);
  const u = {
    uMap: { value: null }, uEye: { value: new THREE.Vector3() },
    uFront: { value: 0 }, uBand: { value: BAND }, uFade: { value: 0 }, uLift: { value: 1 },
    uGamma: { value: gamma }, uLogSpan: { value: 0 }, uCell: { value: 0.01 }, uProj: { value: 1 },
    uCellUv: { value: new THREE.Vector2() }, uExposure: { value: 1 },
    uDim: { value: 0 }, uSwap: { value: 0 }, uHover: { value: 0 },
    uMask0: { value: blank }, uMask1: { value: blank }, uMaskH: { value: blank },
    uBox0: { value: v4() }, uBox1: { value: v4() }, uBoxH: { value: v4() },
    uHas0: { value: 0 }, uHas1: { value: 0 }, uHasH: { value: 0 },
    uCol0: { value: v3() }, uCol1: { value: v3() }, uColH: { value: v3() },
  };
  const material = new THREE.ShaderMaterial({ uniforms: u, vertexShader, fragmentShader });

  let points = null;
  let grid = [0, 0];
  let aspect = 1;
  let texture = null;
  let hasDepth = false;
  let mode = 'flat'; // flat | revealing | revealed | flattening
  let gen = 0;
  let swayAmp = 1;
  let D0 = 2;
  const home = { pos: new THREE.Vector3(0, 0, 2), target: new THREE.Vector3() };
  const listeners = [];
  const masks = new Map(); // region id -> THREE.Texture
  let active = null;       // region currently focused (or fading out)
  let hovered = null;
  const slotIds = [null, null];
  let slot = 0;            // slot the focus is showing (or easing towards)

  // --- tweens (one per uniform; starting a new one replaces the old) ---
  const tweens = new Map();
  const tween = (uni, to, dur, ease = easeInOut) =>
    new Promise((resolve) => tweens.set(uni, { from: uni.value, to, dur: Math.max(dur, 1e-3), t: 0, ease, resolve }));
  const cancel = (...unis) => unis.forEach((x) => tweens.delete(x));
  function stepTweens(dt) {
    for (const [uni, tw] of tweens) {
      tw.t += dt;
      const p = Math.min(1, tw.t / tw.dur);
      uni.value = tw.from + (tw.to - tw.from) * tw.ease(p);
      if (p >= 1) { tweens.delete(uni); tw.resolve(); }
    }
  }

  // --- layout ---
  // Orbit pivots on the print (the near subject stays put). The far end swings (S - 1) / S
  // of any orbit angle across the view, S = far/near distance ratio: cap the angles so it
  // slides at most ~22% of the photo, and slow the drag so that range still takes a real drag.
  function updateOrbit() {
    const S = hasDepth ? Math.exp(gamma * u.uLogSpan.value) : 1;
    const f = Math.max((S - 1) / S, 1e-3);
    const az = clamp(Math.asin(Math.min(1, (0.22 * Math.max(aspect, 1)) / (D0 * f))), 0.14, 0.45);
    const pol = clamp(Math.asin(Math.min(1, 0.22 / (D0 * f))), 0.1, 0.26);
    Object.assign(controls, {
      minAzimuthAngle: -az, maxAzimuthAngle: az,
      minPolarAngle: Math.PI / 2 - pol, maxPolarAngle: Math.PI / 2 + pol,
      minDistance: D0 * 0.45, maxDistance: D0 * 1.3,
      rotateSpeed: Math.max(0.2, (0.5 * az) / 0.45),
    });
    swayAmp = az / 0.45;
  }
  function fit() {
    const w = Math.max(1, container.clientWidth);
    const h = Math.max(1, container.clientHeight);
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    const t = Math.tan(THREE.MathUtils.degToRad(FOV) / 2);
    D0 = Math.max(1, aspect / camera.aspect) / (2 * t * FILL);
    home.pos.set(0, 0, D0);
    home.target.set(0, 0, 0); // orbit around the print: the near subject stays put
    u.uEye.value.copy(home.pos);
    u.uProj.value = renderer.getDrawingBufferSize(new THREE.Vector2()).y / (2 * t);
    updateOrbit();
    if (mode === 'flat') goHome();
  }
  function goHome() {
    camera.position.copy(home.pos);
    controls.target.copy(home.target);
    camera.lookAt(home.target);
  }

  function buildGrid(gw, gh) {
    if (points) { scene.remove(points); points.geometry.dispose(); }
    const n = gw * gh;
    const pos = new Float32Array(n * 3);
    const uv = new Float32Array(n * 2);
    for (let j = 0, i = 0; j < gh; j++) {
      const v = (j + 0.5) / gh;
      for (let x = 0; x < gw; x++, i++) {
        const uu = (x + 0.5) / gw;
        pos[i * 3] = (uu - 0.5) * aspect;
        pos[i * 3 + 1] = 0.5 - v;
        uv[i * 2] = uu;
        uv[i * 2 + 1] = v;
      }
    }
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    geo.setAttribute('uv', new THREE.BufferAttribute(uv, 2));
    geo.setAttribute('aDepth', new THREE.BufferAttribute(new Float32Array(n), 1));
    points = new THREE.Points(geo, material);
    points.frustumCulled = false;
    scene.add(points);
    grid = [gw, gh];
    // Photo is 1 unit tall, `aspect` wide; a sprite spans one grid cell (plus overfill).
    const cell = Math.max(aspect / gw, 1 / gh) * OVERFILL;
    u.uCell.value = cell;
    u.uCellUv.value.set(cell / aspect, cell);
  }

  // --- reveal state machine ---
  function setMode(m) {
    mode = m;
    controls.enabled = m === 'revealing' || m === 'revealed';
    container.classList.toggle('can-reveal', hasDepth && (m === 'flat' || m === 'flattening'));
    container.classList.toggle('orbit', controls.enabled);
    listeners.forEach((fn) => fn({ mode, hasDepth }));
  }
  function resetFlat() {
    gen++;
    cancel(u.uFade, u.uLift, u.uFront);
    u.uFront.value = 0; u.uFade.value = 0; u.uLift.value = 1;
    goHome();
    setMode('flat');
  }
  async function reveal() {
    const g = ++gen;
    cancel(u.uFade, u.uLift, u.uFront);
    setMode('revealing');
    if (u.uFront.value <= 0) {
      // From flat: go dark, then let the front develop the scene near -> far.
      u.uLift.value = 1;
      await tween(u.uFade, 1, 0.4);
      if (g !== gen) return;
    } else {
      // Interrupted mid-flatten: lift back and finish the sweep from where it was.
      tween(u.uLift, 1, 0.5);
      tween(u.uFade, 1, 0.3);
    }
    const left = (1 + BAND - u.uFront.value) / (1 + BAND);
    await tween(u.uFront, 1 + BAND, SWEEP * left, linear);
    if (g === gen) setMode('revealed');
  }
  async function flatten() {
    const g = ++gen;
    cancel(u.uFade, u.uLift, u.uFront);
    setMode('flattening');
    await Promise.all([tween(u.uFade, 0, 0.3), tween(u.uLift, 0, 1.0)]);
    if (g !== gen) return;
    u.uFront.value = 0; u.uLift.value = 1;
    goHome();
    setMode('flat');
  }
  function toggle() {
    if (!points || !hasDepth) return;
    if (mode === 'flat' || mode === 'flattening') reveal();
    else flatten();
  }

  // Click (< 5 px of travel) toggles; anything longer is an orbit drag.
  let down = null;
  canvas.addEventListener('pointerdown', (e) => { if (e.button === 0) down = [e.clientX, e.clientY]; });
  canvas.addEventListener('pointerup', (e) => {
    if (down && Math.hypot(e.clientX - down[0], e.clientY - down[1]) < 5) toggle();
    down = null;
  });

  // Idle sway: a slow azimuth/elevation drift around wherever the user left the camera.
  let dragging = false;
  let idle = 0;
  controls.addEventListener('start', () => { dragging = true; });
  controls.addEventListener('end', () => { dragging = false; idle = 0; });
  const offset = new THREE.Vector3();
  const sph = new THREE.Spherical();
  function sway(dt) {
    if (mode !== 'revealed' || dragging) { idle = 0; return; }
    idle += dt;
    const ramp = THREE.MathUtils.smoothstep(idle, 0.4, 2.5) * swayAmp;
    const w = (2 * Math.PI) / 11;
    offset.copy(camera.position).sub(controls.target);
    sph.setFromVector3(offset);
    sph.theta += 0.09 * w * Math.cos(w * idle) * dt * ramp;
    sph.phi += 0.025 * 1.6 * w * Math.cos(1.6 * w * idle + 1.2) * dt * ramp;
    sph.makeSafe();
    offset.setFromSpherical(sph);
    camera.position.copy(controls.target).add(offset);
  }

  let last = performance.now();
  renderer.setAnimationLoop((now) => {
    const dt = Math.max(0, Math.min(0.05, (now - last) / 1000));
    last = now;
    stepTweens(dt);
    if (mode === 'flattening') {
      const b = 1 - Math.exp(-dt * 5);
      camera.position.lerp(home.pos, b);
      controls.target.lerp(home.target, b);
      camera.lookAt(controls.target);
    } else if (controls.enabled) {
      sway(dt);
      controls.update();
    }
    renderer.render(scene, camera);
  });

  new ResizeObserver(fit).observe(container);
  fit();

  // --- region focus (mask, or box until/unless a mask exists) ---
  const rgb = (tag) => TAG_RGB[tag] || TAG_RGB.focus;
  function fill(s, region) {
    const tex = masks.get(region.id);
    const b = region.box;
    u[`uMask${s}`].value = tex || blank;
    u[`uHas${s}`].value = tex ? 1 : 0;
    u[`uBox${s}`].value.set(b.x, b.y, b.w, b.h);
    u[`uCol${s}`].value.fromArray(rgb(region.tag));
  }
  function showActive(region) {
    active = region;
    if (!region) { tween(u.uDim, 0, FOCUS_MS, easeOut); return; }
    if (u.uDim.value < 0.02) {
      // From nothing: fill the visible slot and fade the dark in.
      cancel(u.uSwap);
      u.uSwap.value = slot;
      fill(slot, region);
      slotIds[slot] = region.id;
    } else {
      // Something is lit: load the other slot and crossfade the light over to it.
      slot = 1 - slot;
      fill(slot, region);
      slotIds[slot] = region.id;
      tween(u.uSwap, slot, FOCUS_MS);
    }
    tween(u.uDim, 1, FOCUS_MS);
  }
  function showHover(region) {
    hovered = region;
    if (!region) { tween(u.uHover, 0, 0.18, easeOut); return; }
    const tex = masks.get(region.id);
    const b = region.box;
    u.uMaskH.value = tex || blank;
    u.uHasH.value = tex ? 1 : 0;
    u.uBoxH.value.set(b.x, b.y, b.w, b.h);
    u.uColH.value.fromArray(rgb(region.tag));
    tween(u.uHover, 1, 0.2);
  }
  function clearMasks() {
    for (const t of masks.values()) t.dispose();
    masks.clear();
    for (const s of [0, 1, 'H']) { u[`uMask${s}`].value = blank; u[`uHas${s}`].value = 0; }
    slotIds[0] = slotIds[1] = null;
  }

  return {
    /** Show a decoded photo flat, on the grid its depth map will have. */
    setPhoto(bitmap, w, h) {
      aspect = w / h;
      const [gw, gh] = gridFor(w, h);
      buildGrid(gw, gh);
      const tex = new THREE.Texture(bitmap);
      tex.flipY = false; // uv (0,0) = top-left, same as depth rows, boxes and masks
      tex.colorSpace = THREE.NoColorSpace; // pass the JPEG's bytes straight through
      tex.minFilter = THREE.LinearMipmapLinearFilter;
      tex.needsUpdate = true;
      if (texture) { texture.image?.close?.(); texture.dispose(); }
      texture = tex;
      u.uMap.value = tex;
      hasDepth = false;
      u.uLogSpan.value = 0;
      cancel(u.uDim, u.uHover, u.uSwap);
      u.uDim.value = 0; u.uHover.value = 0;
      active = hovered = null;
      clearMasks();
      fit();
      resetFlat();
      u.uExposure.value = 0;
      tween(u.uExposure, 1, 0.35);
    },
    /** depth: { data: Float32Array (metres), width, height, p02, p98 } */
    setDepth(depth) {
      if (depth.width !== grid[0] || depth.height !== grid[1]) buildGrid(depth.width, depth.height);
      const attr = points.geometry.getAttribute('aDepth');
      u.uLogSpan.value = logDepth(depth.data, depth.p02, depth.p98, attr.array);
      attr.needsUpdate = true;
      hasDepth = true;
      updateOrbit();
      setMode(mode);
    },
    /** Relief exponent g: distance = D0 * (d / p02)^g. 0 = flat. */
    setGamma(g) {
      gamma = Math.max(0, Number(g) || 0);
      u.uGamma.value = gamma;
      updateOrbit();
    },
    /** far/near distance ratio the current photo opens to at the current g. */
    depthInfo() {
      const span = u.uLogSpan.value;
      return { gamma, hasDepth, spread: Math.exp(gamma * span), p98Spread: Math.exp(gamma * (span - Math.log(FAR_EXT))) };
    },
    /** masks: Map(region id -> { data: Uint8Array (RG), width, height }) */
    setMasks(map) {
      clearMasks();
      for (const [id, m] of map) masks.set(id, maskTexture(m));
      // Upgrade whatever is showing from its box to the traced object.
      if (active && u.uDim.value > 0.02 && masks.has(active.id)) showActive(active);
      else if (active) fill(slot, active);
      if (hovered) showHover(hovered);
    },
    hasMask: (id) => masks.has(id),
    setHover: showHover,
    setActive: showActive,
    toggle,
    onChange(fn) { listeners.push(fn); },
  };
}
