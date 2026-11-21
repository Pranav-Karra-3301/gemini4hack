// Coach Cam audio (brains): mic capture for the engines and a player for coach speech.
// Contract: CAM_CONTRACT.md "Audio".
//
// createMic(stream) -> Promise<Mic>: an AudioWorklet (inline module from a Blob URL) low-passes
// and decimates the mic to 16 kHz mono PCM16 and posts ~100 ms chunks. The main thread keeps a
// rolling 12 s buffer (recentWav), an RMS level and a simple energy VAD with hangover.
// createPlayer(): gapless scheduling of 24 kHz PCM chunks (Gemini Live) and WAV blobs (TTS).
//
// iOS Safari: one shared AudioContext, resumed on any user gesture (pointerdown/touchend/keydown)
// and on unlockAudio(), which the UI can call from its start button.

const RATE = 16000;
const CHUNK = 1600; // 100 ms at 16 kHz
const RING_SECONDS = 12;
const HANGOVER_MS = 450;
const ECHO_TAIL_MS = 250; // ignore mic energy this long after coach audio stops

let shared = null;
const players = new Set();
let lastPlaybackEnd = -Infinity;

function playbackActive() {
  for (const p of players) if (p.playing()) return true;
  return performance.now() - lastPlaybackEnd < ECHO_TAIL_MS;
}

export function audioContext() {
  if (!shared || shared.state === 'closed') {
    const AC = window.AudioContext || window.webkitAudioContext;
    shared = new AC({ latencyHint: 'interactive' });
    installUnlock();
  }
  return shared;
}

let unlockInstalled = false;
function installUnlock() {
  if (unlockInstalled) return;
  unlockInstalled = true;
  const go = () => {
    if (shared && shared.state !== 'running') unlockAudio();
  };
  for (const ev of ['pointerdown', 'touchend', 'keydown', 'click']) document.addEventListener(ev, go, true);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && shared && shared.state !== 'running') shared.resume().catch(() => {});
  });
}

// Call from a user gesture (start button). Resumes the shared context and plays one silent
// sample, which is what iOS needs to allow later playback.
export function unlockAudio() {
  const ctx = audioContext();
  try {
    if (navigator.audioSession && navigator.audioSession.type === 'auto') navigator.audioSession.type = 'play-and-record';
  } catch { /* Safari 17+ only */ }
  if (ctx.state !== 'running') ctx.resume().catch(() => {});
  try {
    const src = ctx.createBufferSource();
    src.buffer = ctx.createBuffer(1, 1, ctx.sampleRate);
    src.connect(ctx.destination);
    src.start(0);
  } catch { /* ignore */ }
  return ctx.state;
}

// Low-pass (biquad, ~7 kHz) + box-filter decimation to `outRate`, emitting Int16Array chunks.
// Used inside the worklet (via toString) and by the ScriptProcessor fallback.
class Decimator {
  constructor(inRate, outRate, chunk, emit) {
    this.step = inRate / outRate;
    this.t = 0;
    this.next = this.step;
    this.acc = 0;
    this.cnt = 0;
    this.chunk = chunk;
    this.emit = emit;
    this.out = new Int16Array(chunk);
    this.n = 0;
    this.sq = 0;
    // RBJ low-pass biquad; skipped when there is nothing to decimate.
    this.lp = inRate > outRate * 1.05;
    const f0 = Math.min(7000, outRate * 0.45);
    const w = (2 * Math.PI * f0) / inRate;
    const alpha = Math.sin(w) / (2 * Math.SQRT1_2);
    const cw = Math.cos(w);
    const a0 = 1 + alpha;
    this.b0 = (1 - cw) / 2 / a0;
    this.b1 = (1 - cw) / a0;
    this.b2 = this.b0;
    this.a1 = (-2 * cw) / a0;
    this.a2 = (1 - alpha) / a0;
    this.x1 = this.x2 = this.y1 = this.y2 = 0;
  }

  push(ch0, ch1) {
    for (let i = 0; i < ch0.length; i++) {
      let x = ch1 ? (ch0[i] + ch1[i]) * 0.5 : ch0[i];
      if (this.lp) {
        const y = this.b0 * x + this.b1 * this.x1 + this.b2 * this.x2 - this.a1 * this.y1 - this.a2 * this.y2;
        this.x2 = this.x1; this.x1 = x; this.y2 = this.y1; this.y1 = y;
        x = y;
      }
      this.acc += x;
      this.cnt += 1;
      this.t += 1;
      if (this.t >= this.next) {
        this.next += this.step;
        let v = this.acc / this.cnt;
        this.acc = 0;
        this.cnt = 0;
        v = v < -1 ? -1 : v > 1 ? 1 : v;
        this.out[this.n++] = v < 0 ? v * 0x8000 : v * 0x7fff;
        this.sq += v * v;
        if (this.n === this.chunk) {
          this.emit(this.out, Math.sqrt(this.sq / this.chunk));
          this.out = new Int16Array(this.chunk);
          this.n = 0;
          this.sq = 0;
        }
      }
    }
    if (this.t > 1e7) { this.t -= 1e7; this.next -= 1e7; }
  }
}

const WORKLET_SRC = `
const Decimator = (${Decimator.toString()});
class CoachMic extends AudioWorkletProcessor {
  constructor() {
    super();
    this.stopped = false;
    this.d = new Decimator(sampleRate, ${RATE}, ${CHUNK}, (pcm, rms) => {
      this.port.postMessage({ pcm: pcm.buffer, rms }, [pcm.buffer]);
    });
    this.port.onmessage = (e) => { if (e.data === 'stop') this.stopped = true; };
  }
  process(inputs) {
    if (this.stopped) return false;
    const input = inputs[0];
    if (input && input[0] && input[0].length) this.d.push(input[0], input[1]);
    return true;
  }
}
registerProcessor('coach-mic', CoachMic);
`;

const moduleLoaded = new WeakMap();
function loadWorklet(ctx) {
  if (!moduleLoaded.has(ctx)) {
    const p = (async () => {
      if (!ctx.audioWorklet) throw new Error('no AudioWorklet');
      const url = URL.createObjectURL(new Blob([WORKLET_SRC], { type: 'application/javascript' }));
      try {
        await ctx.audioWorklet.addModule(url);
      } catch {
        await ctx.audioWorklet.addModule(`data:application/javascript;base64,${btoa(WORKLET_SRC)}`);
      } finally {
        URL.revokeObjectURL(url);
      }
    })();
    moduleLoaded.set(ctx, p);
    p.catch(() => moduleLoaded.delete(ctx));
  }
  return moduleLoaded.get(ctx);
}

function wavBlob(samples, rate) {
  const buf = new ArrayBuffer(44 + samples.length * 2);
  const v = new DataView(buf);
  const str = (o, s) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
  str(0, 'RIFF'); v.setUint32(4, 36 + samples.length * 2, true); str(8, 'WAVE');
  str(12, 'fmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
  v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
  str(36, 'data'); v.setUint32(40, samples.length * 2, true);
  new Int16Array(buf, 44).set(samples);
  return new Blob([buf], { type: 'audio/wav' });
}

export async function createMic(stream) {
  const track = stream && stream.getAudioTracks ? stream.getAudioTracks()[0] : null;
  if (!track) throw new Error('createMic: the stream has no audio track');
  const ctx = audioContext();
  if (ctx.state !== 'running') ctx.resume().catch(() => {});
  const source = ctx.createMediaStreamSource(new MediaStream([track]));
  const sink = ctx.createGain(); // keeps the graph pulled (Safari) without making sound
  sink.gain.value = 0;
  sink.connect(ctx.destination);

  const ring = new Int16Array(RATE * RING_SECONDS);
  const ringChunks = ring.length / CHUNK;
  const voicedRing = new Uint8Array(ringChunks);
  let writePos = 0; // in samples, monotonically increasing
  const listeners = new Set();
  let levelVal = 0;
  let noise = 0.002;
  let run = 0;
  let speakingNow = false;
  let lastVoicedAt = 0;
  let closed = false;

  const mic = {
    lastSpeechEndedAt: 0,
    speechStartedAt: 0, // extra: performance.now() when the current/last utterance started
    sampleRate: RATE,
    onChunk(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    level() { return levelVal; },
    speaking() { return speakingNow; },
    recentWav(seconds = 4) {
      const n = Math.min(writePos, Math.round(seconds * RATE), ring.length);
      if (n < RATE * 0.3) return null;
      const chunks = Math.ceil(n / CHUNK);
      const lastChunk = Math.floor(writePos / CHUNK) - 1;
      let voiced = false;
      for (let i = 0; i < chunks && !voiced; i++) voiced = voicedRing[(((lastChunk - i) % ringChunks) + ringChunks) % ringChunks] === 1;
      if (!voiced) return null;
      const out = new Int16Array(n);
      const start = writePos - n;
      for (let i = 0; i < n; i++) out[i] = ring[(start + i) % ring.length];
      return wavBlob(out, RATE);
    },
    close() {
      if (closed) return;
      closed = true;
      listeners.clear();
      try { node.port && node.port.postMessage('stop'); } catch { /* ignore */ }
      try { source.disconnect(); } catch { /* ignore */ }
      try { node.disconnect(); } catch { /* ignore */ }
      try { sink.disconnect(); } catch { /* ignore */ }
    },
  };

  function onPcm(pcm, rms) {
    if (closed) return;
    const now = performance.now();
    // ring buffer
    for (let i = 0; i < pcm.length; i++) ring[(writePos + i) % ring.length] = pcm[i];
    writePos += pcm.length;
    // level: -60..-10 dBFS -> 0..1, fast attack, slow release
    const db = 20 * Math.log10(rms + 1e-9);
    const lv = Math.max(0, Math.min(1, (db + 60) / 50));
    levelVal = lv > levelVal ? lv : levelVal * 0.75 + lv * 0.25;
    // VAD: adaptive noise floor, 2-chunk attack, hangover
    if (rms < noise) noise = noise * 0.7 + rms * 0.3;
    else noise = noise * 0.997 + rms * 0.003;
    noise = Math.max(noise, 0.0003);
    // While coach audio plays, demand a much louder signal so its echo doesn't count as the user.
    const floor = Math.max(0.012, noise * 3.5);
    const voiced = rms > (playbackActive() ? Math.max(0.06, floor * 4) : floor);
    voicedRing[(Math.floor(writePos / CHUNK) - 1) % ringChunks] = voiced ? 1 : 0;
    if (voiced) {
      run += 1;
      lastVoicedAt = now;
      if (!speakingNow && run >= 2) {
        speakingNow = true;
        mic.speechStartedAt = now - 200;
      }
    } else {
      run = 0;
      if (speakingNow && now - lastVoicedAt > HANGOVER_MS) {
        speakingNow = false;
        mic.lastSpeechEndedAt = lastVoicedAt;
      }
    }
    for (const fn of listeners) {
      try { fn(pcm); } catch (e) { console.error('mic listener', e); }
    }
  }

  let node;
  try {
    await loadWorklet(ctx);
    node = new AudioWorkletNode(ctx, 'coach-mic', { numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1] });
    node.port.onmessage = (e) => onPcm(new Int16Array(e.data.pcm), e.data.rms);
  } catch (err) {
    console.warn('AudioWorklet unavailable, using ScriptProcessor', err);
    const dec = new Decimator(ctx.sampleRate, RATE, CHUNK, (pcm, rms) => onPcm(pcm, rms));
    node = ctx.createScriptProcessor(2048, 1, 1);
    node.onaudioprocess = (e) => dec.push(e.inputBuffer.getChannelData(0));
  }
  source.connect(node);
  node.connect(sink);
  return mic;
}

export function createPlayer() {
  const ctx = audioContext();
  const gain = ctx.createGain();
  gain.connect(ctx.destination);
  const sources = new Set();
  const subs = new Set();
  let nextTime = 0;
  let on = false;
  let muted = false;
  let gen = 0; // bumps on flush so in-flight decodes are dropped

  const setOn = (v) => {
    if (v === on) return;
    on = v;
    if (!v) lastPlaybackEnd = performance.now();
    for (const fn of subs) {
      try { fn(v); } catch (e) { console.error('player listener', e); }
    }
  };

  function schedule(buffer) {
    if (ctx.state !== 'running') ctx.resume().catch(() => {});
    const now = ctx.currentTime;
    if (nextTime < now + 0.02) nextTime = now + 0.06; // small lead from idle absorbs jitter
    const src = ctx.createBufferSource();
    src.buffer = buffer;
    src.connect(gain);
    src.onended = () => {
      sources.delete(src);
      if (!sources.size) setOn(false);
    };
    src.start(nextTime);
    nextTime += buffer.duration;
    sources.add(src);
    setOn(true);
    return buffer.duration;
  }

  const player = {
    push(data, rate = 24000) {
      if (muted || !data) return;
      const i16 = data instanceof Int16Array ? data : new Int16Array(data);
      if (!i16.length) return;
      const buf = ctx.createBuffer(1, i16.length, rate);
      const ch = buf.getChannelData(0);
      for (let i = 0; i < i16.length; i++) ch[i] = i16[i] / 32768;
      schedule(buf);
    },
    // Resolves with the clip duration (s) once it is scheduled; 0 when muted or flushed.
    async playWav(blob) {
      if (muted || !blob) return 0;
      const g = gen;
      const ab = await blob.arrayBuffer();
      const buf = await new Promise((resolve, reject) => ctx.decodeAudioData(ab, resolve, reject));
      if (muted || g !== gen) return 0;
      return schedule(buf);
    },
    flush() {
      gen += 1;
      for (const s of sources) {
        s.onended = null;
        try { s.stop(); } catch { /* not started */ }
      }
      sources.clear();
      nextTime = 0;
      setOn(false);
    },
    get muted() { return muted; },
    set muted(v) {
      muted = !!v;
      if (muted) player.flush();
    },
    playing() { return sources.size > 0; },
    onPlaying(fn) { subs.add(fn); return () => subs.delete(fn); },
    close() { player.flush(); subs.clear(); players.delete(player); try { gain.disconnect(); } catch { /* ignore */ } },
  };
  players.add(player);
  return player;
}
