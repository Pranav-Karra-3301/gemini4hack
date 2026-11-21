// Real-data showcase: "03 · After the shot", lighting by distance in 3D.
// One sticky, full-viewport stage inside a ~400vh track. It opens on the photo from chapter 01 for
// one beat (2D canvas, ./shaders.js), then scroll drives two stages:
//   A the 3D scene rebuilt from the photo and its depth (3D canvas, ../memory3d/): it starts at the
//     capture camera, identical to the photo, then pulls back and orbits ~25deg, frustum marking the
//     frame. Drag to look around.
//   B Gemini's light plan on that scene: three layers picked by distance from the camera (the people,
//     the whole scene's warmth, the far background), fader pills, hold to compare.
// Data: landing/public/showcase/ (IMG_1491 photo; the packed depth and people mask are fetched only
// if the 3D scene cannot load) and landing/public/splats/img-1491.spz (loaded as the section nears).
//
//   import { mountShowcase } from './showcase/showcase.js';
//   const { destroy } = mountShowcase(sectionEl, { heading: true, chapters: ['03 · After the shot'] });

import './showcase.css';
import { VERT, FRAG } from './shaders.js';

const BASE = (import.meta.env && import.meta.env.BASE_URL) || '/';
const asset = (name) => `${BASE}showcase/${name}`;
const SRC = {
  photo: asset('img-1491.webp'),
  packed: asset('img-1491_depth_packed.png'),
  mask: asset('img-1491_people.png'),
};
// The 3D scene for this photo (public/memories.json): splat + capture intrinsics.
const MEMORY = { id: 'img-1491', file: `${BASE}splats/img-1491.spz`, frame: { w: 2978, h: 2234, f: 2236.9 } };

const STAGES = [
  {
    eyebrow: 'Depth',
    title: 'The shot, in 3D',
    line: 'The photo and its depth, rebuilt as a scene you can turn. Drag to look around.',
    label: 'The photo rebuilt in 3D from its depth, seen from beside the camera that took it.',
  },
  {
    eyebrow: 'Edit for Me',
    title: 'Gemini lights it by distance',
    line: 'It picks layers by how far they are: the faces at 2.5 m lift, the warm light stays, the sea settles.',
    label: 'The 3D scene relit by distance: the people brighter, the light warmer, the background dimmer.',
  },
];
const STAGE_AT = [0, 0.56]; // progress where each stage starts

// The three layers Gemini sets, each by its distance from the camera.
const FADERS = [
  { name: 'People', where: '2.5 m', target: 0.6, range: 1, digits: 1 },
  { name: 'Warmth', where: 'whole scene', target: 8, range: 20, digits: 0 },
  { name: 'Background', where: '20 m+', target: -0.3, range: 1, digits: 1 },
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

/** Scroll progress -> every visual parameter. Pure, so it is easy to reason about. */
function stageParams(p) {
  return {
    show3d: ss(0.06, 0.11, p), // the splat at the capture eye looks like the photo: a seamless swap
    pull: easeInOut(clamp((p - 0.12) / 0.32)),
    feather: 1 - ss(0.13, 0.25, p),
    frustum: ss(0.2, 0.34, p),
    edit: ss(STAGE_AT[1], STAGE_AT[1] + 0.04, p),
    stage: p < STAGE_AT[1] ? 0 : 1,
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
        <span class="sc-pill-name">${f.name} <b>&middot;</b> <em>${f.where}</em></span>
        <span class="sc-pill-track"><i class="sc-pill-knob"></i></span>
        <output>${fmt(0, f.digits)}</output>
      </div>`,
  ).join('');
  const head = opts.heading
    ? `<div class="sc-head"><p class="sc-eyebrow">${opts.chapters[0]}</p><h2 class="sc-h2">Light by distance.</h2></div>`
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
        <div class="sc-hint"><span class="sc-hint-text"></span></div>
        <div class="sc-pills" aria-label="The layers Gemini set, by distance">
          ${pills}
          <button type="button" class="sc-pill sc-compare" aria-pressed="false">Hold to compare</button>
        </div>
      </div>
    </div>
  </div>`;
}

// ------------------------------------------------------------------------------------------------
// 2D GL (the opening photo, and the fallback edit if the 3D scene cannot load)

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
  for (const n of ['uPhoto', 'uDepth', 'uMask', 'uRes', 'uTex', 'uEdit', 'uFaders'])
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
  function uploadPhoto(photo) {
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.pixelStorei(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL, gl.BROWSER_DEFAULT_WEBGL);
    tex(0, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, gl.RGBA, gl.UNSIGNED_BYTE, photo);
    gl.generateMipmap(gl.TEXTURE_2D);
    if (aniso) gl.texParameterf(gl.TEXTURE_2D, aniso.TEXTURE_MAX_ANISOTROPY_EXT, 4);
    texW = photo.naturalWidth;
    texH = photo.naturalHeight;
  }

  // Only for the fallback edit: distance (packed depth) and the people mask.
  function uploadEdit({ depth, mask }) {
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    tex(1, false);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R16F, depth.w, depth.h, 0, gl.RED, gl.FLOAT, depth.data);

    gl.pixelStorei(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL, gl.NONE);
    tex(2, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, gl.RED, gl.UNSIGNED_BYTE, mask);
    gl.generateMipmap(gl.TEXTURE_2D);
  }

  function draw(edit, faders) {
    const w = canvas.width, h = canvas.height;
    gl.viewport(0, 0, w, h);
    gl.uniform2f(U.uRes, w, h);
    gl.uniform2f(U.uTex, texW, texH);
    gl.uniform1f(U.uEdit, edit);
    gl.uniform3f(U.uFaders, faders[0], faders[1], faders[2]);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  function dispose() {
    gl.getExtension('WEBGL_lose_context')?.loseContext();
  }

  return { gl, uploadPhoto, uploadEdit, draw, dispose };
}

// ------------------------------------------------------------------------------------------------

export function mountShowcase(el, options = {}) {
  const opts = {
    heading: true,
    chapters: ['03 · After the shot'],
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
  const hintText = $('.sc-hint-text');
  const compare = $('.sc-compare');
  const steps = [...track.querySelectorAll('.sc-step')];
  const ticks = [...track.querySelectorAll('.sc-ticks i')];
  const bars = { hint: $('.sc-hint'), pills: $('.sc-pills') };
  const pills = [...track.querySelectorAll('.sc-pill[data-fader]')].map((n) => ({
    el: n,
    out: n.querySelector('output'),
    knob: n.querySelector('.sc-pill-knob'),
  }));

  const motionMQ = matchMedia('(prefers-reduced-motion: reduce)');
  let reduced = motionMQ.matches;

  let renderer = null;
  let ready = false; // the photo is on the 2D canvas
  let flatEdit = null; // 'loading' | 'ready' | 'failed': depth + mask for the fallback edit
  let destroyed = false;
  let visible = false;
  let raf = 0;
  let lastT = 0;
  let clock = 0;
  let target = 0;
  let cur = 0;
  let stage = -1;
  let bar = null; // which of `bars` is showing
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
    media.setAttribute('aria-label', STAGES[s].label);
  }

  function setBar(key) {
    if (key === bar) return;
    if (bar) bars[bar].classList.remove('is-on');
    if (key) bars[key].classList.add('is-on');
    bar = key;
  }

  // The fallback edit needs distance and the people mask; fetch them only when it is needed.
  function loadFlatEdit() {
    if (flatEdit || !renderer || destroyed) return;
    flatEdit = 'loading';
    Promise.all([loadPackedDepth(SRC.packed), loadImage(SRC.mask)])
      .then(([depth, mask]) => {
        if (destroyed) return;
        renderer.uploadEdit({ depth, mask });
        flatEdit = 'ready';
        invalidate();
      })
      .catch((err) => {
        console.warn('[showcase] flat edit unavailable:', err);
        flatEdit = 'failed';
      });
  }

  // ---- 3D memory ---------------------------------------------------------------------------
  function load3d() {
    if (loading3d || failed3d || destroyed) return;
    hintText.innerHTML = 'Loading the 3D scene';
    loading3d = import('../memory3d/stage.js')
      .then(({ createMemoryStage }) => {
        if (destroyed) return null;
        const st = createMemoryStage(canvas3d, {
          def: MEMORY,
          onDirty: invalidate,
          onProgress: (e) => {
            if (e.lengthComputable && !stage3d) hintText.innerHTML = `Loading the 3D scene <b>&middot;</b> ${Math.round((e.loaded / e.total) * 100)}%`;
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
        hintText.textContent = 'Drag to look around';
        el.classList.add('has-3d');
        invalidate();
      })
      .catch((err) => {
        console.warn('[showcase] 3D scene unavailable, staying flat:', err);
        failed3d = true;
        canvas3d.remove();
        hintText.textContent = '';
        loadFlatEdit();
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
    // Stage A: the load progress, then "Drag to look around" once the 3D scene is on screen.
    // Stage B: the layer pills. Nothing during the photo beat or if the 3D scene failed.
    setBar(P.stage === 1 ? 'pills' : stage3d ? (P.show3d > 0.5 ? 'hint' : null) : failed3d ? null : 'hint');
    if (P.stage === 1 && !stage3d) loadFlatEdit(); // still loading or failed: the photo carries the edit

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

    // 3D: shown once loaded and the photo beat is over. Until then the flat photo holds.
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
      renderer.draw(stage3d || flatEdit !== 'ready' ? 0 : P.edit * editMix, faders);
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

  let rigSy = null; // the 3D rig's own vertical slide, kept for landscape
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
    if (st) {
      // Portrait: the captions sit at the bottom, so slide the pulled-back scene up to keep the people clear.
      rigSy ??= st.rig.sy;
      st.rig.sy = cw / ch < 0.75 ? -0.16 : rigSy;
    }
    // 1.2M splats: Wayback's 1.5x cap keeps the fill rate sane on retina screens.
    st?.resize(cw, ch, Math.min(window.devicePixelRatio || 1, 1.5));
    invalidate();
  }
  const ro = new ResizeObserver(() => sizeCanvases());
  ro.observe(media);

  // ---- fallback (no WebGL2): the plain photo ----------------------------------------------
  function mountFallback() {
    canvas.remove();
    const fb = document.createElement('div');
    fb.className = 'sc-fallback';
    fb.innerHTML = `<img alt="" src="${SRC.photo}">`;
    media.insertBefore(fb, media.firstChild);
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
    loadImage(SRC.photo)
      .then((photo) => {
        if (destroyed) return;
        renderer.uploadPhoto(photo);
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
      renderer?.dispose();
      stage3d?.dispose();
      track.remove();
      el.classList.remove('sc', 'is-ready', 'is-editing', 'has-3d', 'is-dragging');
    },
  };
}
