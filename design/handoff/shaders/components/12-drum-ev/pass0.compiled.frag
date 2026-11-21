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
vec2 p = localPos - halfSize;return vec3(0.9333333333333333, 0.9529411764705882, 1);
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
};vec4 shadeShape(ShapeSample shapeSample);uniform sampler2D uFontAtlas;
uniform sampler2D uFontMetrics;
uniform sampler2D uTextCodes;
uniform float uTime;float metricValue(int code, int row) {
if (code < 32 || code > 126) return 0.0;
vec4 t = texelFetch(uFontMetrics, ivec2(code - 32, row), 0);
return (t.r * 65280.0 + t.g * 255.0) / 65535.0;
}
float glyphAdvance(int code) {
vec4 t = (code < 32 || code > 126) ? vec4(0.0) : texelFetch(uFontMetrics, ivec2(code - 32, 0), 0);
if (t.b < 0.5) return 0.5;
return (t.r * 65280.0 + t.g * 255.0) / 65535.0 * 4.0 - 2.0;
}
bool glyphDrawable(int code) {
if (code < 32 || code > 126) return false;
return texelFetch(uFontMetrics, ivec2(code - 32, 5), 0).b > 0.5;
}
vec4 glyphPlane(int code) {
return vec4(metricValue(code, 1), metricValue(code, 2), metricValue(code, 3), metricValue(code, 4)) * 4.0 - 2.0;
}
vec4 glyphAtlasUv(int code) {
return vec4(metricValue(code, 5), metricValue(code, 6), metricValue(code, 7), metricValue(code, 8));
}
float atlasHeader(int column) {
vec4 t = texelFetch(uFontMetrics, ivec2(column, 9), 0);
return floor(t.r * 255.0 + 0.5) * 256.0 + floor(t.g * 255.0 + 0.5);
}
float atlasEmPerUnit() { return atlasHeader(1) / atlasHeader(0); }
bool atlasTrueSdf() { return mod(atlasHeader(2), 2.0) > 0.5; }int textCode(int i) {
if (i < 0 || i >= 256) return 0;
return int(texelFetch(uTextCodes, ivec2(i, 0), 0).r * 255.0 + 0.5);
}float median3(float r, float g, float b) {
return max(min(r, g), min(max(r, g), b));
}float glyphCoverage(vec2 localUv, vec4 atlasUv, float spr, bool tsdf) {
if (localUv.x < 0.0 || localUv.x > 1.0 || localUv.y < 0.0 || localUv.y > 1.0) return 0.0;
vec2 uv = vec2(mix(atlasUv.x, atlasUv.z, localUv.x), mix(atlasUv.y, atlasUv.w, 1.0 - localUv.y));
vec4 msdf = textureLod(uFontAtlas, uv, 0.0);
float sd = median3(msdf.r, msdf.g, msdf.b) - 0.5;
if (tsdf) sd = mix(sd, msdf.a - 0.5, clamp(abs(msdf.a - 0.5) * 8.0, 0.0, 1.0));
return clamp(spr * sd + 0.5, 0.0, 1.0);
}float streakCoverage(vec2 q, vec2 minP, vec2 ext, vec4 auv, float spr, float B, bool tsdf) {
if (B < 0.05) return glyphCoverage((q - minP) / ext, auv, spr, tsdf);
float s = 0.0;
s += glyphCoverage((q + vec2(-B, 0.0) - minP) / ext, auv, spr, tsdf) * 0.5;
s += glyphCoverage((q + vec2(-0.5 * B, 0.0) - minP) / ext, auv, spr, tsdf);
s += glyphCoverage((q - minP) / ext, auv, spr, tsdf);
s += glyphCoverage((q + vec2(0.5 * B, 0.0) - minP) / ext, auv, spr, tsdf);
s += glyphCoverage((q + vec2(B, 0.0) - minP) / ext, auv, spr, tsdf) * 0.5;
return s / 4.0;
}float backEase(float x) {
float c1 = 1.2;
float c3 = c1 + 1.0;
float y = x - 1.0;
return 1.0 + c3 * y * y * y + c1 * y * y;
}float demoOffset(float t) {
float tc = mod(t, 3.6);
float v = 0.0;
v -= backEase(clamp((tc - 0.60) / 0.24, 0.0, 1.0));
v -= backEase(clamp((tc - 0.84) / 0.24, 0.0, 1.0));
v += backEase(clamp((tc - 2.10) / 0.24, 0.0, 1.0));
v += backEase(clamp((tc - 2.34) / 0.24, 0.0, 1.0));
return v;
}vec4 shadeShape(ShapeSample shapeSample) {
vec2 size = shapeSample.elementSize;
vec2 lp = shapeSample.localPosition;
float fpx = max(fwidth(lp.x), 0.0001);
float cover = shapeSample.coverage * 1.0000;
if (cover <= 0.0) {
return vec4(0.0);
}
float fadeW = max(18.0000, 0.5);
float pxEdge = smoothstep(0.0, fadeW, lp.x) * smoothstep(0.0, fadeW, size.x - lp.x);float em = 30.0000;
float gap = max(46.0000, 1.0);
float track = -0.02;
float ps = 0.6000;
float demoT = uTime / 30.0;
float demoOff = demoOffset(demoT) * 0.0000;
float demoSpeed = abs(demoOff - demoOffset(demoT - 0.0167) * 0.0000) * 60.0;
float value = 2.0000 + demoOff;
float cx = size.x * 0.5;
float cy = size.y * 0.6000;
float B = max(0.0000, clamp(demoSpeed / 17.5, 0.0, 1.0)) * 2.8;
float rel = (lp.x - cx) / gap + value;
int kLo = int(floor(rel)) - 1;
float wAll[4] = float[4](0.0, 0.0, 0.0, 0.0);
float wPre[4] = float[4](0.0, 0.0, 0.0, 0.0);
int nPre[4] = int[4](0, 0, 0, 0);
int k = 0;
int ci = 0;
bool inWord = false;
for (int i = 0; i < 40; i++) {
int c = textCode(i);
if (c == 0) break;
if (c == 32) {
if (inWord) { k++; inWord = false; ci = 0; }
continue;
}
inWord = true;
int j = k - kLo;
if (j >= 0 && j < 4) {
wAll[j] += glyphAdvance(c) + track;
if (c == 47) { wPre[j] = wAll[j]; nPre[j] = ci + 1; }
}
ci++;
}
vec4 pl0 = glyphPlane(48);
float figC = 0.5 * (pl0.y + pl0.w);
float epu = atlasEmPerUnit();
bool tsdf = atlasTrueSdf();
float acc = 0.0;
k = 0;
ci = 0;
inWord = false;
float pen = 0.0;
for (int i = 0; i < 40; i++) {
int c = textCode(i);
if (c == 0) break;
if (c == 32) {
if (inWord) { k++; inWord = false; pen = 0.0; ci = 0; }
continue;
}
inWord = true;
float adv = glyphAdvance(c);
int j = k - kLo;
float cs = 1.0;
if (j >= 0 && j < 4) {
cs = ci < nPre[j] ? ps : 1.0;
if (glyphDrawable(c)) {
float d = float(k) - value;
float ad = abs(d);
float s = 1.0 - 0.5 * smoothstep(0.0, 1.0, ad);
float o = ad < 1.0 ? 1.0 - 0.65 * smoothstep(0.0, 1.0, ad) : 0.35 * (1.0 - smoothstep(1.0, 2.0, ad));
float es = em * s;
float wv = wPre[j] * ps + (wAll[j] - wPre[j]) - track;
float penX = cx + d * gap - 0.5 * wv * es + pen * es;
float ges = es * cs;
if (o > 0.001 && lp.x > penX - ges - B && lp.x < penX + (adv + 1.0) * ges + B) {
vec4 plane = glyphPlane(c);
float baseY = cy - figC * es;
vec2 minP = vec2(penX, baseY) + vec2(plane.x, plane.y) * ges;
vec2 maxP = vec2(penX, baseY) + vec2(plane.z, plane.w) * ges;
vec2 ext = max(maxP - minP, vec2(0.000001));
float spr = max(epu * ges / fpx, 1.0);
float cov = streakCoverage(lp, minP, ext, glyphAtlasUv(c), spr, B, tsdf);
float edge = mix(1.0, pxEdge, smoothstep(1.0, 1.25, ad));
acc = max(acc, cov * o * edge);
}
}
}
pen += (adv + track) * cs;
ci++;
}float a = clamp(acc * cover, 0.0, 1.0);
vec3 col = clamp(shapeSample.fillColor, 0.0, 1.0);
return vec4(col * a, a);
}vec4 sampleShape(vec2 canvasUV) {
vec2 canvasPosPx = vec2(canvasUV.x * uArtboardResolution.x, (1.0 - canvasUV.y) * uArtboardResolution.y);float absWidth = 131.0000;
float absHeight = 84.0000;
vec2 elementSizePx = vec2(absWidth, absHeight);
vec2 elementPosPx = vec2(919.5000, 762.0000) * uArtboardResolution - getAnchorOffsets() * elementSizePx;float dist = sdShape(canvasPosPx, elementPosPx, elementSizePx, 0.0000);
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