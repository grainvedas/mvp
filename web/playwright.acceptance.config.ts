import { defineConfig, devices } from '@playwright/test';

// THE ACCEPTANCE RUN (PRD §12): chain tests T1–T5 through the real screens, on a phone-sized browser, against a
// DEPLOYED build. No dev server is started: the target is whatever ACCEPTANCE_URL serves.
//
//   staging (the run that counts):
//     ACCEPTANCE_URL=https://<staging address>  npx playwright test -c playwright.acceptance.config.ts
//     reads ../.env.local (the staging project's URL + public key) and ../.env.demo-logins (demo passwords)
//   rehearsal on the local stack:
//     ACCEPTANCE_URL=http://127.0.0.1:4173 ENV_FILE=.env.stack GV_LOGINS_FILE=.env.demo-logins.stack \
//       npx playwright test -c playwright.acceptance.config.ts        (with `npx vite preview --mode stack` running)
//
// It records practice lots, so e2e/acceptance.setup.ts refuses to start if the database says it is production, or if
// the deployed build talks to another database than the one in the env file.
// Results: the list on screen, web/test-results/acceptance.json (for scripts/release_gate.mjs) and an HTML report.
const target = process.env.ACCEPTANCE_URL;
if (!target) throw new Error('Set ACCEPTANCE_URL to the deployed address, e.g. ACCEPTANCE_URL=https://grainveda-staging.example');
process.env.ENV_FILE ??= '.env.local';
process.env.GV_LOGINS_FILE ??= '.env.demo-logins';

export default defineConfig({
  testDir: './e2e',
  grep: /\bT[1-5]: /,
  timeout: 420_000,
  expect: { timeout: 20_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,                                  // a retry would hide a flaky chain: the criterion is green, twice, without help
  globalSetup: './e2e/acceptance.setup.ts',
  metadata: { target, run: process.env.ACCEPTANCE_RUN ?? '' },
  reporter: [['list'], ['json', { outputFile: process.env.ACCEPTANCE_REPORT ?? 'test-results/acceptance.json' }],
    ['html', { open: 'never', outputFolder: 'playwright-report/acceptance' }]],
  use: { baseURL: target, trace: 'retain-on-failure', screenshot: 'only-on-failure', ...devices['Pixel 7'] },
});
