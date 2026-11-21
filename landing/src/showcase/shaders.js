// Showcase 2D shader (WebGL2): the opening photo, full-bleed ("cover"), in one full-screen pass; the
// 3D stages are the splat (src/memory3d/). If the splat cannot load, the distance-weighted light edit
// below stands in for it on the flat photo.
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
uniform sampler2D uDepth;   // fallback edit: R16F decoded from the packed PNG; log depth, near = 1
uniform sampler2D uMask;    // fallback edit: R8 + mips, the three people
uniform vec2 uRes;          // drawing-buffer size (px)
uniform vec2 uTex;          // photo size (px)
uniform float uEdit;        // fallback edit (0 = original, hold to compare); depth + mask bound only when > 0
uniform vec3 uFaders;       // fallback edit: people EV, warmth, background EV

out vec4 outColor;

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

  vec3 col = textureGrad(uPhoto, p, gx, gy).rgb;

  // ---- Gemini lights it by distance (fallback when the 3D scene is unavailable) ------------
  if (uEdit > 0.001) {
    float d = depthAt(p);
    float m = textureGrad(uMask, p, gx, gy).r;
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
