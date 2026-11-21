import './style.css';
import { createApi, normalizeImage } from './api.js';
import { createViewer, DEFAULT_GAMMA } from './points.js';
import { decodeMasks } from './masks.js';
import * as ui from './ui.js';

const params = new URLSearchParams(location.search);
const MOCK = params.has('mock') && params.get('mock') !== '0';
const api = createApi({ mock: MOCK, fail: params.get('fail') });
const SAMPLES = ['img-1016', 'img-1216', 'img-1408', 'img-1427', 'img-1457', 'img-1491', 'img-1931', 'img-2178'];

// Relief exponent g (distance = D0 * (d / p02)^g): ?depth= wins, then the slider's last value.
const GAMMA_KEY = 'lc.depthGamma';
const GAMMA_MAX = +(DEFAULT_GAMMA * 2).toFixed(2);
const readGamma = (v) => (v != null && v !== '' && Number.isFinite(+v) && +v >= 0 ? Math.min(+v, GAMMA_MAX * 2) : null);
let stored = null;
try { stored = localStorage.getItem(GAMMA_KEY); } catch { /* storage blocked */ }
const gamma0 = readGamma(params.get('depth')) ?? readGamma(stored) ?? DEFAULT_GAMMA;

const viewer = createViewer(document.getElementById('viewport'), document.getElementById('gl'), { gamma: gamma0 });
document.getElementById('mock-badge').hidden = !MOCK;

const depthCtl = ui.depthControl(gamma0, Math.max(GAMMA_MAX, gamma0), (g) => {
  viewer.setGamma(g);
  try { localStorage.setItem(GAMMA_KEY, String(g)); } catch { /* storage blocked */ }
  showSpread();
});
function showSpread() {
  const d = viewer.depthInfo();
  depthCtl.setReadout(d.hasDepth ? `×${d.spread.toFixed(1)}` : `g ${d.gamma.toFixed(2)}`);
}
showSpread();

let seq = 0;            // bumps on every new photo; older responses are dropped
let controller = null;
let regions = [];
let activeId = null;
let depthState = 'idle'; // idle | loading | ready | error
let viewMode = 'flat';
const pending = new Set();

function updateHint() {
  let text = 'drop a photo to begin';
  if (depthState === 'loading') text = 'estimating depth…';
  else if (depthState === 'error') text = 'depth unavailable · flat view';
  else if (depthState === 'ready') {
    text = { flat: 'click the photo to reveal depth', revealing: 'developing…',
      revealed: 'drag to look around · click to flatten', flattening: '' }[viewMode];
  }
  ui.setHint(text);
}
viewer.onChange(({ mode }) => { viewMode = mode; updateHint(); });

function setActive(r) {
  activeId = r ? r.id : null;
  viewer.setActive(r);
  ui.markRegion(activeId);
}

const clamp01 = (x) => (Number.isFinite(x) ? Math.max(0, Math.min(1, x)) : 0);
function cleanRegions(list) {
  return (Array.isArray(list) ? list : []).map((r, i) => {
    const b = r.box || {};
    const x = clamp01(+b.x);
    const y = clamp01(+b.y);
    return {
      id: String(r.id ?? `r${i + 1}`),
      tag: r.tag === 'remove' ? 'remove' : 'focus',
      note: String(r.note ?? ''),
      box: { x, y, w: Math.min(clamp01(+b.w), 1 - x), h: Math.min(clamp01(+b.h), 1 - y) },
    };
  });
}

async function loadPhoto(source, sampleName = null) {
  const id = ++seq;
  controller?.abort();
  controller = new AbortController();
  const { signal } = controller;
  const current = () => id === seq;

  ui.markThumb(sampleName);
  setActive(null);
  viewer.setHover(null);
  regions = [];
  ui.scoresLoading();
  ui.regionsLoading();
  ui.depthStatus({ state: 'loading' });
  depthState = 'loading';
  updateHint();
  ui.setBusy(true);

  let photo;
  try {
    const blob = source instanceof Blob ? source : await fetch(source, { signal }).then((r) => {
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return r.blob();
    });
    photo = await normalizeImage(blob);
  } catch (e) {
    if (!current() || e.name === 'AbortError') return;
    const msg = `couldn't read that image (${e.message})`;
    ui.scoresError(msg);
    ui.regionsError(msg);
    ui.depthStatus({ state: 'error', error: msg });
    depthState = 'error';
    updateHint();
    ui.setBusy(false);
    return;
  }
  if (!current()) { photo.bitmap.close(); return; }
  viewer.setPhoto(photo.bitmap, photo.width, photo.height);

  // All three in parallel; each panel fills in on its own, and failures stay local.
  pending.clear();
  const run = (name, call, onOk, onErr) => {
    pending.add(name);
    call(photo, signal)
      .then((v) => { if (current()) onOk(v); })
      .catch((e) => { if (current() && e.name !== 'AbortError') onErr(e.message || String(e)); })
      .finally(() => { if (current()) { pending.delete(name); ui.setBusy(pending.size > 0); } });
  };

  showSpread();
  run('depth', api.depth, (d) => {
    viewer.setDepth(d);
    depthState = 'ready';
    ui.depthStatus({ state: 'ok', ...d });
    showSpread();
    updateHint();
  }, (msg) => {
    depthState = 'error';
    ui.depthStatus({ state: 'error', error: msg });
    updateHint();
  });

  run('regions', api.regions, (data) => {
    regions = cleanRegions(data?.regions);
    ui.regionsRender(regions, data, {
      onHover: (r) => viewer.setHover(r),
      onToggle: (r) => setActive(activeId === r.id ? null : r),
    });
    if (!regions.length) return;
    // Then trace each region's object. Until (or unless) that lands, a note lights its box.
    const traced = regions;
    ui.masksLoading();
    run('masks', async (p, s) => decodeMasks(await api.masks(p, traced, s), traced), (m) => {
      viewer.setMasks(m.masks);
      ui.masksReady((id) => viewer.hasMask(id), m);
    }, ui.masksError);
  }, ui.regionsError);

  run('score', api.score, ui.scoresRender, ui.scoresError);
}

// ---------------- input: samples, upload, drag and drop ----------------

ui.renderThumbs(SAMPLES, (name) => loadPhoto(`/samples/${name}.jpg`, name));

const fileInput = document.getElementById('file');
fileInput.addEventListener('change', () => {
  const file = fileInput.files?.[0];
  if (file) loadPhoto(file);
  fileInput.value = '';
});

const hasFiles = (e) => Array.from(e.dataTransfer?.types || []).includes('Files');
let dragDepth = 0;
window.addEventListener('dragenter', (e) => {
  if (!hasFiles(e)) return;
  e.preventDefault();
  dragDepth++;
  document.body.classList.add('dragging');
});
window.addEventListener('dragover', (e) => { if (hasFiles(e)) e.preventDefault(); });
window.addEventListener('dragleave', (e) => {
  if (!hasFiles(e)) return;
  if (--dragDepth <= 0) { dragDepth = 0; document.body.classList.remove('dragging'); }
});
window.addEventListener('drop', (e) => {
  if (!hasFiles(e)) return;
  e.preventDefault();
  dragDepth = 0;
  document.body.classList.remove('dragging');
  const file = Array.from(e.dataTransfer.files).find((f) => f.type.startsWith('image/') || !f.type);
  if (file) loadPhoto(file);
});

window.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && activeId) setActive(null);
});

loadPhoto(`/samples/${SAMPLES[0]}.jpg`, SAMPLES[0]);
