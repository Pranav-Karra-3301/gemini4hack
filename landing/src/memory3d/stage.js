import * as THREE from 'three';
import { SparkRenderer } from '@sparkjsdev/spark';
import { Memory } from './memory.js';

// The showcase's 3D "memory" view, after Wayback's operator view (src/operator.js): the SHARP
// splat floating in black, and a thin wireframe frustum marking where the photo was taken from
// and what it saw. The caller drives it: pose(pull, yaw, pitch) and look({...}), then render().
//
//   const stage = createMemoryStage(canvas, { def, onDirty, onProgress });
//   await stage.ready;

const DEG = Math.PI / 180;
// Where the pull-back ends: orbit `yaw` / `pitch` around a pivot `pivot` x median depth ahead of
// the capture eye, `back` x that distance further out, at a vertical fov of `fov` degrees.
// `sx` / `sy` slide the picture right / down (fractions of the screen) to clear the captions.
export const RIG = { pivot: 0.25, back: 2.2, yaw: 25 * DEG, pitch: 8 * DEG, fov: 50, far: 0.5, sx: 0.1, sy: 0.05 };

// Apex at the capture eye, edges out to `far`, a rectangle where the print sat (Wayback's gizmo).
function makeFrustum(scene, color) {
  const material = new THREE.LineBasicMaterial({ color, transparent: true, opacity: 0, depthTest: false, depthWrite: false });
  const gizmo = new THREE.LineSegments(new THREE.BufferGeometry(), material);
  gizmo.matrixAutoUpdate = false;
  gizmo.renderOrder = 10;
  gizmo.visible = false;
  gizmo.frustumCulled = false;
  scene.add(gizmo);
  return {
    frame(mem, farK) {
      const far = mem.median * farK;
      const corners = (d) => [
        [-mem.tanX * d, -mem.tanY * d, -d],
        [mem.tanX * d, -mem.tanY * d, -d],
        [mem.tanX * d, mem.tanY * d, -d],
        [-mem.tanX * d, mem.tanY * d, -d],
      ];
      const pts = [];
      const near = corners(mem.D);
      const end = corners(far);
      for (let i = 0; i < 4; i++) {
        pts.push([0, 0, 0], end[i]);
        pts.push(near[i], near[(i + 1) % 4]);
        pts.push(end[i], end[(i + 1) % 4]);
      }
      gizmo.geometry.setAttribute('position', new THREE.Float32BufferAttribute(pts.flat(), 3));
      gizmo.matrix.copy(mem.capWorld);
      gizmo.matrixWorld.copy(mem.capWorld);
    },
    set(opacity) {
      if (material.opacity === opacity) return false;
      material.opacity = opacity;
      gizmo.visible = opacity > 0.001;
      return true;
    },
  };
}

export function createMemoryStage(canvas, { def, onDirty, onProgress, frustumColor = 0xeef3ff }) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: false, alpha: false, powerPreference: 'high-performance' });
  renderer.setClearColor(0x000000, 1);
  let aspect = 1;
  let dirty = true;
  const markDirty = () => {
    dirty = true;
    onDirty?.();
  };
  const scene = new THREE.Scene();
  scene.add(new SparkRenderer({ renderer, onDirty: markDirty }));
  const camera = new THREE.PerspectiveCamera(45, 1, 0.01, 2000);
  const mem = new Memory(def, { scene, onChange: markDirty, onProgress });
  const frustum = makeFrustum(scene, frustumColor);
  const pivot = new THREE.Vector3();
  const rig = { ...RIG };

  const ready = mem.load().then(() => {
    frustum.frame(mem, rig.far);
    dirty = true;
    return api;
  });

  const api = {
    ready,
    memory: mem,
    rig,
    reframe() {
      frustum.frame(mem, rig.far);
      dirty = true;
    },
    resize(w, h, dpr) {
      renderer.setPixelRatio(dpr);
      renderer.setSize(w, h, false);
      aspect = w / Math.max(1, h);
      camera.aspect = aspect;
      dirty = true;
    },
    // pull 0 = at the capture eye, exactly the photo ("cover"); 1 = pulled back and orbited.
    // yaw / pitch (radians) add drift and drag on top.
    pose(pull, yaw = 0, pitch = 0) {
      const dT = mem.median * rig.pivot; // orbit around the subject, not the horizon
      pivot.set(0, 0, -dT);
      const r = dT * (1 + rig.back * pull);
      const a = rig.yaw * pull + yaw;
      const b = rig.pitch * pull + pitch;
      camera.position.set(Math.sin(a) * Math.cos(b) * r, Math.sin(b) * r, -dT + Math.cos(a) * Math.cos(b) * r);
      camera.up.set(0, 1, 0);
      camera.lookAt(pivot);
      const cover = mem.fovCover(aspect);
      // End fov: Wayback's operator 50 deg, widened on tall screens so the scene still fits across.
      const half = (rig.fov / 2) * DEG;
      const wide = THREE.MathUtils.radToDeg(2 * Math.atan(Math.max(Math.tan(half), Math.tan(half * 1.2) / aspect)));
      camera.fov = cover + (Math.min(wide, 90) - cover) * pull;
      const sx = aspect > 1 ? rig.sx * pull : 0;
      const sy = rig.sy * pull;
      if (sx || sy) camera.setViewOffset(1000 * aspect, 1000, -sx * 1000 * aspect, -sy * 1000, 1000 * aspect, 1000);
      else camera.clearViewOffset();
      camera.updateProjectionMatrix();
      dirty = true;
    },
    look(l) {
      if (mem.setLook(l)) dirty = true;
    },
    frustum(opacity) {
      if (frustum.set(opacity)) dirty = true;
    },
    render(force) {
      if (!dirty && !force) return;
      dirty = false;
      camera.updateMatrixWorld();
      renderer.render(scene, camera);
    },
    dispose() {
      mem.mesh?.dispose?.();
      renderer.dispose();
      renderer.forceContextLoss?.();
    },
  };
  return api;
}
