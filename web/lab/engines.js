// Dev-only engine lab: camera + mic + one engine + a bus, logging every bus event.
import { createBus } from '../src/cam/bus.js';
import { createMic, unlockAudio } from '../src/cam/audio.js';

const ENGINES = {
  live: () => import('../src/cam/live.js'),
  decide: () => import('../src/cam/decide.js'),
};
const EVENTS = ['move', 'settings', 'intent', 'reaction', 'ready', 'say', 'heard', 'capture', 'speaking',
  'status', 'stats', 'ui:captured', 'ui:settings', 'ui:voice'];

const params = new URLSearchParams(location.search);
const engineName = ENGINES[params.get('engine')] ? params.get('engine') : 'decide';
const facing = params.get('facing') === 'user' ? 'user' : 'environment';
let voice = params.get('voice') !== '0';

const $ = (id) => document.getElementById(id);
const video = $('video');
const logEl = $('log');
const t0 = performance.now();
const events = [];
window.__events = events;

function line(type, detail) {
  const t = (performance.now() - t0) / 1000;
  const d = { ...detail };
  if (d.blob instanceof Blob) d.blob = `Blob(${d.blob.size} B)`;
  events.push({ t: Math.round(t * 100) / 100, type, detail: d });
  const s = `${t.toFixed(2).padStart(7)}s ${type.padEnd(11)} ${JSON.stringify(d)}`;
  console.log(`[bus] ${s}`);
  logEl.textContent += `${s}\n`;
  logEl.scrollTop = logEl.scrollHeight;
}

const bus = createBus();
for (const e of EVENTS) bus.on(e, (d) => line(e, d));

// CamState, updated from engine events the way the real UI would.
const state = {
  facing, mirrored: false, mode: 'photo', zoom: 1, exposure: 0, warmth: 0, iso: null, shutter: null,
  focus: null, flash: 'off', intent: null, subject: null, voice, engine: engineName,
  caps: { zoom: false, exposure: false, iso: false, shutter: false, focus: false, wb: false, torch: false },
};
bus.on('settings', (s) => {
  for (const k of ['mode', 'zoom', 'exposure', 'warmth', 'iso', 'shutter', 'focus', 'flash']) if (s[k] !== undefined) state[k] = s[k];
});
bus.on('intent', (d) => { state.intent = d.intent; if (d.subject) state.subject = d.subject; });
bus.on('capture', async () => {
  const blob = await grabFrame(1600, 0.9);
  if (blob) bus.emit('ui:captured', { blob, source: 'ui' });
});

const canvas = document.createElement('canvas');
function grabFrame(maxSide = 768, quality = 0.7) {
  const w = video.videoWidth;
  const h = video.videoHeight;
  if (!w || !h) return Promise.resolve(null);
  const s = Math.min(1, maxSide / Math.max(w, h));
  canvas.width = Math.round(w * s);
  canvas.height = Math.round(h * s);
  canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);
  return new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', quality));
}

let stream = null;
let mic = null;
let engine = null;
let meterTimer = 0;

async function start() {
  if (engine) return;
  $('start').disabled = true;
  unlockAudio();
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: facing, width: { ideal: 1280 }, height: { ideal: 720 } },
      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });
  } catch (e) {
    line('lab', { error: `getUserMedia: ${e.message}` });
    $('start').disabled = false;
    return;
  }
  video.srcObject = stream;
  await video.play().catch(() => {});
  try {
    mic = await createMic(stream);
  } catch (e) {
    line('lab', { error: `mic: ${e.message}` });
  }
  const mod = await ENGINES[engineName]();
  engine = mod.createEngine({ bus, mic, grabFrame, getState: () => ({ ...state, voice }), voice });
  $('stop').disabled = false;
  meterTimer = setInterval(() => {
    if (!mic) return;
    $('level').value = mic.level();
    $('vad').textContent = mic.speaking() ? 'speaking' : '';
  }, 100);
  line('lab', { started: engineName, voice, facing, video: `${video.videoWidth}x${video.videoHeight}`, mic: !!mic });
  await engine.start();
  const stopAfter = Number(params.get('stopAfter'));
  if (stopAfter > 0) setTimeout(stop, stopAfter * 1000);
}

function stop() {
  if (!engine) return;
  engine.stop();
  engine = null;
  clearInterval(meterTimer);
  if (mic) mic.close();
  mic = null;
  if (stream) for (const t of stream.getTracks()) t.stop();
  stream = null;
  $('stop').disabled = true;
  $('start').disabled = false;
  line('lab', { stopped: true });
}

function toggleVoice() {
  voice = !voice;
  state.voice = voice;
  $('voice').textContent = `Voice: ${voice ? 'on' : 'off'}`;
  if (engine) engine.setVoice(voice);
  bus.emit('ui:voice', { on: voice, source: 'ui' });
}

$('voice').textContent = `Voice: ${voice ? 'on' : 'off'}`;
$('info').textContent = `engine=${engineName} facing=${facing}`;
$('start').onclick = start;
$('stop').onclick = stop;
$('voice').onclick = toggleVoice;
window.__lab = { start, stop, toggleVoice, state, bus };
if (params.get('auto') === '1') start();
