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
vec2 p = localPos - halfSize;return vec3(0.7019607843137254, 0.08627450980392157, 0.10980392156862745);
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
halfSize = elementSizePx * 0.5;float radiusPx = 1.0000 * min(halfSize.x, halfSize.y);
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
}float sdSeg(vec2 p, vec2 a, vec2 b) {
vec2 pa = p - a;
vec2 ba = b - a;
float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
return length(pa - ba * h);
}float micGlyph(vec2 p, float s) {
p /= s;
float head = sdRoundedBox(p - vec2(0.0, -4.0), vec2(3.6, 6.0), 3.6);
vec2 u = p - vec2(0.0, -2.5);
float arc = (u.y < 0.0) ? length(vec2(abs(u.x) - 6.6, u.y)) : abs(length(u) - 6.6);
float stem = sdSeg(p, vec2(0.0, 4.1), vec2(0.0, 7.8));
float base = sdSeg(p, vec2(-3.8, 8.6), vec2(3.8, 8.6));
float strokes = min(arc, min(stem, base)) - 0.85;
return min(head, strokes) * s;
}float waveBars(vec2 p, float x0, float x1, float maxH, float t, float level) {
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
}vec4 shadeShape(ShapeSample shapeSample) {
vec2 size = shapeSample.elementSize;
float press = clamp(0.0000, 0.0, 1.0);
float listen = clamp(0.0000, 0.0, 1.0);
float level = clamp(0.6000, 0.0, 1.0);
vec2 p = (shapeSample.localPosition - size * 0.5) / (1.0 - 0.05 * press);
vec2 hs = size * 0.5;
float rad = min(hs.x, hs.y);
float sdc = sdRoundedBox(p, hs, rad);
float aa = max(fwidth(sdc), 0.0001);float reach = rad * 0.6;
if (sdc > reach) {
return vec4(0.0);
}vec3 deep = vec3(0.639, 0.086, 0.106);
vec3 red = vec3(0.898, 0.282, 0.302);
vec3 glowR = vec3(1.0, 0.5, 0.48);
vec3 white = vec3(0.97, 0.95, 0.95);
float pulse = 0.5 + 0.5 * sin(uTime * 0.2);
float live = listen * (0.6 + 0.4 * pulse) * (0.75 + 0.25 * level);
float xo = max(sdc, 0.0) / (rad * 0.22);
float halo = live * 0.22 / (1.0 + xo * xo);
halo *= 1.0 - smoothstep(reach * 0.5, reach, sdc);
vec3 outC = red * halo;
float outA = clamp(halo * 0.6, 0.0, 1.0);
float segX = max(hs.x - rad, 0.0);
vec2 c = vec2(clamp(p.x, -segX, segX), 0.0);
vec2 v = (p - c) / rad;
float z = sqrt(1.0 - min(dot(v, v), 1.0));
vec3 N = vec3(v, z);
float ang = 0.8750 * TAU;
vec2 L = vec2(cos(ang), sin(ang));
vec3 Ld = normalize(vec3(L * 0.7, 0.7));
float wrap = clamp((dot(N, Ld) + 0.5) / 1.5, 0.0, 1.0);
vec3 base = mix(mix(deep, red, 0.55), mix(red, vec3(1.0, 0.4, 0.4), 0.2), listen);
vec3 col = base * (0.8 + 0.26 * wrap);
col *= mix(0.86, 1.0, smoothstep(-0.2, 0.9, -v.y * 0.5 + z));
col *= 1.0 + 0.12 * press;
float e = max(-sdc, 0.0);
col += glowR * live * (0.32 * exp(-e / 5.0) + 0.14 * exp(-e / 14.0));
float slide = smoothstep(0.0, 1.0, listen);
vec2 gc = vec2(mix(0.0, -segX, slide), 0.0);
float gS = rad / 28.0 * 1.13 * mix(1.0, 0.82, slide);
float glyph = micGlyph(p - gc, gS);
float gA = clamp(0.5 - glyph / 0.8, 0.0, 1.0);
float bars = waveBars(p, -segX + rad * 0.62, segX + rad * 0.25, rad * 0.36, uTime * 0.1, level);
float bA = clamp(0.5 - bars / 0.8, 0.0, 1.0) * smoothstep(0.35, 1.0, listen);
col = mix(col, white, max(gA, bA) * 0.94);
col += (randFibo(floor(shapeSample.localPosition) + 0.53) - 0.5) * 0.045;col = clamp(col + deband(), 0.0, 1.0);
float bodyA = clamp(0.5 - sdc / aa, 0.0, 1.0);
vec4 res = vec4(col * bodyA, bodyA) + vec4(outC, outA) * (1.0 - bodyA);
return res * 1.0000;
}vec4 sampleShape(vec2 canvasUV) {
vec2 canvasPosPx = vec2(canvasUV.x * uArtboardResolution.x, (1.0 - canvasUV.y) * uArtboardResolution.y);float absWidth = 112.0000;
float absHeight = 56.0000;
vec2 elementSizePx = vec2(absWidth, absHeight);
vec2 elementPosPx = vec2(0.1217, 582.0000) * uArtboardResolution - getAnchorOffsets() * elementSizePx;float dist = sdShape(canvasPosPx, elementPosPx, elementSizePx, 0.0000);
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