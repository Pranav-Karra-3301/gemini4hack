// Unicorn Studio shape treatment (shadeShape) source for layer 16a179ad-d7f6-4c54-98df-a43656c5857b
// Not standalone: the engine prepends ShapeSample, sdBox/sdRoundedBox/rotate2D, TAU/PI, uFillAlpha, uBorderRadius
// and calls shadeShape() per fragment. See pass0.compiled.frag for the full runnable GLSL ES 3.0 (control values baked in).

uniform float uTime;
uniform float uAiScale;
uniform float uAiGlow;
uniform float uAiVoice;
uniform float uAiPress;
uniform float uAiLightAngle;
uniform float uAiSwirl;
uniform float uAiCross;
uniform float uAiGrain;

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

// Swirling sheets of light inside the glass: x = signed distance to the nearest sheet, y = blue-to-iris mix
vec2 lightField(vec3 p, float t, float agitate) {
  vec3 q = p * 1.35;
  q.xy = rotate2D(q.xy, t);
  q.xz = rotate2D(q.xz, t * 0.3 + 0.8);
  q += (0.30 + 0.14 * agitate) * sin(q.zxy * 2.1 + vec3(0.0, 1.7, 3.1) + t * 0.35);
  q += 0.16 * sin(q.yzx * 3.7 + vec3(2.3, 0.4, 1.1) - t * 0.5);
  float s = sin(q.x * 2.7 + q.y * 1.2) + sin(q.y * 2.3 - q.z * 1.8 + 1.4) + sin(q.z * 2.5 + q.x * 1.6 + 2.6);
  float hue = 0.5 + 0.5 * sin(q.x * 1.3 - q.z * 1.1 + q.y * 0.8 + 0.7);
  return vec2(s, hue);
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

  float reach = R * 1.1;
  if (sd > reach) {
    return vec4(0.0);
  }

  vec3 blue = vec3(0.298, 0.553, 1.0);
  vec3 iris = vec3(0.604, 0.486, 0.965);
  vec3 frost = vec3(0.933, 0.953, 1.0);
  float time = uTime * 0.0262;
  float voice = clamp(uAiVoice, 0.0, 1.0) * (0.7 + 0.3 * sin(uTime * 0.21));
  float glowGain = (0.55 + 0.75 * ready) * (1.0 + 0.9 * voice) * (1.0 + 0.6 * press) * 2.4;

  // outside: a soft diffuse halo, leaning to the lit low-left side
  vec2 nrm = p / max(d, 0.0001);
  float lowSide = 0.5 + 0.5 * dot(nrm, -L);
  float xo = max(sd, 0.0) / (R * 0.28);
  float halo = (0.05 + 0.3 * ready) * (1.0 + 0.6 * voice) / (1.0 + xo * xo);
  halo *= 1.0 - smoothstep(reach * 0.45, reach, sd);
  vec3 outC = mix(blue, iris, 0.35 * lowSide) * halo * (0.7 + 0.5 * lowSide);
  float outA = clamp(halo * 0.6, 0.0, 1.0);

  // milky sphere
  vec2 q = p / R;
  float r2 = min(dot(q, q), 1.0);
  float z = sqrt(1.0 - r2);
  vec3 N = vec3(q, z);

  // inner light low and to the left of centre, scattered through the milky body
  vec3 src = vec3(-L * 0.42 + vec2(0.0, 0.1), 0.2);
  vec3 toS = N * 0.92 - src;
  float scatter = 1.0 / (1.0 + dot(toS, toS) * 7.0);
  vec2 f = lightField(N * 0.55, time * mix(0.25, 1.75, uAiSwirl) * 0.6, ready);
  float density = 0.86 + 0.14 * exp(-abs(f.x) * 0.8);
  vec3 glowCol = mix(blue, iris, 0.55 * smoothstep(0.55, 1.35, length(toS)));
  vec3 inner = glowCol * scatter * density * glowGain;
  inner += frost * scatter * scatter * 0.55 * glowGain;

  // matte shell: dim milky base, broad soft key from the upper right, gentle limb falloff
  vec3 Ld = normalize(vec3(L * 0.7, 0.7));
  float lambert = max(dot(N, Ld), 0.0);
  vec3 col = vec3(0.04, 0.05, 0.085) * (0.6 + 0.4 * z);
  col += vec3(0.11, 0.14, 0.21) * lambert * 0.32;
  col += inner * (0.5 + 0.5 * z);

  // debossed matte plus
  float crossA = clamp(0.5 - crossD / aaC, 0.0, 1.0) * uAiCross;
  float crossSh = clamp(0.5 - crossS / aaC, 0.0, 1.0) * uAiCross * (1.0 - crossA);
  float crossHi = clamp(0.5 - crossH / aaC, 0.0, 1.0) * uAiCross * (1.0 - crossA);
  col *= 1.0 - 0.35 * crossSh;
  col += frost * 0.04 * crossHi;
  col = mix(col, frost * 0.8, crossA * 0.5);

  // fine grain, like a frosted diffuser
  col += (randFibo(floor(shapeSample.localPosition) + 0.37) - 0.5) * mix(0.0, 0.06, uAiGrain);

  col = clamp(col + deband(), 0.0, 1.0);
  float discA = clamp(0.5 - sd / aa, 0.0, 1.0);
  vec4 res = vec4(col * discA, discA) + vec4(outC, outA) * (1.0 - discA);
  return res * uFillAlpha;
}
