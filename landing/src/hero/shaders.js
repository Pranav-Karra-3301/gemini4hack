// GLSL for the hero. Scene shaders are matte: wrap-lambert + translucency, no specular term.

export const FS_VERT = /* glsl */ `
varying vec2 vUv;
void main() {
  vUv = uv;
  gl_Position = vec4(position.xy, 0.0, 1.0);
}`;

const LIGHT_UNIFORMS = /* glsl */ `
uniform vec3 uSunDir;
uniform vec3 uSunCol;
uniform vec3 uSkyCol;
uniform vec3 uGroundCol;
uniform vec3 uFillCol;
uniform vec3 uSunView; // camera → apparent sun
uniform float uReveal;
`;

// iPhone-style dot projector: a regular dot lattice cast from just beside the camera, so the dots
// land on the surfaces and their rows bend with depth.
const LIDAR = /* glsl */ `
#ifndef BACK
uniform mat4 uProjVP;
uniform vec3 uProjPos;
uniform vec4 uLidar; // x sweep front, y second lattice, z fine lattice, w dot opacity
uniform vec2 uGrid;
uniform float uDepthRef;
uniform vec3 uBlue;
uniform vec3 uBlueGlow;

float lidarDot(vec2 p, float r) {
  vec2 f = fract(p) - 0.5;
  float d = length(f);
  float w = length(fwidth(p)) * 0.6 + 1e-4;
  return (1.0 - smoothstep(r - w, r + w, d)) * (1.0 - smoothstep(0.3, 0.55, w));
}

vec3 lidar(vec3 wp, vec3 N) {
  if (uLidar.w <= 0.001) return vec3(0.0);
  vec4 pc = uProjVP * vec4(wp, 1.0);
  vec2 q = pc.xy / pc.w;
  vec2 g = (q * 0.5 + 0.5) * uGrid;
  float sc = q.x * 0.8 - q.y * 0.45;
  float ahead = uLidar.x - sc;
  float hit = smoothstep(0.0, 0.05, ahead);
  float band = exp(-abs(ahead) * 9.0) * step(-0.03, ahead);
  float dots = lidarDot(g, 0.17);
  dots = max(dots, lidarDot(g + vec2(0.5), 0.15) * uLidar.y);
  dots = max(dots, lidarDot(g * 2.0 + vec2(0.25, 0.75), 0.16) * uLidar.z * 0.85);
  vec3 toP = normalize(uProjPos - wp);
  float facing = 0.18 + 0.82 * clamp(dot(N, toP), 0.0, 1.0);
  float depthF = clamp(1.0 - (pc.w - uDepthRef) * 0.3, 0.3, 1.25);
  float k = dots * hit * facing * depthF;
  vec3 c = mix(uBlue, uBlueGlow, band) * k * (1.5 + band * 3.0);
  c += uBlue * band * facing * depthF * 0.08;
  return c * uLidar.w;
}
#endif
`;

export const FLORET_VERT = /* glsl */ `
attribute vec3 aBud;
attribute vec3 aBudN;
attribute float aRho;
attribute float aLobe;
attribute float aOpen;
attribute float aVar;
attribute float aOcc;
attribute float aSeed;
attribute vec3 aDomeN;
uniform float uTime;
varying vec3 vN;
varying vec3 vW;
varying vec3 vDN;
varying float vRho;
varying float vLobe;
varying float vOpen;
varying float vVar;
varying float vOcc;
void main() {
  float o = aOpen;
  vec3 p = mix(aBud, position, o);
  vec3 n = normalize(mix(aBudN, normal, o) + 1e-5);
  float th = atan(position.y, position.x + 1e-6);
  p.z += o * aRho * aRho * 0.05 * sin(th * 3.0 + aSeed * 40.0);
  vec4 wp = modelMatrix * instanceMatrix * vec4(p, 1.0);
  float sw = sin(uTime * 0.8 + aSeed * 6.2831);
  wp.xyz += vec3(sw, 0.3 * sw, 0.6 * sw) * 0.0035;
  vW = wp.xyz;
  vN = normalize(mat3(modelMatrix) * mat3(instanceMatrix) * n);
  vDN = normalize(mat3(modelMatrix) * aDomeN);
  vRho = aRho;
  vLobe = aLobe;
  vOpen = o;
  vVar = aVar;
  vOcc = aOcc;
  gl_Position = projectionMatrix * viewMatrix * wp;
}`;

export const FLORET_FRAG = /* glsl */ `
${LIGHT_UNIFORMS}
uniform vec3 uPShadow;
uniform vec3 uPBody;
uniform vec3 uPLit;
uniform vec3 uPRim;
uniform vec3 uEye;
#ifdef BACK
uniform vec3 uFogCol;
uniform float uFog;
#endif
${LIDAR}
varying vec3 vN;
varying vec3 vW;
varying vec3 vDN;
varying float vRho;
varying float vLobe;
varying float vOpen;
varying float vVar;
varying float vOcc;
void main() {
  vec3 N = normalize(vN);
  if (!gl_FrontFacing) N = -N;
  vec3 Nd = normalize(vDN);
  vec3 V = normalize(cameraPosition - vW);
  vec3 L = uSunDir;
  float tube = step(vRho, -0.5);
  float rho = max(vRho, 0.0);

  // albedo: violet to lavender, buds deep indigo, darker throat ring, pale eye
  vec3 petal = mix(uPBody, uPLit, vVar * 0.65);
  petal = mix(petal, uPRim, smoothstep(0.72, 1.0, rho) * 0.12 * vOpen);
  petal = mix(uPShadow * 0.85, petal, smoothstep(0.1, 0.9, vOpen));
  petal *= mix(0.45, 1.0, smoothstep(0.12, 0.42, rho));
  petal *= 0.92 + 0.08 * vLobe;
  float eye = smoothstep(0.2, 0.13, rho) * smoothstep(0.03, 0.065, rho) * smoothstep(0.55, 0.85, vOpen) * 0.7;
  vec3 alb = mix(petal, uEye, eye);
  alb = mix(alb, uPShadow * 0.15, smoothstep(0.045, 0.0, rho) * (1.0 - tube) * vOpen);
  alb = mix(alb, uPShadow * 0.45, tube);

  vec3 Nl = normalize(mix(N, Nd, 0.35));
  float vis = smoothstep(-0.45, 0.5, dot(Nd, L));
  float wrap = clamp((dot(Nl, L) + 0.35) / 1.35, 0.0, 1.0);
  float thin = mix(0.3, 1.0, smoothstep(0.2, 0.95, rho)) * (1.0 - tube) * mix(0.55, 1.0, vOpen);
  float back = clamp(-dot(N, L), 0.0, 1.0);
  float vt = clamp(dot(V, -L), 0.0, 1.0);
  float trans = (0.6 * back + 0.25 * vt + 1.1 * pow(vt, 6.0)) * thin;
  float rim = pow(1.0 - clamp(abs(dot(N, V)), 0.0, 1.0), 3.0);

  vec3 hemi = mix(uGroundCol, uSkyCol, Nl.y * 0.5 + 0.5);
  vec3 fill = uFillCol * clamp(dot(Nl, V) * 0.5 + 0.5, 0.0, 1.0);
  vec3 c = alb * (hemi + fill) * vOcc;
  vec3 sunD = mix(uSunCol, vec3(dot(uSunCol, vec3(0.3, 0.5, 0.2))), 0.45);
  c += alb * sunD * wrap * vis * vOcc * 0.45;
  vec3 transTint = mix(uPRim, uPLit, 0.45);
  c += transTint * uSunCol * trans * smoothstep(-0.15, 0.55, dot(Nd, L)) * 0.65 * vOcc;
  c += uPRim * uSunCol * rim * (0.15 + 0.85 * vt) * vis * 0.35;
  c += transTint * uSunCol * thin * thin * vis * 0.12 * vOcc;
  // petals seen against the sun light up from behind: the translucent aureole at the rim
  float aur = pow(clamp(dot(-V, uSunView), 0.0, 1.0), 260.0);
  c += transTint * uSunCol * aur * (0.15 + 1.1 * thin * thin + 1.0 * rim) * smoothstep(-0.6, 0.3, dot(Nd, L));
#ifdef BACK
  c = mix(c * 0.7, uFogCol, uFog);
  gl_FragColor = vec4(c * uReveal, 1.0);
#else
  gl_FragColor = vec4(c * uReveal + lidar(vW, N), 1.0);
#endif
}`;

export const LEAF_VERT = /* glsl */ `
uniform float uTime;
#ifndef STEM
attribute float aVar;
#endif
varying vec2 vUv;
varying vec3 vN;
varying vec3 vW;
varying float vVar;
void main() {
#ifdef USE_INSTANCING
  mat4 m = modelMatrix * instanceMatrix;
#else
  mat4 m = modelMatrix;
#endif
#ifdef STEM
  vVar = 0.5;
#else
  vVar = aVar;
#endif
  vec4 wp = m * vec4(position, 1.0);
  wp.y += sin(uTime * 0.6 + vVar * 20.0) * 0.008 * uv.x;
  vW = wp.xyz;
  vN = normalize(mat3(m) * normal);
  vUv = uv;
  gl_Position = projectionMatrix * viewMatrix * wp;
}`;

export const LEAF_FRAG = /* glsl */ `
${LIGHT_UNIFORMS}
uniform vec3 uLeafDark;
uniform vec3 uLeafLit;
#ifdef BACK
uniform vec3 uFogCol;
uniform float uFog;
#endif
${LIDAR}
varying vec2 vUv;
varying vec3 vN;
varying vec3 vW;
varying float vVar;
void main() {
  vec3 N = normalize(vN);
  if (!gl_FrontFacing) N = -N;
  vec3 V = normalize(cameraPosition - vW);
  vec3 L = uSunDir;
#ifdef STEM
  vec3 alb = uLeafDark * 0.8;
  float shade = 0.45;
#else
  float u = vUv.x;
  float v = vUv.y;
  float av = abs(v);
  float phase = u * 8.5 - av * 1.5;
  float dv = abs(fract(phase + 0.5) - 0.5);
  float fw = fwidth(phase) + 1e-4;
  float lat = (1.0 - smoothstep(0.0, 0.04 + fw, dv)) * smoothstep(0.04, 0.14, av) * (1.0 - smoothstep(0.82, 0.98, av));
  float mid = 1.0 - smoothstep(0.0, 0.03 + fwidth(v), av);
  vec3 alb = mix(uLeafDark, uLeafLit, 0.3 + 0.45 * vVar);
  alb *= mix(0.7, 1.0, smoothstep(0.0, 0.2, dv));
  alb = mix(alb, uLeafLit * 1.2, max(lat * 0.5, mid * 0.65 * smoothstep(0.95, 0.6, u)));
  float shade = mix(0.3, 1.0, smoothstep(0.1, 0.7, u));
#endif
  float wrap = clamp((dot(N, L) + 0.3) / 1.3, 0.0, 1.0);
  float vt = clamp(dot(V, -L), 0.0, 1.0);
  float back = clamp(-dot(N, L), 0.0, 1.0);
  vec3 hemi = mix(uGroundCol, uSkyCol, N.y * 0.5 + 0.5);
  vec3 c = alb * (hemi + uFillCol * 0.5) * shade * 0.8;
  c += alb * uSunCol * wrap * shade * 0.3;
  c += vec3(0.16, 0.26, 0.05) * uSunCol * (0.3 * back + 0.7 * pow(vt, 5.0)) * shade * 0.3;
#ifdef BACK
  c = mix(c, uFogCol, uFog);
  gl_FragColor = vec4(c * uReveal, 1.0);
#else
#ifdef STEM
  gl_FragColor = vec4(c * uReveal + lidar(vW, N), 1.0);
#else
  gl_FragColor = vec4(c * uReveal + lidar(vW, N) * 0.6, 1.0);
#endif
#endif
}`;

export const SKY_FRAG = /* glsl */ `
uniform vec2 uSunUV;
uniform float uAspect;
uniform float uSunI;
uniform float uDawn;
uniform vec3 uTop;
uniform vec3 uMid;
uniform vec3 uHorizon;
uniform vec3 uCore;
uniform vec3 uWarm;
uniform vec3 uEmber;
varying vec2 vUv;
void main() {
  float y = vUv.y;
  vec3 sky = mix(uHorizon, uMid, smoothstep(0.0, 0.55, y));
  sky = mix(sky, uTop, smoothstep(0.5, 1.0, y));
  sky *= mix(0.12, 1.0, uDawn);
  vec2 d2 = (vUv - uSunUV) * vec2(uAspect, 1.0);
  float d = length(d2);
  vec3 sun = uCore * smoothstep(0.04, 0.026, d) * 6.0
    + uCore * exp(-d * d * 700.0) * 2.0
    + uWarm * exp(-d * 11.0) * 0.38
    + uEmber * exp(-d * 4.5) * 0.07;
  sky += sun * uSunI;
  gl_FragColor = vec4(sky, 0.0);
}`;

export const BG_FRAG = /* glsl */ `
uniform sampler2D tBack;
varying vec2 vUv;
void main() {
  vec4 b = texture2D(tBack, vUv);
  gl_FragColor = vec4(b.rgb, b.a * 0.85);
}`;

export const MOTE_VERT = /* glsl */ `
attribute vec4 aSeed4;
uniform vec3 uBoxMin;
uniform vec3 uBoxSize;
uniform float uTime;
uniform float uPx;
uniform float uSunI;
uniform sampler2D tRays;
varying float vI;
void main() {
  vec3 s = aSeed4.xyz;
  vec3 p = s;
  p.y = fract(s.y + uTime * 0.006 * (0.4 + aSeed4.w));
  p.x = fract(s.x + uTime * 0.003 + 0.015 * sin(uTime * 0.3 + s.z * 20.0));
  vec3 wp = uBoxMin + p * uBoxSize;
  wp += 0.04 * sin(uTime * vec3(0.37, 0.29, 0.41) + s * 40.0);
  vec4 cp = projectionMatrix * viewMatrix * vec4(wp, 1.0);
  gl_Position = cp;
  vec2 suv = clamp(cp.xy / cp.w * 0.5 + 0.5, 0.0, 1.0);
  float ray = dot(texture2D(tRays, suv).rgb, vec3(0.3, 0.5, 0.2));
  float edge = smoothstep(0.0, 0.1, p.y) * smoothstep(1.0, 0.9, p.y) * smoothstep(0.0, 0.1, p.x) * smoothstep(1.0, 0.9, p.x);
  vI = (0.08 + ray * 2.2) * edge * uSunI * (0.5 + aSeed4.w);
  gl_PointSize = uPx * (1.4 + 3.2 * fract(aSeed4.w * 7.13)) * (7.0 / max(cp.w, 0.1));
}`;

export const MOTE_FRAG = /* glsl */ `
uniform vec3 uMoteCol;
varying float vI;
void main() {
  float d = length(gl_PointCoord - 0.5);
  float a = exp(-d * d * 16.0) * smoothstep(0.5, 0.3, d);
  gl_FragColor = vec4(uMoteCol * a * vI, 0.0);
}`;

export const BLUR_FRAG = /* glsl */ `
uniform sampler2D tSrc;
uniform vec2 uDir;
varying vec2 vUv;
void main() {
  vec4 c = texture2D(tSrc, vUv) * 0.2270270270;
  c += (texture2D(tSrc, vUv + uDir * 1.3846153846) + texture2D(tSrc, vUv - uDir * 1.3846153846)) * 0.3162162162;
  c += (texture2D(tSrc, vUv + uDir * 3.2307692308) + texture2D(tSrc, vUv - uDir * 3.2307692308)) * 0.0702702703;
  gl_FragColor = c;
}`;

// Light source for the god rays: the sun where the scene leaves the sky open (alpha 0).
export const RAYSRC_FRAG = /* glsl */ `
uniform sampler2D tMain;
uniform vec2 uSunUV;
uniform float uAspect;
uniform float uSunI;
uniform vec3 uCore;
uniform vec3 uWarm;
varying vec2 vUv;
void main() {
  float occ = texture2D(tMain, vUv).a;
  vec2 d2 = (vUv - uSunUV) * vec2(uAspect, 1.0);
  float d = length(d2);
  vec3 src = uCore * exp(-d * d * 420.0) * 2.0 + uWarm * exp(-d * 12.0) * 0.22;
  gl_FragColor = vec4(src * (1.0 - occ) * uSunI, 1.0);
}`;

// Screen-space radial light scattering toward the sun.
export const RAYS_FRAG = /* glsl */ `
uniform sampler2D tSrc;
uniform vec2 uSunUV;
uniform float uDensity;
uniform float uDecay;
uniform float uWeight;
uniform float uExposure;
varying vec2 vUv;
#define N 60
void main() {
  vec2 uv = vUv;
  vec2 delta = (uv - uSunUV) * uDensity / float(N);
  float jitter = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
  uv -= delta * jitter;
  float illum = 1.0;
  vec3 acc = vec3(0.0);
  for (int i = 0; i < N; i++) {
    uv -= delta;
    acc += texture2D(tSrc, uv).rgb * illum;
    illum *= uDecay;
  }
  gl_FragColor = vec4(acc * uWeight * uExposure, 1.0);
}`;

export const BRIGHT_FRAG = /* glsl */ `
uniform sampler2D tSrc;
uniform float uThreshold;
uniform float uKnee;
varying vec2 vUv;
void main() {
  vec3 c = texture2D(tSrc, vUv).rgb;
  float br = max(c.r, max(c.g, c.b));
  float soft = clamp(br - uThreshold + uKnee, 0.0, 2.0 * uKnee);
  soft = soft * soft / (4.0 * uKnee + 1e-4);
  float k = max(soft, br - uThreshold) / max(br, 1e-4);
  gl_FragColor = vec4(c * k, 1.0);
}`;

export const DOWN_FRAG = /* glsl */ `
uniform sampler2D tSrc;
uniform vec2 uTexel;
varying vec2 vUv;
void main() {
  vec3 c = texture2D(tSrc, vUv).rgb * 4.0;
  c += texture2D(tSrc, vUv + uTexel * vec2(-1.0, -1.0)).rgb;
  c += texture2D(tSrc, vUv + uTexel * vec2(1.0, -1.0)).rgb;
  c += texture2D(tSrc, vUv + uTexel * vec2(-1.0, 1.0)).rgb;
  c += texture2D(tSrc, vUv + uTexel * vec2(1.0, 1.0)).rgb;
  gl_FragColor = vec4(c / 8.0, 1.0);
}`;

export const UP_FRAG = /* glsl */ `
uniform sampler2D tSrc;
uniform sampler2D tBase;
uniform vec2 uTexel;
varying vec2 vUv;
void main() {
  vec2 t = uTexel;
  vec3 c = texture2D(tSrc, vUv + vec2(-2.0 * t.x, 0.0)).rgb + texture2D(tSrc, vUv + vec2(2.0 * t.x, 0.0)).rgb
    + texture2D(tSrc, vUv + vec2(0.0, 2.0 * t.y)).rgb + texture2D(tSrc, vUv + vec2(0.0, -2.0 * t.y)).rgb;
  c += 2.0 * (texture2D(tSrc, vUv + vec2(-t.x, t.y)).rgb + texture2D(tSrc, vUv + vec2(t.x, t.y)).rgb
    + texture2D(tSrc, vUv + vec2(t.x, -t.y)).rgb + texture2D(tSrc, vUv + vec2(-t.x, -t.y)).rgb);
  gl_FragColor = vec4(c / 12.0 + texture2D(tBase, vUv).rgb, 1.0);
}`;

export const COMPOSITE_FRAG = /* glsl */ `
uniform sampler2D tMain;
uniform sampler2D tRays;
uniform sampler2D tBloom;
uniform float uRayStr;
uniform float uBloomStr;
uniform float uExposure;
uniform float uTime;
uniform vec4 uMask;   // x: 1 = mobile layout, y: floor of the text-area darkening
uniform vec2 uFocus;  // vignette centre
varying vec2 vUv;
vec3 aces(vec3 x) {
  return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}
vec3 toSRGB(vec3 c) {
  return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}
float hash(vec2 p) {
  return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}
void main() {
  vec3 col = texture2D(tMain, vUv).rgb;
  vec3 rays = texture2D(tRays, vUv).rgb;
  vec3 bloom = texture2D(tBloom, vUv).rgb;
  float desk = mix(uMask.y, 1.0, smoothstep(0.06, 0.56, vUv.x));
  float mob = mix(uMask.y, 1.0, smoothstep(0.08, 0.6, vUv.y));
  float textM = mix(desk, mob, uMask.x);
  col += bloom * uBloomStr;
  col += rays * uRayStr * mix(0.35, 1.0, textM);
  col *= textM;
  vec2 q = (vUv - uFocus) * vec2(1.15, 1.0);
  col *= 1.0 - 0.62 * smoothstep(0.3, 1.05, length(q));
  col = aces(col * uExposure);
  col = toSRGB(col);
  float n = hash(gl_FragCoord.xy + fract(uTime * 13.0) * 97.0) - 0.5;
  col += n * 0.028;
  gl_FragColor = vec4(col, 1.0);
}`;
