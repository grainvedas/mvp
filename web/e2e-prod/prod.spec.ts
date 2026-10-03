import { test, expect } from '@playwright/test';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { signIn, signOut, USERS, SCOPES, openSlot, reviewAndSave } from '../e2e/helpers';
import { loadEnv } from '../../scripts/lib/env.mjs';

// Runs against the BUILT app served by scripts/serve-dist.mjs, which behaves like the production host: dist/_headers
// is sent (the Content-Security-Policy is enforced by the browser), every route answers with the app, and /index.html
// redirects to /.

// A sealed code from the local stack (service key from .env.stack: local only, never in the browser).
async function anySealedCode(): Promise<string> {
  process.env.ENV_FILE ??= '.env.stack';
  const env = loadEnv() as Record<string, string>;
  const r = await fetch(`${env.SUPABASE_URL}/rest/v1/qr_seals?select=qr_code&limit=1`, {
    headers: { apikey: env.SUPABASE_SERVICE_ROLE_KEY, authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}` } });
  const rows = await r.json() as { qr_code: string }[];
  if (!rows.length) throw new Error('no sealed lot on the stack: run the e2e suite first');
  return rows[0].qr_code;
}

test('Public verify page: first load under 200 KB and visible in under 3 s on throttled 3G', async ({ page, context }) => {
  const code = await anySealedCode();
  const cdp = await context.newCDPSession(page);
  await cdp.send('Network.enable');
  await cdp.send('Network.setCacheDisabled', { cacheDisabled: true });
  // Lighthouse "slow 4G / fast 3G" profile: 150 ms RTT, 1.6 Mbps down, 750 kbps up
  await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: 150, downloadThroughput: 1.6e6 / 8, uploadThroughput: 750e3 / 8 });
  let bytes = 0;
  cdp.on('Network.loadingFinished', (e: { encodedDataLength: number }) => { bytes += e.encodedDataLength; });
  const t0 = Date.now();
  await page.goto(`/verify/${code}`);
  await expect(page.getByTestId('public-journey')).toBeVisible();
  const ms = Date.now() - t0;
  console.log(`public page: ${ms} ms, ${Math.round(bytes / 1024)} KB transferred (incl. the journey API call)`);
  expect(ms).toBeLessThan(3000);
  expect(bytes).toBeLessThan(200 * 1024);
});

test('Offline start: after one online sign-in the app opens with no network and still captures a lot', async ({ page, context }) => {
  await signIn(page, { key: '305', phone: '0000000005' });
  await page.evaluate(async () => { await navigator.serviceWorker.ready; });
  await page.reload();                                                    // now controlled by the worker
  await expect.poll(() => page.evaluate(() => !!navigator.serviceWorker.controller)).toBe(true);
  await page.getByTestId('slot-procurement').filter({ hasText: /· Gorakhpur(?! mandi)/ }).click();
  await expect(page.getByRole('button', { name: /Ram Achal/ })).toBeVisible();

  await context.setOffline(true);
  await page.reload();                                                    // cold start with no network
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Procurement (farm-gate)');
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill('Sita');
  await page.getByRole('button', { name: /Sita Devi/ }).click();
  await page.getByLabel(/Gross weight/).fill('150'); await page.getByLabel(/^Bags/).fill('1'); await page.getByLabel(/Tare per bag/).fill('2.5');
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('11.9');
  await expect(page.getByTestId('preview-ok')).toContainText('147.5 kg');
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save on this phone' }).click();
  await expect(page.getByTestId('queued')).toBeVisible();

  await context.setOffline(false);
  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Saved on phone' }).click();
  await expect(page.getByTestId('outbox-synced')).toContainText(/PRSDM-KNM-KH26-P-\d{4}/, { timeout: 60_000 });
  await expect(page.getByTestId('outbox-synced')).toContainText('147.5 kg');
});

test('Production headers: the security policy is sent on every route and names only this project', async ({ request }) => {
  const env = loadEnv() as Record<string, string>;
  const api = new URL(env.VITE_SUPABASE_URL ?? env.SUPABASE_URL).origin;
  for (const path of ['/', '/verify/GV-000000000000', '/work/some/deep/route']) {
    const r = await request.get(path);
    expect(r.status(), path).toBe(200);
    const h = r.headers();
    const csp = h['content-security-policy'] ?? '';
    expect(csp, path).toContain("default-src 'self'");
    expect(csp).toContain("script-src 'self'");
    expect(csp).not.toContain("'unsafe-eval'");
    expect(csp.match(/script-src[^;]*/)![0]).not.toContain("'unsafe-inline'");
    expect(csp).toContain(`connect-src 'self' ${api}`);
    expect(csp).toContain("frame-ancestors 'none'");
    expect(csp).toContain("object-src 'none'");
    expect(h['x-content-type-options']).toBe('nosniff');
    expect(h['x-frame-options']).toBe('DENY');
    expect(h['referrer-policy']).toBe('strict-origin-when-cross-origin');
    expect(h['strict-transport-security']).toContain('max-age=31536000');
    expect(h['cache-control'] ?? '', 'the page itself is never cached for long').not.toContain('immutable');
  }
  const html = await (await request.get('/')).text();
  expect(html, 'no inline script in the page: the policy allows none').not.toMatch(/<script(?![^>]*\bsrc=)[^>]*>/);
  const asset = html.match(/\/assets\/[^"]+\.js/)![0];
  expect((await request.get(asset)).headers()['cache-control']).toBe('public, max-age=31536000, immutable');
  expect((await request.get('/sw.js')).headers()['cache-control']).toBe('no-cache');
  const redirect = await request.get('/index.html', { maxRedirects: 0 });
  expect(redirect.status()).toBe(307);                                     // what Cloudflare does; the service worker copes
  expect((await request.get('/_headers')).headers()['content-type']).toContain('text/html');   // the rules file itself is not served
});

test('Under the enforced security policy the whole journey works: sign in, record with a photo, labels, public page', async ({ page }) => {
  test.setTimeout(180_000);
  const violations: string[] = [];
  await page.addInitScript(() => {
    document.addEventListener('securitypolicyviolation', (e) => console.error(`CSP-VIOLATION ${e.violatedDirective} ${e.blockedURI}`));
  });
  page.on('console', (m) => { if (m.type() === 'error' && /CSP-VIOLATION|Content Security Policy|Refused to/.test(m.text())) violations.push(m.text()); });

  await signIn(page, USERS.procurement);
  await openSlot(page, 'procurement', SCOPES.siddharthnagar);
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill('Sita');
  await page.getByRole('button', { name: /Sita Devi/ }).click();
  await page.getByLabel(/Gross weight/).fill('150'); await page.getByLabel(/^Bags/).fill('1'); await page.getByLabel(/Tare per bag/).fill('2.5');
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('11.9');
  await page.getByLabel(/Photo evidence/).setInputFiles({ name: 'bags.png', mimeType: 'image/png',
    buffer: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64') });
  const code = await reviewAndSave(page, /PRSDM-KNM-KH26-P-\d{4}/);
  await page.getByRole('link', { name: `Open ${code}` }).click();
  await expect(page.getByText('file matches its fingerprint')).toBeVisible();        // storage download allowed by connect-src
  await signOut(page);

  const sealed = await anySealedCode();
  await signIn(page, USERS.qr);
  await page.goto(`/labels/${sealed}`);
  await expect(page.getByTestId('label-sheet').locator('.label img').first()).toBeVisible();   // QR as a data: image
  await page.goto(`/verify/${sealed}`);
  await expect(page.getByTestId('public-journey')).toBeVisible();
  await page.getByLabel('Language').selectOption('hi');
  await expect(page.getByTestId('public-journey')).toContainText('इस लॉट की यात्रा');
  expect(violations, 'requests or scripts blocked by the Content-Security-Policy').toEqual([]);
});

test('First visit, then no network: the app shell opens from the phone (host redirects /index.html)', async ({ page, context }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await page.evaluate(async () => { await navigator.serviceWorker.ready; });
  await expect.poll(() => page.evaluate(() => !!navigator.serviceWorker.controller)).toBe(true);   // claimed without a reload
  await context.setOffline(true);
  await page.reload();                                                    // the very first load handled by the worker, offline
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await page.goto('/work/anything/procurement');                          // a deep link offline also gets the app
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await context.setOffline(false);
});

test('No secret of the env file is in the built app: only the URL and the public key', async () => {
  // The build reads the same file that holds the service key, the database URL and the monitor token (.env.stack here,
  // .env.production at go-live). Only VITE_* / NEXT_PUBLIC_* values may end up in the files a browser downloads.
  const env = loadEnv() as Record<string, string>;
  const dist = join(dirname(fileURLToPath(import.meta.url)), '..', 'dist');
  const files = (d: string): string[] => readdirSync(d).flatMap((n) => { const p = join(d, n); return statSync(p).isDirectory() ? files(p) : [p]; });
  const all = files(dist).map((f) => ({ f, text: readFileSync(f, 'utf8') }));
  expect(all.length).toBeGreaterThan(5);
  const secrets = { SUPABASE_SERVICE_ROLE_KEY: env.SUPABASE_SERVICE_ROLE_KEY, LEDGER_CHECK_TOKEN: env.LEDGER_CHECK_TOKEN, SUPABASE_DB_URL: env.SUPABASE_DB_URL };
  for (const [name, value] of Object.entries(secrets)) {
    expect(value, `${name} is set in the env file, so the check means something`).toBeTruthy();
    const found = all.filter((x) => x.text.includes(value)).map((x) => x.f.replace(dist, 'dist'));
    expect(found, `${name} found in the built app`).toEqual([]);
  }
  expect(all.some((x) => x.text.includes(env.VITE_SUPABASE_ANON_KEY)), 'the public key is in the build (it must be)').toBe(true);
});
