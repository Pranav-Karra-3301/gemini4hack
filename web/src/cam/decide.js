// Coach Cam engine "decide" (brains): Decision 1 fast loop + Hydrogen slow loop + TTS
// (CAM_CONTRACT.md).
//
// Fast loop (~1/s, one request in flight): raw frame (+ the last 4 s of mic audio when the user
// spoke recently) -> POST /api/cam/decide -> smoothed move / ready / mode / exposure / intent /
// reaction events.
// Slow loop: POST /api/cam/understand every ~5 s, and right after the user stops talking (2 frames
// ~1 s apart + the utterance WAV) -> intent, heard, reaction, settings and a spoken tip. Its
// heard / wants / intent feed the next decide `state`.
// Voice: tips go through POST /api/cam/say -> player.playWav (speechSynthesis if TTS fails).

import { createPlayer, unlockAudio } from './audio.js';
import { INTENTS, MODES, MOVES, REACTIONS } from './bus.js';

const SOURCE = 'decide';
const FAST_MS = 1000;
const SLOW_MS = 5000;
const SPEECH_WINDOW_MS = 4000; // attach audio to decide if the user spoke this recently
const ALPHA = 0.6; // EMA weight of the newest tick
const MOVE_MIN = 0.45;
const READY_HOLD = 0.7;
const MODE_MIN = 0.7;
const MODE_GAP_MS = 4000;
const EXPOSURE_MIN = 0.6;
const EXPOSURE_STEP = 0.3;
const EXPOSURE_GAP_MS = 2000;
const AUTO_EXPOSURE_LIMIT = 1.0; // open-loop limit when the frame doesn't show our exposure
const USER_OVERRIDE_MS = 15000; // don't fight a setting the user just changed by hand
const SPEAK_GAP_MS = 6000;
const MOVE_REFRESH_MS = 3000;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const r2 = (v) => Math.round(v * 100) / 100;
const norm = (s) => String(s || '').toLowerCase().replace(/[^a-z0-9 ]/g, '').trim();
function similar(a, b) {
  const wa = new Set(norm(a).split(/\s+/).filter(Boolean));
  const wb = new Set(norm(b).split(/\s+/).filter(Boolean));
  if (!wa.size || !wb.size) return false;
  let both = 0;
  for (const w of wa) if (wb.has(w)) both += 1;
  return both / Math.min(wa.size, wb.size) >= 0.75;
}

function argmax(probs) {
  let best = null;
  let p = -1;
  for (const [k, v] of Object.entries(probs || {})) if (v > p) { best = k; p = v; }
  return [best, p];
}

export function createEngine(ctx) {
  const { bus, mic } = ctx;
  let voice = !!ctx.voice;
  let running = false;
  let abort = null;
  let player = null;
  let offs = [];
  let live = false;

  // What the slow loop learned; fed back into decide's state.
  const mem = { heard: '', history: [], pinnedUntil: 0, keep: [], scene: '', selfie: false, wants: '', intent: null, subject: null, intentAt: -Infinity, lastTip: '', reaction: null, reactionAt: -Infinity };
  const frames = []; // recent fast-loop frames [{blob, t}]
  const ema = {};
  const touched = {}; // setting -> performance.now() of the last manual change
  let prevTopMove = null;
  let lastMove = null;
  let lastMoveAt = -Infinity;
  let modeChoice = null;
  let modeStreak = 0;
  let lastModeAt = -Infinity;
  let intentChoice = null;
  let intentStreak = 0;
  let lastIntentSent = null;
  let lastDecideIntentAt = -Infinity;
  let lastExposureAt = -Infinity;
  let autoExposure = 0;
  let utter = { id: 0, reacted: false };
  let wasSpeaking = false;
  let phraseStart = 0; // start of the current phrase (utterances < 1.5 s apart are one phrase)
  let unheardSince = 0; // start of the earliest speech not yet sent to understand
  let understandStartedAt = 0;
  let inflightFrom = 0; // audio start of the speech-understand in flight
  let lastUtteranceStart = 0;
  let lastReaction = { reaction: null, at: 0 };
  let understandAbort = null;
  let understandFromSpeech = false;
  let speechEndPending = false;
  let understandBusy = false;
  let lastUnderstandAt = 0;
  let lastSayText = '';
  let lastSayAt = -Infinity;
  let lastSpokeAt = -Infinity;
  let fails = 0;

  const emit = (type, detail = {}) => bus.emit(type, { ...detail, source: SOURCE });
  const camState = () => (ctx.getState ? ctx.getState() : {}) || {};

  function smooth(name, probs) {
    if (!probs) return ema[name] || null;
    const prev = ema[name];
    const out = {};
    for (const [k, v] of Object.entries(probs)) out[k] = prev && prev[k] !== undefined ? ALPHA * v + (1 - ALPHA) * prev[k] : v;
    ema[name] = out;
    return out;
  }

  function smoothScalar(name, v) {
    if (typeof v !== 'number') return ema[name] ?? null;
    ema[name] = ema[name] === undefined ? v : ALPHA * v + (1 - ALPHA) * ema[name];
    return ema[name];
  }

  function serverState() {
    const st = camState();
    return {
      facing: st.facing, mirrored: st.mirrored, mode: st.mode, zoom: st.zoom, exposure: st.exposure,
      warmth: st.warmth, iso: st.iso, shutter: st.shutter, flash: st.flash, voice: st.voice ?? voice,
      caps: st.caps, intent: mem.intent || st.intent || null, subject: mem.subject || st.subject || null,
      selfie: mem.selfie, keep: mem.keep, scene: mem.scene, // aim: everyone in + scene revealed
      heard: mem.heard, heard_before: mem.history.slice(0, -1).join(' / '), wants: mem.wants, last_tip: mem.lastTip,
      reaction: performance.now() - mem.reactionAt < 20000 ? mem.reaction : null,
    };
  }

  async function post(url, body, json, signal) {
    const opts = { method: 'POST', body, signal: signal || abort.signal };
    if (json) {
      opts.body = JSON.stringify(body);
      opts.headers = { 'content-type': 'application/json' };
    }
    const r = await fetch(url, opts);
    if (!r.ok) {
      let msg = `HTTP ${r.status}`;
      try { msg += `: ${(await r.json()).error}`; } catch { /* not json */ }
      throw new Error(msg);
    }
    return r;
  }

  // ---- speech -------------------------------------------------------------------------------

  let sayGen = 0;
  async function speak(text) {
    const gen = ++sayGen;
    lastSpokeAt = performance.now();
    try {
      const t = performance.now();
      const r = await post('/api/cam/say', { text }, true);
      const blob = await r.blob();
      emit('stats', { name: 'say', ms: Math.round(performance.now() - t) });
      // Don't talk over the user: wait up to 4 s for a pause; a newer tip replaces this one.
      const until = performance.now() + 4000;
      while (running && gen === sayGen && mic && mic.speaking() && performance.now() < until) await sleep(150);
      if (!voice || !running || gen !== sayGen || (mic && mic.speaking())) {
        if (gen === sayGen) lastSpokeAt = -Infinity;
        return;
      }
      await player.playWav(blob);
    } catch (e) {
      if (e.name === 'AbortError' || !voice || !running) return;
      console.warn('decide: TTS failed, using speechSynthesis', e);
      try {
        const u = new SpeechSynthesisUtterance(text);
        u.onstart = () => emit('speaking', { on: true });
        u.onend = () => emit('speaking', { on: false });
        window.speechSynthesis.speak(u);
      } catch { /* no speech synthesis */ }
    }
  }

  // Caption every new tip; speak it when voice is on, at most once per SPEAK_GAP_MS.
  function say(text, { force = false } = {}) {
    if (!text) return;
    const now = performance.now();
    if (similar(text, lastSayText) && now - lastSayAt < 20000) return; // repeat or near-repeat
    lastSayText = text;
    lastSayAt = now;
    emit('say', { text });
    const gap = now - lastSpokeAt;
    if (voice && (gap >= SPEAK_GAP_MS || (force && gap >= 2500)) && !(player && player.playing())) speak(text);
  }

  // ---- fast loop ------------------------------------------------------------------------------

  function emitSettings(s) {
    if (Object.keys(s).length) emit('settings', s);
  }

  function onReaction(reaction, conf, heard) {
    if (utter.reacted || reaction === 'neutral') return;
    utter.reacted = true;
    const now = performance.now();
    if (reaction === lastReaction.reaction && now - lastReaction.at < 5000) return; // one phrase split in two
    lastReaction = { reaction, at: now };
    mem.reaction = reaction;
    mem.reactionAt = performance.now();
    const d = { reaction, conf: r2(conf) };
    if (heard) d.heard = heard;
    emit('reaction', d);
    if (reaction === 'pleased') {
      ema.ready = Math.max(ema.ready ?? 0, 0.85);
      lastMove = 'hold';
      lastMoveAt = performance.now();
      emit('move', { dir: 'hold', strength: 'small', conf: r2(conf) });
      emit('ready', { p: r2(ema.ready) });
      say('Hold it there.', { force: true });
    } else if (reaction === 'disappointed') {
      // Drop the old plan: forget smoothed moves so the next ticks start fresh, and let the slow
      // loop (which sees reaction = disappointed) propose something different.
      delete ema.move;
      prevTopMove = null;
      lastMove = null;
      lastUnderstandAt = 0;
    }
  }

  function apply(a, utteranceDone) {
    const now = performance.now();
    const st = camState();

    // ready + move
    const ready = smoothScalar('ready', a.ready && a.ready.noul);
    if (ready !== null) emit('ready', { p: r2(ready) });
    const mv = smooth('move', a.move && a.move.probabilities);
    if (mv) {
      const [top, p] = argmax(mv);
      const stable = top === prevTopMove;
      prevTopMove = top;
      let dir = null;
      let conf = p;
      if (ready !== null && ready >= READY_HOLD) {
        dir = 'hold';
        conf = ready;
      } else if (p >= MOVE_MIN && stable && MOVES.includes(top)) {
        dir = top;
      }
      if (dir && (dir !== lastMove || now - lastMoveAt >= MOVE_REFRESH_MS)) {
        const strength = dir === 'hold' ? 'small' : ready !== null && ready >= 0.45 ? 'small' : p >= 0.7 && (ready ?? 0) < 0.2 ? 'large' : 'medium';
        emit('move', { dir, strength, conf: r2(conf) });
        lastMove = dir;
        lastMoveAt = now;
      }
    }

    // mode: >= 0.7 confidence, same answer 2 ticks running, at most every 4 s
    if (a.mode && MODES.includes(a.mode.choice)) {
      modeStreak = a.mode.choice === modeChoice ? modeStreak + 1 : 1;
      modeChoice = a.mode.choice;
      const pinned = now < mem.pinnedUntil && modeChoice !== 'night'; // the user's stated goal wins
      if (a.mode.confidence >= MODE_MIN && modeStreak >= 2 && modeChoice !== st.mode && !pinned
          && now - lastModeAt >= MODE_GAP_MS && now - (touched.mode ?? -Infinity) >= USER_OVERRIDE_MS) {
        lastModeAt = now;
        emitSettings({ mode: modeChoice });
      }
    }

    // exposure: nudge +-0.3 EV when the smoothed answer is >= 0.6
    const ex = smooth('exposure', a.exposure && a.exposure.probabilities);
    if (ex && now - lastExposureAt >= EXPOSURE_GAP_MS && now - (touched.exposure ?? -Infinity) >= USER_OVERRIDE_MS) {
      const cur = Number(st.exposure) || 0;
      const openLoop = !(st.caps && st.caps.exposure);
      let step = 0;
      if ((ex.brighter || 0) >= EXPOSURE_MIN) step = EXPOSURE_STEP;
      else if ((ex.darker || 0) >= EXPOSURE_MIN) step = -EXPOSURE_STEP;
      if (step && openLoop && Math.abs(autoExposure + step) > AUTO_EXPOSURE_LIMIT + 1e-6) step = 0;
      const next = Math.max(-2, Math.min(2, Math.round((cur + step) * 10) / 10));
      if (step && next !== cur) {
        autoExposure += step;
        lastExposureAt = now;
        delete ema.exposure; // judge the next frames fresh
        emitSettings({ exposure: next });
      }
    }

    // intent: decide is a fallback; the slow loop (which hears the user) wins for 12 s
    if (a.intent && INTENTS.includes(a.intent.choice)) {
      intentStreak = a.intent.choice === intentChoice ? intentStreak + 1 : 1;
      intentChoice = a.intent.choice;
      if (a.intent.confidence >= 0.75 && intentStreak >= 3 && intentChoice !== lastIntentSent && now >= mem.pinnedUntil
          && now - lastDecideIntentAt >= 8000
          && intentChoice !== 'other' && now - mem.intentAt >= 12000) {
        lastIntentSent = intentChoice;
        lastDecideIntentAt = now;
        if (!mem.intent || now - mem.intentAt >= 12000) mem.intent = intentChoice;
        emit('intent', { intent: intentChoice, conf: r2(a.intent.confidence) });
      }
    }

    // reaction: only on a finished utterance (partial clips are unreliable); once per utterance
    if (utteranceDone && a.reaction && REACTIONS.includes(a.reaction.choice) && a.reaction.confidence >= 0.7) {
      onReaction(a.reaction.choice, a.reaction.confidence);
    }
  }

  async function decideOnce() {
    const blob = await ctx.grabFrame(768, 0.7);
    if (!blob || !running) return false;
    frames.push({ blob, t: performance.now() });
    if (frames.length > 4) frames.shift();
    const fd = new FormData();
    fd.append('frame', blob, 'frame.jpg');
    const now = performance.now();
    const spoke = mic && (mic.speaking() || (mic.lastSpeechEndedAt && now - mic.lastSpeechEndedAt < SPEECH_WINDOW_MS));
    let withAudio = false;
    const utteranceDone = !mic || !mic.speaking();
    if (spoke && phraseStart) {
      const wav = mic.recentWav(Math.min(4, Math.max(0.8, (now - phraseStart) / 1000 + 0.3)));
      if (wav) {
        fd.append('audio', wav, 'voice.wav');
        withAudio = true;
      }
    }
    fd.append('state', JSON.stringify(serverState()));
    const t = performance.now();
    const r = await post('/api/cam/decide', fd);
    const j = await r.json();
    if (!running) return false;
    emit('stats', { name: 'decide', ms: Math.round(performance.now() - t) });
    if (!live) {
      live = true;
      emit('status', { state: 'live' });
    }
    apply(j.answers || {}, withAudio && utteranceDone);
    return true;
  }

  async function fastLoop() {
    while (running) {
      const t = performance.now();
      try {
        await decideOnce();
        if (fails >= 3) emit('status', { state: 'live' });
        fails = 0;
      } catch (e) {
        if (!running || e.name === 'AbortError') break;
        fails += 1;
        console.warn('decide failed', e);
        if (fails === 3) emit('status', { state: 'error', detail: String(e.message || e) });
      }
      const backoff = fails ? Math.min(8000, 500 * 2 ** fails) : 0;
      await sleep(Math.max(100, FAST_MS - (performance.now() - t)) + backoff);
    }
  }

  // ---- slow loop ------------------------------------------------------------------------------

  async function understand(fromSpeech) {
    understandBusy = true;
    understandFromSpeech = fromSpeech;
    understandStartedAt = performance.now();
    const ctl = new AbortController();
    understandAbort = ctl;
    const onStop = () => ctl.abort();
    abort.signal.addEventListener('abort', onStop);
    lastUnderstandAt = performance.now();
    const uttId = utter.id;
    let sentFrom = 0;
    try {
      const fd = new FormData();
      const latest = frames[frames.length - 1];
      if (!latest) return;
      const older = [...frames].reverse().find((f) => latest.t - f.t >= 800);
      if (older) fd.append('frames', older.blob, 'f0.jpg');
      fd.append('frames', latest.blob, 'f1.jpg');
      let withAudio = false;
      if (fromSpeech && mic) {
        const earliest = Math.min(unheardSince || Infinity, phraseStart || Infinity);
        sentFrom = Number.isFinite(earliest) ? earliest : mic.speechStartedAt || mic.lastSpeechEndedAt - 3000;
        unheardSince = 0;
        inflightFrom = sentFrom;
        const wav = mic.recentWav(Math.min(10, Math.max(1.5, (performance.now() - sentFrom) / 1000 + 0.3)));
        if (wav) {
          fd.append('audio', wav, 'utterance.wav');
          withAudio = true;
        }
      }
      fd.append('state', JSON.stringify(serverState()));
      if (withAudio) emit('status', { state: 'thinking' });
      const t = performance.now();
      const r = await post('/api/cam/understand', fd, false, ctl.signal);
      const j = await r.json();
      if (!running || ctl.signal.aborted) return;
      emit('stats', { name: 'understand', ms: Math.round(performance.now() - t) });
      if (withAudio) emit('status', { state: 'live' });
      onUnderstand(j, withAudio, uttId);
    } catch (e) {
      // A failed request's speech goes out again next time (a superseded one was already restored).
      if (sentFrom && e.name !== 'AbortError') unheardSince = Math.min(unheardSince || Infinity, sentFrom);
      if (e.name !== 'AbortError') {
        console.warn('understand failed', e);
        if (running) emit('status', { state: live ? 'live' : 'connecting' });
      }
    } finally {
      abort.signal.removeEventListener('abort', onStop);
      if (understandAbort === ctl) {
        inflightFrom = 0;
        understandBusy = false;
        understandAbort = null;
        lastUnderstandAt = performance.now();
      }
    }
  }

  function onUnderstand(j, withAudio, uttId) {
    const now = performance.now();
    const st = camState();
    if (withAudio && j.heard) {
      mem.heard = j.heard;
      mem.history = [...mem.history, j.heard].slice(-3);
      emit('heard', { text: j.heard });
    }
    if (j.wants) mem.wants = j.wants;
    if (Array.isArray(j.keep)) mem.keep = j.keep.slice(0, 8);
    if (typeof j.scene === 'string') mem.scene = j.scene;
    if (typeof j.selfie === 'boolean') mem.selfie = j.selfie;
    // A neutral utterance with real words is the user stating a goal: pin its intent for 60 s so
    // the scene (e.g. a group behind "a portrait of my friend") doesn't flip it back.
    const statedGoal = withAudio && j.reaction === 'neutral' && String(j.heard || '').split(/\s+/).length >= 3;
    if (statedGoal) mem.pinnedUntil = now + 60000;
    const pinned = !statedGoal && now < mem.pinnedUntil && mem.intent && j.intent !== mem.intent;
    if (INTENTS.includes(j.intent) && (j.intent !== 'other' || !mem.intent) && !pinned) {
      const changed = j.intent !== mem.intent || (j.subject && j.subject !== mem.subject);
      mem.intent = j.intent;
      mem.subject = j.subject || mem.subject;
      mem.intentAt = now;
      if (changed) {
        lastIntentSent = j.intent;
        const d = { intent: j.intent, conf: 0.8 };
        if (j.subject) d.subject = j.subject;
        emit('intent', d);
      }
    }
    if (withAudio && REACTIONS.includes(j.reaction)) {
      if (uttId === utter.id) onReaction(j.reaction, 0.8, j.heard || undefined);
      else if (j.reaction !== 'neutral') { mem.reaction = j.reaction; mem.reactionAt = now; }
    }
    // settings: only real changes, and never against a recent manual change
    const s = {};
    const set = j.settings || {};
    const free = (k) => now - (touched[k] ?? -Infinity) >= USER_OVERRIDE_MS;
    const modeOk = statedGoal || now >= mem.pinnedUntil || set.mode === 'night' || !pinned;
    if (MODES.includes(set.mode) && set.mode !== st.mode && free('mode') && modeOk && now - lastModeAt >= MODE_GAP_MS) {
      s.mode = set.mode;
      lastModeAt = now;
    }
    if (typeof set.zoom === 'number' && Math.abs(set.zoom - (st.zoom || 1)) >= 0.2 && free('zoom')) s.zoom = set.zoom;
    if (typeof set.exposure === 'number' && Math.abs(set.exposure - (st.exposure || 0)) >= 0.2 && free('exposure')) {
      s.exposure = set.exposure;
      lastExposureAt = now;
    }
    if (typeof set.warmth === 'number' && Math.abs(set.warmth - (st.warmth || 0)) >= 0.15 && free('warmth')) s.warmth = set.warmth;
    emitSettings(s);
    // A "hold it there" tip while the arrows say the frame still needs work (someone cut off)
    // would contradict the HUD; allow it only when ready is decent or the user just said yes.
    const holdTip = /\b(hold (it|still|there|steady)|perfect|looks? (good|great)|that's (lovely|great|good)|fits nicely)\b/i.test(j.tip || '');
    const userPleased = lastReaction.reaction === 'pleased' && now - lastReaction.at < 10000;
    if (holdTip && (ema.ready ?? 1) < 0.4 && !userPleased) j.tip = '';
    if (j.tip && norm(j.tip) !== norm(mem.lastTip)) {
      mem.lastTip = j.tip;
      say(j.tip, { force: withAudio });
    }
  }

  async function slowLoop() {
    while (running) {
      await sleep(150);
      if (!running) break;
      const now = performance.now();
      const speaking = !!(mic && mic.speaking());
      if (speaking && !wasSpeaking) {
        utter = { id: utter.id + 1, reacted: false };
        const start = mic.speechStartedAt || now;
        lastUtteranceStart = now; // when we saw it (speechStartedAt is backdated ~200 ms)
        if (!phraseStart || now - mic.lastSpeechEndedAt > 1500) phraseStart = start;
        if (!unheardSince) unheardSince = start;
      }
      if (!speaking && wasSpeaking) speechEndPending = true; // speaking() drops ~450 ms after the voice stops
      wasSpeaking = speaking;
      if (!speaking && phraseStart && mic && now - mic.lastSpeechEndedAt > SPEECH_WINDOW_MS) phraseStart = 0;
      if (!frames.length) continue;
      if (speechEndPending) {
        if (speaking) continue; // they started again: wait for the end of the whole thing
        // The user's words beat a routine check. A request that went out just before the user
        // carried on (a mid-sentence pause) is resent with the whole phrase; older ones finish.
        const stale = !understandFromSpeech
          || (understandStartedAt <= lastUtteranceStart && lastUtteranceStart - understandStartedAt < 2000);
        if (understandBusy && understandAbort && stale) {
          if (inflightFrom) unheardSince = Math.min(unheardSince || Infinity, inflightFrom);
          understandAbort.abort();
          understandBusy = false;
          understandAbort = null;
        }
        if (!understandBusy) {
          speechEndPending = false;
          understand(true);
        }
        continue;
      }
      if (!understandBusy && !speaking && now - lastUnderstandAt >= SLOW_MS) understand(false);
    }
  }

  function setVoice(on) {
    voice = !!on;
    if (player) player.muted = !voice;
    if (!voice) {
      try { window.speechSynthesis && window.speechSynthesis.cancel(); } catch { /* ignore */ }
    }
  }

  return {
    async start() {
      if (running) return;
      running = true;
      live = false;
      unlockAudio(); // a no-op outside a user gesture; the UI's start tap makes iOS audio work
      abort = new AbortController();
      if (!player) {
        player = createPlayer();
        player.onPlaying((on) => emit('speaking', { on }));
      }
      player.muted = !voice;
      lastUnderstandAt = performance.now() - SLOW_MS + 2000; // first understand ~2 s in
      offs = [
        bus.on('ui:voice', (d) => setVoice(d && d.on)),
        bus.on('ui:settings', (d) => {
          const now = performance.now();
          for (const k of Object.keys(d || {})) if (k !== 'source') touched[k] = now;
          if ('exposure' in (d || {})) autoExposure = 0;
        }),
        bus.on('ui:captured', () => { mem.reaction = null; utter.reacted = true; }),
      ];
      emit('status', { state: 'connecting' });
      fastLoop();
      slowLoop();
    },
    stop() {
      running = false;
      if (abort) abort.abort();
      for (const off of offs) off();
      offs = [];
      if (player) player.flush();
      try { window.speechSynthesis && window.speechSynthesis.cancel(); } catch { /* ignore */ }
      emit('status', { state: 'idle' });
    },
    setVoice,
  };
}
