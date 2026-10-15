// Migration 47 (Veda, 14 Oct 2026, on staging): the person at Procurement and a farmer already verified, on a 527 px
// screen. His lot is refused because the farmer's good farming practice is not filled in; the form now takes him there,
// he answers it, and the lot is saved. Another detail he finds wrong he proposes, with a reason; the Client Manager
// approves it on his Farmers page. Every rule is the database's (tests/41_farmer_proposals.sql).
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, openSlot, reviewAndSave, localStack, USERS, SCOPES, pickFarmer } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const KALANAMAK = '00000000-0000-4000-8000-000000000101';
const fillLot = async (page: Page) => {
  await pickFarmer(page, /Geeta Kumari/);
  await page.getByLabel(/Gross weight/).fill('100');
  await page.getByLabel(/^Bags/).fill('2');
  await page.getByLabel(/Tare per bag/).fill('1');
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('11.9');
};

test('Procurement: the farmer\'s practice filled in from the refused lot; a correction proposed and approved by the Client Manager', async ({ page }) => {
  test.setTimeout(180_000);
  const local = localStack();
  test.skip(!local, 'sets a crop\'s practice list as the State Manager would: local stack only');
  const u = String(Date.now()).slice(-6);
  await local!.setCropGap(KALANAMAK, [{ key: `seed_${u}`, label: 'Seed source certified', type: 'yesno', required: true }]);
  try {
    // 1 · the lot is refused, and the form says where to fill the practice in
    await signIn(page, USERS.procurement);
    await openSlot(page, 'procurement', SCOPES.siddharthnagar);
    await fillLot(page);
    await expect(page.getByTestId('preview-error')).toContainText('good farming practice for Kalanamak rice is not complete');
    await page.getByTestId('fill-practice').click();
    await expect(page.getByTestId('farmer-practice')).toContainText('Geeta Kumari');
    const gap = page.getByTestId('farmer-gap');
    await gap.getByLabel('Seed source certified *').selectOption('yes');
    await gap.getByTestId('gap-save').click();
    await expect(gap.getByTestId('gap-complete')).toBeVisible();
    await expectNoSideScroll(page);
    // 2 · it counts at once: the lot is saved
    await openSlot(page, 'procurement', SCOPES.siddharthnagar);
    await fillLot(page);
    const code = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?P-\d{4}/);
    expect(code).toMatch(/PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?P-\d{4}/);

    // 3 · another detail: proposed with a reason, from his Farmers list
    await page.goto('/farmers');
    await page.getByTestId('farmer-row').filter({ hasText: 'Geeta Kumari' }).getByTestId('farmer-practice-link').click();
    await expect(page.getByTestId('fp-send')).toBeDisabled();
    await page.getByTestId('fp-notes').fill(`TEST rain-fed plot ${u}`);
    await expect(page.getByTestId('fp-changes')).toContainText('Notes');
    await page.getByTestId('fp-reason').fill('told at the farm gate');
    await page.getByTestId('fp-send').click();
    await expect(page.getByTestId('fp-sent')).toBeVisible();
    const mine = page.getByTestId('fp-item').filter({ hasText: `TEST rain-fed plot ${u}` });
    await expect(mine).toHaveAttribute('data-status', 'requested');
    await expect(mine.getByTestId('fp-approve')).toHaveCount(0);                 // not his to approve
    await expectNoSideScroll(page);
    await signOut(page);

    // 4 · the Client Manager approves it on his Farmers page
    await signIn(page, USERS.cm);
    await page.goto('/farmers');
    const item = page.getByTestId('fp-item').filter({ hasText: `TEST rain-fed plot ${u}` });
    await expect(item).toContainText('Proposed by Procurement Op (field)');
    await item.getByTestId('fp-approve').click();
    await expect(page.getByTestId('fp-item').filter({ hasText: `TEST rain-fed plot ${u}` })).toHaveAttribute('data-status', 'approved');
    await expectNoSideScroll(page);
    await signOut(page);
  } finally {
    await local!.setCropGap(KALANAMAK, []);
  }
});
