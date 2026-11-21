// Capture: shutter press + flash, render the processed still through the viewfinder shader,
// fly it into the last-shot thumb, and the review card with Share / Save.
import { haptic } from './hud.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const EASE = {
  out: 'cubic-bezier(.22,1,.36,1)',
  in: 'cubic-bezier(.55,0,1,.45)',
  inOut: 'cubic-bezier(.65,0,.35,1)',
  pop: 'cubic-bezier(.34,1.56,.64,1)',
};
const reducedMq = matchMedia('(prefers-reduced-motion: reduce)');
const laptopMq = matchMedia('(min-width: 900px) and (min-height: 600px)');

function fmtZoom(z) { return `${Math.round(z * 10) / 10}×`; }

export function createCapture({ root, bus, vf, getState, isCoached, els }) {
  const { shutter, flash, thumb, review, reviewImg, card, meta, back, save, share } = els;
  const thumbImg = thumb.querySelector('img');
  const bar = review.querySelector('.review-bar');
  let busy = false;
  let last = null; // {blob, url, width, height, name, meta}

  // ---------------------------------------------------------------- shutter press feel
  const pressOn = () => shutter.classList.add('pressed');
  const pressOff = () => shutter.classList.remove('pressed');
  shutter.addEventListener('pointerdown', pressOn);
  for (const t of ['pointerup', 'pointerleave', 'pointercancel']) shutter.addEventListener(t, pressOff);
  function tapFeel() {
    pressOn();
    setTimeout(pressOff, 90);
  }

  async function shoot(reason = 'user') {
    if (busy || !review.hidden) return;
    const st = getState();
    busy = true;
    if (!shutter.classList.contains('pressed')) tapFeel();
    haptic.rigid();
    const coached = reason !== 'user' || !!isCoached?.();
    const busyTimer = setTimeout(() => shutter.classList.add('busy'), 160);
    try {
      let torch = false;
      if (st.flash === 'on') {
        if (vf.caps.torch) { torch = true; await vf.setTorch(true); await sleep(380); }
        else if (st.facing === 'user') {
          // front "flash": light the face with the screen for a beat
          flash.classList.add('screen');
          await sleep(320);
        }
      }
      const shot = await vf.renderStill(0.92);
      flash.classList.remove('screen');
      flash.animate([{ opacity: 0 }, { opacity: 0.6, offset: 0.3 }, { opacity: 0 }], { duration: 180, easing: EASE.out });
      if (torch) vf.setTorch(false);
      if (!shot?.blob) return;
      if (last?.url) URL.revokeObjectURL(last.url);
      const stamp = new Date().toISOString().replace(/[-:]/g, '').replace('T', '_').slice(0, 15);
      last = {
        ...shot,
        url: URL.createObjectURL(shot.blob),
        name: `coachcam_${stamp}.jpg`,
        meta: { zoom: st.zoom, mode: st.mode, iso: st.iso, exposure: st.exposure, coached },
      };
      await fly(last.url);
      bus.emit('ui:captured', { blob: shot.blob, reason, source: 'ui' });
    } catch (e) {
      console.warn('[cam] capture failed', e);
    } finally {
      clearTimeout(busyTimer);
      shutter.classList.remove('busy');
      busy = false;
    }
  }

  // the captured frame shrinks into the last-shot thumb (FLIP, 420 ms)
  async function fly(url) {
    const img = new Image();
    img.src = url;
    img.className = 'flyer';
    try { await img.decode(); } catch { /* still animate */ }
    const W = root.clientWidth, H = root.clientHeight;
    const tr = thumb.getBoundingClientRect();
    const rr = root.getBoundingClientRect();
    root.append(img);
    const to = { left: `${tr.left - rr.left}px`, top: `${tr.top - rr.top}px`, width: `${tr.width}px`, height: `${tr.height}px`, borderRadius: '16px' };
    const anim = reducedMq.matches
      ? img.animate([{ ...to, opacity: 1 }, { ...to, opacity: 1 }], { duration: 160, fill: 'forwards' })
      : img.animate(
        [{ left: '0px', top: '0px', width: `${W}px`, height: `${H}px`, borderRadius: '0px' }, to],
        { duration: 420, easing: EASE.inOut, fill: 'forwards' },
      );
    await anim.finished.catch(() => {});
    thumbImg.src = url;
    thumb.classList.add('has');
    thumb.animate([{ transform: 'scale(1.1)' }, { transform: 'scale(1)' }], { duration: 240, easing: EASE.pop });
    img.remove();
  }

  // ---------------------------------------------------------------- review
  // The card fits the photo inside the box between the top inset and the meta/actions block.
  function layout() {
    const W = root.clientWidth, H = root.clientHeight;
    const lap = laptopMq.matches;
    const safeT = parseFloat(getComputedStyle(review).paddingTop) || 0; // env(safe-area-inset-top)
    const top = lap ? 40 : Math.max(60, safeT + 8);
    const bottom = lap ? 160 : 212; // meta at +20, actions at +64 (h 64)
    const side = lap ? 32 : 12;
    const bw = W - 2 * side, bh = H - top - bottom;
    const ar = last?.width && last?.height ? last.width / last.height : bw / bh;
    let w, h;
    if (Math.abs(Math.log(ar / (bw / bh))) < 0.15) { w = bw; h = bh; } // close enough: fill (slight crop)
    else if (ar > bw / bh) { w = bw; h = bw / ar; }
    else { h = bh; w = bh * ar; }
    review.style.setProperty('--review-bottom', `${bottom}px`);
    return { left: (W - w) / 2, top: top + (bh - h) / 2, width: w, height: h };
  }
  function place(r) {
    card.style.left = `${r.left}px`;
    card.style.top = `${r.top}px`;
    card.style.width = `${r.width}px`;
    card.style.height = `${r.height}px`;
  }
  function renderMeta() {
    const m = last?.meta || {};
    const items = [
      last?.width ? `${last.width}×${last.height}` : null,
      m.zoom ? fmtZoom(m.zoom) : null,
      m.iso ? `ISO ${Math.round(m.iso)}` : null,
      m.mode ? m.mode : null,
    ].filter(Boolean).slice(0, 3);
    meta.textContent = '';
    for (const t of items) meta.append(Object.assign(document.createElement('span'), { textContent: t }));
    if (m.coached) meta.append(Object.assign(document.createElement('span'), { className: 'coached', textContent: 'Coached' }));
  }

  function openReview() {
    if (!last || !review.hidden) return;
    reviewImg.src = last.url;
    renderMeta();
    review.hidden = false;
    const r = layout();
    place(r);
    root.classList.add('reviewing');
    review.getAnimations({ subtree: true }).forEach((x) => x.cancel());
    const W = root.clientWidth, H = root.clientHeight;
    if (reducedMq.matches) {
      review.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 160 });
      return;
    }
    // photo FLIPs from full-bleed to the card (radius 0 -> 28)
    card.animate(
      [{ left: '0px', top: '0px', width: `${W}px`, height: `${H}px`, borderRadius: '0px' }, { left: `${r.left}px`, top: `${r.top}px`, width: `${r.width}px`, height: `${r.height}px`, borderRadius: '28px' }],
      { duration: 420, easing: EASE.out },
    );
    review.animate([{ backgroundColor: 'rgba(8,8,10,0)' }, { backgroundColor: 'rgba(8,8,10,1)' }], { duration: 240, easing: EASE.out });
    back.animate([{ opacity: 0, transform: 'scale(.8)' }, { opacity: 1, transform: 'none' }], { duration: 240, delay: 200, easing: EASE.pop, fill: 'backwards' });
    for (const x of [meta, bar]) {
      x.animate([{ opacity: 0, translate: '0 16px' }, { opacity: 1, translate: '0 0' }], { duration: 240, delay: 120, easing: EASE.out, fill: 'backwards' });
    }
  }
  async function closeReview() {
    if (review.hidden) return;
    root.classList.remove('reviewing');
    const W = root.clientWidth, H = root.clientHeight;
    const cs = getComputedStyle(card);
    review.getAnimations({ subtree: true }).forEach((x) => x.cancel());
    let a;
    if (reducedMq.matches) a = review.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 160, fill: 'forwards' });
    else {
      for (const x of [meta, bar, back]) x.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 120, fill: 'forwards' });
      review.animate([{ backgroundColor: 'rgba(8,8,10,1)' }, { backgroundColor: 'rgba(8,8,10,0)' }], { duration: 320, easing: EASE.inOut, fill: 'forwards' });
      a = card.animate(
        [{ left: cs.left, top: cs.top, width: cs.width, height: cs.height, borderRadius: '28px', opacity: 1 }, { left: '0px', top: '0px', width: `${W}px`, height: `${H}px`, borderRadius: '0px', opacity: 0 }],
        { duration: 320, easing: EASE.inOut, fill: 'forwards' },
      );
    }
    await a.finished.catch(() => {});
    review.hidden = true;
    review.getAnimations({ subtree: true }).forEach((x) => x.cancel());
  }
  window.addEventListener('resize', () => { if (!review.hidden) place(layout()); });

  function download() {
    if (!last) return;
    const a = document.createElement('a');
    a.href = last.url;
    a.download = last.name;
    document.body.append(a);
    a.click();
    a.remove();
    confirm(save);
  }
  async function doShare() {
    if (!last) return;
    const file = new File([last.blob], last.name, { type: 'image/jpeg' });
    if (navigator.canShare?.({ files: [file] })) {
      try { await navigator.share({ files: [file], title: 'Coach Cam' }); } catch { /* cancelled */ }
    } else download();
  }
  function confirm(btn) {
    btn.classList.add('done');
    setTimeout(() => btn.classList.remove('done'), 1400);
  }

  shutter.addEventListener('click', () => shoot('user'));
  thumb.addEventListener('click', openReview);
  back.addEventListener('click', closeReview);
  save.addEventListener('click', download);
  share.addEventListener('click', doShare);
  bus.on('capture', (d) => shoot(d?.reason || 'coach'));
  window.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeReview(); });

  return {
    shoot,
    openReview,
    closeReview,
    get reviewing() { return !review.hidden; },
    get last() { return last; },
  };
}
