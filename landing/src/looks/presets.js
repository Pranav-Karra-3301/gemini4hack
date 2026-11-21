// The looks the section replays, mirrored from the iPhone app (PR #49).
//
// `metal` is the preset's fallback body from apple/CoachCam/CoachCam/Coach/ShaderAgent.swift,
// verbatim (Swift strips the 8-space literal indent): Halftone at lines 272-298, Kodachrome at
// 299-313. `request` is the preset's request and `title` feeds the app's spoken line
// "<title>, live.". `glsl` is the same body ported line for line to GLSL ES 3.00: float3 → vec3,
// float2x2 → mat2 (both column-major, so the constructor and `r * p` mean the same thing),
// src.sample(s, p) → textureLod(src, p, 0.0) (the app's sampler has no mipmaps).
//
// `broken` is the first round as it fails to compile: one line of the body swapped for a
// mistake Neon really makes (a misnamed variable, a GLSL-ism Metal doesn't have). `error` is
// the Metal compiler's message for it. The body starts at line 16 of the full source
// (ShaderAgent.header is 15 lines), so body line n is program_source line n + 15.

export const BODY_LINE = 16;

export const PRESETS = [
  {
    id: 'kodachrome',
    title: 'Kodachrome',
    request: 'Kodachrome 400 slide film',
    metal: `float3 x = c.rgb;
x = float3(x.r * 1.08 + x.g * -0.04, x.g * 0.98 + x.r * 0.02, x.b * 1.04 - x.r * 0.04);
float l = dot(x, float3(0.299, 0.587, 0.114));
x = mix(float3(l), x, 1.18);
x = clamp(x, 0.0, 1.0);
x = x * x * (3.0 - 2.0 * x) * 0.55 + x * 0.45;
x.r = pow(x.r, 0.94);
x.b = pow(x.b, 1.06);
x = mix(x, x * float3(1.04, 1.0, 0.92), smoothstep(0.5, 1.0, l));
float2 p = uv * size;
float g = fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
x += g * 0.06 * (1.0 - abs(l - 0.5) * 1.6);
return float4(x, 1.0);`,
    // body line 12 (0-based 11): `g` written as `grain`
    broken: { line: 11, text: 'x += grain * 0.06 * (1.0 - abs(l - 0.5) * 1.6);', col: 6, error: "use of undeclared identifier 'grain'" },
    glsl: `
vec3 x = c.rgb;
x = vec3(x.r * 1.08 + x.g * -0.04, x.g * 0.98 + x.r * 0.02, x.b * 1.04 - x.r * 0.04);
float l = dot(x, vec3(0.299, 0.587, 0.114));
x = mix(vec3(l), x, 1.18);
x = clamp(x, 0.0, 1.0);
x = x * x * (3.0 - 2.0 * x) * 0.55 + x * 0.45;
x.r = pow(x.r, 0.94);
x.b = pow(x.b, 1.06);
x = mix(x, x * vec3(1.04, 1.0, 0.92), smoothstep(0.5, 1.0, l));
vec2 p = uv * size;
float g = fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
x += g * 0.06 * (1.0 - abs(l - 0.5) * 1.6);
return vec4(x, 1.0);`,
  },
  {
    id: 'halftone',
    title: 'Halftone',
    request: 'CMYK halftone print, rotated dot screens on paper',
    metal: `float cell = max(size.x, size.y) / 140.0;
float2 px = uv * size;
float3 paper = float3(0.97, 0.95, 0.90);
float4 angles = float4(0.2618, 1.309, 0.0, 0.7854);
float4 ink = float4(0.0);
for (int i = 0; i < 4; i++) {
    float a = angles[i];
    float2x2 r = float2x2(cos(a), -sin(a), sin(a), cos(a));
    float2 q = r * px;
    float2 center = (floor(q / cell) + 0.5) * cell;
    float2 back = transpose(r) * center;
    float3 cs = src.sample(s, back / size).rgb;
    float k = 1.0 - max(cs.r, max(cs.g, cs.b));
    float denom = max(1.0 - k, 0.001);
    float4 cmyk = float4((1.0 - cs.r - k) / denom, (1.0 - cs.g - k) / denom, (1.0 - cs.b - k) / denom, k);
    float rad = sqrt(clamp(cmyk[i], 0.0, 1.0)) * cell * 0.62;
    float d = length(q - center);
    ink[i] = 1.0 - smoothstep(rad - 0.8, rad + 0.8, d);
}
float3 col = paper;
col *= mix(float3(1.0), float3(0.0, 0.62, 0.92), ink.x);
col *= mix(float3(1.0), float3(0.92, 0.10, 0.55), ink.y);
col *= mix(float3(1.0), float3(1.0, 0.92, 0.0), ink.z);
col *= mix(float3(1.0), float3(0.12, 0.12, 0.14), ink.w);
return float4(col, 1.0);`,
    // body line 11 (0-based 10): GLSL's inverse(), which Metal's standard library doesn't have
    broken: { line: 10, text: '    float2 back = inverse(r) * center;', col: 19, error: "use of undeclared identifier 'inverse'" },
    glsl: `
float cell = max(size.x, size.y) / 140.0;
vec2 px = uv * size;
vec3 paper = vec3(0.97, 0.95, 0.90);
vec4 angles = vec4(0.2618, 1.309, 0.0, 0.7854);
vec4 ink = vec4(0.0);
for (int i = 0; i < 4; i++) {
    float a = angles[i];
    mat2 r = mat2(cos(a), -sin(a), sin(a), cos(a));
    vec2 q = r * px;
    vec2 center = (floor(q / cell) + 0.5) * cell;
    vec2 back = transpose(r) * center;
    vec3 cs = textureLod(src, back / size, 0.0).rgb;
    float k = 1.0 - max(cs.r, max(cs.g, cs.b));
    float denom = max(1.0 - k, 0.001);
    vec4 cmyk = vec4((1.0 - cs.r - k) / denom, (1.0 - cs.g - k) / denom, (1.0 - cs.b - k) / denom, k);
    float rad = sqrt(clamp(cmyk[i], 0.0, 1.0)) * cell * 0.62;
    float d = length(q - center);
    ink[i] = 1.0 - smoothstep(rad - 0.8, rad + 0.8, d);
}
vec3 col = paper;
col *= mix(vec3(1.0), vec3(0.0, 0.62, 0.92), ink.x);
col *= mix(vec3(1.0), vec3(0.92, 0.10, 0.55), ink.y);
col *= mix(vec3(1.0), vec3(1.0, 0.92, 0.0), ink.z);
col *= mix(vec3(1.0), vec3(0.12, 0.12, 0.14), ink.w);
return vec4(col, 1.0);`,
  },
];

// ShaderAgent.identity: the untouched photo before the first look.
export const IDENTITY_GLSL = 'return c;';

// The fragment around a body, as ShaderAgent.header/footer wrap it: c is the sRGB-encoded source
// pixel (the texture is loaded without sRGB decode), uv is top-left origin, size is the image in
// pixels, and the result is clamped and drawn at alpha `mix` for the 0.7 s crossfade.
// `u_crop` maps the canvas onto a cover-fitted window of the photo (the mobile frame is square).
export const VERTEX = `#version 300 es
out vec2 v_uv;
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)) * 2.0 - 1.0;
  v_uv = vec2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
  gl_Position = vec4(p, 0.0, 1.0);
}`;

export const fragment = (body) => `#version 300 es
precision highp float;
precision highp int;
uniform sampler2D src;
uniform vec2 u_size;
uniform float u_t;
uniform float u_mix;
uniform vec4 u_crop;
in vec2 v_uv;
out vec4 outColor;

vec4 look(vec4 c, vec2 uv, vec2 size, float t) {
${body}
}

void main() {
  vec2 uv = u_crop.xy + v_uv * u_crop.zw;
  vec4 c = texture(src, uv);
  vec4 r = look(c, uv, u_size, u_t);
  outColor = vec4(clamp(r.rgb, 0.0, 1.0), u_mix);
}`;
