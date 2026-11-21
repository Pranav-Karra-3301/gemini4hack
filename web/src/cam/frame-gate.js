// Live video frames only when the picture changed (issue #37). The same rule and defaults as
// CoachLive's FrameThrottle (apple/CoachKit/Sources/CoachLive/LiveFrames.swift): at most one frame
// per minInterval, and only if a 16x16 luma thumbnail differs from the last *sent* frame.

export const THUMB_SIDE = 16;

// RGBA pixels of a square `side` x `side` image -> THUMB_SIDE^2 luma values (Rec. 709 like the
// Swift side), each the box average of a (side / THUMB_SIDE)^2 block so sensor noise averages out.
export function lumaFromRGBA(rgba, side = THUMB_SIDE) {
  const k = side / THUMB_SIDE;
  const out = new Uint8Array(THUMB_SIDE * THUMB_SIDE);
  for (let cy = 0; cy < THUMB_SIDE; cy++) {
    for (let cx = 0; cx < THUMB_SIDE; cx++) {
      let sum = 0;
      for (let y = cy * k; y < (cy + 1) * k; y++) {
        for (let x = cx * k; x < (cx + 1) * k; x++) {
          const p = (y * side + x) * 4;
          sum += (54 * rgba[p] + 183 * rgba[p + 1] + 19 * rgba[p + 2]) >> 8;
        }
      }
      out[cy * THUMB_SIDE + cx] = Math.round(sum / (k * k));
    }
  }
  return out;
}

// Mean absolute luma difference (0..1) and the fraction of cells that changed by > cellThreshold.
export function difference(a, b, cellThreshold = 0.08) {
  const limit = Math.floor(cellThreshold * 255);
  let total = 0, changed = 0;
  for (let i = 0; i < a.length; i++) {
    const d = Math.abs(a[i] - b[i]);
    total += d;
    if (d > limit) changed += 1;
  }
  return { mean: total / a.length / 255, changedFraction: changed / a.length };
}

// Times are in ms (performance.now()). offer() returns 'send' | 'tooSoon' | 'unchanged' and
// records a 'send'; reset() makes the next frame go out (e.g. after a reconnect).
export function createFrameGate({
  minInterval = 1000, recheckInterval = 250, meanThreshold = 0.02,
  changedFractionThreshold = 0.04, cellThreshold = 0.08, maxStaleInterval = null,
} = {}) {
  let lastSent = null, lastSentAt = null, lastCheckedAt = null;
  const isDue = (now) => !(lastSentAt !== null && now - lastSentAt < minInterval)
    && !(lastCheckedAt !== null && now - lastCheckedAt < recheckInterval);
  return {
    isDue,
    offer(thumb, now) {
      if (!isDue(now)) return 'tooSoon';
      if (lastSent) {
        const stale = maxStaleInterval !== null && now - lastSentAt >= maxStaleInterval;
        const d = difference(thumb, lastSent, cellThreshold);
        if (!stale && d.mean <= meanThreshold && d.changedFraction <= changedFractionThreshold) {
          lastCheckedAt = now;
          return 'unchanged';
        }
      }
      lastSent = thumb;
      lastSentAt = now;
      lastCheckedAt = now;
      return 'send';
    },
    reset() { lastSent = null; lastSentAt = null; lastCheckedAt = null; },
  };
}

// Browser only: the 16x16 luma thumbnail of a JPEG blob (the frame we'd send). Drawn at 128 px,
// then box-averaged, since one 768 -> 16 px drawImage only samples a few pixels per cell.
const SAMPLE_SIDE = 128;
const thumbCanvas = typeof document !== 'undefined' ? document.createElement('canvas') : null;
export async function lumaThumb(blob) {
  const bmp = await createImageBitmap(blob);
  try {
    thumbCanvas.width = SAMPLE_SIDE;
    thumbCanvas.height = SAMPLE_SIDE;
    const c = thumbCanvas.getContext('2d', { willReadFrequently: true });
    c.drawImage(bmp, 0, 0, SAMPLE_SIDE, SAMPLE_SIDE);
    return lumaFromRGBA(c.getImageData(0, 0, SAMPLE_SIDE, SAMPLE_SIDE).data, SAMPLE_SIDE);
  } finally {
    bmp.close();
  }
}
