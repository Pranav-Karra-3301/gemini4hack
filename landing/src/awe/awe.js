// "Dawn from orbit": a pinned, scroll-scrubbed WebGL2 section that leads into
// "Powered by Gemini 4". Usage: mountAwe(document.querySelector('#awe')).
import fragSrc from './awe.frag.glsl?raw';
import './awe.css';

const VERT = `#version 300 es
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`;

const DPR_CAP = 1.5;
const HOLD = 0.12;          // last 12% of the pin holds the finished frame
const REVEAL_FROM = 0.75;   // copy fades in over progress 0.75 -> 1

const clamp01 = (v) => Math.min(1, Math.max(0, v));
const smooth = (a, b, v) => {
  const t = clamp01((v - a) / (b - a));
  return t * t * (3 - 2 * t);
};

function compile(gl, type, src) {
  const sh = gl.createShader(type);
  gl.shaderSource(sh, src);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    const log = gl.getShaderInfoLog(sh);
    gl.deleteShader(sh);
    throw new Error(`awe: shader compile failed\n${log}`);
  }
  return sh;
}

function createProgram(gl) {
  const vs = compile(gl, gl.VERTEX_SHADER, VERT);
  const fs = compile(gl, gl.FRAGMENT_SHADER, fragSrc);
  const prog = gl.createProgram();
  gl.attachShader(prog, vs);
  gl.attachShader(prog, fs);
  gl.linkProgram(prog);
  gl.deleteShader(vs);
  gl.deleteShader(fs);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
    throw new Error(`awe: program link failed\n${gl.getProgramInfoLog(prog)}`);
  }
  return prog;
}

/**
 * Mounts the section into `sectionEl` (an empty <section> is ideal).
 * Returns { destroy(), progress } where progress is the smoothed 0..1 value.
 */
export function mountAwe(sectionEl) {
  sectionEl.classList.add('awe');

  const stage = document.createElement('div');
  stage.className = 'awe__stage';
  const canvas = document.createElement('canvas');
  canvas.className = 'awe__canvas';
  canvas.setAttribute('aria-hidden', 'true');
  const copy = document.createElement('div');
  copy.className = 'awe__copy';
  copy.innerHTML =
    '<h2 class="awe__title">Powered by Gemini 4</h2>' +
    '<p class="awe__sub">Every frame, every fader, every word, reasoned by Gemini 4.</p>';
  stage.append(canvas, copy);
  sectionEl.append(stage);

  const motionQuery = matchMedia('(prefers-reduced-motion: reduce)');
  let reduced = motionQuery.matches;

  let gl = null;
  let prog = null;
  let loc = {};
  let raf = 0;
  let visible = false;
  let lastNow = 0;
  const t0 = performance.now();
  let shown = 0;
  const ptr = { x: 0, y: 0, tx: 0, ty: 0 };
  let quality = 1;
  let slowFrames = 0;

  // Progress: 0 when the section's top meets the viewport top, 1 once the pinned
  // stage has travelled (1 - HOLD) of its sticky range. The rest holds the end frame.
  function readProgress() {
    const r = sectionEl.getBoundingClientRect();
    const span = r.height - stage.offsetHeight;
    if (span <= 0) return r.top <= 0 ? 1 : 0;
    return clamp01(-r.top / span / (1 - HOLD));
  }

  function setReveal(p) {
    copy.style.setProperty('--awe-reveal', smooth(REVEAL_FROM, 1, p).toFixed(4));
  }

  function initGL() {
    gl = canvas.getContext('webgl2', {
      antialias: false,
      alpha: false,
      depth: false,
      stencil: false,
      premultipliedAlpha: false,
      powerPreference: 'high-performance',
    });
    if (!gl) throw new Error('awe: WebGL2 unavailable');
    prog = createProgram(gl);
    gl.useProgram(prog);
    loc = {
      time: gl.getUniformLocation(prog, 'uTime'),
      res: gl.getUniformLocation(prog, 'uResolution'),
      progress: gl.getUniformLocation(prog, 'uProgress'),
      pointer: gl.getUniformLocation(prog, 'uPointer'),
    };
    gl.bindVertexArray(gl.createVertexArray());
  }

  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, DPR_CAP) * quality;
    const w = Math.max(1, Math.round(stage.clientWidth * dpr));
    const h = Math.max(1, Math.round(stage.clientHeight * dpr));
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
  }

  function draw(time, progress) {
    if (!gl || !prog || gl.isContextLost()) return;
    resize();
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.uniform1f(loc.time, time);
    gl.uniform2f(loc.res, canvas.width, canvas.height);
    gl.uniform1f(loc.progress, progress);
    gl.uniform2f(loc.pointer, ptr.x, ptr.y);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  function drawStatic() {
    shown = 1;
    setReveal(1);
    draw(0, 1);
  }

  function frame(now) {
    raf = 0;
    const dt = Math.min(0.1, lastNow ? (now - lastNow) / 1000 : 1 / 60);
    lastNow = now;

    // Heavy, cinematic scrub: progress and pointer ease toward their targets.
    const target = readProgress();
    shown += (target - shown) * (1 - Math.exp(-dt * 3.2));
    if (Math.abs(target - shown) < 1e-4) shown = target;
    const k = 1 - Math.exp(-dt * 1.4);
    ptr.x += (ptr.tx - ptr.x) * k;
    ptr.y += (ptr.ty - ptr.y) * k;

    // Drop resolution once if the GPU can't keep up.
    if (quality === 1 && dt > 0.028) {
      if (++slowFrames > 45) {
        quality = 0.7;
      }
    } else if (slowFrames > 0) {
      slowFrames--;
    }

    draw((now - t0) / 1000, shown);
    setReveal(shown);
    if (visible && !reduced) raf = requestAnimationFrame(frame);
  }

  function start() {
    if (raf || reduced || !gl) return;
    lastNow = 0;
    raf = requestAnimationFrame(frame);
  }

  function stop() {
    if (raf) cancelAnimationFrame(raf);
    raf = 0;
  }

  function applyMotionMode() {
    reduced = motionQuery.matches;
    sectionEl.classList.toggle('awe--static', reduced);
    if (reduced) {
      stop();
      drawStatic();
    } else {
      shown = readProgress();
      if (visible) start();
    }
  }

  const onPointer = (e) => {
    ptr.tx = (e.clientX / window.innerWidth) * 2 - 1;
    ptr.ty = -((e.clientY / window.innerHeight) * 2 - 1);
  };

  const onLost = (e) => {
    e.preventDefault();
    stop();
    prog = null;
  };
  const onRestored = () => {
    try {
      initGL();
      reduced ? drawStatic() : start();
    } catch (err) {
      console.error(err);
    }
  };

  try {
    initGL();
  } catch (err) {
    console.error(err);
    gl = null;
    sectionEl.classList.add('awe--fallback');
    setReveal(1);
  }

  const io = new IntersectionObserver(
    ([entry]) => {
      visible = entry.isIntersecting;
      visible ? start() : stop();
    },
    { rootMargin: '10% 0px' },
  );
  const ro = new ResizeObserver(() => {
    if (!gl) return;
    if (reduced) drawStatic();
    else if (!raf) draw((performance.now() - t0) / 1000, shown);
  });

  if (gl) {
    io.observe(sectionEl);
    ro.observe(stage);
    canvas.addEventListener('webglcontextlost', onLost);
    canvas.addEventListener('webglcontextrestored', onRestored);
    window.addEventListener('pointermove', onPointer, { passive: true });
    motionQuery.addEventListener('change', applyMotionMode);
    applyMotionMode();
  }

  return {
    get progress() {
      return shown;
    },
    destroy() {
      stop();
      io.disconnect();
      ro.disconnect();
      window.removeEventListener('pointermove', onPointer);
      motionQuery.removeEventListener('change', applyMotionMode);
      canvas.removeEventListener('webglcontextlost', onLost);
      canvas.removeEventListener('webglcontextrestored', onRestored);
      gl?.getExtension('WEBGL_lose_context')?.loseContext();
      stage.remove();
      sectionEl.classList.remove('awe', 'awe--static', 'awe--fallback');
    },
  };
}
