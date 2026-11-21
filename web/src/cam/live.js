// Coach Cam engine "live" (brains): Gemini Live over WS /api/live (CAM_CONTRACT.md).
//
// Mic PCM16 (16 kHz, ~100 ms chunks) streams continuously as realtimeInput.audio and the raw
// camera frame goes up at 1 fps as realtimeInput.video. The model answers with tool calls
// (-> bus events, each acknowledged with a SILENT toolResponse) and 24 kHz audio (-> player).
// Because the Live model only takes a turn when the user speaks, the engine also sends a short
// "[tick]" text check-in every few seconds while nobody is talking, so the arrows keep updating.
// The server sends setup and rotates the upstream session on goAway; if the browser socket
// drops, the engine reconnects with the last session resumption handle.

import { createPlayer, unlockAudio } from './audio.js';
import { INTENTS, MODES, MOVES, REACTIONS } from './bus.js';

const SOURCE = 'live';
const FRAME_MS = 1000; // Live accepts at most 1 fps
const TICK_MS = 4000;
const SCENE_MS = 8000; // Hydrogen scene check (who to keep in frame, scenery to reveal)
const SETUP_TIMEOUT_MS = 12000;
const STRENGTHS = ['small', 'medium', 'large'];
const FLASH = ['off', 'on', 'auto'];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function i16ToB64(pcm) {
  const bytes = new Uint8Array(pcm.buffer, pcm.byteOffset, pcm.byteLength);
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

function b64ToI16(b64) {
  const s = atob(b64);
  const bytes = new Uint8Array(s.length & ~1);
  for (let i = 0; i < bytes.length; i++) bytes[i] = s.charCodeAt(i);
  return new Int16Array(bytes.buffer);
}

function blobToB64(blob) {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result).split(',')[1] || '');
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });
}

const num = (v, lo, hi) => {
  const n = Number(v);
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : undefined;
};

function cameraSettings(a) {
  const s = {};
  if (MODES.includes(a.mode)) s.mode = a.mode;
  const put = (k, v) => { if (v !== undefined) s[k] = Math.round(v * 1000) / 1000; };
  put('zoom', num(a.zoom, 1, 5));
  put('exposure', num(a.exposure, -2, 2));
  put('warmth', num(a.warmth, -1, 1));
  put('iso', num(a.iso, 25, 12800));
  put('shutter', num(a.shutter, 1 / 8000, 1));
  const fx = num(a.focus_x, 0, 1);
  const fy = num(a.focus_y, 0, 1);
  if (fx !== undefined && fy !== undefined) s.focus = { x: fx, y: fy };
  if (FLASH.includes(a.flash)) s.flash = a.flash;
  return s;
}

export function createEngine(ctx) {
  const { bus, mic } = ctx;
  let voice = !!ctx.voice;
  let running = false;
  let ws = null;
  let ready = false;
  let handle = null;
  let retry = 0;
  let reconnectTimer = 0;
  let player = null;
  let offs = [];
  let startResolve = null;
  let abort = null;
  const frames = []; // last few frames sent, for the scene check [{blob, t}]
  // From the scene check: who must stay fully in frame, the scenery to reveal, selfie or not.
  const scene = { keep: [], scene: '', selfie: false, key: '' };
  let lastHeard = '';

  // turn bookkeeping
  let trigger = 0; // when we last asked for a response (tick sent / user stopped talking)
  let gotTool = false;
  let gotAudio = false;
  let responding = false;
  let lastActivity = 0; // last model output
  let lastTickAt = 0;
  let lastSpeechSeen = 0;
  let userActive = false; // server VAD (voiceActivity) says the user is talking
  let userEndAt = 0; // when the server saw the user's turn end
  let sayText = '';
  let heardText = '';
  let heardTimer = 0;

  const emit = (type, detail = {}) => bus.emit(type, { ...detail, source: SOURCE });
  const state = () => (ctx.getState ? ctx.getState() : {}) || {};
  const send = (obj) => {
    if (ws && ws.readyState === 1 && ready) {
      ws.send(JSON.stringify(obj));
      return true;
    }
    return false;
  };
  // Slow uplink (phone over a tunnel): drop media rather than queue seconds of stale input.
  const congested = (bytes) => !!ws && ws.bufferedAmount > bytes;
  const note = (text) => send({ clientContent: { turns: [{ role: 'user', parts: [{ text }] }], turnComplete: false } });

  function flushHeard() {
    clearTimeout(heardTimer);
    const text = heardText.trim();
    heardText = '';
    if (text) {
      lastHeard = text;
      emit('heard', { text });
    }
  }

  function flushSay() {
    const text = sayText.trim();
    sayText = '';
    if (text) emit('say', { text });
  }

  // Tool responses wait for the end of the model's turn: if the user spoke, voice is on and the
  // model only acted (no speech), answer WHEN_IDLE so it can add a few words; else SILENT.
  let pending = [];
  let pendingTimer = 0;
  let spokeThisTurn = false;
  let triggerKind = 'tick';

  function flushResponses() {
    clearTimeout(pendingTimer);
    if (!pending.length) return;
    const scheduling = voice && triggerKind === 'user' && !spokeThisTurn ? 'WHEN_IDLE' : 'SILENT';
    send({ toolResponse: { functionResponses: pending.map((r) => ({ ...r, scheduling })) } });
    pending = [];
    triggerKind = 'answered';
  }

  function markTrigger(t, kind = 'tick') {
    trigger = t;
    triggerKind = kind;
    spokeThisTurn = false;
    gotTool = false;
    gotAudio = false;
  }

  function sinceTrigger() {
    const ms = Math.round(performance.now() - trigger);
    return trigger && ms < 10000 ? ms : null;
  }

  function onToolCall(tc) {
    const responses = [];
    if (!gotTool) {
      gotTool = true;
      const ms = sinceTrigger();
      if (ms !== null) emit('stats', { name: 'live_tool', ms });
    }
    lastActivity = performance.now();
    flushHeard();
    for (const fc of tc.functionCalls || []) {
      const a = fc.args || {};
      let result = { ok: true };
      switch (fc.name) {
        case 'guide':
          if (MOVES.includes(a.direction)) {
            emit('move', { dir: a.direction, strength: STRENGTHS.includes(a.strength) ? a.strength : 'medium', conf: 0.9 });
          } else result = { ok: false, error: 'unknown direction' };
          break;
        case 'set_camera': {
          const s = cameraSettings(a);
          if (Object.keys(s).length) emit('settings', s);
          result = { ok: true, applied: s };
          break;
        }
        case 'set_intent':
          if (INTENTS.includes(a.intent)) {
            const d = { intent: a.intent, conf: 0.9 };
            if (a.subject) d.subject = String(a.subject).split(/\s+/).slice(0, 4).join(' ');
            emit('intent', d);
          } else result = { ok: false, error: 'unknown intent' };
          break;
        case 'user_reaction':
          if (REACTIONS.includes(a.reaction)) {
            const d = { reaction: a.reaction, conf: 0.9 };
            if (a.heard) d.heard = String(a.heard);
            emit('reaction', d);
          } else result = { ok: false, error: 'unknown reaction' };
          break;
        case 'shot_ready':
          emit('ready', { p: a.ready ? 0.9 : 0.1 });
          break;
        case 'take_photo':
          emit('capture', { reason: String(a.reason || 'you asked') });
          break;
        default:
          result = { ok: false, error: `unknown tool ${fc.name}` };
      }
      responses.push({ id: fc.id, name: fc.name, response: result });
    }
    if (responses.length) {
      pending.push(...responses);
      clearTimeout(pendingTimer);
      pendingTimer = setTimeout(flushResponses, 2500);
    }
  }

  function onContent(sc) {
    const now = performance.now();
    if (sc.inputTranscription && sc.inputTranscription.text) {
      heardText += sc.inputTranscription.text;
      clearTimeout(heardTimer);
      heardTimer = setTimeout(flushHeard, 900);
    }
    const parts = (sc.modelTurn && sc.modelTurn.parts) || [];
    for (const p of parts) {
      const d = p.inlineData;
      if (!d || !d.data || !String(d.mimeType || '').startsWith('audio/pcm')) continue;
      responding = true;
      lastActivity = now;
      flushHeard();
      spokeThisTurn = true;
      if (!gotAudio) {
        gotAudio = true;
        const ms = sinceTrigger();
        if (ms !== null) emit('stats', { name: 'live_first_audio', ms });
      }
      if (voice && player) {
        const m = /rate=(\d+)/.exec(d.mimeType);
        player.push(b64ToI16(d.data), m ? Number(m[1]) : 24000);
      }
    }
    if (sc.outputTranscription && sc.outputTranscription.text) {
      sayText += sc.outputTranscription.text;
      responding = true;
      lastActivity = now;
      flushHeard();
    }
    if (sc.interrupted || sc.turnComplete) flushResponses();
    if (sc.interrupted) {
      if (player) player.flush();
      flushSay();
      responding = false;
    }
    if (sc.generationComplete || sc.turnComplete) flushSay();
    if (sc.turnComplete) {
      responding = false;
      userActive = false;
      lastActivity = now;
    }
  }

  function onMessage(data, t0) {
    let m;
    try {
      m = JSON.parse(data);
    } catch {
      return;
    }
    if (m.setupComplete) {
      ready = true;
      retry = 0;
      responding = false;
      userActive = false;
      emit('status', { state: 'live' });
      emit('stats', { name: 'live_connect', ms: Math.round(performance.now() - t0) });
      lastTickAt = performance.now() - TICK_MS + 1500; // first check-in shortly after the first frame
      if (startResolve) { startResolve(); startResolve = null; }
      return;
    }
    if (m.error) {
      emit('status', { state: 'error', detail: String(m.error) });
      return;
    }
    const upd = m.sessionResumptionUpdate;
    if (upd && upd.resumable && upd.newHandle) handle = upd.newHandle;
    if (m.goAway) emit('status', { state: 'live', detail: 'session rotating' });
    if (m.sessionRotated) emit('status', { state: 'live', detail: m.sessionRotated.resumed ? 'session resumed' : 'new session' });
    const va = m.voiceActivity;
    if (va && va.type === 'ACTIVITY_START') userActive = true;
    if (va && va.type === 'ACTIVITY_END') {
      userActive = false;
      userEndAt = performance.now();
      if (triggerKind !== 'user') markTrigger(userEndAt, 'user'); // no client VAD end seen
    }
    const cancelled = m.toolCallCancellation && m.toolCallCancellation.ids;
    if (cancelled) pending = pending.filter((r) => !cancelled.includes(r.id));
    if (m.toolCall) onToolCall(m.toolCall);
    if (m.serverContent) onContent(m.serverContent);
  }

  function connect() {
    if (!running) return;
    clearTimeout(reconnectTimer);
    emit('status', { state: 'connecting', detail: retry ? 'reconnecting' : undefined });
    const t0 = performance.now();
    ready = false;
    const q = new URLSearchParams({ voice: voice ? '1' : '0', facing: state().facing === 'user' ? 'user' : 'environment' });
    if (handle) q.set('resume', handle);
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    let sock;
    try {
      sock = new WebSocket(`${proto}//${location.host}/api/live?${q}`);
    } catch (e) {
      emit('status', { state: 'error', detail: String(e.message || e) });
      return;
    }
    ws = sock;
    setTimeout(() => { if (ws === sock && !ready) try { sock.close(4000, 'setup timeout'); } catch { /* ignore */ } }, SETUP_TIMEOUT_MS);
    sock.onmessage = (e) => { if (ws === sock && typeof e.data === 'string') onMessage(e.data, t0); };
    sock.onerror = () => {};
    sock.onclose = (e) => {
      if (ws !== sock) return;
      ws = null;
      ready = false;
      responding = false;
      clearTimeout(pendingTimer);
      pending = [];
      flushSay();
      flushHeard();
      if (player) player.flush();
      if (!running) return;
      if (e.code === 4401) {
        emit('status', { state: 'error', detail: 'coach token missing or wrong' });
        running = false;
        if (startResolve) { startResolve(); startResolve = null; }
        return;
      }
      const delay = Math.min(10000, 800 * 2 ** retry);
      retry += 1;
      if (retry > 3) handle = null; // resumption keeps failing: start fresh
      emit('status', { state: retry > 3 ? 'error' : 'connecting', detail: `connection lost (${e.code}), retrying in ${(delay / 1000).toFixed(1)} s` });
      reconnectTimer = setTimeout(connect, delay);
    };
  }

  async function frameLoop() {
    while (running) {
      const t = performance.now();
      if (ready && document.visibilityState !== 'hidden' && !congested(128 * 1024)) {
        try {
          const blob = await ctx.grabFrame(768, 0.7);
          if (blob && ready) {
            send({ realtimeInput: { video: { data: await blobToB64(blob), mimeType: 'image/jpeg' } } });
            frames.push({ blob, t: performance.now() });
            if (frames.length > 3) frames.shift();
          }
        } catch (e) {
          console.warn('live: frame grab failed', e);
        }
      }
      await sleep(Math.max(100, FRAME_MS - (performance.now() - t)));
    }
  }

  function tickText() {
    const st = state();
    const bits = [`mode ${st.mode || 'photo'}`, `zoom ${Number(st.zoom || 1).toFixed(1)}x`, `exposure ${Number(st.exposure || 0).toFixed(1)} EV`];
    if (st.intent) bits.push(`intent ${st.intent}${st.subject ? ` (${st.subject})` : ''}`);
    let text = `[tick] ${bits.join(', ')}.`;
    if (scene.key) {
      const goal = [];
      if (scene.selfie) goal.push('selfie (arm moves)');
      if (scene.keep.length) goal.push(`keep all ${scene.keep.length} in frame`);
      if (scene.scene) goal.push(`reveal ${scene.scene}`);
      if (goal.length) text += ` Goal: ${goal.join('; ')}.`;
    }
    return text;
  }

  function sceneNote() {
    const parts = [];
    if (scene.selfie) parts.push('This is a selfie: guide with arm moves.');
    parts.push(scene.keep.length ? `Keep fully in frame, no cropped heads or faces: ${scene.keep.join('; ')}.` : 'No people to keep in frame.');
    parts.push(scene.scene ? `Scenery to show more of behind them: ${scene.scene}.` : 'No special scenery.');
    return `[scene] ${parts.join(' ')}`;
  }

  // Background Hydrogen call (the decide engine's /api/cam/understand) so the arrows aim at
  // "everyone in + scene revealed". Tells the Live session only when the picture changes.
  async function sceneLoop() {
    let next = performance.now() + 1500;
    while (running) {
      await sleep(250);
      if (!running || !ready || performance.now() < next || !frames.length) continue;
      next = performance.now() + SCENE_MS;
      try {
        const latest = frames[frames.length - 1];
        const older = frames.find((f) => latest.t - f.t >= 800);
        const fd = new FormData();
        if (older) fd.append('frames', older.blob, 'f0.jpg');
        fd.append('frames', latest.blob, 'f1.jpg');
        const st = state();
        fd.append('state', JSON.stringify({
          facing: st.facing, mode: st.mode, zoom: st.zoom, exposure: st.exposure, intent: st.intent,
          subject: st.subject, heard: lastHeard, selfie: scene.selfie, keep: scene.keep, scene: scene.scene,
        }));
        const t = performance.now();
        const r = await fetch('/api/cam/understand', { method: 'POST', body: fd, signal: abort.signal });
        if (!r.ok) throw new Error(`understand HTTP ${r.status}`);
        const j = await r.json();
        if (!running) break;
        emit('stats', { name: 'understand', ms: Math.round(performance.now() - t) });
        scene.keep = Array.isArray(j.keep) ? j.keep.slice(0, 8) : scene.keep;
        scene.scene = typeof j.scene === 'string' ? j.scene : scene.scene;
        scene.selfie = !!j.selfie;
        const norm = (x) => String(x || '').toLowerCase().replace(/[^a-z ]/g, '').split(/\s+/).slice(0, 3).join(' ');
        const key = `${scene.selfie}|${scene.keep.length}|${norm(scene.scene)}`;
        if (key !== scene.key && note(sceneNote())) scene.key = key;
      } catch (e) {
        if (e.name !== 'AbortError') console.warn('live: scene check failed', e);
      }
    }
  }

  async function tickLoop() {
    while (running) {
      await sleep(250);
      if (!ready) continue;
      const now = performance.now();
      if (mic && mic.lastSpeechEndedAt > lastSpeechSeen) {
        lastSpeechSeen = mic.lastSpeechEndedAt;
        markTrigger(lastSpeechSeen, 'user'); // latency is measured from the end of the user's speech
      }
      if (responding && now - lastActivity > 10000) responding = false; // lost turnComplete
      const quiet = !userActive && !(mic && mic.speaking()) && !(player && player.playing()) && !responding;
      const userEnd = Math.max(userEndAt, (mic && mic.lastSpeechEndedAt) || 0);
      // The model sometimes stays silent after the user talks (proactive audio): nudge it.
      const unanswered = userEndAt > lastActivity && userEndAt > lastTickAt && now - userEndAt >= 1200;
      const routine = now - lastTickAt >= TICK_MS && now - userEnd >= 2000 && now - lastActivity > 1500;
      if (quiet && (unanswered || routine)) {
        if (send({ realtimeInput: { text: tickText() } })) {
          lastTickAt = now;
          markTrigger(now);
        }
      }
    }
  }

  function setVoice(on) {
    on = !!on;
    if (on === voice) return;
    voice = on;
    if (player) player.muted = !on;
    note(on
      ? '[app] Voice is now ON: the user hears you again. Keep it brief, at most 8 words.'
      : '[app] Voice is now OFF: the user only sees captions. Say at most a word or two, or nothing.');
  }

  return {
    async start() {
      if (running) return;
      running = true;
      unlockAudio(); // a no-op outside a user gesture; the UI's start tap makes iOS audio work
      abort = new AbortController();
      if (!player) {
        player = createPlayer();
        player.onPlaying((on) => emit('speaking', { on }));
      }
      player.muted = !voice;
      offs = [
        bus.on('ui:voice', (d) => setVoice(d && d.on)),
        bus.on('ui:captured', () => note('[app] The user just took the photo.')),
      ];
      if (mic) {
        const off = mic.onChunk((pcm) => {
          if (ready && !congested(512 * 1024)) send({ realtimeInput: { audio: { data: i16ToB64(pcm), mimeType: 'audio/pcm;rate=16000' } } });
        });
        if (typeof off === 'function') offs.push(off);
      }
      const started = new Promise((resolve) => { startResolve = resolve; });
      connect();
      frameLoop();
      sceneLoop();
      tickLoop();
      await Promise.race([started, sleep(10000)]);
    },
    stop() {
      running = false;
      if (abort) abort.abort();
      clearTimeout(reconnectTimer);
      clearTimeout(heardTimer);
      clearTimeout(pendingTimer);
      pending = [];
      for (const off of offs) off();
      offs = [];
      const sock = ws;
      ws = null;
      ready = false;
      if (sock) try { sock.close(1000); } catch { /* ignore */ }
      if (player) player.flush();
      flushSay();
      emit('status', { state: 'idle' });
    },
    setVoice,
  };
}
