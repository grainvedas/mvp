// Migration 52 (Veda, 15 Oct 2026: the operator-stages brief, release 5: C1 Procurement, C2 Collection Batch, A13), on a
// 527 px screen. The Client Manager turns on, for an active scope, the questions where / GPS / who delivered and the
// price and payment. Procurement weighs a lot at a collection point: the farmer card, the GPS typed key by key (split
// only when the box is left), an agent named, a UPI payment with its transaction ID; the farmer's receipt. A second lot
// is paid later, in cash. Then, with no network, the Collection Batch takes the lots of one place (two places are
// refused at once, in plain words), works out the villages and the loss on re-weighing, and is saved on the phone; it
// syncs when the network is back. The journey forward runs from a farmer's lot to its batch. Every rule is the
// database's (tests/46_procurement_batch.sql); the phone's mirror says the same (tests/procurement_batch.test.ts).
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, apiAs, openSlot, verifyIncoming, reviewAndSave, fillWhere, USERS, SCOPES, pickFarmer } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const uniq = () => String(Date.now()).slice(-6);
const CLIENT = '00000000-0000-4000-8000-000000000201';
const CODE = /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?P-\d{4}/;

/** Scope 06 back as the other tests expect it: no price, no compulsory where/GPS/who (seed 09). Run whatever happened. */
test.afterAll(async ({ browser }) => {
  const page = await browser.newPage();
  await signIn(page, USERS.cm);
  const api = await apiAs(page);
  await api.update('scopes', `id=eq.${SCOPES.bansiBatch}`, { record_price: false, procurement_details_required: false });
  for (const p of await api.rows('collection_points', `name=like.e2e52*&active=eq.true`)) await api.update('collection_points', `id=eq.${p.id}`, { active: false });
  await page.close();
});

async function newPoint(page: Page, name: string) {
  const api = await apiAs(page);
  const r = await api.insert('collection_points', { client_id: CLIENT, name, kind: 'centre', district: 'Siddharthnagar' });
  expect(r.ok, JSON.stringify(r.data)).toBe(true);
  return String((r.data as { id: string }[])[0].id);
}

/** Where the scope records the price (left on by the test before, whatever its result), a price, payment pending. */
async function payIfAsked(page: Page) {
  if (!(await page.getByLabel(/^Price per quintal/).count())) return;
  await page.getByLabel(/^Price per quintal/).fill('3500');
  await page.getByLabel(/^Payment/).selectOption('pending');
}

async function weigh(page: Page, farmer: RegExp, gross: string) {
  await pickFarmer(page, farmer);
  await expect(page.getByTestId('farmer-card')).toBeVisible();                 // GI land, sold this season, practice, GI area
  await page.getByLabel(/Gross weight/).fill(gross);
  await page.getByLabel(/^Bags/).fill('2');
  await page.getByLabel(/Tare per bag/).fill('1');
  for (const [i, m] of [[1, '12'], [2, '12.2'], [3, '12.1']] as const) await page.getByLabel(`Moisture (3 readings) ${i}`).fill(m);
}

test('C1: the Client Manager turns the questions and the price on; a lot at a collection point, paid by UPI, with its receipt', async ({ page }) => {
  test.setTimeout(240_000);
  const u = uniq();
  await signIn(page, USERS.cm);
  const point = await newPoint(page, `e2e52 Bansi centre ${u}`);
  await page.goto(`/scopes/${SCOPES.bansiBatch}`);
  await expect(page.getByTestId('proc-settings')).toBeVisible();              // also on an active scope
  if (!(await page.getByTestId('ps-details').isChecked())) await page.getByTestId('ps-details').check();
  await expect(page.getByTestId('ps-details')).toBeChecked();
  await page.getByTestId('ps-price').check();
  await expect(page.getByTestId('ps-price')).toBeChecked();
  await expect(page.getByTestId('ps-price')).toBeEnabled();
  await expectNoSideScroll(page);
  const api = await apiAs(page);
  expect((await api.rows('scopes', `id=eq.${SCOPES.bansiBatch}`))[0]).toMatchObject({ record_price: true, procurement_details_required: true });
  await signOut(page);

  await signIn(page, USERS.procurement);
  await openSlot(page, 'procurement', SCOPES.bansiBatch);
  await weigh(page, /Mohan Lal/, '102');
  // where, the GPS and who delivered are asked now, and the price and the payment
  const waiting = page.locator('.alert.info', { hasText: 'GPS where the lot was weighed' });
  await expect(waiting).toBeVisible();
  await expect(waiting).toContainText('Price per quintal');
  await page.getByTestId('where').selectOption(point);
  await page.getByTestId('gps-lat').pressSequentially('27.21, 82.95');      // typed key by key: not split while typing
  await expect(page.getByTestId('gps-lng')).toHaveValue('');
  await page.getByTestId('gps-lat').blur();
  await expect(page.getByTestId('gps-lat')).toHaveValue('27.21');
  await expect(page.getByTestId('gps-lng')).toHaveValue('82.95');
  await page.getByLabel(/^Delivered by/).selectOption('agent');
  await page.getByLabel(/^Price per quintal/).fill('3500');
  await page.getByLabel(/^Payment/).selectOption('paid');
  await page.getByLabel(/^Paid by/).selectOption('upi');
  await expect(page.getByTestId('preview-error')).toContainText('Name the agent who delivered the lot.');
  await page.getByLabel(/^Agent's name/).fill('Ramesh');
  await expect(page.getByTestId('preview-error')).toContainText('Give the transaction ID of the payment.');
  await page.getByLabel(/^Transaction ID/).fill(`UPI-E2E-${u}`);
  await expect(page.getByTestId('preview-ok')).toContainText('100 kg');
  await expectNoSideScroll(page);
  const lot = await reviewAndSave(page, CODE);
  // the farmer's receipt
  await expect(page.getByTestId('receipt-offer')).toBeVisible();
  await page.getByTestId('open-receipt').click();
  const receipt = page.getByTestId('receipt');
  await expect(page.getByTestId('receipt-code')).toHaveText(lot);
  await expect(page.getByTestId('receipt-net')).toContainText('100 kg');
  await expect(page.getByTestId('receipt-amount')).toContainText('3,500');     // 3,500 ₹/quintal × 1 quintal
  await expect(page.getByTestId('receipt-paid')).toContainText(`UPI-E2E-${u}`);
  await expect(receipt.locator('[data-receipt="where"]')).toContainText(`e2e52 Bansi centre ${u}`);
  await expect(receipt.locator('[data-receipt="by"]')).toContainText('An agent (Ramesh)');
  await expectNoSideScroll(page);
  // the record keeps the payment apart: the record page shows it to the person who recorded it
  await page.getByRole('link', { name: lot }).click();
  await expect(page.getByTestId('payment-panel')).toHaveAttribute('data-status', 'paid');
  await expect(page.locator('[data-computed="collection_point"]')).toContainText(`e2e52 Bansi centre ${u}`);

  // a second lot, its payment pending, paid later in cash
  await openSlot(page, 'procurement', SCOPES.bansiBatch);
  await weigh(page, /Sita Devi/, '152');
  await fillWhere(page, point);
  await page.getByLabel(/^Price per quintal/).fill('3400');
  await page.getByLabel(/^Payment/).selectOption('pending');
  const later = await reviewAndSave(page, CODE);
  await page.getByRole('link', { name: later }).click();
  await expect(page.getByTestId('payment-panel')).toHaveAttribute('data-status', 'pending');
  await page.getByTestId('pay-mark').click();
  await page.getByTestId('pay-mode').selectOption('cash');
  await page.getByTestId('pay-save').click();
  await expect(page.getByTestId('payment-panel')).toHaveAttribute('data-status', 'paid');
  await expectNoSideScroll(page);
  // the next stages do not read the price
  const mine = await apiAs(page);
  expect((await mine.rows('lot_payments', `footprint_id=eq.${page.url().split('/records/')[1]}`))[0]).toMatchObject({ amount: 5100 });   // 3,400 × 1.5
  await signOut(page);
  await signIn(page, USERS.villageBatch);
  const theirs = await apiAs(page);
  expect(await theirs.rows('lot_payments', '')).toEqual([]);
  await signOut(page);
});

test('C2: with no network, a Collection Batch of one place, its villages and the loss on re-weighing; the journey forward', async ({ page, context }) => {
  test.setTimeout(300_000);
  const u = uniq();
  await signIn(page, USERS.cm);
  const point = await newPoint(page, `e2e52 Itwa store ${u}`);
  await signOut(page);

  await signIn(page, USERS.procurement);
  const lots: string[] = [];
  for (const [farmer, gross, where] of [[/Ram Achal/, '102', point], [/Sita Devi/, '152', point], [/Geeta Kumari/, '62', 'farm']] as const) {
    await openSlot(page, 'procurement', SCOPES.bansiBatch);
    await weigh(page, farmer, gross);
    await fillWhere(page, where);
    await payIfAsked(page);
    lots.push(await reviewAndSave(page, CODE));
  }
  const [a, b, c] = lots;
  await signOut(page);

  await signIn(page, USERS.villageBatch);
  await openSlot(page, 'village_batch', SCOPES.bansiBatch);
  for (const x of lots) { await verifyIncoming(page, x); await page.getByRole('button', { name: 'Back' }).click(); }
  await page.getByRole('tab', { name: /New Collection Batch/ }).click();     // online once: the lots are kept on the phone
  const place = page.locator('[data-testid^="batch-place-"][data-place]').filter({ hasText: `e2e52 Itwa store ${u}` });
  await expect(place).toContainText(a);
  await expect(place).toContainText(b);
  await context.setOffline(true);
  await expect(page.getByTestId('net-badge')).toContainText('Offline');
  await page.getByRole('checkbox', { name: new RegExp(a) }).check();
  await page.getByRole('checkbox', { name: new RegExp(c) }).check();        // weighed at the farm: another place
  await expect(page.getByTestId('batch-two-places')).toBeVisible();
  await expect(page.getByTestId('preview-error')).toContainText('These lots are from different collection points');
  await page.getByRole('checkbox', { name: new RegExp(c) }).uncheck();
  await page.getByRole('checkbox', { name: new RegExp(b) }).check();
  await page.getByLabel(/^Bags in the batch/).fill('4');
  await page.getByLabel(/^Re-weighed total/).fill('245');
  const ok = page.getByTestId('preview-ok');
  await expect(ok).toContainText('245 kg');
  await expect(page.getByTestId('offline-maths')).toBeVisible();                // the same maths the server does
  await expect(ok).toContainText('The batch weighs 5.0 kg (2.0 %) less than its lots.');
  await expectNoSideScroll(page);
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save on this phone' }).click();
  await expect(page.getByTestId('queued')).toBeVisible();
  await context.setOffline(false);                                              // network back: the outbox sends by itself
  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Saved on phone' }).click();
  const sent = page.getByTestId('outbox-synced').locator('tbody tr').filter({ hasText: '245 kg' });
  await expect(sent).toHaveCount(1, { timeout: 60_000 });
  const batch = (await sent.locator('td.mono').textContent())!.trim();
  await page.getByRole('button', { name: 'Clear sent list' }).click();
  const api = await apiAs(page);
  const [vb] = await api.rows('footprints', `footprint_code=eq.${batch}`);
  expect(vb.computed).toMatchObject({ total_kg: 250, farmers: 2, collection_point: `e2e52 Itwa store ${u}`, loss_kg: 5 });
  expect((vb.computed as { villages: { village: string }[] }).villages.map((v) => v.village)).toEqual(['Itwa', 'Bansi']);
  await page.goto(`/records/${vb.id}`);
  await expect(page.locator('[data-computed="villages"]')).toContainText('Itwa 150 kg (60 %) · Bansi 100 kg (40 %)');
  await expectNoSideScroll(page);
  await signOut(page);

  // A13: the journey forward, from a farmer's lot to the batch it went into (the Client Manager sees the whole scope)
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  const [first] = await cm.rows('footprints', `footprint_code=eq.${a}`);
  await page.goto(`/records/${first.id}`);
  const fwd = page.getByTestId('lot-forward');
  await expect(fwd).toContainText(batch);
  await expect(fwd).toContainText('took 100 kg');
  await page.goto(`/trace/${first.id}`);
  await expect(page.getByTestId('lot-forward')).toContainText(batch);
  await expectNoSideScroll(page);
  await signOut(page);
});
