// GLSL for the footer sunrise. Three passes per frame:
//   1. OCCLUSION (quarter res): the sun and its glow, blocked by the flower and wordmark silhouettes.
//   2. RAYS (quarter res): a radial blur of pass 1 toward the sun, which turns gaps into god rays.
//   3. COMPOSITE (full res): sky, sun, rim-lit wordmark, three rim-lit flower layers, haze, rays, grain.
// Lighting is done in linear light and encoded to sRGB at the end. Palette from DESIGN_V4.md.

const lin = (hex) => {
  const n = parseInt(hex.slice(1), 16);
  const ch = (v) => {
    const c = v / 255;
    return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  };
  return `vec3(${[ch(n >> 16), ch((n >> 8) & 255), ch(n & 255)].map((v) => v.toFixed(5)).join(', ')})`;
};

const PALETTE = `
#define INK ${lin('#05060B')}
#define INDIGO ${lin('#0B1030')}
#define HORIZON ${lin('#1B2A66')}
#define CORE ${lin('#FFF4E0')}
#define WARM ${lin('#FFC37A')}
#define EMBER ${lin('#FF8A3D')}
#define PET_SHADOW ${lin('#3B2A8C')}
#define PET_BODY ${lin('#6E4BD8')}
#define PET_LIT ${lin('#9A7CF6')}
#define PET_RIM ${lin('#C9B8FF')}
#define BODY0 ${lin('#141320')}
#define BODY1 ${lin('#0A0B16')}
#define BODY2 ${lin('#06070E')}
#define FACE ${lin('#0A0B14')}
#define ROSE ${lin('#A86A74')}
`;

export const QUAD_VERT = /* glsl */ `
varying vec2 vUv;
void main() {
  vUv = uv;
  gl_Position = vec4(position.xy, 0.0, 1.0);
}
`;

const COMMON = /* glsl */ `
${PALETTE}
uniform vec2 uRes;      // drawing buffer, device px
uniform vec2 uSun;      // sun centre, device px, y down
uniform float uSunR;    // sun radius, device px
uniform float uRise;    // 0 night .. 1 risen (light)
uniform float uTime;
uniform sampler2D uL0;
uniform sampler2D uL1;
uniform sampler2D uL2;
uniform vec4 uR0;       // layer rects: x, y, w, h in device px (y down)
uniform vec4 uR1;
uniform vec4 uR2;
uniform sampler2D uWord;
uniform vec4 uWR;
varying vec2 vUv;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
float inRect(vec2 uv) {
  return step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
}
`;

export const OCC_FRAG = /* glsl */ `
${COMMON}
void main() {
  vec2 p = vec2(vUv.x, 1.0 - vUv.y) * uRes;
  float occ = texture(uL0, (p - uR0.xy) / uR0.zw).g;
  occ = max(occ, texture(uL1, (p - uR1.xy) / uR1.zw).g);
  occ = max(occ, texture(uL2, (p - uR2.xy) / uR2.zw).g);
  vec2 wuv = (p - uWR.xy) / uWR.zw;
  occ = max(occ, texture(uWord, wuv).r * inRect(wuv) * 0.9);

  vec2 d = p - uSun;
  float r = length(d);
  float rn = r / uRes.y;
  float ang = atan(d.y, d.x);
  // slow angular variation in the source, so the blur fans out into separate shafts
  float fan = 0.5 + 0.5 * sin(ang * 23.0 + 1.6 * sin(ang * 7.0 + uTime * 0.05));
  fan *= 0.55 + 0.45 * sin(ang * 61.0 - uTime * 0.035);
  fan = 0.15 + 0.85 * fan * fan;
  float disc = smoothstep(uSunR * 1.25, uSunR * 0.7, r);
  float glow = exp(-rn * 9.0);
  vec3 c = CORE * disc * 1.6 + mix(WARM, CORE, exp(-rn * 14.0)) * glow * 0.5 * fan;
  gl_FragColor = vec4(c * (1.0 - occ) * uRise, 1.0);
}
`;

export const RAYS_FRAG = /* glsl */ `
uniform sampler2D uSrc;
uniform vec2 uSunUv;
uniform vec2 uTexel;
varying vec2 vUv;
#define N 56
float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
void main() {
  vec2 delta = (vUv - uSunUv) * (0.94 / float(N));
  vec2 uv = vUv - delta * hash(vUv / uTexel);
  float illum = 1.0;
  vec3 acc = vec3(0.0);
  for (int i = 0; i < N; i++) {
    acc += texture(uSrc, uv).rgb * illum;
    illum *= 0.952;
    uv -= delta;
  }
  gl_FragColor = vec4(acc * (2.0 / float(N)), 1.0);
}
`;

export const MAIN_FRAG = /* glsl */ `
${COMMON}
uniform sampler2D uRays;
uniform vec2 uWTex;     // wordmark texel size
uniform float uBevel;   // face normal strength from the narrow blur
uniform float uHz;      // horizon y, device px
uniform float uDpr;

// One flower layer: dark silhouette, warm/violet rim where it faces the sun, florets that glow through.
vec3 shadeLayer(sampler2D tex, vec4 rect, vec2 p, vec3 body, float lod, float fall, float rimK, float glowK, out float sil) {
  vec2 uv = (p - rect.xy) / rect.zw;
  vec4 t = texture(tex, uv);
  sil = t.g;
  float inv = 1.0 / max(t.g, 0.02);
  float bump = t.r * inv;
  float flo = t.b * inv;

  vec2 o = exp2(lod) * 0.75 / rect.zw;
  float b0 = textureLod(tex, uv, lod).g;
  float bx = textureLod(tex, uv + vec2(o.x, 0.0), lod).g;
  float by = textureLod(tex, uv + vec2(0.0, o.y), lod).g;
  vec2 grad = vec2(bx - b0, by - b0);
  vec2 nOut = -grad / (length(grad) + 1e-4);

  vec2 toS = uSun - p;
  float dist = length(toS) / uRes.y;
  toS /= max(length(toS), 1e-3);
  float light = uRise * exp(-dist * fall);
  float edge = clamp((1.0 - b0) * 2.2, 0.0, 1.0);
  float facing = max(dot(nOut, toS), 0.0);
  float rim = edge * edge * pow(facing, 1.3) * light;

  // floret bumps: the side of each tiny floret that faces the sun catches a crescent
  vec2 bg = vec2(dFdx(bump), -dFdy(bump));
  float cres = max(dot(-bg / (length(bg) + 1e-4), toS), 0.0) * clamp(length(bg) * 4.0, 0.0, 1.0);

  vec3 c = body;
  // translucency: light through thin petals near the edge, deep violet, only where the light is
  c += mix(PET_SHADOW, PET_BODY, edge) * flo * light * (0.008 + 0.32 * edge * edge) * (0.55 + 0.45 * bump) * glowK;
  vec3 rimF = mix(PET_LIT, PET_RIM, clamp(rim * 1.4, 0.0, 1.0));
  vec3 rimL = mix(EMBER, WARM, clamp(rim, 0.0, 1.0)) * 0.22;
  // thin parts (stems, leaf tips) barely hold a rim; florets on a dome edge do
  float thick = mix(smoothstep(0.12, 0.45, b0), 1.0, flo);
  c += mix(rimL, rimF, flo) * rim * rimK * thick * mix(1.0, 0.45 + 0.9 * cres, flo);
  c += PET_LIT * flo * cres * light * (0.25 + 0.75 * edge) * 0.2 * rimK;
  return c;
}

// Wordmark: near-ink matte letters (a hint of the sky behind) with a thin, crisp rim of sunlight on the edges
// that face the sun. The rim lives in the narrow band where the small blur falls off inside each glyph.
vec4 wordmark(vec2 p, vec3 sky) {
  vec2 uv = (p - uWR.xy) / uWR.zw;
  float inside = inRect(uv);
  if (inside < 0.5) return vec4(0.0);
  vec4 w = textureLod(uWord, uv, 0.0);
  float a = w.r;
  if (a < 0.002) return vec4(0.0);
  vec2 tx = vec2(uWTex.x, 0.0);
  vec2 ty = vec2(0.0, uWTex.y);
  float hr = textureLod(uWord, uv + tx, 0.0).g;
  float hl = textureLod(uWord, uv - tx, 0.0).g;
  float hd = textureLod(uWord, uv + ty, 0.0).g;
  float hu = textureLod(uWord, uv - ty, 0.0).g;
  vec2 g = vec2(hr - hl, hd - hu);
  vec2 nOut = -g / (length(g) + 1e-5);

  vec2 toS = uSun - p;
  float dist = length(toS) / uRes.y;
  toS /= max(length(toS), 1e-3);
  float kI = pow(uRise, 1.6) * 1.7 * exp(-dist * 1.1);

  float edge = 1.0 - smoothstep(0.5, 0.94, w.g);
  float facing = max(dot(nOut, toS), 0.0);
  float rim = edge * edge * pow(facing, 1.4) * kI;

  // a whisper of face shading from the same tight bevel: engraved, not inflated
  vec3 n = normalize(vec3(-g * uBevel, 1.0));
  float fill = max(dot(n, vec3(0.0, -0.75, 0.66)), 0.0);
  float low = clamp((p.y - uWR.y) / uWR.w, 0.0, 1.0);
  vec3 c = (FACE + sky * 0.1) * (0.8 + 0.3 * fill);
  c += WARM * low * low * 0.006 * kI;
  c += mix(WARM, CORE, clamp(rim - 0.35, 0.0, 1.0)) * rim * 1.1;
  return vec4(c, a);
}

vec3 toSrgb(vec3 c) {
  return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

vec3 softclip(vec3 c) {
  vec3 k = vec3(0.72);
  vec3 over = max(c - k, 0.0);
  return min(c, k) + (1.0 - k) * (1.0 - exp(-over / (1.0 - k)));
}

void main() {
  vec2 p = vec2(vUv.x, 1.0 - vUv.y) * uRes;
  float H = uRes.y;
  float v = p.y / H;
  float hz = uHz / H;
  float glowK = 0.12 + 0.88 * uRise;

  // sky: night ink at the top into deep navy, then at the horizon amber -> ember -> a thin dusty rose -> navy
  float k1 = clamp(v / hz, 0.0, 1.2);
  vec3 c = mix(INK, INDIGO, smoothstep(0.05, 0.85, k1));
  c = mix(c, HORIZON, pow(clamp(k1, 0.0, 1.0), 5.0) * 0.4);
  vec2 q = (p - uSun) / H;
  float above = max((uHz - p.y) / H, 0.0);
  float dx = (p.x - uSun.x) / uRes.x;
  float spread = exp(-(dx * dx) / 0.12);
  vec3 dawn = mix(WARM, EMBER, smoothstep(0.0, 0.03, above));
  dawn = mix(dawn, ROSE, smoothstep(0.025, 0.07, above));
  float band = exp(-above / 0.038) * (0.3 + 0.7 * spread);
  c += dawn * band * 0.3 * glowK;
  float qd = length(q * vec2(0.75, 1.0));
  c += WARM * (exp(-(qd * qd) / 0.018) * 0.2 + exp(-qd * 14.0) * 0.08) * uRise;

  vec3 skyC = c; // the sky alone, before the sun: what the far row's haze veil is made of

  // a few faint stars that fade out at dawn
  vec2 sc = floor(p / (3.0 * uDpr));
  float st = hash(sc);
  float star = step(0.9965, st) * smoothstep(0.62, 0.05, v) * (0.5 + 0.5 * sin(uTime * (0.6 + st * 2.0) + st * 40.0));
  c += vec3(0.55, 0.6, 0.8) * star * 0.05 * (1.0 - 0.9 * uRise);

  // the sun: a matte warm disc with a corona; never pure white
  float r = length(p - uSun);
  float disc = smoothstep(uSunR + 1.5 * uDpr, uSunR - 1.5 * uDpr, r);
  vec3 discC = mix(WARM, CORE, smoothstep(uSunR * 1.05, uSunR * 0.15, r));
  c = mix(c, discC, disc);
  float rs = r / uSunR;
  c += mix(EMBER, WARM, exp(-rs * 0.6)) * (exp(-rs * 0.9) * 0.55 + exp(-(rs * rs) / 10.0) * 0.1) * uRise * (1.0 - disc);

  vec3 rays = texture(uRays, vUv).rgb * (0.12 + 0.88 * smoothstep(0.22, hz, v));
  c += rays * 0.34;

  vec4 wm = wordmark(p, c);
  c = mix(c, wm.rgb, wm.a * (0.62 + 0.38 * uRise));

  // warm haze along the horizon, drifting
  float hzd = (p.y - uHz) / H;
  float haze = exp(-abs(hzd) * (hzd > 0.0 ? 20.0 : 11.0)) * (0.75 + 0.25 * sin(p.x / H * 5.0 + uTime * 0.07 + sin(p.y / H * 9.0 - uTime * 0.05)));
  vec3 hazeC = mix(EMBER, WARM, spread) * (0.1 + 0.25 * spread) * haze * glowK;

  // the farthest row is mostly haze: a darker veil of the horizon glow behind it
  float s0, s1, s2;
  float below = max(hzd, 0.0);
  vec3 veil = mix(skyC, BODY0, clamp(0.55 + below * 7.0, 0.55, 0.94));
  vec3 l0 = shadeLayer(uL0, uR0, p, veil + hazeC * 0.4, 2.0, 2.6, 0.35, 0.5, s0);
  c = mix(c, l0, s0);
  c += hazeC * 0.35;
  vec3 l1 = shadeLayer(uL1, uR1, p, BODY1, 2.6, 4.0, 1.25, 1.0, s1);
  c = mix(c, l1, s1);
  c += hazeC * 0.18;
  vec3 l2 = shadeLayer(uL2, uR2, p, BODY2, 3.2, 3.2, 1.4, 0.9, s2);
  c = mix(c, l2, s2);

  // light in the air in front of everything (less over the near silhouettes)
  c += rays * 0.12 * (1.0 - 0.85 * s2);

  // vignette and a clean ink floor
  vec2 vq = (vUv - vec2(0.5, 0.42)) * vec2(1.0, 1.15);
  c *= 1.0 - 0.6 * smoothstep(0.25, 0.95, length(vq));
  c = mix(c, INK, smoothstep(0.84, 0.99, v));

  c = softclip(c);
  c = toSrgb(c);
  c += (hash(p + fract(uTime * 0.37) * 97.0) - 0.5) * 0.024 * (1.0 - smoothstep(0.9, 0.99, v));
  gl_FragColor = vec4(c, 1.0);
}
`;

export const MOTE_VERT = /* glsl */ `
attribute vec4 aSeed;   // x, y in 0..1, speed/size, phase
uniform vec2 uRes;
uniform vec2 uSun;
uniform float uRise;
uniform float uTime;
uniform float uDpr;
uniform sampler2D uRays;
varying float vA;
void main() {
  float t = uTime * (0.004 + 0.008 * aSeed.z);
  float x = fract(aSeed.x + t * 0.6 + 0.02 * sin(uTime * 0.11 + aSeed.w * 6.283));
  float y = fract(aSeed.y - t);
  vec2 px = vec2(x * uRes.x, mix(0.12, 0.8, y) * uRes.y);
  vec2 ruv = vec2(px.x / uRes.x, 1.0 - px.y / uRes.y);
  float ray = dot(texture(uRays, ruv).rgb, vec3(0.4, 0.4, 0.2));
  float d = length(px - uSun) / uRes.y;
  float edge = smoothstep(0.0, 0.12, y) * smoothstep(1.0, 0.85, y);
  vA = uRise * edge * (ray * 2.2 + 0.18 * exp(-d * 3.0)) * (0.55 + 0.45 * sin(uTime * (0.5 + aSeed.z) + aSeed.w * 20.0));
  gl_Position = vec4(px.x / uRes.x * 2.0 - 1.0, 1.0 - px.y / uRes.y * 2.0, 0.0, 1.0);
  gl_PointSize = (1.4 + 2.6 * aSeed.z * aSeed.z) * uDpr;
}
`;

export const MOTE_FRAG = /* glsl */ `
${PALETTE}
varying float vA;
void main() {
  float r = length(gl_PointCoord - 0.5) * 2.0;
  float a = smoothstep(1.0, 0.0, r);
  vec3 c = pow(mix(EMBER, WARM, 0.7), vec3(1.0 / 2.2));
  gl_FragColor = vec4(c * a * a * min(vA, 0.8), 1.0);
}
`;
