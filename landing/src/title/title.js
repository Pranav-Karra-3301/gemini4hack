// The section title: one big, clean line (Google Sans Flex 700, solid frost). Importance comes
// from size alone: no gradient, glow or shadow. Usage: el.prepend(sectionTitle(TITLES.lidar)).
import './title.css';

export function sectionTitle(text, { tag = 'h2', className = '' } = {}) {
  const h = document.createElement(tag);
  h.className = `sec-title ${className}`.trim();
  h.textContent = text;
  return h;
}
