// Unicorn Studio shape treatment (shadeShape) source for layer f75e82a9-1129-4a19-ba76-0e9e6e0f24d0
// Not standalone: the engine prepends ShapeSample, sdBox/sdRoundedBox/rotate2D, TAU/PI, uFillAlpha, uBorderRadius
// and calls shadeShape() per fragment. See pass0.compiled.frag for the full runnable GLSL ES 3.0 (control values baked in).

uniform float uTime;
uniform float uAiIntensity;
uniform float uAiReach;
uniform float uAiLapSpeed;

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

vec4 shadeShape(ShapeSample shapeSample) {
  float alpha = shapeSample.coverage * uFillAlpha;
  if (alpha <= 0.0) {
    return vec4(0.0);
  }
  vec2 size = shapeSample.elementSize;
  vec2 hs = size * 0.5;
  vec2 p = shapeSample.localPosition - hs;
  float e = max(shapeSample.signedDistance, 0.0);
  vec3 col = shapeSample.fillColor;

  // 1px hairline at 12%
  float line = clamp(1.0 - e, 0.0, 1.0);
  col = mix(col, vec3(0.706, 0.808, 1.0), line * 0.12);

  // iridescent film flowing around the inside edge, one lap every ~2.4 s
  float intensity = clamp(uAiIntensity, 0.0, 1.0);
  float s = atan(p.y / hs.y, p.x / hs.x) / TAU;
  float lap = uTime * 0.01389 * mix(0.4, 1.6, uAiLapSpeed);
  float phase = 2.0 * (s - lap) + e * 0.012;
  vec3 film = filmSpectrum(phase);
  float shimmer = 0.82 + 0.18 * sin(s * TAU * 3.0 - lap * TAU * 1.7);
  float fall = mix(6.0, 20.0, uAiReach);
  float ex = max(hs.x - abs(p.x), 0.0);
  float ey = max(hs.y - abs(p.y), 0.0);
  float gx = 0.62 * exp(-ex / (fall * 0.25)) + 0.38 * exp(-ex / (fall * 0.75));
  float gy = 0.62 * exp(-ey / (fall * 0.25)) + 0.38 * exp(-ey / (fall * 0.75));
  float g = 0.7 * (gx + gy - gx * gy);
  col += film * g * shimmer * intensity;

  col = clamp(col + deband(), 0.0, 1.0);
  return vec4(col * alpha, alpha);
}
