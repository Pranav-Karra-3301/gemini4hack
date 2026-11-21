// Unicorn Studio shape treatment (shadeShape) source for layer 7a53b606-7d06-4e50-a28e-b786cec2e5d0
// Not standalone: the engine prepends ShapeSample, sdBox/sdRoundedBox/rotate2D, TAU/PI, uFillAlpha, uBorderRadius
// and calls shadeShape() per fragment. See pass0.compiled.frag for the full runnable GLSL ES 3.0 (control values baked in).

uniform float uTime;
uniform float uAiDirection;
uniform float uAiStrength;
uniform float uAiPulse;
uniform float uAiShimmer;

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

vec2 guideDir(int di) {
  vec2 dir = vec2(-1.0, 0.0);
  if (di == 1) {
    dir = vec2(1.0, 0.0);
  } else if (di == 2) {
    dir = vec2(0.0, -1.0);
  } else if (di == 3) {
    dir = vec2(0.0, 1.0);
  } else if (di == 4 || di == 8) {
    dir = vec2(-0.7071, -0.7071);
  } else if (di == 5 || di == 9) {
    dir = vec2(0.7071, -0.7071);
  } else if (di == 6) {
    dir = vec2(-0.7071, 0.7071);
  } else if (di == 7) {
    dir = vec2(0.7071, 0.7071);
  }
  return dir;
}

vec4 shadeShape(ShapeSample shapeSample) {
  vec2 size = shapeSample.elementSize;
  vec2 hs = size * 0.5;
  vec2 p = shapeSample.localPosition - hs;
  float rad = uBorderRadius * min(hs.x, hs.y);
  float sdv = sdRoundedBox(p, hs, rad);
  float aa = max(fwidth(sdv), 0.0001);
  if (sdv > 18.0) {
    return vec4(0.0);
  }

  vec3 blue = vec3(0.298, 0.553, 1.0);
  vec3 hot = vec3(0.706, 0.808, 1.0);
  float time = uTime * 0.0262;
  float strength = clamp(uAiStrength, 0.0, 1.0);
  float pulse = clamp(uAiPulse, 0.0, 1.0);

  // which part of the border points where the camera should go
  int di = int(uAiDirection + 0.5);
  vec2 dir = guideDir(di);
  vec2 nd = normalize(p / hs + vec2(0.0001));
  float align = dot(nd, dir);
  float lo = 0.35;
  float hi = 0.82;
  if (di >= 8) {
    align = abs(align);
    lo = 0.72;
    hi = 0.97;
  } else if (di >= 4) {
    lo = 0.45;
    hi = 0.86;
  }
  float w = smoothstep(lo, hi, align);
  float cornerHot = di >= 4 ? smoothstep(0.93, 1.0, align) : 0.0;

  // slow shimmer travelling along the edge
  float s = atan(p.y / hs.y, p.x / hs.x) / TAU;
  float travel = s * 3.0 - time * 0.35;
  float band = exp(-pow(travel - floor(travel) - 0.5, 2.0) * 30.0);
  float sh = 0.8 + 0.2 * sin(s * TAU * 7.0 - time * 1.6) + 0.45 * band;
  sh = mix(1.0, sh, uAiShimmer);

  // profile: hot line at the edge, blue falloff about 40px in, slight bleed outside
  float ein = max(-sdv, 0.0);
  float edgeHot = exp(-ein / 1.6);
  float fallB = 0.55 * exp(-ein / 9.0) + 0.45 * exp(-ein / 26.0);
  float guide = w * strength * sh;
  vec3 glowIn = hot * edgeHot * (0.95 * guide + 0.6 * pulse + 0.5 * cornerHot * strength) + blue * fallB * (0.8 * guide + 0.42 * pulse);
  float outside = smoothstep(-0.5, 0.5, sdv) * exp(-max(sdv, 0.0) / 5.0);
  vec3 glowOut = (blue * 0.55 + hot * 0.2) * outside * (guide + 0.6 * pulse);
  float aOut = clamp(glowOut.b * 0.7, 0.0, 1.0);

  // photo-less viewfinder: dark panel, faintly lifted centre, 1px hairline
  vec3 base = mix(vec3(0.03, 0.043, 0.082), shapeSample.fillColor, smoothstep(0.1, 1.2, length(p / hs)));
  base = mix(base, vec3(0.706, 0.808, 1.0), 0.12 * clamp(1.0 - abs(ein - 0.5), 0.0, 1.0));
  vec3 colIn = clamp(base + glowIn + deband(), 0.0, 1.0);

  float inside = clamp(0.5 - sdv / aa, 0.0, 1.0);
  vec4 res = vec4(colIn * inside, inside) + vec4(glowOut, aOut) * (1.0 - inside);
  return res * uFillAlpha;
}
