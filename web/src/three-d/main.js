// 3D coach: the photo as a SHARP splat seen from the camera that took it, coaching regions as
// markers anchored on their objects, a guided walkthrough (1 · 2 · 3 · reframe), scores, and
// an upload screen.
import './3d.css';
import { normalizeImage } from '../api.js';
import * as coach from './coach.js';
import { createHud } from './hud.js';
import { packMasks, placeRegion } from './regions.js';
import { createStage } from './stage.js';

// Phone tunnel: ?k=<token> becomes the coach_k cookie and leaves the URL (as cam.html does).
const params = new URLSearchParams(location.search);
{
  const token = params.get('k');
  if (token) {
    document.cookie = `coach_k=${token}; path=/; SameSite=Lax`;
    params.delete('k');
    const qs = params.toString();
    history.replaceState(history.state, '', location.pathname + (qs ? `?${qs}` : '') + location.hash);
  }
}

const REDUCED = matchMedia('(prefers-reduced-motion: reduce)');
const body = document.body;
const canvas = document.getElementById('gl');
const hud = createHud();

let job = null; // the open photo and its in-flight work
let hovered = -1;
// The walkthrough. step: -1 overview, 0..n-1 a region, 'rf' the reframe. kept: the reframed
// angle stays after "Keep this angle".
const flow = { step: -1, dir: 1, kept: false, timers: [] };

const stage = createStage(canvas, { onFrame });

function onFrame() {
  if (!job?.regions) return;
  if (!job.markersShown && (stage.revealed || job.splat === 'flat')) {
    job.markersShown = true;
    hud.setMarkers(job.regions, { onEnter, onLeave, onTap });
    hud.setMarkerState(regionStep(), hovered);
    hud.hideMarkers(flow.step === 'rf');
    setupSteps();
  }
  if (job.markersShown) {
    const pts = stage.projectRegions();
    hud.placeMarkers(pts);
    const ni = noteIndex();
    if (ni >= 0 && pts[ni]) hud.placeNote(stage.projectBox(ni), pts[ni]);
  }
}

// ---------- the walkthrough ----------
const regionStep = () => (typeof flow.step === 'number' ? flow.step : -1);
const noteIndex = () => (regionStep() >= 0 ? regionStep() : flow.step === -1 ? hovered : -1);
const rank = (s) => (s === 'rf' ? 99 : s);
const later = (ms, fn) => flow.timers.push(setTimeout(fn, ms));
const clearTimers = () => flow.timers.splice(0).forEach(clearTimeout);
const haptic = (ms = 10) => navigator.vibrate?.(ms);

function setupSteps() {
  const me = job;
  if (!me?.markersShown) return;
  hud.setSteps(me.regions.length, rf.available !== false, (k) => goStep(k));
  updateStepUi();
  hud.setReady(true);
}
function updateStepUi() {
  hud.setStep(flow.step, { kept: flow.kept, rfBusy: flow.step === 'rf' && !job?.rfRes });
}

function applyFocus() {
  const s = regionStep();
  if (s >= 0) stage.focus(s, 1, 1);
  else if (hovered >= 0 && flow.step === -1) stage.focus(hovered, 0.35, 0);
  else stage.focus(-1, 0, 0);
  hud.setMarkerState(s, flow.step === -1 ? hovered : -1);
  updateNote();
}
function updateNote(delay) {
  const r = job?.regions;
  const i = noteIndex();
  if (!r || i < 0 || !r[i]) return hud.showNote(null);
  const isStep = regionStep() === i;
  hud.showNote({ kind: r[i].tag, text: r[i].note, step: isStep ? i + 1 : 0, total: r.length }, { dir: flow.dir, delay: delay ?? (isStep ? 280 : 90) });
}

/** One choreographed move: the camera glides to the target while the previous effect
 *  releases and the new one blooms (both springs run at once), and the note slides with it. */
function goStep(target, dir) {
  const me = job;
  if (!me?.markersShown || target === flow.step) return;
  const n = me.regions.length;
  if (typeof target === 'number' && (target < -1 || target >= n)) return;
  if (target === 'rf' && rf.available === false) return;
  const from = flow.step;
  flow.dir = dir ?? (rank(target) >= rank(from) ? 1 : -1);
  clearTimers();
  hud.showScoreCard(null);
  hovered = -1;
  haptic();
  if (target === 'rf') return enterReframe(me);
  if (from === 'rf') leaveReframe();
  else if (flow.kept && target !== -1) {
    flow.kept = false;
    flyTo(0);
  }
  flow.step = target;
  updateStepUi();
  applyFocus();
}
function next() {
  const n = job?.regions?.length ?? 0;
  const s = flow.step;
  if (s === 'rf') return job?.rfRes && keepAngle();
  const t = s + 1 < n ? s + 1 : rf.available !== false ? 'rf' : -1;
  goStep(t, 1);
}
function prev() {
  const n = job?.regions?.length ?? 0;
  const s = flow.step;
  if (s === -1) return;
  goStep(s === 'rf' ? n - 1 : s - 1, -1);
}
function exitToOverview() {
  if (flow.step === -1) return;
  goStep(-1, -1);
}

// ---------- reframe: the last step ----------
// Fetched once per photo right after the regions (cached per photo), so the step flies at once.
const rf = { available: null };

async function fetchReframe(me) {
  if (me.rfBusy) return me.rfWait;
  if (rf.available === false) return null;
  me.rfBusy = true;
  me.rfWait = (async () => {
    try {
      const list = me.list?.map(({ id, box, tag, note }) => ({ id, box, tag, note }));
      const res = await coach.reframe(me.photo, list, me.key, me.ctrl.signal);
      if (!res) rf.available = false;
      else {
        rf.available = true;
        me.rfRes = res;
      }
    } catch (err) {
      if (err.name !== 'AbortError') console.warn('reframe', err);
    } finally {
      me.rfBusy = false;
    }
    if (job === me) {
      if (rf.available === false && flow.step === 'rf') goStep(-1, -1);
      setupSteps();
    }
    return me.rfRes ?? null;
  })();
  return me.rfWait;
}

function rfSub(res) {
  const parts = [];
  const n = Array.isArray(res.keep) ? res.keep.length : 0;
  if (n >= 2) parts.push(`keeps all ${n}`);
  else if (n === 1) parts.push('keeps your subject');
  let sc = String(res.scene || '').trim().replace(/\.+$/, '');
  sc = sc.split(/,|;|:| and | with | where | that /)[0].trim();
  if (sc.length > 34) sc = sc.slice(0, 34).replace(/\s+\S*$/, '');
  sc = sc.replace(/\s+(of|over|in|on|at|the|a|an|and|to|by)$/i, '');
  if (sc) parts.push(`shows ${/^(the|a|an|its|their|his|her|your)\b/i.test(sc) ? '' : 'the '}${sc}`);
  const line = parts.join(' · ');
  return line ? line[0].toUpperCase() + line.slice(1) : '';
}

function flyTo(k) {
  if (REDUCED.matches) {
    // reduced motion: the flight becomes a short crossfade
    canvas.style.opacity = '0';
    setTimeout(() => {
      stage.reframeTo(k, { instant: true });
      canvas.style.opacity = '1';
    }, 100);
  } else stage.reframeTo(k);
}

async function enterReframe(me) {
  flow.step = 'rf';
  updateStepUi();
  stage.focus(-1, 0, 0); // the last effect releases as the flight takes off
  hud.setMarkerState(-1, -1);
  hud.hideMarkers(true);
  hud.showNote(null);
  const res = me.rfRes ?? (await fetchReframe(me));
  if (job !== me || flow.step !== 'rf') return;
  updateStepUi();
  if (!res) return goStep(-1, -1);
  const chrome = () => {
    hud.showFrame(true);
    later(REDUCED.matches ? 0 : 280, () => hud.showRfNote({ note: res.note, sub: rfSub(res) }));
  };
  if (flow.kept && stage.reframeK === 1 && !stage.flying) return chrome();
  if (stage.reframeX === 0) {
    const k = stage.setReframe(res.move);
    if (k < 1 && params.has('debug')) console.log(`reframe scaled to ${k.toFixed(2)} to keep the foreground in frame`);
  }
  flyTo(1);
  if (REDUCED.matches) return later(200, chrome);
  later(1120, () => hud.showFrame(true)); // brackets draw in at 80% of the flight
  later(1400, () => hud.showRfNote({ note: res.note, sub: rfSub(res) }));
}
function leaveReframe() {
  hud.showFrame(false);
  hud.showRfNote(null);
  hud.hideMarkers(false);
  flow.kept = false;
  flyTo(0);
}
function keepAngle() {
  clearTimers();
  hud.showFrame(false);
  hud.showRfNote(null);
  hud.hideMarkers(false);
  flow.kept = true;
  flow.step = -1;
  haptic(16);
  updateStepUi();
  applyFocus();
}
stage.onFlightCancel(() => {
  if (flow.step !== 'rf' || !job?.rfRes) return;
  clearTimers();
  hud.showFrame(true);
  hud.showRfNote({ note: job.rfRes.note, sub: rfSub(job.rfRes) });
});

// ---------- markers ----------
function onEnter(i) {
  if (flow.step !== -1) return;
  hovered = i;
  applyFocus();
}
function onLeave(i) {
  if (hovered === i) hovered = -1;
  applyFocus();
}
function onTap(i) {
  goStep(i);
}
stage.onTap(() => {
  hud.showScoreCard(null);
  if (flow.step !== -1) exitToOverview();
  else if (hovered >= 0) {
    hovered = -1;
    applyFocus();
  }
});
stage.onSwipe((d) => {
  if (body.dataset.view !== 'scene') return;
  if (d > 0) next();
  else prev();
});
hud.nextBtn.addEventListener('click', next);
hud.prevBtn.addEventListener('click', prev);

// ---------- opening a photo ----------
const index = await fetch('/splats/index.json')
  .then((r) => (r.ok ? r.json() : {}))
  .catch(() => ({}));
const SAMPLES = Object.keys(index);
const PICKS = ['img-1016', 'img-1216', 'img-1408', 'img-1427', 'img-1931', 'img-1491'].filter((s) => SAMPLES.includes(s));
const SHOWN = PICKS.length >= 6 ? PICKS : SAMPLES.slice(0, 6);

function intrinsicsFor(photo, sample) {
  const fw = index[sample]?.f_over_w;
  // Uploads until /api/splat says otherwise: a phone main camera, f ~ 0.75 x long side.
  const f = fw ? fw * photo.width : 0.75 * Math.max(photo.width, photo.height);
  return { tanX: photo.width / (2 * f), tanY: photo.height / (2 * f) };
}

function resetFlow() {
  clearTimers();
  flow.step = -1;
  flow.kept = false;
  flow.dir = 1;
  hovered = -1;
  hud.setReady(false);
  hud.showNote(null);
  hud.showFrame(false);
  hud.showRfNote(null);
  hud.showScoreCard(null);
  updateStepUi();
}

function setView(v) {
  body.dataset.view = v;
  const loading = job?.viaPicker && job.splat === 'loading';
  hud.setUpload(loading ? 'loading' : 'idle', { back: v === 'upload' && !!job?.photo && !loading });
}

function progress(me, p) {
  if (job !== me) return;
  me.progress = Math.max(me.progress || 0, p);
  hud.setProgress(me.progress);
}

async function open({ sample = null, file = null }, { viaPicker = false } = {}) {
  job?.ctrl.abort();
  clearInterval(job?.estimate);
  const ctrl = new AbortController();
  const signal = ctrl.signal;
  const me = { ctrl, sample, regions: null, markersShown: false, splat: 'loading', viaPicker, progress: 0 };
  job = me;
  resetFlow();
  hud.clearMarkers();
  hud.setScores('loading');
  hud.setFlat(false);
  hud.markSample(sample);
  hud.setProgress(0);
  if (viaPicker) {
    setView('upload');
    progress(me, 0.02);
  }

  let photo;
  try {
    const blob = file ?? (await fetch(`/samples/${sample}.jpg`, { signal }).then((r) => r.blob()));
    photo = await normalizeImage(blob);
  } catch (err) {
    if (err.name !== 'AbortError') console.error('photo', err);
    if (job === me && viaPicker) hud.setUpload('idle');
    return;
  }
  if (job !== me) return;
  me.photo = photo;
  progress(me, 0.06);
  const token = stage.showPhoto(photo.bitmap, intrinsicsFor(photo, sample));
  me.key = sample ? `sample:${sample}` : `img:${await coach.hashBlob(photo.blob)}`;
  hud.setBusy(true);

  loadSplat(me, token);
  analyze(me);
  coach
    .score(photo, me.key, signal)
    .then((j) => job === me && hud.setScores(j?.scores || 'error'))
    .catch((err) => job === me && err.name !== 'AbortError' && (console.warn('score', err), hud.setScores('error')));
}

async function loadSplat(me, token) {
  try {
    let source;
    const dl = (f) => progress(me, 0.06 + 0.86 * f);
    if (me.sample) {
      source = { url: `/splats/${me.sample}.spz`, onProgress: (e) => e.lengthComputable && e.total && dl(e.loaded / e.total) };
    } else {
      // No progress from SHARP itself: ease toward 66% while the server works, then the
      // download fills the rest.
      const t0 = performance.now();
      me.estimate = setInterval(() => progress(me, 0.06 + 0.6 * (1 - Math.exp(-(performance.now() - t0) / 6000))), 120);
      const s = await coach.splat(me.photo, me.ctrl.signal, (n, total) => {
        clearInterval(me.estimate);
        progress(me, 0.66 + 0.26 * (n / total));
      });
      clearInterval(me.estimate);
      if (job !== me) return;
      if (!s) throw Object.assign(new Error('no /api/splat'), { flat: true });
      if (s.intrinsics) stage.setIntrinsics(s.intrinsics.tanX, s.intrinsics.tanY);
      source = { fileBytes: s.bytes, fileName: 'photo.spz' };
    }
    const ok = await stage.loadSplat(source, token);
    if (!ok || job !== me) return;
    me.splat = '3d';
    if (me.decoded) place(me); // re-anchor markers on real depth
    ready(me);
  } catch (err) {
    clearInterval(me.estimate);
    if (err.name === 'AbortError' || job !== me) return;
    if (!err.flat) console.warn('splat', err);
    me.splat = 'flat'; // keep the flat photo with parallax; the top bar says so
    hud.setFlat(true);
    ready(me);
  }
}

/** The scene is ready: the upload screen gives way and the splats sweep in, near to far. */
function ready(me) {
  progress(me, 1);
  const wasPicking = body.dataset.view === 'upload' && me.viaPicker;
  if (wasPicking) setTimeout(() => job === me && setView('scene'), 160);
  else setView(body.dataset.view);
  if (me.splat === '3d') setTimeout(() => job === me && stage.reveal(), wasPicking ? 260 : 120);
}

async function analyze(me) {
  const { photo, key, ctrl } = me;
  try {
    const list = await coach.regions(photo, key, ctrl.signal);
    if (job !== me) return;
    let decoded = null;
    try {
      decoded = (await coach.masks(photo, list, ctrl.signal)).masks;
    } catch (err) {
      if (err.name === 'AbortError') return;
      console.warn('masks: falling back to soft box ellipses', err);
    }
    if (job !== me) return;
    me.list = list;
    me.decoded = decoded ?? new Map();
    place(me);
  } catch (err) {
    if (err.name === 'AbortError') return;
    console.warn('regions', err);
    if (job === me) me.regions = [];
  } finally {
    if (job === me) {
      hud.setBusy(false);
      fetchReframe(me);
    }
  }
}

/** Masks -> texture + 3D anchors (median splat depth inside each mask). */
function place(me) {
  const v = stage.view;
  const pack = packMasks(me.decoded, me.list, photoAspect(me));
  const samples = me.splat === '3d' ? v.samples : null;
  const placed = me.list.map((r, i) => ({ ...r, ...placeRegion(pack, i, r, samples, v.tanX, v.tanY, stage.planeD) }));
  if (params.has('debug')) console.log(`S=${v.S.toFixed(2)} near=${v.near.toFixed(2)} regions ` + JSON.stringify(placed.map((r) => ({ id: r.id, tag: r.tag, depth: r.depth.toFixed(2), gate: [r.gate.x.toFixed(2), r.gate.y.toFixed(2)], n: r.count, uv: r.uv.map((x) => x.toFixed(3)) }))));
  stage.setRegions(placed, pack.tex);
  me.regions = placed;
  stage.requestRender();
}

const photoAspect = (me) => me.photo.width / me.photo.height;

// ---------- input ----------
hud.setSamples(SHOWN, (name) => open({ sample: name }, { viaPicker: true }));
const fileInput = document.getElementById('file');
fileInput.addEventListener('change', (e) => {
  const f = e.target.files?.[0];
  if (f) open({ file: f }, { viaPicker: true });
  e.target.value = '';
});
document.getElementById('add').addEventListener('click', () => fileInput.click());
document.getElementById('back').addEventListener('click', () => {
  if (flow.step !== -1) exitToOverview();
  setView('upload');
});
document.getElementById('up-back').addEventListener('click', () => job?.photo && setView('scene'));

let dragDepth = 0;
let dragPeek = false;
window.addEventListener('dragenter', (e) => {
  e.preventDefault();
  if (dragDepth++ === 0) {
    hud.dropZone.classList.add('over');
    if (body.dataset.view !== 'upload') {
      dragPeek = true;
      setView('upload');
    }
  }
});
const endDrag = () => {
  dragDepth = 0;
  hud.dropZone.classList.remove('over');
  if (dragPeek) setView('scene');
  dragPeek = false;
};
window.addEventListener('dragleave', () => --dragDepth <= 0 && endDrag());
window.addEventListener('dragover', (e) => e.preventDefault());
window.addEventListener('drop', (e) => {
  e.preventDefault();
  const f = [...(e.dataTransfer?.files || [])].find((x) => x.type.startsWith('image/'));
  dragPeek = false;
  endDrag();
  if (f) open({ file: f }, { viaPicker: true });
});

window.addEventListener('keydown', (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  if (body.dataset.view === 'upload') {
    if (e.key === 'Escape' && job?.photo && !(job.viaPicker && job.splat === 'loading')) setView('scene');
    return;
  }
  if (e.key === 'Escape') {
    hud.showScoreCard(null);
    if (flow.step !== -1) exitToOverview();
    else if (hovered >= 0) onLeave(hovered);
  } else if (e.key === 'ArrowRight') next();
  else if (e.key === 'ArrowLeft') prev();
  else if ((e.key === 'r' || e.key === 'R') && !e.repeat) goStep(flow.step === 'rf' ? -1 : 'rf');
  else {
    const n = Number(e.key);
    if (n >= 1 && n <= 3) goStep(n - 1);
  }
});

// Debug/QA handle.
window.__lc3d = {
  stage,
  hud,
  open,
  focus: (i) => goStep(i),
  step: (s) => goStep(s),
  next,
  prev,
  keep: keepAngle,
  hover: (i) => (i >= 0 ? onEnter(i) : onLeave(hovered)),
  get flow() {
    return flow;
  },
  get job() {
    return job;
  },
};

const first = params.get('sample');
if (SAMPLES.includes(first)) open({ sample: first });
else setView('upload');
