// The DOM layer: top bar, score dials, markers anchored to the 3D scene, the one note card,
// the stepper (1 · 2 · 3 · reframe), the reframe preview and the upload screen.
// Icon-led and quiet: words appear only where they explain something.

const $ = (sel) => document.querySelector(sel);

const svg = (body, size = 24, sw = 2) =>
  `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;

export const ICONS = {
  back: svg('<path d="M14.5 6 8.5 12l6 6"/>', 22, 2),
  next: svg('<path d="M9.5 6l6 6-6 6"/>', 26, 2.4),
  plus: svg('<path d="M12 5v14M5 12h14"/>', 22, 2),
  upload: svg('<path d="M12 15V4.5M7.5 9 12 4.5 16.5 9"/><path d="M5 13.5v3.5A2.5 2.5 0 0 0 7.5 19.5h9a2.5 2.5 0 0 0 2.5-2.5v-3.5"/>', 40, 2),
  // orbit + camera
  reframe: svg('<path d="M19.6 9.2A8 8 0 1 0 20 13"/><path d="M20.4 4.6v4.8h-4.8"/><rect x="8.6" y="11" width="7.8" height="5.8" rx="1.3"/><circle cx="12.5" cy="13.9" r="1.35"/>', 26, 2.1),
  reframeSm: svg('<path d="M19.6 9.2A8 8 0 1 0 20 13"/><path d="M20.4 4.6v4.8h-4.8"/><circle cx="12" cy="12.6" r="2.2"/>', 15, 2.2),
  check: svg('<path d="M5 12.5 9.5 17 19 7.5"/>', 24, 2.4),
};

const NOTE_WORDS = { focus: 'FOCUS', remove: 'REMOVE' };
const SCORE_NAME = { lighting: 'LIGHT', composition: 'COMPOSITION' };

export function createHud() {
  const body = document.body;
  const markersEl = $('#markers');
  const noteEl = $('#note');
  const noteStack = noteEl.querySelector('.note-stack');
  const statusEl = $('#status');
  const scoresEl = $('#scores');
  const scoreCard = $('#score-card');
  const rfNote = $('#rf-note');
  const frameEl = $('#frame');
  const dotsEl = $('#dots');
  const prevBtn = $('#prev');
  const nextBtn = $('#next');
  const uploadEl = $('#upload');
  const samplesEl = $('#samples');
  const pctEl = $('#up-pct');
  const dropZone = $('#drop-zone');
  let markers = [];

  $('#back').innerHTML = ICONS.back;
  $('#up-back').innerHTML = ICONS.back;
  $('#add').innerHTML = ICONS.plus;
  uploadEl.querySelector('.up-i').innerHTML = ICONS.upload;
  prevBtn.innerHTML = ICONS.back;
  frameEl.innerHTML = '<i></i><i></i><i></i><i></i>';

  // ---------------- status (next to the wordmark) ----------------
  const setBusy = (on) => (statusEl.dataset.busy = on ? '1' : '0');
  const setFlat = (on) => (statusEl.dataset.flat = on ? '1' : '0');

  // ---------------- markers ----------------
  function setMarkers(regions, { onEnter, onLeave, onTap }) {
    clearMarkers();
    markers = regions.map((r, i) => {
      const el = document.createElement('button');
      el.className = 'marker';
      el.dataset.tag = r.tag;
      el.style.setProperty('--i', i);
      el.setAttribute('aria-label', `${i + 1}: ${r.tag}. ${r.note}`);
      el.innerHTML = r.tag === 'remove' ? '<span class="m-body"><span class="m-disc"></span></span>' : '<span class="m-body"><span class="m-halo"></span><span class="m-core"></span></span>';
      el.addEventListener('pointerenter', (e) => e.pointerType === 'mouse' && onEnter(i));
      el.addEventListener('pointerleave', (e) => e.pointerType === 'mouse' && onLeave(i));
      el.addEventListener('click', (e) => {
        e.stopPropagation();
        onTap(i);
      });
      markersEl.appendChild(el);
      return el;
    });
    requestAnimationFrame(() => requestAnimationFrame(() => markers.forEach((el) => el.classList.add('in'))));
  }
  function clearMarkers() {
    markersEl.replaceChildren();
    markers = [];
    markersEl.dataset.focus = '';
  }
  // Markers stay clear of the top bar, the score panel and the bottom bar; an object outside
  // the crop gets its marker pinned to the nearest edge instead of vanishing.
  function placeMarkers(points) {
    const W = innerWidth;
    const H = innerHeight;
    const phone = W <= 600;
    const top = phone ? 132 : 96;
    const bottom = H - (phone ? 120 : 124);
    const panel = scoresEl.getBoundingClientRect();
    points.forEach((p, i) => {
      const el = markers[i];
      if (!el) return;
      let x = Math.min(W - 34, Math.max(34, p.x));
      let y = Math.min(bottom, Math.max(top, p.y));
      if (panel.width && x > panel.left - 26 && y < panel.bottom + 26) {
        // under the score panel: slide left or down, whichever is shorter
        if (x - (panel.left - 26) < panel.bottom + 26 - y) x = panel.left - 26;
        else y = panel.bottom + 26;
      }
      el.style.transform = `translate3d(${x.toFixed(1)}px, ${y.toFixed(1)}px, 0)`;
      el.classList.toggle('off', !p.visible);
    });
  }
  function setMarkerState(focused, hovered) {
    markersEl.dataset.focus = focused >= 0 ? '1' : '';
    markers.forEach((el, i) => {
      el.classList.toggle('focused', i === focused);
      el.classList.toggle('hovered', i === hovered && focused < 0);
    });
  }
  const hideMarkers = (on) => markersEl.classList.toggle('hide', on);

  // ---------------- the note card ----------------
  // One card. On a laptop it sits beside its object and glides with it; on a phone it docks
  // above the bar. Changing steps slides the old text out and the new one in, overlapping.
  let noteKey = null;
  let notePos = null; // smoothed laptop position
  let noteTarget = null;
  function showNote(n, { dir = 1, delay = 280 } = {}) {
    const key = n ? `${n.kind}|${n.text}|${n.step}` : null;
    if (key === noteKey) return;
    const wasShown = noteEl.classList.contains('show') && noteKey;
    noteKey = key;
    if (!n) {
      noteEl.classList.remove('show');
      return;
    }
    const el = document.createElement('div');
    el.className = 'note-body';
    el.dataset.kind = n.kind;
    el.style.setProperty('--dir', dir);
    el.innerHTML = `<p class="note-tag"><span></span><span class="n"></span></p><p class="note-text"></p>`;
    el.querySelector('.note-tag span').textContent = NOTE_WORDS[n.kind] || n.kind.toUpperCase();
    el.querySelector('.n').textContent = n.step ? `${n.step} / ${n.total}` : '';
    el.querySelector('.note-text').textContent = n.text;
    for (const old of noteStack.children) {
      old.style.setProperty('--dir', dir);
      old.classList.add('out');
      setTimeout(() => old.remove(), 260);
    }
    if (wasShown) {
      el.classList.add('pre');
      noteStack.appendChild(el);
      el.getBoundingClientRect();
      el.classList.remove('pre');
    } else {
      for (const old of [...noteStack.children]) if (old !== el) old.remove();
      noteStack.appendChild(el);
      notePos = null;
      noteEl.style.setProperty('--note-delay', `${delay}ms`);
      noteEl.classList.add('show');
    }
  }
  /** Laptop: 24px right of the object's screen box (left if no room), clamped 32px from the
   *  edges and clear of the score panel; glides there (exponential approach). */
  let glideRaf = 0;
  let glideT = 0;
  function glide(now) {
    const dt = Math.min(0.05, (now - glideT) / 1000 || 1 / 60);
    glideT = now;
    if (!notePos || !noteTarget) return (glideRaf = 0);
    const k = 1 - Math.exp(-10 * dt);
    notePos.x += (noteTarget.x - notePos.x) * k;
    notePos.y += (noteTarget.y - notePos.y) * k;
    const done = Math.abs(noteTarget.x - notePos.x) < 0.3 && Math.abs(noteTarget.y - notePos.y) < 0.3;
    if (done) notePos = { ...noteTarget };
    noteEl.style.transform = `translate3d(${notePos.x.toFixed(1)}px, ${notePos.y.toFixed(1)}px, 0)`;
    glideRaf = done ? 0 : requestAnimationFrame(glide);
  }
  function placeNote(box, anchor) {
    if (innerWidth <= 600 || !noteKey || !box) return;
    const W = innerWidth;
    const H = innerHeight;
    const w = noteEl.offsetWidth || 296;
    const h = noteEl.offsetHeight || 120;
    const m = 32;
    let x = box.r + 24;
    if (x + w > W - m) x = box.l - 24 - w >= m ? box.l - 24 - w : W - m - w;
    x = Math.max(m, Math.min(W - m - w, x));
    let y = anchor.y - 28;
    const panel = scoresEl.getBoundingClientRect();
    const minY = panel.width && x + w > panel.left - 16 ? panel.bottom + 16 : 96;
    y = Math.max(minY, Math.min(H - 124 - h, y));
    noteTarget = { x, y };
    if (!notePos || !noteEl.classList.contains('show')) {
      notePos = { ...noteTarget };
      noteEl.style.transform = `translate3d(${x.toFixed(1)}px, ${y.toFixed(1)}px, 0)`;
      return;
    }
    if (!glideRaf) {
      glideT = performance.now();
      glideRaf = requestAnimationFrame(glide);
    }
  }

  // ---------------- score dials ----------------
  // Each dial: the score as "3.6/5" on a ring, the Decision 1 distribution as five bars, a
  // word label. Tap for the model's one-line reason and what the distribution means.
  const R = 31;
  const C = 2 * Math.PI * R;
  const dialHtml = (key) =>
    `<button class="dial" data-k="${key}" aria-expanded="false">
      <span class="ring"><svg viewBox="0 0 76 76" aria-hidden="true"><circle class="track" cx="38" cy="38" r="${R}"/>
      <circle class="arc" cx="38" cy="38" r="${R}" stroke-dasharray="${C.toFixed(2)} ${C.toFixed(2)}" stroke-dashoffset="${C.toFixed(2)}"/></svg>
      <span class="num"><b>–</b><small>/5</small></span></span>
      <span class="hist" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i></span>
      <span class="lbl">${SCORE_NAME[key]}</span></button>`;
  scoresEl.innerHTML = dialHtml('lighting') + dialHtml('composition');
  let scoreData = {};
  let cardKey = null;
  let cardTimer = 0;
  function showScoreCard(key) {
    clearTimeout(cardTimer);
    const s = key && scoreData[key];
    cardKey = s ? key : null;
    for (const b of scoresEl.children) b.setAttribute('aria-expanded', String(b.dataset.k === cardKey));
    if (!s) return scoreCard.classList.remove('show');
    const dist = s.distribution || {};
    let mode = Math.round(s.score);
    let pm = -1;
    for (const [k, p] of Object.entries(dist)) if (Number(p) > pm) (pm = Number(p)), (mode = Number(k));
    const sure = pm >= 0 ? `${Math.round(pm * 100)}% sure it's a ${mode}` : `${Math.round((s.confidence ?? 0) * 100)}% confident`;
    scoreCard.innerHTML = `<p class="sc-tag"></p><p class="sc-text"></p><p class="sc-why"></p>`;
    scoreCard.querySelector('.sc-tag').textContent = `${SCORE_NAME[key]} · ${s.score.toFixed(1)} / 5`;
    scoreCard.querySelector('.sc-text').textContent = s.label || (key === 'lighting' ? 'How well the light works.' : 'How well the frame is built.');
    scoreCard.querySelector('.sc-why').textContent = `Gemini Decision 1 · ${sure}`;
    scoreCard.classList.add('show');
    cardTimer = setTimeout(() => showScoreCard(null), 7000);
  }
  for (const b of scoresEl.children) {
    b.addEventListener('click', (e) => {
      e.stopPropagation();
      showScoreCard(cardKey === b.dataset.k ? null : b.dataset.k);
    });
  }
  function setScores(state) {
    scoresEl.dataset.state = typeof state === 'string' ? state : state ? 'ready' : 'none';
    showScoreCard(null);
    scoreData = {};
    for (const b of scoresEl.children) {
      const k = b.dataset.k;
      const s = state && typeof state === 'object' ? state[k] : null;
      const arc = b.querySelector('.arc');
      const num = b.querySelector('.num b');
      const bars = b.querySelectorAll('.hist i');
      if (s && Number.isFinite(s.score)) {
        const hi = (s.scale || [1, 5])[1] || 5;
        const frac = Math.min(1, Math.max(0, s.score / hi));
        arc.style.strokeDashoffset = (C * (1 - frac)).toFixed(2);
        num.textContent = s.score.toFixed(1);
        b.setAttribute('aria-label', `${k} ${s.score.toFixed(1)} out of ${hi}. Tap for why.`);
        scoreData[k] = s;
        const p = [1, 2, 3, 4, 5].map((n) => Number(s.distribution?.[n] ?? s.distribution?.[String(n)] ?? 0));
        const max = Math.max(...p, 1e-6);
        const top = p.indexOf(max);
        bars.forEach((el, i) => {
          el.style.height = `${Math.max(2, (p[i] / max) * 16).toFixed(1)}px`;
          el.classList.toggle('mode', i === top && max > 0);
        });
      } else {
        arc.style.strokeDashoffset = C.toFixed(2);
        num.textContent = '–';
        bars.forEach((el) => ((el.style.height = '2px'), el.classList.remove('mode')));
      }
    }
  }

  // ---------------- stepper ----------------
  let dotsHandler = null;
  function setSteps(n, hasReframe, onPick) {
    dotsHandler = onPick;
    const items = [...Array(n).keys()].map((i) => ({ k: i, label: String(i + 1), aria: `Step ${i + 1}` }));
    if (hasReframe) items.push({ k: 'rf', label: ICONS.reframeSm, aria: 'Reframe' });
    dotsEl.replaceChildren(
      ...items.map((it) => {
        const b = document.createElement('button');
        b.className = 'dot';
        b.dataset.k = String(it.k);
        b.setAttribute('role', 'tab');
        b.setAttribute('aria-label', it.aria);
        b.innerHTML = `<span>${it.label}</span>`;
        b.addEventListener('click', () => dotsHandler?.(it.k));
        return b;
      }),
    );
  }
  /** step: -1 overview, region index, or 'rf'. */
  function setStep(step, { kept = false, rfBusy = false } = {}) {
    body.dataset.step = String(step);
    const idx = step === 'rf' ? Infinity : step;
    for (const b of dotsEl.children) {
      const k = b.dataset.k === 'rf' ? 'rf' : Number(b.dataset.k);
      const order = k === 'rf' ? Infinity - 1 : k;
      b.classList.toggle('on', String(k) === String(step));
      b.classList.toggle('done', step !== -1 && order < idx);
      b.classList.toggle('kept', k === 'rf' && kept && step !== 'rf');
      b.classList.toggle('wait', k === 'rf' && rfBusy && step === 'rf');
      b.setAttribute('aria-selected', String(String(k) === String(step)));
    }
    let mode = 'step';
    if (step === -1) mode = 'start';
    else if (step === 'rf') mode = rfBusy ? 'busy' : 'keep';
    nextBtn.dataset.mode = mode;
    nextBtn.innerHTML =
      mode === 'start' ? `<span class="lbl">Start</span>${ICONS.next}` : mode === 'keep' || mode === 'busy' ? `${ICONS.check}<span class="lbl">Keep this angle</span>` : ICONS.next;
    nextBtn.setAttribute('aria-label', mode === 'start' ? 'Start the walkthrough' : mode === 'step' ? 'Next step' : 'Keep this angle');
  }
  const setReady = (on) => (body.dataset.ready = on ? '1' : '0');

  // ---------------- reframe preview ----------------
  const showFrame = (on) => frameEl.classList.toggle('show', on);
  function showRfNote(res) {
    if (res) {
      rfNote.querySelector('.rf-line').textContent = res.note || '';
      rfNote.querySelector('.rf-sub').textContent = res.sub || '';
    }
    rfNote.classList.toggle('show', !!res);
  }

  // ---------------- upload screen ----------------
  function setSamples(names, onPick) {
    samplesEl.replaceChildren(
      ...names.map((name) => {
        const b = document.createElement('button');
        b.className = 'sample';
        b.dataset.name = name;
        b.setAttribute('aria-label', `Sample ${name}`);
        b.innerHTML = `<img src="/samples/${name}.jpg" alt="" decoding="async" />`;
        b.addEventListener('click', () => onPick(name));
        return b;
      }),
    );
  }
  function markSample(name) {
    for (const b of samplesEl.children) b.classList.toggle('on', b.dataset.name === name);
  }
  function setUpload(state, { back = false } = {}) {
    uploadEl.dataset.state = state;
    uploadEl.dataset.back = back ? '1' : '0';
  }
  let shownPct = -1;
  function setProgress(p) {
    const v = Math.max(0, Math.min(1, p));
    uploadEl.style.setProperty('--p', v.toFixed(3));
    const pct = Math.floor(v * 100);
    if (pct !== shownPct) {
      shownPct = pct;
      pctEl.textContent = `${pct}%`;
    }
  }

  return {
    setBusy,
    setFlat,
    setMarkers,
    clearMarkers,
    placeMarkers,
    setMarkerState,
    hideMarkers,
    showNote,
    placeNote,
    setScores,
    showScoreCard,
    setSteps,
    setStep,
    setReady,
    showFrame,
    showRfNote,
    setSamples,
    markSample,
    setUpload,
    setProgress,
    dropZone,
    prevBtn,
    nextBtn,
  };
}
