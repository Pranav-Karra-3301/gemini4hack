// HUD: guidance glyphs over the viewfinder (arrows + edge glow, rings, roll, ready brackets),
// plus the live chrome: status pill, readout pill (odometer), intent chip, caption, the "you
// said" chip, mode selector, shutter ready glow, voice bars and the debug overlay.
// Colour rule (design/DESIGN.md): amber = the coach is speaking or acting, paper-white = you.
// Motion: every entrance/exit is a WAAPI animation that starts from the element's current
// rendered value, so a new event retargets instead of queueing.

const MOVE_TTL = 2500;        // hide a cue the engine stopped repeating
const STABLE_MS = 400;        // a direction must hold this long before it shows
const MIN_SHOW_MS = 1200;     // and then stays at least this long
const ON_TARGET_MS = 300;     // hide this long after "hold" / ready
const READY_TTL = 4500;
const CHIP_HOLD = 2000;
const WORD_MS = 330;          // caption word timing when TTS gives no word boundaries
const CAPTION_EXIT = 1200;    // after speech ends

const EASE = {
  out: 'cubic-bezier(.22,1,.36,1)',
  in: 'cubic-bezier(.55,0,1,.45)',
  inOut: 'cubic-bezier(.65,0,.35,1)',
  pop: 'cubic-bezier(.34,1.56,.64,1)',
};
const reducedMq = matchMedia('(prefers-reduced-motion: reduce)');
const reduced = () => reducedMq.matches;

// Haptics: light on mode switch / numeral roll, medium on Ready, rigid on shutter (Android).
const coarse = matchMedia('(pointer: coarse)');
function vibrate(ms) {
  try {
    if (!coarse.matches || !navigator.vibrate || !navigator.userActivation?.hasBeenActive) return;
    navigator.vibrate(ms);
  } catch { /* unsupported */ }
}
export const haptic = { light: () => vibrate(10), medium: () => vibrate(16), rigid: () => vibrate(24) };

// 24×24 filled glyphs for the intent chip (ink on a safelight disc).
const GLYPHS = {
  portrait: '<circle cx="12" cy="7.6" r="4.1"/><path d="M3.8 20.6c.4-4.3 3.9-7.1 8.2-7.1s7.8 2.8 8.2 7.1z"/>',
  group: '<circle cx="12" cy="7.4" r="3.3"/><path d="M6.4 19.2c.3-3.6 2.6-5.9 5.6-5.9s5.3 2.3 5.6 5.9z"/><circle cx="5.3" cy="9.3" r="2.5"/><circle cx="18.7" cy="9.3" r="2.5"/><path d="M.9 18c.2-2.8 1.9-4.6 4.4-4.6 1.1 0 2 .3 2.7.9-1 1.1-1.7 2.6-1.9 3.7z"/><path d="M23.1 18c-.2-2.8-1.9-4.6-4.4-4.6-1.1 0-2 .3-2.7.9 1 1.1 1.7 2.6 1.9 3.7z"/>',
  landscape: '<path d="M1.5 19.6l6.6-10.4 4.4 6.4 2.7-3.7 7.3 7.7z"/><circle cx="17.2" cy="5.8" r="2.4"/>',
  night: '<path d="M19.8 15.1A8.6 8.6 0 0 1 8.9 4.2 8.6 8.6 0 1 0 19.8 15.1z"/>',
  macro: '<path d="M12 2.6a3.1 3.1 0 0 1 3 3.9 3.1 3.1 0 0 1 2.4 5.2A3.1 3.1 0 0 1 13.6 15h-3.2a3.1 3.1 0 0 1-3.8-3.3 3.1 3.1 0 0 1 2.4-5.2A3.1 3.1 0 0 1 12 2.6zm0 5.6a2 2 0 1 0 0 4 2 2 0 0 0 0-4z" fill-rule="evenodd"/><path d="M11.2 14.6h1.6v6.8h-1.6z"/><path d="M12.4 19.4c.6-2.4 2.5-3.8 5-3.7-.5 2.4-2.4 3.8-5 3.7z"/>',
  food: '<path d="M5.6 2.6h1.3v5.2H8V2.6h1.3v5.2h1.1V2.6h1.3v6.1c0 1.3-.9 2.4-2.1 2.7v10.1H8V11.4c-1.4-.3-2.4-1.4-2.4-2.8z"/><path d="M15.4 21.5V2.7c2.4.5 3.9 3.3 3.9 7.4v3.6h-1.9v7.8z"/>',
  pet: '<ellipse cx="6.2" cy="10.4" rx="1.9" ry="2.4"/><ellipse cx="9.6" cy="5.9" rx="2" ry="2.6"/><ellipse cx="14.4" cy="5.9" rx="2" ry="2.6"/><ellipse cx="17.8" cy="10.4" rx="1.9" ry="2.4"/><path d="M12 11.4c2.6 0 5.6 4 5.6 6.4 0 2.2-1.9 2.6-3.2 2.2-1-.3-1.6-.6-2.4-.6s-1.4.3-2.4.6c-1.3.4-3.2 0-3.2-2.2 0-2.4 3-6.4 5.6-6.4z"/>',
  object: '<path d="M12 2.4l8.6 4.8v9.6L12 21.6l-8.6-4.8V7.2z"/><path d="M3.9 7.5L12 12l8.1-4.5M12 12v9.2" fill="none" stroke="#FFA53D" stroke-width="1.5"/>',
  street: '<path d="M2.5 21V9.4l5.4-3.2V21zM9.4 21V3.2l6.2 2.7V21zM17.1 21v-9.6l4.4 1.9V21z"/>',
  document: '<path d="M5.5 2.5h8.6l4.4 4.4v14.6h-13z"/><path d="M8.6 12.2h6.8M8.6 15.8h6.8" fill="none" stroke="#FFA53D" stroke-width="1.5"/>',
  other: '<path d="M12 2.4l2.3 6.6 6.6 2.3-6.6 2.3-2.3 6.6-2.3-6.6-6.6-2.3 6.6-2.3z"/>',
};
const INTENT_WORDS = { portrait: 'Portrait', group: 'Group', landscape: 'Landscape', object: 'Object', food: 'Food', street: 'Street', document: 'Document', other: 'Scene' };
const MODE_WORDS = { photo: 'Photo', portrait: 'Portrait', night: 'Night', macro: 'Macro' };
const MODE_GLYPH = { portrait: 'portrait', night: 'night', macro: 'macro', photo: 'other' };

const ENGINE_NAMES = { live: 'Gemini Live', decide: 'Gemini Decide', mock: 'Mock' };
const GUIDE_WORDS = {
  left: 'Move left', right: 'Move right', up: 'Move up', down: 'Move down',
  closer: 'Get closer', back: 'Step back', rotate_left: 'Rotate left', rotate_right: 'Rotate right', ready: 'Ready',
};
const MIRROR = { left: 'right', right: 'left', rotate_left: 'rotate_right', rotate_right: 'rotate_left' };
const VEC = { left: [-1, 0], right: [1, 0], up: [0, -1], down: [0, 1] };

const ARROW_SVG = '<svg viewBox="-8 -8 156 104"><path d="M44 0L0 44l44 44"/><path d="M92 0L48 44l44 44"/><path d="M140 0L96 44l44 44"/></svg>';
const RINGS_SVG = '<svg viewBox="0 0 360 360"><circle class="r3" cx="180" cy="180" r="166"/><circle class="r2" cx="180" cy="180" r="138"/><circle class="r1" cx="180" cy="180" r="108"/></svg>';
const ROTATE_HTML = '<div class="horizon"><i></i><i></i></div><svg class="rot-arrow" viewBox="0 0 120 60"><path class="arc" pathLength="1" d="M18 52A44 44 0 0 1 98 28"/><path class="head" d="M83 22l16 5.5-5 15.5"/></svg>';
const CORNER = (c) => `<svg class="${c}" viewBox="0 0 40 40"><path pathLength="1" d="M2 38V14A12 12 0 0 1 14 2h24"/></svg>`;

function el(tag, cls, html) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html) e.innerHTML = html;
  return e;
}
const clamp01 = (v) => Math.min(1, Math.max(0, Number(v) || 0));

// Animate `elm` from whatever it renders right now to `to`. Cancels earlier script animations
// on the element (CSS animations and transitions are left alone), so it never queues.
function retarget(elm, to, opts) {
  const cs = getComputedStyle(elm);
  const from = {};
  for (const k of Object.keys(to)) from[k] = cs[k];
  for (const a of elm.getAnimations()) {
    if (!(globalThis.CSSAnimation && a instanceof CSSAnimation) && !(globalThis.CSSTransition && a instanceof CSSTransition)) a.cancel();
  }
  return elm.animate([from, to], { fill: 'forwards', ...opts });
}
const done = (a) => (a?.finished || Promise.resolve()).catch(() => {});

export function createHud({ root, bus, getState, els }) {
  const { hud, shutter, caption, readout, intent, dot, engineName, voice, modes, modesTrack, debug, said, srGuide, srCaption } = els;
  const engineBtn = dot.closest('button');

  // ================================================================= guidance glyphs
  const glow = el('div', 'edge-glow');
  const arrow = el('div', 'cue cue-arrow', `<div class="cue-glyph">${ARROW_SVG}</div>`);
  const rings = el('div', 'cue cue-rings', RINGS_SVG);
  const rotate = el('div', 'cue cue-rotate', ROTATE_HTML);
  const brackets = el('div', 'brackets', CORNER('tl') + CORNER('tr') + CORNER('br') + CORNER('bl'));
  const wash = el('div', 'wash');
  hud.append(wash, brackets, glow, arrow, rings, rotate);

  const kindOf = (key) => (VEC[key] ? 'arrow' : key === 'closer' || key === 'back' ? 'rings' : key?.startsWith('rotate') ? 'rotate' : null);
  const cueEl = { arrow, rings, rotate };
  const gen = { arrow: 0, rings: 0, rotate: 0 };

  function placeRings() {
    const st = getState();
    const W = root.clientWidth, H = root.clientHeight;
    let x = W / 2, y = H * 0.49;
    if (st.focus && els.rawToScreen) {
      const s = els.rawToScreen(st.focus.x, st.focus.y);
      x = Math.min(W - 90, Math.max(90, s.x));
      y = Math.min(H * 0.62, Math.max(H * 0.3, s.y));
    }
    rings.style.left = `${x}px`;
    rings.style.top = `${y}px`;
  }

  function showCue(key, d) {
    const kind = kindOf(key);
    const node = cueEl[kind];
    const g = ++gen[kind];
    node.style.setProperty('--s', strengthOf(d.strength).toFixed(3));
    node.style.setProperty('--c', clamp01(d.conf ?? 0.7).toFixed(3));
    const rm = reduced();
    if (kind === 'arrow') {
      const [dx, dy] = VEC[key];
      arrow.dataset.dir = key;
      glow.dataset.edge = key;
      arrow.style.setProperty('--dx', dx);
      arrow.style.setProperty('--dy', dy);
      arrow.classList.remove('idle');
      glow.classList.remove('idle');
      const from = rm ? 'none' : `translate(${-24 * dx}px, ${-24 * dy}px)`;
      arrow.getAnimations().forEach((a) => a.cancel());
      const a = arrow.animate([{ opacity: 0, transform: from }, { opacity: 1, transform: 'none' }], { duration: rm ? 160 : 240, easing: EASE.out, fill: 'forwards' });
      retarget(glow, { opacity: 1 }, { duration: 240, easing: EASE.out });
      done(a).then(() => { if (gen.arrow === g) { arrow.classList.add('idle'); glow.classList.add('idle'); } });
    } else {
      if (kind === 'rings') { rings.dataset.dir = key; placeRings(); }
      if (kind === 'rotate') rotate.dataset.dir = key === 'rotate_left' ? 'ccw' : 'cw';
      node.classList.remove('idle');
      node.classList.toggle('static', rm);
      if (!rm) node.classList.add('idle');
      const a = retarget(node, { opacity: 1, transform: 'none' }, { duration: rm ? 160 : 240, easing: EASE.out });
      void a;
    }
  }

  function hideCue(key) {
    const kind = kindOf(key);
    const node = cueEl[kind];
    const g = ++gen[kind];
    const rm = reduced();
    let a;
    if (kind === 'arrow') {
      const [dx, dy] = VEC[arrow.dataset.dir] || [0, 0];
      a = retarget(arrow, { opacity: 0, transform: rm ? 'none' : `translate(${16 * dx}px, ${16 * dy}px)` }, { duration: 160, easing: EASE.in });
      retarget(glow, { opacity: 0 }, { duration: 240, easing: EASE.in });
    } else {
      a = retarget(node, { opacity: 0 }, { duration: 160, easing: EASE.in });
    }
    return done(a).then(() => {
      if (gen[kind] !== g) return;
      node.classList.remove('idle');
      if (kind === 'arrow') glow.classList.remove('idle');
    });
  }

  // hysteresis: show after STABLE_MS, keep MIN_SHOW_MS, hide ON_TARGET_MS after on-target
  let shown = null;      // { key, at }
  let pending = null;    // { key, d }
  let pendingTimer = 0, ttlTimer = 0, targetTimer = 0, swapGen = 0;

  function strengthOf(v) {
    if (typeof v === 'number' && isFinite(v)) return clamp01(v);
    return { small: 0.3, medium: 0.62, large: 1 }[v] ?? 0.6;
  }
  function cancelPending() { clearTimeout(pendingTimer); pending = null; }
  function armTtl() { clearTimeout(ttlTimer); ttlTimer = setTimeout(() => clearMove(), MOVE_TTL); }

  function move(d = {}) {
    const dir = d.dir;
    if (!dir) return;
    const st = getState();
    const key = st.mirrored && MIRROR[dir] ? MIRROR[dir] : dir;
    if (key === 'hold') { onTarget(); return; }
    if (!kindOf(key)) return;
    if (shown?.key === key) {
      clearTimeout(targetTimer); targetTimer = 0;
      cancelPending();
      armTtl();
      const node = cueEl[kindOf(key)];
      node.style.setProperty('--s', strengthOf(d.strength).toFixed(3));
      if (key === 'closer' || key === 'back') placeRings();
      return;
    }
    if (pending?.key === key) { pending.d = d; return; }
    cancelPending();
    pending = { key, d };
    pendingTimer = setTimeout(commit, STABLE_MS);
  }
  function commit() {
    if (!pending) return;
    const wait = shown ? MIN_SHOW_MS - (performance.now() - shown.at) : 0;
    if (wait > 0) { pendingTimer = setTimeout(commit, wait); return; }
    const next = pending;
    pending = null;
    swapTo(next);
  }
  async function swapTo(next) {
    const token = ++swapGen;
    clearTimeout(targetTimer); targetTimer = 0;
    if (shown) {
      const prev = shown;
      shown = null;
      await hideCue(prev.key); // out, then in: no overlap
      if (token !== swapGen) return;
    }
    showCue(next.key, next.d);
    shown = { key: next.key, at: performance.now() };
    armTtl();
    announce(GUIDE_WORDS[next.key]);
  }
  function onTarget() {
    cancelPending();
    if (shown && !targetTimer) targetTimer = setTimeout(() => { targetTimer = 0; clearMove(); }, ON_TARGET_MS);
  }
  function clearMove() {
    cancelPending();
    clearTimeout(ttlTimer);
    clearTimeout(targetTimer); targetTimer = 0;
    swapGen++;
    if (shown) { const prev = shown; shown = null; hideCue(prev.key); }
  }

  // ================================================================= a11y live region (≤ 1 per 1.5 s)
  let lastAnnounce = 0, announceTimer = 0;
  function announce(text) {
    if (!text || !srGuide) return;
    const wait = Math.max(0, 1500 - (performance.now() - lastAnnounce));
    clearTimeout(announceTimer);
    announceTimer = setTimeout(() => { srGuide.textContent = text; lastAnnounce = performance.now(); }, wait);
  }

  // ================================================================= focus square (tap to focus)
  const focusEl = el('div', 'focus', '<i class="tick t"></i><i class="tick r"></i><i class="tick b"></i><i class="tick l"></i><span class="sun"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3.5"/><path d="M12 3v2.2M12 18.8V21M3 12h2.2M18.8 12H21M5.6 5.6l1.6 1.6M16.8 16.8l1.6 1.6M5.6 18.4l1.6-1.6M16.8 7.2l1.6-1.6"/></svg></span>');
  hud.append(focusEl);
  let focusTimers = [];
  function focusAt(x, y, { sun = false } = {}) {
    focusTimers.forEach(clearTimeout);
    focusEl.style.left = `${x}px`;
    focusEl.style.top = `${y}px`;
    focusEl.classList.toggle('with-sun', sun);
    focusEl.classList.remove('on', 'dim');
    void focusEl.offsetWidth;
    focusEl.classList.add('on');
    focusTimers = [
      setTimeout(() => focusEl.classList.add('dim'), 1300),
      setTimeout(() => focusEl.classList.remove('on', 'dim'), 3600),
    ];
  }
  function focusSun(ev) {
    focusEl.style.setProperty('--ev', String(ev));
    if (!focusEl.classList.contains('on')) return;
    focusEl.classList.remove('dim');
    focusEl.classList.add('with-sun');
    focusTimers.forEach(clearTimeout);
    focusTimers = [
      setTimeout(() => focusEl.classList.add('dim'), 1500),
      setTimeout(() => focusEl.classList.remove('on', 'dim'), 3800),
    ];
  }

  // ================================================================= ready: shutter glow + brackets
  let readyOn = false, readyTimer = 0;
  function ready({ p = 0 } = {}) {
    const v = clamp01(p);
    const on = v >= 0.7;
    if (on !== readyOn) {
      readyOn = on;
      shutter.classList.toggle('ready', on);
      root.classList.toggle('is-ready', on);
      brackets.classList.toggle('on', on);
      if (on) { haptic.medium(); announce(GUIDE_WORDS.ready); onTarget(); }
    }
    clearTimeout(readyTimer);
    if (v > 0) readyTimer = setTimeout(() => ready({ p: 0 }), READY_TTL);
  }

  // ================================================================= reactions: wash + "you said" chip
  let lastHeard = { text: '', at: 0 };
  let flipNextChip = false;
  let saidTimer = 0;
  function quoteOf(text) {
    let t = String(text || '').trim().split(/[.!?;]/)[0].trim();
    if (!t) return '';
    const words = t.split(/\s+/);
    if (words.length > 6) t = `${words.slice(0, 6).join(' ')}…`;
    t = t.replace(/'/g, '’');
    return t.charAt(0).toLowerCase() + t.slice(1);
  }
  function showSaid(text) {
    const q = quoteOf(text);
    if (!q || !said) return;
    said.querySelector('q').textContent = q;
    clearTimeout(saidTimer);
    hideCaption(true);
    const op = getComputedStyle(said).opacity;
    said.getAnimations().forEach((a) => a.cancel());
    said.animate(
      [{ opacity: op, transform: reduced() ? 'translate(-50%, 0)' : 'translate(-50%, 0) scale(.92)' }, { opacity: 1, transform: 'translate(-50%, 0) scale(1)' }],
      { duration: reduced() ? 160 : 240, easing: reduced() ? EASE.out : EASE.pop, fill: 'forwards' },
    );
    saidTimer = setTimeout(() => retarget(said, { opacity: 0, transform: 'translate(-50%, 4px) scale(.98)' }, { duration: 160, easing: EASE.in }), 1600);
  }
  function reaction({ reaction: r, conf = 1, heard } = {}) {
    if (r !== 'pleased' && r !== 'disappointed') return;
    const c = clamp01(conf);
    const text = heard || (performance.now() - lastHeard.at < 4000 ? lastHeard.text : '');
    wash.dataset.kind = r;
    wash.getAnimations().forEach((a) => a.cancel());
    if (r === 'pleased') {
      wash.animate([{ opacity: 0 }, { opacity: 1, offset: 160 / 1060 }, { opacity: 1, offset: 360 / 1060 }, { opacity: 0 }], { duration: 1060, easing: EASE.out });
      showSaid(text);
      if (c >= 0.6) ready({ p: 0.9 });
    } else {
      wash.animate([{ opacity: 0 }, { opacity: 1, offset: 160 / 660 }, { opacity: 0 }], { duration: 660, easing: EASE.out });
      showSaid(text);
      clearMove();
      flipNextChip = true;
      setTimeout(() => { flipNextChip = false; }, 6000);
    }
  }

  // ================================================================= intent chip
  let chipTimer = 0, chipOn = false, lastIntent = null;
  function chip(glyph, text) {
    const disc = intent.querySelector('.intent-disc svg');
    const label = intent.querySelector('.intent-text');
    const flip = chipOn || flipNextChip;
    flipNextChip = false;
    disc.innerHTML = GLYPHS[glyph] || GLYPHS.other;
    label.textContent = text;
    const rm = reduced();
    if (flip && !rm) {
      intent.getAnimations().forEach((a) => a.cancel());
      intent.animate(
        [{ opacity: chipOn ? 1 : 0, transform: 'translate(-50%, 0) perspective(400px) rotateX(90deg)' }, { opacity: 1, transform: 'translate(-50%, 0) perspective(400px) rotateX(0deg)' }],
        { duration: 240, easing: EASE.out, fill: 'forwards' },
      );
    } else {
      retarget(intent, { opacity: 1, transform: 'translate(-50%, 0)' }, { duration: rm ? 160 : 240, easing: EASE.pop });
    }
    chipOn = true;
    clearTimeout(chipTimer);
    chipTimer = setTimeout(() => {
      chipOn = false;
      retarget(intent, { opacity: 0, transform: rm ? 'translate(-50%, 0)' : 'translate(-50%, -12px)' }, { duration: 160, easing: EASE.in });
    }, CHIP_HOLD);
  }
  function setIntent({ intent: it, conf = 1 } = {}) {
    if (!it || !GLYPHS[it] || it === 'other' || clamp01(conf) < 0.35) { lastIntent = null; return; }
    if (it === lastIntent) return;
    lastIntent = it;
    chip(it, INTENT_WORDS[it]);
  }

  // ================================================================= caption (coach speech)
  const capText = caption.querySelector('.cap-text');
  let capTimer = 0, capDelay = 0, wordTimer = 0, speakingOn = false;
  let pendingSay = null; // { text, at, shown }
  let capShown = false;
  function setWords(text, spokenAll) {
    capText.textContent = '';
    for (const [i, w] of text.split(/\s+/).filter(Boolean).entries()) {
      if (i) capText.append(' ');
      const s = el('span', `w${spokenAll ? ' on' : ''}`);
      s.textContent = w;
      capText.append(s);
    }
  }
  function enterCaption() {
    clearTimeout(capTimer);
    if (said) { clearTimeout(saidTimer); retarget(said, { opacity: 0 }, { duration: 120, easing: EASE.in }); }
    if (!capShown) caption.style.transform = 'translate(-50%, 8px)';
    capShown = true;
    retarget(caption, { opacity: 1, transform: 'translate(-50%, 0)' }, { duration: reduced() ? 160 : 240, easing: EASE.out });
  }
  function hideCaption(fast = false) {
    clearTimeout(capTimer);
    clearInterval(wordTimer);
    if (!capShown) return;
    capShown = false;
    retarget(caption, { opacity: 0, transform: reduced() ? 'translate(-50%, 0)' : 'translate(-50%, 4px)' }, { duration: fast ? 120 : 240, easing: EASE.in });
  }
  function showFull(text, holdMs) {
    clearInterval(wordTimer);
    setWords(text, true);
    enterCaption();
    capTimer = setTimeout(() => hideCaption(), holdMs);
  }
  function karaoke(text) {
    clearInterval(wordTimer);
    clearTimeout(capTimer);
    setWords(text, false);
    enterCaption();
    const words = [...capText.querySelectorAll('.w')];
    let i = 0;
    const step = () => { if (i < words.length) words[i++].classList.add('on'); else clearInterval(wordTimer); };
    step();
    wordTimer = setInterval(step, WORD_MS);
  }
  const readMs = (text) => Math.min(5000, 2200 + text.length * 35);
  function say({ text } = {}) {
    if (!text) return;
    if (srCaption) srCaption.textContent = text;
    clearTimeout(capDelay);
    pendingSay = { text, at: performance.now(), shown: false };
    if (!getState().voice) { pendingSay.shown = true; showFull(text, readMs(text)); return; }
    if (speakingOn) { pendingSay.shown = true; karaoke(text); return; }
    // voice on: wait for the audio so words light up with it; if none comes (TTS down,
    // autoplay blocked), show the whole line.
    capDelay = setTimeout(() => {
      if (pendingSay && !pendingSay.shown) { pendingSay.shown = true; showFull(text, readMs(text)); }
    }, 1600);
  }
  function speaking({ on } = {}) {
    const was = speakingOn;
    speakingOn = !!on;
    const voiced = speakingOn && getState().voice;
    voice.classList.toggle('speaking', voiced);
    if (voiced) startBars();
    if (speakingOn && !was && pendingSay && !pendingSay.shown && performance.now() - pendingSay.at < 4000) {
      clearTimeout(capDelay);
      pendingSay.shown = true;
      karaoke(pendingSay.text);
    }
    if (!speakingOn && was && capShown) {
      clearInterval(wordTimer);
      capText.querySelectorAll('.w').forEach((w) => w.classList.add('on'));
      clearTimeout(capTimer);
      capTimer = setTimeout(() => hideCaption(), CAPTION_EXIT);
    }
  }

  // ================================================================= voice toggle + bars
  const bars = [...voice.querySelectorAll('.bars i')];
  const barH = bars.map(() => 4);
  let barsRaf = 0;
  // The coach's audio player doesn't expose its output level, so the bars follow a smooth
  // speech-like envelope while audio plays (heights 6-26 px), lerped .35 per frame.
  function startBars() {
    if (barsRaf) return;
    const t0 = performance.now();
    const tick = (now) => {
      const t = (now - t0) / 1000;
      const live = voice.classList.contains('speaking') && !reduced();
      let settled = true;
      bars.forEach((b, i) => {
        let target = 4;
        if (voice.classList.contains('speaking')) {
          if (!live) target = [10, 16, 22, 26, 18, 12][i];
          else {
            const syll = 0.5 + 0.5 * Math.sin(t * 9.1 + i * 0.7) * Math.sin(t * 3.3 + i * 1.9);
            const shape = [0.45, 0.7, 0.9, 1, 0.8, 0.55][i];
            target = 6 + 20 * shape * Math.max(0, Math.min(1, syll * 1.15 + 0.1 * Math.sin(t * 17 + i)));
          }
        }
        barH[i] += (target - barH[i]) * 0.35;
        if (Math.abs(target - barH[i]) > 0.2 || target !== 4) settled = false;
        b.style.height = `${barH[i].toFixed(2)}px`;
      });
      barsRaf = settled ? 0 : requestAnimationFrame(tick);
    };
    barsRaf = requestAnimationFrame(tick);
  }
  function setVoice(on) {
    voice.setAttribute('aria-pressed', on ? 'true' : 'false');
    voice.classList.toggle('on', on);
    if (!on) { voice.classList.remove('speaking'); startBars(); }
    else if (speakingOn) { voice.classList.add('speaking'); startBars(); }
  }
  function micLevel(v) {
    voice.style.setProperty('--lvl', Math.min(1, v * 2.2).toFixed(3));
  }

  // ================================================================= pills: width follows content
  function resizeWith(pill, mutate) {
    const w0 = pill.getBoundingClientRect().width;
    mutate();
    const w1 = pill.getBoundingClientRect().width;
    if (Math.abs(w1 - w0) < 0.5 || reduced() || !w0) return;
    pill.animate([{ width: `${w0}px` }, { width: `${w1}px` }], { duration: 240, easing: EASE.out });
  }

  // ================================================================= readout pill (odometer)
  // items: [{ key, prefix, value, num }]. Same keys -> per-character roll; new keys -> line swap.
  let roKeys = '';
  let roNoteTimer = 0, roNoting = false, roLast = null;
  function cell(ch) { const s = el('span', 'ro-ch'); s.textContent = ch; return s; }
  function rollItem(item, value, dir) {
    const valEl = item.querySelector('.ro-val');
    const old = valEl.dataset.v ?? '';
    if (old === value) return false;
    valEl.dataset.v = value;
    const oc = [...old], nc = [...value];
    valEl.textContent = '';
    const cells = nc.map((c) => { const s = cell(c); valEl.append(s); return s; });
    if (!dir || reduced() || !old) return true;
    const from = `translateY(${dir > 0 ? 100 : -100}%)`;
    const out = `translateY(${dir > 0 ? -100 : 100}%)`;
    const ghost = (text, left) => {
      const g = el('span', 'ro-ch ro-ghost');
      g.textContent = text;
      g.style.left = `${left}px`;
      item.append(g);
      g.animate([{ transform: 'none' }, { transform: out }], { duration: 240, easing: EASE.out, fill: 'forwards' }).finished.then(() => g.remove(), () => g.remove());
    };
    if (oc.length === nc.length) {
      cells.forEach((s, i) => {
        if (oc[i] === nc[i]) return;
        s.animate([{ transform: from }, { transform: 'none' }], { duration: 240, easing: EASE.out });
        ghost(oc[i], s.offsetLeft);
      });
    } else {
      valEl.animate([{ transform: from }, { transform: 'none' }], { duration: 240, easing: EASE.out });
      ghost(old, valEl.offsetLeft);
    }
    return true;
  }
  function renderReadout(items, { coachKeys = [], dirs = {} } = {}) {
    const keys = items.map((i) => i.key).join('|');
    let rolled = false;
    resizeWith(readout, () => {
      if (keys !== roKeys) {
        const oldLine = readout.querySelector('.ro-line');
        const line = el('span', 'ro-line');
        line.style.display = 'contents';
        items.forEach((it, i) => {
          if (i) line.append(el('span', 'ro-sep', '·'));
          const item = el('span', 'ro-item');
          item.dataset.k = it.key;
          if (it.prefix) item.append(Object.assign(el('span', 'ro-pre'), { textContent: it.prefix }));
          const v = el('span', 'ro-val');
          v.dataset.v = it.value;
          v.textContent = it.value;
          item.append(v);
          line.append(item);
        });
        oldLine?.remove();
        readout.append(line);
        if (roKeys && !reduced()) {
          for (const item of line.querySelectorAll('.ro-item, .ro-sep')) item.animate([{ transform: 'translateY(100%)', opacity: 0 }, { transform: 'none', opacity: 1 }], { duration: 240, easing: EASE.out });
        }
        roKeys = keys;
        return;
      }
      for (const it of items) {
        const item = readout.querySelector(`.ro-item[data-k="${it.key}"]`);
        if (!item) continue;
        if (rollItem(item, it.value, dirs[it.key] ?? 1)) {
          rolled = true;
          if (coachKeys.includes(it.key)) {
            item.classList.add('coach');
            clearTimeout(item._t);
            item._t = setTimeout(() => item.classList.remove('coach'), 600);
          }
        }
      }
    });
    if (rolled) haptic.light();
  }
  function setReadout(items, opts = {}) {
    roLast = items;
    if (roNoting) return; // a device note is up; it restores roLast when it ends
    renderReadout(items, opts);
  }
  // Briefly replace the readout with a short note (e.g. the active camera's name).
  function readoutNote(text, ms = 1600) {
    roNoting = true;
    readout.classList.add('device');
    renderReadout([{ key: 'note', value: String(text).toUpperCase() }]);
    clearTimeout(roNoteTimer);
    roNoteTimer = setTimeout(() => {
      roNoting = false;
      readout.classList.remove('device');
      if (roLast) renderReadout(roLast);
    }, ms);
  }

  // ================================================================= status pill
  let engineCur = 'mock', engineFallback = null, statusState = 'idle', labelTimer = 0, labelHold = null;
  function restLabel() {
    if (statusState === 'error') return 'Offline';
    if (engineFallback && engineCur === 'mock') return 'Mock';
    return 'Live';
  }
  function renderLabel() {
    const text = (labelHold || restLabel()).toUpperCase();
    if (engineName.textContent === text) return;
    resizeWith(engineBtn, () => { engineName.textContent = text; });
  }
  function status({ state: s } = {}) {
    if (!s) return;
    statusState = s;
    dot.dataset.state = s;
    renderLabel();
  }
  // Show a label in the status pill for a while (engine name on switch / long-press).
  function holdLabel(text, ms = 1600) {
    labelHold = text;
    renderLabel();
    clearTimeout(labelTimer);
    if (ms > 0) labelTimer = setTimeout(() => { labelHold = null; renderLabel(); }, ms);
  }
  function engine(name, { fallback = false, failed = null, announce: ann = true } = {}) {
    engineCur = name;
    engineFallback = fallback ? failed || true : null;
    dot.classList.toggle('fallback', !!fallback);
    engineBtn.setAttribute('aria-label', `Coach: ${ENGINE_NAMES[name] || name}${fallback ? ` (fallback, ${failed} unavailable)` : ''}. Tap to switch engine, hold for details`);
    if (!ann) { renderLabel(); return; }
    if (fallback && failed) holdLabel(`${ENGINE_NAMES[name] || name} · ${failed} off`, 2600);
    else holdLabel(ENGINE_NAMES[name] || name, 1600);
  }
  function showEngineName(ms = 1600) {
    const name = ENGINE_NAMES[engineCur] || engineCur;
    holdLabel(engineFallback && typeof engineFallback === 'string' ? `${name} · ${engineFallback} off` : name, ms);
  }

  // ================================================================= mode selector
  modesTrack.querySelectorAll('button[data-mode]').forEach((b) => {
    if (!b.querySelector('span')) b.innerHTML = `<span>${b.textContent.trim()}</span>`;
  });
  const modeDot = modesTrack.querySelector('.mode-dot');
  let modeCur = null;
  function vertical() { return getComputedStyle(modesTrack).flexDirection === 'column'; }
  function setMode(mode, { instant = false, by = null } = {}) {
    const btns = [...modesTrack.querySelectorAll('button[data-mode]')];
    const b = btns.find((x) => x.dataset.mode === mode) || btns[0];
    btns.forEach((x) => { x.classList.toggle('active', x === b); x.setAttribute('aria-pressed', x === b ? 'true' : 'false'); });
    if (by) modes.dataset.by = by;
    if (instant || reduced()) modeDot.style.transition = 'none';
    const span = b.querySelector('span') || b;
    if (vertical()) modeDot.style.transform = `translate(0, ${b.offsetTop + b.offsetHeight / 2}px)`;
    else modeDot.style.transform = `translate(${span.offsetLeft + span.offsetWidth / 2}px, 0)`;
    if (instant || reduced()) { void modeDot.offsetWidth; modeDot.style.transition = ''; }
    const changed = modeCur !== null && modeCur !== b.dataset.mode;
    modeCur = b.dataset.mode;
    if (changed && !instant) {
      haptic.light();
      if (by === 'coach' && mode !== 'photo') {
        const it = getState().intent;
        chip(it && GLYPHS[it] && it !== 'other' ? it : MODE_GLYPH[mode], `${MODE_WORDS[mode]} on`);
      }
    }
  }

  // ================================================================= debug overlay
  const log = [];
  const stats = new Map();
  let debugOn = false, dbgQueued = false;
  const t0 = performance.now();
  function fmt(v) {
    if (v == null) return '';
    if (typeof v === 'number') return Math.abs(v) < 10 ? v.toFixed(2).replace(/\.?0+$/, '') : String(Math.round(v));
    if (typeof v === 'object') return JSON.stringify(v).replace(/"/g, '').slice(0, 40);
    return String(v).slice(0, 48);
  }
  function record(type, d = {}) {
    if (type === 'stats') {
      const s = stats.get(d.name) || { last: 0, avg: 0, n: 0 };
      s.last = d.ms; s.n += 1; s.avg = s.n === 1 ? d.ms : s.avg * 0.8 + d.ms * 0.2;
      stats.set(d.name, s);
    } else {
      const parts = Object.entries(d).filter(([k]) => k !== 'source' && k !== 'blob').map(([k, v]) => `${k}=${fmt(v)}`);
      const t = ((performance.now() - t0) / 1000).toFixed(1).padStart(6);
      log.push(`${t} ${(d.source || '').slice(0, 3).padEnd(3)} ${type.padEnd(9)} ${parts.join(' ')}`);
      if (log.length > 16) log.shift();
    }
    if (debugOn && !dbgQueued) { dbgQueued = true; requestAnimationFrame(renderDebug); }
  }
  function renderDebug() {
    dbgQueued = false;
    const st = getState();
    const lat = [...stats.entries()].map(([k, s]) => `${k.padEnd(12)} ${String(Math.round(s.last)).padStart(5)} ms  avg ${String(Math.round(s.avg)).padStart(5)}`);
    const caps = Object.entries(st.caps || {}).filter(([, v]) => v).map(([k]) => k).join(' ') || 'none (emulated)';
    debug.textContent = [
      `engine ${st.engine}  mode ${st.mode}  zoom ${fmt(st.zoom)}  ev ${fmt(st.exposure)}  voice ${st.voice ? 'on' : 'off'}`,
      `camera ${st.facing}${st.mirrored ? ' mirrored' : ''}  hw ${caps}`,
      ...(lat.length ? ['', ...lat] : []),
      '',
      ...log,
    ].join('\n');
  }
  function setDebug(on) {
    debugOn = on;
    debug.hidden = !on;
    if (on) renderDebug();
  }

  // ================================================================= bus wiring
  const types = ['move', 'settings', 'intent', 'reaction', 'ready', 'say', 'heard', 'capture', 'speaking', 'status', 'stats', 'ui:settings', 'ui:voice', 'ui:captured'];
  for (const t of types) bus.on(t, (d) => record(t, d || {}));
  bus.on('move', move);
  bus.on('reaction', reaction);
  bus.on('ready', ready);
  bus.on('say', say);
  bus.on('speaking', speaking);
  bus.on('intent', setIntent);
  bus.on('status', status);
  bus.on('heard', (d) => { if (d?.text) lastHeard = { text: d.text, at: performance.now() }; });

  return {
    move, clearMove, focusAt, focusSun, reaction, ready, say, speaking, setVoice, micLevel,
    setReadout, readoutNote, setIntent, status, engine, showEngineName, setMode, setDebug, chip,
    get debugOn() { return debugOn; },
    get readyOn() { return readyOn; },
    refreshDebug() { if (debugOn) renderDebug(); },
  };
}
