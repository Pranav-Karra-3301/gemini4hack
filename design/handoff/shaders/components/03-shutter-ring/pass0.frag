// Unicorn Studio shape treatment (shadeShape) source for layer 5ead6365-d0e3-4b4f-b6a6-b5b42de587b9
// Not standalone: the engine prepends ShapeSample, sdBox/sdRoundedBox/rotate2D, TAU/PI, uFillAlpha, uBorderRadius
// and calls shadeShape() per fragment. See pass0.compiled.frag for the full runnable GLSL ES 3.0 (control values baked in).

uniform float uAiScale;
uniform float uAiGlow;
uniform float uAiPress;
uniform float uAiLightAngle;
uniform float uAiBrush;
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

float hashP(float i, float period) {
  float k = mod(i, period);
  return fract(sin(k * 127.1 + 3.7) * 43758.5453);
}

// smooth 1D noise that wraps after `period` cells, so brushing has no seam around the ring
float lineNoise(float x, float period) {
  float i = floor(x);
  float w = x - i;
  w = w * w * (3.0 - 2.0 * w);
  return mix(hashP(i, period), hashP(i + 1.0, period), w);
}

vec4 shadeShape(ShapeSample shapeSample) {
  vec2 size = shapeSample.elementSize;
  vec2 p = shapeSample.localPosition - size * 0.5;
  float press = clamp(uAiPress, 0.0, 1.0);
  float ready = clamp(uAiGlow, 0.0, 1.0);
  float R = min(size.x, size.y) * 0.5 * uAiScale;
  float d = length(p);
  float sd = d - R;
  float aa = max(fwidth(sd), 0.0001);
  float rIn = R * 0.845;
  float rDisc = R * 0.79 * (1.0 - 0.05 * press);
  float arm = R * 0.2115;
  float crossD = min(sdBox(p, vec2(arm, 0.75)), sdBox(p, vec2(0.75, arm)));
  float aaC = max(fwidth(crossD), 0.0001);

  float reach = R * 0.7;
  if (sd > reach) {
    return vec4(0.0);
  }

  float ang = uAiLightAngle * TAU;
  vec2 L = vec2(cos(ang), sin(ang));
  vec2 nrm = p / max(d, 0.0001);
  float facing = dot(nrm, L);
  vec3 frost = vec3(0.933, 0.953, 1.0);
  vec3 blue = vec3(0.298, 0.553, 1.0);
  vec3 hot = vec3(0.706, 0.808, 1.0);

  // outside: faint blue halo when ready
  float xo = max(sd, 0.0) / (R * 0.14);
  float halo = ready * 0.22 / (1.0 + xo * xo);
  halo *= 1.0 - smoothstep(reach * 0.5, reach, sd);
  vec3 outC = blue * halo;
  float outA = clamp(halo * 0.5, 0.0, 1.0);

  // machined ring: matte frost, fine radial brushing, rounded profile, chamfered edges
  float t = clamp((d - rIn) / (R - rIn), 0.0, 1.0);
  float bead = (randFibo(floor(shapeSample.localPosition) + 0.71) - 0.5) * mix(0.0, 0.16, uAiBrush);
  vec3 ringN = normalize(vec3(nrm * (t - 0.5) * 1.6, 1.0));
  vec3 Ld = normalize(vec3(L * 0.7, 0.7));
  float wrap = clamp((dot(ringN, Ld) + 0.35) / 1.35, 0.0, 1.0);
  float ao = mix(0.72, 1.0, smoothstep(0.0, 0.35, t)) * mix(0.88, 1.0, smoothstep(1.0, 0.8, t));
  vec3 ringCol = frost * (0.3 + 0.16 * wrap + 0.05 * facing) * ao * (1.0 + bead);

  // groove between ring and disc, lit blue when ready
  float gMid = (rIn + rDisc) * 0.5;
  vec3 grooveCol = mix(vec3(0.008, 0.01, 0.018), blue * 0.75, ready);
  grooveCol += hot * ready * exp(-abs(d - gMid) / 2.0) * 0.3;

  // solid dark disc with a faint dome toward the light and a chamfer on its lit edge
  vec2 dq = p / rDisc;
  vec3 discCol = vec3(0.039, 0.055, 0.094) * (1.0 + 0.45 * dot(dq, L) * 0.5 - 0.25 * dot(dq, dq)) * (1.0 - 0.3 * press);
  discCol *= mix(0.7, 1.0, smoothstep(0.0, 5.0, rDisc - d));
  discCol *= 1.0 + bead * 0.6;
  float crossA = clamp(0.5 - crossD / aaC, 0.0, 1.0) * uAiCross;
  discCol = mix(discCol, frost, crossA * 0.8);

  float mOut = clamp(0.5 - sd / aa, 0.0, 1.0);
  float mRingIn = clamp(0.5 + (d - rIn) / aa, 0.0, 1.0);
  float mDisc = clamp(0.5 - (d - rDisc) / aa, 0.0, 1.0);
  vec3 col = mix(mix(discCol, grooveCol, 1.0 - mDisc), ringCol, mRingIn);
  col = clamp(col, 0.0, 1.0);

  vec4 res = vec4(col * mOut, mOut) + vec4(outC, outA) * (1.0 - mOut);
  return res * uFillAlpha;
}
