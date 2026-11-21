// Showcase 2D shaders (WebGL2): the flat stages, full-bleed ("cover"). One full-screen pass draws the
// photo, the Depth Pro map and its scan line; the 3D stages are the splat (src/memory3d/). If the
// splat cannot load, the edit below stands in for it on the flat photo.
// Textures are addressed top-left = (0,0) (no UNPACK_FLIP_Y), so uv.y is flipped here.

export const VERT = /* glsl */ `#version 300 es
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`;

export const FRAG = /* glsl */ `#version 300 es
precision highp float;
precision highp sampler2D;

uniform sampler2D uPhoto;   // SRGB8_ALPHA8 + mips: sampled values are linear light
uniform sampler2D uDepth;   // R16F decoded from the packed PNG; log depth, near = 1
uniform sampler2D uMask;    // R8 + mips: the three people
uniform vec2 uRes;          // drawing-buffer size (px)
uniform vec2 uTex;          // photo size (px)
uniform float uDepthMix;    // stage 2: photo -> depth map
uniform float uScan;        // stage 2: scan depth (1 = near ... 0 = far)
uniform float uScanOn;
uniform float uEdit;        // fallback stage 4: the edit (0 = original, hold to compare)
uniform vec3 uFaders;       // fallback stage 4: people EV, warmth, background EV

out vec4 outColor;

const vec3 BLUE = vec3(0.0704, 0.2705, 1.0);    // #4C8DFF, linear

// Log depth -> a disparity-like value so near layers separate the way real parallax does.
float disp(float d) {
  const float K = 4.0;
  return mix(d, (exp(K * d) - 1.0) / (exp(K) - 1.0), 0.6);
}

float depthAt(vec2 uv) { return textureLod(uDepth, uv, 0.0).r; }

vec3 shoulder(vec3 x) {
  const float k = 0.62;
  vec3 over = max(x - k, 0.0);
  return min(x, vec3(k)) + (1.0 - k) * (1.0 - exp(-over / (1.0 - k)));
}

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
float toLin(float c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }
vec3 toSRGB(vec3 c) {
  c = clamp(c, 0.0, 1.0);
  return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

void main() {
  vec2 uv = vec2(gl_FragCoord.x / uRes.x, 1.0 - gl_FragCoord.y / uRes.y);
  // Cover: fill the screen, crop the photo's long side (matches the 3D view's fovCover()).
  float sa = uRes.x / uRes.y;
  float ta = uTex.x / uTex.y;
  vec2 cover = sa > ta ? vec2(1.0, ta / sa) : vec2(sa / ta, 1.0);
  vec2 p = 0.5 + (uv - 0.5) * cover;
  vec2 gx = dFdx(p);
  vec2 gy = dFdy(p);

  float d = depthAt(p);
  float m = textureGrad(uMask, p, gx, gy).r;
  vec3 photo = textureGrad(uPhoto, p, gx, gy).rgb;
  vec3 col = photo;

  // ---- 2. Depth Pro reads distance --------------------------------------------------------
  col = mix(col, vec3(toLin(pow(d, 1.35))), uDepthMix);

  if (uScanOn > 0.001) {
    float fw = clamp(fwidth(d), 2e-5, 0.004);
    float dd = d - uScan;
    float line = 1.0 - smoothstep(0.7, 1.9, abs(dd) / fw);
    float halo = exp(-abs(dd) / (fw * 7.0));
    float wake = step(0.0, dd) * exp(-dd * 28.0) * step(0.02, d);
    col += BLUE * (0.42 * halo + 0.10 * wake) * uScanOn;
    col = mix(col, BLUE * 1.15, line * uScanOn);
  }

  // ---- 4. Gemini edits by light (fallback when the 3D memory is unavailable) ---------------
  if (uEdit > 0.001) {
    float mS = textureLod(uMask, p, 3.0).r;
    float mSoft = clamp(max(m, mS * 0.85), 0.0, 1.0);
    float far = 1.0 - disp(d);
    float bgW = (1.0 - mSoft) * smoothstep(0.1, 0.8, far);
    float base = max(0.0, log2(max(length(gx * uTex), length(gy * uTex))));
    float soft = clamp(-uFaders.z / 0.3, 0.0, 1.0);
    vec3 e = textureLod(uPhoto, p, base + 1.4 * bgW * soft).rgb;
    e *= exp2(uFaders.x * mSoft);
    e = mix(e, shoulder(e), mSoft * clamp(uFaders.x / 0.6, 0.0, 1.0));
    e *= exp2(uFaders.z * bgW);
    float w = uFaders.y / 100.0;
    e *= vec3(1.0 + 0.75 * w, 1.0 + 0.1 * w, 1.0 - 0.95 * w);
    col = mix(col, e, uEdit);
  }

  vec3 o = toSRGB(col);
  float n = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
  outColor = vec4(o + (n - 0.5) / 255.0, 1.0);
}`;
