// Looks: Gemini 4 Neon writes a Metal shader for a spoken look, the phone compiles it, and the
// photo changes live. A scripted ~14 s replay of the app's Looks tab (PR #49, ShaderLab.swift):
// the request, the body streaming into a tinted pane with a cursor and Neon's violet light, one
// failed compile (amber pulse, the error, the line retyped), a violet flash, then the look
// crossfades in over 0.7 s. The bodies are the app's real preset code (presets.js), and the photo
// is rendered by their GLSL ports, so what you see is that shader's look.
// Text-free (DESIGN_V5.md): no copy column. The section title (TITLES.looks) and Neon's chip (id and
// role) above a large, centred frame that feathers into the ink; the request chip is the only other
// words.
//
//   const { destroy } = mountLooks(sectionEl, CHAPTERS.find((c) => c.id === 'looks'));
//
// From `chapter` it uses only steps[0].text (the first request) and the lede (screen readers).
// Pauses off screen; under prefers-reduced-motion it shows the finished state (code plus the
// applied look) without typing.
import './looks.css';
import { MODELS, TITLES } from '../config.js';
import { sectionTitle } from '../title/title.js';
import { PRESETS, BODY_LINE, IDENTITY_GLSL, VERTEX, fragment } from './presets.js';

const PHOTO = { src: '/showcase/img-1491.webp', w: 2048, h: 1536 };
const DPR_CAP = 1.75;
const FADE = 0.7; // LabRenderer.fade

// Loop timeline, in seconds: say it, Neon writes, compile, live.
const T = {
  chip: 0.3,
  open: 1.2,
  typeStart: 1.45,
  typeEnd: 5.45, // ~4 s to stream the body
  error: 5.6,
  erase: 5.95,
  retype: 6.25,
  fixed: 6.85, // compiled: violet flash, crossfade starts (ShaderLab swaps on `serial`)
  collapse: 7.55, // the app folds the pane 0.7 s after ready
  out: 13.5,
  end: 14,
};
const STILL_T = 9; // the finished state shown under reduced motion

/* ---------- code tint (ShaderLab.swift CodeTint) ---------- */

const KEYWORD = /^(float[234]?(x[234])?|half[234]?|int[234]?|uint|bool|const|constexpr|return|for|if|else|while|break|continue)$/;
const TOKEN = /\/\/.*|\d+(?:\.\d+)?|[A-Za-z_][A-Za-z0-9_]*|\s+|[^\sA-Za-z0-9_]/g;

function tokenClass(tok, next) {
  if (tok.startsWith('//')) return 'lk-t-com';
  if (/^\d/.test(tok)) return 'lk-t-num';
  if (KEYWORD.test(tok)) return 'lk-t-kw';
  if (/^[a-z_]/.test(tok) && next === '(') return 'lk-t-fn';
  return '';
}

const h = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
};

// One line of code as token spans, indented with a hanging wrap.
function buildLine(text) {
  const indent = text.match(/^ */)[0].length;
  const line = h('span', 'lk-ln');
  line.style.paddingLeft = `${indent + 2}ch`;
  line.style.textIndent = '-2ch';
  const src = text.slice(indent);
  const toks = [];
  let m;
  TOKEN.lastIndex = 0;
  while ((m = TOKEN.exec(src))) {
    const tok = m[0];
    const span = h('span', tokenClass(tok, src[m.index + tok.length]), tok);
    span.hidden = true;
    line.append(span);
    toks.push(span);
  }
  line.hidden = true;
  return { line, toks };
}

// A deterministic stream: tokens grouped into small irregular chunks, like streamed deltas.
function chunkTimes(count, start, end, seed) {
  let r = seed;
  const rand = () => ((r = (r * 1664525 + 1013904223) >>> 0) / 4294967296);
  const sizes = [];
  for (let left = count; left > 0; ) {
    const n = Math.min(left, 1 + Math.floor(rand() * 5));
    sizes.push(n);
    left -= n;
  }
  const gaps = sizes.map(() => 0.5 + rand() * (rand() < 0.12 ? 3 : 1));
  const total = gaps.reduce((a, b) => a + b, 0);
  const at = new Float32Array(count); // time each token appears
  let t = start;
  let i = 0;
  sizes.forEach((n, k) => {
    t += (gaps[k] / total) * (end - start);
    for (let j = 0; j < n; j++) at[i++] = t;
  });
  return at;
}

// The code pane for one preset: round 0 (with the broken line), then the fixed line.
function buildCode(preset, seed) {
  const b = preset.broken;
  const pre = h('code', 'lk-code__src');
  const stream = []; // round-0 tokens, in streaming order
  const lines = []; // { el, first }: a line shows once its first token has streamed
  let broken = null;
  let fixed = null;
  preset.metal.split('\n').forEach((text, i) => {
    const l = buildLine(i === b.line ? b.text : text);
    lines.push({ el: l.line, first: stream.length });
    if (i === b.line) {
      broken = { ...l, first: stream.length };
      l.line.classList.add('lk-ln--broken');
    }
    stream.push(...l.toks);
    pre.append(l.line);
    if (i === b.line) {
      fixed = buildLine(text);
      pre.append(fixed.line);
    }
  });
  return {
    pre,
    errAt: `program_source:${BODY_LINE + b.line}:${b.col}: `,
    errMsg: `error: ${b.error}`,
    stream,
    streamAt: chunkTimes(stream.length, T.typeStart, T.typeEnd, seed),
    lines: lines.filter((l) => l.el !== broken.line),
    broken,
    fixed,
    vis: new Uint8Array(stream.length + fixed.toks.length),
  };
}

/* ---------- WebGL2: the photo through the ported bodies ---------- */

function createRenderer(canvas, onFail) {
  const gl = canvas.getContext('webgl2', { alpha: false, antialias: false, premultipliedAlpha: false, preserveDrawingBuffer: false });
  if (!gl) throw new Error('WebGL2 unavailable');

  const compile = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(`shader compile: ${gl.getShaderInfoLog(s)}`);
    return s;
  };
  const vs = compile(gl.VERTEX_SHADER, VERTEX);
  const program = (body) => {
    const p = gl.createProgram();
    gl.attachShader(p, vs);
    gl.attachShader(p, compile(gl.FRAGMENT_SHADER, fragment(body)));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(`program link: ${gl.getProgramInfoLog(p)}`);
    const u = (n) => gl.getUniformLocation(p, n);
    return { p, src: u('src'), size: u('u_size'), t: u('u_t'), mix: u('u_mix'), crop: u('u_crop') };
  };
  const progs = { identity: program(IDENTITY_GLSL) };
  PRESETS.forEach((pr) => (progs[pr.id] = program(pr.glsl)));

  const vao = gl.createVertexArray();
  const tex = gl.createTexture();
  let ready = false;
  const crop = new Float32Array([0, 0, 1, 1]);

  const lost = (e) => {
    e.preventDefault();
    ready = false;
    onFail(new Error('WebGL context lost'));
  };
  canvas.addEventListener('webglcontextlost', lost);

  return {
    setImage(img) {
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false); // row 0 is the top, as uv is top-left
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, img); // no sRGB decode, like the app
      gl.generateMipmap(gl.TEXTURE_2D); // only the base `c` sample uses them; bodies read level 0
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      ready = true;
    },
    get ready() {
      return ready;
    },
    resize(w, h) {
      canvas.width = w;
      canvas.height = h;
      // cover-fit the photo into the canvas
      const ca = w / h;
      const ia = PHOTO.w / PHOTO.h;
      if (ca > ia) crop.set([0, (1 - ia / ca) / 2, 1, ia / ca]);
      else crop.set([(1 - ca / ia) / 2, 0, ca / ia, 1]);
    },
    // Draw `from` fully, then `to` over it at alpha `k` (smoothstepped), as LabRenderer.draw does.
    draw(from, to, k, t) {
      if (!ready || gl.isContextLost()) return;
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.bindVertexArray(vao);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, tex);
      const pass = (prog, mix) => {
        gl.useProgram(prog.p);
        gl.uniform1i(prog.src, 0);
        gl.uniform2f(prog.size, PHOTO.w, PHOTO.h);
        gl.uniform1f(prog.t, t);
        gl.uniform1f(prog.mix, mix);
        gl.uniform4fv(prog.crop, crop);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
      };
      gl.disable(gl.BLEND);
      if (k < 1) pass(progs[from], 1);
      if (k > 0) {
        gl.enable(gl.BLEND);
        gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        pass(progs[to], k * k * (3 - 2 * k));
      }
    },
    destroy() {
      canvas.removeEventListener('webglcontextlost', lost);
      Object.values(progs).forEach((pr) => gl.deleteProgram(pr.p));
      gl.deleteShader(vs);
      gl.deleteTexture(tex);
      gl.deleteVertexArray(vao);
      gl.getExtension('WEBGL_lose_context')?.loseContext();
    },
  };
}

/* ---------- mount ---------- */

export function mountLooks(el, chapter) {
  if (!chapter) throw new Error('mountLooks: missing chapter');
  const steps = chapter.steps || [];

  el.classList.add('looks');
  el.innerHTML = '';

  // the stage: the title and Neon's chip, then the photo in a frame that feathers into the ink
  const stage = h('div', 'lk-stage');
  const head = h('div', 'lk-head');
  const model = h('p', 'lk-model');
  model.setAttribute('aria-hidden', 'true');
  model.append(h('i'), h('span', 'lk-model__id', MODELS.neon.id), h('span', 'lk-model__role', MODELS.neon.role));
  head.append(sectionTitle(TITLES.looks), model);
  const media = h('div', 'lk-media');
  const aura = h('div', 'lk-aura'); // Neon's light around the frame while it writes
  const frame = h('figure', 'lk-frame');
  frame.setAttribute('role', 'img');
  frame.setAttribute('aria-label', chapter.lede || chapter.title || 'Gemini 4 Neon writes a Metal shader and the photo changes live.');
  const img = h('img', 'lk-photo');
  img.alt = '';
  img.decoding = 'async';
  img.width = PHOTO.w;
  img.height = PHOTO.h;
  const canvas = h('canvas', 'lk-canvas');
  canvas.setAttribute('aria-hidden', 'true');
  const shade = h('div', 'lk-shade');
  const pane = h('div', 'lk-pane');
  const paneHead = h('div', 'lk-pane__head');
  const status = h('span', 'lk-pane__status');
  paneHead.append(status);
  const body = h('div', 'lk-pane__body');
  const pre = h('pre', 'lk-code');
  body.append(pre);
  // the compiler's message, pinned under the code while Neon fixes it
  const err = h('div', 'lk-pane__err');
  const errAt = h('span', 'lk-pane__err-at');
  const errMsg = h('span');
  err.append(errAt, errMsg);
  pane.append(paneHead, body, err);
  const chip = h('div', 'lk-chip');
  frame.append(img, canvas, shade, pane, chip);
  [shade, pane, chip].forEach((n) => n.setAttribute('aria-hidden', 'true'));
  media.append(aura, frame);
  stage.append(head, media);
  el.append(stage);

  // per-preset code, built once; the first request is the chapter's own words
  const ask = steps[0]?.text?.replace(/^[“"]|[”"]$/g, '');
  const codes = PRESETS.map((p, i) => buildCode(p, 0x9e3779b9 ^ (i * 2654435761)));
  const requests = PRESETS.map((p, i) => (i === 0 && ask ? ask : p.request));
  const cursor = h('span', 'lk-cursor', '▍');

  /* ----- renderer ----- */

  let gl = null;
  let glFailed = false;
  const failGL = (err) => {
    glFailed = true;
    frame.classList.add('lk-frame--nogl');
    console.warn('[looks] WebGL look unavailable, showing the plain photo:', err);
  };
  try {
    gl = createRenderer(canvas, failGL);
  } catch (err) {
    failGL(err);
  }
  let alive = true;
  img.src = PHOTO.src;
  img
    .decode()
    .then(() => {
      if (!alive || !gl || glFailed) return;
      gl.setImage(img);
      sized = false;
      frame.classList.add('is-ready');
      paint(true);
    })
    .catch((err) => console.warn(`[looks] ${PHOTO.src} failed to load:`, err));

  /* ----- state ----- */

  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  let still = reduced.matches;
  let clock = 0; // seconds of loop time played; advances only while the frame is on screen
  let raf = 0;
  let last = 0;
  let sized = false;
  // what's on screen, so each frame only touches what changed
  const cur = { preset: -1, phase: '', status: '', cursorAt: null, scroll: 0 };
  const want = { from: 'identity', to: 'identity', k: 0 };
  const drawn = { from: '', to: '', k: -1 };

  function showPreset(i) {
    const c = codes[i];
    pre.replaceChildren(c.pre);
    errAt.textContent = c.errAt;
    errMsg.textContent = c.errMsg;
    chip.textContent = requests[i];
    cur.preset = i;
    cur.cursorAt = null;
    cur.scroll = 0;
    body.scrollTop = 0;
  }

  function setTok(c, i, tok, on) {
    if (c.vis[i] === +on) return;
    c.vis[i] = +on;
    tok.hidden = !on;
  }

  // Shows code `c` as it stands at loop time `t`; returns the node the cursor follows.
  function codeAt(c, t) {
    const n = c.stream.length;
    let shown = 0;
    while (shown < n && c.streamAt[shown] <= t) shown++;
    const { first: b0, toks: bt, line: bl } = c.broken;
    const ft = c.fixed.toks;
    const erased = t < T.erase ? 0 : Math.min(bt.length, Math.floor(((t - T.erase) / (T.retype - T.erase)) * bt.length));
    const typed = t < T.retype ? 0 : Math.min(ft.length, Math.ceil(((t - T.retype) / (T.fixed - 0.05 - T.retype)) * ft.length));
    const keep = bt.length - erased;
    for (let i = 0; i < n; i++) setTok(c, i, c.stream[i], i < shown && !(i >= b0 + keep && i < b0 + bt.length));
    for (let j = 0; j < ft.length; j++) setTok(c, n + j, ft[j], j < typed);
    for (const L of c.lines) if (L.el.hidden !== shown <= L.first) L.el.hidden = shown <= L.first;
    const brokenOn = shown > b0 && t < T.retype;
    if (bl.hidden === brokenOn) bl.hidden = !brokenOn;
    if (c.fixed.line.hidden !== t < T.retype) c.fixed.line.hidden = t < T.retype;
    bl.classList.toggle('is-flagged', t >= T.error);
    if (t < T.erase) return shown ? c.stream[shown - 1] : c.lines[0].el;
    if (t < T.retype) return keep ? bt[keep - 1] : bl;
    return typed ? ft[typed - 1] : c.fixed.line;
  }

  function phaseAt(t) {
    if (t < T.open) return 'ask';
    if (t < T.error) return 'writing';
    if (t < T.fixed) return 'fixing';
    if (t < T.fixed + 0.06) return 'flash';
    if (still || t < T.collapse) return 'compiled';
    return 'live';
  }
  const STATUS = { ask: '', writing: 'writing', fixing: 'fixing 1/2', flash: 'compiled', compiled: 'compiled', live: 'compiled' };

  function render(dt) {
    const loop = Math.floor(clock / T.end);
    const t = still ? STILL_T : clock - loop * T.end;
    const pi = still ? 0 : loop % PRESETS.length;
    if (pi !== cur.preset) showPreset(pi);

    // pane state and the request chip; the stage mirrors the phase for Neon's light around it
    const phase = phaseAt(t);
    if (phase !== cur.phase) {
      frame.dataset.phase = phase;
      stage.dataset.phase = phase;
      cur.phase = phase;
    }
    if (STATUS[phase] !== cur.status) status.textContent = cur.status = STATUS[phase];
    frame.classList.toggle('is-open', still || (t >= T.open && t < T.out));
    frame.classList.toggle('has-chip', still || (t >= T.chip && t < T.out));
    frame.classList.toggle('has-error', !still && t >= T.error && t < T.fixed);

    // code and cursor (shown while Neon is busy, as in the app)
    const c = codes[pi];
    const at = codeAt(c, t);
    const target = !still && t >= T.open && t < T.fixed ? at : null;
    if (target !== cur.cursorAt) {
      if (!target) cursor.remove();
      else if (target.classList.contains('lk-ln')) target.prepend(cursor);
      else target.after(cursor);
      cur.cursorAt = target;
    }

    // auto-scroll: ease toward the bottom of what's written, or to the line being fixed
    const max = Math.max(0, body.scrollHeight - body.clientHeight);
    let goal = max;
    if (!still && t >= T.error && t < T.collapse) {
      const line = t < T.retype ? c.broken.line : c.fixed.line;
      goal = Math.min(max, Math.max(0, line.offsetTop - (body.clientHeight - line.offsetHeight) * 0.5));
    }
    cur.scroll = dt > 0 ? cur.scroll + (goal - cur.scroll) * Math.min(1, dt * 9) : goal;
    if (Math.abs(body.scrollTop - cur.scroll) >= 0.5) body.scrollTop = cur.scroll;

    // the photo: the previous look, crossfading into this one once it compiles
    want.from = still || loop === 0 ? 'identity' : PRESETS[(loop - 1) % PRESETS.length].id;
    want.to = PRESETS[pi].id;
    want.k = still ? 1 : Math.min(1, Math.max(0, (t - T.fixed) / FADE));
    paint(false);
  }

  function paint(force) {
    if (!gl || glFailed || !gl.ready) return;
    if (!sized) resize();
    if (!force && want.from === drawn.from && want.to === drawn.to && want.k === drawn.k) return;
    gl.draw(want.from, want.to, want.k, 0);
    drawn.from = want.from;
    drawn.to = want.to;
    drawn.k = want.k;
  }

  function resize() {
    if (!gl || glFailed) return;
    // layout size, not the bounding box: the reveal scales the media while it rises in
    const cw = frame.clientWidth;
    const ch = frame.clientHeight;
    if (!cw || !ch) return;
    const dpr = Math.min(window.devicePixelRatio || 1, DPR_CAP);
    const w = Math.round(cw * dpr);
    const ht = Math.round(ch * dpr);
    if (w !== canvas.width || ht !== canvas.height) gl.resize(w, ht);
    sized = true;
  }

  /* ----- loop: plays while the frame is on screen ----- */

  function tick(now) {
    raf = 0;
    const dt = last ? Math.min(0.1, (now - last) / 1000) : 0;
    last = now;
    clock += dt;
    render(dt);
    raf = requestAnimationFrame(tick);
  }
  function start() {
    if (raf || still) return;
    last = 0;
    raf = requestAnimationFrame(tick);
  }
  function stop() {
    if (raf) cancelAnimationFrame(raf);
    raf = 0;
  }

  // start once a fifth of the frame is in view; pause when none of it is
  let onScreen = false;
  const playIO = new IntersectionObserver(
    (entries) => {
      const e = entries[entries.length - 1];
      if (e.intersectionRatio >= 0.2) onScreen = true;
      else if (!e.isIntersecting) onScreen = false;
      if (onScreen) start();
      else stop();
    },
    { threshold: [0, 0.2] },
  );
  // the stage rises in as it enters, as the page's own reveal does
  const revealIO = new IntersectionObserver(
    (entries) =>
      entries.forEach((e) => {
        if (e.isIntersecting) e.target.classList.add('is-in');
        else if (e.boundingClientRect.top > 0) e.target.classList.remove('is-in');
      }),
    { threshold: 0.12, rootMargin: '0px 0px -6% 0px' },
  );
  revealIO.observe(stage);
  playIO.observe(frame);

  const ro = new ResizeObserver(() => {
    sized = false;
    resize();
    paint(true);
  });
  ro.observe(frame);

  const onMotion = () => {
    still = reduced.matches;
    frame.classList.toggle('is-still', still);
    stage.classList.toggle('is-still', still);
    if (still) stop();
    else if (onScreen) start();
    render(0);
  };
  reduced.addEventListener('change', onMotion);
  frame.classList.toggle('is-still', still);
  stage.classList.toggle('is-still', still);
  render(0);

  return {
    destroy() {
      alive = false;
      stop();
      playIO.disconnect();
      revealIO.disconnect();
      ro.disconnect();
      reduced.removeEventListener('change', onMotion);
      gl?.destroy();
      gl = null;
      el.innerHTML = '';
      el.classList.remove('looks');
    },
  };
}
