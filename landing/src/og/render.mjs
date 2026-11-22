// Renders the link-preview files from src/og/demo.html into public/:
//   og.mp4         1200 x 630, 30 fps, 9 s loop, H.264, no audio (og:video; Messages autoplays it)
//   og.jpg         1200 x 630 still (og:image, twitter:image)
//   og-square.jpg  600 x 600 still (the second og:image, for square cards)
//
// Needs the dev server (`npm run dev`), Google Chrome, ffmpeg and playwright-core. playwright-core
// isn't a dependency of the page; install it anywhere and point at it:
//   npm i --no-save playwright-core     (or PLAYWRIGHT_CORE=/path/to/playwright-core/index.mjs)
//   node src/og/render.mjs [--frames 0,90,180] [--stills-only] [--video-only]
// Env: OG_URL (default http://localhost:5330/src/og/demo.html), CHROME (path to Chrome).
// --frames writes only those frames as PNGs to $TMPDIR/og-frames, to check a moment quickly.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const { chromium } = await import(process.env.PLAYWRIGHT_CORE || 'playwright-core');
const URL_ = process.env.OG_URL || 'http://localhost:5330/src/og/demo.html';
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PUBLIC = fileURLToPath(new URL('../../public/', import.meta.url));
const SCALE = 2; // capture at 2x and downsample: smoother point sprites, cleaner encode

const args = process.argv.slice(2);
const flag = (f) => args.includes(f);
const pick = args.includes('--frames') ? args[args.indexOf('--frames') + 1].split(',').map(Number) : null;

const browser = await chromium.launch({
  executablePath: CHROME,
  headless: true,
  args: ['--use-angle=metal', '--ignore-gpu-blocklist', '--hide-scrollbars'],
});

async function open(width, height, mode) {
  const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: SCALE });
  page.on('pageerror', (e) => {
    throw new Error(`page error: ${e.message}`);
  });
  page.on('console', (m) => m.type() === 'error' && console.error('[page]', m.text()));
  await page.goto(`${URL_}?${mode}`, { waitUntil: 'networkidle' });
  await page.evaluate(() => window.og.ready);
  return page;
}

const ff = (...a) => execFileSync('ffmpeg', ['-v', 'error', '-y', ...a], { stdio: 'inherit' });

try {
  if (pick || !flag('--stills-only')) {
    const page = await open(1200, 630, 'render');
    const dir = pick ? join(tmpdir(), 'og-frames') : mkdtempSync(join(tmpdir(), 'og-'));
    if (pick) execFileSync('mkdir', ['-p', dir]);
    const total = pick ? Math.max(...pick) + 1 : (await page.evaluate(() => window.og.FPS * window.og.DURATION));
    for (let n = 0; n < total; n++) {
      await page.evaluate((n) => window.og.frame(n), n);
      if (!pick || pick.includes(n)) {
        const name = String(n).padStart(4, '0');
        await page.screenshot({ path: join(dir, `${name}.png`), animations: 'allow' });
      }
      if (!pick && n % 30 === 0) process.stdout.write(`frame ${n}/${total}\r`);
    }
    await page.close();
    if (pick) {
      console.log(`frames in ${dir}`);
    } else {
      const out = join(PUBLIC, 'og.mp4');
      ff(
        '-framerate', '30', '-i', join(dir, '%04d.png'),
        '-vf', 'scale=1200:630:flags=lanczos,format=yuv420p',
        '-c:v', 'libx264', '-profile:v', 'high', '-level', '4.0', '-preset', 'veryslow', '-crf', '24',
        '-tune', 'film', '-movflags', '+faststart', '-an', out,
      );
      rmSync(dir, { recursive: true, force: true });
      console.log(`og.mp4 ${(statSync(out).size / 1e6).toFixed(2)} MB`);
    }
  }

  if (!pick && !flag('--video-only')) {
    for (const [file, w, h, size, opts] of [
      ['og.jpg', 1200, 630, '1200:630', { focus: [0.5, 0.62], seam: 0.445 }],
      ['og-square.jpg', 900, 900, '600:600', { focus: [0.485, 0.5], seam: 0.447 }],
    ]) {
      const page = await open(w, h, 'still');
      await page.evaluate((o) => window.og.poster(o), opts);
      const png = join(tmpdir(), `og-still-${w}x${h}.png`);
      await page.screenshot({ path: png });
      await page.close();
      const out = join(PUBLIC, file);
      // WhatsApp drops og:image previews over ~300 KB: the best JPEG quality that fits under that
      for (let q = 2; q <= 12; q++) {
        ff('-i', png, '-vf', `scale=${size}:flags=lanczos`, '-q:v', String(q), out);
        if (statSync(out).size < 290_000) break;
      }
      rmSync(png, { force: true });
      console.log(`${file} ${(statSync(out).size / 1e3).toFixed(0)} KB`);
    }
  }
} finally {
  await browser.close();
}
