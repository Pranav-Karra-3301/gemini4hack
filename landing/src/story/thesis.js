// The thesis under the hero: "Image analysis describes a picture. Heliocam takes one."
// A warm light rises behind the second sentence; below it, a comparison where a light
// sweeps left to right on scroll entry and settles on the Heliocam column.
import { THESIS } from '../config.js';
import { h, deco, reducedMotion } from './util.js';
import './story.css';

export function mountThesis(el) {
  const { line, rows, labels } = THESIS;
  const reduced = reducedMotion();

  const root = h('div', 'st-thesis');
  if (reduced) root.classList.add('is-static');
  const inner = h('div', 'container');

  // Every sentence but the last is the muted "before"; the last one is lit.
  const title = h('h2', 'st-thesis__line');
  line.slice(0, -1).forEach((s) => title.append(h('span', 'st-thesis__a', s), ' '));
  const lit = h('span', 'st-thesis__b');
  lit.append(deco(h('span', 'st-thesis__sun')), deco(h('span', 'st-thesis__horizon')), h('span', 'st-thesis__b-text', line.at(-1)));
  title.append(lit);

  const cmp = h('div', 'st-cmp');
  cmp.setAttribute('role', 'table');
  cmp.setAttribute('aria-label', `${labels.a} · ${labels.b}`);
  cmp.style.setProperty('--rows', rows.length + 1);
  const sweep = deco(h('div', 'st-cmp__sweep'));
  cmp.append(deco(h('div', 'st-cmp__pool')), sweep);

  const row = (cls) => {
    const r = h('div', `st-cmp__row ${cls || ''}`.trim());
    r.setAttribute('role', 'row');
    return r;
  };
  const cell = (cls, text, role, label) => {
    const c = h('span', cls, text);
    c.setAttribute('role', role);
    if (label) c.dataset.label = label;
    return c;
  };

  const head = row('st-cmp__row--head');
  const headB = cell('st-cmp__h st-cmp__h--b', labels.b, 'columnheader');
  head.append(cell('st-cmp__k', '', 'columnheader'), cell('st-cmp__h st-cmp__h--a', labels.a, 'columnheader'), headB);
  cmp.append(head);
  const rowEls = rows.map((r, i) => {
    const rEl = row();
    rEl.style.setProperty('--i', i);
    rEl.append(
      cell('st-cmp__k', r.k, 'rowheader'),
      cell('st-cmp__a', r.a, 'cell', labels.a),
      cell('st-cmp__b', r.b, 'cell', labels.b),
    );
    cmp.append(rEl);
    return rEl;
  });

  inner.append(title, cmp);
  root.append(inner);
  el.append(root);

  // The sweep ends centred on the Heliocam column (measured, so it follows the grid).
  const aim = () => {
    const w = sweep.offsetWidth;
    cmp.style.setProperty('--sweep-to', `${(headB.offsetLeft + headB.offsetWidth / 2 - w / 2).toFixed(0)}px`);
  };

  let io = null;
  if (reduced) {
    for (const t of [title, cmp, ...rowEls]) t.classList.add('is-lit');
  } else {
    io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (!e.isIntersecting) continue;
          if (e.target === cmp) aim();
          e.target.classList.add('is-lit');
          io.unobserve(e.target);
        }
      },
      { rootMargin: '0px 0px -18% 0px', threshold: 0.3 },
    );
    // Desktop lights the table at once; mobile (rows stacked) lights each row as it arrives.
    for (const t of [title, cmp, ...rowEls]) io.observe(t);
  }

  return {
    destroy() {
      io?.disconnect();
      root.remove();
    },
  };
}
