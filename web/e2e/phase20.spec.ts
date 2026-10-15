// Migration 48 (Veda, 15 Oct 2026: the operator-stages brief, release 1, with the Client Manager's home, menu and
// ledger), on a 527 px screen. Procurement records a lot "on" yesterday; QC returns it with a reason; the sender sees it
// first on his home, corrects it, and QC verifies it with a condition. The Client Manager: his own menu, "Needs my
// action", his client's ledger with the return and its reason, a record he makes at a stage he does not hold (with his
// reason), and the farmer's history with every line named. Every rule is the database's (tests/42_operator_template.sql).
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, openSlot, reviewAndSave, procure, USERS, SCOPES, todayIST, pickFarmer } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const S = SCOPES.siddharthnagar;
const yesterday = () => { const d = new Date(`${todayIST()}T00:00:00Z`); d.setUTCDate(d.getUTCDate() - 1); return d.toISOString().slice(0, 10); };
const lotRow = (page: Page, code: string) => page.getByTestId('incoming-row').filter({ hasText: code });

test('return to sender, the date it happened, verify with a condition, and the Client Manager\'s day', async ({ page }) => {
  test.setTimeout(240_000);
  const u = String(Date.now()).slice(-5);

  // 1 · Procurement records a lot "on" yesterday; its number names the scope (E4)
  await signIn(page, USERS.procurement);
  await openSlot(page, 'procurement', S);
  await pickFarmer(page, /Geeta Kumari/);
  await page.getByTestId('happened-on').fill(yesterday());
  await page.getByLabel(/Gross weight/).fill('130');
  await page.getByLabel(/^Bags/).fill('2');
  await page.getByLabel(/Tare per bag/).fill('1');
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('11.9');
  await expect(page.getByTestId('preview-ok')).toBeVisible();
  await page.getByRole('button', { name: 'Review' }).click();
  await expect(page.getByTestId('review-on')).not.toHaveText('');
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save record' }).click();
  const code = (await page.getByTestId('saved').textContent())!.match(/PRSDM-KNM-KH26-SDR-P-\d{4}/)![0];
  await expectNoSideScroll(page);
  await signOut(page);

  // 2 · QC returns it with a reason (A1); it shows as returned and cannot be verified
  await signIn(page, USERS.qc);
  await openSlot(page, 'qc', S);
  await lotRow(page, code).click();
  await page.getByTestId('return-open').click();
  await expect(page.getByTestId('return-send')).toBeDisabled();                       // fewer than 10 characters
  await page.getByTestId('return-why').fill(`moisture readings look copied ${u}`);
  await page.getByTestId('return-send').click();
  await expect(page.getByTestId('returned-note')).toContainText(`moisture readings look copied ${u}`);
  await expect(page.getByTestId('verify-button')).toHaveCount(0);
  await expectNoSideScroll(page);
  await signOut(page);

  // 3 · the sender sees it first on his home, with the reason, and corrects it
  await signIn(page, USERS.procurement);
  const line = page.getByTestId('needs-action-line').filter({ hasText: code });
  await expect(line).toContainText(`moisture readings look copied ${u}`);
  await line.getByRole('link', { name: 'Correct it' }).click();
  await expect(page.getByTestId('returns-panel')).toContainText(`moisture readings look copied ${u}`);
  await page.getByTestId('return-correct').click();
  await page.getByLabel('Moisture (3 readings) 2').fill('12.1');
  await expect(page.getByTestId('preview-ok')).toBeVisible();
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save record' }).click();
  await expect(page.getByTestId('saved')).toBeVisible();
  await page.goto('/');
  await expect(page.getByTestId('needs-action-line').filter({ hasText: code })).toHaveCount(0);
  await signOut(page);

  // 4 · QC verifies it, with a condition
  await signIn(page, USERS.qc);
  await openSlot(page, 'qc', S);
  await lotRow(page, code).click();
  await expect(page.getByTestId('returned-note')).toHaveCount(0);
  for (const box of await page.getByRole('checkbox').all()) await box.check();
  await page.getByTestId('with-condition').click();
  await page.getByTestId('condition-text').fill(`slip photo to be added ${u}`);
  await page.getByTestId('verify-button').click();
  await expect(page.locator('.alert.ok', { hasText: 'Verified' })).toBeVisible();
  await signOut(page);

  // 5 · the Client Manager: his menu, "Needs my action", his client's ledger with the return and its reason
  await signIn(page, USERS.cm);
  await expect(page.locator('nav[aria-label="Main"]')).toHaveAttribute('data-menu', 'client_manager');
  await expect(page.getByTestId('needs-action')).toBeVisible();
  await expect(page.getByTestId('needs-action-line').filter({ hasText: /open condition/ })).toBeVisible();
  await page.goto('/system/ledger');
  await expect(page.getByRole('heading', { name: /Ledger of my client/ })).toBeVisible();
  await page.getByTestId('ledger-event').selectOption('return');
  await expect(page.getByTestId('ledger-note').filter({ hasText: `moisture readings look copied ${u}` }).first()).toBeVisible();
  await expectNoSideScroll(page);

  // 6 · he records at a stage he does not hold: only with his reason (A10)
  await page.goto(`/work/${S}/procurement`);
  await pickFarmer(page, /Geeta Kumari/);
  await page.getByLabel(/Gross weight/).fill('60');
  await page.getByLabel(/^Bags/).fill('1');
  await page.getByLabel(/Tare per bag/).fill('1');
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('11.9');
  await expect(page.getByTestId('preview-ok')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Review' })).toBeDisabled();
  await page.getByTestId('manager-why').fill(`operator away at the mandi ${u}`);
  const mine = await reviewAndSave(page, /PRSDM-KNM-KH26-SDR-P-\d{4}/);
  await page.getByRole('link', { name: new RegExp(mine) }).click();
  await expect(page.getByTestId('record-manager-reason')).toContainText(`operator away at the mandi ${u}`);

  // 7 · the farmer's history: every line named (fix 1)
  await page.goto('/farmers/00000000-0000-4000-8000-000000000504');                    // Geeta Kumari (seed 02)
  await expect(page.getByTestId('fh-event').filter({ hasText: `Lot ${code} recorded at` })).toBeVisible();
  for (const e of await page.getByTestId('fh-event').all()) expect((await e.textContent())!.trim().startsWith('·')).toBe(false);
  await expectNoSideScroll(page);
  await signOut(page);
});
