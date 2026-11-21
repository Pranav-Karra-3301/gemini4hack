// DOM for the side panel, filmstrip and hint. No innerHTML with model text: everything via h().

export function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'style') el.style.cssText = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v);
  }
  for (const kid of kids.flat(Infinity)) if (kid != null && kid !== false) el.append(kid);
  return el;
}

const $ = (sel) => document.querySelector(sel);
const scoresBody = $('#scores .body');
const regionsBody = $('#regions .body');
const clamp01 = (x) => Math.max(0, Math.min(1, x));
const fmtMs = (ms) => (Number.isFinite(ms) ? (ms >= 1000 ? `${(ms / 1000).toFixed(1)} s` : `${Math.round(ms)} ms`) : '');

const loading = (text, rows, cls) => [
  ...Array.from({ length: rows }, () => h('div', { class: `skel ${cls}` })),
  h('p', { class: 'loading' }, text),
];
const errorBox = (msg) => h('p', { class: 'error' }, h('strong', {}, 'Error '), msg);

// ---------------- scores ----------------

export const scoresLoading = () => scoresBody.replaceChildren(...loading('reading the light…', 2, 'skel-metric'));
export const scoresError = (msg) => scoresBody.replaceChildren(errorBox(msg));

function metric(name, m) {
  if (!m || !Number.isFinite(Number(m.score))) {
    return h('div', { class: 'metric' }, h('div', { class: 'metric-head' },
      h('span', { class: 'metric-name' }, name), h('span', { class: 'metric-score' }, '—')));
  }
  const [lo, hi] = Array.isArray(m.scale) && m.scale.length === 2 ? m.scale.map(Number) : [1, 5];
  const score = Number(m.score);
  const dist = [];
  for (let k = lo; k <= hi; k++) dist.push(Math.max(0, Number(m.distribution?.[k] ?? 0) || 0));
  const top = Math.max(...dist, 1e-6);
  const peak = lo + dist.indexOf(Math.max(...dist));
  const fill = h('i', { 'data-w': (clamp01((score - lo) / (hi - lo)) * 100).toFixed(1) });
  const conf = Number(m.confidence);
  return h('div', { class: 'metric' },
    h('div', { class: 'metric-head' },
      h('span', { class: 'metric-name' }, name),
      h('span', { class: 'metric-score' }, score.toFixed(1), h('small', {}, ` / ${hi}`))),
    h('div', { class: 'bar' }, fill),
    h('div', { class: 'metric-meta' },
      h('div', { class: 'hist', title: 'score distribution' },
        dist.map((p, i) => h('span', { class: lo + i === peak ? 'on' : null, title: `${lo + i}: ${Math.round(p * 100)}%` },
          h('i', { style: `--p:${(p / top).toFixed(3)}` }), h('b', {}, lo + i)))),
      h('span', { class: 'conf' },
        h('strong', {}, Number.isFinite(conf) ? `${Math.round(conf * 100)}%` : '—'), ' confidence')),
    m.label ? h('p', { class: 'metric-label' }, m.label) : null);
}

export function scoresRender(data) {
  const s = data?.scores || {};
  scoresBody.replaceChildren(
    metric('Lighting', s.lighting),
    metric('Composition', s.composition),
    h('p', { class: 'meta' }, [data?.provider, fmtMs(data?.ms)].filter(Boolean).join(' · ')));
  // Let the bars grow in from zero.
  requestAnimationFrame(() => requestAnimationFrame(() =>
    scoresBody.querySelectorAll('.bar i').forEach((el) => { el.style.width = `${el.dataset.w}%`; })));
}

// ---------------- regions ----------------

export const regionsLoading = () => regionsBody.replaceChildren(...loading('finding what to fix…', 3, 'skel-card'));
export const regionsError = (msg) => regionsBody.replaceChildren(errorBox(msg));

export function regionsRender(regions, meta, { onHover, onToggle }) {
  if (!regions.length) { regionsBody.replaceChildren(h('p', { class: 'loading' }, 'No regions returned.')); return; }
  regionsBody.replaceChildren(
    ...regions.map((r, i) => h('button', {
      type: 'button', class: `region tag-${r.tag}`, 'data-id': r.id,
      onmouseenter: () => onHover(r), onmouseleave: () => onHover(null),
      onfocus: () => onHover(r), onblur: () => onHover(null),
      onclick: () => onToggle(r),
    },
      h('div', { class: 'region-head' },
        h('span', { class: 'chip' }, r.tag.toUpperCase()),
        h('span', { class: 'region-aside' },
          h('span', { class: 'trace' }, 'tracing…'),
          h('span', { class: 'region-idx' }, String(i + 1).padStart(2, '0')))),
      h('p', { class: 'region-note' }, r.note))),
    h('p', { class: 'meta' }, [meta?.model, fmtMs(meta?.ms)].filter(Boolean).join(' · ')),
    h('p', { class: 'meta mask-meta' }));
}

// Masks arrive after the regions: cards show "tracing…" until then; a failure keeps the boxes.
const cards = () => regionsBody.querySelectorAll('.region');
export function masksLoading() {
  regionsBody.querySelector('.mask-error')?.remove();
  cards().forEach((el) => el.classList.add('tracing'));
}
export function masksReady(hasMask, meta) {
  cards().forEach((el) => {
    el.classList.remove('tracing');
    const ok = hasMask(el.dataset.id);
    el.classList.toggle('no-mask', !ok);
    el.title = ok ? '' : 'no object mask · showing its box';
  });
  const m = regionsBody.querySelector('.mask-meta');
  if (m) m.textContent = ['masks', meta?.model, fmtMs(meta?.ms)].filter(Boolean).join(' · ');
}
export function masksError(msg) {
  cards().forEach((el) => el.classList.remove('tracing'));
  const err = h('p', { class: 'error mask-error' }, h('strong', {}, 'Error '), `masks: ${msg} · notes use boxes`);
  regionsBody.querySelector('.mask-meta')?.before(err);
}

export function markRegion(id) {
  regionsBody.querySelectorAll('.region').forEach((el) => el.classList.toggle('active', el.dataset.id === id));
}

// ---------------- misc ----------------

export function depthStatus(s) {
  const el = $('#depth-status');
  el.parentElement.classList.toggle('error', s.state === 'error');
  if (s.state === 'loading') el.textContent = 'depth · estimating…';
  else if (s.state === 'error') el.textContent = `depth error: ${s.error}`;
  else el.textContent = `depth ${[fmtMs(s.inferMs), s.device, `${s.width}×${s.height}`].filter(Boolean).join(' · ')}`;
}

export const setHint = (text) => { $('#hint').textContent = text; };
export const setBusy = (on) => $('#safelight').classList.toggle('on', on);

export function renderThumbs(names, onPick) {
  $('#thumbs').replaceChildren(...names.map((name) =>
    h('button', { type: 'button', class: 'thumb', 'data-name': name, title: name, onclick: () => onPick(name) },
      h('img', { src: `/samples/${name}.jpg`, alt: '', loading: 'lazy', decoding: 'async' }))));
}

export function markThumb(name) {
  document.querySelectorAll('.thumb').forEach((el) => el.classList.toggle('on', el.dataset.name === name));
}

/** Relief slider in the footer. onInput(g) on every move; setSpread(text) updates the readout. */
export function depthControl(value, max, onInput) {
  const input = $('#depth-g');
  const out = $('#depth-out');
  input.max = String(max);
  input.step = String(max / 100);
  input.value = String(value);
  input.addEventListener('input', () => onInput(Number(input.value)));
  return { setReadout: (text) => { out.textContent = text; } };
}
