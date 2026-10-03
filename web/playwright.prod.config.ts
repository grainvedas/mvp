import { defineConfig, devices } from '@playwright/test';

// Production build checks against the LOCAL STACK: the service worker (offline start) and the public page budget
// (PRD §9: verify page < 3 s on 3G, < 200 KB first load). Builds with `vite build --mode stack` and serves the result.
export default defineConfig({
  testDir: './e2e-prod',
  timeout: 120_000,
  expect: { timeout: 15_000 },
  workers: 1,
  reporter: [['list']],
  use: { baseURL: 'http://127.0.0.1:4173', trace: 'retain-on-failure', screenshot: 'only-on-failure', ...devices['Pixel 7'] },
  // scripts/serve-dist.mjs behaves like the production host: it sends dist/_headers (so the Content-Security-Policy is
  // enforced), answers every route with the app, and redirects /index.html to /.
  webServer: { command: 'npx vite build --mode stack && node scripts/serve-dist.mjs', url: 'http://127.0.0.1:4173', reuseExistingServer: false, timeout: 180_000 },
});
