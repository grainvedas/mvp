// Migration 49 (Veda, 15 Oct 2026: the operator-stages brief, release 2, "numbers you can trust"), on a 527 px screen,
// scope Basti (Procurement → QC → Milling → Commercial → QR). The receiver sees what the system checked and ticks only
// what he sees; the lots waiting show what is left on them and the form starts from it; a milling outturn above the
// crop's ceiling is warned in plain words; "New record" opens without reloading; the record page says where the lot
// comes from, its farmers and its GI status. Every rule is the database's (tests/43_trust_numbers.sql).
import { test, expect } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, openSlot, procure, reviewAndSave, localStack, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const S = SCOPES.basti;
const KALANAMAK = '00000000-0000-4000-8000-000000000101';

test('system checks and physical ticks, what is left, the outturn ceiling, no reload, lineage and GI', async ({ page }) => {
  test.setTimeout(240_000);
  const local = localStack();

  // 1 · a lot at Procurement; QC sees what the system checked and ticks only what he sees (A2/G3)
  await signIn(page, USERS.procurement);
  const lot = await procure(page, S, 'Ram Achal', '126', '3', '2', '12');           // 120 kg
  await signOut(page);
  await signIn(page, USERS.qc);
  await openSlot(page, 'qc', S);
  await page.getByTestId('incoming-row').filter({ hasText: lot }).click();
  const sys = page.getByTestId('system-checks');
  await expect(sys).toContainText('The farmer Ram Achal is verified');
  await expect(sys).toContainText('Three moisture readings recorded');
  await expect(sys.locator('li[data-ok="true"]')).not.toHaveCount(0);
  await expect(page.getByLabel('Bags counted: the number matches the record')).toBeVisible();
  await expect(page.getByLabel('Net quantity reviewed')).toHaveCount(0);                      // the system's, not a tick any more
  await expect(page.getByTestId('verify-button')).toBeDisabled();
  for (const box of await page.getByRole('checkbox').all()) await box.check();
  await page.getByTestId('verify-button').click();
  await expect(page.locator('.alert.ok', { hasText: 'Verified' })).toBeVisible();
  await page.getByRole('button', { name: /Record Quality Control/ }).click();
  await page.getByLabel(/Sample drawn/).fill('1');
  await page.getByLabel(/^Moisture \(%\)/).fill('11.8');
  await page.getByLabel(/^Broken grains/).fill('2');
  await page.getByLabel(/^Foreign matter/).fill('0.2');
  const q = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?QC-\d{4}/);         // 119 kg
  await signOut(page);

  // 2 · the Mill: a first run of 60 kg at 75 %: above the crop's ceiling, said in plain words (A7/G5)
  await signIn(page, USERS.mill);
  await openSlot(page, 'milling', S);
  await page.getByTestId('incoming-row').filter({ hasText: q }).click();
  for (const box of await page.getByRole('checkbox').all()) await box.check();
  await page.getByTestId('verify-button').click();
  await page.getByRole('button', { name: /Record Milling/ }).click();
  await expect(page.getByLabel(/Paddy in/)).toHaveValue('119');
  await page.getByLabel(/Paddy in/).fill('60');
  await page.getByLabel(/^Head rice/).fill('45'); await page.getByLabel(/^Broken rice/).fill('0'); await page.getByLabel(/^Husk/).fill('14'); await page.getByLabel(/^Bran/).fill('0');
  await expect(page.getByTestId('preview-ok')).toContainText("Outturn 75.0 % is above the crop's ceiling of 70 %");
  const m = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?M-\d{4}/);
  // 3 · "New record" without reloading (A5/G11); the lab lot shows what is left, and the next run starts from it (A3/G2)
  await page.evaluate(() => { (window as unknown as { __kept: number }).__kept = 49; });
  await page.getByTestId('new-record').click();
  expect(await page.evaluate(() => (window as unknown as { __kept?: number }).__kept)).toBe(49);
  await expect(page.getByTestId('incoming-row').filter({ hasText: q }).getByTestId('incoming-left')).toContainText('59 kg left of 119 kg');
  await page.getByTestId('incoming-row').filter({ hasText: q }).click();
  await page.getByRole('button', { name: /Record Milling/ }).click();
  await expect(page.getByLabel(/Paddy in/)).toHaveValue('59');
  await expectNoSideScroll(page);

  // 4 · the record page: where it comes from, its farmers, its GI status
  await page.goto('/');
  await signOut(page);
  await signIn(page, USERS.cm);
  try {
    if (local) await local.setCrop(KALANAMAK, { gi_districts: ['Siddharth Nagar', 'Basti'] });
    await page.goto('/');
    await page.goto(`/work/${S}/milling?tab=records`);
    await page.getByRole('link', { name: m }).click();
    const facts = page.getByTestId('lot-facts');
    await expect(facts.getByTestId('lot-sources')).toContainText(`${q}`);
    await expect(facts.getByTestId('lot-sources')).toContainText('60 kg taken');
    await expect(facts.getByTestId('lot-farmers')).toContainText('Ram Achal');
    await expect(facts.getByTestId('lot-farmers')).toContainText('100 %');
    if (local) await expect(facts.getByTestId('lot-gi')).toContainText('GI (every source from the GI area)');
    await expect(page.locator('.alert.warn')).toContainText("Outturn 75.0 % is above the crop's ceiling");
    await expectNoSideScroll(page);
  } finally {
    if (local) await local.setCrop(KALANAMAK, { gi_districts: [] });
  }
  await signOut(page);
});
