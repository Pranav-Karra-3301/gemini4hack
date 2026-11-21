import * as THREE from 'three';
import { SplatMesh, unpackSplat } from '@sparkjsdev/spark';
import { makeMemoryModifier, makeMemoryUniforms } from './memoryShader.js';

// Adapted from Wayback (src/memory.js): a memory is the 3D splat SHARP made from one photo, plus
// the camera that took it. The gallery, poster and print-flattening are gone; what stays is the
// capture camera (from the photo's frame: w, h, focal px), the depth measurement and the
// "only push uniforms when something changed" tick.
//
// World layout: the capture camera sits at the origin looking down -z (three's default camera),
// so a PerspectiveCamera at the origin with fovCover() sees exactly the photo.

export const CARD_H = 0.56; // half-height of the print rectangle the frustum marks, world units
const FLIP = new THREE.Vector3(1, -1, -1); // file coords (y down, z forward) <-> upright world

export class Memory {
  constructor(def, { scene, source, onChange, onProgress }) {
    this.def = def;
    this.scene = scene;
    this.source = source ?? { url: def.file };
    this.onChange = onChange;
    this.onProgress = onProgress;
    this.count = 0;
    this.median = 2.5;
    this.near = 1;
    this.mesh = null;
    this.loading = null;
    this.u = makeMemoryUniforms();
    this.u.maxDist.value = def.maxDist ?? 1e5;

    const fr = def.frame;
    this.tanX = fr.w / (2 * fr.f);
    this.tanY = fr.h / (2 * fr.f);
    this.D = CARD_H / this.tanY;
    this.halfW = this.D * this.tanX;

    // Capture camera, in the file's own coordinates.
    const eyeO = new THREE.Vector3(...(def.eye ?? [0, 0, 0])).multiply(FLIP);
    const tgtO = new THREE.Vector3(...(def.target ?? [0, 0, -1])).multiply(FLIP);
    const capObj = new THREE.Matrix4().lookAt(eyeO, tgtO, new THREE.Vector3(0, -1, 0)).setPosition(eyeO);
    this.u.eye.value.copy(eyeO);
    this.capObjInv = capObj.invert();
    this.capWorld = new THREE.Matrix4(); // identity: capture eye at the origin, looking down -z

    this.look = { fade: 1, people: 0, warmth: 0, background: 0, edit: 1 };
    this.lastSig = '';
  }

  // Load and prepare the splat once; later calls share the same promise.
  load() {
    if (this.loading) return this.loading;
    const mesh = new SplatMesh({ ...this.source, onProgress: this.onProgress });
    mesh.matrixAutoUpdate = false;
    this.scene.add(mesh);
    this.mesh = mesh;
    this.loading = mesh.initialized.then(() => {
      mesh.objectModifier = makeMemoryModifier(this.u);
      mesh.updateGenerator();
      this.count = mesh.packedSplats?.numSplats ?? mesh.splats?.getNumSplats?.() ?? 0;
      this.measure();
      this.updatePose();
      this.onChange?.();
      return this;
    });
    this.loading.catch(() => {
      this.scene.remove(mesh);
      this.mesh = null;
      this.loading = null;
    });
    return this.loading;
  }

  // One pass over a sample of splats: the depth range (edit weights) and overall size (camera rig).
  measure() {
    const eye = this.u.eye.value;
    const maxDist = this.u.maxDist.value;
    const dists = [];
    const add = (c) => {
      const len = c.distanceTo(eye);
      if (len < maxDist) dists.push(len);
    };
    // Read ~40k evenly spaced splats straight from the packed buffer instead of walking all of
    // them, so loading doesn't stall the main thread.
    const packed = this.mesh.packedSplats?.packedArray;
    const step = Math.max(1, Math.floor(this.count / 40000));
    if (packed) for (let i = 0; i < this.count; i += step) add(unpackSplat(packed, i).center);
    else this.mesh.forEachSplat((i, c) => i % step === 0 && add(c));
    dists.sort((a, b) => a - b);
    const at = (q) => Math.max(1e-3, dists[Math.floor(dists.length * q)] || 1);
    this.u.logNear.value = Math.log(at(0.03));
    this.u.logFar.value = Math.max(this.u.logNear.value + 0.5, Math.log(at(0.97)));
    this.median = at(0.5);
    this.near = at(0.2);
    this.u.logMid.value = Math.log(this.median);
    this.quantiles = [0.03, 0.1, 0.2, 0.35, 0.5, 0.75, 0.97].map((q) => +at(q).toFixed(2));
  }

  updatePose() {
    if (!this.mesh) return;
    // Parent is the scene root, so matrixWorld = matrix.
    this.mesh.matrix.multiplyMatrices(this.capWorld, this.capObjInv);
    this.mesh.matrixWorld.copy(this.mesh.matrix);
  }

  // Widest view from the capture eye that stays inside the photo: fills the screen ("cover").
  fovCover(aspect) {
    return THREE.MathUtils.radToDeg(2 * Math.atan(Math.min(this.tanY, this.tanX / aspect)));
  }

  // Push the look to the GPU only when something changed. Returns true if it did.
  setLook(look) {
    Object.assign(this.look, look);
    if (!this.mesh || !this.count) return false;
    const L = this.look;
    const sig = `${L.fade}|${L.people}|${L.warmth}|${L.background}|${L.edit}`;
    if (sig === this.lastSig) return false;
    this.lastSig = sig;
    const u = this.u;
    u.fade.value = L.fade;
    u.people.value = L.people;
    u.warmth.value = L.warmth;
    u.background.value = L.background;
    u.edit.value = L.edit;
    this.mesh.updateVersion();
    return true;
  }
}
