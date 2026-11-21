// Coach Cam: wires the viewfinder, HUD, capture flow and the selected engine around one CamState.
import { createBus, MODES } from './bus.js';
import { createViewfinder } from './viewfinder.js';
import { createHud } from './hud.js';
import { createCapture } from './capture.js';
import * as audio from './audio.js';

const ENGINES = {
  live: () => import('./live.js'),
  decide: () => import('./decide.js'),
  mock: () => import('./mock.js'),
};
const ORDER = ['live', 'decide', 'mock'];
const FALLBACK = { live: 'decide', decide: 'mock', mock: null };
const $ = (id) => document.getElementById(id);
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- URL: token + params
const query = new URLSearchParams(location.search);
const token = query.get('k');
if (token) {
  document.cookie = `coach_k=${token}; path=/; SameSite=Lax`;
  query.delete('k');
  const qs = query.toString();
  history.replaceState(null, '', location.pathname + (qs ? `?${qs}` : '') + location.hash);
}
const initialEngine = ENGINES[query.get('engine')] ? query.get('engine') : 'live';

// ---------------------------------------------------------------- camera choice (remembered)
const CAM_KEY = 'coachcam.camera';
const camQuery = (query.get('cam') || '').trim().toLowerCase();
const IS_MOBILE = /iPhone|iPad|iPod|Android/i.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
function loadCam() { try { return JSON.parse(localStorage.getItem(CAM_KEY) || 'null'); } catch { return null; } }
function saveCam(v) { try { localStorage.setItem(CAM_KEY, JSON.stringify(v)); } catch { /* private mode */ } }
const savedCam = loadCam();

// Cameras that look away from you: an iPhone/iPad via Continuity Camera (its rear camera),
// Desk View, or anything labelled back/rear. Those are never mirrored.
const REAR_RE = /iphone|ipad|continuity|desk view|\bback\b|\brear\b|environment|world/i;
function facingOf(track) {
  const label = track?.label || '';
  const fm = track?.getSettings?.().facingMode;
  if (REAR_RE.test(label)) return 'environment';
  if (fm === 'environment' || fm === 'user') return fm;
  return 'user';
}
function shortName(label = '') {
  if (/desk view/i.test(label)) return 'Desk View';
  if (/iphone/i.test(label)) return 'iPhone';
  if (/ipad/i.test(label)) return 'iPad';
  if (/facetime|built-?in|integrated/i.test(label)) return 'Built-in';
  if (/front/i.test(label)) return 'Front';
  if (/back|rear/i.test(label)) return /ultra/i.test(label) ? 'Back ultra wide' : /tele/i.test(label) ? 'Back tele' : 'Back';
  const s = label.replace(/\([^)]*\)/g, '').replace(/\b(camera|webcam|video|hd|usb)\b/gi, '').replace(/\s+/g, ' ').trim();
  return (s || 'Camera').slice(0, 14);
}

// ---------------------------------------------------------------- state (single source of truth)
const state = {
  facing: query.get('facing') === 'environment' || (!query.get('facing') && savedCam?.facing === 'environment' && IS_MOBILE) ? 'environment' : 'user',
  mirrored: true,
  mode: 'photo',
  zoom: 1,
  exposure: 0,
  warmth: 0,
  iso: null,
  shutter: null,
  focus: null,
  flash: 'off',
  intent: null,
  subject: null,
  voice: query.get('voice') !== '0',
  engine: initialEngine,
  caps: { zoom: false, exposure: false, iso: false, shutter: false, focus: false, wb: false, torch: false },
};
function getState() {
  return { ...state, focus: state.focus ? { ...state.focus } : null, caps: { ...state.caps } };
}

// ---------------------------------------------------------------- modules
const root = $('cam');
const bus = createBus();
const vf = createViewfinder({ canvas: $('vf'), video: $('video') });
const hud = createHud({
  root, bus, getState,
  els: {
    hud: $('hud'), shutter: $('shutter'), caption: $('caption'), readout: $('readout'), intent: $('intent'),
    dot: $('dot'), engineName: $('engine-name'), voice: $('voice'), modes: $('modes'), modesTrack: $('modes-track'),
    debug: $('debug'), said: $('said'), srGuide: $('sr-guide'), srCaption: $('sr-caption'),
    rawToScreen: (x, y) => vf.rawToScreen(x, y),
  },
});
const capture = createCapture({
  root, bus, vf, getState,
  isCoached: () => hud.readyOn,
  els: {
    shutter: $('shutter'), flash: $('flash'), thumb: $('thumb'), review: $('review'), reviewImg: $('review-img'),
    card: $('review-card'), meta: $('review-meta'),
    back: $('review-back'), save: $('review-save'), share: $('review-share'),
  },
});

hud.setVoice(state.voice);
hud.engine(state.engine, { announce: false });
hud.status({ state: 'idle' });
requestAnimationFrame(() => hud.setMode(state.mode, { instant: true, by: 'user' }));
if (query.get('debug') === '1') hud.setDebug(true);

// ---------------------------------------------------------------- readout pill: zoom · ISO · EV
// Real values only: zoom and EV are what the viewfinder applies (hardware or emulated); ISO is
// the coach-set value, else what the camera reports, else AUTO.
function fmtZoom(z) { return `${Math.round(z * 10) / 10}×`; }
function fmtEV(v) {
  const r = Math.round(v * 10) / 10;
  return `${r > 0 ? '+' : r < 0 ? '−' : '±'}${Math.abs(r).toFixed(1)}`;
}
function hwIso() {
  try { const v = vf.track?.getSettings?.().iso; return Number.isFinite(v) && v > 0 ? v : null; } catch { return null; }
}
let roPrev = { zoom: 1, iso: null, exposure: 0 };
function updateReadout(changed = {}, source = 'engine') {
  const iso = state.iso || hwIso();
  const items = [
    { key: 'zoom', value: fmtZoom(state.zoom) },
    { key: 'iso', prefix: 'ISO ', value: iso ? String(Math.round(iso)) : 'AUTO' },
    { key: 'ev', value: fmtEV(state.exposure) },
  ];
  const dirs = {
    zoom: Math.sign(state.zoom - roPrev.zoom) || 1,
    iso: Math.sign((iso || 0) - (roPrev.iso || 0)) || 1,
    ev: Math.sign(state.exposure - roPrev.exposure) || 1,
  };
  const coachKeys = source === 'ui' ? [] : [
    'zoom' in changed && 'zoom', ('iso' in changed) && 'iso', 'exposure' in changed && 'ev',
  ].filter(Boolean);
  roPrev = { zoom: state.zoom, iso, exposure: state.exposure };
  hud.setReadout(items, { coachKeys, dirs });
}
updateReadout();

// ---------------------------------------------------------------- settings
function normalize(k, v) {
  switch (k) {
    case 'mode': return MODES.includes(v) ? v : undefined;
    case 'zoom': return Number.isFinite(+v) ? clamp(+v, 1, 5) : undefined;
    case 'exposure': return Number.isFinite(+v) ? clamp(+v, -2, 2) : undefined;
    case 'warmth': return Number.isFinite(+v) ? clamp(+v, -1, 1) : undefined;
    case 'iso': return v == null ? null : +v > 0 ? +v : undefined;
    case 'shutter': return v == null ? null : +v > 0 ? +v : undefined;
    case 'focus':
      if (v == null) return null;
      if (Number.isFinite(+v.x) && Number.isFinite(+v.y)) return { x: clamp(+v.x, 0, 1), y: clamp(+v.y, 0, 1) };
      return undefined;
    case 'flash': return ['off', 'on', 'auto'].includes(v) ? v : undefined;
    default: return undefined;
  }
}
const same = (a, b) => (a && b && typeof a === 'object' ? a.x === b.x && a.y === b.y : a === b);

function applySettings(patch = {}, source = 'engine', { emit = true } = {}) {
  const p = { ...patch };
  if (p.focus === undefined && (p.focus_x != null || p.focus_y != null)) p.focus = { x: p.focus_x ?? 0.5, y: p.focus_y ?? 0.5 };
  const changed = {};
  for (const k of ['mode', 'zoom', 'exposure', 'warmth', 'iso', 'shutter', 'focus', 'flash']) {
    if (!(k in p)) continue;
    const v = normalize(k, p[k]);
    if (v === undefined || same(state[k], v)) continue;
    state[k] = v;
    changed[k] = v;
  }
  if (!Object.keys(changed).length) return changed;
  vf.setTarget(state);
  if ('mode' in changed) {
    hud.setMode(state.mode, { by: source === 'ui' ? 'user' : 'coach' });
    // a 4px blur pop hides the camera reconfiguring
    if (!matchMedia('(prefers-reduced-motion: reduce)').matches) $('vf').animate([{ filter: 'blur(4px)' }, { filter: 'blur(0px)' }], { duration: 120, easing: 'cubic-bezier(.22,1,.36,1)' });
  }
  if ('zoom' in changed || 'exposure' in changed || 'iso' in changed) updateReadout(changed, source);
  if ('focus' in changed && state.focus && source !== 'ui') {
    const s = vf.rawToScreen(state.focus.x, state.focus.y);
    hud.focusAt(s.x, s.y);
  }
  if (source === 'ui' && emit) bus.emit('ui:settings', { ...changed, source: 'ui' });
  hud.refreshDebug();
  return changed;
}
vf.setTarget(state);

bus.on('settings', (d) => {
  if (d?.source === 'ui') return;
  applySettings(d, 'engine');
});
bus.on('intent', (d) => {
  state.intent = d?.intent ?? null;
  state.subject = d?.subject ?? state.subject;
});

// ---------------------------------------------------------------- engine (live -> decide -> mock)
let engine = null;
let engineGen = 0;
let ctx = null;

async function loadEngine(name) {
  const mod = await ENGINES[name]();
  return mod.createEngine(ctx);
}

// Start `name`; if it can't reach "live" (start throws, live never gets a session, or it reports
// an error before it ever went live), fall back down the chain and mark the engine dot.
async function startEngine(name, { failed = null } = {}) {
  const gen = ++engineGen;
  if (engine) { try { engine.stop(); } catch (e) { console.warn('[cam] engine stop', e); } }
  engine = null;
  state.engine = name;
  ctx.voice = state.voice;
  hud.engine(name, { fallback: !!failed, failed, announce: !!failed || gen > 1 });
  hud.status({ state: 'connecting' });
  let eng = null, wentLive = false, fellBack = false, watchdog = 0;
  const off = bus.on('status', (d) => {
    if (gen !== engineGen || d?.source === 'ui') return;
    if (d?.state === 'live' || d?.state === 'thinking') { wentLive = true; off(); clearTimeout(watchdog); }
    else if (d?.state === 'error' && !wentLive) fallback(d.detail || 'error');
  });
  watchdog = setTimeout(off, 30000);
  async function fallback(why) {
    if (fellBack || gen !== engineGen) return;
    fellBack = true;
    off();
    clearTimeout(watchdog);
    const next = FALLBACK[name];
    console.warn(`[cam] engine "${name}" failed (${why})${next ? `, falling back to ${next}` : ''}`);
    if (next) { try { eng?.stop?.(); } catch { /* ignore */ } engine = null; }
    bus.emit('status', { state: 'error', detail: `${name}: ${why}`, source: 'ui' });
    if (!next) return;
    await sleep(700); // let the error dot register
    if (gen === engineGen) startEngine(next, { failed: failed || name });
  }
  try {
    eng = await loadEngine(name);
    if (gen !== engineGen) { eng.stop?.(); off(); return; }
    engine = eng;
    eng.setVoice?.(state.voice);
    await eng.start();
    if (gen === engineGen && name === 'live' && !wentLive) fallback('no session');
  } catch (e) {
    fallback(e?.message || String(e));
  }
  if (gen !== engineGen || fellBack) return;
  const qs = new URLSearchParams(location.search);
  qs.set('engine', failed || name);
  history.replaceState(null, '', `${location.pathname}?${qs}${location.hash}`);
}

// ---------------------------------------------------------------- start screen footer
const ENGINE_FOOT = { live: 'Gemini Live', decide: 'Gemini', mock: 'Mock' };
async function checkBackend() {
  const foot = $('start-foot');
  const label = foot.querySelector('span');
  const set = (s, t) => { foot.dataset.state = s; label.textContent = `${ENGINE_FOOT[state.engine]} · ${t}`; };
  if (state.engine === 'mock') { set('ready', 'Ready'); return; }
  set('checking', 'Checking');
  try {
    const r = await fetch('/api/health', { cache: 'no-store' });
    if (r.ok) set('ready', 'Ready');
    else if (r.status === 401) set('offline', 'Needs key');
    else set('offline', 'Offline');
  } catch { set('offline', 'Offline'); }
}
checkBackend();

// ---------------------------------------------------------------- camera start
let stream = null;
let mic = null;
let audioCtx = null;
let videoInputs = [];

function unlockAudio() {
  try {
    audio.unlockAudio();
    return audio.audioContext?.() || null;
  } catch (e) {
    console.warn('[cam] audio unlock failed', e?.message || e);
    return null;
  }
}

function videoConstraints(extra = {}) {
  return { width: { ideal: 1280 }, height: { ideal: 720 }, ...extra };
}

async function listCameras() {
  try { videoInputs = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === 'videoinput'); } catch { videoInputs = []; }
  $('flip').hidden = videoInputs.length < 2;
  return videoInputs;
}
const matchQuery = (list) => (camQuery ? list.find((d) => d.label.toLowerCase().includes(camQuery)) : null);

// Which device to open first: ?cam= (label substring) > remembered choice > default.
async function initialDeviceId() {
  const list = await listCameras(); // labels are only there once permission was granted before
  const q = matchQuery(list);
  if (q) return q.deviceId;
  if (!IS_MOBILE && savedCam?.deviceId && list.some((d) => d.deviceId === savedCam.deviceId)) return savedCam.deviceId;
  return null;
}

async function openStream() {
  const audioC = { echoCancellation: true, noiseSuppression: true, channelCount: 1 };
  const id = await initialDeviceId();
  const video = videoConstraints(id ? { deviceId: { exact: id } } : { facingMode: state.facing });
  const plain = videoConstraints({ facingMode: state.facing });
  const attempts = [
    { video: { ...video, zoom: true }, audio: audioC },
    { video, audio: audioC },
    ...(id ? [{ video: plain, audio: audioC }] : []),
    { video: plain, audio: false },
  ];
  let err;
  for (const c of attempts) {
    try { return await navigator.mediaDevices.getUserMedia(c); } catch (e) {
      err = e;
      if (e?.name === 'NotAllowedError' && c.audio === false) break;
    }
  }
  throw err;
}

let noteCamera = false;
function applyStreamInfo(info) {
  state.mirrored = info.mirrored;
  state.facing = info.facing;
  state.caps = info.caps;
  vf.setTarget(state);
  updateReadout();
  hud.refreshDebug();
  const track = stream?.getVideoTracks()[0];
  console.info('[cam] camera', track?.label || '?', info.settings?.width, 'x', info.settings?.height, 'facing', info.facing, 'mirrored', info.mirrored, 'hw caps', info.caps);
  if (noteCamera && track) hud.readoutNote(shortName(track.label));
  noteCamera = false;
}
async function attachStream() {
  const track = stream.getVideoTracks()[0];
  applyStreamInfo(await vf.attach(stream, { facing: facingOf(track) }));
  watchTrack(track);
}

async function start() {
  if (root.dataset.state === 'starting' || root.dataset.state === 'live') return;
  audioCtx = audioCtx || unlockAudio(); // inside the tap: iOS only unlocks audio in a gesture
  root.dataset.state = 'starting';
  try {
    if (!navigator.mediaDevices?.getUserMedia) throw new Error('Camera needs HTTPS');
    stream = await openStream();
  } catch (e) {
    console.warn('[cam] getUserMedia failed', e);
    root.dataset.state = 'error';
    $('start-label').textContent = e?.name === 'NotAllowedError' ? 'Camera blocked' : 'No camera';
    return;
  }
  await attachStream();
  try {
    mic = stream.getAudioTracks().length ? await audio.createMic(stream) : null;
  } catch (e) {
    console.warn('[cam] mic unavailable:', e?.message || e);
    mic = null;
  }
  const list = await listCameras();
  root.dataset.state = 'live';
  // ?cam= couldn't be honoured before permission (no labels yet): switch now.
  const want = matchQuery(list);
  const cur = stream.getVideoTracks()[0];
  if (want && cur?.getSettings?.().deviceId !== want.deviceId) await useDevice(want.deviceId);
  else if (cur) {
    if (list.length > 1) hud.readoutNote(shortName(cur.label));
    if (camQuery) saveCam({ deviceId: cur.getSettings?.().deviceId, label: cur.label, facing: state.facing });
  }
  ctx = { bus, mic, grabFrame: (maxSide = 768, quality = 0.7) => vf.grabFrame(maxSide, quality), getState, voice: state.voice, audioCtx };
  startEngine(state.engine);
}
$('start-btn').addEventListener('click', start);

// ---------------------------------------------------------------- switch camera
// Desktop: cycle videoinputs by deviceId (an iPhone via Continuity Camera shows up as one).
// Phone: flip facingMode, falling back to the next device when that doesn't change camera.
let switching = false;
async function swapVideoTrack(vs) {
  const old = stream.getVideoTracks()[0];
  if (old) { old.onended = null; stream.removeTrack(old); old.stop(); }
  stream.addTrack(vs.getVideoTracks()[0]);
  $('video').srcObject = null;
  noteCamera = true;
  await attachStream();
  hud.clearMove();
  const t = stream.getVideoTracks()[0];
  saveCam({ deviceId: t?.getSettings?.().deviceId, label: t?.label, facing: state.facing });
}
async function useDevice(deviceId) {
  if (!stream || switching) return false;
  switching = true;
  root.classList.add('flipping');
  try {
    await sleep(160);
    let vs = null;
    try { vs = await navigator.mediaDevices.getUserMedia({ video: videoConstraints({ deviceId: { exact: deviceId } }) }); } catch (e) {
      // some phones can't open a second camera while one is running
      const old = stream.getVideoTracks()[0];
      old?.stop();
      try { vs = await navigator.mediaDevices.getUserMedia({ video: videoConstraints({ deviceId: { exact: deviceId } }) }); } catch (e2) {
        console.warn('[cam] camera switch failed', e2?.name || e2);
        vs = await navigator.mediaDevices.getUserMedia({ video: videoConstraints() }).catch(() => null);
      }
    }
    if (vs) await swapVideoTrack(vs);
    return !!vs;
  } finally {
    setTimeout(() => root.classList.remove('flipping'), 60);
    switching = false;
  }
}
async function flipFacing() {
  if (!stream || switching) return;
  switching = true;
  root.classList.add('flipping');
  try {
    await sleep(160);
    const old = stream.getVideoTracks()[0];
    const oldId = old?.getSettings?.().deviceId;
    const next = state.facing === 'user' ? 'environment' : 'user';
    old?.stop();
    let vs = null;
    try { vs = await navigator.mediaDevices.getUserMedia({ video: videoConstraints({ facingMode: { exact: next } }) }); } catch { vs = null; }
    if (!vs || vs.getVideoTracks()[0]?.getSettings?.().deviceId === oldId) {
      vs?.getTracks().forEach((t) => t.stop());
      const i = videoInputs.findIndex((d) => d.deviceId === oldId);
      const nextDev = videoInputs[(i + 1) % videoInputs.length];
      try { vs = await navigator.mediaDevices.getUserMedia({ video: videoConstraints({ deviceId: { exact: nextDev.deviceId } }) }); }
      catch { vs = await navigator.mediaDevices.getUserMedia({ video: videoConstraints({ deviceId: oldId ? { exact: oldId } : undefined }) }); }
    }
    await swapVideoTrack(vs);
  } catch (e) {
    console.warn('[cam] flip failed', e?.name || e);
  } finally {
    setTimeout(() => root.classList.remove('flipping'), 60);
    switching = false;
  }
}
async function flip() {
  if (!stream || root.dataset.state !== 'live') return;
  if (IS_MOBILE && !camQuery) { flipFacing(); return; }
  const list = videoInputs.length ? videoInputs : await listCameras();
  if (list.length < 2) return;
  const cur = stream.getVideoTracks()[0]?.getSettings?.().deviceId;
  const i = list.findIndex((d) => d.deviceId === cur);
  useDevice(list[(i + 1) % list.length].deviceId);
}
$('flip').addEventListener('click', flip);

// Plugging an iPhone in (or out) mid-session: re-list, and recover if our camera went away.
function watchTrack(track) {
  if (!track) return;
  track.onended = async () => {
    if (root.dataset.state !== 'live' || switching) return;
    const list = await listCameras();
    if (list[0]) useDevice(list[0].deviceId);
  };
}
navigator.mediaDevices?.addEventListener?.('devicechange', () => { listCameras(); });

// ---------------------------------------------------------------- voice
function toggleVoice() {
  state.voice = !state.voice;
  if (ctx) ctx.voice = state.voice;
  if (audioCtx?.state === 'suspended') audioCtx.resume();
  hud.setVoice(state.voice);
  try { engine?.setVoice(state.voice); } catch (e) { console.warn('[cam] setVoice', e); }
  bus.emit('ui:voice', { on: state.voice, source: 'ui' });
}
$('voice').addEventListener('click', toggleVoice);

// ---------------------------------------------------------------- engine pill: tap cycles, long-press = name + debug
{
  const btn = $('engine');
  let timer = 0, long = false;
  btn.addEventListener('pointerdown', () => {
    long = false;
    timer = setTimeout(() => { long = true; hud.showEngineName(2200); hud.setDebug(!hud.debugOn); }, 520);
  });
  const cancel = () => clearTimeout(timer);
  btn.addEventListener('pointerleave', cancel);
  btn.addEventListener('pointercancel', cancel);
  btn.addEventListener('pointerup', cancel);
  btn.addEventListener('click', () => {
    if (long) return;
    if (!ctx) { hud.showEngineName(); return; }
    const i = ORDER.indexOf(state.engine);
    startEngine(ORDER[(i + 1) % ORDER.length]);
  });
  btn.addEventListener('contextmenu', (e) => e.preventDefault());
}

// ---------------------------------------------------------------- mode selector
$('modes-track').addEventListener('click', (e) => {
  const b = e.target.closest('button[data-mode]');
  if (b) applySettings({ mode: b.dataset.mode }, 'ui');
});
function stepMode(d) {
  const i = MODES.indexOf(state.mode);
  const n = clamp(i + d, 0, MODES.length - 1);
  if (n !== i) applySettings({ mode: MODES[n] }, 'ui');
}

// ---------------------------------------------------------------- viewfinder gestures
// tap = focus, vertical drag = exposure, horizontal swipe = mode, pinch = zoom
{
  const canvas = $('vf');
  const pts = new Map();
  let g = null;
  const dist = () => { const [a, b] = [...pts.values()]; return Math.hypot(a.x - b.x, a.y - b.y); };
  canvas.addEventListener('pointerdown', (e) => {
    if (root.dataset.state !== 'live') return;
    try { canvas.setPointerCapture(e.pointerId); } catch { /* synthetic or already released */ }
    pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pts.size === 1) g = { kind: null, x0: e.clientX, y0: e.clientY, t0: performance.now(), ev0: state.exposure };
    else if (pts.size === 2) g = { kind: 'pinch', d0: dist(), z0: state.zoom };
  });
  canvas.addEventListener('pointermove', (e) => {
    if (!pts.has(e.pointerId) || !g) return;
    pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (g.kind === 'pinch' && pts.size === 2) {
      applySettings({ zoom: g.z0 * (dist() / g.d0) }, 'ui', { emit: false });
      g.moved = true;
      return;
    }
    const dx = e.clientX - g.x0, dy = e.clientY - g.y0;
    if (!g.kind && Math.hypot(dx, dy) > 12) g.kind = Math.abs(dy) > Math.abs(dx) ? 'ev' : 'swipe';
    if (g.kind === 'ev') {
      const ev = Math.round(clamp(g.ev0 - dy / 130, -2, 2) * 10) / 10;
      applySettings({ exposure: ev }, 'ui', { emit: false });
      hud.focusSun(ev);
      g.moved = true;
    }
  });
  const end = (e) => {
    if (!pts.has(e.pointerId)) return;
    pts.delete(e.pointerId);
    if (!g || pts.size) return;
    const dx = e.clientX - g.x0;
    if (g.kind === 'pinch') bus.emit('ui:settings', { zoom: state.zoom, source: 'ui' });
    else if (g.kind === 'ev') bus.emit('ui:settings', { exposure: state.exposure, source: 'ui' });
    else if (g.kind === 'swipe' && Math.abs(dx) > 48) stepMode(dx < 0 ? 1 : -1);
    else if (!g.kind && e.type === 'pointerup') {
      const raw = vf.screenToRaw(e.clientX, e.clientY);
      hud.focusAt(e.clientX - root.getBoundingClientRect().left, e.clientY - root.getBoundingClientRect().top, { sun: true });
      hud.focusSun(state.exposure);
      applySettings({ focus: { x: Math.round(raw.x * 1000) / 1000, y: Math.round(raw.y * 1000) / 1000 } }, 'ui');
    }
    g = null;
  };
  canvas.addEventListener('pointerup', end);
  canvas.addEventListener('pointercancel', end);
  canvas.addEventListener('wheel', (e) => {
    if (root.dataset.state !== 'live') return;
    e.preventDefault();
    applySettings({ zoom: state.zoom * Math.exp(-e.deltaY / 600) }, 'ui');
  }, { passive: false });
}

// ---------------------------------------------------------------- keyboard (laptop)
// Space/Enter = shutter, V = voice, F = switch camera, ←/→ = mode, D = debug, Esc = close review
window.addEventListener('keydown', (e) => {
  if (e.target.closest?.('input, textarea') || e.metaKey || e.ctrlKey || e.altKey) return;
  if (root.dataset.state !== 'live') {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); start(); }
    return;
  }
  if (capture.reviewing) return;
  const k = e.key.toLowerCase();
  if (e.key === ' ' || e.key === 'Enter') {
    e.preventDefault();
    capture.shoot('user');
  } else if (e.key === 'ArrowLeft') stepMode(-1);
  else if (e.key === 'ArrowRight') stepMode(1);
  else if (k === 'v') toggleVoice();
  else if (k === 'f') flip();
  else if (k === 'd') hud.setDebug(!hud.debugOn);
});

// ---------------------------------------------------------------- per-frame: mic level
vf.onFrame(() => {
  if (mic) { try { hud.micLevel(mic.level()); } catch { /* engine-owned */ } }
});

window.addEventListener('resize', () => hud.setMode(state.mode, { instant: true }));
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && audioCtx?.state === 'suspended') audioCtx.resume();
});

// handle for QA / console poking
window.__cam = { bus, getState, applySettings, vf, hud, capture, get engine() { return engine; }, startEngine, flip, useDevice, listCameras };
