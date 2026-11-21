// Apply a .cube as a WebGL2 3D texture in headless Chrome (as the web demos would); write a PNG.
// usage: node lut_webgl.js in.jpg look.cube out.png
const fs = require('fs');
const { chromium } = require('/tmp/lc_qa/node_modules/playwright-core');
const [img, cubePath, out] = process.argv.slice(2);
const lines = fs.readFileSync(cubePath, 'utf8').split('\n');
let n = 0; const vals = [];
for (const l of lines) {
  if (l.startsWith('LUT_3D_SIZE')) n = +l.split(/\s+/)[1];
  else if (/^[-\d.]/.test(l)) vals.push(...l.trim().split(/\s+/).map(Number));
}
(async () => {
  const browser = await chromium.launch({
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: true, args: ['--use-angle=metal', '--ignore-gpu-blocklist'],
  });
  const page = await browser.newPage();
  const res = await page.evaluate(async ({ b64, n, vals }) => {
    const im = new Image(); im.src = 'data:image/jpeg;base64,' + b64; await im.decode();
    const cv = document.createElement('canvas'); cv.width = im.naturalWidth; cv.height = im.naturalHeight;
    const gl = cv.getContext('webgl2', { preserveDrawingBuffer: true });
    const floatLinear = !!gl.getExtension('OES_texture_float_linear');
    const src = (t, s) => { const x = gl.createShader(t); gl.shaderSource(x, s); gl.compileShader(x); return x; };
    const p = gl.createProgram();
    gl.attachShader(p, src(gl.VERTEX_SHADER, `#version 300 es
in vec2 a; out vec2 uv; void main(){ uv = a*0.5+0.5; gl_Position = vec4(a,0.,1.); }`));
    gl.attachShader(p, src(gl.FRAGMENT_SHADER, `#version 300 es
precision highp float; precision highp sampler3D;
uniform sampler2D u_image; uniform sampler3D u_lut; uniform float u_n; uniform float u_strength;
in vec2 uv; out vec4 o;
void main(){
  vec3 c = texture(u_image, uv).rgb;
  vec3 l = texture(u_lut, c * (u_n - 1.0) / u_n + 0.5 / u_n).rgb;  // texel-center remap
  o = vec4(mix(c, l, u_strength), 1.0);
}`));
    gl.bindAttribLocation(p, 0, 'a'); gl.linkProgram(p); gl.useProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) return { err: gl.getProgramInfoLog(p) };
    const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    gl.activeTexture(gl.TEXTURE0); const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, im);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    gl.activeTexture(gl.TEXTURE1); const t3 = gl.createTexture(); gl.bindTexture(gl.TEXTURE_3D, t3);
    // .cube order (red fastest) == texImage3D(width=r, height=g, depth=b)
    if (floatLinear) gl.texImage3D(gl.TEXTURE_3D, 0, gl.RGB32F, n, n, n, 0, gl.RGB, gl.FLOAT, new Float32Array(vals));
    else gl.texImage3D(gl.TEXTURE_3D, 0, gl.RGB16F, n, n, n, 0, gl.RGB, gl.FLOAT, new Float32Array(vals));
    for (const k of [gl.TEXTURE_MIN_FILTER, gl.TEXTURE_MAG_FILTER]) gl.texParameteri(gl.TEXTURE_3D, k, gl.LINEAR);
    for (const k of [gl.TEXTURE_WRAP_S, gl.TEXTURE_WRAP_T, gl.TEXTURE_WRAP_R]) gl.texParameteri(gl.TEXTURE_3D, k, gl.CLAMP_TO_EDGE);
    gl.uniform1i(gl.getUniformLocation(p, 'u_image'), 0); gl.uniform1i(gl.getUniformLocation(p, 'u_lut'), 1);
    gl.uniform1f(gl.getUniformLocation(p, 'u_n'), n); gl.uniform1f(gl.getUniformLocation(p, 'u_strength'), 1.0);
    gl.viewport(0, 0, cv.width, cv.height); gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    return { floatLinear, data: cv.toDataURL('image/png') };
  }, { b64: fs.readFileSync(img).toString('base64'), n, vals });
  await browser.close();
  if (res.err) { console.error(res.err); process.exit(1); }
  fs.writeFileSync(out, Buffer.from(res.data.split(',')[1], 'base64'));
  console.log('ok', n, 'floatLinear', res.floatLinear);
})();
