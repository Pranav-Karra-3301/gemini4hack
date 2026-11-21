#version 300 es
// Copyright (c) Unicorn Studio. Licensed under the Unicorn Studio Commercial License.
// Unauthorized copying, redistribution, or use in competing products is prohibited.
precision highp float;in vec2 vTextureCoord;
in vec3 vVertexPosition;uniform vec2 uArtboardResolution;uniform vec2 uResolution;
uniform vec2 uMousePos;
uniform sampler2D uBgTexture;const float TAU = 6.28318530718;
const float PI = 3.14159265359;out vec4 fragColor;vec2 rotate2D(vec2 p, float angle) {
float s = sin(angle);
float c = cos(angle);
return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}vec2 getAnchorOffsets() {
return vec2(0.5, 0.5);
}vec3 getFillColor(vec2 localPos, vec2 elementSize, float signedDist, float maxInset) {
vec2 halfSize = elementSize * 0.5;
vec2 p = localPos - halfSize;return vec3(0.0196078431372549, 0.027450980392156862, 0.050980392156862744);
}float sdBox(vec2 p, vec2 b) {
vec2 d = abs(p) - b;
return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}float sdRoundedBox(vec2 p, vec2 b, float r) {
vec2 q = abs(p) - (b - vec2(r));
return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}float sdShape(vec2 canvasPosPx, vec2 elementPosPx, vec2 elementSizePx, float rotationTurns) {
vec2 p = vec2(0.0);
vec2 halfSize = vec2(0.0);elementSizePx = abs(elementSizePx);vec2 centerPx = elementPosPx + elementSizePx * 0.5;
vec2 rel = canvasPosPx - centerPx;
vec2 local = rotate2D(rel, -rotationTurns * TAU) + elementSizePx * 0.5;
p = local - elementSizePx * 0.5;
halfSize = elementSizePx * 0.5;float radiusPx = 0.2000 * min(halfSize.x, halfSize.y);
radiusPx = clamp(radiusPx, 0.0, min(halfSize.x, halfSize.y));
return sdRoundedBox(p, halfSize, radiusPx);
return sdBox(p, halfSize);
}struct ShapeSample {
float signedDistance;
float coverage;
vec2 localPosition;
vec2 elementSize;
vec3 fillColor;
vec2 mousePosition;
};vec4 shadeShape(ShapeSample shapeSample);uniform float uTime;uvec2 pcg2d(uvec2 v) {
v = v * 1664525u + 1013904223u;
v.x += v.y * v.y * 1664525u + 1013904223u;
v.y += v.x * v.x * 1664525u + 1013904223u;
v ^= v >> 16;
v.x += v.y * v.y * 1664525u + 1013904223u;
v.y += v.x * v.x * 1664525u + 1013904223u;
return v;
}float randFibo(vec2 p) {
uvec2 v = floatBitsToUint(p);
v = pcg2d(v);
uint r = v.x ^ v.y;
return float(r) / float(0xffffffffu);
}float deband() {
return (randFibo(gl_FragCoord.xy) - 0.5) / 255.0;
}vec2 guideDir(int di) {
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
}vec4 shadeShape(ShapeSample shapeSample) {
vec2 size = shapeSample.elementSize;
vec2 hs = size * 0.5;
vec2 p = shapeSample.localPosition - hs;
float rad = 0.2000 * min(hs.x, hs.y);
float sdv = sdRoundedBox(p, hs, rad);
float aa = max(fwidth(sdv), 0.0001);
if (sdv > 18.0) {
return vec4(0.0);
}vec3 blue = vec3(0.298, 0.553, 1.0);
vec3 hot = vec3(0.706, 0.808, 1.0);
float time = uTime * 0.0262;
float strength = clamp(0.8500, 0.0, 1.0);
float pulse = clamp(0.0000, 0.0, 1.0);
int di = int(0.0000 + 0.5);
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
float s = atan(p.y / hs.y, p.x / hs.x) / TAU;
float travel = s * 3.0 - time * 0.35;
float band = exp(-pow(travel - floor(travel) - 0.5, 2.0) * 30.0);
float sh = 0.8 + 0.2 * sin(s * TAU * 7.0 - time * 1.6) + 0.45 * band;
sh = mix(1.0, sh, 0.7000);
float ein = max(-sdv, 0.0);
float edgeHot = exp(-ein / 1.6);
float fallB = 0.55 * exp(-ein / 9.0) + 0.45 * exp(-ein / 26.0);
float guide = w * strength * sh;
vec3 glowIn = hot * edgeHot * (0.95 * guide + 0.6 * pulse + 0.5 * cornerHot * strength) + blue * fallB * (0.8 * guide + 0.42 * pulse);
float outside = smoothstep(-0.5, 0.5, sdv) * exp(-max(sdv, 0.0) / 5.0);
vec3 glowOut = (blue * 0.55 + hot * 0.2) * outside * (guide + 0.6 * pulse);
float aOut = clamp(glowOut.b * 0.7, 0.0, 1.0);
vec3 base = mix(vec3(0.03, 0.043, 0.082), shapeSample.fillColor, smoothstep(0.1, 1.2, length(p / hs)));
base = mix(base, vec3(0.706, 0.808, 1.0), 0.12 * clamp(1.0 - abs(ein - 0.5), 0.0, 1.0));
vec3 colIn = clamp(base + glowIn + deband(), 0.0, 1.0);float inside = clamp(0.5 - sdv / aa, 0.0, 1.0);
vec4 res = vec4(colIn * inside, inside) + vec4(glowOut, aOut) * (1.0 - inside);
return res * 1.0000;
}vec4 sampleShape(vec2 canvasUV) {
vec2 canvasPosPx = vec2(canvasUV.x * uArtboardResolution.x, (1.0 - canvasUV.y) * uArtboardResolution.y);float absWidth = 300.0000;
float absHeight = 460.0000;
vec2 elementSizePx = vec2(absWidth, absHeight);
vec2 elementPosPx = vec2(0.8000, 380.0000) * uArtboardResolution - getAnchorOffsets() * elementSizePx;float dist = sdShape(canvasPosPx, elementPosPx, elementSizePx, 0.0000);
float aa = max(length(vec2(dFdx(dist), dFdy(dist))), 0.75);
float uvGrad = max(length(dFdx(canvasUV)), length(dFdy(canvasUV)));
float seamFactor = smoothstep(0.01, 0.03, uvGrad);
aa = mix(aa, 0.75, seamFactor);float fillAlpha = 1.0 - smoothstep(mix(0.0, -150., 0.0000), mix(aa, 150., 0.0000), dist);
fillAlpha = mix(fillAlpha, step(dist, 0.0), seamFactor);
vec2 localPos;
localPos = rotate2D(canvasPosPx - (elementPosPx + elementSizePx * 0.5), 0.0000 * -TAU) + elementSizePx * 0.5;
vec2 localSize;
localSize = elementSizePx;vec2 centerPx;
centerPx = elementPosPx + elementSizePx * 0.5;
float centerDist = sdShape(centerPx, elementPosPx, elementSizePx, 0.0000);
float maxInset = max(-centerDist, 0.00001);vec3 fillRgb = getFillColor(localPos, localSize, dist, maxInset);vec2 mouseCanvasPosPx = vec2(uMousePos.x, 1.0 - uMousePos.y) * uArtboardResolution;
vec2 mousePosition = localPos + rotate2D(mouseCanvasPosPx - canvasPosPx, 0.0000 * -TAU);
vec4 fill = shadeShape(ShapeSample(-dist, fillAlpha, localPos, localSize, fillRgb, mousePosition));float strokeAlpha = 0.0;
vec4 stroke = vec4(vec3(0, 0, 0) * strokeAlpha, strokeAlpha);
vec4 col = stroke + fill * (1.0 - stroke.a);
return col;
}vec4 getNormalOutput(vec4 color, vec4 background) {
return mix(background, color + background * (1.0 - color.a), 1.0000);
}vec4 getOutputByMode(vec4 color, vec4 background) {
return getNormalOutput(color, background);
}vec4 getCompositeOutput(vec2 uv) {
vec4 background = vec4(0.0);background = texture(uBgTexture, vTextureCoord);vec4 color = sampleShape(uv);return getOutputByMode(color, background);
}void main() {
vec2 uv = vTextureCoord;
vec2 pos = (uMousePos - 0.5) * 0.0000;uv -= pos;fragColor = getCompositeOutput(uv);
}