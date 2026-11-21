// Footer: a sunrise over a heliotrope field, with the wordmark in raking light, then the app row and credits.
// When the scene scrolls into view the sun rises behind three parallax layers of flower silhouettes (~4 s);
// florets and letter bevels catch its light, god rays fan up through the gaps. Afterwards the sun eases toward
// the cursor's x (or drifts on touch). Pauses off screen; one still, risen frame under reduced motion.
// Usage: const { destroy } = mountFooter(document.querySelector('footer'));
import './footer.css';
import {
  AdditiveBlending,
  BufferAttribute,
  BufferGeometry,
  Camera,
  CanvasTexture,
  LinearFilter,
  LinearMipmapLinearFilter,
  Mesh,
  NoColorSpace,
  PlaneGeometry,
  Points,
  Scene,
  ShaderMaterial,
  Vector2,
  Vector4,
  WebGLRenderTarget,
  WebGLRenderer,
} from 'three';
import { buildField, buildWordmark, rng } from './field.js';
import { MAIN_FRAG, MOTE_FRAG, MOTE_VERT, OCC_FRAG, QUAD_VERT, RAYS_FRAG } from './shaders.js';

const ICON_IOS = '/assets/ios-AppIcon-1024.png';
const CREDITS =
  'Flower photos: Wikimedia Commons contributors (Emőke Dénes, Cephas, Niepokój Zbigniew, shirleybolling2005), CC BY-SA 4.0 / CC BY 2.0';
const FAMILY = '"Google Sans Flex", "Google Sans", system-ui, sans-serif';
const WORD = 'Heliocam';
const DPR_MAX = 1.75;
const RISE_S = 4.2; // sunrise length
const START_RATIO = 0.45; // share of the scene in view before the sun starts to rise
const PARALLAX_X = [0.03, 0.07, 0.13]; // layer shift per px of sun travel (back, mid, front)
const RISE_Y = [0.012, 0.03, 0.06]; // layer rise during the sunrise, share of scene height

const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const smooth = (a, b, v) => {
  const t = clamp((v - a) / (b - a), 0, 1);
  return t * t * (3 - 2 * t);
};
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

function markup() {
  return `
    <div class="hf__scene" role="img" aria-label="Heliocam: a sun rising over a field of heliotrope">
      <canvas class="hf__canvas" aria-hidden="true"></canvas>
      <p class="hf__fallback" aria-hidden="true">${WORD}</p>
    </div>
    <div class="hf__wrap">
      <div class="hf__app">
        <img class="hf__icon" src="${ICON_IOS}" width="56" height="56" alt="" loading="lazy" decoding="async" />
        <p class="hf__name">${WORD}<span>for iPhone · LiDAR · Gemini 4</span></p>
      </div>
      <div class="hf__base">
        <p class="hf__built">Built with Gemini 4</p>
        <p class="hf__credits">${CREDITS}</p>
        <p class="hf__year">© 2026</p>
      </div>
    </div>`;
}

function dataTexture(canvas, mips) {
  const t = new CanvasTexture(canvas);
  t.flipY = false;
  t.colorSpace = NoColorSpace;
  t.generateMipmaps = mips;
  t.minFilter = mips ? LinearMipmapLinearFilter : LinearFilter;
  t.magFilter = LinearFilter;
  t.needsUpdate = true;
  return t;
}

/** Mounts the footer into an empty `<footer>` element. */
export function mountFooter(el) {
  el.classList.add('hf');
  el.innerHTML = markup();
  const sceneEl = el.querySelector('.hf__scene');
  const canvas = el.querySelector('.hf__canvas');
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  const fine = matchMedia('(hover: hover) and (pointer: fine)');

  let gl = null;
  let initing = false;
  let destroyed = false;
  let raf = 0;
  let last = 0;
  let visible = false;
  let started = false;
  let time = 0;
  let sr = 0; // seconds into the sunrise
  let W = 0;
  let H = 0;
  let scale = 1; // device px per CSS px
  let sceneLeft = 0;
  let sunX = 0;
  let pointerX = -1;
  let lay = null;
  let rebuildTimer = 0;
  let lit = false;

  function layout() {
    const mobile = W < 768;
    const hz = H * (mobile ? 0.7 : 0.68);
    const sunR = 0.032 * Math.max(Math.min(W, H * 1.4), 620);
    const pad = clamp(W * 0.05, 20, 64);
    return {
      hz,
      sunR,
      sunEnd: hz - sunR * 0.5,
      sunStart: hz + sunR * 1.5 + H * 0.04,
      margin: Math.round(W * 0.035 + 12),
      wordW: Math.min(W, 1280) - pad * 2,
      wordCY: H * (mobile ? 0.42 : 0.4),
    };
  }

  function build() {
    const w = Math.round(sceneEl.clientWidth);
    const h = Math.round(sceneEl.clientHeight);
    if (!w || !h) return false;
    W = w;
    H = h;
    sceneLeft = sceneEl.getBoundingClientRect().left;
    let dpr = Math.min(window.devicePixelRatio || 1, DPR_MAX);
    if (W * dpr > 4096) dpr = 4096 / W;
    const { renderer, u, rtOcc, rtRays, tmp } = gl;
    renderer.setPixelRatio(dpr);
    renderer.setSize(W, H, false);
    renderer.getDrawingBufferSize(tmp);
    scale = tmp.x / W;
    u.uRes.value.copy(tmp);
    u.uDpr.value = scale;
    const qw = Math.max(2, Math.round(tmp.x / 4));
    const qh = Math.max(2, Math.round(tmp.y / 4));
    rtOcc.setSize(qw, qh);
    rtRays.setSize(qw, qh);
    gl.raysMat.uniforms.uTexel.value.set(1 / qw, 1 / qh);

    lay = layout();
    u.uHz.value = lay.hz * scale;
    u.uSunR.value = lay.sunR * scale;
    if (!sunX) sunX = W / 2;

    const layers = buildField(W, H, dpr, { hz: lay.hz, margin: lay.margin });
    for (let i = 0; i < 3; i++) {
      gl.layerTex[i]?.dispose();
      gl.layerTex[i] = dataTexture(layers[i].canvas, true);
      u[`uL${i}`].value = gl.layerTex[i];
    }
    gl.layers = layers;

    const word = buildWordmark(WORD, FAMILY, lay.wordW, dpr);
    gl.wordTex?.dispose();
    gl.wordTex = dataTexture(word.canvas, false);
    u.uWord.value = gl.wordTex;
    u.uWR.value.set(((W - word.w) / 2) * scale, (lay.wordCY - word.h / 2) * scale, word.w * scale, word.h * scale);
    gl.mainMat.uniforms.uWTex.value.set(1 / word.canvas.width, 1 / word.canvas.height);
    gl.mainMat.uniforms.uBevel.value = word.sigma * 0.5;
    return true;
  }

  function update(dt) {
    const p = Math.min(1, sr / RISE_S);
    const e = 0.5 - 0.5 * Math.cos(Math.PI * p);
    const sunY = lay.sunStart + (lay.sunEnd - lay.sunStart) * e;
    const follow = smooth(0.7, 1, p);
    let target = W / 2;
    if (fine.matches && pointerX >= 0) target += follow * clamp((pointerX - W / 2) * 0.3, -0.16 * W, 0.16 * W);
    else target += follow * Math.sin(time * 0.12) * 0.07 * W;
    sunX += (target - sunX) * (1 - Math.exp(-dt * 1.3));

    const { u, layers, rects } = gl;
    u.uSun.value.set(sunX * scale, sunY * scale);
    u.uRise.value = Math.pow(e, 0.85);
    u.uTime.value = time;
    gl.raysMat.uniforms.uSunUv.value.set(sunX / W, 1 - sunY / H);
    const dx = sunX - W / 2;
    for (let i = 0; i < 3; i++) {
      const l = layers[i];
      rects[i].set((l.x - dx * PARALLAX_X[i]) * scale, (l.y + (1 - e) * RISE_Y[i] * H) * scale, l.w * scale, l.h * scale);
    }
    if (!lit && p >= 0.55) {
      lit = true;
      el.classList.add('hf--lit');
    }
  }

  function render() {
    const { renderer, cam } = gl;
    renderer.setRenderTarget(gl.rtOcc);
    renderer.render(gl.occScene, cam);
    renderer.setRenderTarget(gl.rtRays);
    renderer.render(gl.raysScene, cam);
    renderer.setRenderTarget(null);
    renderer.render(gl.mainScene, cam);
  }

  function frame(now) {
    raf = requestAnimationFrame(frame);
    const dt = Math.min(0.05, Math.max(0, (now - last) / 1000));
    last = now;
    time += dt;
    if (started) sr += dt;
    update(dt);
    render();
  }

  function play() {
    if (raf || !gl || !lay || !visible || destroyed || reduce.matches) return;
    last = performance.now();
    raf = requestAnimationFrame(frame);
  }

  function pause() {
    cancelAnimationFrame(raf);
    raf = 0;
  }

  function still() {
    if (!gl || !lay) return;
    sr = RISE_S;
    sunX = W / 2;
    update(0);
    render();
  }

  async function init() {
    if (gl || initing || destroyed) return;
    initing = true;
    await Promise.race([document.fonts.load(`700 100px ${FAMILY}`, WORD), wait(3000)]).catch(() => {});
    if (destroyed) return;
    let renderer;
    try {
      renderer = new WebGLRenderer({ canvas, antialias: false, alpha: false, powerPreference: 'high-performance' });
    } catch (err) {
      console.error('[footer] WebGL is unavailable; showing the static footer instead.', err);
      el.classList.add('hf--nogl');
      return;
    }
    renderer.setClearColor(0x05060b, 1);

    const u = {
      uRes: { value: new Vector2(1, 1) },
      uSun: { value: new Vector2() },
      uSunR: { value: 20 },
      uRise: { value: 0 },
      uTime: { value: 0 },
      uDpr: { value: 1 },
      uHz: { value: 0 },
      uL0: { value: null },
      uL1: { value: null },
      uL2: { value: null },
      uR0: { value: new Vector4() },
      uR1: { value: new Vector4() },
      uR2: { value: new Vector4() },
      uWord: { value: null },
      uWR: { value: new Vector4() },
    };
    const rtOpts = { depthBuffer: false, stencilBuffer: false, magFilter: LinearFilter, minFilter: LinearFilter };
    const rtOcc = new WebGLRenderTarget(2, 2, rtOpts);
    const rtRays = new WebGLRenderTarget(2, 2, rtOpts);
    const quad = new PlaneGeometry(2, 2);
    const quadMat = (frag, extra) =>
      new ShaderMaterial({ vertexShader: QUAD_VERT, fragmentShader: frag, uniforms: { ...u, ...extra }, depthTest: false, depthWrite: false });
    const occMat = quadMat(OCC_FRAG, {});
    const raysMat = quadMat(RAYS_FRAG, {
      uSrc: { value: rtOcc.texture },
      uSunUv: { value: new Vector2(0.5, 0.3) },
      uTexel: { value: new Vector2(1, 1) },
    });
    const mainMat = quadMat(MAIN_FRAG, {
      uRays: { value: rtRays.texture },
      uWTex: { value: new Vector2(1, 1) },
      uBevel: { value: 1 },
    });
    const occScene = new Scene();
    occScene.add(new Mesh(quad, occMat));
    const raysScene = new Scene();
    raysScene.add(new Mesh(quad, raysMat));
    const mainScene = new Scene();
    const mainQuad = new Mesh(quad, mainMat);
    mainQuad.frustumCulled = false;
    mainScene.add(mainQuad);

    // motes drifting in the beams; positions are computed on the GPU from fixed seeds
    const count = matchMedia('(max-width: 767px)').matches ? 70 : 140;
    const rand = rng(91);
    const seeds = new Float32Array(count * 4);
    for (let i = 0; i < seeds.length; i++) seeds[i] = rand();
    const moteGeo = new BufferGeometry();
    moteGeo.setAttribute('position', new BufferAttribute(new Float32Array(count * 3), 3));
    moteGeo.setAttribute('aSeed', new BufferAttribute(seeds, 4));
    const moteMat = new ShaderMaterial({
      vertexShader: MOTE_VERT,
      fragmentShader: MOTE_FRAG,
      uniforms: { uRes: u.uRes, uSun: u.uSun, uRise: u.uRise, uTime: u.uTime, uDpr: u.uDpr, uRays: { value: rtRays.texture } },
      blending: AdditiveBlending,
      transparent: true,
      depthTest: false,
      depthWrite: false,
    });
    const motes = new Points(moteGeo, moteMat);
    motes.frustumCulled = false;
    motes.renderOrder = 1;
    mainScene.add(motes);

    gl = {
      renderer,
      cam: new Camera(),
      u,
      rtOcc,
      rtRays,
      quad,
      occMat,
      raysMat,
      mainMat,
      moteGeo,
      moteMat,
      occScene,
      raysScene,
      mainScene,
      layerTex: [null, null, null],
      wordTex: null,
      layers: null,
      rects: [u.uR0.value, u.uR1.value, u.uR2.value],
      tmp: new Vector2(),
    };
    if (!build()) return;
    if (!document.fonts.check(`700 100px ${FAMILY}`, WORD)) {
      document.fonts.load(`700 100px ${FAMILY}`, WORD).then(() => !destroyed && gl && build() && (reduce.matches ? still() : 0));
    }
    if (reduce.matches) {
      el.classList.add('hf--lit');
      still();
    } else {
      el.classList.add('hf--armed');
      update(0);
      render();
      play();
    }
  }

  function scheduleRebuild() {
    clearTimeout(rebuildTimer);
    rebuildTimer = setTimeout(() => {
      if (!gl || destroyed) return;
      const w = Math.round(sceneEl.clientWidth);
      const h = Math.round(sceneEl.clientHeight);
      if (w === W && h === H) return;
      if (build()) {
        if (reduce.matches) still();
        else if (!raf) {
          update(0);
          render();
        }
      }
    }, 160);
  }

  const onPointer = (e) => {
    pointerX = e.clientX - sceneLeft;
  };
  const onReduce = () => {
    if (!gl) return;
    if (reduce.matches) {
      pause();
      el.classList.add('hf--lit');
      still();
    } else {
      play();
    }
  };

  const nearIO = new IntersectionObserver(
    (entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        nearIO.disconnect();
        init();
      }
    },
    { rootMargin: '0px 0px 120% 0px' },
  );
  const visIO = new IntersectionObserver(
    (entries) => {
      const e = entries[entries.length - 1];
      visible = e.isIntersecting;
      if (visible && e.intersectionRatio >= START_RATIO) started = true;
      if (visible) play();
      else pause();
    },
    { threshold: [0, START_RATIO, 0.75, 1] },
  );
  const ro = new ResizeObserver(scheduleRebuild);
  nearIO.observe(sceneEl);
  visIO.observe(sceneEl);
  ro.observe(sceneEl);
  window.addEventListener('pointermove', onPointer, { passive: true });
  reduce.addEventListener('change', onReduce);

  return {
    destroy() {
      if (destroyed) return;
      destroyed = true;
      pause();
      clearTimeout(rebuildTimer);
      nearIO.disconnect();
      visIO.disconnect();
      ro.disconnect();
      window.removeEventListener('pointermove', onPointer);
      reduce.removeEventListener('change', onReduce);
      if (gl) {
        gl.layerTex.forEach((t) => t?.dispose());
        gl.wordTex?.dispose();
        gl.rtOcc.dispose();
        gl.rtRays.dispose();
        gl.quad.dispose();
        gl.occMat.dispose();
        gl.raysMat.dispose();
        gl.mainMat.dispose();
        gl.moteGeo.dispose();
        gl.moteMat.dispose();
        gl.renderer.dispose();
        gl.renderer.forceContextLoss();
        gl = null;
      }
      el.innerHTML = '';
      el.classList.remove('hf', 'hf--nogl', 'hf--armed', 'hf--lit');
    },
  };
}
