// Faults found on 4 October 2026 while the built system was run side by side with the prototype
// (docs/INTERFACE_GAP.md section 10; docs/FIX_LIST.md lines 22 to 31, which were open items 6 to 16 that day).
// Each fault test fails on the build of 2 October at the fault it names: the checks are ordered, or made soft, so that
// a run against the old app reaches the fault itself and not merely an element that did not exist yet.
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, USERS, SCOPES, openSlot, verifyIncoming, reviewAndSave, procure, recordQc, sealLot, apiAs } from './helpers';
import { hi } from '../src/lib/i18n.hi';

const uniq = () => Math.random().toString(36).slice(2, 7).toUpperCase();
/** Words no person should be shown: a number formatter fed with text, or a list printed as code. */
async function noRawData(scope: ReturnType<Page['locator']>) {
  const text = (await scope.textContent()) ?? '';
  expect(text, 'a text value went through a number formatter').not.toContain('NaN');
  expect(text, 'a list is printed as code text').not.toMatch(/\[\{|\{"|":/);
}

test('Text values are shown as text and lists as words: review, arrival check and record page (items 6, 10, 11)', async ({ page }) => {
  test.setTimeout(240_000);
  const batch = `KNM-KH26-B${uniq()}`;
  await signIn(page, USERS.procurement);
  await openSlot(page, 'procurement', SCOPES.bastiMill);
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill('Suresh');
  await page.getByRole('button', { name: /Suresh Yadav/ }).click();
  await page.getByLabel(/Gross weight/).fill('199'); await page.getByLabel(/^Bags/).fill('2'); await page.getByLabel(/Tare per bag/).fill('2');
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('11.8');
  await expect(page.getByTestId('preview-ok')).toBeVisible();
  await page.getByRole('button', { name: 'Review' }).click();
  const review = page.getByTestId('review');
  await expect.soft(review, 'item 11: a name, not the internal key').toContainText('Net weight');     // was "Net Kg"
  await expect.soft(review.locator('[data-computed="net_kg"]')).toHaveText('195 kg');
  await expect.soft(review.locator('[data-computed="moisture_avg"]')).toHaveText('11.8 %');
  await expect.soft(review).not.toContainText('Net Kg');
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save record' }).click();
  const p = (await page.getByTestId('saved').textContent())!.match(/PRSDM-KNM-KH26-P-\d{4}/)![0];
  await signOut(page);

  await signIn(page, USERS.qc); const q = await recordQc(page, SCOPES.bastiMill, p, '11.8'); await signOut(page);

  await signIn(page, USERS.mill);
  await openSlot(page, 'milling', SCOPES.bastiMill);
  await verifyIncoming(page, q);
  await page.getByRole('button', { name: /Record Milling/ }).click();
  await page.getByLabel(/Rice out/).fill('130'); await page.getByLabel(/^Bran/).fill('54'); await page.getByLabel(/^Loss/).fill('10');
  const m = await reviewAndSave(page, /PRSDM-KNM-KH26-M-\d{4}/); await signOut(page);

  // Packing: the batch code is text. At review it read "Batch Code NaN".
  await signIn(page, USERS.sorting);
  await openSlot(page, 'packing', SCOPES.bastiMill);
  await verifyIncoming(page, m);
  await page.getByRole('button', { name: /Record Packing/ }).click();
  await page.getByLabel('Packets 1').fill('129'); await page.getByLabel('Size (kg) 1').fill('1');
  await page.getByLabel(/^Wastage/).fill('1'); await page.getByLabel(/Batch code/).fill(batch);
  await expect(page.getByTestId('preview-ok')).toContainText('129 kg');
  await page.getByRole('button', { name: 'Review' }).click();
  await expect(review.getByLabel('I have checked these numbers against the lot')).toBeVisible();
  await noRawData(review);                                             // item 6: "NaN" stood here
  await expect(review.locator('[data-computed="batch_code"]')).toHaveText(batch);
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save record' }).click();
  const pk = (await page.getByTestId('saved').textContent())!.match(/PRSDM-KNM-KH26-PK-\d{4}/)![0];
  await signOut(page);

  // The next stage's arrival check: the person ticking "Batch code assigned" must be able to read it.
  await signIn(page, USERS.commercial);
  await openSlot(page, 'commercial', SCOPES.bastiMill);
  await page.getByTestId('incoming-row').filter({ hasText: pk }).click();
  const arrival = page.locator('.card', { hasText: 'Check what arrived' });
  await expect(arrival.locator('[data-computed="batch_code"]')).toHaveText(batch);
  await expect(arrival.locator('[data-computed="packed_kg"]')).toHaveText('129 kg');
  await noRawData(arrival.locator('dl.kv'));
  for (const box of await page.getByRole('checkbox').all()) await box.check();
  await page.getByRole('button', { name: 'Verify this lot' }).click();
  await page.getByRole('button', { name: /Record Commercial Clearance/ }).click();
  await page.getByLabel(/^Buyer/).fill('Amira Foods BV'); await page.getByLabel(/^Market/).selectOption('export');
  await page.getByLabel(/Quantity to this buyer/).fill('60');
  // the maths panel says what will be LEFT on the lot (it read "129 kg still available", the lot before this sale)
  await expect(page.getByTestId('preview-ok')).toContainText('69 kg will be left on the source lot');
  await page.getByRole('button', { name: 'Review' }).click();
  await expect(review.locator('[data-computed="buyer"]')).toHaveText('Amira Foods BV');
  await expect(review.locator('[data-computed="market"]')).toHaveText('export');
  await noRawData(review);
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save record' }).click();
  const cm = (await page.getByTestId('saved').textContent())!.match(/PRSDM-KNM-KH26-CM-\d{4}/)![0];

  // The record page: worked-out values, and the entered values as a list with the form's own names
  await page.getByRole('link', { name: `Open ${cm}` }).click();
  await expect(page.locator('[data-computed="buyer"]')).toHaveText('Amira Foods BV');
  await page.getByText('Entered values').click();
  const entered = page.getByTestId('entered-values');
  await expect(entered.locator('[data-entered="buyer"]')).toHaveText('Amira Foods BV');
  await expect(entered.locator('[data-entered="qty_kg"]')).toHaveText('60 kg');
  await expect(entered).toContainText('Quantity to this buyer');
  await noRawData(page.locator('main'));
  await signOut(page);
});

test('Reject reasons and the grade split are shown in words (item 10)', async ({ page }) => {
  test.setTimeout(180_000);
  await signIn(page, USERS.procurement); const p = await procure(page, SCOPES.gorakhpur, 'Ram Achal', '200', '2', '1'); await signOut(page);
  await signIn(page, USERS.sorting);
  await openSlot(page, 'sorting', SCOPES.gorakhpur);
  await verifyIncoming(page, p);
  await page.getByRole('button', { name: /Record Sorting/ }).click();
  await page.getByLabel(/^Reject \(kg\)/).fill('6'); await page.getByLabel(/^Loss/).fill('2');
  await page.getByLabel('Reason 1').fill('discoloured grains'); await page.getByLabel('kg 1').fill('4');
  await page.getByRole('button', { name: /reason/i }).click();
  await page.getByLabel('Reason 2').fill('stones'); await page.getByLabel('kg 2').fill('2');
  await expect(page.getByTestId('preview-ok')).toBeVisible();
  await page.getByRole('button', { name: 'Review' }).click();
  const review = page.getByTestId('review');
  await expect(review.getByLabel('I have checked these numbers against the lot')).toBeVisible();
  await noRawData(review);                                             // [{"reason":"discoloured grains","kg":4},…] stood here
  await expect(review.locator('[data-computed="reject_reasons"]')).toHaveText('discoloured grains 4 kg · stones 2 kg');
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save record' }).click();
  const s = (await page.getByTestId('saved').textContent())!.match(/PRSDM-KNM-KH26-S-\d{4}/)![0];
  await signOut(page);

  await signIn(page, USERS.grading);
  await openSlot(page, 'grading', SCOPES.gorakhpur);
  await verifyIncoming(page, s);
  await page.getByRole('button', { name: /Record Grading/ }).click();
  await page.getByLabel(/^Grade A/).fill('120'); await page.getByLabel(/^Grade B/).fill('50'); await page.getByLabel(/^Grade C/).fill('15');
  await page.getByLabel(/^Reject/).fill('3'); await page.getByLabel(/^Loss/).fill('2');
  await expect(page.getByTestId('preview-ok')).toBeVisible();
  await page.getByRole('button', { name: 'Review' }).click();
  await expect(review.locator('[data-computed="grade_split"]')).toHaveText('A 120 kg · B 50 kg · C 15 kg');
  await noRawData(review);
  await signOut(page);
});

test('A quality limit can be typed with a decimal point (item 7)', async ({ page }) => {
  const code = `Z${uniq().replace(/[^A-Z]/g, 'Q').slice(0, 3)}`;
  await signIn(page, USERS.admin);
  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Crop Registry' }).click();
  await page.getByRole('button', { name: 'Create' }).click();
  await page.getByLabel('Name', { exact: true }).fill(`Decimal test ${code}`); await page.getByLabel('Code', { exact: true }).fill(code);
  await page.getByRole('button', { name: '+ limit' }).click();
  await page.getByLabel('key', { exact: true }).fill('moisture_pct'); await page.getByLabel('label', { exact: true }).fill('Moisture');
  await page.getByLabel('domestic limit').pressSequentially('12.5');     // key by key, as a person types
  await page.getByLabel('export limit').pressSequentially('11.75');
  await expect(page.getByLabel('domestic limit')).toHaveValue('12.5');    // was 125
  await expect(page.getByLabel('export limit')).toHaveValue('11.75');     // was 1175
  await page.getByRole('button', { name: 'Save' }).click();
  await page.getByRole('listitem').filter({ hasText: code }).getByRole('button', { name: 'Edit' }).click();
  await expect(page.getByLabel('domestic limit')).toHaveValue('12.5');
  await expect(page.getByLabel('export limit')).toHaveValue('11.75');
  // something that is not a number is said to be one, and cannot be saved
  await page.getByLabel('export limit').fill('11,5x');
  await expect(page.getByTestId('limit-not-a-number')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Save' })).toBeDisabled();
  const api = await apiAs(page);
  const row = (await api.rows('crops', `code=eq.${code}`))[0] as { quality_params: { domestic_limit: number; export_limit: number }[] };
  expect(row.quality_params[0].domestic_limit).toBe(12.5);
  expect(row.quality_params[0].export_limit).toBe(11.75);
  await signOut(page);
});

test('The lab sees pass or fail before saving, and it is what the save derives (item 9)', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, USERS.procurement); const p = await procure(page, SCOPES.siddharthnagar, 'Sita Devi', '150', '1', '2.5'); await signOut(page);
  await signIn(page, USERS.qc);
  await openSlot(page, 'qc', SCOPES.siddharthnagar);
  await verifyIncoming(page, p);
  await page.getByRole('button', { name: /Record Quality Control/ }).click();
  await page.getByLabel(/Sample drawn/).fill('0.5');
  await page.getByLabel(/^Moisture \(%\)/).fill('12.6');                 // domestic limit 13, export limit 12
  await page.getByLabel(/^Broken grains/).fill('2'); await page.getByLabel(/^Foreign matter/).fill('0.2');
  const verdict = page.getByTestId('verdict-preview');
  await expect(verdict.first()).toContainText('domestic passed');
  await expect(verdict.first()).toContainText('export not met');
  await expect(verdict.first()).toContainText('Not met: Moisture (export)');
  await page.getByRole('button', { name: 'Review' }).click();
  await expect(page.getByTestId('review').getByTestId('verdict-preview')).toContainText('export not met');
  await expect(verdict).toHaveCount(1);                                  // said once at review, in the summary
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save record' }).click();
  const q = (await page.getByTestId('saved').textContent())!.match(/PRSDM-KNM-KH26-QC-\d{4}/)![0];
  await page.getByRole('link', { name: `Open ${q}` }).click();
  const lab = page.locator('.card').filter({ has: page.getByRole('heading', { name: 'Quality control' }) });
  await expect(lab).toContainText('Pass'); await expect(lab).toContainText('Fail');   // the saved verdict: domestic pass, export fail
  await expect(lab).toContainText('Moisture');                           // was "Moisture Pct"
  await expect(lab).not.toContainText('Moisture Pct');
  await signOut(page);
});

test('A record saved without network keeps the time it was captured (item 8)', async ({ page, context }) => {
  test.setTimeout(120_000);
  await signIn(page, USERS.procurement);
  await openSlot(page, 'procurement', SCOPES.siddharthnagar);
  await expect(page.getByRole('button', { name: /Ram Achal/ })).toBeVisible();
  await context.setOffline(true);
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill('Ram');
  await page.getByRole('button', { name: /Ram Achal/ }).click();
  await page.getByLabel(/Gross weight/).fill('121'); await page.getByLabel(/^Bags/).fill('1'); await page.getByLabel(/Tare per bag/).fill('1');
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('12');
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save on this phone' }).click();
  await expect(page.getByTestId('queued')).toBeVisible();
  // The save now waits on the phone. Make it one that has waited three hours (the test cannot wait that long).
  const captured = await page.evaluate(() => new Promise<string>((resolve, reject) => {
    const open = indexedDB.open('grainveda-offline');
    open.onerror = () => reject(open.error);
    open.onsuccess = () => {
      const store = open.result.transaction('outbox', 'readwrite').objectStore('outbox');
      const all = store.getAll();
      all.onsuccess = () => {
        const item = (all.result as { state: string; captured_at: string }[]).find((x) => x.state === 'queued')!;
        item.captured_at = new Date(Date.now() - 3 * 3600_000).toISOString();
        store.put(item).onsuccess = () => resolve(item.captured_at);
      };
    };
  }));
  await context.setOffline(false);
  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Saved on phone' }).click();
  const synced = page.getByTestId('outbox-synced').locator('tbody tr');
  await expect(synced).toHaveCount(1, { timeout: 60_000 });
  await synced.locator('td.mono a').click();
  await expect(page.getByRole('heading', { name: /PRSDM-KNM-KH26-P-\d{4}/ })).toBeVisible();
  const api = await apiAs(page);
  const id = page.url().split('/').pop()!;
  const rec = (await api.rows('footprints', `id=eq.${id}`))[0] as { created_at: string; captured_at: string };
  expect(new Date(rec.captured_at).getTime(), 'the record carries the time it was captured, three hours before it was sent')
    .toBe(new Date(captured).getTime());
  expect(new Date(rec.created_at).getTime() - new Date(rec.captured_at).getTime()).toBeGreaterThan(2.9 * 3600_000);
  await expect(page.getByTestId('sent-later')).toContainText('kept on the phone, sent');
  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Saved on phone' }).click();
  await page.getByRole('button', { name: 'Clear sent list' }).click();
  await signOut(page);
});

test('A client viewer gets no controls on a scope, and a first stage shows its records (items 12, 13)', async ({ page }) => {
  await signIn(page, USERS.view);
  await page.goto(`/scopes/${SCOPES.siddharthnagar}?step=people`);
  await expect(page.getByRole('heading', { name: 'People' })).toBeVisible();
  await expect(page.locator('main')).toContainText('Procurement Op');   // who holds the stages is shown
  await expect(page.getByRole('button', { name: '+ new person' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: /Remove/ })).toHaveCount(0);
  await expect(page.getByRole('combobox', { name: /^Assign/ })).toHaveCount(0);
  await expect(page.getByTestId('slots')).toContainText('Procurement');
  // a first stage, opened by someone who cannot record there: its records, not tabs with nothing under them
  await page.goto(`/work/${SCOPES.siddharthnagar}/procurement`);
  await expect(page.getByRole('tab', { name: 'Records at this stage' })).toHaveAttribute('aria-selected', 'true');
  await expect(page.locator('main table').or(page.getByText('Nothing here yet.'))).toBeVisible();
  await signOut(page);
});

test('On a 390 px phone: a small header that says who is signed in, and no page wider than the screen (item 14)', async ({ page }) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 390, height: 844 });
  // Soft checks: one run names every fault of the item (on the old app: the name, the header, three wide pages).
  const softly = expect.configure({ soft: true });
  const fits = (what: string) => softly.poll(() => page.evaluate(() => window.innerWidth - document.documentElement.clientWidth),
    { message: `${what}: px wider than the screen` }).toBe(0);
  await signIn(page, USERS.procurement);
  await softly(page.getByTestId('whoami'), 'who is signed in').toBeVisible();
  await softly(page.getByTestId('whoami')).toContainText('Procurement Op');
  const headerHeight = () => page.evaluate(() => Math.round(document.querySelector('main')!.getBoundingClientRect().top + window.scrollY));
  softly(await headerHeight(), 'practice strip + top bar + menu, in px').toBeLessThanOrEqual(150);   // was 239
  // The strip still says what this system is, in its short wording, on one line. (A check of the strip's text alone
  // passes when the words are hidden: the first version of this fix left an empty gold bar on phones.)
  const strip = page.getByTestId('practice-strip');
  await softly(strip.locator('.short')).toBeVisible();
  await softly(strip).toHaveText('PRACTICE SYSTEM · not real lots', { useInnerText: true });
  softly((await strip.boundingBox())!.height, 'the strip is one line').toBeLessThan(30);
  await fits('home');
  const p = await procure(page, SCOPES.siddharthnagar, 'Mohan Lal', '180', '2', '1');
  await page.getByRole('link', { name: `Open ${p}` }).click();
  await expect(page.getByRole('heading', { name: new RegExp(p) })).toBeVisible();
  await fits('record page');                                            // was 402 px wide
  await signOut(page);

  await signIn(page, USERS.qc); const q = await recordQc(page, SCOPES.siddharthnagar, p, '11.9'); await signOut(page);
  await signIn(page, USERS.qr); const code = await sealLot(page, SCOPES.siddharthnagar, q);
  await page.goto(`/labels/${code}`);
  await expect(page.getByTestId('label-sheet').locator('.label').first()).toBeVisible();
  await fits('label sheet');                                            // was 525 px wide
  await signOut(page);

  await signIn(page, USERS.cm);
  softly(await headerHeight(), 'the same for a manager, in px').toBeLessThanOrEqual(150);
  await page.setViewportSize({ width: 1366, height: 768 });               // on a laptop: the full wording, the product name, the role
  await softly(strip).toHaveText('PRACTICE SYSTEM · for training and testing · not real lots', { useInnerText: true });
  await softly(page.getByTestId('whoami')).toHaveText(/^Prasaadam Client Manager\s+Client Manager$/, { useInnerText: true });   // the name over the role
  await page.setViewportSize({ width: 390, height: 844 });
  await softly(page.getByTestId('whoami')).toHaveText('Prasaadam Client Manager', { useInnerText: true });   // the role gives way to the name
  await page.goto(`/scopes/${SCOPES.siddharthnagar}?step=people`);
  await expect(page.getByRole('combobox', { name: /^Assign/ }).first()).toBeVisible();
  await fits('people of a scope');                                      // was 454 px wide
  await signOut(page);
});

test('The language can be chosen on the sign-in screen (item 16)', async ({ page }) => {
  await page.goto('/');
  await page.evaluate(() => localStorage.clear());
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await page.getByTestId('signin-language').selectOption('hi');
  await expect(page.getByRole('heading', { name: hi['signin.title'] })).toBeVisible();
  await page.getByTestId('signin-language').selectOption('en');
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
});

test('A lot the lab has not seen shows no "verdict pending"; dashboard figures say what they are (item 16)', async ({ page }) => {
  test.setTimeout(120_000);
  // Soft checks: the three faults are independent, and a run on the old build should name all three.
  await signIn(page, USERS.procurement);
  const p = await procure(page, SCOPES.siddharthnagar, 'Ram Achal', '150', '2', '1');
  await page.getByRole('link', { name: `Open ${p}` }).click();
  await expect(page.getByRole('heading', { name: new RegExp(p) })).toBeVisible();
  const recordUrl = page.url();
  await expect(page.locator('main')).toContainText('Recorded');
  await expect.soft(page.locator('main'), 'a farm-gate record has no lab result: it said "domestic Pending · export Pending"')
    .not.toContainText('Market verdict');
  await signOut(page);

  await signIn(page, USERS.qc);
  const q = await recordQc(page, SCOPES.siddharthnagar, p, '11.9');
  await page.getByRole('link', { name: `Open ${q}` }).click();
  await expect(page.locator('main')).toContainText(/Market verdict\s*domestic\s*Pass\s*·\s*export\s*Pass/);   // the lab's record still says it
  await signOut(page);

  await signIn(page, USERS.cm);
  await page.goto(recordUrl);                                           // the farm-gate record, after its lot passed the lab
  await expect(page.getByRole('heading', { name: new RegExp(p) })).toBeVisible();
  await expect(page.locator('main')).toContainText('Recorded');
  await expect.soft(page.locator('main'), 'it kept "Pending" for ever: the verdict is on the lab record')
    .not.toContainText('Market verdict');
  await page.goto(`/dashboard/${SCOPES.siddharthnagar}`);
  const box = page.getByTestId('stage-dots').locator('li').first();
  await expect(box).toBeVisible();
  await expect.soft(box, 'two bare numbers: "7 · 1,234 kg"').toContainText(/\d+ records · [\d,.]+ kg available/);
  await expect(page.locator('main')).toContainText('Activity, last 14 days');
  await expect.soft(page.locator('main'), 'the column also counts stage assignments and said "Manager actions"')
    .toContainText('Manager actions and stage assignments');
  await signOut(page);
});

// Not a fault that was fixed: the path the guides give for a limit that was accepted (docs/FIX_LIST.md K19, decision G8 = A).
test('An arrival that is wrong: no "Reject", so the receiver flags it from the arrival check and the manager withdraws it (limit K19)', async ({ page }) => {
  test.setTimeout(120_000);
  const note = `Two bags short on arrival ${uniq()}`;
  await signIn(page, USERS.procurement);
  const p = await procure(page, SCOPES.siddharthnagar, 'Mohan Lal', '120', '2', '1');
  await signOut(page);

  await signIn(page, USERS.qc);                                          // the receiving stage
  await openSlot(page, 'qc', SCOPES.siddharthnagar);
  await page.getByTestId('incoming-row').filter({ hasText: p }).click();
  await expect(page.getByRole('button', { name: 'Verify this lot' })).toBeDisabled();   // nothing ticked: nothing verified
  await expect(page.getByRole('button', { name: /reject|refuse|send back/i })).toHaveCount(0);   // the accepted limit
  await page.getByRole('link', { name: 'Open full record' }).click();
  await expect(page.getByRole('heading', { name: new RegExp(p) })).toBeVisible();
  const recordUrl = page.url();
  await page.getByPlaceholder('Raise a flag').fill(note);
  await page.getByRole('button', { name: 'Raise a flag' }).click();
  await expect(page.getByText(note)).toBeVisible();
  await signOut(page);

  await signIn(page, USERS.cm);                                          // the manager sees it, and takes the record out
  await page.goto('/flags');
  await expect(page.getByText(note)).toBeVisible();
  await page.goto(recordUrl);
  await expect(page.locator('main .badge').first()).toHaveText('Pending verification');   // still not verified by anyone
  await page.getByTestId('withdraw-open').click();
  await page.getByLabel('Reason (kept in the ledger)').fill('Refused on arrival: two bags short');
  await page.getByRole('button', { name: 'Withdraw this record' }).click();
  await expect(page.getByTestId('withdrawal-info')).toContainText('Refused on arrival: two bags short');
  await signOut(page);

  await signIn(page, USERS.qc);                                          // and it no longer waits at the receiving stage
  await openSlot(page, 'qc', SCOPES.siddharthnagar);
  await expect(page.getByRole('heading', { name: 'Quality Control' })).toBeVisible();
  // the waiting list has loaded (rows, or the line that says nothing is waiting) before its absence there is checked
  await expect(page.getByTestId('incoming-row').first().or(page.getByText(/^Nothing is waiting from/))).toBeVisible();
  await expect(page.getByTestId('incoming-row').filter({ hasText: p })).toHaveCount(0);
  await signOut(page);
});

// The app is deployed by a push to GitHub; the database by a separate command. For a while the new app can meet a
// database that does not have migration 29. The refusal below is the server software's own answer to a column it does
// not know (PostgREST 12.2.3, read from the local stack), given here for the capture time.
test('An app deployed ahead of its database still sends a save that waited on the phone (item 8)', async ({ page, context }) => {
  test.setTimeout(120_000);
  const refused: string[] = []; const passedOn: string[] = [];
  await page.route('**/rest/v1/footprints*', async (route) => {
    const req = route.request();
    if (req.method() !== 'POST') return route.continue();
    const body = req.postData() ?? '';
    if (!body.includes('"captured_at"')) { passedOn.push(body); return route.continue(); }
    refused.push(body);
    return route.fulfill({ status: 400, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' },
      body: JSON.stringify({ code: 'PGRST204', details: null, hint: null, message: "Could not find the 'captured_at' column of 'footprints' in the schema cache" }) });
  });
  await signIn(page, USERS.procurement);
  await openSlot(page, 'procurement', SCOPES.siddharthnagar);
  await expect(page.getByRole('button', { name: /Ram Achal/ })).toBeVisible();
  await context.setOffline(true);
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill('Ram');
  await page.getByRole('button', { name: /Ram Achal/ }).click();
  await page.getByLabel(/Gross weight/).fill('111'); await page.getByLabel(/^Bags/).fill('1'); await page.getByLabel(/Tare per bag/).fill('1');
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('12');
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save on this phone' }).click();
  await expect(page.getByTestId('queued')).toBeVisible();
  await context.setOffline(false);
  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Saved on phone' }).click();
  const synced = page.getByTestId('outbox-synced').locator('tbody tr');
  await expect(synced).toHaveCount(1, { timeout: 60_000 });              // it went through
  await expect(page.getByTestId('outbox-open')).toHaveCount(0);          // and is not left as "needs attention"
  expect(refused, 'sent once with the capture time, refused as an unknown column').toHaveLength(1);
  expect(passedOn, 'sent again without it, once').toHaveLength(1);
  expect(JSON.parse(passedOn[0]).client_ref, 'under the same save id').toBe(JSON.parse(refused[0]).client_ref);
  await synced.locator('td.mono a').click();
  await expect(page.locator('main')).toContainText('110 kg');
  await expect(page.getByTestId('sent-later')).toHaveCount(0);           // dated by the server, as before migration 29
  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Saved on phone' }).click();
  await page.getByRole('button', { name: 'Clear sent list' }).click();
  await signOut(page);
});
