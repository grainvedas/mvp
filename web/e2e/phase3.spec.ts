import { test, expect, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { signIn, signOut, expectNoSideScroll, openSlotAt } from './helpers';

// Phase 3 through the real screens: airplane-mode capture (PRD §12 edge check: 10 lots offline sync in order),
// a refused offline save surfaces and is fixed, dashboards + Client View + exports, Hindi.
const op = (key: string, n: string) => ({ key, phone: `00000000${n}` });
const P = { proc: op('305', '05'), qc: op('306', '06'), mill: op('308', '08') };
const CM = { key: '303', email: 'grainvedas+clientmanager@gmail.com' };
const VIEW = { key: '304', email: 'grainvedas+clientview@gmail.com' };
const FARMERS = ['Ram Achal', 'Sita Devi', 'Mohan Lal', 'Geeta Kumari', 'Suresh Yadav'];

// A person who holds stages in several scopes works in one at a time (identity layer): the helper picks the place first.
const open = openSlotAt;

async function fillProcurement(page: Page, farmer: string, gross: number) {
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill(farmer.split(' ')[0]);
  await page.getByRole('button', { name: new RegExp(farmer) }).click();
  await page.getByLabel(/Gross weight/).fill(String(gross));
  await page.getByLabel(/^Bags/).fill('1');
  await page.getByLabel(/Tare per bag/).fill('1');
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('12');
}

test('Airplane mode: 10 farm-gate lots captured offline sync in capture order with consecutive codes', async ({ page, context }) => {
  test.setTimeout(240_000);
  await signIn(page, P.proc);
  await open(page, 'procurement', 'Gorakhpur');                       // online once: form + farmer list kept on the phone
  await expect(page.getByRole('button', { name: /Ram Achal/ })).toBeVisible();
  await context.setOffline(true);
  await expect(page.getByTestId('net-badge')).toContainText('Offline');
  await expectNoSideScroll(page);                                       // the offline badge must not widen the page

  const expected: number[] = [];
  for (let i = 0; i < 10; i++) {
    const gross = 100 + i;
    expected.push(gross - 1);
    await fillProcurement(page, FARMERS[i % 5], gross);
    await expect(page.getByTestId('offline-maths')).toBeVisible();
    await expect(page.getByTestId('preview-ok')).toContainText(`${gross - 1} kg`);   // the same maths the server does
    await page.getByRole('button', { name: 'Review' }).click();
    await page.getByLabel('I have checked these numbers against the lot').check();
    await page.getByRole('button', { name: 'Save on this phone' }).click();
    await expect(page.getByTestId('queued')).toBeVisible();
    await page.getByTestId('queue-another').click();
  }
  await expect(page.getByTestId('net-badge')).toContainText('10 to send');

  await context.setOffline(false);                                      // network back: the outbox sends by itself
  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Saved on phone' }).click();
  const synced = page.getByTestId('outbox-synced').locator('tbody tr');
  await expect(synced).toHaveCount(10, { timeout: 60_000 });
  await expect(page.getByTestId('outbox-open')).toHaveCount(0);
  const codes = await synced.locator('td.mono').allTextContents();
  const seqs = codes.map((c) => Number(c.match(/-P-(\d{4})$/)![1]));
  seqs.forEach((s, i) => expect(s).toBe(seqs[0] + i));                 // capture order, no gaps
  const rows = await synced.allTextContents();
  rows.forEach((r, i) => expect(r).toContain(`${expected[i]} kg`));    // the figure reviewed offline is the one saved
  await expect(page.getByTestId('net-badge')).toHaveCount(0);
  await page.getByRole('button', { name: 'Clear sent list' }).click();
  await signOut(page);
});

test('A processing save refused at sync stays on the phone with the reason, is fixed and saved', async ({ page, context }) => {
  test.setTimeout(180_000);
  await signIn(page, P.proc);
  await open(page, 'procurement', 'Basti mill');
  await fillProcurement(page, 'Suresh Yadav', 199);
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save record' }).click();
  const p = (await page.getByTestId('saved').textContent())!.match(/PRSDM-KNM-KH26-P-\d{4}/)![0];
  await signOut(page);

  await signIn(page, P.qc);
  await open(page, 'qc', 'Basti mill');
  await page.getByTestId('incoming-row').filter({ hasText: p }).click();
  for (const box of await page.getByRole('checkbox').all()) await box.check();
  await page.getByRole('button', { name: 'Verify this lot' }).click();
  await page.getByRole('button', { name: /Record Quality Control/ }).click();
  await page.getByLabel(/Sample drawn/).fill('1');
  await page.getByLabel(/^Moisture \(%\)/).fill('11.8');
  await page.getByLabel(/^Broken grains/).fill('2');
  await page.getByLabel(/^Foreign matter/).fill('0.2');
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save record' }).click();
  const q = (await page.getByTestId('saved').textContent())!.match(/PRSDM-KNM-KH26-QC-\d{4}/)![0];
  await signOut(page);

  await signIn(page, P.mill);
  await open(page, 'milling', 'Basti mill');
  await page.getByTestId('incoming-row').filter({ hasText: q }).click();
  for (const box of await page.getByRole('checkbox').all()) await box.check();
  await page.getByRole('button', { name: 'Verify this lot' }).click();              // verifying needs the network
  await page.getByRole('button', { name: /Record Milling/ }).click();
  await context.setOffline(true);
  await page.getByLabel(/Rice out/).fill('130'); await page.getByLabel(/^Bran/).fill('54'); await page.getByLabel(/^Loss/).fill('40');
  await expect(page.getByTestId('preview-ok')).toContainText('checked by the server when it syncs');
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save on this phone' }).click();
  await expect(page.getByTestId('queued')).toBeVisible();
  await context.setOffline(false);

  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Saved on phone' }).click();
  const open1 = page.getByTestId('outbox-open');
  await expect(open1).toContainText('needs attention', { timeout: 30_000 });
  await expect(open1).toContainText(/input|rice|bran|loss/i);                        // the database's own reason
  await page.getByRole('link', { name: 'Fix and save again' }).click();
  await expect(page.getByTestId('draft-error')).toBeVisible();
  await expect(page.getByLabel(/Rice out/)).toHaveValue('130');                     // what was typed offline is kept
  await page.getByLabel(/^Loss/).fill('13');                                           // 197 = 130 + 54 + 13
  await expect(page.getByTestId('preview-ok')).toContainText('130 kg');
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save record' }).click();
  await expect(page.getByTestId('saved')).toContainText(/PRSDM-KNM-KH26-M-\d{4}/);
  await page.goto('/outbox');
  await expect(page.getByTestId('outbox-open')).toHaveCount(0);
  await signOut(page);
});

test('Dashboards: pipeline dots, sealed lots, flag log, season CSV, journey CSV; Client View reads the same', async ({ page }) => {
  // Uses "Basti mill", which phase2.spec.ts T4 (a sealed lot) and the test above (processing records) fill: run the
  // whole suite (files run in name order, as in CI), not this file alone.
  test.setTimeout(120_000);
  const openBasti = async () => {
    await page.goto('/');
    await page.locator('.card').filter({ hasText: 'Basti mill' }).getByTestId('dashboard-link').click();
    await expect(page.getByTestId('stage-dots').locator('li').first()).toBeVisible();
    await expectNoSideScroll(page);
  };
  for (const who of [CM, VIEW]) {
    await signIn(page, who);
    await openBasti();
    await expect(page.getByTestId('stage-dots').locator('li.done')).not.toHaveCount(0);
    const dl = page.waitForEvent('download');
    await page.getByTestId('season-csv').click();
    const csv = readFileSync((await (await dl).path())!, 'utf8').replace(/^\uFEFF/, '');
    // 4 Oct 2026 (capture time, migration 29): the time column is the time the work was recorded and is named so; the
    // time the server stored it is a new last column. The other columns are where they were.
    expect(csv.split('\r\n')[0]).toBe('code,stage,status,qty_in_kg,qty_out_kg,grade,lot_closed,farmer_id,farmer,village,batch_code,buyer,market,recorded_at,verified_at,warnings,received_by_server_at');
    expect(csv).toMatch(/\r\nSUMMARY 1,procurement,/);
    expect(csv).toMatch(/\r\nPRSDM-KNM-KH26-P-\d{4},procurement,verified,/);
    expect(csv).toMatch(/\r\nPRSDM-KNM-KH26-M-\d{4},milling,/);
    await signOut(page);
  }
  await signIn(page, VIEW);
  await openBasti();
  await page.getByTestId('sealed-lots').getByRole('link', { name: 'Journey & export' }).first().click();
  await expect(page.getByTestId('trace-steps').locator('> li')).toHaveCount(7);          // procure → … → ship → QR
  const dl = page.waitForEvent('download');
  await page.getByTestId('trace-csv').click();
  const csv = readFileSync((await (await dl).path())!, 'utf8');
  expect(csv).toContain('step,code,stage,status,farmer_id');
  expect(csv).toMatch(/GV-[0-9A-F]{12}/);
  expect(csv).not.toMatch(/\+91\d{10}/);                                                // no farmer phones in exports
  await expect(page.getByRole('button', { name: 'Print / save as PDF' })).toBeVisible();
  await signOut(page);
});

test('Hindi: operator screens switch language; English stays as the database sends it', async ({ page }) => {
  await signIn(page, P.proc);
  await page.getByLabel('Language').selectOption('hi');
  await expect(page.getByRole('link', { name: 'डैशबोर्ड' })).toBeVisible();
  await open(page, 'procurement', 'Gorakhpur');
  await expect(page.getByRole('heading', { level: 1 })).toContainText('ख़रीद (फ़ार्म-गेट)');   // after its pictogram
  await expect(page.getByText(/^कुल वज़न/)).toBeVisible();
  await expect(page.getByPlaceholder('नाम, किसान आईडी, फ़ोन या गाँव')).toBeVisible();
  // The record page too: its labels, the status word and the ledger's event names (they come from the database in English).
  await page.getByRole('tab', { name: 'इस चरण के रिकॉर्ड' }).click();
  await page.locator('tbody tr').first().getByRole('link').click();
  await expect(page.getByRole('heading', { level: 1 })).toContainText('रिकॉर्ड');
  const card = page.locator('.card').first();
  for (const word of ['चरण', 'आई मात्रा', 'निकली मात्रा', 'अभी उपलब्ध', 'दर्ज', 'भरे गए मान']) await expect(card).toContainText(word);
  await expect(card.locator('.badge').first()).toHaveText(/^(सत्यापन बाकी|स्वीकृत|बंद)$/);
  await expect(page.locator('th', { hasText: 'घटना' })).toBeVisible();
  await expect(page.locator('td', { hasText: 'दर्ज किया' }).first()).toBeVisible();
  await expect(page.locator('main').getByRole('link', { name: 'ख़रीद (फ़ार्म-गेट)' })).toBeVisible();   // the way back to the stage, in Hindi too (the menu names the stage as well, now that a scope is in force)
  await expect(page.getByText('Quantity in')).toHaveCount(0);
  await page.getByLabel('Language').selectOption('en');
  await expect(card).toContainText('Quantity in');
  await page.goBack();
  await expect(page.getByRole('heading', { level: 1 })).toContainText('Procurement (farm-gate)');
  await signOut(page);
});
