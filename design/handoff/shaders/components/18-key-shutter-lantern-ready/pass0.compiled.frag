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
vec2 p = localPos - halfSize;return vec3(0.027450980392156862, 0.043137254901960784, 0.08627450980392157);
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
}vec2 lightField(vec3 p, float t, float agitate) {
vec3 q = p * 1.35;
q.xy = rotate2D(q.xy, t);
q.xz = rotate2D(q.xz, t * 0.3 + 0.8);
q += (0.30 + 0.14 * agitate) * sin(q.zxy * 2.1 + vec3(0.0, 1.7, 3.1) + t * 0.35);
q += 0.16 * sin(q.yzx * 3.7 + vec3(2.3, 0.4, 1.1) - t * 0.5);
float s = sin(q.x * 2.7 + q.y * 1.2) + sin(q.y * 2.3 - q.z * 1.8 + 1.4) + sin(q.z * 2.5 + q.x * 1.6 + 2.6);
float hue = 0.5 + 0.5 * sin(q.x * 1.3 - q.z * 1.1 + q.y * 0.8 + 0.7);
return vec2(s, hue);
}vec4 shadeShape(ShapeSample shapeSample) {
vec2 size = shapeSample.elementSize;
float press = clamp(0.0000, 0.0, 1.0);
float ready = clamp(1.0000, 0.0, 1.0);
vec2 p = (shapeSample.localPosition - size * 0.5) / (1.0 - 0.04 * press);
vec2 hs = size * 0.5;
float rad = min(hs.x, hs.y);
float sdc = sdRoundedBox(p, hs, rad);
float aa = max(fwidth(sdc), 0.0001);float ang = 0.8750 * TAU;
vec2 L = vec2(cos(ang), sin(ang));
float arm = rad * 0.27;
float crossD = min(sdBox(p, vec2(arm, 0.75)), sdBox(p, vec2(0.75, arm)));
vec2 psS = p - L * 0.7;
float crossS = min(sdBox(psS, vec2(arm, 0.75)), sdBox(psS, vec2(0.75, arm)));
vec2 psH = p + L * 0.7;
float crossH = min(sdBox(psH, vec2(arm, 0.75)), sdBox(psH, vec2(0.75, arm)));
float aaC = max(fwidth(crossD), 0.0001);float reach = rad * 0.65;
if (sdc > reach) {
return vec4(0.0);
}vec3 blue = vec3(0.298, 0.553, 1.0);
vec3 iris = vec3(0.604, 0.486, 0.965);
vec3 frost = vec3(0.933, 0.953, 1.0);
float time = uTime * 0.0262;
float voice = clamp(0.0000, 0.0, 1.0) * (0.7 + 0.3 * sin(uTime * 0.21));
float glowGain = (0.55 + 0.75 * ready) * (1.0 + 0.9 * voice) * (1.0 + 0.6 * press) * 2.4;
float segX = max(hs.x - rad, 0.0);
vec2 c = vec2(clamp(p.x, -segX, segX), 0.0);
vec2 v = (p - c) / rad;
float z = sqrt(1.0 - min(dot(v, v), 1.0));
vec3 N = vec3(v, z);
vec3 Ld = normalize(vec3(L * 0.7, 0.7));
float wrap = clamp((dot(N, Ld) + 0.5) / 1.5, 0.0, 1.0);
float lambert = max(dot(N, Ld), 0.0);
vec2 nrm = (p - c) / max(length(p - c), 0.0001);
float lowSide = 0.5 + 0.5 * dot(nrm, -L);
float xo = max(sdc, 0.0) / (rad * 0.28);
float halo = (0.05 + 0.3 * ready) * (1.0 + 0.6 * voice) / (1.0 + xo * xo);
halo *= 1.0 - smoothstep(reach * 0.45, reach, sdc);
vec3 outC = mix(blue, iris, 0.35 * lowSide) * halo * (0.7 + 0.5 * lowSide);
float outA = clamp(halo * 0.6, 0.0, 1.0);
float span = rad + segX * 0.7;
vec3 Q = vec3(p.x / span, p.y / rad, z);
vec2 srcPx = vec2(-L.x * 0.42 * hs.x, (-L.y * 0.42 + 0.1) * rad * 0.62);
vec3 src = vec3(srcPx.x / span, srcPx.y / rad, 0.55);
vec3 toS = Q * 0.92 - src;
float scatter = 0.88 / (1.0 + dot(toS, toS) * 4.6);
vec2 f = lightField(Q * 0.55, time * mix(0.25, 1.75, 0.5000) * 0.6, ready);
float density = 0.86 + 0.14 * exp(-abs(f.x) * 0.8);
vec3 glowCol = mix(blue, iris, 0.55 * smoothstep(0.55, 1.35, length(toS)));
vec3 inner = glowCol * scatter * density * glowGain;
inner += frost * scatter * scatter * 0.32 * glowGain;
vec3 col = vec3(0.04, 0.05, 0.085) * (0.6 + 0.4 * z) * (0.8 + 0.26 * wrap);
col += vec3(0.11, 0.14, 0.21) * lambert * 0.32;
col += inner * (0.5 + 0.5 * z);
col *= mix(0.86, 1.0, smoothstep(-0.2, 0.9, -v.y * 0.5 + z));
float crossA = clamp(0.5 - crossD / aaC, 0.0, 1.0) * 1.0000;
float crossSh = clamp(0.5 - crossS / aaC, 0.0, 1.0) * 1.0000 * (1.0 - crossA);
float crossHi = clamp(0.5 - crossH / aaC, 0.0, 1.0) * 1.0000 * (1.0 - crossA);
col *= 1.0 - 0.35 * crossSh;
col += frost * 0.04 * crossHi;
col = mix(col, frost * 0.8, crossA * 0.5);
col += (randFibo(floor(shapeSample.localPosition) + 0.37) - 0.5) * mix(0.0, 0.06, 0.7500);col = clamp(col + deband(), 0.0, 1.0);
float bodyA = clamp(0.5 - sdc / aa, 0.0, 1.0);
vec4 res = vec4(col * bodyA, bodyA) + vec4(outC, outA) * (1.0 - bodyA);
return res * 1.0000;
}vec4 sampleShape(vec2 canvasUV) {
vec2 canvasPosPx = vec2(canvasUV.x * uArtboardResolution.x, (1.0 - canvasUV.y) * uArtboardResolution.y);float absWidth = 229.0000;
float absHeight = 72.0000;
vec2 elementSizePx = vec2(absWidth, absHeight);
vec2 elementPosPx = vec2(322.5000, 962.0000) * uArtboardResolution - getAnchorOffsets() * elementSizePx;float dist = sdShape(canvasPosPx, elementPosPx, elementSizePx, 0.0000);
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