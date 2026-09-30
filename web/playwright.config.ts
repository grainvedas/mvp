import { defineConfig, devices } from '@playwright/test';

// End-to-end against the LOCAL STACK (local-stack/up.sh + scripts/create_demo_logins.mjs with ENV_FILE=.env.stack).
// Vite runs in "stack" mode, which loads ../.env.stack (local keys only).
export default defineConfig({
  testDir: './e2e',
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list']],
  use: { baseURL: 'http://127.0.0.1:5173', trace: 'retain-on-failure', screenshot: 'only-on-failure', ...devices['Pixel 7'] },
  webServer: { command: 'npx vite --mode stack', url: 'http://127.0.0.1:5173', reuseExistingServer: true, timeout: 60_000 },
});
