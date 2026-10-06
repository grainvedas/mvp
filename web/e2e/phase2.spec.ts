import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, openSlotAt } from './helpers';

// Phase 2 through the real screens: T4 (7 people, 2 buyers, labels), T2 (grading split), Village Batch.
const op = (key: string, n: string) => ({ key, phone: `00000000${n}` });
const P = { proc: op('305', '05'), qc: op('306', '06'), qr: op('307', '07'), mill: op('308', '08'), sort: op('309', '09'),
  grade: op('310', '10'), comm: op('311', '11'), ship: op('314', '14'), vb: op('315', '15') };
const uniq = () => String(Date.now()).slice(-5);

// A person who holds stages in several scopes works in one at a time (identity layer): the helper picks the place first.
const open = openSlotAt;
async function verifyIncoming(page: Page, code: string) {
  await page.getByTestId('incoming-row').filter({ hasText: code }).click();
  for (const box of await page.getByRole('checkbox').all()) await box.check();
  await page.getByRole('button', { name: 'Verify this lot' }).click();
  await expect(page.locator('.alert.ok', { hasText: 'Verified' })).toBeVisible();
}
async function reviewAndSave(page: Page, code: RegExp) {
  await expect(page.getByTestId('preview-ok')).toBeVisible();
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save record' }).click();
  await expect(page.getByTestId('saved')).toBeVisible();
  return (await page.getByTestId('saved').textContent())!.match(code)![0];
}
async function procure(page: Page, place: string, farmer: RegExp, gross: string, bags: string, tare: string) {
  await open(page, 'procurement', place);
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill(String(farmer.source).split(' ')[0]);
  await page.getByRole('button', { name: farmer }).click();
  await page.getByLabel(/Gross weight/).fill(gross);
  await page.getByLabel(/^Bags/).fill(bags);
  await page.getByLabel(/Tare per bag/).fill(tare);
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('11.8');
  return reviewAndSave(page, /PRSDM-KNM-KH26-P-\d{4}/);
}
async function qc(page: Page, place: string, from: string, moisture = '11.8') {
  await open(page, 'qc', place);
  await verifyIncoming(page, from);
  await page.getByRole('button', { name: /Record Quality Control/ }).click();
  await page.getByLabel(/Sample drawn/).fill('1');
  await page.getByLabel(/^Moisture \(%\)/).fill(moisture);
  await page.getByLabel(/^Broken grains/).fill('2');
  await page.getByLabel(/^Foreign matter/).fill('0.2');
  return reviewAndSave(page, /PRSDM-KNM-KH26-QC-\d{4}/);
}
async function seal(page: Page, place: string, from: string) {
  await open(page, 'qr_activation', place);
  await verifyIncoming(page, from);
  await page.getByRole('button', { name: 'Activate and seal' }).click();
  return (await page.getByTestId('sealed').textContent())!.match(/GV-[0-9A-F]{12}/)![0];
}

test('T4: procure → QC → mill → pack → two buyers → ship → seal → labels → public page', async ({ page }) => {
  test.setTimeout(180_000);
  const batch = `KNM-KH26-B${uniq()}`;
  await signIn(page, P.proc); const p = await procure(page, 'Basti mill', /Suresh Yadav/, '199', '2', '2'); await signOut(page);
  await signIn(page, P.qc); const q = await qc(page, 'Basti mill', p); await signOut(page);

  await signIn(page, P.mill);
  await open(page, 'milling', 'Basti mill');
  await verifyIncoming(page, q);
  await page.getByRole('button', { name: /Record Milling/ }).click();
  await expect(page.getByLabel(/Paddy in/)).toHaveValue('194');
  await page.getByLabel(/Rice out/).fill('130'); await page.getByLabel(/^Bran/).fill('54'); await page.getByLabel(/^Loss/).fill('10');
  await expect(page.getByTestId('preview-ok')).toContainText('yield below threshold');
  const m = await reviewAndSave(page, /PRSDM-KNM-KH26-M-\d{4}/); await signOut(page);

  await signIn(page, P.sort);
  await open(page, 'packing', 'Basti mill');
  await verifyIncoming(page, m);
  await page.getByRole('button', { name: /Record Packing/ }).click();
  await page.getByLabel('Packets 1').fill('100'); await page.getByLabel('Size (kg) 1').fill('1');
  await page.getByRole('button', { name: '+ packet size' }).click();
  await page.getByLabel('Packets 2').fill('58'); await page.getByLabel('Size (kg) 2').fill('0.5');
  await page.getByLabel(/^Wastage/).fill('1');
  // PRD §12 T4 "batch code mandatory": without it there is nothing to review or save
  await expect(page.locator('.alert.info', { hasText: 'Batch code' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Review' })).toBeDisabled();
  await page.getByLabel(/Batch code/).fill(batch);
  await expect(page.getByTestId('preview-ok')).toContainText('129 kg');
  const pk = await reviewAndSave(page, /PRSDM-KNM-KH26-PK-\d{4}/); await signOut(page);

  await signIn(page, P.comm);
  await open(page, 'commercial', 'Basti mill');
  await verifyIncoming(page, pk);
  await page.getByRole('button', { name: /Record Commercial Clearance/ }).click();
  await page.getByLabel(/^Buyer/).fill('Delhi Wholesaler'); await page.getByLabel(/^Market/).selectOption('domestic');
  await page.getByLabel(/Quantity to this buyer/).fill('50');
  await reviewAndSave(page, /PRSDM-KNM-KH26-CM-\d{4}/);
  await expect(page.getByText('79 kg still available on the source lot')).toBeVisible();
  await page.getByTestId('another').click();
  await page.getByLabel(/^Buyer/).fill('EU Importer'); await page.getByLabel(/^Market/).selectOption('export');
  await page.getByLabel(/Quantity to this buyer/).fill('79');
  const ex = await reviewAndSave(page, /PRSDM-KNM-KH26-CM-\d{4}/); await signOut(page);

  await signIn(page, P.ship);
  await open(page, 'shipment', 'Basti mill');
  await verifyIncoming(page, ex);
  await page.getByRole('button', { name: /Record Shipment/ }).click();
  await expect(page.getByLabel(/^Shipped/)).toHaveValue('79');
  await page.getByLabel(/Transit loss/).fill('0.5'); await page.getByLabel(/Vehicle/).fill('MSKU1234567');
  await page.getByLabel(/Dispatch date/).fill('2026-11-20'); await page.getByLabel(/Destination/).fill('Rotterdam');
  await expect(page.getByTestId('preview-ok')).toContainText('78.5 kg');
  const sh = await reviewAndSave(page, /PRSDM-KNM-KH26-SH-\d{4}/); await signOut(page);

  await signIn(page, P.qr);
  const code = await seal(page, 'Basti mill', sh);
  await page.getByRole('link', { name: 'Print labels' }).click();
  await expect(page.getByTestId('label-sheet').locator('.label')).toHaveCount(12);
  await expect(page.getByTestId('label-sheet').locator('.label').first()).toContainText(batch);
  await page.goto(`/verify/${code}`);
  const pub = page.getByTestId('public-journey');
  await expect(pub).toContainText('Grown by Suresh Yadav');
  await expect(pub).toContainText('Milled');
  await expect(pub).toContainText(`Batch ${batch}`);
  await expect(pub).toContainText('Shipped to Rotterdam');
  await expect(pub).toContainText('Sealed with this QR code');
});

test('T2: sort → grade with split → three grade lots downstream, run hidden → two lots tested and sealed independently', async ({ page }) => {
  test.setTimeout(240_000);
  await signIn(page, P.proc); const p = await procure(page, 'Gorakhpur', /Mohan Lal/, '180', '1', '2'); await signOut(page);
  await signIn(page, P.sort);
  await open(page, 'sorting', 'Gorakhpur');
  await verifyIncoming(page, p);
  await page.getByRole('button', { name: /Record Sorting/ }).click();
  await page.getByLabel(/^Reject \(kg\)/).fill('6'); await page.getByLabel(/^Loss/).fill('2');
  await page.getByLabel('Reason 1').fill('discoloured'); await page.getByLabel('kg 1').fill('6');
  await expect(page.getByTestId('preview-ok')).toContainText('170 kg');
  const s = await reviewAndSave(page, /PRSDM-KNM-KH26-S-\d{4}/); await signOut(page);

  await signIn(page, P.grade);
  await open(page, 'grading', 'Gorakhpur');
  await verifyIncoming(page, s);
  await page.getByRole('button', { name: /Record Grading/ }).click();
  // PRD §12 T2 "A + B + C + reject + loss = input enforced": 100 + 50 + 25 + 3 + 2 = 180 ≠ 170 is refused by the database
  await page.getByLabel(/^Grade A/).fill('100'); await page.getByLabel(/^Grade B/).fill('50'); await page.getByLabel(/^Grade C/).fill('25');
  await page.getByLabel(/^Reject/).fill('3'); await page.getByLabel(/^Loss/).fill('2');
  await expect(page.getByTestId('preview-error')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Review' })).toBeDisabled();
  await page.getByLabel(/^Grade C/).fill('15');
  await page.getByLabel(/Split into grade lots/).check();
  const run = await reviewAndSave(page, /PRSDM-KNM-KH26-G-\d{4}/);
  const lots = page.getByTestId('grade-lots');
  await expect(lots).toContainText(/-A \(100 kg\)/); await expect(lots).toContainText(/-B \(50 kg\)/); await expect(lots).toContainText(/-C \(15 kg\)/);
  const lotCodes = (await lots.textContent())!.match(/PRSDM-KNM-KH26-G-\d{4}-[ABC]/g)!;
  expect(lotCodes).toHaveLength(3);
  const gradeA = lotCodes.find((c) => c.endsWith('-A'))!, gradeB = lotCodes.find((c) => c.endsWith('-B'))!;
  await signOut(page);

  // The three grade lots appear downstream; the run they came from does not (PRD §12 T2 "parent hidden")
  await signIn(page, P.qc);
  await open(page, 'qc', 'Gorakhpur');
  for (const c of lotCodes) await expect(page.getByTestId('incoming-row').filter({ hasText: c })).toBeVisible();
  await expect(page.getByTestId('incoming-row').filter({ hasText: new RegExp(`${run}(?!-)`) })).toHaveCount(0);
  const test1 = async (lot: string, kg: string) => {
    await verifyIncoming(page, lot);
    await page.getByRole('button', { name: /Record Quality Control/ }).click();
    await expect(page.getByLabel(/Lot quantity/)).toHaveValue(kg);
    await page.getByLabel(/Sample drawn/).fill('0.5'); await page.getByLabel(/^Moisture \(%\)/).fill('12.4');
    await page.getByLabel(/^Broken grains/).fill('2'); await page.getByLabel(/^Foreign matter/).fill('0.2');
    return reviewAndSave(page, /PRSDM-KNM-KH26-QC-\d{4}/);
  };
  const qA = await test1(gradeA, '100');
  await page.goto('/');
  await open(page, 'qc', 'Gorakhpur');
  const qB = await test1(gradeB, '50');
  await signOut(page);

  // Each grade lot seals on its own (grade C is left unsealed)
  await signIn(page, P.qr);
  const codeA = await seal(page, 'Gorakhpur', qA);
  await page.goto('/');
  const codeB = await seal(page, 'Gorakhpur', qB);
  expect(codeA).not.toBe(codeB);
  await page.goto(`/verify/${codeA}`);
  await expect(page.getByTestId('public-journey')).toContainText('Graded');
  await expect(page.getByTestId('public-journey')).toContainText('Grade A');
  await page.goto(`/verify/${codeB}`);
  await expect(page.getByTestId('public-journey')).toContainText('Grade B');
  await expect(page.getByTestId('public-journey')).not.toContainText('Grade A');
});

test('Village Batch: two farmer lots verified, batched, tested, sealed; public page names both farmers', async ({ page }) => {
  test.setTimeout(150_000);
  await signIn(page, P.proc);
  const a = await procure(page, 'Bansi batch', /Ram Achal/, '126', '3', '2');
  await page.goto('/');
  const b = await procure(page, 'Bansi batch', /Geeta Kumari/, '166', '2', '2');
  await signOut(page);

  await signIn(page, P.vb);
  await open(page, 'village_batch', 'Bansi batch');
  await verifyIncoming(page, a);
  await page.getByRole('button', { name: 'Back' }).click();
  await verifyIncoming(page, b);
  await page.getByRole('tab', { name: /New Village Batch/ }).click();
  await page.getByRole('checkbox', { name: new RegExp(a) }).check();
  await page.getByRole('checkbox', { name: new RegExp(b) }).check();
  await page.getByRole('textbox', { name: 'Village *', exact: true }).fill('Bansi');
  await expect(page.getByTestId('preview-ok')).toContainText('282 kg');
  const vb = await reviewAndSave(page, /PRSDM-KNM-KH26-VB-\d{4}/);
  await signOut(page);

  await signIn(page, P.qc); const q = await qc(page, 'Bansi batch', vb); await signOut(page);
  await signIn(page, P.qr); const code = await seal(page, 'Bansi batch', q);
  await page.goto(`/verify/${code}`);
  const pub = page.getByTestId('public-journey');
  await expect(pub).toContainText('2 farmers of Bansi');
  await expect(pub).toContainText('Ram Achal, Bansi');
  await expect(pub).toContainText('Geeta Kumari, Naugarh');
});
