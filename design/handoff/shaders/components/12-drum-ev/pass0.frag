// Unicorn Studio shape treatment (shadeShape) source for layer f79c5d21-b281-4868-8e91-41a30c0a1f45
// Not standalone: the engine prepends ShapeSample, sdBox/sdRoundedBox/rotate2D, TAU/PI, uFillAlpha, uBorderRadius
// and calls shadeShape() per fragment. See pass0.compiled.frag for the full runnable GLSL ES 3.0 (control values baked in).

uniform sampler2D uFontAtlas;
uniform sampler2D uFontMetrics;
uniform sampler2D uTextCodes;
uniform float uAiValue;
uniform float uAiBlur;
uniform float uAiSize;
uniform float uAiSpacing;
uniform float uAiFade;
uniform float uAiTextY;
uniform float uAiPrefix;
uniform float uTime;
uniform float uAiDemo;

float metricValue(int code, int row) {
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
float atlasPxRange() { return atlasHeader(1); }
float atlasEmPerUnit() { return atlasHeader(1) / atlasHeader(0); }
bool atlasTrueSdf() { return mod(atlasHeader(2), 2.0) > 0.5; }

int textCode(int i) {
  if (i < 0 || i >= 256) return 0;
  return int(texelFetch(uTextCodes, ivec2(i, 0), 0).r * 255.0 + 0.5);
}

float median3(float r, float g, float b) {
  return max(min(r, g), min(max(r, g), b));
}

// MSDF coverage of one glyph at a local uv, with the screen-pixel range known up front
float glyphCoverage(vec2 localUv, vec4 atlasUv, float spr, bool tsdf) {
  if (localUv.x < 0.0 || localUv.x > 1.0 || localUv.y < 0.0 || localUv.y > 1.0) return 0.0;
  vec2 uv = vec2(mix(atlasUv.x, atlasUv.z, localUv.x), mix(atlasUv.y, atlasUv.w, 1.0 - localUv.y));
  vec4 msdf = textureLod(uFontAtlas, uv, 0.0);
  float sd = median3(msdf.r, msdf.g, msdf.b) - 0.5;
  if (tsdf) sd = mix(sd, msdf.a - 0.5, clamp(abs(msdf.a - 0.5) * 8.0, 0.0, 1.0));
  return clamp(spr * sd + 0.5, 0.0, 1.0);
}

// coverage averaged along a short horizontal streak, for motion blur while the wheel turns
float streakCoverage(vec2 q, vec2 minP, vec2 ext, vec4 auv, float spr, float B, bool tsdf) {
  if (B < 0.05) return glyphCoverage((q - minP) / ext, auv, spr, tsdf);
  float s = 0.0;
  s += glyphCoverage((q + vec2(-B, 0.0) - minP) / ext, auv, spr, tsdf) * 0.5;
  s += glyphCoverage((q + vec2(-0.5 * B, 0.0) - minP) / ext, auv, spr, tsdf);
  s += glyphCoverage((q - minP) / ext, auv, spr, tsdf);
  s += glyphCoverage((q + vec2(0.5 * B, 0.0) - minP) / ext, auv, spr, tsdf);
  s += glyphCoverage((q + vec2(B, 0.0) - minP) / ext, auv, spr, tsdf) * 0.5;
  return s / 4.0;
}

// ease out with a slight overshoot past the detent
float backEase(float x) {
  float c1 = 1.2;
  float c3 = c1 + 1.0;
  float y = x - 1.0;
  return 1.0 + c3 * y * y * y + c1 * y * y;
}

// demo, in seconds: two detents down 240 ms each, hold, two detents back up, hold (3.6 s loop)
float demoOffset(float t) {
  float tc = mod(t, 3.6);
  float v = 0.0;
  v -= backEase(clamp((tc - 0.60) / 0.24, 0.0, 1.0));
  v -= backEase(clamp((tc - 0.84) / 0.24, 0.0, 1.0));
  v += backEase(clamp((tc - 2.10) / 0.24, 0.0, 1.0));
  v += backEase(clamp((tc - 2.34) / 0.24, 0.0, 1.0));
  return v;
}

vec4 shadeShape(ShapeSample shapeSample) {
  vec2 size = shapeSample.elementSize;
  vec2 lp = shapeSample.localPosition;
  float fpx = max(fwidth(lp.x), 0.0001);
  float cover = shapeSample.coverage * uFillAlpha;
  if (cover <= 0.0) {
    return vec4(0.0);
  }

  // soft fade at both side edges; it only bites on values scrolling past the neighbours
  float fadeW = max(uAiFade, 0.5);
  float pxEdge = smoothstep(0.0, fadeW, lp.x) * smoothstep(0.0, fadeW, size.x - lp.x);

  float em = uAiSize;
  float gap = max(uAiSpacing, 1.0);
  float track = -0.02;
  float ps = uAiPrefix;
  // at Speed 0.5 the engine clock runs 30 units per second
  float demoT = uTime / 30.0;
  float demoOff = demoOffset(demoT) * uAiDemo;
  float demoSpeed = abs(demoOff - demoOffset(demoT - 0.0167) * uAiDemo) * 60.0;
  float value = uAiValue + demoOff;
  float cx = size.x * 0.5;
  float cy = size.y * uAiTextY;
  float B = max(uAiBlur, clamp(demoSpeed / 17.5, 0.0, 1.0)) * 2.8;

  // only the values within two detents of this fragment can reach it
  float rel = (lp.x - cx) / gap + value;
  int kLo = int(floor(rel)) - 1;

  // pass 1: per nearby value, its advance, the advance up to its slash, and how many chars precede it
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

  // one optical centre line for every value, taken from the zero digit
  vec4 pl0 = glyphPlane(48);
  float figC = 0.5 * (pl0.y + pl0.w);
  float epu = atlasEmPerUnit();
  bool tsdf = atlasTrueSdf();

  // pass 2: draw the nearby values on the cylinder
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
        // scale 1 at the centre easing to .5 one detent out; opacity 1 -> .35 -> hidden at two detents
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
  }

  float a = clamp(acc * cover, 0.0, 1.0);
  vec3 col = clamp(shapeSample.fillColor, 0.0, 1.0);
  return vec4(col * a, a);
}
