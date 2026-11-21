// Finale: "Powered by Gemini 4". A sticky stage shows Gemini's real reading of one frame
// (regions, labels, notes), then the headline; the footer follows and ends on ink.
// Usage: const { destroy } = mountFinale(document.querySelector('#finale'));
import './finale.css';
import { mountReading, READING, smooth, T } from './reading.js';
import { mountWordmark } from './wordmark.js';

/** Hackathon name for the footer credit line; leave empty to omit it. */
export const HACKATHON = '';

const ICON_IOS = '/assets/ios-AppIcon-1024.png';
const ICON_MAC = '/assets/mac-AppIcon-1024.png';
const CREDITS =
  'Flower photos: Wikimedia Commons contributors (Emőke Dénes, Cephas, Niepokój Zbigniew, shirleybolling2005), CC BY-SA 4.0 / CC BY 2.0';

const REVEAL_AT = 0.8; // headline in once the reading has settled
const HIDE_BELOW = 0.7; // hysteresis: it resets only once the notes are back

const clamp01 = (v) => Math.min(1, Math.max(0, v));
const MODEL = READING.model.replace(/^.*\//, '');
const SECONDS = (READING.ms / 1000).toFixed(1);

function letters(text, startMs = 0) {
  let i = 0;
  return [...text]
    .map((ch) => {
      if (ch === ' ') return ' ';
      const s = `<span class="fn-ch"><span class="fn-ch__in" style="--i:${i};--d:${startMs}ms">${ch}</span></span>`;
      i++;
      return s;
    })
    .join('');
}

function footerHTML() {
  const built = HACKATHON ? `Built with Gemini 4 · ${HACKATHON}` : 'Built with Gemini 4';
  return `
    <div class="ff__wrap">
      <p class="ff__mark" role="img" aria-label="Heliocam"><canvas aria-hidden="true"></canvas></p>
      <ul class="ff__apps" role="list">
        <li class="ff__app">
          <img class="ff__icon ff__icon--ios" src="${ICON_IOS}" width="64" height="64" alt="" loading="lazy" decoding="async" />
          <p class="ff__name">Heliocam <span>· iPhone</span></p>
        </li>
        <li class="ff__app">
          <img class="ff__icon" src="${ICON_MAC}" width="64" height="64" alt="" loading="lazy" decoding="async" />
          <p class="ff__name">Heliocam Studio <span>· Mac</span></p>
        </li>
      </ul>
      <div class="ff__base">
        <p class="ff__built">${built}</p>
        <p class="ff__credits">${CREDITS}</p>
        <p class="ff__year">© 2026</p>
      </div>
    </div>`;
}

/**
 * Mounts the finale (sticky frame reading + headline) and the footer into `sectionEl`.
 * Returns { destroy }.
 */
export function mountFinale(sectionEl) {
  sectionEl.classList.add('finale');
  const motion = matchMedia('(prefers-reduced-motion: reduce)');

  const summary = READING.regions
    .map((r, i) => `<li>${READING.labels?.[i] ?? r.id} (${r.tag}): ${r.note}</li>`)
    .join('');

  const pin = document.createElement('div');
  pin.className = 'finale__pin';
  pin.innerHTML = `
    <div class="finale__stage">
      <figure class="finale__figure">
        <div class="finale__reading" aria-hidden="true"></div>
        <figcaption class="fn-sr">Gemini 4's reading of a group photo:<ul>${summary}</ul></figcaption>
      </figure>
      <div class="finale__pool" aria-hidden="true"></div>
      <div class="finale__copy">
        <h2 class="finale__heading" aria-label="Powered by Gemini 4">
          <span class="finale__eyebrow" aria-hidden="true">${letters('Powered by', 0)}</span>
          <span class="finale__title" aria-hidden="true">${letters('Gemini 4', 200)}</span>
        </h2>
        <p class="finale__lede">It reads every frame, finds what matters, and tells you how to fix it.</p>
        <p class="finale__meta">${MODEL} · read in ${SECONDS} s</p>
      </div>
    </div>`;
  const footer = document.createElement('footer');
  footer.className = 'ff';
  footer.innerHTML = footerHTML();
  sectionEl.append(pin, footer);

  const stage = pin.querySelector('.finale__stage');
  const pool = pin.querySelector('.finale__pool');
  const copy = pin.querySelector('.finale__copy');
  const reading = mountReading(pin.querySelector('.finale__reading'));

  let destroyed = false;
  let raf = 0;
  let revealed = false;

  function setRevealed(on) {
    if (on === revealed) return;
    revealed = on;
    copy.classList.toggle('is-revealed', on);
  }

  function update() {
    raf = 0;
    if (destroyed) return;
    const vh = window.innerHeight;

    if (motion.matches) {
      // Still frame: every region and note shown, the headline above it.
      reading.update({ p: T.end + 0.02, e: 1, settle: 0, still: true });
      setRevealed(true);
      return;
    }

    const sr = sectionEl.getBoundingClientRect();
    const e = clamp01((vh - sr.top) / vh);
    const pr = pin.getBoundingClientRect();
    const span = pr.height - stage.offsetHeight;
    const p = span > 0 ? clamp01(-pr.top / span) : pr.top <= 0 ? 1 : 0;
    reading.update({ p, e });
    pool.style.opacity = smooth(T.settle[0], T.settle[1], p).toFixed(3);
    copy.style.setProperty('--fn-p', p.toFixed(4));

    if (p >= REVEAL_AT) setRevealed(true);
    else if (p < HIDE_BELOW) setRevealed(false);
  }

  const schedule = () => {
    if (!raf) raf = requestAnimationFrame(update);
  };
  const onResize = () => {
    reading.layout();
    schedule();
  };
  const onMotion = () => {
    sectionEl.classList.toggle('finale--static', motion.matches);
    requestAnimationFrame(() => {
      reading.layout();
      schedule();
    });
  };

  // Only track scroll while the section is near the viewport.
  const io = new IntersectionObserver(
    ([entry]) => {
      if (entry.isIntersecting) {
        window.addEventListener('scroll', schedule, { passive: true });
        schedule();
      } else {
        window.removeEventListener('scroll', schedule);
      }
    },
    { rootMargin: '50% 0px' },
  );

  const wordmark = mountWordmark(footer.querySelector('.ff__mark canvas'));

  onMotion();
  io.observe(sectionEl);
  window.addEventListener('resize', onResize);
  motion.addEventListener('change', onMotion);
  update();

  return {
    destroy() {
      destroyed = true;
      cancelAnimationFrame(raf);
      io.disconnect();
      window.removeEventListener('scroll', schedule);
      window.removeEventListener('resize', onResize);
      motion.removeEventListener('change', onMotion);
      reading.destroy();
      wordmark.destroy();
      pin.remove();
      footer.remove();
      sectionEl.classList.remove('finale', 'finale--static');
    },
  };
}
