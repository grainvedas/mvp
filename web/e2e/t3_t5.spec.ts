import { test, expect } from '@playwright/test';
import { signIn, signOut, USERS, SCOPES, openSlot, verifyIncoming, reviewAndSave, procure, recordQc, sealLot, apiAs, refusal } from './helpers';

// PRD §12 T3 and T5 through the real screens. Where the PRD says "cannot", the test also asks the database directly
// with that person's own token (helpers.apiAs): hiding a button is not the rule, the refusal is.

async function recordId(page: import('@playwright/test').Page, code: string) {
  const rows = await (await apiAs(page)).rows('footprints', `footprint_code=eq.${code}`);
  expect(rows, `the signed-in user should see ${code}`).toHaveLength(1);
  return rows[0].id as string;
}

test('T3: domestic-only lot is not offered for export; export-passed lot is; a manager override opens export with an audit entry', async ({ page }) => {
  test.setTimeout(300_000);
  const S = SCOPES.basti;                                   // procurement → QC → milling → commercial → QR

  // Two farm-gate lots (PRD sample data): Ram Achal 120 kg will test at 12.1 % (domestic only), Sita Devi 147.5 kg at 11.9 %.
  await signIn(page, USERS.procurement);
  const pA = await procure(page, S, 'Ram Achal', '124', '2', '2', '12.1');
  await page.goto('/');
  const pB = await procure(page, S, 'Sita Devi', '150', '1', '2.5', '11.9');
  await signOut(page);

  await signIn(page, USERS.qc);
  const qA = await recordQc(page, S, pA, '12.1');
  await page.getByRole('link', { name: `Open ${qA}` }).click();
  await expect(page.getByText(/Domestic\s*Pass/)).toBeVisible();
  await expect(page.getByText(/Export\s*Fail/)).toBeVisible();
  const qcUrlA = page.url();
  await page.goto('/');
  const qB = await recordQc(page, S, pB, '11.9');
  await signOut(page);

  await signIn(page, USERS.mill);
  await openSlot(page, 'milling', S);
  await verifyIncoming(page, qA);
  await page.getByRole('button', { name: /Record Milling/ }).click();
  await expect(page.getByLabel(/Paddy in/)).toHaveValue('119');                       // 120 − 1 kg sample
  await page.getByLabel(/Rice out/).fill('80'); await page.getByLabel(/^Bran/).fill('30'); await page.getByLabel(/^Loss/).fill('9');
  const mA = await reviewAndSave(page, /PRSDM-KNM-KH26-M-\d{4}/);
  await page.goto('/');
  await openSlot(page, 'milling', S);
  await verifyIncoming(page, qB);
  await page.getByRole('button', { name: /Record Milling/ }).click();
  await expect(page.getByLabel(/Paddy in/)).toHaveValue('146.5');
  await page.getByLabel(/Rice out/).fill('100'); await page.getByLabel(/^Bran/).fill('36.5'); await page.getByLabel(/^Loss/).fill('10');
  const mB = await reviewAndSave(page, /PRSDM-KNM-KH26-M-\d{4}/);
  await signOut(page);

  // Commercial: the domestic-only lot is not offered for export, on the screen and in the database.
  await signIn(page, USERS.commercial);
  await openSlot(page, 'commercial', S);
  await verifyIncoming(page, mA);
  await expect(page.getByTestId('market-verdict')).toContainText(/domestic\s*passed/);
  await expect(page.getByTestId('market-verdict')).toContainText(/export\s*not met/);
  await page.getByRole('button', { name: /Record Commercial Clearance/ }).click();
  const market = page.getByLabel(/^Market/);
  await expect(market.locator('option[value="domestic"]')).toHaveCount(1);
  await expect(market.locator('option[value="export"]')).toHaveCount(0);
  await expect(page.getByTestId('market-gate')).toContainText('Export is not offered');
  const mAid = await recordId(page, mA);
  const api = await apiAs(page);
  const forced = await api.insert('footprints', { scope_id: S, client_id: '00000000-0000-4000-8000-000000000201', stage_type: 'commercial',
    prev_footprint_id: mAid, created_by: '00000000-0000-4000-8000-000000000311', payload: { buyer: 'EU Importer', market: 'export', qty_kg: 10 } });
  expect(forced.ok, 'an export sale of a domestic-only lot sent straight to the API').toBe(false);
  expect(refusal(forced)).toMatch(/export/i);
  // …a domestic sale of the same lot is fine
  await page.getByLabel(/^Buyer/).fill('Delhi Wholesaler'); await market.selectOption('domestic');
  await page.getByLabel(/Quantity to this buyer/).fill('30');
  await reviewAndSave(page, /PRSDM-KNM-KH26-CM-\d{4}/);
  await expect(page.getByText('50 kg still available on the source lot')).toBeVisible();

  // The export-passed lot is offered for export.
  await page.goto('/');
  await openSlot(page, 'commercial', S);
  await verifyIncoming(page, mB);
  await expect(page.getByTestId('market-verdict')).toContainText(/export\s*passed/);
  await page.getByRole('button', { name: /Record Commercial Clearance/ }).click();
  await expect(page.getByLabel(/^Market/).locator('option[value="export"]')).toHaveCount(1);
  await expect(page.getByTestId('market-gate')).toHaveCount(0);
  await page.getByLabel(/^Buyer/).fill('EU Importer'); await page.getByLabel(/^Market/).selectOption('export');
  await page.getByLabel(/Quantity to this buyer/).fill('100');
  const exB = await reviewAndSave(page, /PRSDM-KNM-KH26-CM-\d{4}/);
  await signOut(page);

  // The Client Manager overrides the failed export verdict with a reason: kept, named, and in the ledger.
  await signIn(page, USERS.cm);
  await page.goto(qcUrlA);
  await page.getByLabel('Reason (kept in the audit trail)').fill('Buyer accepts 12.1% with re-drying at destination');
  await page.getByRole('button', { name: 'Override the export verdict' }).click();
  await expect(page.getByText(/Override: export · “Buyer accepts 12.1%/)).toBeVisible();
  await expect(page.getByText(/Export\s*Fail/)).toBeVisible();                           // the derived verdict is not rewritten
  await expect(page.getByRole('row', { name: /Override\s+Prasaadam Client Manager/ })).toBeVisible();   // audit entry
  await signOut(page);

  // Now the same lot is offered for export, and says why.
  await signIn(page, USERS.commercial);
  await openSlot(page, 'commercial', S);
  await page.getByTestId('incoming-row').filter({ hasText: mA }).click();
  await expect(page.getByTestId('market-verdict')).toContainText('export approved with a recorded reason');
  await page.getByRole('button', { name: /Record Commercial Clearance/ }).click();
  await expect(page.getByLabel(/^Market/).locator('option[value="export"]')).toHaveCount(1);
  await page.getByLabel(/^Buyer/).fill('EU Importer'); await page.getByLabel(/^Market/).selectOption('export');
  await page.getByLabel(/Quantity to this buyer/).fill('50');
  const exA = await reviewAndSave(page, /PRSDM-KNM-KH26-CM-\d{4}/);
  await signOut(page);

  // Seal both export sales; the public page discloses the override on one and not on the other.
  await signIn(page, USERS.qr);
  const codeA = await sealLot(page, S, exA);
  await page.goto('/');
  const codeB = await sealLot(page, S, exB);
  await page.goto(`/verify/${codeA}`);
  const pub = page.getByTestId('public-journey');
  await expect(pub).toContainText('Grown by Ram Achal');
  await expect(pub).toContainText('Milled');
  await expect(pub).toContainText(/export\s*not met/);
  await expect(pub).toContainText('export approved with a recorded reason');
  await page.goto(`/verify/${codeB}`);
  await expect(pub).toContainText('Grown by Sita Devi');
  await expect(pub).toContainText(/export\s*passed/);
  await expect(pub).not.toContainText('export approved with a recorded reason');
});

test('T5: an operator works only at the assigned stage of the assigned scope; farmers and the QR seal are closed to everyone else', async ({ page }) => {
  test.setTimeout(240_000);
  const PRSDM = '00000000-0000-4000-8000-000000000201';

  // Something real to be kept away from: a lot waiting for Sorting in Gorakhpur, and a tested lot in Siddharthnagar.
  await signIn(page, USERS.procurement);
  const pSort = await procure(page, SCOPES.gorakhpur, 'Mohan Lal', '180', '1', '2');
  const pSortId = await recordId(page, pSort);
  await page.goto('/');
  const pSeal = await procure(page, SCOPES.siddharthnagar, 'Geeta Kumari', '164', '1', '2');
  const pSealId = await recordId(page, pSeal);
  expect((await (await apiAs(page)).rows('farmers')).length, 'the procurement operator sees the farmer registry').toBeGreaterThanOrEqual(5);
  await signOut(page);

  // 1. The Grading operator cannot create at Sorting.
  await signIn(page, USERS.grading);
  await expect(page.locator('[data-testid^="slot-"]')).toHaveCount(1);
  await expect(page.getByTestId('slot-grading')).toHaveCount(1);
  await page.goto(`/work/${SCOPES.gorakhpur}/sorting`);
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  await expect(page.getByTestId('incoming-row')).toHaveCount(0);                         // not even the waiting lot is shown to him
  await expect(page.getByRole('button', { name: /Record Sorting/ })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Verify this lot' })).toHaveCount(0);
  let api = await apiAs(page);
  const asGrader = await api.insert('footprints', { scope_id: SCOPES.gorakhpur, client_id: PRSDM, stage_type: 'sorting', prev_footprint_id: pSortId,
    created_by: '00000000-0000-4000-8000-000000000310', payload: { input_kg: 178, reject_kg: 0, loss_kg: 0, reject_reasons: [] } });
  expect(asGrader.ok, 'a Sorting record sent straight to the API by the Grading operator').toBe(false);
  const verifyAsGrader = await api.rpc('verify_footprint', { p_fp: pSortId });
  expect(verifyAsGrader.ok, 'verifying the lot waiting for Sorting, as the Grading operator').toBe(false);

  // 2. An operator in one scope sees nothing of another scope (same client), on the screen or through the API.
  expect(await api.rows('footprints', `scope_id=eq.${SCOPES.siddharthnagar}`)).toHaveLength(0);
  expect(await api.rows('footprints', `scope_id=eq.${SCOPES.basti}`)).toHaveLength(0);
  expect(await api.rows('footprints', `id=eq.${pSealId}`)).toHaveLength(0);
  await page.goto(`/records/${pSealId}`);
  await expect(page.getByRole('alert')).toBeVisible();
  await expect(page.getByText(pSeal)).toHaveCount(0);
  await page.goto(`/work/${SCOPES.siddharthnagar}/qc`);
  await expect(page.getByRole('alert')).toBeVisible();
  await expect(page.getByTestId('incoming-row')).toHaveCount(0);

  // 3. Farmers are hidden from non-procurement operators.
  await expect(page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Farmers' })).toHaveCount(0);
  expect(await api.rows('farmers')).toHaveLength(0);
  await signOut(page);

  // …and another client's operator sees nothing at all of this client.
  await signIn(page, USERS.otherClient);
  await expect(page.getByTestId('no-assignment')).toContainText('A manager will assign you to your work soon');   // nobody has assigned him: the calm screen
  api = await apiAs(page);
  for (const table of ['footprints', 'farmers', 'scopes', 'qc_verdicts', 'qr_seals', 'flags', 'ledger']) {
    expect(await api.rows(table), `${table} as another client's operator`).toHaveLength(0);
  }
  await signOut(page);

  // 4. The QR seal is gated to the assigned sealer: the QC technician tests the lot but cannot seal it.
  await signIn(page, USERS.qc);
  await expect(page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Farmers' })).toHaveCount(0);
  const q = await recordQc(page, SCOPES.siddharthnagar, pSeal, '11.8');
  const qId = await recordId(page, q);
  api = await apiAs(page);
  expect(await api.rows('farmers')).toHaveLength(0);
  await page.goto(`/work/${SCOPES.siddharthnagar}/qr_activation`);
  await expect(page.getByRole('button', { name: 'Activate and seal' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Verify this lot' })).toHaveCount(0);
  const gate = await api.insert('footprints', { scope_id: SCOPES.siddharthnagar, client_id: PRSDM, stage_type: 'qr_activation', prev_footprint_id: qId,
    created_by: '00000000-0000-4000-8000-000000000306', payload: {} });
  expect(gate.ok, 'a QR record sent straight to the API by the QC technician').toBe(false);
  const sealAttempt = await api.rpc('seal_lot', { p_qr_fp: qId });
  expect(sealAttempt.ok, 'seal_lot called by the QC technician').toBe(false);
  expect(await api.rows('qr_seals', `footprint_id=eq.${qId}`)).toHaveLength(0);
  await signOut(page);

  // The assigned sealer can.
  await signIn(page, USERS.qr);
  const code = await sealLot(page, SCOPES.siddharthnagar, q);
  expect(code).toMatch(/^GV-[0-9A-F]{12}$/);
  await signOut(page);
});
