import { defineConfig } from 'vite';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const publicDir = fileURLToPath(new URL('./public', import.meta.url));

// Dev only: a scene JSON that hasn't been dropped in yet answers 204 (empty, not JSON)
// instead of 404, so the page's availability check falls back without a console error.
// In production the Worker's SPA fallback serves text/html, which the check also rejects.
const quietMissingScenes = {
  name: 'quiet-missing-scenes',
  configureServer(server) {
    server.middlewares.use((req, res, next) => {
      const path = (req.url || '').split('?')[0];
      if (/^\/scenes\/.+\.json$/.test(path) && !existsSync(publicDir + decodeURIComponent(path))) {
        res.statusCode = 204;
        return res.end();
      }
      next();
    });
  },
};

// appType 'mpa' makes missing files 404 instead of falling back to index.html,
// so a scene JSON that hasn't been dropped in yet is detected as missing.
export default defineConfig({
  appType: 'mpa',
  plugins: [quietMissingScenes],
  server: { port: 5330, strictPort: true },
});
