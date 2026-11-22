// Byte ranges for og.mp4. Static assets answer a Range request with the whole file (200), and
// Safari and AVFoundation, which Messages uses for og:video, expect 206 partial content for MP4.
// wrangler.jsonc runs this Worker first only for /og.mp4; every other path is served straight
// from the assets.
export default {
  async fetch(request, env) {
    const range = request.headers.get('Range');
    // a HEAD has no body to measure, so a ranged HEAD reads the asset with GET
    const res = await env.ASSETS.fetch(range ? new Request(request.url, { method: 'GET' }) : request);
    if (res.status !== 200 || !range) {
      const out = new Response(res.body, res);
      if (res.status === 200) out.headers.set('Accept-Ranges', 'bytes');
      return out;
    }
    const body = await res.arrayBuffer();
    const size = body.byteLength;
    const m = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
    let start = m && m[1] !== '' ? Number(m[1]) : NaN;
    let end = m && m[2] !== '' ? Number(m[2]) : NaN;
    if (m && m[1] === '' && m[2] !== '') {
      start = Math.max(0, size - end); // bytes=-n: the last n bytes
      end = size - 1;
    } else if (!Number.isNaN(start)) {
      end = Number.isNaN(end) ? size - 1 : Math.min(end, size - 1);
    }
    if (!m || Number.isNaN(start) || start > end || start >= size) {
      return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } });
    }
    const headers = new Headers(res.headers);
    headers.set('Accept-Ranges', 'bytes');
    headers.set('Content-Range', `bytes ${start}-${end}/${size}`);
    headers.set('Content-Length', String(end - start + 1));
    const part = request.method === 'HEAD' ? null : body.slice(start, end + 1);
    return new Response(part, { status: 206, headers });
  },
};
