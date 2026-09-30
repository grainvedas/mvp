import { test, expect } from '@playwright/test';
import { signIn } from '../e2e/helpers';
import { loadEnv } from '../../scripts/lib/env.mjs';

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
