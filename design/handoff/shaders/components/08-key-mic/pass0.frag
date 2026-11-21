// Unicorn Studio shape treatment (shadeShape) source for layer 79b527f4-904c-4379-8516-92fa50f84e12
// Not standalone: the engine prepends ShapeSample, sdBox/sdRoundedBox/rotate2D, TAU/PI, uFillAlpha, uBorderRadius
// and calls shadeShape() per fragment. See pass0.compiled.frag for the full runnable GLSL ES 3.0 (control values baked in).

uniform float uTime;
uniform float uAiListen;
uniform float uAiLevel;
uniform float uAiPress;
uniform float uAiLightAngle;

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

// light swirling inside the glass: x = distance to the nearest sheet, y = colour mix
vec2 lightField(vec3 p, float t) {
  vec3 q = p * 1.35;
  q.xy = rotate2D(q.xy, t);
  q.xz = rotate2D(q.xz, t * 0.3 + 0.8);
  q += 0.32 * sin(q.zxy * 2.1 + vec3(0.0, 1.7, 3.1) + t * 0.35);
  q += 0.16 * sin(q.yzx * 3.7 + vec3(2.3, 0.4, 1.1) - t * 0.5);
  float s = sin(q.x * 2.7 + q.y * 1.2) + sin(q.y * 2.3 - q.z * 1.8 + 1.4) + sin(q.z * 2.5 + q.x * 1.6 + 2.6);
  float hue = 0.5 + 0.5 * sin(q.x * 1.3 - q.z * 1.1 + q.y * 0.8 + 0.7);
  return vec2(s, hue);
}

float sdSeg(vec2 p, vec2 a, vec2 b) {
  vec2 pa = p - a;
  vec2 ba = b - a;
  float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
  return length(pa - ba * h);
}

// mic glyph about its centre, about 22px tall at s = 1.13
float micGlyph(vec2 p, float s) {
  p /= s;
  float head = sdRoundedBox(p - vec2(0.0, -4.0), vec2(3.6, 6.0), 3.6);
  vec2 u = p - vec2(0.0, -2.5);
  float arc = (u.y < 0.0) ? length(vec2(abs(u.x) - 6.6, u.y)) : abs(length(u) - 6.6);
  float stem = sdSeg(p, vec2(0.0, 4.1), vec2(0.0, 7.8));
  float base = sdSeg(p, vec2(-3.8, 8.6), vec2(3.8, 8.6));
  float strokes = min(arc, min(stem, base)) - 0.85;
  return min(head, strokes) * s;
}

// ten rounded bars between x0 and x1, heights moving like live speech
float waveBars(vec2 p, float x0, float x1, float maxH, float t, float level) {
  float dmin = 1e5;
  for (int i = 0; i < 10; i++) {
    float fi = float(i);
    float x = mix(x0, x1, fi / 9.0);
    float env = 1.0 - abs(fi - 4.5) / 6.5;
    float a = abs(sin(t * 3.1 + fi * 1.37) * sin(t * 1.9 + fi * 0.71 + 1.0));
    float hh = mix(1.2, maxH, clamp(a * env * (0.45 + 0.9 * level), 0.0, 1.0));
    dmin = min(dmin, sdRoundedBox(p - vec2(x, 0.0), vec2(1.15, hh), 1.15));
  }
  return dmin;
}

vec4 shadeShape(ShapeSample shapeSample) {
  vec2 size = shapeSample.elementSize;
  float press = clamp(uAiPress, 0.0, 1.0);
  float listen = clamp(uAiListen, 0.0, 1.0);
  float level = clamp(uAiLevel, 0.0, 1.0);
  vec2 p = (shapeSample.localPosition - size * 0.5) / (1.0 - 0.05 * press);
  vec2 hs = size * 0.5;
  float rad = min(hs.x, hs.y);
  float sdc = sdRoundedBox(p, hs, rad);
  float aa = max(fwidth(sdc), 0.0001);

  float reach = rad * 0.6;
  if (sdc > reach) {
    return vec4(0.0);
  }

  vec3 deep = vec3(0.639, 0.086, 0.106);
  vec3 red = vec3(0.898, 0.282, 0.302);
  vec3 glowR = vec3(1.0, 0.5, 0.48);
  vec3 white = vec3(0.97, 0.95, 0.95);
  float pulse = 0.5 + 0.5 * sin(uTime * 0.2);
  float live = listen * (0.6 + 0.4 * pulse) * (0.75 + 0.25 * level);

  // outside: a soft diffuse red halo while listening
  float xo = max(sdc, 0.0) / (rad * 0.22);
  float halo = live * 0.22 / (1.0 + xo * xo);
  halo *= 1.0 - smoothstep(reach * 0.5, reach, sdc);
  vec3 outC = red * halo;
  float outA = clamp(halo * 0.6, 0.0, 1.0);

  // capsule form from the nearest point on its core segment
  float segX = max(hs.x - rad, 0.0);
  vec2 c = vec2(clamp(p.x, -segX, segX), 0.0);
  vec2 v = (p - c) / rad;
  float z = sqrt(1.0 - min(dot(v, v), 1.0));
  vec3 N = vec3(v, z);
  float ang = uAiLightAngle * TAU;
  vec2 L = vec2(cos(ang), sin(ang));
  vec3 Ld = normalize(vec3(L * 0.7, 0.7));
  float wrap = clamp((dot(N, Ld) + 0.5) / 1.5, 0.0, 1.0);

  // matte soft-touch red: flat colour, a soft form shade, gentle occlusion at the lower edge
  vec3 base = mix(mix(deep, red, 0.55), mix(red, vec3(1.0, 0.4, 0.4), 0.2), listen);
  vec3 col = base * (0.8 + 0.26 * wrap);
  col *= mix(0.86, 1.0, smoothstep(-0.2, 0.9, -v.y * 0.5 + z));
  col *= 1.0 + 0.12 * press;

  // soft diffuse red inner glow while listening
  float e = max(-sdc, 0.0);
  col += glowR * live * (0.32 * exp(-e / 5.0) + 0.14 * exp(-e / 14.0));

  // white matte mic glyph; when listening it slides to the left end and a waveform fills the rest
  float slide = smoothstep(0.0, 1.0, listen);
  vec2 gc = vec2(mix(0.0, -segX, slide), 0.0);
  float gS = rad / 28.0 * 1.13 * mix(1.0, 0.82, slide);
  float glyph = micGlyph(p - gc, gS);
  float gA = clamp(0.5 - glyph / 0.8, 0.0, 1.0);
  float bars = waveBars(p, -segX + rad * 0.62, segX + rad * 0.25, rad * 0.36, uTime * 0.1, level);
  float bA = clamp(0.5 - bars / 0.8, 0.0, 1.0) * smoothstep(0.35, 1.0, listen);
  col = mix(col, white, max(gA, bA) * 0.94);

  // fine soft-touch grain
  col += (randFibo(floor(shapeSample.localPosition) + 0.53) - 0.5) * 0.045;

  col = clamp(col + deband(), 0.0, 1.0);
  float bodyA = clamp(0.5 - sdc / aa, 0.0, 1.0);
  vec4 res = vec4(col * bodyA, bodyA) + vec4(outC, outA) * (1.0 - bodyA);
  return res * uFillAlpha;
}
