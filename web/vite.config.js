import { resolve } from 'node:path';
import { defineConfig } from 'vite';

// Pages: / (lighting coach), /cam.html (live coach camera), /3d.html (3D coach, SHARP splats).
// COACH_HOST=0.0.0.0 exposes the dev server on the LAN (phone testing); API_PORT points the
// proxy at another API instance (agents test on their own port).
const API = `http://127.0.0.1:${process.env.API_PORT || 8787}`;

export default defineConfig({
  server: {
    port: Number(process.env.WEB_PORT || 5320),
    strictPort: true,
    host: process.env.COACH_HOST || 'localhost',
    allowedHosts: true,
    proxy: {
      '/api': { target: API, changeOrigin: true, ws: true },
    },
  },
  preview: { port: 5321 },
  build: {
    chunkSizeWarningLimit: 1200, // three.js + spark
    rollupOptions: {
      input: {
        main: resolve(import.meta.dirname, 'index.html'),
        cam: resolve(import.meta.dirname, 'cam.html'),
        '3d': resolve(import.meta.dirname, '3d.html'),
      },
    },
  },
});
