// Gemini's live agent trace beside the phone viewfinder. Same interface as StepTrack
// (src/scenes.js): the page calls render(t) every frame with t in seconds since the loop
// started, and reset() when the loop wraps or the section leaves.
import { h, deco, reducedMotion } from './util.js';
import './story.css';

// Header copy until the chapter carries its own `traceLabel` in config.js.
const LABEL = 'Agent trace · live';
// Lines fade out this many seconds before the loop wraps.
const CLEAR = 0.5;
const MARKS = { in: '→', call: '←' };
const SPARK =
  '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 0c.4 4.4 3.6 7.6 8 8-4.4.4-7.6 3.6-8 8-.4-4.4-3.6-7.6-8-8 4.4-.4 7.6-3.6 8-8z"/></svg>';
// Segments set in Google Sans Code: JSON, camelCase identifiers, function calls, model ids.
const CODE = /^[{[]|^[a-z]+[A-Z]\w*$|^[a-z_]+\(|^[a-z][a-z0-9]*(-[a-z0-9.]+)+$/;

/** Splits "a: 1, b: \"x, y\"" on top-level commas (quotes and brackets kept whole). */
function splitArgs(s) {
  const out = [];
  let depth = 0;
  let quote = '';
  let cur = '';
  for (const ch of s) {
    if (quote) {
      cur += ch;
      if (ch === quote) quote = '';
      continue;
    }
    if (ch === '"' || ch === "'") quote = ch;
    else if ('{[('.includes(ch)) depth++;
    else if ('}])'.includes(ch)) depth--;
    else if (ch === ',' && depth === 0) {
      out.push(cur.trim());
      cur = '';
      continue;
    }
    cur += ch;
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

/** name({ k: v, … }) as spans: the name in Gemini blue, each argument wraps as one unit. */
function callMarkup(text) {
  const m = /^([A-Za-z_][\w.]*)\(\s*(\{?)\s*([\s\S]*?)\s*(\}?)\s*\)$/.exec(text.trim());
  const code = h('span', 'st-code st-call');
  if (!m) {
    code.textContent = text;
    return code;
  }
  const [, name, open, body, close] = m;
  code.append(h('span', 'st-call__fn', name), h('span', 'st-call__p', `(${open}${open ? ' ' : ''}`));
  const args = splitArgs(body);
  args.forEach((arg, i) => {
    const unit = h('span', 'st-call__arg');
    const kv = /^([\w$]+)\s*:\s*([\s\S]*)$/.exec(arg);
    if (kv) unit.append(h('span', 'st-call__k', kv[1]), h('span', 'st-call__p', ': '), h('span', 'st-call__v', kv[2]));
    else unit.append(h('span', 'st-call__v', arg));
    const last = i === args.length - 1;
    unit.append(h('span', 'st-call__p', last ? `${close ? ' ' : ''}${close})` : ','));
    code.append(unit);
    if (!last) code.append(' ');
  });
  if (!args.length) code.append(h('span', 'st-call__p', `${close})`));
  return code;
}

/** "a · b · c" with code-like segments in Google Sans Code. */
function segments(cls, text) {
  const el = h('span', cls);
  text.split(' · ').forEach((seg, i) => {
    if (i) el.append(h('span', 'st-tl__sep', ' · '));
    el.append(CODE.test(seg) ? h('span', 'st-code', seg) : document.createTextNode(seg));
  });
  return el;
}

function lineMarkup(line) {
  const li = h('li', `st-tl st-tl--${line.dir}`);
  li.append(deco(h('span', 'st-tl__t st-code', line.t.toFixed(2))));
  const mark = deco(h('span', 'st-tl__mark'));
  if (line.dir === 'think') mark.innerHTML = SPARK;
  else mark.textContent = MARKS[line.dir] || '·';
  const body = h('div', 'st-tl__body');
  if (line.dir === 'call') body.append(callMarkup(line.text));
  else if (line.dir === 'think') body.append(h('span', 'st-tl__text st-code', line.text));
  else body.append(segments('st-tl__text', line.text));
  if (line.meta) body.append(segments('st-tl__meta', line.meta));
  li.append(mark, body);
  return li;
}

export class AgentTrace {
  constructor(listEl, chapter) {
    this.el = listEl;
    this.lines = chapter.trace || [];
    this.loop = chapter.loop || 0;
    this.clearAt = this.loop > CLEAR ? this.loop - CLEAR : Infinity;
    this.reduced = reducedMotion();

    const panel = h('div', 'st-trace__panel');
    const head = h('div', 'st-trace__head');
    head.append(deco(h('span', 'st-trace__dot')), h('span', '', chapter.traceLabel || LABEL));
    const list = h('ol', 'st-trace__lines');
    list.setAttribute('role', 'log');
    list.setAttribute('aria-live', 'off');
    this.items = this.lines.map(lineMarkup);
    list.append(...this.items);
    panel.append(head, list);
    listEl.classList.add('st-trace');
    if (this.reduced) listEl.classList.add('is-static');
    listEl.replaceChildren(panel);
    if (chapter.traceNote) listEl.append(h('p', 'st-trace__note', chapter.traceNote));

    // CSS loops (the live dot, the shimmer) only run while the panel is on screen.
    this.io = new IntersectionObserver((entries) => listEl.classList.toggle('is-off', !entries.at(-1).isIntersecting));
    this.io.observe(listEl);

    this.idx = -2;
    this.clearing = false;
    if (this.reduced) this.setIndex(this.items.length - 1);
    else this.reset();
  }

  render(t) {
    if (this.reduced) return;
    let idx = -1;
    for (let i = 0; i < this.lines.length; i++) if (t >= this.lines[i].t) idx = i;
    this.setIndex(idx);
    const clearing = t >= this.clearAt;
    if (clearing !== this.clearing) {
      this.clearing = clearing;
      this.el.classList.toggle('is-clearing', clearing);
    }
  }

  setIndex(idx) {
    if (idx === this.idx) return;
    this.idx = idx;
    this.items.forEach((li, i) => {
      const on = i <= idx;
      li.classList.toggle('is-in', on);
      li.classList.toggle('is-newest', i === idx);
      if (on) li.dataset.age = Math.min(idx - i, 4);
      else delete li.dataset.age;
    });
  }

  reset() {
    if (this.reduced) return;
    this.clearing = false;
    this.el.classList.remove('is-clearing');
    this.setIndex(-1);
  }

  destroy() {
    this.io.disconnect();
    this.el.classList.remove('st-trace', 'is-static', 'is-off', 'is-clearing');
    this.el.replaceChildren();
  }
}
