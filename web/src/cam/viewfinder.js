// Viewfinder: a WebGL2 full-screen canvas that draws the camera video with animated "looks"
// (exposure, white balance, zoom crop, portrait blur, night lift + temporal denoise, macro
// sharpen). Real camera controls are applied through MediaStreamTrack constraints when the
// track offers them; everything else is emulated in the shader.
//
// Coordinates: "raw" = normalized 0..1 in the unmirrored camera frame, origin top-left.

const SEG_INTERVAL = 75; // ms between segmentations (~13 fps)
const SEG_LONG = 256; // long side of the segmentation input
const MAX_DPR = 2;

const clamp = (v, a, b) => Math.min(b, Math.max(a, v));

// ---------------------------------------------------------------- shaders
const VS = `#version 300 es
out vec2 vUv;
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  vUv = p;
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`;

const FS_DENOISE = `#version 300 es
precision highp float;
in vec2 vUv; out vec4 o;
uniform sampler2D uCur, uPrev;
uniform float uBlend; // weight of the current frame (1 = no denoise)
void main() {
  vec3 c = texture(uCur, vUv).rgb;
  vec3 p = texture(uPrev, vUv).rgb;
  float a = mix(uBlend, 1.0, smoothstep(0.07, 0.22, length(c - p)));
  o = vec4(mix(p, c, a), 1.0);
}`;

const FS_BLUR = `#version 300 es
precision highp float;
in vec2 vUv; out vec4 o;
uniform sampler2D uTex;
uniform vec2 uDir;
void main() {
  vec3 s = texture(uTex, vUv).rgb * 0.227027;
  s += (texture(uTex, vUv + uDir * 1.3846).rgb + texture(uTex, vUv - uDir * 1.3846).rgb) * 0.3162162;
  s += (texture(uTex, vUv + uDir * 3.2308).rgb + texture(uTex, vUv - uDir * 3.2308).rgb) * 0.0702703;
  o = vec4(s, 1.0);
}`;

const FS_MAIN = `#version 300 es
precision highp float;
in vec2 vUv; out vec4 o;
uniform sampler2D uSrc, uBlur, uMask;
uniform vec2 uScale, uCenter, uTexel, uMaskTexel, uSubject;
uniform float uZoom, uMirror, uFlipY, uAspect;
uniform float uGain, uWarmth, uPortrait, uNight, uMacro, uMaskMix;

vec3 knee(vec3 x) {
  const float k = 0.78;
  vec3 over = max(x - k, 0.0);
  return min(x, vec3(k)) + over / (1.0 + over / (1.0 - k));
}

float maskAt(vec2 uv) {
  vec2 d = uMaskTexel * 1.6;
  float m = texture(uMask, uv).r * 0.4;
  m += texture(uMask, uv + vec2(d.x, d.y)).r * 0.15;
  m += texture(uMask, uv + vec2(-d.x, d.y)).r * 0.15;
  m += texture(uMask, uv + vec2(d.x, -d.y)).r * 0.15;
  m += texture(uMask, uv + vec2(-d.x, -d.y)).r * 0.15;
  return smoothstep(0.22, 0.78, m);
}

void main() {
  vec2 s = vec2(vUv.x, uFlipY > 0.5 ? 1.0 - vUv.y : vUv.y);
  if (uMirror > 0.5) s.x = 1.0 - s.x;
  vec2 uv = uCenter + (s - 0.5) * uScale / uZoom;
  vec3 c = texture(uSrc, uv).rgb;

  if (uMacro > 0.001) {
    vec2 d = uTexel * 1.3;
    vec3 n = texture(uSrc, uv + vec2(d.x, 0.0)).rgb + texture(uSrc, uv - vec2(d.x, 0.0)).rgb
           + texture(uSrc, uv + vec2(0.0, d.y)).rgb + texture(uSrc, uv - vec2(0.0, d.y)).rgb;
    c = clamp(c + uMacro * 0.85 * (c - n * 0.25), 0.0, 1.0);
  }

  float subj = 1.0;
  if (uPortrait > 0.001) {
    vec2 q = (uv - uSubject) * vec2(uAspect, 1.0);
    float radial = 1.0 - smoothstep(0.14, 0.52, length(q));
    subj = mix(radial, maskAt(uv), uMaskMix);
    vec3 b = texture(uBlur, uv).rgb;
    c = mix(c, b, uPortrait * (1.0 - subj));
  }

  vec3 l = c * c; // ~linear
  l *= uGain;
  l *= vec3(1.0 + 0.15 * uWarmth, 1.0 + 0.02 * uWarmth, 1.0 - 0.17 * uWarmth);
  if (uPortrait > 0.001) l *= 1.0 + uPortrait * (0.16 * subj - 0.12 * (1.0 - subj));
  l = mix(l, knee(l), clamp((uGain - 1.0) * 4.0 + uPortrait * 0.5, 0.0, 1.0));
  vec3 g = sqrt(max(l, 0.0));

  if (uNight > 0.001) {
    vec3 lifted = 1.0 - pow(1.0 - clamp(g, 0.0, 1.0), vec3(2.1));
    g = mix(g, lifted, uNight * 0.75);
    float y = dot(g, vec3(0.2126, 0.7152, 0.0722));
    g = mix(g, vec3(y), uNight * 0.2) * mix(vec3(1.0), vec3(0.97, 0.99, 1.04), uNight);
  }
  o = vec4(clamp(g, 0.0, 1.0), 1.0);
}`;

// ---------------------------------------------------------------- springs
// Critically damped spring: smooth start, no overshoot, settles in ~450 ms.
function spring(value, omega = 11) {
  return {
    x: value, v: 0, t: value, omega,
    step(dt) {
      const k = this.omega * this.omega;
      const c = 2 * this.omega;
      const a = k * (this.t - this.x) - c * this.v;
      this.v += a * dt;
      this.x += this.v * dt;
      if (Math.abs(this.t - this.x) < 1e-4 && Math.abs(this.v) < 1e-4) { this.x = this.t; this.v = 0; }
    },
    get moving() { return this.x !== this.t; },
  };
}

// ---------------------------------------------------------------- GL helpers
function compile(gl, vs, fs) {
  const mk = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  };
  const p = gl.createProgram();
  gl.attachShader(p, mk(gl.VERTEX_SHADER, vs));
  gl.attachShader(p, mk(gl.FRAGMENT_SHADER, fs));
  gl.linkProgram(p);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
  const u = {};
  const n = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS);
  for (let i = 0; i < n; i++) {
    const name = gl.getActiveUniform(p, i).name;
    u[name] = gl.getUniformLocation(p, name);
  }
  return { p, u };
}

function makeTex(gl, w, h, { internal = gl.RGBA8, format = gl.RGBA, data = null } = {}) {
  const t = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, t);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  if (w && h) gl.texImage2D(gl.TEXTURE_2D, 0, internal, w, h, 0, format, gl.UNSIGNED_BYTE, data);
  return t;
}

function makeTarget(gl, w, h) {
  const tex = makeTex(gl, w, h);
  const fb = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  return { tex, fb, w, h };
}

function freeTarget(gl, t) {
  if (!t) return;
  gl.deleteTexture(t.tex);
  gl.deleteFramebuffer(t.fb);
}

// ---------------------------------------------------------------- viewfinder
export function createViewfinder({ canvas, video }) {
  const gl = canvas.getContext('webgl2', { alpha: false, antialias: false, premultipliedAlpha: false, preserveDrawingBuffer: false });
  const fallback = !gl;
  if (fallback) video.classList.add('vf-fallback');

  let progMain, progBlur, progDenoise, videoTex, maskTex;
  let accum = [null, null], accumIdx = 0, accumValid = false;
  let blurA = null, blurB = null;
  let texW = 0, texH = 0;
  let newFrame = true;
  let mirrored = true;
  let track = null;
  let caps = { zoom: false, exposure: false, iso: false, shutter: false, focus: false, wb: false, torch: false };
  let rawCaps = {};
  let hw = { zoom: 1 };

  const p = {
    gain: spring(1), warmth: spring(0), zoom: spring(1), cx: spring(0.5), cy: spring(0.5),
    portrait: spring(0, 9), night: spring(0, 9), macro: spring(0, 9), maskMix: spring(0, 6),
    sx: spring(0.5, 7), sy: spring(0.45, 7),
  };
  const springs = Object.values(p);
  let target = null; // last CamState seen

  if (!fallback) {
    progMain = compile(gl, VS, FS_MAIN);
    progBlur = compile(gl, VS, FS_BLUR);
    progDenoise = compile(gl, VS, FS_DENOISE);
    videoTex = makeTex(gl, 0, 0);
    maskTex = makeTex(gl, 1, 1, { internal: gl.R8, format: gl.RED, data: new Uint8Array([255]) });
    gl.bindVertexArray(gl.createVertexArray());
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  }

  // ---- canvas size
  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, MAX_DPR);
    const w = Math.max(1, Math.round(canvas.clientWidth * dpr));
    const h = Math.max(1, Math.round(canvas.clientHeight * dpr));
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
  }
  new ResizeObserver(resize).observe(canvas);
  resize();

  function ensureTargets(w, h) {
    if (w === texW && h === texH) return;
    texW = w; texH = h;
    accum.forEach((t) => freeTarget(gl, t));
    freeTarget(gl, blurA); freeTarget(gl, blurB);
    accum = [makeTarget(gl, w, h), makeTarget(gl, w, h)];
    accumValid = false;
    const bw = Math.max(16, Math.round(w / 4)), bh = Math.max(16, Math.round(h / 4));
    blurA = makeTarget(gl, bw, bh);
    blurB = makeTarget(gl, bw, bh);
  }

  // ---- geometry: screen <-> raw
  function coverScale(outW, outH) {
    const vw = video.videoWidth || 16, vh = video.videoHeight || 9;
    const ac = outW / outH, av = vw / vh;
    return ac > av ? [1, av / ac] : [ac / av, 1];
  }
  function cropCenter(scale, zoom) {
    const hx = (0.5 * scale[0]) / zoom, hy = (0.5 * scale[1]) / zoom;
    return [clamp(p.cx.x, hx, 1 - hx), clamp(p.cy.x, hy, 1 - hy)];
  }
  function screenToRaw(clientX, clientY) {
    const r = canvas.getBoundingClientRect();
    let sx = (clientX - r.left) / r.width, sy = (clientY - r.top) / r.height;
    if (mirrored) sx = 1 - sx;
    const sc = coverScale(r.width, r.height);
    const z = p.zoom.x;
    const [cx, cy] = cropCenter(sc, z);
    return { x: clamp(cx + ((sx - 0.5) * sc[0]) / z, 0, 1), y: clamp(cy + ((sy - 0.5) * sc[1]) / z, 0, 1) };
  }
  function rawToScreen(x, y) {
    const r = canvas.getBoundingClientRect();
    const sc = coverScale(r.width, r.height);
    const z = p.zoom.x;
    const [cx, cy] = cropCenter(sc, z);
    let sx = 0.5 + ((x - cx) * z) / sc[0];
    const sy = 0.5 + ((y - cy) * z) / sc[1];
    if (mirrored) sx = 1 - sx;
    return { x: r.left + sx * r.width, y: r.top + sy * r.height };
  }

  // ---- state -> targets
  function setTarget(s) {
    target = s;
    const mode = s.mode;
    const macro = mode === 'macro' ? 1 : 0;
    if (caps.zoom) hw.zoom = clamp(s.zoom || 1, Math.max(rawCaps.zoom.min, 1), rawCaps.zoom.max);
    const hwZ = caps.zoom ? hw.zoom : 1;
    const zoom = Math.max(1, (s.zoom || 1) / hwZ) * (1 + 0.18 * macro);
    p.zoom.t = zoom;
    const f = s.focus || { x: 0.5, y: 0.5 };
    const k = clamp((zoom - 1) * 2, 0, 1);
    p.cx.t = 0.5 + (f.x - 0.5) * k;
    p.cy.t = 0.5 + (f.y - 0.5) * k;
    p.sx.t = s.focus ? f.x : 0.5;
    p.sy.t = s.focus ? f.y : 0.45;

    let ev = 0;
    if (!caps.exposure) ev += s.exposure || 0;
    if (!caps.iso && s.iso) ev += clamp(Math.log2(s.iso / 200) * 0.6, -1.5, 1.5);
    if (!caps.shutter && s.shutter) ev += clamp(Math.log2(s.shutter * 60) * 0.6, -1.5, 1.5);
    if (mode === 'night') ev += 0.35;
    p.gain.t = Math.pow(2, clamp(ev, -2.5, 2.5));
    p.warmth.t = caps.wb ? 0 : clamp(s.warmth || 0, -1, 1);
    p.portrait.t = mode === 'portrait' ? 1 : 0;
    p.night.t = mode === 'night' ? 1 : 0;
    p.macro.t = macro;
    if (mode === 'portrait') ensureSegmenter();
    scheduleHw();
  }

  // ---- hardware constraints (throttled, latest wins)
  let hwBusy = false, hwDirty = false, lastTorch = false;
  function scheduleHw() {
    if (!track || !target) return;
    hwDirty = true;
    if (!hwBusy) flushHw();
  }
  async function flushHw() {
    hwBusy = true;
    while (hwDirty && track) {
      hwDirty = false;
      const s = target, c = rawCaps, adv = {};
      if (caps.zoom) adv.zoom = hw.zoom;
      if (caps.exposure) {
        if (c.exposureMode?.includes('continuous') && !(caps.iso && s.iso) && !(caps.shutter && s.shutter)) adv.exposureMode = 'continuous';
        adv.exposureCompensation = clamp(s.exposure || 0, c.exposureCompensation.min, c.exposureCompensation.max);
      }
      if ((caps.iso && s.iso) || (caps.shutter && s.shutter)) {
        adv.exposureMode = 'manual';
        if (caps.iso && s.iso) adv.iso = clamp(s.iso, c.iso.min, c.iso.max);
        if (caps.shutter && s.shutter) adv.exposureTime = clamp(s.shutter * 10000, c.exposureTime.min, c.exposureTime.max); // 100 µs units
      }
      if (caps.focus && s.focus) {
        adv.pointsOfInterest = [{ x: s.focus.x, y: s.focus.y }];
        adv.focusMode = c.focusMode.includes('single-shot') ? 'single-shot' : 'continuous';
      }
      if (caps.wb) {
        if (Math.abs(s.warmth || 0) < 0.02) adv.whiteBalanceMode = 'continuous';
        else {
          adv.whiteBalanceMode = 'manual';
          adv.colorTemperature = clamp(5500 + (s.warmth || 0) * 2200, c.colorTemperature.min, c.colorTemperature.max);
        }
      }
      const torch = caps.torch && s.flash === 'on' && torchWanted;
      if (caps.torch && torch !== lastTorch) { adv.torch = torch; lastTorch = torch; }
      if (Object.keys(adv).length) {
        try { await track.applyConstraints({ advanced: [adv] }); } catch (e) { console.warn('[cam] applyConstraints', e?.message || e); }
      }
      await new Promise((r) => setTimeout(r, 90));
    }
    hwBusy = false;
  }
  let torchWanted = false;
  async function setTorch(on) {
    torchWanted = on;
    scheduleHw();
  }

  function readCaps() {
    rawCaps = {};
    try { rawCaps = track?.getCapabilities?.() || {}; } catch { rawCaps = {}; }
    const sup = navigator.mediaDevices?.getSupportedConstraints?.() || {};
    const range = (k) => !!(rawCaps[k] && typeof rawCaps[k].max === 'number' && rawCaps[k].max > rawCaps[k].min);
    caps = {
      zoom: range('zoom') && rawCaps.zoom.max > 1,
      exposure: range('exposureCompensation'),
      iso: range('iso') && !!rawCaps.exposureMode?.includes('manual'),
      shutter: range('exposureTime') && !!rawCaps.exposureMode?.includes('manual'),
      focus: !!(sup.pointsOfInterest && rawCaps.focusMode?.length),
      wb: range('colorTemperature') && !!rawCaps.whiteBalanceMode?.includes('manual'),
      torch: rawCaps.torch === true || (Array.isArray(rawCaps.torch) && rawCaps.torch.includes(true)),
    };
    hw.zoom = 1;
    return caps;
  }

  // ---- attach a stream
  // `facing` overrides what the track reports: desktop cameras (built-in, USB, an iPhone via
  // Continuity Camera) usually report no facingMode, so the caller decides from the device label.
  async function attach(stream, { facing = null } = {}) {
    track = stream.getVideoTracks()[0] || null;
    const settings = track?.getSettings?.() || {};
    const facingNow = facing || (settings.facingMode === 'environment' ? 'environment' : 'user');
    mirrored = facingNow !== 'environment';
    video.srcObject = stream;
    video.muted = true;
    try { await video.play(); } catch (e) { console.warn('[cam] video.play', e?.message || e); }
    if (!video.videoWidth) await new Promise((r) => video.addEventListener('loadedmetadata', r, { once: true }));
    readCaps();
    accumValid = false;
    if (target) setTarget(target);
    canvas.classList.toggle('mirrored', mirrored);
    video.classList.toggle('mirrored', mirrored);
    return { caps: { ...caps }, mirrored, facing: facingNow, rawCaps, settings };
  }

  // ---- video frame tracking
  function watchFrames() {
    if (!video.requestVideoFrameCallback) { newFrame = true; return; }
    const cb = () => { newFrame = true; video.requestVideoFrameCallback(cb); };
    video.requestVideoFrameCallback(cb);
  }
  watchFrames();

  // ---- portrait segmentation (MediaPipe, lazy)
  let seg = null, segLoading = false, segFailed = false, lastSeg = 0, lastPerson = 0;
  let maskBuf = null, maskW = 0, maskH = 0;
  const segCanvas = document.createElement('canvas');
  const segCtx = segCanvas.getContext('2d', { willReadFrequently: false });

  async function ensureSegmenter() {
    if (seg || segLoading || segFailed || fallback) return;
    segLoading = true;
    try {
      const { ImageSegmenter, FilesetResolver } = await import('@mediapipe/tasks-vision');
      const files = await FilesetResolver.forVisionTasks('/cam/mediapipe');
      const opts = (delegate) => ({
        baseOptions: { modelAssetPath: '/cam/models/selfie_segmenter.tflite', delegate },
        runningMode: 'VIDEO', outputConfidenceMasks: true, outputCategoryMask: false,
      });
      try { seg = await ImageSegmenter.createFromOptions(files, opts('GPU')); }
      catch { seg = await ImageSegmenter.createFromOptions(files, opts('CPU')); }
    } catch (e) {
      segFailed = true;
      console.warn('[cam] segmenter unavailable, using radial portrait blur', e?.message || e);
    }
    segLoading = false;
  }

  function runSegmentation(now) {
    if (!seg || p.portrait.t < 0.5 || now - lastSeg < SEG_INTERVAL) return;
    lastSeg = now;
    const vw = video.videoWidth, vh = video.videoHeight;
    const s = SEG_LONG / Math.max(vw, vh);
    const w = Math.round(vw * s), h = Math.round(vh * s);
    if (segCanvas.width !== w || segCanvas.height !== h) { segCanvas.width = w; segCanvas.height = h; }
    segCtx.drawImage(video, 0, 0, w, h);
    let res;
    try { res = seg.segmentForVideo(segCanvas, now); } catch (e) { console.warn('[cam] segment', e?.message || e); return; }
    const m = res?.confidenceMasks?.[0];
    if (!m) return;
    const f = m.getAsFloat32Array();
    const mw = m.width, mh = m.height;
    if (!maskBuf || maskW !== mw || maskH !== mh) { maskBuf = new Uint8Array(mw * mh); maskW = mw; maskH = mh; }
    let on = 0;
    for (let i = 0; i < f.length; i++) {
      const v = f[i];
      if (v > 0.5) on++;
      maskBuf[i] = (maskBuf[i] * 0.35 + v * 255 * 0.65) | 0;
    }
    res.close?.();
    if (on / f.length > 0.025) lastPerson = now;
    p.maskMix.t = now - lastPerson < 600 ? 1 : 0;
    gl.bindTexture(gl.TEXTURE_2D, maskTex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, mw, mh, 0, gl.RED, gl.UNSIGNED_BYTE, maskBuf);
  }

  // ---- passes
  function pass(prog, fb, w, h) {
    gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.viewport(0, 0, w, h);
    gl.useProgram(prog.p);
  }
  function bindTex(unit, tex, loc) {
    gl.activeTexture(gl.TEXTURE0 + unit);
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.uniform1i(loc, unit);
  }

  function processFrame() {
    gl.bindTexture(gl.TEXTURE_2D, videoTex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, video);
    let src = videoTex;
    if (p.night.x > 0.01) {
      const prev = accum[accumIdx], next = accum[1 - accumIdx];
      pass(progDenoise, next.fb, texW, texH);
      bindTex(0, videoTex, progDenoise.u.uCur);
      bindTex(1, accumValid ? prev.tex : videoTex, progDenoise.u.uPrev);
      gl.uniform1f(progDenoise.u.uBlend, 1 - 0.72 * p.night.x);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      accumIdx = 1 - accumIdx;
      accumValid = true;
      src = next.tex;
    } else accumValid = false;
    if (p.portrait.x > 0.01) {
      const steps = [[1, 0, src, blurA], [0, 1, blurA.tex, blurB], [2.2, 0, blurB.tex, blurA], [0, 2.2, blurA.tex, blurB]];
      for (const [dx, dy, from, to] of steps) {
        pass(progBlur, to.fb, to.w, to.h);
        bindTex(0, from, progBlur.u.uTex);
        gl.uniform2f(progBlur.u.uDir, dx / to.w, dy / to.h);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
      }
    }
    return src;
  }

  let srcTex = null;
  function drawMain(fb, w, h, { still = false } = {}) {
    pass(progMain, fb, w, h);
    const u = progMain.u;
    const sc = still ? [1, 1] : coverScale(w, h);
    const z = p.zoom.x;
    const [cx, cy] = cropCenter(sc, z);
    bindTex(0, srcTex || videoTex, u.uSrc);
    bindTex(1, blurB ? blurB.tex : videoTex, u.uBlur);
    bindTex(2, maskTex, u.uMask);
    gl.uniform2f(u.uScale, sc[0], sc[1]);
    gl.uniform2f(u.uCenter, cx, cy);
    gl.uniform2f(u.uTexel, 1 / texW, 1 / texH);
    gl.uniform2f(u.uMaskTexel, 1 / Math.max(maskW, 1), 1 / Math.max(maskH, 1));
    gl.uniform2f(u.uSubject, p.sx.x, p.sy.x);
    gl.uniform1f(u.uZoom, z);
    gl.uniform1f(u.uMirror, mirrored ? 1 : 0);
    gl.uniform1f(u.uFlipY, still ? 0 : 1);
    gl.uniform1f(u.uAspect, texW / texH);
    gl.uniform1f(u.uGain, p.gain.x);
    gl.uniform1f(u.uWarmth, p.warmth.x);
    gl.uniform1f(u.uPortrait, p.portrait.x);
    gl.uniform1f(u.uNight, p.night.x);
    gl.uniform1f(u.uMacro, p.macro.x);
    gl.uniform1f(u.uMaskMix, maskW ? p.maskMix.x : 0);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  let last = performance.now();
  let listeners = [];
  function loop(now) {
    const dt = Math.min(0.05, Math.max(0, (now - last) / 1000));
    last = now;
    for (const s of springs) s.step(dt);
    if (!fallback && video.readyState >= 2 && video.videoWidth) {
      ensureTargets(video.videoWidth, video.videoHeight);
      if (newFrame || !srcTex) {
        srcTex = processFrame();
        newFrame = !video.requestVideoFrameCallback;
      }
      runSegmentation(now);
      drawMain(null, canvas.width, canvas.height);
    }
    for (const fn of listeners) fn(now);
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(loop);

  // ---- frames out
  const grabCanvas = document.createElement('canvas');
  const grabCtx = grabCanvas.getContext('2d');
  function grabFrame(maxSide = 768, quality = 0.7) {
    const vw = video.videoWidth, vh = video.videoHeight;
    if (!vw || !vh || video.readyState < 2) return Promise.resolve(null);
    const s = Math.min(1, maxSide / Math.max(vw, vh));
    const w = Math.round(vw * s), h = Math.round(vh * s);
    if (grabCanvas.width !== w || grabCanvas.height !== h) { grabCanvas.width = w; grabCanvas.height = h; }
    grabCtx.drawImage(video, 0, 0, w, h);
    return new Promise((r) => grabCanvas.toBlob((b) => r(b), 'image/jpeg', quality));
  }

  // Processed still at full video resolution, same look as the preview (mirrored like the preview).
  async function renderStill(quality = 0.92) {
    const vw = video.videoWidth, vh = video.videoHeight;
    if (!vw) return null;
    const out = document.createElement('canvas');
    out.width = vw; out.height = vh;
    if (fallback) {
      const c = out.getContext('2d');
      if (mirrored) { c.translate(vw, 0); c.scale(-1, 1); }
      c.drawImage(video, 0, 0, vw, vh);
    } else {
      ensureTargets(vw, vh);
      srcTex = processFrame();
      const t = makeTarget(gl, vw, vh);
      drawMain(t.fb, vw, vh, { still: true });
      const px = new Uint8Array(vw * vh * 4);
      gl.readPixels(0, 0, vw, vh, gl.RGBA, gl.UNSIGNED_BYTE, px);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      freeTarget(gl, t);
      out.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(px.buffer), vw, vh), 0, 0);
    }
    const blob = await new Promise((r) => out.toBlob(r, 'image/jpeg', quality));
    return { blob, width: vw, height: vh };
  }

  return {
    attach,
    setTarget,
    grabFrame,
    renderStill,
    screenToRaw,
    rawToScreen,
    setTorch,
    onFrame(fn) { listeners.push(fn); return () => { listeners = listeners.filter((f) => f !== fn); }; },
    get caps() { return { ...caps }; },
    get rawCaps() { return rawCaps; },
    get mirrored() { return mirrored; },
    get track() { return track; },
    get webgl() { return !fallback; },
    get segmenter() { return seg ? 'mediapipe' : segFailed ? 'failed' : segLoading ? 'loading' : 'off'; },
    get personInFrame() { return p.maskMix.t > 0.5; },
    videoSize() { return { w: video.videoWidth, h: video.videoHeight }; },
  };
}
