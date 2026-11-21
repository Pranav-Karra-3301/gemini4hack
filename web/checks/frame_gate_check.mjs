// Check the web live client's frame gate (src/cam/frame-gate.js, issue #37). No browser, no deps.
// Usage: cd web && node checks/frame_gate_check.mjs
import { createFrameGate, difference, lumaFromRGBA, THUMB_SIDE } from '../src/cam/frame-gate.js';

let failures = 0;
const check = (ok, msg) => { console.log(`${ok ? '  ok  ' : '  FAIL'} ${msg}`); if (!ok) failures += 1; };

// A 128x128 RGBA frame: a horizontal gradient, plus optional per-pixel noise and a bright square.
let seed = 1;
const rand = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
function frame({ noise = 0, square = null, gain = 1 } = {}) {
  const side = 128, px = new Uint8ClampedArray(side * side * 4);
  for (let y = 0; y < side; y++) {
    for (let x = 0; x < side; x++) {
      let v = (40 + x * 1.4) * gain;
      if (square && x >= square.x && x < square.x + square.s && y >= square.y && y < square.y + square.s) v = 235;
      v += noise ? (rand() * 2 - 1) * noise : 0;
      const p = (y * side + x) * 4;
      px[p] = px[p + 1] = px[p + 2] = v; px[p + 3] = 255;
    }
  }
  return lumaFromRGBA(px, side);
}

console.log('thumbnail');
const base = frame();
check(base.length === THUMB_SIDE * THUMB_SIDE, `${THUMB_SIDE}x${THUMB_SIDE} luma values`);
const noisy = frame({ noise: 12 });
const dn = difference(noisy, base);
check(dn.mean <= 0.02 && dn.changedFraction <= 0.04,
  `sensor-like noise (+-12 per pixel) averages out: mean ${dn.mean.toFixed(4)}, changed ${dn.changedFraction}`);
const moved = difference(frame({ square: { x: 40, y: 40, s: 40 } }), base);
check(moved.changedFraction > 0.04, `a new bright object counts as changed: ${moved.changedFraction.toFixed(3)} of cells`);
const darker = difference(frame({ gain: 0.85 }), base);
check(darker.mean > 0.02, `a 15% exposure change counts as changed: mean ${darker.mean.toFixed(3)}`);

console.log('gate');
const g = createFrameGate({ minInterval: 900 });
check(g.offer(base, 0) === 'send', 'first frame is sent');
check(g.offer(base, 500) === 'tooSoon', 'a frame 0.5 s later is too soon');
check(g.offer(noisy, 1000) === 'unchanged', 'the same scene with noise 1 s later is not sent');
check(g.offer(frame({ noise: 12 }), 2000) === 'unchanged', 'still unchanged 2 s later');
check(g.offer(frame({ square: { x: 40, y: 40, s: 40 } }), 2100) === 'tooSoon', 'a change right after a check waits for the recheck interval');
check(g.offer(frame({ square: { x: 40, y: 40, s: 40 } }), 2300) === 'send', 'the changed scene is sent');
check(g.offer(base, 2800) === 'tooSoon', 'at most one frame per minInterval');
g.reset();
check(g.offer(base, 2900) === 'send', 'after reset() (a reconnect) the next frame is sent');
const stale = createFrameGate({ maxStaleInterval: 10000 });
stale.offer(base, 0);
check(stale.offer(base, 5000) === 'unchanged' && stale.offer(base, 10000) === 'send', 'maxStaleInterval re-sends an unchanged scene');

// A minute of a still scene at the frame loop's 1 s cadence sends one frame; a changing one sends ~60.
const still = createFrameGate({ minInterval: 900 });
let sent = 0;
for (let t = 0; t < 60000; t += 1000) if (still.offer(frame({ noise: 12 }), t) === 'send') sent += 1;
check(sent === 1, `60 s of a still, noisy scene -> ${sent} frame(s) sent`);
const moving = createFrameGate({ minInterval: 900 });
sent = 0;
for (let t = 0; t < 60000; t += 1000) if (moving.offer(frame({ square: { x: (t / 1000) % 2 ? 8 : 80, y: 40, s: 40 } }), t) === 'send') sent += 1;
check(sent === 60, `60 s of a changing scene -> ${sent} frames sent`);

console.log(`${failures} failures`);
process.exit(failures ? 1 : 0);
