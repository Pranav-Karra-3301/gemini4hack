// Compile + render GLSL ES 3.0 fragment shaders in headless Chrome (WebGL2).
// usage: node shader_harness.js jobs.json results.json
// jobs: [{id, image, glsl, out}]  (image: JPEG path; out: JPEG path)
// results: [{id, ok, stage, log, ms, stats}]
const fs = require('fs');
const { chromium } = require('/tmp/lc_qa/node_modules/playwright-core');

const VS = `#version 300 es
in vec2 a_pos; out vec2 v_uv;
void main(){ v_uv = a_pos * 0.5 + 0.5; gl_Position = vec4(a_pos, 0.0, 1.0); }`;

async function run(page, job) {
  const img = fs.readFileSync(job.image).toString('base64');
  return page.evaluate(async ({ img, fsrc, vsrc }) => {
    const im = new Image();
    im.src = 'data:image/jpeg;base64,' + img;
    await im.decode();
    const cv = document.createElement('canvas');
    cv.width = im.naturalWidth; cv.height = im.naturalHeight;
    const gl = cv.getContext('webgl2', { preserveDrawingBuffer: true });
    if (!gl) return { ok: false, stage: 'context', log: 'no webgl2' };
    const sh = (type, src) => {
      const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
      return [s, gl.getShaderParameter(s, gl.COMPILE_STATUS), gl.getShaderInfoLog(s)];
    };
    const [vs] = sh(gl.VERTEX_SHADER, vsrc);
    const [f, okc, flog] = sh(gl.FRAGMENT_SHADER, fsrc);
    if (!okc) return { ok: false, stage: 'compile', log: flog };
    const p = gl.createProgram(); gl.attachShader(p, vs); gl.attachShader(p, f);
    gl.bindAttribLocation(p, 0, 'a_pos'); gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) return { ok: false, stage: 'link', log: gl.getProgramInfoLog(p) };
    gl.useProgram(p);
    const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    const t = gl.createTexture(); gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, t);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, im);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    const u = (n) => gl.getUniformLocation(p, n);
    gl.uniform1i(u('u_image'), 0); gl.uniform2f(u('u_res'), cv.width, cv.height);
    gl.uniform1f(u('u_time'), 0.0); gl.uniform1f(u('u_strength'), 1.0);
    gl.viewport(0, 0, cv.width, cv.height);
    const t0 = performance.now();
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    const px = new Uint8Array(4 * 64 * 64);
    gl.readPixels(0, 0, 64, 64, gl.RGBA, gl.UNSIGNED_BYTE, px);   // forces completion
    const ms = performance.now() - t0;
    const err = gl.getError();
    if (err) return { ok: false, stage: 'draw', log: 'gl error ' + err };
    return { ok: true, stage: 'render', ms, data: cv.toDataURL('image/jpeg', 0.92) };
  }, { img, fsrc: job.glsl, vsrc: VS });
}

(async () => {
  const jobs = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const browser = await chromium.launch({
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: true, args: ['--use-angle=metal', '--ignore-gpu-blocklist'],
  });
  const page = await browser.newPage();
  await page.setContent('<html><body></body></html>');
  const results = [];
  for (const job of jobs) {
    let r;
    try { r = await run(page, job); } catch (e) { r = { ok: false, stage: 'exception', log: String(e) }; }
    if (r.ok) { fs.writeFileSync(job.out, Buffer.from(r.data.split(',')[1], 'base64')); delete r.data; }
    results.push({ id: job.id, ...r });
  }
  await browser.close();
  fs.writeFileSync(process.argv[3], JSON.stringify(results, null, 1));
})();
