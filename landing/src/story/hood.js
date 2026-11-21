// "Under the hood": the app's stages as a two-lane pipeline (On the iPhone | Gemini 4)
// around a vertical spine. A glowing bead follows the scroll down the spine and lights
// each stage as it passes: warm white in the phone lane, Gemini blue in the Gemini lane.
import { HOOD } from '../config.js';
import { h, deco, clamp, reducedMotion } from './util.js';
import './story.css';

// Lane names until HOOD carries its own `lanes` in config.js.
const LANES = { phone: 'On the iPhone', gemini: 'Gemini 4' };
const ANCHOR = 34; // px from a card's top to its connector (the middle of the name line)
const GAP = 20; // px between two cards in the same lane
const READ = 0.58; // the bead follows this line of the viewport (fraction of its height)
const DESKTOP = '(min-width: 768px)';

export function mountHood(el) {
  const lanes = { ...LANES, ...(HOOD.lanes || {}) };
  const stages = HOOD.stages;
  const reduced = reducedMotion();
  const desktop = matchMedia(DESKTOP);

  const root = h('div', 'st-hood');
  if (reduced) root.classList.add('is-static');
  const inner = h('div', 'container');

  const copy = h('div', 'copy st-hood__copy');
  copy.append(h('p', 'eyebrow', HOOD.label), h('h2', 'h2', HOOD.title), h('p', 'lede st-hood__lede', HOOD.lede));

  const pipe = h('div', 'st-pipe');
  const heads = deco(h('div', 'st-pipe__heads'));
  for (const lane of ['phone', 'gemini']) {
    const head = h('p', `st-pipe__head st-pipe__head--${lane}`);
    head.append(h('span', 'st-pipe__dot'), lanes[lane]);
    heads.append(head);
  }

  const track = h('div', 'st-pipe__track');
  const spine = deco(h('div', 'st-spine'));
  const spineLit = h('div', 'st-spine__lit');
  spine.append(spineLit);
  const bead = deco(h('div', 'st-bead'));
  const tail = h('span', 'st-bead__tail');
  bead.append(h('span', 'st-bead__halo'), tail, h('span', 'st-bead__core'));

  const list = h('ol', 'st-pipe__list');
  const cards = stages.map((s, i) => {
    const card = h('li', `st-card st-card--${s.lane === 'gemini' ? 'gemini' : 'phone'}`);
    card.append(deco(h('span', 'st-card__conn')), deco(h('span', 'st-card__idx st-code', String(i + 1).padStart(2, '0'))));
    const body = h('div', 'st-card__inner');
    const top = h('div', 'st-card__top');
    top.append(h('h3', 'st-card__name', s.name));
    if (s.status) top.append(h('span', 'st-card__status', s.status));
    const tech = h('ul', 'st-card__tech');
    for (const t of s.tech.split(' · ')) tech.append(h('li', 'st-chip st-code', t));
    body.append(h('p', 'st-card__lane', lanes[s.lane]), top, h('p', 'st-card__what', s.what), tech);
    card.append(body);
    return card;
  });
  list.append(...cards);
  track.append(spine, bead, list);
  pipe.append(heads, track);
  inner.append(copy, pipe);
  root.append(inner);
  el.append(root);

  // ---- layout: desktop staggers the lanes (a card starts part-way down the previous one),
  // mobile is one column. Anchors are where each connector meets the spine.
  let height = 0;
  let anchors = [];
  const layout = () => {
    const hs = cards.map((c) => c.offsetHeight);
    if (desktop.matches) {
      const bottom = { phone: -Infinity, gemini: -Infinity };
      const tops = [];
      stages.forEach((s, i) => {
        let top = i ? tops[i - 1] + Math.max(96, hs[i - 1] * 0.56) : 0;
        top = Math.max(top, bottom[s.lane] + GAP);
        tops[i] = top;
        bottom[s.lane] = top + hs[i];
      });
      height = Math.max(bottom.phone, bottom.gemini);
      anchors = tops.map((t) => t + ANCHOR);
      cards.forEach((c, i) => (c.style.transform = `translateY(${tops[i]}px)`));
      track.style.height = `${height}px`;
    } else {
      cards.forEach((c) => (c.style.transform = ''));
      track.style.height = '';
      height = track.offsetHeight;
      anchors = cards.map((c) => c.offsetTop + ANCHOR);
    }
    lit = -1;
    kick();
  };

  // ---- the bead: eases toward the reading line, its tail stretches with speed.
  let y = 0;
  let raf = 0;
  let last = 0;
  let lit = -1;
  let active = false;
  const target = () => clamp(innerHeight * READ - track.getBoundingClientRect().top, 0, height);
  const apply = (v) => {
    const s = clamp(0.3 + Math.abs(v) / 1400, 0.3, 1.6) * (v < -1 ? -1 : 1);
    bead.style.transform = `translate3d(0, ${y.toFixed(1)}px, 0)`;
    tail.style.transform = `scaleY(${s.toFixed(3)})`;
    spineLit.style.transform = `scaleY(${height ? (y / height).toFixed(4) : 0})`;
    let n = 0;
    while (n < anchors.length && y >= anchors[n] - 2) n++;
    if (n === lit) return;
    lit = n;
    cards.forEach((c, i) => c.classList.toggle('is-lit', i < n));
    root.dataset.bead = stages[Math.max(0, n - 1)].lane;
    root.classList.toggle('is-done', n === cards.length && y >= height - 1);
  };
  const frame = (now) => {
    raf = 0;
    const dt = Math.min(0.05, (now - last) / 1000 || 1 / 60);
    last = now;
    const to = target();
    const prev = y;
    y += (to - y) * (1 - Math.exp(-dt * 7));
    if (Math.abs(to - y) < 0.3) y = to;
    apply((y - prev) / dt);
    if (y !== to) raf = requestAnimationFrame(frame);
  };
  function kick() {
    if (reduced || !active || raf) return;
    last = performance.now();
    raf = requestAnimationFrame(frame);
  }

  const ro = new ResizeObserver(() => layout());
  ro.observe(pipe);
  cards.forEach((c) => ro.observe(c));
  desktop.addEventListener('change', layout);

  let io = null;
  if (reduced) {
    cards.forEach((c) => c.classList.add('is-lit'));
  } else {
    root.dataset.bead = stages[0].lane;
    io = new IntersectionObserver((entries) => {
      const e = entries.at(-1);
      active = e.isIntersecting;
      if (active) {
        addEventListener('scroll', kick, { passive: true });
        kick();
      } else {
        removeEventListener('scroll', kick);
        cancelAnimationFrame(raf);
        raf = 0;
      }
    });
    io.observe(track);
  }
  layout();

  return {
    destroy() {
      io?.disconnect();
      ro.disconnect();
      desktop.removeEventListener('change', layout);
      removeEventListener('scroll', kick);
      cancelAnimationFrame(raf);
      root.remove();
    },
  };
}
