// Unicorn Studio shape treatment (shadeShape) source for layer 6369005a-8b02-4d79-b2d0-6a633c6e7ee2
// Not standalone: the engine prepends ShapeSample, sdBox/sdRoundedBox/rotate2D, TAU/PI, uFillAlpha, uBorderRadius
// and calls shadeShape() per fragment. See pass0.compiled.frag for the full runnable GLSL ES 3.0 (control values baked in).

uniform float uAiGrain;
uniform float uAiHairline;

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

vec4 shadeShape(ShapeSample shapeSample) {
  float alpha = shapeSample.coverage * uFillAlpha;
  if (alpha <= 0.0) {
    return vec4(0.0);
  }
  vec2 lp = shapeSample.localPosition;
  vec3 col = shapeSample.fillColor;

  // fine matte grain, about 3% at the default
  col += (randFibo(floor(lp) + 0.71) - 0.5) * mix(0.0, 0.06, uAiGrain);

  // one 1px frost hairline along the top edge (rgba 180,206,255 at 12%)
  float hl = clamp(1.0 - lp.y, 0.0, 1.0);
  col = mix(col, vec3(0.706, 0.808, 1.0), 0.12 * hl * uAiHairline);

  col = clamp(col + deband(), 0.0, 1.0);
  return vec4(col * alpha, alpha);
}
