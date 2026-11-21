// Small DOM and motion helpers shared by the story modules (thesis, trace).

export const reducedMotion = () => matchMedia('(prefers-reduced-motion: reduce)').matches;

/** Creates an element with an optional class name and text (always textContent, never HTML). */
export function h(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text != null) el.textContent = text;
  return el;
}

/** Marks an element as decoration so screen readers skip it. */
export function deco(el) {
  el.setAttribute('aria-hidden', 'true');
  return el;
}

export const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
