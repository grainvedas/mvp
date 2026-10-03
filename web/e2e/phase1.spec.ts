import { test, expect, type Page } from '@playwright/test';
import writeXlsxFile from 'write-excel-file/node';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { signIn, signOut, USERS } from './helpers';

const uniq = () => String(Date.now()).slice(-6);

async function reviewAndSave(page: Page) {
  await expect(page.getByTestId('preview-ok')).toBeVisible();
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save record' }).click();
  await expect(page.getByTestId('saved')).toBeVisible();
  return (await page.getByTestId('saved').textContent())!;
}
async function verifyIncoming(page: Page, code: string) {
  await page.getByTestId('incoming-row').filter({ hasText: code }).click();
  for (const box of await page.getByRole('checkbox').all()) await box.check();
  await page.getByRole('button', { name: 'Verify this lot' }).click();
  await expect(page.locator('.alert.ok', { hasText: 'Verified' })).toBeVisible();
}

test('Lot Inward → QC (export fail) → seal; Client Manager overrides with a reason', async ({ page }) => {
  await signIn(page, USERS.lotInward);
  await page.getByTestId('slot-lot_inward').click();
  await page.getByLabel(/Declared quantity/).fill('500');
  await page.getByLabel(/Actual weighed/).fill('480');
  await page.getByLabel(/Source type/).selectOption('fpo');
  await page.getByLabel(/Source name/).fill('Kushinagar FPO');
  await page.getByLabel(/Crop declared/).fill('Kalanamak');
  await page.getByLabel(/Moisture baseline/).fill('12.5');
  await expect(page.getByTestId('preview-ok')).toContainText('declared vs weighed variance exceeds tolerance');
  const saved = await reviewAndSave(page);
  const liCode = saved.match(/PRSDM-KNM-KH26-LI-\d{4}/)![0];
  await signOut(page);

  await signIn(page, USERS.qc);
  await page.getByTestId('slot-qc').filter({ hasText: 'Gorakhpur mandi' }).click();
  await verifyIncoming(page, liCode);
  await page.getByRole('button', { name: /Record Quality Control/ }).click();
  await page.getByLabel(/Sample drawn/).fill('1');
  await page.getByLabel(/^Moisture \(%\)/).fill('12.5');
  await page.getByLabel(/^Broken grains/).fill('2');
  await page.getByLabel(/^Foreign matter/).fill('0.2');
  const qcSaved = await reviewAndSave(page);
  const qcCode = qcSaved.match(/PRSDM-KNM-KH26-QC-\d{4}/)![0];
  await page.getByRole('link', { name: `Open ${qcCode}` }).click();
  await expect(page.getByText(/Domestic\s*Pass/)).toBeVisible();
  await expect(page.getByText(/Export\s*Fail/)).toBeVisible();
  await expect(page.getByRole('button', { name: 'Override the export verdict' })).toHaveCount(0);   // operators cannot
  const qcUrl = page.url();
  await signOut(page);

  await signIn(page, USERS.cm);
  await page.goto(qcUrl);
  await page.getByLabel('Reason (kept in the audit trail)').fill('Buyer accepts 12.5% with re-drying at destination');
  await page.getByRole('button', { name: 'Override the export verdict' }).click();
  await expect(page.getByText(/Override: export · “Buyer accepts 12.5%/)).toBeVisible();
  await expect(page.getByText(/Export\s*Fail/)).toBeVisible();                                         // derived verdict kept
  await signOut(page);

  await signIn(page, USERS.qr);
  await page.getByTestId('slot-qr_activation').filter({ hasText: 'Gorakhpur mandi' }).click();
  await verifyIncoming(page, qcCode);
  await page.getByRole('button', { name: 'Activate and seal' }).click();
  const qr = (await page.getByTestId('sealed').textContent())!.match(/GV-[0-9A-F]{12}/)![0];
  await page.goto(`/verify/${qr}`);
  await expect(page.getByTestId('public-journey')).toContainText('Received from Kushinagar FPO');
  await expect(page.getByTestId('public-journey')).toContainText('export approved with a recorded reason');
});

test('Scope wizard: build a chain, create a person for a stage, activate', async ({ page }) => {
  const u = uniq();
  await signIn(page, USERS.cm);
  await page.goto('/scopes/new');
  await page.getByLabel(/Geography/).fill(`Deoria ${u}`);
  await page.getByRole('button', { name: 'Next' }).click();
  await page.getByLabel('Crop').selectOption({ label: 'Kalanamak rice' });
  await page.getByRole('button', { name: 'Next' }).click();
  await page.getByTestId('before-sorting').check();
  await expect(page.getByTestId('chain-preview')).toContainText('Procurement (farm-gate) → Sorting → Quality Control → QR Activation (seal)');
  await expect(page.getByText('This chain is valid.')).toBeVisible();
  await page.getByRole('button', { name: /Save draft/ }).click();
  await expect(page.getByRole('heading', { name: new RegExp(`Deoria ${u}`) })).toContainText('Draft');
  await page.getByRole('row', { name: /Sorting/ }).getByRole('button', { name: '+ new person' }).click();
  await page.getByLabel('Name').fill(`Sorter ${u}`);
  await page.getByLabel('Mobile').fill(`97${u}11`);
  await page.getByRole('button', { name: 'Create' }).click();
  await expect(page.getByTestId('temp-password')).toContainText(/Temporary password for \+9197\d{6}11: Gv-/);
  await expect(page.getByRole('row', { name: /Sorting/ })).toContainText(`Sorter ${u}`);
  page.once('dialog', (d) => d.accept());
  await page.getByRole('button', { name: 'Activate scope' }).click();
  await expect(page.getByRole('heading', { name: new RegExp(`Deoria ${u}`) })).toContainText('Active');
});

test('Farmer: operator registers and submits; State Manager verifies and a Farmer ID is issued', async ({ page }) => {
  const u = uniq();
  await signIn(page, USERS.procurement);
  await page.goto('/farmers/new');
  await page.getByLabel('Name *', { exact: true }).fill(`Kalawati ${u}`);
  await page.getByLabel('Father / husband name *').fill('Shri Ramdin');
  await page.getByLabel('Village *').fill('Bansi');
  await page.getByLabel('District *').fill('Siddharthnagar');
  await page.getByLabel('Mobile number *').fill(`96${u}21`);
  await page.getByLabel('Land (acres) *').fill('1.75');
  await page.getByRole('button', { name: 'Submit for verification' }).click();
  await expect(page.getByRole('heading', { name: 'Farmers' })).toBeVisible();
  await signOut(page);

  await signIn(page, USERS.sm);
  await page.goto('/farmers');
  await page.getByLabel('Client').selectOption({ label: 'GrainVeda (Prasaadam trade scope)' });
  await page.getByRole('tab', { name: 'Ready to verify' }).click();
  const row = page.getByTestId('farmer-row').filter({ hasText: `Kalawati ${u}` });
  await row.getByRole('button', { name: 'Verify and issue Farmer ID' }).click();
  await page.getByRole('tab', { name: 'Active', exact: true }).click();
  await expect(page.getByTestId('farmer-row').filter({ hasText: `Kalawati ${u}` })).toContainText(/PRSDM-F-\d{4}/);
});

test('Excel import: bad rows are named and nothing is imported; a clean file imports', async ({ page }) => {
  const u = uniq();
  const header = ['name', 'guardian_name', 'village', 'district', 'phone', 'land_area_acres'].map((value) => ({ value }));
  const bad = join(tmpdir(), `bad-${u}.xlsx`), good = join(tmpdir(), `good-${u}.xlsx`);
  await writeXlsxFile([header,
    ['Asha', 'Shri A', 'Itwa', 'Siddharthnagar', `95${u}01`, 1].map((value) => ({ value })),
    ['', 'Shri B', 'Itwa', 'Siddharthnagar', `95${u}02`, 1].map((value) => ({ value })),
    ['Chandra', 'Shri C', 'Itwa', 'Siddharthnagar', '12345', 1].map((value) => ({ value }))], { filePath: bad });
  await writeXlsxFile([header,
    ['Durga', 'Shri D', 'Naugarh', 'Siddharthnagar', `95${u}03`, 2].map((value) => ({ value })),
    ['Ekta', 'Shri E', 'Naugarh', 'Siddharthnagar', `95${u}04`, 3].map((value) => ({ value }))], { filePath: good });
  await signIn(page, USERS.procurement);
  await page.goto('/farmers/import');
  await page.getByLabel('Choose the filled Excel file').setInputFiles(bad);
  const errs = page.getByTestId('import-errors');
  await expect(errs).toContainText('2 problems found');
  await expect(errs.getByRole('row', { name: /^3 name required/ })).toBeVisible();
  await expect(errs.getByRole('row', { name: /^4 phone not a 10-digit/ })).toBeVisible();
  await page.getByLabel('Choose the filled Excel file').setInputFiles(good);
  await page.getByRole('button', { name: 'Import 2 farmers' }).click();
  await expect(page.getByTestId('import-done')).toContainText('2 farmers imported');
});

test('Role rules are visible in the UI: QC technician has no Farmers menu; client view cannot record', async ({ page }) => {
  await signIn(page, USERS.qc);
  await expect(page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Farmers' })).toHaveCount(0);
  await signOut(page);
  await signIn(page, USERS.view);
  await page.goto('/farmers');
  await expect(page.getByRole('link', { name: 'New farmer' })).toHaveCount(0);
  await page.goto('/work/00000000-0000-4000-8000-000000000401/procurement');
  await expect(page.getByRole('tab', { name: /New Procurement/ })).toHaveCount(0);
});

test('Correct a pending record; flag it; manager resolves the flag', async ({ page }) => {
  await signIn(page, USERS.procurement);
  await page.goto('/work/00000000-0000-4000-8000-000000000403/procurement');
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill('Mohan');
  await page.getByRole('button', { name: /Mohan Lal/ }).click();
  await page.getByLabel(/Gross weight/).fill('100');
  await page.getByLabel(/^Bags/).fill('2');
  await page.getByLabel(/Tare per bag/).fill('1');
  for (const [i, v] of ['12', '12.1', '12.2'].entries()) await page.getByLabel(`Moisture (3 readings) ${i + 1}`).fill(v);
  const saved = await reviewAndSave(page);
  expect(saved).toContain('98 kg');
  await page.getByRole('link', { name: /^Open PRSDM/ }).click();
  await page.getByRole('link', { name: 'Correct this record' }).click();
  await page.getByLabel(/Gross weight/).fill('110');
  await expect(page.getByTestId('preview-ok')).toContainText('108 kg');
  const corrected = await reviewAndSave(page);
  expect(corrected).toContain('108 kg');
  await page.getByRole('link', { name: /^Open PRSDM/ }).click();
  const recordUrl = page.url();
  await page.getByPlaceholder('Raise a flag').fill('Bag count looked off on the truck');
  await page.getByRole('button', { name: 'Raise a flag' }).click();
  await expect(page.getByText('Bag count looked off on the truck')).toBeVisible();
  await signOut(page);

  await signIn(page, USERS.cm);
  await page.goto('/flags');
  await expect(page.getByText('Bag count looked off on the truck')).toBeVisible();
  await page.goto(recordUrl);
  await expect(page.getByRole('link', { name: 'Correct this record' })).toBeVisible();   // managers may correct too
  await page.getByRole('button', { name: 'Resolve' }).click();
  await expect(page.getByText(/Resolved\s*Bag count/)).toBeVisible();
});
