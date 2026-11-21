// Heliocam hero: a procedural heliotrope that assembles out of LiDAR dots, then turns toward a
// sun the visitor moves. mountHero(el) → { destroy() }.
import * as THREE from 'three';
import {
  floretGeometry,
  leafGeometry,
  stemGeometry,
  buildCluster,
  floretInstances,
  concatInstances,
  leafInstances,
  makeRng,
} from './flower.js';
import * as S from './shaders.js';

const PAL = {
  ink: '#05060B',
  indigo: '#0B1030',
  horizon: '#1B2A66',
  core: '#FFF4E0',
  warm: '#FFC37A',
  ember: '#FF8A3D',
  pShadow: '#3B2A8C',
  pBody: '#6E4BD8',
  pLit: '#9A7CF6',
  pRim: '#C9B8FF',
  eye: '#F6E7B0',
  blue: '#4C8DFF',
  blueGlow: '#7FB2FF',
  leafDark: '#1d2b1f',
  leafLit: '#34503a',
};
const C = (hex) => new THREE.Color(hex); // sRGB hex → linear working space

const clamp01 = (x) => Math.min(1, Math.max(0, x));
const smooth = (a, b, x) => {
  const t = clamp01((x - a) / (b - a));
  return t * t * (3 - 2 * t);
};
const easeOut = (t) => 1 - Math.pow(1 - clamp01(t), 3);

// Intro timeline (seconds of on-screen time)
const T_SETTLED = 12;

export function mountHero(el) {
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const touch = window.matchMedia('(hover: none), (pointer: coarse)').matches;

  const canvas = document.createElement('canvas');
  canvas.setAttribute('aria-hidden', 'true');
  Object.assign(canvas.style, {
    position: 'absolute',
    inset: '0',
    width: '100%',
    height: '100%',
    display: 'block',
    zIndex: '-1',
    background: PAL.ink,
  });
  // Keep the canvas under the page's text without requiring the text to be positioned.
  const prevIsolation = el.style.isolation;
  el.style.isolation = 'isolate';
  el.prepend(canvas);

  let renderer;
  try {
    renderer = new THREE.WebGLRenderer({
      canvas,
      antialias: false,
      alpha: false,
      depth: true,
      stencil: false,
      powerPreference: 'high-performance',
    });
  } catch (err) {
    console.error('[hero] WebGL renderer could not be created; showing a static background.', err);
    return {
      destroy() {
        canvas.remove();
        el.style.isolation = prevIsolation;
      },
    };
  }
  renderer.setClearColor(0x000000, 0);
  renderer.info.autoReset = false;

  const disposables = [];
  const track = (x) => (disposables.push(x), x);

  // ---------- shared uniforms ----------
  const U = {
    uSunDir: { value: new THREE.Vector3(0, 1, 0) },
    uSunCol: { value: new THREE.Color(0, 0, 0) },
    uSkyCol: { value: C('#454080').multiplyScalar(0.45) },
    uGroundCol: { value: C('#0b0a14').multiplyScalar(0.6) },
    uFillCol: { value: C('#8c80b4').multiplyScalar(0.2) },
    uSunView: { value: new THREE.Vector3(0, 0, -1) },
    uReveal: { value: 0 },
    uTime: { value: 0 },
    uProjVP: { value: new THREE.Matrix4() },
    uProjPos: { value: new THREE.Vector3() },
    uLidar: { value: new THREE.Vector4(-2, 0, 0, 0) },
    uGrid: { value: new THREE.Vector2(160, 100) },
    uDepthRef: { value: 7 },
    uBlue: { value: C(PAL.blue) },
    uBlueGlow: { value: C(PAL.blueGlow) },
  };
  const petalU = {
    uPShadow: { value: C(PAL.pShadow) },
    uPBody: { value: C(PAL.pBody) },
    uPLit: { value: C(PAL.pLit) },
    uPRim: { value: C(PAL.pRim) },
    uEye: { value: C(PAL.eye) },
  };
  const leafU = { uLeafDark: { value: C(PAL.leafDark) }, uLeafLit: { value: C(PAL.leafLit) } };
  const fogU = { uFogCol: { value: C(PAL.horizon).multiplyScalar(0.45) }, uFog: { value: 0.52 } };

  const sceneMat = (vert, frag, uniforms, defines = {}) =>
    track(
      new THREE.ShaderMaterial({
        vertexShader: vert,
        fragmentShader: frag,
        uniforms,
        defines,
        side: THREE.DoubleSide,
      }),
    );

  // ---------- geometry ----------
  const floretGeo = track(floretGeometry());
  const leafGeo = track(leafGeometry());

  const heroList = buildCluster(7, { floretR: 0.036, H: 0.46 });
  const heroInst = floretInstances(heroList, null, 11);

  const backA = new THREE.Matrix4().compose(
    new THREE.Vector3(3.1, -2.0, -4.2),
    new THREE.Quaternion().setFromEuler(new THREE.Euler(0.15, 0.6, -0.12)),
    new THREE.Vector3(1.15, 1.15, 1.15),
  );
  const backB = new THREE.Matrix4().compose(
    new THREE.Vector3(1.8, -4.0, -3.2),
    new THREE.Quaternion().setFromEuler(new THREE.Euler(0.25, -0.4, 0.18)),
    new THREE.Vector3(0.95, 0.95, 0.95),
  );
  const backInst = concatInstances(
    floretInstances(buildCluster(23, { floretR: 0.08, primaries: 5, fill2: false }), backA, 29),
    floretInstances(buildCluster(41, { floretR: 0.085, primaries: 5, fill2: false }), backB, 43),
  );

  function floretMesh(inst, mat) {
    const g = track(new THREE.BufferGeometry());
    g.index = floretGeo.index;
    for (const name of ['position', 'normal', 'aBud', 'aBudN', 'aRho', 'aLobe']) g.setAttribute(name, floretGeo.getAttribute(name));
    g.setAttribute('aOpen', new THREE.InstancedBufferAttribute(inst.open, 1));
    g.setAttribute('aVar', new THREE.InstancedBufferAttribute(inst.vari, 1));
    g.setAttribute('aOcc', new THREE.InstancedBufferAttribute(inst.occ, 1));
    g.setAttribute('aSeed', new THREE.InstancedBufferAttribute(inst.sd, 1));
    g.setAttribute('aDomeN', new THREE.InstancedBufferAttribute(inst.domeN, 3));
    const m = new THREE.InstancedMesh(g, mat, inst.n);
    m.instanceMatrix.array.set(inst.mats);
    m.instanceMatrix.needsUpdate = true;
    m.frustumCulled = false;
    return m;
  }
  function leafMesh(inst, mat) {
    const g = track(new THREE.BufferGeometry());
    g.index = leafGeo.index;
    for (const name of ['position', 'normal', 'uv']) g.setAttribute(name, leafGeo.getAttribute(name));
    g.setAttribute('aVar', new THREE.InstancedBufferAttribute(inst.vari, 1));
    const m = new THREE.InstancedMesh(g, mat, inst.n);
    m.instanceMatrix.array.set(inst.mats);
    m.instanceMatrix.needsUpdate = true;
    m.frustumCulled = false;
    return m;
  }

  const floretMat = sceneMat(S.FLORET_VERT, S.FLORET_FRAG, { ...U, ...petalU });
  const floretBackMat = sceneMat(S.FLORET_VERT, S.FLORET_FRAG, { ...U, ...petalU, ...fogU }, { BACK: 1 });
  const leafMat = sceneMat(S.LEAF_VERT, S.LEAF_FRAG, { ...U, ...leafU });
  const leafBackMat = sceneMat(S.LEAF_VERT, S.LEAF_FRAG, { ...U, ...leafU, ...fogU }, { BACK: 1 });
  const stemMat = sceneMat(S.LEAF_VERT, S.LEAF_FRAG, { ...U, ...leafU }, { STEM: 1 });

  const heroFlorets = floretMesh(heroInst, floretMat);
  const heroLeaves = leafMesh(leafInstances(5, 15, null, { y: -0.28, len: [0.95, 1.55] }), leafMat);
  const stems = new THREE.Mesh(track(stemGeometry(3, { H: 0.46 })), stemMat);
  stems.frustumCulled = false;
  const backFlorets = floretMesh(backInst, floretBackMat);
  const backLeafInst = (() => {
    const a = leafInstances(31, 7, backA, { y: -0.3 });
    const b = leafInstances(47, 7, backB, { y: -0.3 });
    const mats = new Float32Array(a.mats.length + b.mats.length);
    mats.set(a.mats);
    mats.set(b.mats, a.mats.length);
    const vari = new Float32Array(a.n + b.n);
    vari.set(a.vari);
    vari.set(b.vari, a.n);
    return { n: a.n + b.n, mats, vari };
  })();
  const backLeaves = leafMesh(backLeafInst, leafBackMat);

  // dome pivots at the top of the stalk so it can lean toward the sun
  const PIVOT_Y = -0.45;
  const pivot = new THREE.Group();
  pivot.position.y = PIVOT_Y;
  const dome = new THREE.Group();
  dome.position.y = -PIVOT_Y;
  dome.add(heroFlorets, stems);
  pivot.add(dome);

  // ---------- full-screen helpers ----------
  const fsGeo = track(new THREE.BufferGeometry());
  fsGeo.setAttribute('position', new THREE.Float32BufferAttribute([-1, -1, 0, 3, -1, 0, -1, 3, 0], 3));
  fsGeo.setAttribute('uv', new THREE.Float32BufferAttribute([0, 0, 2, 0, 0, 2], 2));
  const fsMat = (frag, uniforms, extra = {}) =>
    track(
      new THREE.ShaderMaterial({
        vertexShader: S.FS_VERT,
        fragmentShader: frag,
        uniforms,
        depthTest: false,
        depthWrite: false,
        ...extra,
      }),
    );
  const fullscreen = (mat, order) => {
    const m = new THREE.Mesh(fsGeo, mat);
    m.frustumCulled = false;
    m.renderOrder = order;
    return m;
  };

  // ---------- render targets ----------
  const initialDpr = Math.min(window.devicePixelRatio || 1, 1.75);
  const rt = (opts = {}) =>
    track(
      new THREE.WebGLRenderTarget(1, 1, {
        type: THREE.HalfFloatType,
        minFilter: THREE.LinearFilter,
        magFilter: THREE.LinearFilter,
        depthBuffer: false,
        generateMipmaps: false,
        ...opts,
      }),
    );
  const mainRT = rt({ depthBuffer: true, samples: initialDpr >= 1.5 ? 2 : 4 });
  const backRT = rt({ depthBuffer: true });
  const blurA = rt();
  const blurB = rt();
  const raysA = rt();
  const raysB = rt();
  const bl = [rt(), rt(), rt(), rt()]; // 1/2, 1/4, 1/8, 1/16
  const bu = [rt(), rt(), rt()]; // 1/2, 1/4, 1/8 upsample results

  // ---------- scenes ----------
  const skyMat = fsMat(S.SKY_FRAG, {
    uSunUV: { value: new THREE.Vector2(0.7, 0.8) },
    uAspect: { value: 1.6 },
    uSunI: { value: 0 },
    uDawn: { value: 0 },
    uTop: { value: C(PAL.ink) },
    uMid: { value: C(PAL.indigo) },
    uHorizon: { value: C(PAL.horizon) },
    uCore: { value: C(PAL.core) },
    uWarm: { value: C(PAL.warm) },
    uEmber: { value: C(PAL.ember) },
  });
  const backScene = new THREE.Scene();
  backScene.add(fullscreen(skyMat, -10), backFlorets, backLeaves);

  const bgMat = fsMat(S.BG_FRAG, { tBack: { value: blurB.texture } });
  const MOTES = 260;
  const moteGeo = track(new THREE.BufferGeometry());
  {
    const rand = makeRng(91);
    const seeds = new Float32Array(MOTES * 4);
    for (let i = 0; i < seeds.length; i++) seeds[i] = rand();
    moteGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(MOTES * 3), 3));
    moteGeo.setAttribute('aSeed4', new THREE.BufferAttribute(seeds, 4));
  }
  const moteMat = track(
    new THREE.ShaderMaterial({
      vertexShader: S.MOTE_VERT,
      fragmentShader: S.MOTE_FRAG,
      uniforms: {
        uBoxMin: { value: new THREE.Vector3(-2.4, -1.0, -3.2) },
        uBoxSize: { value: new THREE.Vector3(5.6, 4.2, 4.6) },
        uTime: U.uTime,
        uPx: { value: 1 },
        uSunI: { value: 0 },
        tRays: { value: raysB.texture },
        uMoteCol: { value: C(PAL.warm) },
      },
      transparent: true,
      depthWrite: false,
      blending: THREE.CustomBlending,
      blendEquation: THREE.AddEquation,
      blendSrc: THREE.OneFactor,
      blendDst: THREE.OneFactor,
      blendSrcAlpha: THREE.ZeroFactor,
      blendDstAlpha: THREE.OneFactor,
    }),
  );
  const motes = new THREE.Points(moteGeo, moteMat);
  motes.frustumCulled = false;
  motes.renderOrder = 10;

  const mainScene = new THREE.Scene();
  mainScene.add(fullscreen(bgMat, -10), pivot, heroLeaves, motes);

  // ---------- post ----------
  const blurMat = fsMat(S.BLUR_FRAG, { tSrc: { value: null }, uDir: { value: new THREE.Vector2() } });
  const raySrcMat = fsMat(S.RAYSRC_FRAG, {
    tMain: { value: mainRT.texture },
    uSunUV: skyMat.uniforms.uSunUV,
    uAspect: skyMat.uniforms.uAspect,
    uSunI: skyMat.uniforms.uSunI,
    uCore: { value: C(PAL.core) },
    uWarm: { value: C(PAL.warm) },
  });
  const raysMat = fsMat(S.RAYS_FRAG, {
    tSrc: { value: raysA.texture },
    uSunUV: skyMat.uniforms.uSunUV,
    uDensity: { value: 0.94 },
    uDecay: { value: 0.975 },
    uWeight: { value: 0.05 },
    uExposure: { value: 0.85 },
  });
  const brightMat = fsMat(S.BRIGHT_FRAG, {
    tSrc: { value: mainRT.texture },
    uThreshold: { value: 1.1 },
    uKnee: { value: 0.35 },
  });
  const downMat = fsMat(S.DOWN_FRAG, { tSrc: { value: null }, uTexel: { value: new THREE.Vector2() } });
  const upMat = fsMat(S.UP_FRAG, {
    tSrc: { value: null },
    tBase: { value: null },
    uTexel: { value: new THREE.Vector2() },
  });
  const compMat = fsMat(S.COMPOSITE_FRAG, {
    tMain: { value: mainRT.texture },
    tRays: { value: raysB.texture },
    tBloom: { value: bu[0].texture },
    uRayStr: { value: 1.0 },
    uBloomStr: { value: 0.35 },
    uExposure: { value: 1.0 },
    uTime: U.uTime,
    uMask: { value: new THREE.Vector4(0, 0.42, 0, 0) },
    uFocus: { value: new THREE.Vector2(0.64, 0.55) },
  });
  const fsScene = new THREE.Scene();
  const fsQuad = fullscreen(blurMat, 0);
  fsScene.add(fsQuad);
  const fsCam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
  const pass = (mat, target) => {
    fsQuad.material = mat;
    renderer.setRenderTarget(target);
    renderer.render(fsScene, fsCam);
  };

  // ---------- camera + state ----------
  const camera = new THREE.PerspectiveCamera(30, 1, 0.1, 60);
  const target = new THREE.Vector3(0, 0.05, 0);
  const projector = new THREE.Object3D();
  const sunUV = new THREE.Vector2(0.73, 0.8); // eased sun position (uv, y up)
  const sunTarget = new THREE.Vector2();
  const sunHome = new THREE.Vector2(0.73, 0.8);
  const _v = new THREE.Vector3();
  const _r = new THREE.Vector3();
  const _u = new THREE.Vector3();
  const _c = new THREE.Color();
  const _m = new THREE.Matrix4();
  const _w = new THREE.Vector3();
  const cEmber = C(PAL.ember);
  const cWarm = C(PAL.warm);
  const cCore = C(PAL.core);
  const spring = { x: 0, z: 0, vx: 0, vz: 0 };

  let W = 1;
  let H = 1;
  let mobile = false;
  let baseDist = 7;
  let shiftX = 0.3;
  let shiftY = 0;
  let pointer = { x: 0.5, y: 0.5, seen: false };
  let T = 0;
  let frozen = -1;
  let raf = 0;
  let last = 0;
  let visible = false;
  let destroyed = false;
  let frames = 0;

  function layout(w, h) {
    const aspect = w / h;
    mobile = w < 768;
    camera.aspect = aspect;
    const tanH = Math.tan(THREE.MathUtils.degToRad(camera.fov / 2));
    // the dome (2 units across) fills ~half the width on desktop, ~95% on mobile
    let visH = mobile ? 2.85 / aspect : Math.max(3.5, 5.2 / aspect);
    baseDist = visH / (2 * tanH);
    shiftX = mobile ? 0 : 0.38;
    shiftY = mobile ? 0.4 : 0.02;
    // park the sun just over the head's upper-right rim so its beams spill through the florets
    const t0 = T;
    T = T_SETTLED;
    placeCamera();
    T = t0;
    _v.set(0.42, 0.44, -0.72).project(camera);
    sunHome.set(_v.x * 0.5 + 0.5 - 0.02, _v.y * 0.5 + 0.5 - 0.12);
    skyMat.uniforms.uAspect.value = aspect;
    U.uGrid.value.set(w / 9, h / 9);
    U.uDepthRef.value = baseDist;
    compMat.uniforms.uMask.value.set(mobile ? 1 : 0, mobile ? 0.4 : 0.36, 0, 0);
    compMat.uniforms.uFocus.value.set(mobile ? 0.5 : 0.64, mobile ? 0.66 : 0.55);
  }

  function placeCamera() {
    const dolly = 1 + 0.08 * (1 - easeOut(T / 9));
    const d = baseDist * dolly;
    const px = pointer.seen && !touch ? pointer.x - 0.5 : 0;
    const az = 0.05 * Math.sin(T * 0.06) - px * 0.06;
    const elv = 0.5 + 0.02 * Math.sin(T * 0.05);
    camera.position.set(
      target.x + d * Math.sin(az) * Math.cos(elv),
      target.y + d * Math.sin(elv),
      target.z + d * Math.cos(az) * Math.cos(elv),
    );
    camera.lookAt(target);
    camera.updateProjectionMatrix();
    // lens shift: moves the flower off-centre without perspective skew
    camera.projectionMatrix.elements[8] = -shiftX;
    camera.projectionMatrix.elements[9] = -shiftY;
    camera.projectionMatrixInverse.copy(camera.projectionMatrix).invert();
    camera.updateMatrixWorld();
  }

  function update(dt) {
    U.uTime.value = T;
    // --- intro: LiDAR sweep → densify → surfaces → sunrise
    const front = -1.5 + 3.1 * smooth(0.12, 1.25, T);
    const dense1 = smooth(0.95, 1.35, T);
    const dense2 = smooth(1.3, 1.75, T);
    const dots = 1 - smooth(1.95, 2.7, T);
    U.uLidar.value.set(front, dense1, dense2, dots);
    U.uReveal.value = smooth(1.6, 2.55, T);
    const rise = smooth(2.2, 4.8, T);

    // --- sun: follows the cursor (eased); drifts by itself on touch or before the first move
    if (touch || !pointer.seen) {
      const amp = mobile ? 0.16 : 0.06;
      sunTarget.set(sunHome.x + amp * Math.sin(T * 0.11), sunHome.y + 0.035 * Math.sin(T * 0.17 + 1));
    } else {
      // pulled toward the cursor, but kept off the text column
      sunTarget.set(Math.max(0.5, sunHome.x + (pointer.x - sunHome.x) * 0.6), sunHome.y + (1 - pointer.y - sunHome.y) * 0.6);
    }
    const k = dt > 0 ? 1 - Math.exp(-dt * 2.0) : 1;
    sunUV.x += (sunTarget.x - sunUV.x) * k;
    sunUV.y += (sunTarget.y - sunUV.y) * k;
    const su = skyMat.uniforms.uSunUV.value;
    su.set(sunUV.x, sunUV.y - (1 - easeOut(rise)) * 0.42);
    skyMat.uniforms.uSunI.value = rise;
    skyMat.uniforms.uDawn.value = Math.max(U.uReveal.value * 0.35, rise);
    moteMat.uniforms.uSunI.value = rise;

    _c.copy(cEmber).lerp(cWarm, smooth(0, 0.6, rise)).lerp(cCore, 0.3 * smooth(0.5, 1, rise));
    U.uSunCol.value.copy(_c).multiplyScalar(2.6 * rise);

    placeCamera();

    // sun in the world: far behind the flower, on the ray through its screen position
    // light direction follows the sun's place on screen relative to the flower: always above
    // and behind it, so the head is backlit and its top takes the light
    _r.set(1, 0, 0).applyQuaternion(camera.quaternion);
    _r.y = 0;
    _r.normalize();
    _v.set(0, 0, -1).applyQuaternion(camera.quaternion);
    _v.y = 0;
    _v.normalize();
    _w.set(su.x * 2 - 1, su.y * 2 - 1, 0.5).unproject(camera).sub(camera.position).normalize();
    U.uSunView.value.copy(_w);
    U.uSunDir.value
      .set(0, Math.max(0.15, 0.45 + 1.1 * (su.y - (0.5 + shiftY * 0.5))), 0)
      .addScaledVector(_r, (su.x - (0.5 + shiftX * 0.5)) * 2.4)
      .addScaledVector(_v, 0.8)
      .normalize();

    // --- heliotropism: the head leans toward the sun, spring-damped
    const L = U.uSunDir.value;
    const tz = -THREE.MathUtils.clamp(L.x * 0.8, -0.3, 0.3);
    const tx = 0.1 - 0.34 * (1 - clamp01(L.y * 1.3));
    if (dt > 0) {
      const ks = 7;
      const cs = 2 * Math.sqrt(ks) * 0.55;
      const steps = 4;
      const h = dt / steps;
      for (let i = 0; i < steps; i++) {
        spring.vx += (ks * (tx - spring.x) - cs * spring.vx) * h;
        spring.vz += (ks * (tz - spring.z) - cs * spring.vz) * h;
        spring.x += spring.vx * h;
        spring.z += spring.vz * h;
      }
    } else {
      spring.x = tx;
      spring.z = tz;
      spring.vx = spring.vz = 0;
    }
    pivot.rotation.set(spring.x + 0.012 * Math.sin(T * 0.5), 0, spring.z + 0.01 * Math.sin(T * 0.37));

    // --- projector for the LiDAR lattice: beside the camera, same lens
    _r.set(1, 0, 0).applyQuaternion(camera.quaternion);
    _u.set(0, 1, 0).applyQuaternion(camera.quaternion);
    projector.position.copy(camera.position).addScaledVector(_r, 0.45).addScaledVector(_u, 0.25);
    projector.quaternion.copy(camera.quaternion);
    projector.updateMatrixWorld();
    _m.copy(projector.matrixWorld).invert();
    U.uProjVP.value.multiplyMatrices(camera.projectionMatrix, _m);
    U.uProjPos.value.copy(projector.position);
  }

  function setTexel(mat, target) {
    mat.uniforms.uTexel.value.set(1 / target.width, 1 / target.height);
  }

  function render() {
    frames++;
    renderer.info.reset();
    // 1. sky + out-of-focus clusters at half resolution, then blurred
    renderer.setRenderTarget(backRT);
    renderer.clear();
    renderer.render(backScene, camera);
    blurMat.uniforms.tSrc.value = backRT.texture;
    blurMat.uniforms.uDir.value.set(1.6 / backRT.width, 0);
    pass(blurMat, blurA);
    blurMat.uniforms.tSrc.value = blurA.texture;
    blurMat.uniforms.uDir.value.set(0, 1.6 / backRT.height);
    pass(blurMat, blurB);
    // 2. hero cluster (MSAA, HDR); alpha = occluder coverage
    renderer.setRenderTarget(mainRT);
    renderer.clear();
    renderer.render(mainScene, camera);
    // 3. god rays at half resolution
    pass(raySrcMat, raysA);
    pass(raysMat, raysB);
    // 4. bloom: bright pass + dual-filter down/up chain
    pass(brightMat, bl[0]);
    for (let i = 1; i < 4; i++) {
      downMat.uniforms.tSrc.value = bl[i - 1].texture;
      setTexel(downMat, bl[i - 1]);
      pass(downMat, bl[i]);
    }
    for (let i = 2; i >= 0; i--) {
      const src = i === 2 ? bl[3] : bu[i + 1];
      upMat.uniforms.tSrc.value = src.texture;
      upMat.uniforms.tBase.value = bl[i].texture;
      setTexel(upMat, src);
      pass(upMat, bu[i]);
    }
    // 5. composite to screen
    pass(compMat, null);
  }

  function resize() {
    const w = Math.max(1, el.clientWidth);
    const h = Math.max(1, el.clientHeight);
    const dpr = Math.min(window.devicePixelRatio || 1, 1.75);
    renderer.setPixelRatio(dpr);
    renderer.setSize(w, h, false);
    W = Math.round(w * dpr);
    H = Math.round(h * dpr);
    mainRT.setSize(W, H);
    const hw = Math.max(1, W >> 1);
    const hh = Math.max(1, H >> 1);
    for (const t of [backRT, blurA, blurB, raysA, raysB]) t.setSize(hw, hh);
    for (let i = 0; i < 4; i++) bl[i].setSize(Math.max(1, W >> (i + 1)), Math.max(1, H >> (i + 1)));
    for (let i = 0; i < 3; i++) bu[i].setSize(Math.max(1, W >> (i + 1)), Math.max(1, H >> (i + 1)));
    moteMat.uniforms.uPx.value = dpr;
    layout(w, h);
    if (reduced || !raf) renderStill();
  }

  function renderStill() {
    if (destroyed) return;
    if (reduced) {
      T = T_SETTLED;
      sunUV.copy(sunHome);
    }
    update(0);
    render();
  }

  function frame(now) {
    raf = requestAnimationFrame(frame);
    const dt = Math.min((now - last) / 1000, 1 / 20);
    last = now;
    if (frozen >= 0) T = frozen;
    else T += dt;
    update(frozen >= 0 ? 1 / 60 : dt);
    render();
  }

  function sync() {
    const run = visible && !document.hidden && !reduced && !destroyed;
    if (run && !raf) {
      last = performance.now();
      raf = requestAnimationFrame(frame);
    } else if (!run && raf) {
      cancelAnimationFrame(raf);
      raf = 0;
    }
  }

  function onPointer(e) {
    if (e.pointerType === 'touch') return;
    const r = el.getBoundingClientRect();
    pointer.x = clamp01((e.clientX - r.left) / r.width);
    pointer.y = clamp01((e.clientY - r.top) / r.height);
    pointer.seen = true;
  }
  function onContextLost(e) {
    e.preventDefault();
    console.error('[hero] WebGL context lost; rendering stopped.');
    visible = false;
    sync();
  }

  const ro = new ResizeObserver(resize);
  ro.observe(el);
  const io = new IntersectionObserver(
    (entries) => {
      visible = entries[entries.length - 1].isIntersecting;
      sync();
    },
    { threshold: 0 },
  );
  io.observe(el);
  document.addEventListener('visibilitychange', sync);
  if (!touch) window.addEventListener('pointermove', onPointer, { passive: true });
  canvas.addEventListener('webglcontextlost', onContextLost);
  resize();

  return {
    destroy() {
      if (destroyed) return;
      destroyed = true;
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
      ro.disconnect();
      io.disconnect();
      document.removeEventListener('visibilitychange', sync);
      window.removeEventListener('pointermove', onPointer);
      canvas.removeEventListener('webglcontextlost', onContextLost);
      for (const d of disposables) d.dispose();
      renderer.dispose();
      renderer.forceContextLoss();
      canvas.remove();
      el.style.isolation = prevIsolation;
    },
    // QA hooks: pin the timeline, read counts. Not part of the page contract.
    _debug: {
      freeze(t) {
        frozen = t;
      },
      resume() {
        frozen = -1;
      },
      // render n frames back to back, waiting for the GPU each time; returns ms per frame
      bench(n = 60) {
        const gl = renderer.getContext();
        const px = new Uint8Array(4);
        const sync = () => gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
        render();
        sync();
        const t0 = performance.now();
        for (let i = 0; i < n; i++) {
          render();
          sync();
        }
        return (performance.now() - t0) / n;
      },
      info() {
        return {
          frames,
          heroFlorets: heroInst.n,
          backFlorets: backInst.n,
          leaves: heroLeaves.count + backLeaves.count,
          calls: renderer.info.render.calls,
          triangles: renderer.info.render.triangles,
          size: [W, H],
          samples: mainRT.samples,
          sun: [skyMat.uniforms.uSunUV.value.x, skyMat.uniforms.uSunUV.value.y],
          back: [backA, backB].map((m) => {
            const p = new THREE.Vector3().setFromMatrixPosition(m).project(camera);
            return [+(p.x * 0.5 + 0.5).toFixed(2), +(p.y * 0.5 + 0.5).toFixed(2)];
          }),
        };
      },
    },
  };
}
