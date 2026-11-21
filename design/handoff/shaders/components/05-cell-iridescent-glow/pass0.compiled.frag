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
vec2 p = localPos - halfSize;return vec3(0.027450980392156862, 0.0392156862745098, 0.0784313725490196);
}float sdBox(vec2 p, vec2 b) {
vec2 d = abs(p) - b;
return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}float sdShape(vec2 canvasPosPx, vec2 elementPosPx, vec2 elementSizePx, float rotationTurns) {
vec2 p = vec2(0.0);
vec2 halfSize = vec2(0.0);elementSizePx = abs(elementSizePx);vec2 centerPx = elementPosPx + elementSizePx * 0.5;
vec2 rel = canvasPosPx - centerPx;
vec2 local = rotate2D(rel, -rotationTurns * TAU) + elementSizePx * 0.5;
p = local - elementSizePx * 0.5;
halfSize = elementSizePx * 0.5;
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
}float smoothSeg(float x) {
float t = clamp(x, 0.0, 1.0);
return t * t * (3.0 - 2.0 * t);
}vec3 filmSpectrum(float x) {
float k = (x - floor(x)) * 5.0;
vec3 c = mix(vec3(0.478, 0.655, 1.0), vec3(0.706, 0.549, 1.0), smoothSeg(k));
c = mix(c, vec3(1.0, 0.561, 0.812), smoothSeg(k - 1.0));
c = mix(c, vec3(1.0, 0.761, 0.478), smoothSeg(k - 2.0));
c = mix(c, vec3(0.549, 0.961, 0.824), smoothSeg(k - 3.0));
c = mix(c, vec3(0.478, 0.655, 1.0), smoothSeg(k - 4.0));
return c;
}vec4 shadeShape(ShapeSample shapeSample) {
float alpha = shapeSample.coverage * 1.0000;
if (alpha <= 0.0) {
return vec4(0.0);
}
vec2 size = shapeSample.elementSize;
vec2 hs = size * 0.5;
vec2 p = shapeSample.localPosition - hs;
float e = max(shapeSample.signedDistance, 0.0);
vec3 col = shapeSample.fillColor;
float line = clamp(1.0 - e, 0.0, 1.0);
col = mix(col, vec3(0.706, 0.808, 1.0), line * 0.12);
float intensity = clamp(1.0000, 0.0, 1.0);
float s = atan(p.y / hs.y, p.x / hs.x) / TAU;
float lap = uTime * 0.01389 * mix(0.4, 1.6, 0.5000);
float phase = 2.0 * (s - lap) + e * 0.012;
vec3 film = filmSpectrum(phase);
float shimmer = 0.82 + 0.18 * sin(s * TAU * 3.0 - lap * TAU * 1.7);
float fall = mix(6.0, 20.0, 0.4300);
float ex = max(hs.x - abs(p.x), 0.0);
float ey = max(hs.y - abs(p.y), 0.0);
float gx = 0.62 * exp(-ex / (fall * 0.25)) + 0.38 * exp(-ex / (fall * 0.75));
float gy = 0.62 * exp(-ey / (fall * 0.25)) + 0.38 * exp(-ey / (fall * 0.75));
float g = 0.7 * (gx + gy - gx * gy);
col += film * g * shimmer * intensity;col = clamp(col + deband(), 0.0, 1.0);
return vec4(col * alpha, alpha);
}vec4 sampleShape(vec2 canvasUV) {
vec2 canvasPosPx = vec2(canvasUV.x * uArtboardResolution.x, (1.0 - canvasUV.y) * uArtboardResolution.y);float absWidth = 130.0000;
float absHeight = 84.0000;
vec2 elementSizePx = vec2(absWidth, absHeight);
vec2 elementPosPx = vec2(0.4025, 568.0000) * uArtboardResolution - getAnchorOffsets() * elementSizePx;float dist = sdShape(canvasPosPx, elementPosPx, elementSizePx, 0.0000);
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