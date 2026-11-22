// Link previews: og.mp4 (Messages autoplays an og:video that is a plain MP4) and the og.jpg /
// og-square.jpg stills. Dev only, like the section demos: open /src/og/demo.html to watch it, and
// `node src/og/render.mjs` to render the files into public/.
//
// The video, one 9 s loop, text-free (TN3156: the title and domain already sit under a preview):
//   0.0-0.3   out of ink, the LiDAR emitter glowing at the lens
//   0.3-2.8   the scan: a dot grid sweeps IMG_1491 and the points land in Gemini blue (lidar.js)
//   2.8-4.0   the camera swings round the cloud
//   4.0-6.0   into the photo: the points take the photo's colours and flatten onto it
//   6.4-7.4   Neon's look: the app's Kodachrome shader wipes across behind a violet seam
//   8.4-9.0   back into ink, where the loop starts again
// The 3D part is the landing's own LiDAR section (mountLidar), fed a scroll position. lidar.js
// schedules its frames with requestAnimationFrame, so this page takes requestAnimationFrame over
// and fires the queue itself: frame n is the same picture at any capture speed.
//
// The stills are one flat frame drawn here: the photo full-bleed, LiDAR's depth dots to the left
// of a scan seam and the photograph to the right, and the wordmark small in the corner.
import { mountLidar } from '../lidar/lidar.js';
import { PRESETS } from '../looks/presets.js';

export const FPS = 30;
export const DURATION = 9;

const PHOTO = { src: '/showcase/img-1491.webp', w: 2978, h: 2234 }; // capture aspect (lidar.js FRAME)
const DEPTH = '/showcase/img-1491_depth_packed.png'; // v = log nearness, 16 bits in R (high) + G (low)

// ---- the clock --------------------------------------------------------------------------------
const realRaf = window.requestAnimationFrame.bind(window);
const pending = new Map();
let rafId = 0;
let clockMs = 0;
window.requestAnimationFrame = (cb) => {
  pending.set(++rafId, cb);
  return rafId;
};
window.cancelAnimationFrame = (id) => pending.delete(id);
function tick(ms) {
  clockMs += ms;
  const due = [...pending.values()];
  pending.clear();
  for (const cb of due) cb(clockMs);
}

// ---- timeline ---------------------------------------------------------------------------------
const clamp = (x, a = 0, b = 1) => (x < a ? a : x > b ? b : x);
const remap = (x, a, b) => clamp((x - a) / (b - a));
const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
const smooth = (t) => t * t * (3 - 2 * t);

// lidar.js progress p: 0-0.35 the scan, 0.35-0.65 the turn (its distance labels are hidden here),
// 0.65-1 into the photo. Each segment is [t0, t1, p0, p1, easing].
const P_KEYS = [
  [0.0, 0.3, 0.02, 0.03, (x) => x],
  [0.3, 2.8, 0.03, 0.33, (x) => x],
  [2.8, 4.0, 0.33, 0.62, smooth],
  [4.0, 6.0, 0.62, 1.0, ease],
];
function progressAt(t) {
  for (const [t0, t1, p0, p1, f] of P_KEYS) if (t < t1) return p0 + (p1 - p0) * f(remap(t, t0, t1));
  return 1;
}
const WIPE = [6.4, 7.4]; // the look sweeps left to right across the photo
const INK_IN = 0.3; // the loop opens out of ink ...
const INK_OUT = [8.4, 9.0]; // ... and closes back into it

// ---- shaders -------------------------------------------------------------------------------------
const VS = `#version 300 es
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)) * 2.0 - 1.0;
  gl_Position = vec4(p, 0.0, 1.0);
}`;

const COMMON = `#version 300 es
precision highp float;
uniform sampler2D src;  // the photo, sRGB bytes as they are (no decode), like the app's sampler
uniform vec2 u_res;     // canvas, device px
uniform vec4 u_rect;    // the photo's box in device px, top-left origin: x, y, w, h
uniform float u_dpr;
out vec4 outColor;
const vec3 INK = vec3(5.0, 6.0, 11.0) / 255.0;
vec3 toLinear(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c)); }
vec3 toSrgb(vec3 c) { return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c)); }
vec2 fragTL() { return vec2(gl_FragCoord.x, u_res.y - gl_FragCoord.y); }
`;

// The video's look: the app's Kodachrome body over the photo, left of a violet seam at u_wipe.
const kodachrome = PRESETS.find((p) => p.id === 'kodachrome');
const LOOK_FS = `${COMMON}
uniform vec2 u_size;    // what look() calls size (the photo in css px)
uniform float u_feather, u_wipe;

vec4 look(vec4 c, vec2 uv, vec2 size, float t) {
${kodachrome.glsl}
}

void main() {
  vec2 uv = (fragTL() - u_rect.xy) / u_rect.zw;
  if (u_wipe < -0.5 || uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) { outColor = vec4(0.0); return; }
  vec3 lk = clamp(look(texture(src, uv), uv, u_size, 0.0).rgb, 0.0, 1.0);
  // lidar.js PHOTO_FRAG: the vignette in linear light, the feathered edge as coverage over the ink
  vec2 e = min(uv, 1.0 - uv);
  float edge = smoothstep(0.0, u_feather, e.x) * smoothstep(0.0, u_feather * 1.3333, e.y);
  vec2 q = (uv - 0.5) * vec2(1.0, 0.75) * 2.0;
  vec3 col = mix(INK, toSrgb(toLinear(lk) * (1.0 - 0.32 * smoothstep(0.35, 1.25, length(q)))), edge);
  float px = (uv.x - u_wipe) * u_rect.z / u_dpr; // css px from the seam
  float covered = 1.0 - smoothstep(-1.0, 1.0, px);
  float sweeping = smoothstep(-0.06, 0.0, u_wipe) * (1.0 - smoothstep(1.0, 1.06, u_wipe));
  float core = exp(-px * px / 4.5);
  float halo = exp(-abs(px) / 36.0) * 0.55;
  vec3 violet = vec3(0.604, 0.486, 0.965);
  vec3 light = (violet * halo + mix(violet, vec3(1.0), 0.6) * core) * sweeping * edge;
  outColor = vec4(col * covered + light, clamp(covered + (core + halo) * sweeping * edge, 0.0, 1.0));
}`;

// The still: LiDAR's depth dots left of the seam (lidar.js CLOUD_VERT's colours, seen head on),
// the photograph right of it.
const POSTER_FS = `${COMMON}
uniform sampler2D dmap; // packed depth, no colour conversion, nearest
uniform float u_seam;   // css px
uniform float u_cell;   // css px between dots
uniform vec3 u_near, u_mid, u_far; // linear

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float depthAt(vec2 uv) { vec4 k = texture(dmap, uv); return (k.r * 65280.0 + k.g * 255.0) / 65535.0; }

void main() {
  vec2 frag = fragTL();
  vec2 css = frag / u_dpr;
  vec2 uv = (frag - u_rect.xy) / u_rect.zw;
  vec3 photo = toLinear(texture(src, uv).rgb);

  // one jittered dot per cell, sized and coloured like a cloud point
  vec2 cell = floor(css / u_cell);
  vec2 j = vec2(hash(cell), hash(cell + 17.3)) - 0.5;
  vec2 ctr = (cell + 0.5 + j * 0.22) * u_cell;
  vec2 cuv = (ctr * u_dpr - u_rect.xy) / u_rect.zw;
  float d = depthAt(cuv);
  // like the scan, no return at a silhouette: drop the dot where the depth jumps (lidar.js EDGE_REL)
  vec2 o = 4.0 / vec2(textureSize(dmap, 0));
  float jump = max(max(abs(depthAt(cuv + vec2(o.x, 0.0)) - depthAt(cuv - vec2(o.x, 0.0))),
                       abs(depthAt(cuv + vec2(0.0, o.y)) - depthAt(cuv - vec2(0.0, o.y)))), 0.0);
  float keep = 1.0 - smoothstep(0.025, 0.05, jump);
  float lum = dot(toLinear(texture(src, cuv).rgb), vec3(0.2126, 0.7152, 0.0722));
  vec3 dc = mix(u_far, u_mid, smoothstep(0.3, 0.8, d));
  dc = mix(dc, u_near, smoothstep(0.84, 0.98, d));
  dc *= mix(0.12, 1.0, pow(d, 3.0)) * (0.4 + 1.0 * sqrt(lum));
  // nearer points are bigger, as they would be in perspective
  float r = mix(0.55, 1.15, smoothstep(0.35, 0.98, d)) * (0.85 + 0.3 * hash(cell + 5.1));
  float dist = length(css - ctr);
  float dotm = 1.0 - smoothstep(r - 0.5, r + 0.5, dist);
  float s = u_seam - css.x; // css px behind the scan front
  float band = exp(-s * s / 5000.0);
  vec3 cloud = (dc * (2.2 + band * 1.5) + u_near * band * 0.6) * dotm * keep * smoothstep(0.0, 0.16, d);
  cloud = 1.0 - exp(-cloud * 1.3); // roll off the near points so the figure keeps its texture

  // the photo, a touch lifted, and the seam: a frost core in a blue halo
  vec3 col = s > 0.0 ? cloud : photo * 1.06;
  float core = exp(-s * s / 2.0);
  float halo = exp(-abs(s) / 22.0) + 0.35 * exp(-abs(s) / 90.0);
  col += vec3(0.86, 0.9, 1.0) * core * 1.4 + u_mid * halo * 0.3;

  // frame vignette, and a little more ink under the wordmark (bottom left)
  vec2 q = frag / u_res - 0.5;
  col *= 1.0 - 0.55 * smoothstep(0.3, 0.85, length(q * vec2(1.0, 1.25)));
  vec2 m = (frag / u_res - vec2(0.0, 1.0)) * vec2(1.6, 2.6);
  col *= 1.0 - 0.45 * exp(-dot(m, m) * 2.2);
  outColor = vec4(toSrgb(col), 1.0);
}`;

// ---- the stage ----------------------------------------------------------------------------------
const section = document.getElementById('lidar');
mountLidar(section, { label: 'LiDAR · on device' });
const sticky = section.querySelector('.ld__sticky');
const ink = document.querySelector('.og-ink');
const mark = document.querySelector('.og-mark');

// Above the LiDAR canvas and under its vignette and edge fades. In the video it draws the look
// where lidar.js draws the photo once the camera is home (centred, the stage's full height, 4:3,
// the same feather and vignette), so only the seam moves. For the stills it draws everything.
const layerCanvas = document.createElement('canvas');
layerCanvas.className = 'og-look';
sticky.querySelector('.ld__canvas').after(layerCanvas);
const layer = makeLayer(layerCanvas);

function scrollTo(p) {
  const top = section.getBoundingClientRect().top + window.scrollY;
  window.scrollTo(0, top + p * (section.offsetHeight - window.innerHeight));
  window.dispatchEvent(new Event('scroll')); // lidar.js reads its target on scroll
}

const ready = Promise.all([
  layer.ready,
  new Promise((resolve) => {
    const check = () => (section.classList.contains('is-ready') ? resolve() : setTimeout(check, 50));
    check();
  }),
  document.fonts.ready,
]);

/** Frame `n` of the loop. Call in order from 0: lidar.js eases toward its target frame by frame. */
function frame(n) {
  const t = n / FPS;
  scrollTo(progressAt(t));
  tick(1000 / FPS / 2);
  tick(1000 / FPS / 2);
  layer.look(t < WIPE[0] ? -1 : -0.06 + 1.12 * ease(remap(t, WIPE[0], WIPE[1])));
  ink.style.opacity = String(Math.max(1 - remap(t, 0, INK_IN), smooth(remap(t, INK_OUT[0], INK_OUT[1]))));
  mark.style.opacity = '0';
}

/**
 * The still. `focus` is the photo point (u, v from the top left) kept at the frame's centre when
 * the photo is cover-fitted; `seam` is the scan seam's x as a fraction of the frame's width.
 */
function poster({ focus = [0.5, 0.62], seam = 0.445, lidar = null } = {}) {
  if (lidar !== null) {
    // or a moment of the LiDAR scene itself, held at progress `lidar`
    scrollTo(lidar);
    for (let i = 0; i < 120; i++) tick(1000 / FPS);
    layer.look(-1);
  } else {
    document.body.classList.add('is-still'); // its own vignette; lidar.js's overlays off
    layer.poster(focus, seam);
  }
  ink.style.opacity = '0';
  mark.style.opacity = '1';
}

// Live preview at real speed: /src/og/demo.html.
function play() {
  let n = 0;
  let last = 0;
  const loop = (ms) => {
    if (!last || ms - last >= 1000 / FPS - 1) {
      last = ms;
      frame(n);
      n = (n + 1) % (FPS * DURATION);
    }
    realRaf(loop);
  };
  realRaf(loop);
}

window.og = { ready, frame, poster, FPS, DURATION, play };

// ---- the layer ----------------------------------------------------------------------------------
function makeLayer(canvas) {
  const gl = canvas.getContext('webgl2', { premultipliedAlpha: true, antialias: false });
  const lookP = program(gl, VS, LOOK_FS);
  const posterP = program(gl, VS, POSTER_FS);
  const photoTex = texture(gl, gl.LINEAR);
  const depthTex = texture(gl, gl.NEAREST);

  const photo = new Image();
  photo.src = PHOTO.src;
  const ready = Promise.all([
    photo.decode().then(() => upload(gl, photoTex, photo)),
    fetch(DEPTH)
      .then((r) => {
        if (!r.ok) throw new Error(`og: depth ${r.status}`);
        return r.blob();
      })
      .then((b) => createImageBitmap(b, { colorSpaceConversion: 'none', premultiplyAlpha: 'none' }))
      .then((bmp) => upload(gl, depthTex, bmp)),
  ]);

  function begin(prog) {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const W = canvas.clientWidth;
    const H = canvas.clientHeight;
    const w = Math.round(W * dpr);
    const h = Math.round(H * dpr);
    if (canvas.width !== w || canvas.height !== h) Object.assign(canvas, { width: w, height: h });
    gl.viewport(0, 0, w, h);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    if (!prog) return null;
    gl.useProgram(prog.p);
    gl.uniform2f(prog.u('u_res'), w, h);
    gl.uniform1f(prog.u('u_dpr'), dpr);
    gl.uniform1i(prog.u('src'), 0);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, photoTex);
    return { W, H, dpr };
  }

  function look(wipe) {
    if (wipe < -0.5) return void begin(null);
    const { W, H, dpr } = begin(lookP);
    const u = lookP.u;
    // lidar.js layout() on desktop: the photo is min(H, 0.94 W * 0.75) tall, 4:3, centred
    const rh = Math.min(H, W * 0.94 * 0.75);
    const rw = rh * (PHOTO.w / PHOTO.h);
    gl.uniform4f(u('u_rect'), ((W - rw) / 2) * dpr, ((H - rh) / 2) * dpr, rw * dpr, rh * dpr);
    gl.uniform2f(u('u_size'), rw, rh);
    gl.uniform1f(u('u_feather'), W < 768 ? 0.06 : 0.12);
    gl.uniform1f(u('u_wipe'), wipe);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  function poster([fu, fv], seam) {
    const { W, H, dpr } = begin(posterP);
    const u = posterP.u;
    const s = Math.max(W / PHOTO.w, H / PHOTO.h);
    const rw = PHOTO.w * s;
    const rh = PHOTO.h * s;
    const x = clamp(W / 2 - fu * rw, W - rw, 0);
    const y = clamp(H / 2 - fv * rh, H - rh, 0);
    gl.uniform4f(u('u_rect'), x * dpr, y * dpr, rw * dpr, rh * dpr);
    gl.uniform1f(u('u_seam'), seam * W);
    gl.uniform1f(u('u_cell'), 3.2);
    const lin = (hex) => [0, 2, 4].map((i) => Math.pow(parseInt(hex.slice(i, i + 2), 16) / 255, 2.2));
    gl.uniform3f(u('u_near'), ...lin('7FB2FF'));
    gl.uniform3f(u('u_mid'), ...lin('4C8DFF'));
    gl.uniform3f(u('u_far'), ...lin('2B2F96'));
    gl.uniform1i(u('dmap'), 1);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, depthTex);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  return { ready, look, poster };
}

function texture(gl, filter) {
  const t = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, t);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  return t;
}

function upload(gl, tex, source) {
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.pixelStorei(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL, gl.NONE);
  gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, source);
}

function program(gl, vsrc, fsrc) {
  const sh = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(`og shader: ${gl.getShaderInfoLog(s)}`);
    return s;
  };
  const p = gl.createProgram();
  gl.attachShader(p, sh(gl.VERTEX_SHADER, vsrc));
  gl.attachShader(p, sh(gl.FRAGMENT_SHADER, fsrc));
  gl.linkProgram(p);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(`og link: ${gl.getProgramInfoLog(p)}`);
  const cache = new Map();
  const u = (n) => {
    if (!cache.has(n)) cache.set(n, gl.getUniformLocation(p, n));
    return cache.get(n);
  };
  return { p, u };
}
