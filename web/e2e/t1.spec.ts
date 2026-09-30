import { test, expect } from '@playwright/test';
import { signIn, signOut, USERS } from './helpers';

// PRD §12 T1 through the real screens, signed in as three different people: procure → QC → seal → public page.
test('T1: procurement → QC → QR seal from the UI', async ({ page }) => {
  // 1. Procurement operator records Sita Devi's lot
  await signIn(page, USERS.procurement);
  await page.getByTestId('slot-procurement').filter({ hasText: 'Siddharthnagar' }).click();
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill('Sita');
  await page.getByRole('button', { name: /Sita Devi/ }).click();
  await page.getByLabel(/Gross weight/).fill('150');
  await page.getByLabel(/^Bags/).fill('1');
  await page.getByLabel(/Tare per bag/).fill('2.5');
  await page.getByLabel('Moisture (3 readings) 1').fill('11.9');
  await page.getByLabel('Moisture (3 readings) 2').fill('11.8');
  await page.getByLabel('Moisture (3 readings) 3').fill('12.0');
  await expect(page.getByTestId('preview-ok')).toContainText('147.5 kg');
  await page.getByRole('button', { name: 'Review' }).click();
  await expect(page.getByTestId('review-qty-out')).toHaveText('147.5 kg');
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save record' }).click();
  await expect(page.getByTestId('saved')).toContainText(/Saved as PRSDM-KNM-KH26-P-\d{4} · 147.5 kg/);
  const code = (await page.getByTestId('saved').textContent())!.match(/PRSDM-KNM-KH26-P-\d{4}/)![0];
  await signOut(page);

  // 2. QC technician verifies what arrived, then records QC
  await signIn(page, USERS.qc);
  await page.getByTestId('slot-qc').filter({ hasText: 'Siddharthnagar' }).click();
  await page.getByTestId('incoming-row').filter({ hasText: code }).click();
  const verifyBtn = page.getByRole('button', { name: 'Verify this lot' });
  await expect(verifyBtn).toBeDisabled();
  for (const box of await page.getByRole('checkbox').all()) await box.check();
  await verifyBtn.click();
  await page.getByRole('button', { name: /Record Quality Control for this lot/ }).click();
  await expect(page.getByLabel(/Lot quantity/)).toHaveValue('147.5');
  await page.getByLabel(/Sample drawn/).fill('0.5');
  await page.getByLabel(/^Moisture \(%\)/).fill('11.9');
  await page.getByLabel(/^Broken grains/).fill('2');
  await page.getByLabel(/^Foreign matter/).fill('0.2');
  await expect(page.getByTestId('preview-ok')).toContainText('147 kg');
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save record' }).click();
  await expect(page.getByTestId('saved')).toContainText('147 kg');
  const qcCode = (await page.getByTestId('saved').textContent())!.match(/PRSDM-KNM-KH26-QC-\d{4}/)![0];
  await signOut(page);

  // 3. QR operator verifies QC and seals
  await signIn(page, USERS.qr);
  await page.getByTestId('slot-qr_activation').filter({ hasText: 'Siddharthnagar' }).click();
  await page.getByTestId('incoming-row').filter({ hasText: qcCode }).click();
  for (const box of await page.getByRole('checkbox').all()) await box.check();
  await page.getByRole('button', { name: 'Verify this lot' }).click();
  await page.getByRole('button', { name: 'Activate and seal' }).click();
  await expect(page.getByTestId('sealed')).toContainText(/Sealed\. QR code GV-[0-9A-F]{12}/);
  const qr = (await page.getByTestId('sealed').textContent())!.match(/GV-[0-9A-F]{12}/)![0];
  await expect(page.getByRole('img', { name: `QR code ${qr}` })).toBeVisible();

  // 4. Anyone, no login, can verify the lot
  await page.goto(`/verify/${qr}`);
  const pub = page.getByTestId('public-journey');
  await expect(pub).toContainText('Kalanamak rice');
  await expect(pub).toContainText('Grown by Sita Devi, Itwa');
  await expect(pub).not.toContainText('9000000002');
});
