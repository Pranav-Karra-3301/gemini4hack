// The live loop: one real phone, pinned, while three Gemini models take a beat each as you
// scroll. hydrogen turns the dials, Decision pulses the viewfinder's edge every second, and the
// voice says the only sentence. One centered column: title, model chip, phone, the beat's output
// line (always in the same spot under the phone), dots. The light behind it changes colour per
// model (Unicorn scene `v5-model`, variable `model`, or a CSS light until it's exported).
//
//   const live = mountLive(sectionEl);   // live.destroy()
import { LIVE, SCENES, TITLES } from '../config.js';
import { phoneEl, phoneScreen, swapScreen } from '../phone/phone.js';
import { sectionTitle } from '../title/title.js';
import { mountBackdrop, reducedMotion } from '../unicorn.js';
import './live.css';

const WAVE_BARS = 18;
const MODEL_MS = 600;

const clamp = (v) => Math.max(0, Math.min(1, v));
const easeInOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

function markup() {
  const { dials, viewfinder } = LIVE.regions;
  const [hydrogen, decision, voice] = LIVE.beats;
  const region = (r) => `top:${r.top}%;height:${r.height}%`;
  const c = (beat) => `--c:${beat.model.color}`;
  const bars = Array.from({ length: WAVE_BARS }, (_, i) => {
    const x = (i + 0.5) / WAVE_BARS;
    // A spoken phrase: two humps, louder on the first.
    const amp = 0.18 + 0.82 * Math.abs(Math.sin(Math.PI * x * 2.1)) * (1 - 0.45 * x);
    return `<i style="--i:${i};--amp:${amp.toFixed(2)}"></i>`;
  }).join('');
  const overlays = `
    <i class="live__dials" style="${region(dials)};${c(hydrogen)}"></i>
    <i class="live__edge" style="${region(viewfinder)};${c(decision)}"></i>`;
  const call = (b) => `<p class="live__out" style="${c(b)}"><b>${b.call}</b><span>${b.args}</span></p>`;
  const stage = `
    <div class="live__stage">
      <div class="backdrop live__backdrop" aria-hidden="true">
        <div class="backdrop__css live__light">${LIVE.beats.map((b) => `<i style="${c(b)}"></i>`).join('')}</div>
      </div>
      <div class="live__center">
        <ul class="live__models" aria-label="Models">
          ${LIVE.beats.map((b) => `<li class="chip chip--model" style="${c(b)}"><i></i>${b.model.id}<span class="chip__role">${b.model.role}</span></li>`).join('')}
        </ul>
        <div class="live__outs">
          ${call(hydrogen)}
          ${call(decision)}
          <p class="live__out live__out--voice" style="${c(voice)}">
            <span class="live__wave" aria-hidden="true">${bars}</span>
            <span class="live__quote">${voice.quote}</span>
          </p>
        </div>
        <ol class="live__dots" aria-hidden="true">${LIVE.beats.map((b) => `<li style="${c(b)}"></li>`).join('')}</ol>
      </div>
    </div>`;
  return { stage, overlays };
}

export function mountLive(el) {
  el.classList.add('live');
  const { stage, overlays } = markup();
  el.innerHTML = stage;
  el.dataset.beat = '0';

  // The title heads the column and stays there for all three beats.
  const center = el.querySelector('.live__center');
  center.prepend(sectionTitle(TITLES.live, { className: 'live__title' }));

  // One real phone, between the model chip and the output line; the overlays sit on its
  // screen, in % of the screenshot.
  const screenOf = (b) => LIVE.screens[LIVE.beats[b].screen];
  const phone = phoneEl({ src: screenOf(0), alt: '', className: 'live__phone' });
  phoneScreen(phone).insertAdjacentHTML('beforeend', overlays);
  center.querySelector('.live__models').after(phone);
  // Decode the other screens now, so the first swap is a crossfade, not a wait.
  for (const src of new Set(Object.values(LIVE.screens))) {
    const img = new Image();
    img.src = src;
  }

  const still = reducedMotion();
  const backdrop = mountBackdrop(el.querySelector('.live__backdrop'), SCENES.model, { vars: { model: 0 } });

  // The scene's `model` glides to the beat's value over 600 ms, like the CSS light's crossfade.
  let model = 0;
  let tween = 0;
  const glideTo = (target) => {
    cancelAnimationFrame(tween);
    if (still) return backdrop.setVar('model', (model = target));
    const from = model;
    const t0 = performance.now();
    const step = (now) => {
      const t = clamp((now - t0) / MODEL_MS);
      model = from + (target - from) * easeInOut(t);
      backdrop.setVar('model', model);
      if (t < 1) tween = requestAnimationFrame(step);
    };
    tween = requestAnimationFrame(step);
  };

  // The beat is a function of how far the pinned stage has scrolled: a third each.
  let beat = 0;
  let queued = false;
  const update = () => {
    queued = false;
    const r = el.getBoundingClientRect();
    const vh = innerHeight;
    if (r.bottom < 0 || r.top > vh) return;
    const p = clamp(-r.top / Math.max(1, r.height - vh));
    const next = Math.min(LIVE.beats.length - 1, Math.floor(p * LIVE.beats.length));
    if (next === beat) return;
    beat = next;
    el.dataset.beat = String(beat);
    glideTo(beat);
    swapScreen(phone, screenOf(beat), { ms: still ? 0 : 600 });
  };
  const queue = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(update);
  };
  addEventListener('scroll', queue, { passive: true });
  addEventListener('resize', queue);
  update();

  // The pulse and the waveform only run while the stage is on screen.
  const io = new IntersectionObserver(([e]) => el.classList.toggle('is-on', e.isIntersecting), { threshold: 0 });
  io.observe(el);

  return {
    destroy() {
      removeEventListener('scroll', queue);
      removeEventListener('resize', queue);
      cancelAnimationFrame(tween);
      io.disconnect();
      backdrop.destroy();
      el.replaceChildren();
    },
  };
}
