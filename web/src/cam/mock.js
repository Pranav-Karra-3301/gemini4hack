// Mock engine: a scripted ~30 s loop that exercises every bus event, so the UI can be judged
// without a backend. Same interface as live.js / decide.js.

const LOOP = 30;

// [t seconds, type, detail]. `speak` lines turn into say + speaking on/off when voice is on.
const SCRIPT = [
  [0.0, 'status', { state: 'connecting' }],
  [0.9, 'status', { state: 'live' }],
  [1.4, 'move', { dir: 'left', strength: 0.35, conf: 0.55 }],
  [2.2, 'move', { dir: 'left', strength: 0.6, conf: 0.72 }],
  [3.0, 'move', { dir: 'left', strength: 0.85, conf: 0.88 }],
  [3.4, 'intent', { intent: 'portrait', conf: 0.82, subject: 'friend by the window' }],
  [3.8, 'speak', { text: 'Portrait. Let me soften the background.' }],
  [4.6, 'settings', { mode: 'portrait' }],
  [6.2, 'move', { dir: 'up', strength: 'small', conf: 0.6 }],
  [7.4, 'settings', { exposure: 0.3 }],
  [8.2, 'move', { dir: 'closer', strength: 'medium', conf: 0.78 }],
  [9.4, 'move', { dir: 'closer', strength: 'medium', conf: 0.8 }],
  [10.6, 'status', { state: 'thinking' }],
  [10.8, 'heard', { text: "Hmm, no. That's not it" }],
  [11.0, 'reaction', { reaction: 'disappointed', conf: 0.84, heard: "Hmm, no. That's not it" }],
  [11.3, 'status', { state: 'live' }],
  [11.5, 'speak', { text: 'Step back — keep her shoulders in.' }],
  [11.9, 'move', { dir: 'back', strength: 'large', conf: 0.85 }],
  [13.6, 'move', { dir: 'rotate_left', strength: 0.4, conf: 0.7 }],
  [15.0, 'settings', { zoom: 1.5 }],
  [15.8, 'move', { dir: 'right', strength: 'small', conf: 0.5 }],
  [17.0, 'move', { dir: 'hold', strength: 0.5, conf: 0.9 }],
  [17.2, 'ready', { p: 0.35 }],
  [17.9, 'ready', { p: 0.55 }],
  [18.5, 'move', { dir: 'hold', strength: 0.5, conf: 0.92 }],
  [18.6, 'ready', { p: 0.78 }],
  [19.2, 'ready', { p: 0.92 }],
  [19.4, 'speak', { text: "That's it. Hold still." }],
  [20.6, 'heard', { text: "Oh, that's good! Yeah, that one" }],
  [20.8, 'reaction', { reaction: 'pleased', conf: 0.9, heard: "Oh, that's good! Yeah, that one" }],
  [21.4, 'ready', { p: 0.25 }],
  [22.0, 'settings', { exposure: 0 }],
  [22.8, 'move', { dir: 'down', strength: 'medium', conf: 0.66 }],
  [24.0, 'move', { dir: 'rotate_right', strength: 0.3, conf: 0.6 }],
  [25.2, 'settings', { warmth: 0.35 }],
  [26.0, 'settings', { zoom: 1 }],
  [26.6, 'intent', { intent: 'landscape', conf: 0.7, subject: 'the street' }],
  [27.0, 'move', { dir: 'right', strength: 'large', conf: 0.9 }],
  [28.6, 'settings', { mode: 'photo', warmth: 0 }],
];

export function createEngine(ctx) {
  const { bus } = ctx;
  let voice = !!ctx.voice;
  let timers = [];
  let running = false;
  let loopStart = 0;
  const offs = [];

  const emit = (type, detail) => bus.emit(type, { ...detail, source: 'mock' });
  const at = (sec, fn) => timers.push(setTimeout(fn, sec * 1000));

  function speak(text) {
    emit('say', { text });
    if (!voice) return;
    const dur = 900 + text.length * 55;
    at(0.25, () => emit('speaking', { on: true }));
    at(0.25 + dur / 1000, () => emit('speaking', { on: false }));
  }

  function runLoop() {
    if (!running) return;
    timers = timers.slice(-4); // earlier ones have fired; keep any trailing speaking-off
    loopStart = performance.now();
    for (const [t, type, detail] of SCRIPT) {
      at(t, () => {
        if (type === 'speak') speak(detail.text);
        else emit(type, detail);
      });
    }
    // latency samples, like the real engines
    for (let t = 1.2; t < LOOP; t += 1.1) at(t, () => emit('stats', { name: 'decide', ms: Math.round(650 + Math.random() * 450) }));
    for (let t = 4; t < LOOP; t += 5) at(t, () => emit('stats', { name: 'understand', ms: Math.round(2900 + Math.random() * 1600) }));
    for (let t = 4.1; t < LOOP; t += 7.6) at(t, () => emit('stats', { name: 'tts', ms: Math.round(420 + Math.random() * 380) }));
    at(LOOP, runLoop);
  }

  return {
    async start() {
      if (running) return;
      running = true;
      offs.push(bus.on('ui:captured', () => {
        if (!running) return;
        setTimeout(() => {
          emit('reaction', { reaction: 'pleased', conf: 0.7 });
          speak('Nice one.');
        }, 500);
      }));
      offs.push(bus.on('ui:voice', ({ on }) => { voice = !!on; }));
      runLoop();
    },
    stop() {
      running = false;
      timers.forEach(clearTimeout);
      timers = [];
      offs.splice(0).forEach((off) => off());
      if (voice) bus.emit('speaking', { on: false, source: 'mock' });
      bus.emit('status', { state: 'idle', source: 'mock' });
    },
    setVoice(on) {
      voice = !!on;
      if (!voice) emit('speaking', { on: false });
    },
    get elapsed() { return running ? (performance.now() - loopStart) / 1000 : 0; },
  };
}
