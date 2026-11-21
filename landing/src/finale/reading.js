// Gemini's real reading of a frame (out/regions_img-1491.json, copied verbatim beside this file).
// The photo appears dimmed, a scan line passes, then each region box draws in with its label tag,
// and its note types in beside it, one at a time. finale.js feeds pin progress p (0..1).
import data from './img-1491.regions.json';

export const READING = data;
export const PHOTO = '/showcase/img-1491.webp';
const ASPECT = 4 / 3; // 1600x1200

const N = data.regions.length;
export const T = {
  scan: [0.02, 0.14],
  first: 0.14,
  end: 0.72, // last note has started typing well before this
  settle: [0.75, 0.85],
};
const EACH = (T.end - T.first) / N;
const CH_MS = 15; // typing speed

const BLUE = '#4C8DFF';
const FROST = 'rgba(238, 243, 255, 0.62)';

const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const clamp01 = (v) => clamp(v, 0, 1);
export const smooth = (a, b, v) => {
  const t = clamp01((v - a) / (b - a));
  return t * t * (3 - 2 * t);
};
const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);
const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const SVG = 'http://www.w3.org/2000/svg';

export function mountReading(root) {
  const regions = data.regions.map((r, i) => ({
    ...r,
    label: cap(data.labels?.[i] || r.id),
    focus: r.tag === 'focus',
  }));

  root.classList.add('fr');
  root.innerHTML = `
    <div class="fr__frame">
      <img class="fr__photo" src="${PHOTO}" width="1600" height="1200" alt="" decoding="async" />
      <div class="fr__scan"></div>
    </div>
    <p class="fr__status"><i></i><span>Gemini 4 · reading the frame</span></p>
    <svg class="fr__lines" xmlns="${SVG}"></svg>
    ${regions
      .map(
        (r) => `
      <p class="fr__tag ${r.focus ? 'is-focus' : 'is-remove'}">
        <span class="fr__label">${esc(r.label)}</span><span class="fr__kind">${esc(r.tag)}</span>
      </p>
      <p class="fr__note ${r.focus ? 'is-focus' : 'is-remove'}">
        <span class="fr__ghost">${esc(r.note)}</span><span class="fr__typed"></span>
      </p>`,
      )
      .join('')}`;

  const frame = root.querySelector('.fr__frame');
  const photo = root.querySelector('.fr__photo');
  const scan = root.querySelector('.fr__scan');
  const status = root.querySelector('.fr__status');
  const statusText = status.querySelector('span');
  const svg = root.querySelector('.fr__lines');
  const tags = [...root.querySelectorAll('.fr__tag')];
  const notes = [...root.querySelectorAll('.fr__note')];

  const items = regions.map((r, i) => {
    const box = document.createElementNS(SVG, 'rect');
    box.setAttribute('class', `fr__box ${r.focus ? 'is-focus' : 'is-remove'}`);
    box.setAttribute('pathLength', '1');
    box.setAttribute('stroke', r.focus ? BLUE : FROST);
    const lead = document.createElementNS(SVG, 'path');
    lead.setAttribute('class', 'fr__lead');
    lead.setAttribute('pathLength', '1');
    lead.setAttribute('stroke', r.focus ? BLUE : FROST);
    const dot = document.createElementNS(SVG, 'circle');
    dot.setAttribute('r', '2.5');
    dot.setAttribute('fill', r.focus ? BLUE : FROST);
    svg.append(box, lead, dot);
    return {
      r,
      box,
      lead,
      dot,
      tag: tags[i],
      note: notes[i],
      typed: notes[i].querySelector('.fr__typed'),
      on: false, // note triggered
      t0: 0,
      shown: -1, // chars currently rendered
    };
  });

  let mode = 'side';
  let raf = 0;
  let instant = false;
  let done = false;

  // ---------- layout (resize / fonts) ----------
  function layout() {
    const W = root.clientWidth;
    const H = root.clientHeight;
    if (!W || !H) return;
    const padX = clamp(W * 0.05, 20, 64);
    const padY = clamp(H * 0.09, 48, 96);
    mode = W >= 900 ? 'side' : 'list';
    root.classList.toggle('fr--list', mode === 'list');

    const noteW = mode === 'side' ? clamp(W * 0.17, 220, 260) : 0;
    const reach = 36; // frame edge -> note
    let fw;
    let fh;
    if (mode === 'side') {
      fw = Math.min((H - padY * 2) * ASPECT, W - padX * 2 - (noteW + reach) * 2, 1120);
      fh = fw / ASPECT;
    } else {
      fw = W - padX * 2;
      fh = fw / ASPECT;
      if (fh > H * 0.4) {
        fh = H * 0.4;
        fw = fh * ASPECT;
      }
    }
    const fx = (W - fw) / 2;
    const fy = mode === 'side' ? (H - fh) / 2 : padY;
    Object.assign(frame.style, { left: `${fx}px`, top: `${fy}px`, width: `${fw}px`, height: `${fh}px` });
    status.style.left = `${fx}px`;
    status.style.top = `${fy - 34}px`;

    svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
    svg.setAttribute('width', W);
    svg.setAttribute('height', H);

    // Boxes, inset so the stroke stays on the photo.
    const ins = 1.5;
    for (const it of items) {
      const b = it.r.box;
      const x = fx + clamp(b.x, 0, 1) * fw + ins;
      const y = fy + clamp(b.y, 0, 1) * fh + ins;
      const w = Math.max(8, Math.min(b.w, 1 - b.x) * fw - ins * 2);
      const h = Math.max(8, Math.min(b.h, 1 - b.y) * fh - ins * 2);
      it.px = { x, y, w, h, cx: x + w / 2, cy: y + h / 2 };
      const rx = Math.min(10, w / 4, h / 4);
      for (const [k, v] of Object.entries({ x, y, width: w, height: h, rx })) it.box.setAttribute(k, v.toFixed(1));
    }

    // Label tag sits on the box's top edge (inside if the box touches the top),
    // nudged right past any other box edge it would sit on.
    for (const it of items) {
      const { x, y } = it.px;
      const tw = it.tag.offsetWidth;
      const th = it.tag.offsetHeight;
      let tx = clamp(x, fx + 4, fx + fw - tw - 4);
      let ty = y - th - 6;
      if (ty < fy + 4) {
        ty = y + 6;
        tx = clamp(x + 6, fx + 4, fx + fw - tw - 4);
      }
      for (const o of items) {
        if (o === it) continue;
        const b = o.px;
        const vert = ty < b.y + b.h && ty + th > b.y;
        const right = b.x + b.w;
        if (vert && tx < right + 6 && tx + tw > right && right - tx < tw / 2) tx = right + 6;
      }
      tx = Math.min(tx, fx + fw - tw - 4);
      it.tag.style.transform = `translate3d(${tx.toFixed(1)}px, ${ty.toFixed(1)}px, 0)`;
    }

    // Notes.
    if (mode === 'side') {
      const sides = { l: [], r: [] };
      for (const it of items) {
        it.side = (it.r.box.x + it.r.box.w / 2) < 0.4 ? 'l' : 'r';
        it.note.style.width = `${noteW}px`;
        sides[it.side].push(it);
      }
      const top = padY * 0.5;
      const bot = H - padY * 0.5;
      for (const list of Object.values(sides)) {
        list.sort((a, b) => a.px.cy - b.px.cy);
        let y = top;
        for (const it of list) {
          it.nh = it.note.offsetHeight;
          it.ny = Math.max(y, clamp(it.px.cy - 25, top, bot - it.nh));
          y = it.ny + it.nh + 14;
        }
        // If the stack overflows the bottom, push it back up.
        let over = list.length ? list[list.length - 1].ny + list[list.length - 1].nh - bot : 0;
        for (let i = list.length - 1; i >= 0 && over > 0; i--) {
          const prevBottom = i ? list[i - 1].ny + list[i - 1].nh + 14 : top;
          const room = list[i].ny - prevBottom;
          list[i].ny -= over;
          over = Math.max(0, over - room);
        }
      }
      for (const it of items) {
        const { x, w, cy } = it.px;
        const right = it.side === 'r';
        const nx = right ? fx + fw + reach : fx - reach - noteW;
        it.note.style.transform = `translate3d(${nx.toFixed(1)}px, ${it.ny.toFixed(1)}px, 0)`;
        const sx = right ? x + w : x;
        const ex = right ? nx - 8 : nx + noteW + 8;
        const ey = it.ny + 25; // first line of the note
        const kx = right ? fx + fw + 14 : fx - 14; // elbow just outside the frame
        const d = Math.abs(ey - cy) < 1 ? `M${sx},${cy}H${ex}` : `M${sx},${cy}H${kx}L${kx + (right ? 10 : -10)},${ey}H${ex}`;
        it.lead.setAttribute('d', d);
        it.dot.setAttribute('cx', sx);
        it.dot.setAttribute('cy', cy);
      }
    } else {
      let y = fy + fh + 20;
      for (const it of items) {
        it.note.style.width = `${fw}px`;
        it.note.style.transform = `translate3d(${fx.toFixed(1)}px, ${y.toFixed(1)}px, 0)`;
        y += it.note.offsetHeight + 10;
        it.lead.setAttribute('d', '');
      }
    }
  }

  // ---------- typing ----------
  function renderTyping(now) {
    let busy = false;
    for (const it of items) {
      const full = it.r.note;
      const n = !it.on ? 0 : instant ? full.length : Math.min(full.length, Math.floor((now - it.t0) / CH_MS));
      if (n !== it.shown) {
        it.shown = n;
        it.typed.textContent = full.slice(0, n);
        it.note.classList.toggle('is-typing', it.on && n < full.length);
      }
      if (it.on && n < full.length) busy = true;
    }
    return busy;
  }
  function loop(now) {
    raf = renderTyping(now) ? requestAnimationFrame(loop) : 0;
  }
  function kick() {
    if (!raf) raf = requestAnimationFrame(loop);
  }

  // ---------- scroll state ----------
  /** p: pin progress 0..1, e: entry 0..1, settle: override (reduced motion), still: no typing animation. */
  function update({ p, e = 1, settle, still = false }) {
    instant = still;
    const q = settle ?? smooth(T.settle[0], T.settle[1], p);
    const appear = smooth(0.2, 0.95, e);
    root.style.setProperty('--fr-appear', appear.toFixed(3));
    root.style.setProperty('--fr-settle', q.toFixed(3));
    photo.style.filter = `brightness(${(0.72 - 0.4 * q).toFixed(3)}) saturate(${(0.9 - 0.3 * q).toFixed(3)})`;

    const sc = (p - T.scan[0]) / (T.scan[1] - T.scan[0]);
    scan.style.opacity = sc > 0 && sc < 1 ? Math.sin(Math.PI * sc).toFixed(3) : '0';
    scan.style.setProperty('--scan', clamp01(sc).toFixed(4));

    let newlyOn = false;
    let read = 0;
    items.forEach((it, i) => {
      const s = clamp01((p - (T.first + i * EACH)) / EACH);
      const k = smooth(0, 0.3, s);
      it.box.style.strokeDashoffset = (1 - k).toFixed(4);
      it.box.style.opacity = k > 0 ? (1 - 0.7 * q).toFixed(3) : '0';
      const t = smooth(0.18, 0.32, s) * (1 - q);
      it.tag.style.opacity = t.toFixed(3);
      const l = smooth(0.28, 0.42, s);
      it.lead.style.strokeDashoffset = (1 - l).toFixed(4);
      it.lead.style.opacity = l > 0 ? (0.7 * (1 - q)).toFixed(3) : '0';
      it.dot.style.opacity = (smooth(0.26, 0.3, s) * (1 - q)).toFixed(3);
      const want = it.on ? s > 0.26 : s >= 0.36;
      if (want !== it.on) {
        it.on = want;
        it.t0 = performance.now();
        if (want) newlyOn = true;
      }
      it.note.classList.toggle('is-on', it.on);
      it.note.style.opacity = it.on ? (1 - q).toFixed(3) : '0';
      if (s >= 1) read++;
    });
    const label = read >= N ? `Gemini 4 · ${N} regions found` : 'Gemini 4 · reading the frame';
    if (statusText.textContent !== label) statusText.textContent = label;
    status.classList.toggle('is-done', read >= N);
    status.style.opacity = (smooth(0.0, 0.06, p) * (1 - q)).toFixed(3);

    if (instant || newlyOn || items.some((it) => it.on !== it.shown > 0)) kick();
    if (instant) renderTyping(performance.now());
  }

  const onFonts = () => !done && layout();
  document.fonts?.ready.then(onFonts);
  layout();

  return {
    layout,
    update,
    destroy() {
      done = true;
      cancelAnimationFrame(raf);
      root.classList.remove('fr', 'fr--list');
      root.innerHTML = '';
    },
  };
}
