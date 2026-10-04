import { test, expect, type BrowserContext, type Page } from '@playwright/test';
import { signIn, USERS, apiAs } from '../e2e/helpers';
import { loadEnv } from '../../scripts/lib/env.mjs';

// A day in the field, against the BUILT app with its service worker.
//
// The sign-in token lasts one hour and is renewed over the network. An operator signs in at home, reaches the farm
// gate after it ran out, and has no network there. Before Phase 4 the app then showed the sign-in screen (nobody can
// sign in without a network), looked for the forms kept on the phone under the wrong name, and could send a waiting
// save with the public key instead of the operator's token, which the database refuses. These tests are that day.
process.env.ENV_FILE ??= '.env.stack';
const env = loadEnv() as Record<string, string>;
const API = new URL(env.SUPABASE_URL).origin;
const OP = { key: '305', phone: '0000000005' };
const GORAKHPUR = /· Gorakhpur(?! mandi)/;

/** As if the hour were over: the token kept on the phone is past its time. */
async function ageTheToken(page: Page) {
  await page.evaluate(() => {
    const raw = localStorage.getItem('grainveda-auth');
    if (!raw) throw new Error('no login kept on this phone');
    const s = JSON.parse(raw);
    s.expires_at = Math.floor(Date.now() / 1000) - 120;
    localStorage.setItem('grainveda-auth', JSON.stringify(s));
  });
}
const keptToken = (page: Page) => page.evaluate(() => (JSON.parse(localStorage.getItem('grainveda-auth') ?? 'null') as { access_token: string; expires_at: number } | null));

/** What the app keeps on the phone for offline work (IndexedDB store "cache"): the keys only. */
const keptForOffline = (page: Page) => page.evaluate(() => new Promise<string[]>((resolve, reject) => {
  const open = indexedDB.open('grainveda-offline');
  open.onerror = () => reject(open.error);
  open.onsuccess = () => {
    const db = open.result;
    if (!db.objectStoreNames.contains('cache')) { db.close(); indexedDB.deleteDatabase('grainveda-offline'); resolve([]); return; }
    const req = db.transaction('cache', 'readonly').objectStore('cache').getAllKeys();
    req.onsuccess = () => { db.close(); resolve(req.result.map(String)); };
    req.onerror = () => reject(req.error);
  };
}));

/** Sign in with a network, let the service worker take over, open the farm-gate form once: now it is kept on the phone. */
async function atHomeWithNetwork(page: Page) {
  await signIn(page, OP);
  await page.evaluate(async () => { await navigator.serviceWorker.ready; });
  await page.reload();
  await expect.poll(() => page.evaluate(() => !!navigator.serviceWorker.controller)).toBe(true);
  await page.getByTestId('slot-procurement').filter({ hasText: GORAKHPUR }).click();
  await expect(page.getByRole('button', { name: /Ram Achal/ })).toBeVisible();
}

/** A weight nobody else uses, so the database can be asked how many records carry it. */
const oddWeight = () => (150 + (Date.now() % 4000) / 100 + Math.floor(Math.random() * 9) / 1000).toFixed(3);

async function fillLot(page: Page, farmer: string, gross: string) {
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill(farmer.split(' ')[0]);
  await page.getByRole('button', { name: new RegExp(farmer) }).click();
  await page.getByLabel(/Gross weight/).fill(gross); await page.getByLabel(/^Bags/).fill('1'); await page.getByLabel(/Tare per bag/).fill('2.5');
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('11.9');
  await expect(page.getByTestId('preview-ok')).toBeVisible({ timeout: 20_000 });
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByLabel('I have checked these numbers against the lot').check();
}

/** How many records with this gross weight the database holds (service key: local stack only, never in the browser). */
async function recordsWeighing(gross: string): Promise<number> {
  const r = await fetch(`${API}/rest/v1/footprints?select=id&stage_type=eq.procurement&payload->>gross_kg=eq.${Number(gross)}`, {
    headers: { apikey: env.SUPABASE_SERVICE_ROLE_KEY, authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}` } });
  if (!r.ok) throw new Error(`count failed: ${r.status} ${await r.text()}`);
  return (await r.json() as unknown[]).length;
}

async function openOutbox(page: Page) {
  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Saved on phone' }).click();
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Saved on this phone');
}
/** Every request to the database fails at once, while the browser still believes it is online (a dead link). */
const cutTheLink = (context: BrowserContext) => context.route(`${API}/**`, (route) => route.abort('internetdisconnected'));
const mendTheLink = (context: BrowserContext) => context.unroute(`${API}/**`);

test('No network for more than an hour: the app opens from the phone, captures a lot, and sends it when the network is back', async ({ page, context }) => {
  const gross = oddWeight();
  await atHomeWithNetwork(page);

  await context.setOffline(true);
  await ageTheToken(page);
  const t0 = Date.now();
  await page.reload();                                                    // cold start: no network, the hour is over
  await expect(page.getByRole('heading', { level: 1 })).toContainText('Procurement (farm-gate)');
  console.log(`cold start with no network and a run-out token: ${Date.now() - t0} ms`);
  expect(Date.now() - t0, 'the app opens at once, it does not wait for a renewal that cannot happen').toBeLessThan(5000);

  await fillLot(page, 'Sita Devi', gross);
  const t1 = Date.now();
  await page.getByRole('button', { name: 'Save on this phone' }).click();
  await expect(page.getByTestId('queued')).toBeVisible();
  expect(Date.now() - t1, 'saving on the phone does not wait either').toBeLessThan(3000);
  expect(await recordsWeighing(gross)).toBe(0);

  await context.setOffline(false);
  await openOutbox(page);
  await expect(page.getByTestId('outbox-synced')).toContainText(/PRSDM-KNM-KH26-P-\d{4}/, { timeout: 90_000 });
  await expect(page.getByText('needs attention')).toHaveCount(0);        // never sent without the operator's own token
  expect(await recordsWeighing(gross)).toBe(1);
  const now = await keptToken(page);
  expect(now!.expires_at * 1000, 'the token was renewed by itself').toBeGreaterThan(Date.now() + 60_000);
});

test('The link is connected but dead and the hour is over: the save falls back to the phone, then goes out by itself, once', async ({ page, context }) => {
  test.setTimeout(240_000);
  const gross = oddWeight();
  await atHomeWithNetwork(page);
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill('Sita');     // the form is on screen and stays there

  await cutTheLink(context);
  await ageTheToken(page);
  await page.getByRole('button', { name: /Sita Devi/ }).click();
  await page.getByLabel(/Gross weight/).fill(gross); await page.getByLabel(/^Bags/).fill('1'); await page.getByLabel(/Tare per bag/).fill('2.5');
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('11.9');
  await expect(page.getByTestId('preview-ok')).toBeVisible({ timeout: 20_000 });   // worked out on the phone: the server could not be asked
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByLabel('I have checked these numbers against the lot').check();
  // The browser says "online", so the button says Save record. The token cannot be renewed: the save must not go out
  // with the public key, and must not be lost. It is kept on the phone.
  const t0 = Date.now();
  await page.getByRole('button', { name: 'Save record' }).click();
  await expect(page.getByTestId('queued')).toBeVisible({ timeout: 20_000 });
  console.log(`dead link, run-out token: kept on the phone after ${Date.now() - t0} ms`);

  // Long enough for the library's own renewal attempts to give up and start their one-minute pause.
  await page.waitForTimeout(32_000);
  await openOutbox(page);
  await expect(page.getByTestId('outbox-open')).toContainText('waiting');
  await expect(page.getByText('needs attention')).toHaveCount(0);
  expect(await recordsWeighing(gross)).toBe(0);

  await mendTheLink(context);
  const t1 = Date.now();
  await expect(page.getByTestId('outbox-synced')).toContainText(/PRSDM-KNM-KH26-P-\d{4}/, { timeout: 150_000 });
  console.log(`link back: sent by itself after ${Math.round((Date.now() - t1) / 1000)} s`);
  await expect(page.getByText('needs attention')).toHaveCount(0);
  expect(await recordsWeighing(gross)).toBe(1);
});

test('A link that takes requests and never answers: the form opens from the phone within seconds, the save is stopped after 30 s and kept', async ({ page, context }) => {
  test.setTimeout(240_000);
  const gross = oddWeight();
  await atHomeWithNetwork(page);

  await context.route(`${API}/**`, () => { /* taken, never answered */ });
  const t0 = Date.now();
  await page.reload();
  await expect(page.getByRole('heading', { level: 1 })).toContainText('Procurement (farm-gate)', { timeout: 40_000 });
  const opened = Date.now() - t0;
  console.log(`dead link: the form opened from the phone after ${opened} ms`);
  expect(opened, 'one wait of 8 s, then every further screen straight from the phone').toBeLessThan(14_000);
  await fillLot(page, 'Sita Devi', gross);
  const t1 = Date.now();
  await page.getByRole('button', { name: 'Save record' }).click();
  await expect(page.getByTestId('queued')).toBeVisible({ timeout: 45_000 });
  const kept = Date.now() - t1;
  console.log(`dead link: the save was stopped and kept on the phone after ${kept} ms`);
  expect(kept).toBeGreaterThan(25_000);

  await context.unroute(`${API}/**`);
  await openOutbox(page);
  await expect(page.getByTestId('outbox-synced')).toContainText(/PRSDM-KNM-KH26-P-\d{4}/, { timeout: 90_000 });
  expect(await recordsWeighing(gross)).toBe(1);
});

test('The login was ended by the server while the phone had no network: what was captured stays on the phone and is sent after signing in again', async ({ page, context }) => {
  test.setTimeout(180_000);
  const gross = oddWeight();
  await atHomeWithNetwork(page);
  const before = await keptToken(page);

  await context.setOffline(true);
  await fillLot(page, 'Sita Devi', gross);
  await page.getByRole('button', { name: 'Save on this phone' }).click();
  await expect(page.getByTestId('queued')).toBeVisible();

  // Meanwhile, at the office: every session of this person is ended (what a password reset does).
  const out = await fetch(`${API}/auth/v1/logout?scope=global`, { method: 'POST',
    headers: { apikey: env.SUPABASE_ANON_KEY, authorization: `Bearer ${before!.access_token}` } });
  expect(out.status).toBe(204);
  await ageTheToken(page);

  await context.setOffline(false);                                         // back in coverage: the renewal is refused
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible({ timeout: 60_000 });
  expect(await keptToken(page), 'the login is gone from the phone').toBeNull();
  await expect.poll(() => keptForOffline(page), { message: 'and so is everything kept for offline work' }).toEqual([]);
  expect(await recordsWeighing(gross), 'nothing was sent without a valid login').toBe(0);

  await signIn(page, OP);                                                  // signIn() clears localStorage only; the outbox is in IndexedDB
  await openOutbox(page);
  await expect(page.getByTestId('outbox-synced')).toContainText(/PRSDM-KNM-KH26-P-\d{4}/, { timeout: 60_000 });
  await expect(page.getByText('needs attention')).toHaveCount(0);
  expect(await recordsWeighing(gross)).toBe(1);
});

test('Sign out with no network signs out on this phone, after a warning, and leaves nothing behind', async ({ page, context }) => {
  await atHomeWithNetwork(page);
  expect((await keptForOffline(page)).some((k) => k.includes(':farmers:')), 'the farmer list is kept for offline work').toBe(true);

  await context.setOffline(true);
  const asked: string[] = [];
  page.once('dialog', (d) => { asked.push(d.message()); void d.dismiss(); });
  await page.getByRole('button', { name: 'Sign out' }).click();
  expect(asked.join(' ')).toContain('cannot sign in again until the network is back');
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();          // answered "no": still signed in
  expect((await keptForOffline(page)).length, 'and nothing was wiped').toBeGreaterThan(0);

  page.once('dialog', (d) => void d.accept());
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible({ timeout: 10_000 });
  expect(await keptToken(page)).toBeNull();
  await expect.poll(() => keptForOffline(page)).toEqual([]);
  await page.reload();                                                     // and it stays signed out
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await context.setOffline(false);
});

test('Lost phone: once the person is deactivated, the phone gets nothing more and erases its offline copy at the next contact', async ({ page, browser }) => {
  test.setTimeout(180_000);
  await atHomeWithNetwork(page);
  const kept = await keptForOffline(page);
  expect(kept.some((k) => k.includes(':farmers:'))).toBe(true);

  const office = await browser.newContext();
  const manager = await office.newPage();
  await signIn(manager, USERS.cm);
  const api = await apiAs(manager);
  const person = (await api.rows('app_users')).find((u) => String(u.phone ?? '').endsWith(OP.phone));
  expect(person, 'the Client Manager sees the operator').toBeTruthy();
  try {
    const off = await api.update('app_users', `id=eq.${person!.id}`, { active: false });
    expect(off.ok, JSON.stringify(off.data)).toBe(true);

    await page.reload();                                                   // the lost phone is opened, with a network
    await expect(page.getByText('no GrainVeda user is linked')).toBeVisible();
    await expect.poll(() => keptForOffline(page), { message: 'the farmer list and forms are erased from the phone' }).toEqual([]);
    const phoneApi = await apiAs(page);
    for (const table of ['footprints', 'farmers', 'scopes', 'ledger']) expect(await phoneApi.rows(table), table).toHaveLength(0);
  } finally {
    const on = await api.update('app_users', `id=eq.${person!.id}`, { active: true });
    expect(on.ok, JSON.stringify(on.data)).toBe(true);
    await office.close();
  }
  await page.reload();
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();          // active again: the same login works
});

test('A save whose answer is lost on the way back is not made twice', async ({ page, context }) => {
  const gross = oddWeight();
  await atHomeWithNetwork(page);
  await fillLot(page, 'Sita Devi', gross);
  // The request reaches the database; the answer never reaches the phone (a weak signal does exactly this).
  let lost = 0;
  await context.route(`${API}/rest/v1/footprints*`, async (route) => {
    if (route.request().method() !== 'POST' || lost > 0) { await route.continue(); return; }
    lost++;
    await route.fetch();
    await route.abort('connectionreset');
  });
  await page.getByRole('button', { name: 'Save record' }).click();
  await expect(page.getByTestId('queued')).toBeVisible();                 // the phone cannot know it was stored, and keeps it
  expect(lost).toBe(1);
  expect(await recordsWeighing(gross), 'the database did store it').toBe(1);
  await openOutbox(page);
  await expect(page.getByTestId('outbox-synced')).toContainText(/PRSDM-KNM-KH26-P-\d{4}/, { timeout: 60_000 });
  await expect(page.getByText('needs attention')).toHaveCount(0);
  expect(await recordsWeighing(gross), 'sent again from the phone, found by its save id, not made a second time').toBe(1);
});

test('The record went through but its photo did not: the photo waits on the phone and is attached when the network is back', async ({ page, context }) => {
  const gross = oddWeight();
  const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
  await atHomeWithNetwork(page);
  await page.getByLabel(/Photo evidence/).setInputFiles({ name: `bags-${gross}.png`, mimeType: 'image/png', buffer: PNG });
  await fillLot(page, 'Sita Devi', gross);
  await context.route(`${API}/storage/v1/**`, (route) => route.abort('internetdisconnected'));
  await page.getByRole('button', { name: 'Save record' }).click();
  await expect(page.getByTestId('queued')).toBeVisible();
  expect(await recordsWeighing(gross)).toBe(1);
  await openOutbox(page);
  await expect(page.getByTestId('outbox-open')).toContainText('its photo is still to be sent', { timeout: 30_000 });

  await context.unroute(`${API}/storage/v1/**`);
  await expect(page.getByTestId('outbox-synced')).toContainText(/PRSDM-KNM-KH26-P-\d{4}/, { timeout: 60_000 });
  await page.getByTestId('outbox-synced').getByRole('link', { name: /PRSDM-KNM-KH26-P-\d{4}/ }).first().click();
  await expect(page.getByText('file matches its fingerprint')).toBeVisible();
  expect(await recordsWeighing(gross)).toBe(1);
});
