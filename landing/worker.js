// Byte ranges for og.mp4. Static assets answer a Range request with the whole file (200), and
// Safari and AVFoundation, which Messages uses for og:video, expect 206 partial content for MP4.
// wrangler.jsonc runs this Worker first for /og.mp4. With SPA not-found handling, a request that
// matches no asset and isn't a page navigation also lands here; it goes straight to the assets.
const RANGED = '/og.mp4';

export default {
  async fetch(request, env) {
    if (new URL(request.url).pathname !== RANGED) return env.ASSETS.fetch(request);
    const range = request.headers.get('Range');
    // a HEAD has no body to measure, so a ranged HEAD reads the asset with GET
    const res = await env.ASSETS.fetch(range ? new Request(request.url, { method: 'GET' }) : request);
    const headers = new Headers(res.headers);
    if (res.status === 200) headers.set('Accept-Ranges', 'bytes');
    if (res.status !== 200 || !range) return new Response(res.body, { status: res.status, headers });

    const body = await res.arrayBuffer();
    const size = body.byteLength;
    const r = parseRange(range, size);
    if (r === 'unsatisfiable') {
      return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } });
    }
    if (!r) return new Response(request.method === 'HEAD' ? null : body, { status: 200, headers });
    const [start, end] = r;
    headers.set('Content-Range', `bytes ${start}-${end}/${size}`);
    headers.set('Content-Length', String(end - start + 1));
    return new Response(request.method === 'HEAD' ? null : body.slice(start, end + 1), { status: 206, headers });
  },
};

/**
 * One `bytes=` range as [start, end] (inclusive), 'unsatisfiable', or null when the header should
 * be ignored and the whole file sent (malformed, several ranges, end before start: RFC 9110 14.2).
 */
function parseRange(header, size) {
  const m = /^bytes=(\d*)-(\d*)$/i.exec(header.trim());
  if (!m || (m[1] === '' && m[2] === '')) return null;
  if (m[1] === '') {
    const n = Number(m[2]); // bytes=-n: the last n bytes
    return n === 0 ? 'unsatisfiable' : [Math.max(0, size - n), size - 1];
  }
  const start = Number(m[1]);
  if (m[2] !== '' && Number(m[2]) < start) return null;
  if (start >= size) return 'unsatisfiable';
  return [start, m[2] === '' ? size - 1 : Math.min(Number(m[2]), size - 1)];
}
