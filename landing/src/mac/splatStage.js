import * as THREE from 'three';
import { SparkRenderer, SplatMesh, dyno, unpackSplat } from '@sparkjsdev/spark';

// The Mac screen's 3D stage: one SHARP splat (capture camera at the origin, file coords x right,
// y down, z forward) floating in a dark void. One dyno program carries the desk's effects:
//   people: splats nearer than the median depth brighten, the rest dims a touch
//   warmth: a gentle warm grade over everything
//   depth:  splats behind the median dim, desaturate and soften (wider, fainter gaussians)
// plus a soft superellipse edge so the photo has no hard frame, and a fade in after loading.

const FILE_TO_WORLD = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(1, 0, 0), Math.PI);
const DEG = Math.PI / 180;
const VOID = 0x06070b;

function makeUniforms() {
  return {
    tanX: dyno.dynoFloat(0.5),
    tanY: dyno.dynoFloat(0.66),
    logNear: dyno.dynoFloat(0),
    logFar: dyno.dynoFloat(2),
    logMid: dyno.dynoFloat(1),
    people: dyno.dynoFloat(0),
    warmth: dyno.dynoFloat(0),
    depth: dyno.dynoFloat(0),
    fade: dyno.dynoFloat(0),
  };
}

function makeModifier(u) {
  const inTypes = { gsplat: dyno.Gsplat };
  for (const [k, v] of Object.entries(u)) inTypes[k] = v.type;
  return dyno.dynoBlock({ gsplat: dyno.Gsplat }, { gsplat: dyno.Gsplat }, ({ gsplat }) => {
    const program = new dyno.Dyno({
      inTypes,
      outTypes: { gsplat: dyno.Gsplat },
      statements: ({ inputs: i, outputs: o }) =>
        dyno.unindentLines(/* glsl */ `
        ${o.gsplat} = ${i.gsplat};
        vec3 c = ${i.gsplat}.center;
        vec3 sc = ${i.gsplat}.scales;
        vec4 col = ${i.gsplat}.rgba;
        float dist = max(length(c), 1e-4);
        float span = max(${i.logFar} - ${i.logNear}, 1e-3);
        float lf = clamp((log(dist) - ${i.logNear}) / span, 0.0, 1.0);
        float lm = clamp((${i.logMid} - ${i.logNear}) / span, 0.0, 1.0);
        float nearK = 1.0 - smoothstep(lm - 0.07, lm + 0.05, lf);
        float farK = smoothstep(lm - 0.02, min(lm + 0.32, 1.0), lf);
        vec3 rgb = col.rgb;

        // People: the near subject lifts, everything behind it settles a little.
        float P = ${i.people};
        rgb *= 1.0 + P * (0.36 * nearK - 0.26 * (1.0 - nearK));
        rgb += P * nearK * vec3(0.016, 0.02, 0.028);

        // Warmth: a soft warm grade.
        rgb *= mix(vec3(1.0), vec3(1.1, 1.0, 0.84), ${i.warmth});

        // Depth: the far field dims, desaturates and softens.
        float D = ${i.depth} * farK;
        float lum = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
        rgb = mix(rgb, vec3(lum), 0.4 * D) * (1.0 - 0.6 * D);
        sc *= 1.0 + 0.7 * D;
        float a = col.a * (1.0 - 0.3 * D);

        // No hard frame: splats dissolve into the void towards the photo's edge.
        if (c.z > 1e-3) {
          vec2 q = abs(c.xy / c.z / vec2(${i.tanX}, ${i.tanY}));
          float r = pow(pow(q.x, 4.0) + pow(q.y, 4.0), 0.25);
          float e = smoothstep(0.7, 1.0, r);
          a *= 1.0 - e;
          sc *= 1.0 - 0.35 * e;
        }

        ${o.gsplat}.scales = sc;
        ${o.gsplat}.rgba = vec4(max(rgb, vec3(0.0)), a * ${i.fade});
      `),
    });
    return { gsplat: program.apply({ gsplat, ...u }).gsplat };
  });
}

const quantile = (sorted, q) => sorted[Math.min(sorted.length - 1, Math.max(0, Math.floor(sorted.length * q)))];

/** Depth range, field of view and a subject target, from a subsample of the splats. */
function measure(mesh) {
  const count = mesh.packedSplats?.numSplats ?? 0;
  const step = Math.max(1, Math.floor(count / 80000));
  const pts = [];
  const add = (c, op) => {
    if (c.z > 1e-3 && op > 0.05) pts.push(c.x, c.y, c.z);
  };
  const packed = mesh.packedSplats?.packedArray;
  if (packed && count) {
    for (let i = 0; i < count; i += step) {
      const p = unpackSplat(packed, i);
      add(p.center, p.opacity);
    }
  } else {
    let k = 0;
    mesh.forEachSplat((_i, c, _s, _q, op) => (k++ % step === 0 ? add(c, op) : 0));
  }
  const n = pts.length / 3;
  const dist = new Float32Array(n);
  const rx = new Float32Array(n);
  const ry = new Float32Array(n);
  for (let k = 0; k < n; k++) {
    const x = pts[3 * k], y = pts[3 * k + 1], z = pts[3 * k + 2];
    dist[k] = Math.hypot(x, y, z);
    rx[k] = Math.abs(x / z);
    ry[k] = Math.abs(y / z);
  }
  const ds = Float32Array.from(dist).sort();
  const near = quantile(ds, 0.03);
  const far = quantile(ds, 0.97);
  const mid = quantile(ds, 0.5);
  const tanX = quantile(Float32Array.from(rx).sort(), 0.99);
  const tanY = quantile(Float32Array.from(ry).sort(), 0.99);

  // Subject: the splats in front of the median depth, inside the central part of the frame.
  let sx = 0, sy = 0, m = 0;
  const zs = [];
  for (let k = 0; k < n; k++) {
    const x = pts[3 * k], y = pts[3 * k + 1], z = pts[3 * k + 2];
    if (dist[k] > mid || Math.abs(x / z) > tanX * 0.75 || Math.abs(y / z) > tanY * 0.8) continue;
    sx += x / z;
    sy += y / z;
    zs.push(z);
    m++;
  }
  zs.sort((a, b) => a - b);
  return {
    count,
    near,
    far,
    mid,
    tanX,
    tanY,
    subject: { nx: m ? sx / m : 0, ny: m ? sy / m : 0, z: zs.length ? quantile(zs, 0.5) : mid },
  };
}

/**
 * host: an element the canvas fills. Returns { load, update(dt, time, fx), setReduced, destroy }.
 * fx: { people, warmth, depth } in 0..1.
 */
export function createSplatStage(host, { url, reduced = false, onReady } = {}) {
  const canvas = document.createElement('canvas');
  canvas.className = 'hm__canvas';
  host.appendChild(canvas);

  let renderer;
  try {
    renderer = new THREE.WebGLRenderer({ canvas, antialias: false, alpha: false, powerPreference: 'high-performance' });
  } catch (err) {
    console.warn('[mac] WebGL unavailable', err);
    canvas.remove();
    return { load: async () => false, update() {}, setReduced() {}, destroy() {}, info: () => null };
  }
  renderer.setClearColor(VOID, 1);

  let dirty = true;
  const scene = new THREE.Scene();
  scene.add(new SparkRenderer({ renderer, onDirty: () => (dirty = true) }));
  const camera = new THREE.PerspectiveCamera(40, 2, 0.01, 2000);

  const u = makeUniforms();
  const view = {
    mesh: null,
    m: null,
    target: new THREE.Vector3(0, 0, -3),
    offset: new THREE.Vector3(0, 0, 3), // target -> eye
    radius: 3,
    V: 0.4,
    fadeT: 0,
    sig: '',
  };

  // ---- size ----
  let w = 0, h = 0;
  function fitFov() {
    camera.fov = 2 * Math.atan(view.V) / DEG;
    camera.updateProjectionMatrix();
  }
  function frameView() {
    const m = view.m;
    if (!m) return;
    const a = camera.aspect;
    // Fill most of the stage height; on a wide stage the sides stay open void.
    // Slightly tighter than the capture so the orbit never reveals the splat's edges.
    view.V = Math.max(m.tanY * 0.86, (m.tanX * 0.9) / a);
    fitFov();
  }
  function resize() {
    const r = host.getBoundingClientRect();
    const nw = Math.max(1, Math.round(r.width));
    const nh = Math.max(1, Math.round(r.height));
    if (nw === w && nh === h) return;
    w = nw;
    h = nh;
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    frameView();
    fitFov();
    dirty = true;
  }
  const ro = new ResizeObserver(resize);
  ro.observe(host);
  resize();

  // ---- pointer orbit: hover leans a little, drag orbits further; both ease back ----
  const user = { yaw: 0, pitch: 0, tYaw: 0, tPitch: 0, hover: false, drag: null };
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  function onMove(e) {
    if (reduced) return;
    const r = host.getBoundingClientRect();
    const nx = ((e.clientX - r.left) / r.width) * 2 - 1;
    const ny = ((e.clientY - r.top) / r.height) * 2 - 1;
    if (user.drag) {
      const dx = (e.clientX - user.drag.x) / r.width;
      const dy = (e.clientY - user.drag.y) / r.height;
      user.tYaw = clamp(user.drag.yaw - dx * 40 * DEG, -16 * DEG, 16 * DEG);
      user.tPitch = clamp(user.drag.pitch - dy * 18 * DEG, -6 * DEG, 6 * DEG);
    } else if (e.pointerType === 'mouse') {
      user.tYaw = -nx * 5 * DEG;
      user.tPitch = -ny * 2.5 * DEG;
    }
  }
  function onDown(e) {
    if (reduced || (e.pointerType === 'mouse' && e.button !== 0)) return;
    user.drag = { x: e.clientX, y: e.clientY, yaw: user.tYaw, pitch: user.tPitch };
    host.classList.add('is-dragging');
    host.setPointerCapture?.(e.pointerId);
  }
  function onUp(e) {
    if (!user.drag) return;
    user.drag = null;
    host.classList.remove('is-dragging');
    host.releasePointerCapture?.(e.pointerId);
    if (!user.hover) user.tYaw = user.tPitch = 0;
  }
  function onEnter() {
    user.hover = true;
  }
  function onLeave() {
    user.hover = false;
    if (!user.drag) user.tYaw = user.tPitch = 0;
  }
  host.addEventListener('pointermove', onMove);
  host.addEventListener('pointerdown', onDown);
  host.addEventListener('pointerup', onUp);
  host.addEventListener('pointercancel', onUp);
  host.addEventListener('pointerenter', onEnter);
  host.addEventListener('pointerleave', onLeave);

  // ---- load ----
  let loading = null;
  let destroyed = false;
  function load() {
    if (loading) return loading;
    loading = (async () => {
      const mesh = new SplatMesh({ url });
      mesh.quaternion.copy(FILE_TO_WORLD);
      mesh.visible = false;
      scene.add(mesh);
      try {
        await mesh.initialized;
      } catch (err) {
        console.warn('[mac] splat failed to load', err);
        scene.remove(mesh);
        return false;
      }
      if (destroyed) {
        mesh.dispose?.();
        return false;
      }
      const m = measure(mesh);
      view.m = m;
      u.tanX.value = m.tanX;
      u.tanY.value = m.tanY;
      u.logNear.value = Math.log(m.near);
      u.logFar.value = Math.max(Math.log(m.near) + 0.4, Math.log(m.far));
      u.logMid.value = Math.log(m.mid);
      u.fade.value = reduced ? 1 : 0;
      mesh.objectModifier = makeModifier(u);
      mesh.updateGenerator();
      mesh.updateVersion();
      mesh.visible = true;
      view.mesh = mesh;

      // Look at the people (pulled most of the way back to the frame centre), orbit around them
      // from the capture eye.
      const s = m.subject;
      const tz = s.z;
      view.target.set(s.nx * 0.5 * tz, -(s.ny * 0.5 * tz), -tz);
      view.offset.copy(view.target).negate();
      view.radius = view.offset.length();
      frameView();
      dirty = true;
      onReady?.(m);
      return true;
    })();
    return loading;
  }

  // ---- per frame ----
  const euler = new THREE.Euler(0, 0, 0, 'YXZ');
  const eye = new THREE.Vector3();
  const look = new THREE.Vector3();
  const lastCam = new THREE.Matrix4();
  const smooth = (t) => t * t * t * (t * (t * 6 - 15) + 10);

  function update(dt, time, fx) {
    if (destroyed) return;
    resize();
    // Camera: a slow orbit (+-7 deg yaw, +-2 deg pitch), a gentle bob, plus the user's lean.
    const k = 1 - Math.exp(-dt * (user.drag ? 10 : 2.6));
    user.yaw += (user.tYaw - user.yaw) * k;
    user.pitch += (user.tPitch - user.pitch) * k;
    const T = Math.PI * 2;
    const auto = reduced ? 0 : 1;
    const yaw = auto * 7 * DEG * Math.sin((T * time) / 22) + user.yaw;
    const pitch = auto * 2 * DEG * Math.sin((T * time) / 8.5 + 0.6) + user.pitch;
    const bob = auto * 0.008 * view.radius * Math.sin((T * time) / 6.4);
    euler.set(pitch, yaw, 0);
    eye.copy(view.offset).applyEuler(euler).add(view.target);
    eye.y += bob;
    look.copy(view.target);
    look.y += bob * 0.5;
    camera.position.copy(eye);
    camera.lookAt(look);
    camera.updateMatrixWorld();
    const a = camera.matrixWorld.elements;
    const b = lastCam.elements;
    for (let i = 0; i < 16; i++) {
      if (Math.abs(a[i] - b[i]) > 1e-7) {
        lastCam.copy(camera.matrixWorld);
        dirty = true;
        break;
      }
    }

    if (view.mesh) {
      if (u.fade.value < 1) {
        view.fadeT = Math.min(1, view.fadeT + dt / 1.6);
        u.fade.value = reduced ? 1 : smooth(view.fadeT);
      }
      u.people.value = fx.people;
      u.warmth.value = fx.warmth;
      u.depth.value = fx.depth;
      const sig = `${u.people.value.toFixed(4)}|${u.warmth.value.toFixed(4)}|${u.depth.value.toFixed(4)}|${u.fade.value.toFixed(4)}`;
      if (sig !== view.sig) {
        view.sig = sig;
        view.mesh.updateVersion();
        dirty = true;
      }
    }

    if (dirty) {
      dirty = false;
      renderer.render(scene, camera);
    }
  }

  function destroy() {
    destroyed = true;
    ro.disconnect();
    host.removeEventListener('pointermove', onMove);
    host.removeEventListener('pointerdown', onDown);
    host.removeEventListener('pointerup', onUp);
    host.removeEventListener('pointercancel', onUp);
    host.removeEventListener('pointerenter', onEnter);
    host.removeEventListener('pointerleave', onLeave);
    if (view.mesh) {
      scene.remove(view.mesh);
      view.mesh.dispose?.();
    }
    renderer.dispose();
    renderer.forceContextLoss?.();
    canvas.remove();
  }

  return {
    load,
    update,
    setReduced(v) {
      reduced = v;
      if (v) user.tYaw = user.tPitch = 0;
      dirty = true;
    },
    destroy,
    info: () => (view.m ? { ...view.m, fov: camera.fov, aspect: camera.aspect } : null),
  };
}
