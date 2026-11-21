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
vec2 p = localPos - halfSize;return vec3(0.0392156862745098, 0.054901960784313725, 0.09411764705882353);
}float sdBox(vec2 p, vec2 b) {
vec2 d = abs(p) - b;
return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}float sdEllipse(vec2 p, vec2 ab) {
vec2 q = p / ab;
return (length(q) - 1.0) * min(ab.x, ab.y);
}float sdShape(vec2 canvasPosPx, vec2 elementPosPx, vec2 elementSizePx, float rotationTurns) {
vec2 p = vec2(0.0);
vec2 halfSize = vec2(0.0);elementSizePx = abs(elementSizePx);vec2 centerPx = elementPosPx + elementSizePx * 0.5;
vec2 rel = canvasPosPx - centerPx;
vec2 local = rotate2D(rel, -rotationTurns * TAU) + elementSizePx * 0.5;
p = local - elementSizePx * 0.5;
halfSize = elementSizePx * 0.5;return sdEllipse(p, vec2(max(halfSize.x, 0.00001), max(halfSize.y, 0.00001)));
return sdBox(p, halfSize);
}struct ShapeSample {
float signedDistance;
float coverage;
vec2 localPosition;
vec2 elementSize;
vec3 fillColor;
vec2 mousePosition;
};vec4 shadeShape(ShapeSample shapeSample);uvec2 pcg2d(uvec2 v) {
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
}vec4 shadeShape(ShapeSample shapeSample) {
vec2 size = shapeSample.elementSize;
vec2 p = shapeSample.localPosition - size * 0.5;
float press = clamp(0.0000, 0.0, 1.0);
float ready = clamp(0.0000, 0.0, 1.0);
float R = min(size.x, size.y) * 0.5 * 1.0000;
float d = length(p);
float sd = d - R;
float aa = max(fwidth(sd), 0.0001);
float rIn = R * 0.845;
float rDisc = R * 0.79 * (1.0 - 0.05 * press);
float arm = R * 0.2115;
float crossD = min(sdBox(p, vec2(arm, 0.75)), sdBox(p, vec2(0.75, arm)));
float aaC = max(fwidth(crossD), 0.0001);float reach = R * 0.7;
if (sd > reach) {
return vec4(0.0);
}float ang = 0.8750 * TAU;
vec2 L = vec2(cos(ang), sin(ang));
vec2 nrm = p / max(d, 0.0001);
float facing = dot(nrm, L);
vec3 frost = vec3(0.933, 0.953, 1.0);
vec3 blue = vec3(0.298, 0.553, 1.0);
vec3 hot = vec3(0.706, 0.808, 1.0);
float xo = max(sd, 0.0) / (R * 0.14);
float halo = ready * 0.22 / (1.0 + xo * xo);
halo *= 1.0 - smoothstep(reach * 0.5, reach, sd);
vec3 outC = blue * halo;
float outA = clamp(halo * 0.5, 0.0, 1.0);
float t = clamp((d - rIn) / (R - rIn), 0.0, 1.0);
float bead = (randFibo(floor(shapeSample.localPosition) + 0.71) - 0.5) * mix(0.0, 0.16, 0.5500);
vec3 ringN = normalize(vec3(nrm * (t - 0.5) * 1.6, 1.0));
vec3 Ld = normalize(vec3(L * 0.7, 0.7));
float wrap = clamp((dot(ringN, Ld) + 0.35) / 1.35, 0.0, 1.0);
float ao = mix(0.72, 1.0, smoothstep(0.0, 0.35, t)) * mix(0.88, 1.0, smoothstep(1.0, 0.8, t));
vec3 ringCol = frost * (0.3 + 0.16 * wrap + 0.05 * facing) * ao * (1.0 + bead);
float gMid = (rIn + rDisc) * 0.5;
vec3 grooveCol = mix(vec3(0.008, 0.01, 0.018), blue * 0.75, ready);
grooveCol += hot * ready * exp(-abs(d - gMid) / 2.0) * 0.3;
vec2 dq = p / rDisc;
vec3 discCol = vec3(0.039, 0.055, 0.094) * (1.0 + 0.45 * dot(dq, L) * 0.5 - 0.25 * dot(dq, dq)) * (1.0 - 0.3 * press);
discCol *= mix(0.7, 1.0, smoothstep(0.0, 5.0, rDisc - d));
discCol *= 1.0 + bead * 0.6;
float crossA = clamp(0.5 - crossD / aaC, 0.0, 1.0) * 1.0000;
discCol = mix(discCol, frost, crossA * 0.8);float mOut = clamp(0.5 - sd / aa, 0.0, 1.0);
float mRingIn = clamp(0.5 + (d - rIn) / aa, 0.0, 1.0);
float mDisc = clamp(0.5 - (d - rDisc) / aa, 0.0, 1.0);
vec3 col = mix(mix(discCol, grooveCol, 1.0 - mDisc), ringCol, mRingIn);
col = clamp(col, 0.0, 1.0);vec4 res = vec4(col * mOut, mOut) + vec4(outC, outA) * (1.0 - mOut);
return res * 1.0000;
}vec4 sampleShape(vec2 canvasUV) {
vec2 canvasPosPx = vec2(canvasUV.x * uArtboardResolution.x, (1.0 - canvasUV.y) * uArtboardResolution.y);float absWidth = 160.0000;
float absHeight = 160.0000;
vec2 elementSizePx = vec2(absWidth, absHeight);
vec2 elementPosPx = vec2(0.5417, 230.0000) * uArtboardResolution - getAnchorOffsets() * elementSizePx;float dist = sdShape(canvasPosPx, elementPosPx, elementSizePx, 0.0000);
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