import { test, expect, type Page } from '@playwright/test';
import { signIn, signInWith, signOut, USERS, SCOPES, openSlot, verifyIncoming, reviewAndSave, procure, recordQc, sealLot, apiAs } from './helpers';

// Phase 4 "live season" through the real screens: what goes wrong in a real week and how it is put right.
const uniq = () => String(Date.now()).slice(-6);
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
const pdf = (text: string) => Buffer.from(`%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\n% ${text}\n%%EOF\n`, 'utf8');

async function fillProcurement(page: Page, farmer: string, gross: string, bags: string, tare: string) {
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill(farmer.split(' ')[0]);
  await page.getByRole('button', { name: new RegExp(farmer) }).click();
  await page.getByLabel(/Gross weight/).fill(gross);
  await page.getByLabel(/^Bags/).fill(bags);
  await page.getByLabel(/Tare per bag/).fill(tare);
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('11.8');
}
async function openSaved(page: Page, code: string) {
  await page.getByRole('link', { name: `Open ${code}` }).click();
  await expect(page.getByRole('heading', { level: 1 })).toContainText(code);
  return page.url();
}

test('Switching to another app and back keeps a half-filled form', async ({ page }) => {
  await signIn(page, USERS.procurement);
  await openSlot(page, 'procurement', SCOPES.gorakhpur);
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill('Sita');
  await page.getByRole('button', { name: /Sita Devi/ }).click();
  await page.getByLabel(/Gross weight/).fill('150');
  // What the browser tells the page when the operator comes back from the calculator or a phone call.
  for (let i = 0; i < 3; i++) {
    await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange', { bubbles: true })));
    await page.waitForTimeout(400);
  }
  await expect(page.getByLabel(/Gross weight/)).toHaveValue('150');
  await expect(page.getByTestId('farmer-picked')).toContainText('Sita Devi');
  await signOut(page);
});

test('A wrong lab record is withdrawn by the manager with a reason and recorded again; the replacement carries the history', async ({ page }) => {
  test.setTimeout(240_000);
  const S = SCOPES.siddharthnagar;
  await page.goto('/');
  await expect(page.getByTestId('practice-strip')).toContainText('PRACTICE SYSTEM', { useInnerText: true });   // this is not the production system (the words as shown, not hidden text)

  await signIn(page, USERS.procurement);
  const p = await procure(page, S, 'Suresh Yadav', '199', '2', '2');
  await signOut(page);

  await signIn(page, USERS.qc);
  const q1 = await recordQc(page, S, p, '11.8', '10');                                    // sample typed as 10 kg: should be 1
  const q1Url = await openSaved(page, q1);
  await expect(page.getByText('This record cannot be corrected after saving')).toBeVisible();
  await expect(page.getByRole('link', { name: 'Correct this record' })).toHaveCount(0);
  await expect(page.getByTestId('withdraw-open')).toHaveCount(0);                         // operators cannot withdraw
  const tryWithdraw = await (await apiAs(page)).rpc('withdraw_footprint', { p_fp: q1Url.split('/').pop(), p_reason: 'x' });
  expect(tryWithdraw.ok, 'withdraw called straight through the API by an operator').toBe(false);
  await signOut(page);

  await signIn(page, USERS.cm);
  await page.goto(q1Url);
  await page.getByTestId('withdraw-open').click();
  await expect(page.getByRole('button', { name: 'Withdraw this record' })).toBeDisabled();   // a reason is mandatory
  await page.getByLabel('Reason (kept in the ledger)').fill('Sample typed as 10 kg, the lab drew 1 kg');
  await page.getByRole('button', { name: 'Withdraw this record' }).click();
  const info = page.getByTestId('withdrawal-info');
  await expect(info).toContainText('Withdrawn');
  await expect(info).toContainText('Sample typed as 10 kg, the lab drew 1 kg');
  await expect(page.getByRole('row', { name: /Supervisory\s+Prasaadam Client Manager/ })).toBeVisible();
  await signOut(page);

  await signIn(page, USERS.qc);
  await page.goto(q1Url);
  await page.getByTestId('record-replacement').click();
  await expect(page.getByTestId('replaces-note')).toContainText(q1);
  await expect(page.getByTestId('replaces-note')).toContainText('the lab drew 1 kg');
  await expect(page.getByLabel(/Lot quantity/)).toHaveValue('195');                      // the lot is back with the lab, whole
  await expect(page.getByLabel(/Sample drawn/)).toHaveValue('10');                       // what was typed, to be put right
  await page.getByLabel(/Sample drawn/).fill('1');
  await expect(page.getByTestId('preview-ok')).toContainText('194 kg');
  const q2 = await reviewAndSave(page, /PRSDM-KNM-KH26-QC-\d{4}/);
  expect(q2).not.toBe(q1);
  const q2Url = await openSaved(page, q2);
  await expect(page.getByTestId('withdrawal-info')).toContainText('Replaces');
  await expect(page.getByTestId('withdrawal-info').getByRole('link', { name: q1 })).toBeVisible();
  await page.goto(q1Url);
  await expect(page.getByTestId('withdrawal-info')).toContainText('Replaced by');
  await expect(page.getByTestId('withdrawal-info').getByRole('link', { name: q2 })).toBeVisible();
  await expect(page.getByTestId('record-replacement')).toHaveCount(0);                    // one replacement only
  await signOut(page);

  // The sealer sees what the lot replaces before verifying it; the withdrawn record is not offered to him.
  await signIn(page, USERS.qr);
  await openSlot(page, 'qr_activation', S);
  await expect(page.getByTestId('incoming-row').filter({ hasText: q1 })).toHaveCount(0);
  await page.getByTestId('incoming-row').filter({ hasText: q2 }).click();
  await expect(page.getByTestId('replaces-note')).toContainText(q1);
  await page.goto('/');
  const code = await sealLot(page, S, q2);
  await page.goto(`/verify/${code}`);
  await expect(page.getByTestId('public-journey')).toContainText('Grown by Suresh Yadav');
  await expect(page.getByTestId('practice-strip')).toBeVisible();                         // a practice label cannot pass for a real one

  // The journey export names the withdrawn record, its reason and who withdrew it; the dashboard counts the day's work.
  await signIn(page, USERS.cm);
  await page.goto(q2Url);
  await page.getByTestId('trace-link').click();
  await expect(page.getByTestId('trace-steps')).toContainText('Replaces');
  await expect(page.getByTestId('trace-steps')).toContainText('the lab drew 1 kg');
  await page.goto(`/dashboard/${S}`);
  const today = page.getByTestId('activity').locator('tbody tr').first();
  await expect(today).toBeVisible();
  expect(Number(await today.locator('td').nth(1).textContent())).toBeGreaterThanOrEqual(4);   // saved today: at least P, QC, QC again, QR
  expect(Number(await today.locator('td').nth(4).textContent())).toBeGreaterThanOrEqual(1);   // manager actions: the withdrawal
  await signOut(page);
});

test('A seal refused at the gate (open flag) leaves the lot with the sealer; it seals once the flag is resolved', async ({ page }) => {
  test.setTimeout(180_000);
  const S = SCOPES.siddharthnagar;
  await signIn(page, USERS.procurement);
  const p = await procure(page, S, 'Sita Devi', '150', '1', '2.5');
  await signOut(page);
  await signIn(page, USERS.qc);
  const q = await recordQc(page, S, p, '11.9');
  const qUrl = await openSaved(page, q);
  await page.getByPlaceholder('Raise a flag').fill('Moisture meter was not calibrated today');
  await page.getByRole('button', { name: 'Raise a flag' }).click();
  await expect(page.getByText('Moisture meter was not calibrated today')).toBeVisible();
  await signOut(page);

  await signIn(page, USERS.qr);
  await openSlot(page, 'qr_activation', S);
  await verifyIncoming(page, q);
  await page.getByRole('button', { name: 'Activate and seal' }).click();
  await expect(page.getByRole('alert')).toContainText(/open flag on qc/i);
  await expect(page.getByTestId('sealed')).toHaveCount(0);
  await page.goto('/');
  await openSlot(page, 'qr_activation', S);
  await expect(page.getByTestId('incoming-row').filter({ hasText: q })).toHaveCount(1);     // still his to seal: nothing was saved
  const left = await (await apiAs(page)).rows('footprints', `scope_id=eq.${S}&stage_type=eq.qr_activation&status=eq.pending`);
  expect(left, 'QR records left behind by the refused seal').toHaveLength(0);
  await signOut(page);

  await signIn(page, USERS.cm);
  await page.goto(qUrl);
  await page.getByRole('button', { name: 'Resolve' }).click();
  await expect(page.getByText(/Resolved\s*Moisture meter/)).toBeVisible();
  await signOut(page);

  await signIn(page, USERS.qr);
  await openSlot(page, 'qr_activation', S);
  await page.getByTestId('incoming-row').filter({ hasText: q }).click();
  await page.getByRole('button', { name: 'Activate and seal' }).click();
  await expect(page.getByTestId('sealed')).toContainText(/Sealed\. QR code GV-[0-9A-F]{12}/);
  await signOut(page);
});

test('Evidence: a photo at the farm gate and papers added later are stored, fingerprinted and shown only with the record', async ({ page }) => {
  test.setTimeout(180_000);
  const S = SCOPES.siddharthnagar;
  await signIn(page, USERS.procurement);
  await openSlot(page, 'procurement', S);
  await fillProcurement(page, 'Ram Achal', '126', '3', '2');
  await page.getByLabel(/Photo evidence/).setInputFiles({ name: 'bags.png', mimeType: 'image/png', buffer: PNG });
  const p = await reviewAndSave(page, /PRSDM-KNM-KH26-P-\d{4}/);
  const url = await openSaved(page, p);
  await expect(page.getByText('file matches its fingerprint')).toHaveCount(1);              // downloaded again and re-hashed
  await page.getByTestId('evidence-file').setInputFiles({ name: 'gate-pass.pdf', mimeType: 'application/pdf', buffer: pdf(`gate pass ${uniq()}`) });
  await page.getByTestId('evidence-attach').click();
  await expect(page.getByTestId('evidence-attached')).toBeVisible();
  await expect(page.getByText('file matches its fingerprint')).toHaveCount(2);
  await expect(page.getByRole('link', { name: 'Document' })).toBeVisible();
  await expect(page.getByRole('row', { name: /Evidence\s+Procurement Op/ })).toHaveCount(2);  // both fingerprints are ledger blocks
  let api = await apiAs(page);
  const files = await api.rows('attachments', `footprint_id=eq.${url.split('/').pop()}&order=created_at`);
  expect(files.map((f) => f.kind)).toEqual(['photo', 'document']);
  const stored = files[0].storage_path as string;
  const again = await api.upload(stored, PNG, 'image/png');
  expect(again.ok, 'a stored file cannot be overwritten').toBe(false);
  await signOut(page);

  await signIn(page, USERS.qc);                                                            // the next stage sees it with the lot
  await page.goto(url);
  await expect(page.getByText('file matches its fingerprint')).toHaveCount(2);
  await signOut(page);

  await signIn(page, USERS.grading);                                                       // an operator of another scope does not
  api = await apiAs(page);
  expect(await api.rows('attachments')).toHaveLength(0);
  const signed = await api.signedUrl(stored);
  expect(signed.ok, 'a signed link to the photo, asked for by an operator who cannot see the record').toBe(false);
  const plant = await api.upload(stored.replace(/[^/]+$/, 'planted.png'), PNG, 'image/png');
  expect(plant.ok, 'a file planted under a record he cannot see').toBe(false);
  await signOut(page);
});

test('A pending grading run corrected to "split" gets its grade lots', async ({ page }) => {
  test.setTimeout(180_000);
  const S = SCOPES.gorakhpur;
  await signIn(page, USERS.procurement);
  const p = await procure(page, S, 'Mohan Lal', '102', '1', '2');
  await signOut(page);
  await signIn(page, USERS.sorting);
  await openSlot(page, 'sorting', S);
  await verifyIncoming(page, p);
  await page.getByRole('button', { name: /Record Sorting/ }).click();
  await page.getByLabel(/^Reject \(kg\)/).fill('0'); await page.getByLabel(/^Loss/).fill('0');
  const s = await reviewAndSave(page, /PRSDM-KNM-KH26-S-\d{4}/);
  await signOut(page);
  await signIn(page, USERS.grading);
  await openSlot(page, 'grading', S);
  await verifyIncoming(page, s);
  await page.getByRole('button', { name: /Record Grading/ }).click();
  await page.getByLabel(/^Grade A/).fill('60'); await page.getByLabel(/^Grade B/).fill('30'); await page.getByLabel(/^Grade C/).fill('8');
  await page.getByLabel(/^Reject/).fill('1'); await page.getByLabel(/^Loss/).fill('1');
  const g = await reviewAndSave(page, /PRSDM-KNM-KH26-G-\d{4}/);                           // saved without the split
  await expect(page.getByTestId('grade-lots')).toHaveCount(0);
  await openSaved(page, g);
  await page.getByRole('link', { name: 'Correct this record' }).click();
  await page.getByLabel(/Split into grade lots/).check();
  await reviewAndSave(page, /PRSDM-KNM-KH26-G-\d{4}/);
  const lots = page.getByTestId('grade-lots');
  await expect(lots).toContainText(/-A \(60 kg\)/); await expect(lots).toContainText(/-B \(30 kg\)/); await expect(lots).toContainText(/-C \(8 kg\)/);
  const lotCodes = (await lots.textContent())!.match(/PRSDM-KNM-KH26-G-\d{4}-[ABC]/g)!;
  expect(lotCodes).toHaveLength(3);
  await signOut(page);
  await signIn(page, USERS.qc);
  await openSlot(page, 'qc', S);
  for (const c of lotCodes) await expect(page.getByTestId('incoming-row').filter({ hasText: c })).toHaveCount(1);
  await expect(page.getByTestId('incoming-row').filter({ hasText: g })).toHaveCount(0);   // the run itself is not a source
  await signOut(page);
});

test('A new person chooses an own password; the manager resets a forgotten one; a deactivated login opens nothing', async ({ page }) => {
  test.setTimeout(240_000);
  const u = uniq();
  const name = `Meera ${u}`, phone = `97${u}11`;
  const mine = `Kalanamak-${u}`, mine2 = `Basmati-${u}`;
  const tempFrom = async () => (await page.getByTestId('temp-password').textContent())!.match(/: (Gv-[A-Za-z0-9_-]+) —/)![1];

  await signIn(page, USERS.cm);
  await page.goto('/users');
  await page.getByLabel('Name').fill(name);
  await page.getByLabel('Mobile').fill(phone);
  await page.getByRole('button', { name: 'Create' }).click();
  await expect(page.getByTestId('temp-password')).toContainText(`+91${phone}`);
  const temp = await tempFrom();
  await signOut(page);

  // First sign-in with the temporary password: nothing of the app until an own password is chosen.
  await signInWith(page, phone, temp);
  await expect(page.getByTestId('must-change')).toBeVisible();
  await expect(page.getByRole('navigation', { name: 'Main' })).toHaveCount(0);
  await page.getByLabel('New password', { exact: true }).fill('short');
  await expect(page.getByTestId('pw-problem')).toContainText('at least 8');
  await expect(page.getByRole('button', { name: 'Set password' })).toBeDisabled();
  await page.getByLabel('New password', { exact: true }).fill(temp);
  await page.getByLabel('New password again').fill(temp);
  await page.getByRole('button', { name: 'Set password' }).click();
  await expect(page.getByRole('alert')).toContainText('different from the one you were given');
  await page.getByLabel('New password', { exact: true }).fill(mine);
  await page.getByLabel('New password again').fill(mine);
  await page.getByRole('button', { name: 'Set password' }).click();
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
  await expect(page.getByText('You are not assigned to any stage yet')).toBeVisible();
  await page.getByRole('link', { name: 'My account' }).click();
  await expect(page.getByTestId('account-me')).toContainText(name);
  await expect(page.getByTestId('account-me')).toContainText('Operator');
  await signOut(page);

  await signInWith(page, phone, temp);                                                      // the temporary one is dead
  await expect(page.getByRole('alert')).toContainText('Wrong sign-in details');
  await signInWith(page, phone, mine);
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
  await expect(page.getByTestId('must-change')).toHaveCount(0);
  await signOut(page);

  // Forgotten: the manager gives a new temporary password. The old one stops working at once.
  await signIn(page, USERS.cm);
  await page.goto('/users');
  const row = page.getByTestId('user-row').filter({ hasText: name });
  await row.getByTestId('reset-password').click();
  await row.getByTestId('reset-confirm').click();
  await expect(page.getByTestId('temp-password')).toContainText(`+91${phone}`);
  const temp2 = await tempFrom();
  expect(temp2).not.toBe(temp);
  await signOut(page);
  await signInWith(page, phone, mine);
  await expect(page.getByRole('alert')).toContainText('Wrong sign-in details');
  await signInWith(page, phone, temp2);
  await expect(page.getByTestId('must-change')).toBeVisible();
  await page.getByLabel('New password', { exact: true }).fill(mine2);
  await page.getByLabel('New password again').fill(mine2);
  await page.getByRole('button', { name: 'Set password' }).click();
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
  await signOut(page);

  // An operator cannot reset anyone, on the screen or through the function.
  await signIn(page, USERS.procurement);
  await expect(page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Users' })).toHaveCount(0);
  await signOut(page);

  // Left the job, or the phone is lost: deactivated. The login still signs in but opens nothing.
  await signIn(page, USERS.cm);
  await page.goto('/users');
  await page.getByTestId('user-row').filter({ hasText: name }).getByRole('button', { name: 'Deactivate' }).click();
  await expect(page.getByTestId('user-row').filter({ hasText: name })).toContainText('inactive');
  await signOut(page);
  await signInWith(page, phone, mine2);
  await expect(page.getByText('no GrainVeda user is linked')).toBeVisible();
  await expect(page.getByRole('navigation', { name: 'Main' })).toHaveCount(0);
  const api = await apiAs(page);
  for (const table of ['footprints', 'farmers', 'scopes', 'slot_assignments', 'ledger']) expect(await api.rows(table), `${table} as a deactivated user`).toHaveLength(0);
  expect((await api.rows('app_users')).map((r) => r.display_name), 'a deactivated user reads only the own row').toEqual([name]);
});

test('A manager gives a stage to a person and takes it away again', async ({ page }) => {
  test.setTimeout(120_000);
  const S = SCOPES.gorakhpur;
  await signIn(page, USERS.cm);
  await page.goto(`/scopes/${S}`);
  const holders = page.getByTestId('slot-holder-sorting');
  await expect(holders).toHaveCount(1);
  await page.getByLabel('Assign Sorting').selectOption({ label: 'Shipment Operator' });
  await expect(holders).toHaveCount(2);
  await expect(holders.filter({ hasText: 'Shipment Operator' })).toHaveCount(1);
  await signOut(page);
  await signIn(page, USERS.shipment);
  await expect(page.locator(`[data-testid="slot-sorting"][data-scope="${S}"]`)).toHaveCount(1);
  await signOut(page);

  await signIn(page, USERS.cm);
  await page.goto(`/scopes/${S}`);
  page.once('dialog', (d) => d.accept());
  await page.getByRole('button', { name: 'Remove: Shipment Operator · Sorting' }).click();
  await expect(page.getByTestId('slot-holder-sorting')).toHaveCount(1);
  await expect(page.getByTestId('slot-holder-sorting')).toContainText('Sorting Operator');       // the regular sorter keeps the stage
  const blocks = await (await apiAs(page)).rows('ledger', `scope_id=eq.${S}&event=eq.supervisory&order=seq.desc&limit=2`);
  expect(blocks.map((b) => (b.payload as { act: string }).act)).toEqual(['slot_removed', 'slot_assigned']);   // both acts are in the ledger
  await signOut(page);
  await signIn(page, USERS.shipment);
  await expect(page.getByTestId('slot-shipment')).toHaveCount(1);                                // his own stage is untouched
  await expect(page.locator(`[data-testid="slot-sorting"][data-scope="${S}"]`)).toHaveCount(0);
  await signOut(page);
});

test('A verified farmer is changed only by the State Manager; deactivated farmers cannot be bought from', async ({ page }) => {
  test.setTimeout(180_000);
  const u = uniq();
  const name = `Kamla ${u}`;
  await signIn(page, USERS.procurement);
  await page.goto('/farmers/new');
  await page.getByLabel('Name *', { exact: true }).fill(name);
  await page.getByLabel('Father / husband name *').fill('Shri Ramdin');
  await page.getByLabel('Village *').fill('Bansi');
  await page.getByLabel('District *').fill('Siddharthnagar');
  await page.getByLabel('Mobile number *').fill(`94${u}31`);
  await page.getByLabel('Land (acres) *').fill('1.5');
  await page.getByRole('button', { name: 'Submit for verification' }).click();
  await expect(page.getByRole('heading', { name: 'Farmers' })).toBeVisible();
  await signOut(page);

  await signIn(page, USERS.sm);
  await page.goto('/farmers');
  await page.getByLabel('Client').selectOption({ label: 'GrainVeda (Prasaadam trade scope)' });
  await page.getByRole('tab', { name: 'Ready to verify' }).click();
  await page.getByTestId('farmer-row').filter({ hasText: name }).getByRole('button', { name: 'Verify and issue Farmer ID' }).click();
  await page.getByRole('tab', { name: 'Active', exact: true }).click();
  const row = page.getByTestId('farmer-row').filter({ hasText: name });
  await expect(row).toContainText(/PRSDM-F-\d{4}/);
  await row.getByRole('link', { name: 'Edit' }).click();
  await expect(page.getByTestId('farmer-verified-note')).toBeVisible();                    // every change is ledgered
  await page.getByLabel('Village *').fill('Bansi Khurd');
  await page.getByRole('button', { name: 'Save' }).click();
  await page.getByRole('tab', { name: 'Active', exact: true }).click();
  await expect(page.getByTestId('farmer-row').filter({ hasText: name })).toContainText('Bansi Khurd');
  await page.getByTestId('farmer-row').filter({ hasText: name }).getByTestId('farmer-inactive').click();
  await page.getByRole('tab', { name: 'Inactive' }).click();
  await expect(page.getByTestId('farmer-row').filter({ hasText: name })).toHaveCount(1);
  await signOut(page);

  await signIn(page, USERS.procurement);
  await openSlot(page, 'procurement', SCOPES.siddharthnagar);
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill('Kamla');
  await expect(page.getByRole('button', { name: /Sita Devi/ })).toHaveCount(0);            // the list has filtered
  await expect(page.getByRole('button', { name: new RegExp(name) })).toHaveCount(0);       // not offered at the farm gate
  await page.goto('/farmers');
  await expect(page.getByTestId('farmer-row').filter({ hasText: name })).toHaveCount(0);
  await signOut(page);

  await signIn(page, USERS.sm);
  await page.goto('/farmers');
  await page.getByLabel('Client').selectOption({ label: 'GrainVeda (Prasaadam trade scope)' });
  await page.getByRole('tab', { name: 'Inactive' }).click();
  await page.getByTestId('farmer-row').filter({ hasText: name }).getByTestId('farmer-active').click();
  await page.getByRole('tab', { name: 'Active', exact: true }).click();
  await expect(page.getByTestId('farmer-row').filter({ hasText: name })).toHaveCount(1);
  await signOut(page);
});

test('Health page: the admin checks the ledger on demand and sees a problem reported from an operator\'s phone', async ({ page }) => {
  test.setTimeout(120_000);
  const marker = `e2e probe ${uniq()}`;
  await signIn(page, USERS.procurement);
  await expect(page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Health' })).toHaveCount(0);
  const reported = page.waitForResponse((r) => r.url().includes('/rpc/report_client_error'));
  await page.evaluate((m) => { setTimeout(() => { throw new Error(m); }, 0); }, marker);     // an uncaught error on his phone
  expect((await reported).ok()).toBe(true);
  expect(await (await apiAs(page)).rows('client_errors'), 'operators cannot read the error log').toHaveLength(0);
  await signOut(page);

  await signIn(page, USERS.cm);
  await expect(page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Health' })).toHaveCount(0);
  await signOut(page);

  await signIn(page, USERS.admin);
  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Health' }).click();
  await expect(page.getByTestId('health-system')).toContainText('Practice: training and testing');
  await page.getByTestId('check-now').click();
  await expect(page.getByTestId('health-ledger')).toContainText(/Ledger check passed: \d+ blocks intact/);
  await expect(page.getByTestId('health-checks').locator('tbody tr').first()).toContainText('Manual');
  const errors = page.getByTestId('health-errors');
  await expect(errors).toContainText(marker);
  await expect(errors.getByRole('row', { name: new RegExp(marker) })).toContainText('Procurement Op (field)');
  await signOut(page);

  await signIn(page, USERS.sm);
  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Health' }).click();
  await expect(page.getByTestId('health-ledger')).toBeVisible();
  await signOut(page);
});
