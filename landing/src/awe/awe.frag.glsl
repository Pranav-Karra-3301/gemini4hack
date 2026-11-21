#version 300 es
precision highp float;

// "Dawn from orbit": low orbit above the night side of a planet whose horizon is
// a vast, gentle arc. Scroll (uProgress) brings the sun up over the limb.

uniform float uTime;        // seconds
uniform vec2  uResolution;  // device pixels
uniform float uProgress;    // 0..1
uniform vec2  uPointer;     // -1..1, smoothed

out vec4 fragColor;

const float PI = 3.14159265359;

// Planet radius = 1. Telephoto lens from low orbit: the arc spans several viewport widths.
const float CAM_ALT    = 0.02;
const float HORIZON_Y  = 0.64;    // arc apex, fraction of height from the top (mirrored in awe.css)
const float TAN_HALF   = 0.2493;  // tan(14 deg), vertical half-FOV on landscape screens
const float H_LIMB     = 0.0009;  // dense limb scale height
const float H_HAZE     = 0.0040;  // upper haze scale height
const float H_GLOW     = 0.00032; // visible limb glow scale height: a razor-thin line
const float INV_SQRT2H = 23.57;   // 1 / sqrt(2 * H_LIMB)
const float CLOUD_ALT  = 0.0045;
const float CLOUD_FREQ = 55.0;
const float SUN_AZ     = -0.10;   // radians, slightly left of centre
const float SUN_R      = 0.0047;  // angular radius
const float SPIN       = 6.0e-5;  // planet rotation, rad/s

const float SUN        = 1.5;
const float K_EXT      = 4.0;     // extinction of grazing sunlight
const float TAU_LIMB   = 6.0;
const float TAU_HAZE   = 0.3;
const float AIRGLOW    = 0.17;

const vec3 NAVY  = vec3(0.047, 0.102, 0.227);  // #0C1A3A
const vec3 BLUE  = vec3(0.298, 0.553, 1.000);  // #4C8DFF
const vec3 HOT   = vec3(0.706, 0.808, 1.000);  // #B4CEFF
const vec3 FROST = vec3(0.933, 0.953, 1.000);  // #EEF3FF
const vec3 INK   = vec3(0.0275, 0.0353, 0.0627); // #070910, the page colour

// ---------------------------------------------------------------- palettes
// Every light source is a scalar intensity mapped through one restrained ramp,
// so the scene stays in the navy -> Gemini blue -> hot -> frost family.
vec3 palette(float x) {
  x = max(x, 0.0);
  vec3 c = mix(vec3(0.0), NAVY, smoothstep(0.0, 0.2, x));
  c = mix(c, BLUE,  smoothstep(0.2, 0.62, x));
  c = mix(c, HOT,   smoothstep(0.62, 1.0, x));
  c = mix(c, FROST, smoothstep(1.0, 1.6, x));
  return mix(c, vec3(1.0), smoothstep(1.6, 3.0, x));
}

// Muted ramp for cloud tops: matte slate rather than saturated blue.
vec3 surfacePalette(float x) {
  x = max(x, 0.0);
  vec3 c = mix(vec3(0.0), vec3(0.035, 0.055, 0.10), clamp(x / 0.12, 0.0, 1.0));
  c = mix(c, vec3(0.20, 0.30, 0.50), smoothstep(0.12, 0.55, x));
  c = mix(c, HOT,   smoothstep(0.55, 1.0, x));
  return mix(c, FROST, smoothstep(1.0, 1.6, x));
}

vec3 screenBlend(vec3 a, vec3 b) { return 1.0 - (1.0 - a) * (1.0 - b); }

// ---------------------------------------------------------------- noise
float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float hash13(vec3 p3) {
  p3 = fract(p3 * 0.1031);
  p3 += dot(p3, p3.zyx + 31.32);
  return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec3 x) {
  vec3 i = floor(x);
  vec3 f = fract(x);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(mix(hash13(i),                   hash13(i + vec3(1, 0, 0)), f.x),
                 mix(hash13(i + vec3(0, 1, 0)),   hash13(i + vec3(1, 1, 0)), f.x), f.y),
             mix(mix(hash13(i + vec3(0, 0, 1)),   hash13(i + vec3(1, 0, 1)), f.x),
                 mix(hash13(i + vec3(0, 1, 1)),   hash13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

const mat3 OCT = mat3(0.00, 0.80, 0.60, -0.80, 0.36, -0.48, -0.60, -0.48, 0.64);

// fp = pixel footprint in noise units; octaves finer than a pixel fade to their mean.
float fbm(vec3 p, float fp) {
  float sum = 0.0, amp = 0.5, norm = 0.0, f = 1.0;
  for (int i = 0; i < 6; i++) {
    float lod = 1.0 - smoothstep(0.3, 0.9, fp * f);
    sum  += amp * mix(0.5, vnoise(p), lod);
    norm += amp;
    p = OCT * p * 2.03 + vec3(1.7, 9.2, 3.1);
    f   *= 2.03;
    amp *= 0.5;
  }
  return sum / norm;
}

mat3 rotX(float a) {
  float c = cos(a), s = sin(a);
  return mat3(1.0, 0.0, 0.0, 0.0, c, s, 0.0, -s, c);
}

// ---------------------------------------------------------------- light
// Sun elevation above the apparent horizon (rad) as a function of scroll.
// Ease-out: long pre-dawn, the limb crests around 0.72, half disc ~0.78.
float sunElevRel(float p) {
  return -0.10 + 0.106 * (1.0 - pow(1.0 - p, 1.93));
}

// Fraction of sunlight reaching point X (|X| = 1 + altitude), with the planet's
// shadow and extinction along the grazing path through an exponential atmosphere.
float sunTrans(vec3 X, vec3 s) {
  float r  = length(X);
  float a  = r - 1.0;
  float mu = dot(X, s) / r;
  if (mu >= 0.0) {
    return exp(-0.5 * K_EXT * exp(-a / H_LIMB) / (1.0 + mu * INV_SQRT2H));
  }
  float at   = r * sqrt(1.0 - mu * mu) - 1.0;   // lowest altitude on the path to the sun
  float occl = smoothstep(-3.0e-4, 3.0e-4, at); // penumbra of the sun's disc
  float atc  = max(at, 0.0);
  float tau  = K_EXT * exp(-atc / H_LIMB) * (1.0 - 0.5 * exp(-(a - atc) / H_LIMB));
  return occl * exp(-tau);
}

// Henyey-Greenstein, normalised to 1 looking straight at the sun.
float hgNorm(float c, float g) {
  float d = 1.0 + g * g - 2.0 * g * c;
  return pow((1.0 - g) * (1.0 - g) / d, 1.5);
}

// ---------------------------------------------------------------- main
void main() {
  vec2 res = uResolution;
  float S  = min(res.y, res.x * 0.69);   // portrait screens get a wider lens
  vec2 uv  = (gl_FragCoord.xy - 0.5 * res) / S;
  float p  = clamp(uProgress, 0.0, 1.0);

  // Very slow push-in: a little with scroll, a little with time (asymptotic).
  float push    = 0.06 * smoothstep(0.0, 1.0, p) + 0.025 * (1.0 - exp(-uTime / 80.0));
  float tanHalf = TAN_HALF * (1.0 - push);
  vec2  tp      = uv * 2.0 * tanHalf;
  float pixAng  = 2.0 * tanHalf / S;

  // Pitch so the apex of the arc always sits at HORIZON_Y.
  float dip   = acos(1.0 / (1.0 + CAM_ALT));
  float yH    = (0.5 - HORIZON_Y) * res.y / S;
  float pitch = -dip + atan(-yH * 2.0 * tanHalf) + uPointer.y * 0.0025;
  float yaw   = uPointer.x * 0.015;

  vec3 fwd = vec3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch));
  vec3 rgt = normalize(cross(vec3(0.0, 1.0, 0.0), fwd));
  vec3 up  = cross(fwd, rgt);
  vec3 rd  = normalize(fwd + tp.x * rgt + tp.y * up);
  vec3 ro  = vec3(0.0, 1.0 + CAM_ALT, 0.0);

  float eRel = sunElevRel(p);
  float sEl  = -dip + eRel;
  vec3 sunDir = vec3(sin(SUN_AZ) * cos(sEl), sin(sEl), cos(SUN_AZ) * cos(sEl));
  float dawn  = smoothstep(-0.10, 0.0, eRel);

  // Ray vs planet; closest approach gives the tangent altitude for sky rays.
  float b    = dot(ro, rd);
  float c    = dot(ro, ro) - 1.0;
  float disc = b * b - c;
  vec3  T    = ro + rd * max(-b, 0.0);
  float aSigned = length(T) - 1.0;
  float aPx     = sqrt(c) * pixAng;                 // altitude covered by one pixel at the limb
  float ground  = b < 0.0 ? smoothstep(0.7 * aPx, -0.7 * aPx, aSigned) : 0.0;

  // ---- atmosphere along the limb
  float a     = max(aSigned, 0.0);
  vec3  Tsky  = normalize(T) * (1.0 + a);
  float cosT  = dot(rd, sunDir);
  float phR   = 0.75 * (1.0 + cosT * cosT);
  float phM   = hgNorm(cosT, 0.75);
  float Ts    = sunTrans(Tsky, sunDir);
  float tau1  = TAU_LIMB * exp(-a / H_LIMB);
  float tau2  = TAU_HAZE * exp(-a / H_HAZE);
  float tauL  = TAU_LIMB * exp(-a / H_GLOW);          // thin emission/scatter shell for the visible limb
  // The upper haze stays faint until the sun is nearly at the limb.
  float hazeGate = mix(0.18, 1.0, smoothstep(-0.03, 0.004, eRel));
  float xSky  = AIRGLOW * 0.8 * (1.0 - exp(-tauL))
              + SUN * 0.85 * Ts * (1.0 - exp(-tauL)) * phR
              + SUN * Ts * (1.0 - exp(-tau2)) * phM * 2.1 * hazeGate;

  // ---- sun: small bead at the limb, mild glow, enormous soft bloom
  float th    = cosT > 0.0 ? length(cross(rd, sunDir)) : 2.0;
  float vis   = smoothstep(-0.9 * SUN_R, 1.2 * SUN_R, eRel);
  float disk  = smoothstep(SUN_R, SUN_R * 0.7, th) * (1.0 - ground) * exp(-tau1 * 0.6);
  float bloom = vis * (1.6 * exp(-th / 0.006) + 0.42 * exp(-th / 0.04) + 0.2 * exp(-th / 0.22));

  vec3 col = palette(xSky + bloom + disk * 6.0);

  // Desaturate the limb line toward a cool silver so it reads as light, not neon.
  float limbW = (1.0 - exp(-tauL)) * (1.0 - ground) * (1.0 - smoothstep(0.0, 0.6, bloom));
  float lum   = dot(col, vec3(0.2126, 0.7152, 0.0722));
  col = mix(col, vec3(lum) * vec3(0.94, 0.96, 1.0) * 1.08, 0.62 * limbW);

  // ---- planet: near-black night side, cloud tops catching the first light
  if (ground > 0.0) {
    float tHit   = -b - sqrt(max(disc, 0.0));
    vec3  P      = ro + rd * tHit;
    vec3  n      = normalize(P);
    float sinInc = max(-dot(rd, n), 0.0);
    float mu     = dot(n, sunDir);

    mat3  spin = rotX(uTime * SPIN);
    vec3  wind = vec3(uTime * 0.0035, 0.0, uTime * 0.0012);
    vec3  q    = spin * n * CLOUD_FREQ + wind;
    float fp   = tHit * pixAng * CLOUD_FREQ / pow(max(sinInc, 0.003), 0.8);
    float fc   = fbm(q, fp);
    float cov  = smoothstep(0.46, 0.70, fc);

    // Raking light: slope of the cloud field toward the sun.
    vec3  sT   = normalize(sunDir - n * mu);
    float fc2  = fbm(q + spin * sT * 0.22, fp);
    float rake = clamp(0.5 - (fc2 - fc) * 7.0, 0.0, 1.0);

    float Tc   = sunTrans(n * (1.0 + CLOUD_ALT), sunDir);
    float Tg   = sunTrans(n * (1.0 + 1.5 * H_LIMB), sunDir);
    float fwdS = exp(-(1.0 - cosT) * 30.0);
    float twil = exp(clamp((mu + 0.085) / 0.028, -30.0, 0.0)) * dawn;

    float xCloud = cov * (0.05
                 + 1.3 * SUN * Tc * (0.2 + 0.8 * rake) * (0.35 + 1.1 * fwdS)
                 + 0.18 * twil);

    // Long, low path through the air near the limb: airglow + sunlit haze in front.
    float colRel = clamp(2.0 * H_LIMB / (max(sinInc, 1e-4) * 0.075), 0.0, 1.0);
    float tauG   = TAU_LIMB * 0.5 * colRel;
    float xIns   = (AIRGLOW + SUN * Tg * phR) * (1.0 - exp(-tauG));

    vec3 gcol = screenBlend(surfacePalette(xCloud * exp(-tauG * 0.5)), palette(xIns + bloom));
    col = mix(col, gcol, ground);
  }

  // ---- finish: soft vignette, then the ink floor (so the edges match the page), fine grain (~2%)
  vec2  vq  = gl_FragCoord.xy / res - 0.5;
  col *= 1.0 - 0.3 * smoothstep(0.35, 0.85, length(vq * vec2(1.0, 0.85)));
  col = screenBlend(col, INK);
  float gt  = floor(fract(uTime * 0.37) * 997.0);
  float g1  = hash12(gl_FragCoord.xy + gt * vec2(37.0, 17.0));
  float g2  = hash12(gl_FragCoord.xy * 1.37 + gt * vec2(11.0, 53.0));
  col += (g1 + g2 - 1.0) * 0.02;

  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
