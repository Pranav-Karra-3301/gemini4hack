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
vec2 p = localPos - halfSize;return vec3(0.023529411764705882, 0.03137254901960784, 0.058823529411764705);
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
}vec4 shadeShape(ShapeSample shapeSample) {
vec2 size = shapeSample.elementSize;
vec2 p = shapeSample.localPosition - size * 0.5;
float press = clamp(0.0000, 0.0, 1.0);
float ready = clamp(0.6000, 0.0, 1.0);
float R = min(size.x, size.y) * 0.5 * 1.0000 * (1.0 - 0.06 * press);
float d = length(p);
float sd = d - R;
float aa = max(fwidth(sd), 0.0001);
float ang = 0.8750 * TAU;
vec2 L = vec2(cos(ang), sin(ang));
float arm = R * 0.2115;
float crossD = min(sdBox(p, vec2(arm, 0.75)), sdBox(p, vec2(0.75, arm)));
vec2 psS = p - L * 0.7;
float crossS = min(sdBox(psS, vec2(arm, 0.75)), sdBox(psS, vec2(0.75, arm)));
vec2 psH = p + L * 0.7;
float crossH = min(sdBox(psH, vec2(arm, 0.75)), sdBox(psH, vec2(0.75, arm)));
float aaC = max(fwidth(crossD), 0.0001);float reach = R * 1.2;
if (sd > reach) {
return vec4(0.0);
}vec3 blue = vec3(0.298, 0.553, 1.0);
vec3 iris = vec3(0.604, 0.486, 0.965);
vec3 frost = vec3(0.933, 0.953, 1.0);
float time = uTime * 0.0262 * mix(0.2, 1.6, 0.5000);
vec2 nrm = p / max(d, 0.0001);
float a = atan(nrm.y, nrm.x);
float lowSide = 0.5 + 0.5 * dot(nrm, -L);
float drift = 0.82 + 0.18 * sin(a * 3.0 + time * 1.3) * sin(a * 2.0 - time * 0.7 + 1.0);
float corona = mix(0.3, 1.1, 0.6500) * (0.35 + 0.65 * ready) * (0.4 + 0.6 * lowSide) * drift * (1.0 + 0.5 * press);
vec3 coronaCol = mix(blue, iris, 0.25 + 0.45 * (1.0 - lowSide));
float xo = max(sd, 0.0) / (R * 0.2);
float outer = corona / (1.0 + xo * xo);
outer *= 1.0 - smoothstep(reach * 0.5, reach, sd);
vec3 outC = coronaCol * outer * 0.8;
float outA = clamp(outer * 0.6, 0.0, 1.0);
vec2 q = p / R;
float r2 = min(dot(q, q), 1.0);
float z = sqrt(1.0 - r2);
vec3 N = vec3(q, z);
vec3 Ld = normalize(vec3(L * 0.7, 0.7));
float wrap = clamp((dot(N, Ld) + 0.4) / 1.4, 0.0, 1.0);
vec3 col = vec3(0.028, 0.034, 0.052) + vec3(0.085, 0.095, 0.125) * wrap * wrap * 0.9;
float e = R - d;
col += coronaCol * corona * exp(-max(e, 0.0) / (R * 0.09)) * 0.4;
float crossA = clamp(0.5 - crossD / aaC, 0.0, 1.0) * 1.0000;
float crossSh = clamp(0.5 - crossS / aaC, 0.0, 1.0) * 1.0000 * (1.0 - crossA);
float crossHi = clamp(0.5 - crossH / aaC, 0.0, 1.0) * 1.0000 * (1.0 - crossA);
col *= 1.0 - 0.4 * crossSh;
col += frost * 0.035 * crossHi;
col = mix(col, frost * 0.75, crossA * 0.42);
col += (randFibo(floor(shapeSample.localPosition) + 0.37) - 0.5) * 0.04;col = clamp(col + deband(), 0.0, 1.0);
float discA = clamp(0.5 - sd / aa, 0.0, 1.0);
vec4 res = vec4(col * discA, discA) + vec4(outC, outA) * (1.0 - discA);
return res * 1.0000;
}vec4 sampleShape(vec2 canvasUV) {
vec2 canvasPosPx = vec2(canvasUV.x * uArtboardResolution.x, (1.0 - canvasUV.y) * uArtboardResolution.y);float absWidth = 160.0000;
float absHeight = 160.0000;
vec2 elementSizePx = vec2(absWidth, absHeight);
vec2 elementPosPx = vec2(0.3417, 230.0000) * uArtboardResolution - getAnchorOffsets() * elementSizePx;float dist = sdShape(canvasPosPx, elementPosPx, elementSizePx, 0.0000);
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