import { defineConfig, devices } from '@playwright/test';

// The first day of a pilot, from an EMPTY local stack (local-stack/fresh_start.sh first). One test, laptop size:
// this is the set-up an admin and HR do at a desk. Not part of the default suite: it needs the stack emptied, and the
// default suite needs the demo data.
export default defineConfig({
  testDir: './e2e-fresh',
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list']],
  use: { baseURL: 'http://127.0.0.1:5173', actionTimeout: 20_000, trace: 'retain-on-failure', screenshot: 'only-on-failure', ...devices['Desktop Chrome'], viewport: { width: 1366, height: 768 } },
  webServer: { command: 'npx vite --mode stack', url: 'http://127.0.0.1:5173', reuseExistingServer: true, timeout: 60_000 },
});
