// Real-data showcase: "Sees in depth" -> "Edits with you".
// One sticky, full-viewport stage inside a ~500vh track. Scroll drives four stages:
//   1 the photo, full-bleed · 2 Depth Pro depth + scan line (2D canvas, ./shaders.js) ·
//   3 the SHARP splat "memory" (3D canvas, ../memory3d/, after Wayback): it starts at the capture
//     camera, identical to the photo, then pulls back and orbits ~25deg, frustum marking the frame ·
//   4 Gemini's depth-aware light edit on the splat, fader pills, hold to compare.
// Data: landing/public/showcase/ (IMG_1491 photo, Depth Pro map, people mask) and
// landing/public/splats/img-1491.spz (loaded lazily as the section approaches).
//
//   import { mountShowcase } from './showcase/showcase.js';
//   const { destroy } = mountShowcase(sectionEl, { heading: true });

import './showcase.css';
import { VERT, FRAG } from './shaders.js';

const BASE = (import.meta.env && import.meta.env.BASE_URL) || '/';
const asset = (name) => `${BASE}showcase/${name}`;
const SRC = {
  photo: asset('img-1491.webp'),
  depth: asset('img-1491_depth.png'),
  packed: asset('img-1491_depth_packed.png'),
  mask: asset('img-1491_people.png'),
};
// Wayback's manifest entry for this photo (public/memories.json): SHARP splat + capture intrinsics.
const MEMORY = { id: 'img-1491', file: `${BASE}splats/img-1491.spz`, frame: { w: 2978, h: 2234, f: 2236.9 } };

const STAGES = [
  {
    eyebrow: 'As shot',
    title: 'The photo',
    line: 'One frame from the coast, untouched.',
    label: 'The original photo: three friends at a railing above the sea.',
  },
  {
    eyebrow: 'Depth Pro',
    title: 'Depth Pro reads distance',
    line: 'Every pixel gets a distance, from 2.5 m out to the sea.',
    label: 'The Depth Pro depth map of the photo. Near is white, far is black.',
  },
  {
    eyebrow: 'Memory',
    title: 'Step inside the shot',
    line: 'One photo becomes a 3D scene. Drag to look around.',
    label: 'The photo rebuilt in 3D, seen from beside the camera that took it.',
  },
  {
    eyebrow: 'Gemini',
    title: 'Gemini edits by light',
    line: 'Brighter faces, warmer light, a quieter sea.',
    label: 'The 3D scene relit: the people brighter, the light warmer, the background dimmer.',
  },
];
const STAGE_AT = [0, 0.16, 0.39, 0.74]; // progress where each stage starts

const FADERS = [
  { name: 'People', target: 0.6, range: 1, digits: 1 },
  { name: 'Warmth', target: 8, range: 20, digits: 0 },
  { name: 'Background', target: -0.3, range: 1, digits: 1 },
];

const DEG = Math.PI / 180;
const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const ss = (a, b, x) => {
  const t = clamp((x - a) / (b - a));
  return t * t * (3 - 2 * t);
};
const easeInOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
const approach = (cur, to, rate, dt) => {
  const v = to + (cur - to) * Math.exp(-rate * dt);
  return Math.abs(v - to) < 1e-4 ? to : v;
};
const fmt = (v, digits) => {
  const r = Number(v.toFixed(digits));
  const s = Math.abs(r).toFixed(digits);
  return r > 0 ? `+${s}` : r < 0 ? `−${s}` : s;
};
const fmtCount = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${Math.round(n / 1e3)}k` : String(n));

/** Scroll progress -> every visual parameter. Pure, so it is easy to reason about. */
function stageParams(p) {
  const scanT = clamp((p - 0.19) / 0.15);
  return {
    depthMix: ss(0.12, 0.2, p) * (1 - ss(0.35, 0.405, p)),
    scan: 1 - Math.pow(scanT, 2) * 0.93,
    scanOn: ss(0.175, 0.2, p) * (1 - ss(0.33, 0.355, p)),
    show3d: ss(0.405, 0.44, p), // the splat at the capture eye looks like the photo: a seamless swap
    pull: easeInOut(clamp((p - 0.45) / 0.27)),
    feather: 1 - ss(0.46, 0.56, p),
    frustum: ss(0.5, 0.62, p),
    edit: ss(0.74, 0.78, p),
    stage: p < STAGE_AT[1] ? 0 : p < STAGE_AT[2] ? 1 : p < STAGE_AT[3] ? 2 : 3,
  };
}

function template(opts) {
  const steps = STAGES.map(
    (s, i) => `
      <li class="sc-step${i === 0 ? ' is-active' : ''}" data-step="${i}"${i === 0 ? '' : ' aria-hidden="true"'}>
        <span class="sc-eyebrow">${s.eyebrow}</span>
        <h3 class="sc-h3">${s.title}</h3>
        <p class="sc-line">${s.line}</p>
      </li>`,
  ).join('');
  const ticks = STAGES.map((_, i) => `<i${i === 0 ? ' class="is-on"' : ''}></i>`).join('');
  const pills = FADERS.map(
    (f, i) => `
      <div class="sc-pill" data-fader="${i}">
        <span>${f.name}</span>
        <span class="sc-pill-track"><i class="sc-pill-knob"></i></span>
        <output>${fmt(0, f.digits)}</output>
      </div>`,
  ).join('');
  const head = opts.heading
    ? `<div class="sc-swap sc-head">
        <div data-chapter="0"><p class="sc-eyebrow">${opts.chapters[0]}</p><h2 class="sc-h2">Sees in depth.</h2></div>
        <div data-chapter="1" aria-hidden="true"><p class="sc-eyebrow">${opts.chapters[1]}</p><h2 class="sc-h2">Edits with you.</h2></div>
      </div>`
    : '';
  return `
  <div class="sc-track">
    <div class="sc-sticky">
      <div class="sc-media" role="img" aria-label="${STAGES[0].label}">
        <canvas class="sc-canvas sc-canvas--2d"></canvas>
        <canvas class="sc-canvas sc-canvas--3d"></canvas>
        <div class="sc-feather"></div>
      </div>
      <div class="sc-shade" aria-hidden="true"></div>
      <div class="sc-copy">
        ${head}
        <div class="sc-ticks" aria-hidden="true">${ticks}</div>
        <ol class="sc-steps">${steps}</ol>
      </div>
      <div class="sc-bar">
        <div class="sc-meta is-on">IMG_1491.jpg <b>&middot;</b> 2048 &times; 1536 <b>&middot;</b> as shot</div>
        <div class="sc-legend" aria-hidden="true">
          <span>Near <b>2.5 m</b></span>
          <span class="sc-legend-bar"><i class="sc-legend-tick"></i></span>
          <span>Far <b>the sea</b></span>
        </div>
        <div class="sc-hint"><span class="sc-hint-text">SHARP <b>&middot;</b> one photo to 3D</span></div>
        <div class="sc-pills" aria-label="What Gemini changed">
          ${pills}
          <button type="button" class="sc-pill sc-compare" aria-pressed="false">Hold to compare</button>
        </div>
      </div>
    </div>
  </div>`;
}

// ------------------------------------------------------------------------------------------------
// 2D GL (stages 1-2, and the fallback edit)

function loadImage(src) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.decoding = 'async';
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error(`showcase: failed to load ${src}`));
    img.src = src;
  });
}

/** Packed PNG (R = high byte, G = low byte) -> Float32 depth, exactly, with no colour management. */
async function loadPackedDepth(src) {
  const blob = await (await fetch(src)).blob();
  const bmp = await createImageBitmap(blob, { colorSpaceConversion: 'none', premultiplyAlpha: 'none' });
  const { width: w, height: h } = bmp;
  const c = typeof OffscreenCanvas !== 'undefined' ? new OffscreenCanvas(w, h) : Object.assign(document.createElement('canvas'), { width: w, height: h });
  const ctx = c.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(bmp, 0, 0);
  bmp.close?.();
  const px = ctx.getImageData(0, 0, w, h).data;
  const out = new Float32Array(w * h);
  for (let i = 0, j = 0; i < out.length; i++, j += 4) out[i] = (px[j] * 256 + px[j + 1]) / 65535;
  return { w, h, data: out };
}

function compile(gl, type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s) || 'shader compile failed');
  return s;
}

function createRenderer(canvas) {
  const gl = canvas.getContext('webgl2', {
    alpha: false,
    antialias: false,
    depth: false,
    stencil: false,
    premultipliedAlpha: false,
    powerPreference: 'high-performance',
  });
  if (!gl) return null;

  const prog = gl.createProgram();
  gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VERT));
  gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FRAG));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog) || 'link failed');
  gl.useProgram(prog);
  const vao = gl.createVertexArray();
  gl.bindVertexArray(vao);

  const U = {};
  for (const n of ['uPhoto', 'uDepth', 'uMask', 'uRes', 'uTex', 'uDepthMix', 'uScan', 'uScanOn', 'uEdit', 'uFaders'])
    U[n] = gl.getUniformLocation(prog, n);
  gl.uniform1i(U.uPhoto, 0);
  gl.uniform1i(U.uDepth, 1);
  gl.uniform1i(U.uMask, 2);

  const aniso = gl.getExtension('EXT_texture_filter_anisotropic');
  const tex = (unit, mip) => {
    const t = gl.createTexture();
    gl.activeTexture(gl.TEXTURE0 + unit);
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, mip ? gl.LINEAR_MIPMAP_LINEAR : gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    return t;
  };

  let texW = 1600, texH = 1200;
  function upload({ photo, depth, mask }) {
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.pixelStorei(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL, gl.BROWSER_DEFAULT_WEBGL);
    tex(0, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, gl.RGBA, gl.UNSIGNED_BYTE, photo);
    gl.generateMipmap(gl.TEXTURE_2D);
    if (aniso) gl.texParameterf(gl.TEXTURE_2D, aniso.TEXTURE_MAX_ANISOTROPY_EXT, 4);
    texW = photo.naturalWidth;
    texH = photo.naturalHeight;

    tex(1, false);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R16F, depth.w, depth.h, 0, gl.RED, gl.FLOAT, depth.data);

    gl.pixelStorei(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL, gl.NONE);
    tex(2, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, gl.RED, gl.UNSIGNED_BYTE, mask);
    gl.generateMipmap(gl.TEXTURE_2D);
  }

  function draw(P, edit, faders) {
    const w = canvas.width, h = canvas.height;
    gl.viewport(0, 0, w, h);
    gl.uniform2f(U.uRes, w, h);
    gl.uniform2f(U.uTex, texW, texH);
    gl.uniform1f(U.uDepthMix, P.depthMix);
    gl.uniform1f(U.uScan, P.scan);
    gl.uniform1f(U.uScanOn, P.scanOn);
    gl.uniform1f(U.uEdit, edit);
    gl.uniform3f(U.uFaders, faders[0], faders[1], faders[2]);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  function dispose() {
    gl.getExtension('WEBGL_lose_context')?.loseContext();
  }

  return { gl, upload, draw, dispose };
}

// ------------------------------------------------------------------------------------------------

export function mountShowcase(el, options = {}) {
  const opts = {
    heading: true,
    chapters: ['02 · Depth', '03 · Edit'],
    ...options,
  };
  el.classList.add('sc');
  const host = document.createElement('div');
  host.innerHTML = template(opts);
  const track = host.firstElementChild;
  el.appendChild(track);

  const $ = (s) => track.querySelector(s);
  const media = $('.sc-media');
  const canvas = $('.sc-canvas--2d');
  const canvas3d = $('.sc-canvas--3d');
  const feather = $('.sc-feather');
  const tick = $('.sc-legend-tick');
  const hintText = $('.sc-hint-text');
  const compare = $('.sc-compare');
  const steps = [...track.querySelectorAll('.sc-step')];
  const ticks = [...track.querySelectorAll('.sc-ticks i')];
  const chapters = [...track.querySelectorAll('[data-chapter]')];
  const bars = [$('.sc-meta'), $('.sc-legend'), $('.sc-hint'), $('.sc-pills')];
  const pills = [...track.querySelectorAll('.sc-pill[data-fader]')].map((n) => ({
    el: n,
    out: n.querySelector('output'),
    knob: n.querySelector('.sc-pill-knob'),
  }));

  const motionMQ = matchMedia('(prefers-reduced-motion: reduce)');
  let reduced = motionMQ.matches;

  let renderer = null;
  let ready = false;
  let destroyed = false;
  let visible = false;
  let raf = 0;
  let lastT = 0;
  let clock = 0;
  let target = 0;
  let cur = 0;
  let stage = -1;
  let barIdx = 0;
  let editOn = false;
  let comparing = false;
  let editMix = 1;
  const faders = [0, 0, 0];
  const tweens = [null, null, null];

  // 3D memory (lazy)
  let stage3d = null; // set once the splat is ready
  let loading3d = null;
  let failed3d = false;
  let shown3d = 0;
  let warmed = false;
  const drag = { on: false, id: -1, x: 0, y: 0, yaw: 0, pitch: 0 };

  // ---- progress ----------------------------------------------------------------------------
  function readProgress() {
    const r = track.getBoundingClientRect();
    const total = r.height - window.innerHeight;
    return total > 0 ? clamp(-r.top / total) : 0;
  }

  function invalidate() {
    if (!raf && visible && !destroyed) raf = requestAnimationFrame(frame);
  }

  // ---- faders ------------------------------------------------------------------------------
  function setFaders(on, now) {
    FADERS.forEach((f, i) => {
      const to = on ? f.target : 0;
      if (reduced) {
        faders[i] = to;
        tweens[i] = null;
      } else {
        tweens[i] = { from: faders[i], to, start: now + (on ? 280 + i * 560 : 0), dur: on ? 950 : 360 };
      }
    });
  }

  function stepFaders(now) {
    let busy = false;
    FADERS.forEach((f, i) => {
      const tw = tweens[i];
      let moving = false;
      if (tw) {
        const t = clamp((now - tw.start) / tw.dur);
        faders[i] = tw.from + (tw.to - tw.from) * easeInOut(t);
        moving = now >= tw.start && t < 1 && Math.abs(tw.to - tw.from) > 1e-3;
        if (t >= 1) tweens[i] = null;
        else busy = true;
      }
      const pl = pills[i];
      pl.out.textContent = fmt(faders[i], f.digits);
      pl.knob.style.transform = `translateX(${((faders[i] / f.range) * 22).toFixed(2)}px)`;
      pl.el.classList.toggle('is-moving', moving);
    });
    return busy;
  }

  // ---- DOM sync ----------------------------------------------------------------------------
  function setStage(s) {
    if (s === stage) return;
    stage = s;
    steps.forEach((n, i) => {
      n.classList.toggle('is-active', i === s);
      if (i === s) n.removeAttribute('aria-hidden');
      else n.setAttribute('aria-hidden', 'true');
    });
    ticks.forEach((n, i) => n.classList.toggle('is-on', i <= s));
    const ch = s === 3 ? 1 : 0;
    chapters.forEach((n, i) => (i === ch ? n.removeAttribute('aria-hidden') : n.setAttribute('aria-hidden', 'true')));
    media.setAttribute('aria-label', STAGES[s].label);
    if (s !== barIdx) {
      bars[barIdx].classList.remove('is-on');
      bars[s].classList.add('is-on');
      barIdx = s;
    }
  }

  // ---- 3D memory ---------------------------------------------------------------------------
  function load3d() {
    if (loading3d || failed3d || destroyed) return;
    hintText.innerHTML = 'Loading the 3D memory';
    loading3d = import('../memory3d/stage.js')
      .then(({ createMemoryStage }) => {
        if (destroyed) return null;
        const st = createMemoryStage(canvas3d, {
          def: MEMORY,
          onDirty: invalidate,
          onProgress: (e) => {
            if (e.lengthComputable && !stage3d) hintText.innerHTML = `Loading the 3D memory <b>&middot;</b> ${Math.round((e.loaded / e.total) * 100)}%`;
          },
        });
        sizeCanvases(st);
        return st.ready;
      })
      .then((st) => {
        if (!st || destroyed) return;
        stage3d = st;
        if (import.meta.env?.DEV) window.__showcase3d = { st, invalidate };
        const m = st.memory;
        console.info('[showcase] memory ready', { splats: m.count, median: m.median, quantiles: m.quantiles });
        hintText.innerHTML = `SHARP <b>&middot;</b> ${fmtCount(m.count)} gaussians <b>&middot;</b> drag to look around`;
        el.classList.add('has-3d');
        invalidate();
      })
      .catch((err) => {
        console.warn('[showcase] 3D memory unavailable, staying flat:', err);
        failed3d = true;
        canvas3d.remove();
        hintText.innerHTML = 'SHARP <b>&middot;</b> one photo to 3D';
        invalidate();
      });
  }

  // ---- frame -------------------------------------------------------------------------------
  function frame(now) {
    raf = 0;
    const dtMs = lastT ? Math.min(64, now - lastT) : 16.7;
    const dt = dtMs / 1000;
    lastT = now;
    clock += dt;
    target = readProgress();
    if (reduced) cur = target;
    else {
      cur += (target - cur) * (1 - Math.pow(1 - 0.15, dtMs / 16.7));
      if (Math.abs(target - cur) < 1e-4) cur = target;
    }

    const P = stageParams(cur);
    setStage(P.stage);

    const wantEdit = editOn ? P.edit > 0.3 : P.edit > 0.6;
    if (wantEdit !== editOn) {
      editOn = wantEdit;
      el.classList.toggle('is-editing', editOn);
      compare.tabIndex = editOn ? 0 : -1;
      setFaders(editOn, now);
      if (!editOn) setComparing(false);
    }
    const busy = stepFaders(now);
    const mixTo = comparing ? 0 : 1;
    editMix = reduced ? mixTo : approach(editMix, mixTo, 14, dt);

    tick.style.left = `${((1 - P.scan) / 0.93) * 100}%`;
    tick.style.opacity = String(P.scanOn);

    // 3D: shown once loaded and the scroll reaches stage 3. Until then the flat photo holds.
    let anim3d = false;
    const want3d = stage3d ? P.show3d : 0;
    shown3d = want3d;
    canvas3d.style.opacity = String(shown3d);
    feather.style.opacity = String(stage3d ? P.feather : 1);

    if (stage3d && (shown3d > 0 || !warmed)) {
      warmed = true; // one hidden render up front starts Spark's sort before the swap
      // Drag: a little orbit that eases home after release. Drift: gentle, only once pulled back.
      if (!drag.on) {
        drag.yaw = approach(drag.yaw, 0, 1.6, dt);
        drag.pitch = approach(drag.pitch, 0, 1.6, dt);
      }
      const amt = reduced ? 0 : ss(0, 0.35, P.pull);
      const yaw = amt * (Math.sin(clock * 0.23) * 2.2 + Math.sin(clock * 0.11) * 1.2) * DEG + drag.yaw;
      const pitch = amt * Math.sin(clock * 0.17 + 1.3) * 1.1 * DEG + drag.pitch;
      stage3d.pose(P.pull, yaw, pitch);
      stage3d.frustum(P.frustum * 0.55);
      stage3d.look({
        people: faders[0],
        warmth: faders[1],
        background: faders[2],
        edit: editMix,
      });
      stage3d.render();
      anim3d = amt > 0 || drag.yaw !== 0 || drag.pitch !== 0 || drag.on;
    }

    // 2D draws whenever it can be seen: under the 3D crossfade, or as the fallback edit.
    if (ready && shown3d < 1) {
      const flatEdit = stage3d ? 0 : P.edit * editMix;
      renderer.draw(P, flatEdit, faders);
    }

    if (cur !== target || busy || anim3d || editMix !== mixTo) invalidate();
    else lastT = 0;
  }

  // ---- compare + drag ----------------------------------------------------------------------
  function setComparing(on) {
    if (on && !editOn) return;
    if (comparing === on) return;
    comparing = on;
    compare.classList.toggle('is-held', on);
    compare.setAttribute('aria-pressed', String(on));
    compare.textContent = on ? 'Original' : 'Hold to compare';
    invalidate();
  }
  const holdOn = (e) => {
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    compare.setPointerCapture?.(e.pointerId);
    setComparing(true);
    e.preventDefault();
  };
  const holdOff = () => setComparing(false);
  const keyHold = (e) => {
    if (e.key !== ' ' && e.key !== 'Enter') return;
    e.preventDefault();
    if (!e.repeat) setComparing(e.type === 'keydown');
  };
  compare.addEventListener('pointerdown', holdOn);
  compare.addEventListener('pointerup', holdOff);
  compare.addEventListener('pointercancel', holdOff);
  compare.addEventListener('lostpointercapture', holdOff);
  compare.addEventListener('keydown', keyHold);
  compare.addEventListener('keyup', keyHold);
  compare.addEventListener('contextmenu', (e) => e.preventDefault());
  compare.tabIndex = -1;

  function onDown(e) {
    if (!stage3d || shown3d < 0.5 || (e.pointerType === 'mouse' && e.button !== 0)) return;
    drag.on = true;
    drag.id = e.pointerId;
    drag.x = e.clientX;
    drag.y = e.clientY;
    media.setPointerCapture?.(e.pointerId);
    el.classList.add('is-dragging');
    invalidate();
  }
  function onMove(e) {
    if (!drag.on || e.pointerId !== drag.id) return;
    const k = 0.18 * DEG; // per px
    drag.yaw = clamp(drag.yaw - (e.clientX - drag.x) * k, -14 * DEG, 14 * DEG);
    drag.pitch = clamp(drag.pitch + (e.clientY - drag.y) * k * (e.pointerType === 'touch' ? 0 : 1), -7 * DEG, 7 * DEG);
    drag.x = e.clientX;
    drag.y = e.clientY;
    invalidate();
  }
  function onUp(e) {
    if (e.pointerId !== drag.id) return;
    drag.on = false;
    drag.id = -1;
    el.classList.remove('is-dragging');
    invalidate();
  }
  media.addEventListener('pointerdown', onDown);
  media.addEventListener('pointermove', onMove);
  media.addEventListener('pointerup', onUp);
  media.addEventListener('pointercancel', onUp);

  // ---- listeners ---------------------------------------------------------------------------
  const onScroll = () => invalidate();
  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', onScroll, { passive: true });

  const onMotion = () => {
    reduced = motionMQ.matches;
    invalidate();
  };
  motionMQ.addEventListener?.('change', onMotion);

  const io = new IntersectionObserver(
    ([entry]) => {
      visible = entry.isIntersecting;
      if (visible) {
        lastT = 0;
        invalidate();
      } else if (raf) {
        cancelAnimationFrame(raf);
        raf = 0;
      }
    },
    { rootMargin: '120px 0px' },
  );
  io.observe(track);

  // The splat (15 MB) loads only once the section is about a screen away.
  const ioLoad = new IntersectionObserver(
    ([entry]) => {
      if (!entry.isIntersecting) return;
      ioLoad.disconnect();
      load3d();
    },
    { rootMargin: '100% 0px' },
  );
  ioLoad.observe(track);

  function sizeCanvases(st = stage3d) {
    const r = media.getBoundingClientRect();
    const cw = Math.max(1, Math.round(r.width));
    const ch = Math.max(1, Math.round(r.height));
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.round(cw * dpr);
    const h = Math.round(ch * dpr);
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
    // 1.2M splats: Wayback's 1.5x cap keeps the fill rate sane on retina screens.
    st?.resize(cw, ch, Math.min(window.devicePixelRatio || 1, 1.5));
    invalidate();
  }
  const ro = new ResizeObserver(() => sizeCanvases());
  ro.observe(media);

  // ---- fallback (no WebGL2): plain images, photo <-> depth by stage -------------------------
  let cleanupFallback = null;
  function mountFallback() {
    canvas.remove();
    const fb = document.createElement('div');
    fb.className = 'sc-fallback';
    fb.innerHTML = `<img alt="" src="${SRC.photo}"><img alt="" src="${SRC.depth}" style="opacity:0">`;
    media.insertBefore(fb, media.firstChild);
    const depthImg = fb.lastElementChild;
    const sync = () => {
      depthImg.style.opacity = steps[1].classList.contains('is-active') ? '1' : '0';
    };
    const obs = new MutationObserver(sync);
    obs.observe(steps[1], { attributes: true, attributeFilter: ['class'] });
    sync();
    cleanupFallback = () => obs.disconnect();
  }

  // ---- boot --------------------------------------------------------------------------------
  try {
    renderer = createRenderer(canvas);
  } catch (err) {
    console.warn(err);
    renderer = null;
  }
  if (!renderer) {
    mountFallback();
  } else {
    canvas.addEventListener('webglcontextlost', (e) => e.preventDefault());
    canvas3d.addEventListener('webglcontextlost', (e) => e.preventDefault());
    Promise.all([loadImage(SRC.photo), loadPackedDepth(SRC.packed), loadImage(SRC.mask)])
      .then(([photo, depth, mask]) => {
        if (destroyed) return;
        renderer.upload({ photo, depth, mask });
        ready = true;
        el.classList.add('is-ready');
        invalidate();
      })
      .catch((err) => {
        console.warn(err);
        if (!destroyed) mountFallback();
      });
  }

  target = cur = readProgress();
  invalidate();

  return {
    destroy() {
      destroyed = true;
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
      window.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', onScroll);
      motionMQ.removeEventListener?.('change', onMotion);
      io.disconnect();
      ioLoad.disconnect();
      ro.disconnect();
      cleanupFallback?.();
      renderer?.dispose();
      stage3d?.dispose();
      track.remove();
      el.classList.remove('sc', 'is-ready', 'is-editing', 'has-3d', 'is-dragging');
    },
  };
}
