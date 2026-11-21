// Unicorn Studio shape treatment (shadeShape) source for layer a07fb3d5-5cf6-499e-aa59-7c98d9b97005
// Not standalone: the engine prepends ShapeSample, sdBox/sdRoundedBox/rotate2D, TAU/PI, uFillAlpha, uBorderRadius
// and calls shadeShape() per fragment. See pass0.compiled.frag for the full runnable GLSL ES 3.0 (control values baked in).

uniform float uTime;
uniform float uAiScale;
uniform float uAiGlow;
uniform float uAiPress;
uniform float uAiLightAngle;
uniform float uAiFlow;
uniform float uAiFilm;
uniform float uAiCross;

uvec2 pcg2d(uvec2 v) {
  v = v * 1664525u + 1013904223u;
  v.x += v.y * v.y * 1664525u + 1013904223u;
  v.y += v.x * v.x * 1664525u + 1013904223u;
  v ^= v >> 16;
  v.x += v.y * v.y * 1664525u + 1013904223u;
  v.y += v.x * v.x * 1664525u + 1013904223u;
  return v;
}

float randFibo(vec2 p) {
  uvec2 v = floatBitsToUint(p);
  v = pcg2d(v);
  uint r = v.x ^ v.y;
  return float(r) / float(0xffffffffu);
}

float deband() {
  return (randFibo(gl_FragCoord.xy) - 0.5) / 255.0;
}

float smoothSeg(float x) {
  float t = clamp(x, 0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

// pastel thin-film spectrum: blue, violet, pink, amber, mint, back to blue
vec3 filmSpectrum(float x) {
  float k = (x - floor(x)) * 5.0;
  vec3 c = mix(vec3(0.478, 0.655, 1.0), vec3(0.706, 0.549, 1.0), smoothSeg(k));
  c = mix(c, vec3(1.0, 0.561, 0.812), smoothSeg(k - 1.0));
  c = mix(c, vec3(1.0, 0.761, 0.478), smoothSeg(k - 2.0));
  c = mix(c, vec3(0.549, 0.961, 0.824), smoothSeg(k - 3.0));
  c = mix(c, vec3(0.478, 0.655, 1.0), smoothSeg(k - 4.0));
  return c;
}

// film thickness flowing over the sphere, thicker toward the bottom like a draining bubble
float filmThickness(vec3 n, float t) {
  vec3 q = n * 1.6;
  q.xz = rotate2D(q.xz, t * 0.5);
  q += 0.45 * sin(q.yzx * 1.9 + vec3(0.3, 2.1, 4.0) + t * 0.6);
  q += 0.22 * sin(q.zxy * 3.6 + vec3(1.7, 0.2, 2.9) - t * 0.9);
  float h = sin(q.x * 1.7 + q.y) * 0.5 + sin(q.y * 2.1 - q.z * 1.3) * 0.35 + sin(q.z * 2.6 + q.x * 0.9) * 0.15;
  return h * 0.5 + n.y * 0.55;
}

vec4 shadeShape(ShapeSample shapeSample) {
  vec2 size = shapeSample.elementSize;
  vec2 p = shapeSample.localPosition - size * 0.5;
  float press = clamp(uAiPress, 0.0, 1.0);
  float ready = clamp(uAiGlow, 0.0, 1.0);
  float R = min(size.x, size.y) * 0.5 * uAiScale * (1.0 - 0.06 * press);
  float d = length(p);
  float sd = d - R;
  float aa = max(fwidth(sd), 0.0001);
  float ang = uAiLightAngle * TAU;
  vec2 L = vec2(cos(ang), sin(ang));

  // debossed plus: the mark, the shadowed wall on the key side and the lit lip opposite
  float arm = R * 0.2115;
  float crossD = min(sdBox(p, vec2(arm, 0.75)), sdBox(p, vec2(0.75, arm)));
  vec2 psS = p - L * 0.7;
  float crossS = min(sdBox(psS, vec2(arm, 0.75)), sdBox(psS, vec2(0.75, arm)));
  vec2 psH = p + L * 0.7;
  float crossH = min(sdBox(psH, vec2(arm, 0.75)), sdBox(psH, vec2(0.75, arm)));
  float aaC = max(fwidth(crossD), 0.0001);

  float reach = R * 1.2;
  if (sd > reach) {
    return vec4(0.0);
  }

  vec3 blue = vec3(0.298, 0.553, 1.0);
  vec3 iris = vec3(0.604, 0.486, 0.965);
  vec3 frost = vec3(0.933, 0.953, 1.0);
  float time = uTime * 0.0262 * mix(0.2, 1.6, uAiFlow);
  vec2 nrm = p / max(d, 0.0001);
  float a = atan(nrm.y, nrm.x);

  // corona: diffuse backlight escaping around the edge, strongest low-left, away from the key
  float lowSide = 0.5 + 0.5 * dot(nrm, -L);
  float drift = 0.82 + 0.18 * sin(a * 3.0 + time * 1.3) * sin(a * 2.0 - time * 0.7 + 1.0);
  float corona = mix(0.3, 1.1, uAiFilm) * (0.35 + 0.65 * ready) * (0.4 + 0.6 * lowSide) * drift * (1.0 + 0.5 * press);
  vec3 coronaCol = mix(blue, iris, 0.25 + 0.45 * (1.0 - lowSide));
  float xo = max(sd, 0.0) / (R * 0.2);
  float outer = corona / (1.0 + xo * xo);
  outer *= 1.0 - smoothstep(reach * 0.5, reach, sd);
  vec3 outC = coronaCol * outer * 0.8;
  float outA = clamp(outer * 0.6, 0.0, 1.0);

  // dark soft-touch sphere: broad wrapped key from the upper right, no highlight
  vec2 q = p / R;
  float r2 = min(dot(q, q), 1.0);
  float z = sqrt(1.0 - r2);
  vec3 N = vec3(q, z);
  vec3 Ld = normalize(vec3(L * 0.7, 0.7));
  float wrap = clamp((dot(N, Ld) + 0.4) / 1.4, 0.0, 1.0);
  vec3 col = vec3(0.028, 0.034, 0.052) + vec3(0.085, 0.095, 0.125) * wrap * wrap * 0.9;

  // backlight bleeding softly in through the edge
  float e = R - d;
  col += coronaCol * corona * exp(-max(e, 0.0) / (R * 0.09)) * 0.4;

  // debossed matte plus
  float crossA = clamp(0.5 - crossD / aaC, 0.0, 1.0) * uAiCross;
  float crossSh = clamp(0.5 - crossS / aaC, 0.0, 1.0) * uAiCross * (1.0 - crossA);
  float crossHi = clamp(0.5 - crossH / aaC, 0.0, 1.0) * uAiCross * (1.0 - crossA);
  col *= 1.0 - 0.4 * crossSh;
  col += frost * 0.035 * crossHi;
  col = mix(col, frost * 0.75, crossA * 0.42);

  // fine soft-touch grain
  col += (randFibo(floor(shapeSample.localPosition) + 0.37) - 0.5) * 0.04;

  col = clamp(col + deband(), 0.0, 1.0);
  float discA = clamp(0.5 - sd / aa, 0.0, 1.0);
  vec4 res = vec4(col * discA, discA) + vec4(outC, outA) * (1.0 - discA);
  return res * uFillAlpha;
}
