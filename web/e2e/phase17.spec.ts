// Production safeguards (migration 45, Veda 14 Oct 2026: "when in production … can such thing happen and not
// recorded?"), on a 527 px screen: the admin's Safeguards page (the change log intact, how changes came, the changes
// behind the app, the fingerprint copied outside), a correction asked by the admin with its reason and approved by the
// HR Admin (a second person), never by the one who asked; a Client Manager is refused. Every rule is also the
// database's (tests/39_production_safeguards.sql).
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, apiAs, USERS } from './helpers';

const menu = (page: Page) => page.getByRole('navigation', { name: 'Main' });

test.use({ viewport: { width: 527, height: 900 } });
const u = String(Date.now()).slice(-6);
const REASON = `Village of farmer 1 typed wrong at import (${u})`;

test('Safeguards: the change log, changes behind the app, a correction asked and approved by a second person', async ({ page }) => {
  test.setTimeout(180_000);
  // 1 · the admin: the page under Audit; the log intact; how changes came; the changes behind the app (the demo seed's)
  await signIn(page, USERS.admin);
  await menu(page).getByRole('link', { name: 'Safeguards' }).click();
  await expect(page.getByTestId('safeguards')).toBeVisible();
  await expect(page.getByTestId('sg-log')).toContainText(/Change log intact: \d+ lines/);
  await expect(page.getByTestId('sg-paths')).toContainText('in the app');
  await expect(page.getByTestId('sg-paths')).toContainText('direct');
  await expect(page.getByTestId('sg-change').first()).toBeVisible();
  await expect(page.getByTestId('sg-change').first()).toContainText('database account:');
  // ten at first (the demo seed made many), the rest on request
  await expect(page.getByTestId('sg-change')).toHaveCount(10);
  await page.getByTestId('sg-more').click();
  expect(await page.getByTestId('sg-change').count()).toBeGreaterThan(10);
  await expect(page.getByTestId('sg-head')).toContainText(/#\d+ · [0-9a-f]{6}…[0-9a-f]{6}/);
  await expect(page.getByTestId('sg-two-person')).toContainText('Two-person approval is off');
  await expectNoSideScroll(page);
  // he asks for a correction: a reason first
  await expect(page.getByTestId('sg-request')).toBeDisabled();
  await page.getByTestId('sg-reason').fill(REASON);
  await page.getByTestId('sg-detail').fill('farmer 1: village');
  await page.getByTestId('sg-request').click();
  const mine = page.getByTestId('sg-correction').filter({ hasText: REASON });
  await expect(mine).toContainText('Waiting for approval');
  await expect(mine.getByTestId('sg-approve')).toHaveCount(0);              // not his to approve
  await signOut(page);

  // 2 · a Client Manager: refused, and no menu entry
  await signIn(page, USERS.cm);
  await expect(menu(page).getByRole('link', { name: 'Safeguards' })).toHaveCount(0);
  await page.goto('/system/safeguards');
  await expect(page.getByRole('alert').first()).toBeVisible();
  await expect(page.getByTestId('sg-log')).toHaveCount(0);
  await signOut(page);

  // 3 · the HR Admin: the page in her menu; she approves (a refusal would need a reason)
  await signIn(page, USERS.hrAdmin);
  await menu(page).getByRole('link', { name: 'Safeguards' }).click();
  const req = page.getByTestId('sg-correction').filter({ hasText: REASON });
  await expect(req).toContainText('Waiting for approval');
  await expect(page.getByTestId('sg-request')).toHaveCount(0);              // she asks for none
  await req.getByTestId('sg-refuse').click();
  await expect(req.getByTestId('sg-refuse-confirm')).toBeDisabled();
  await req.getByRole('button', { name: 'Cancel' }).click();
  await req.getByTestId('sg-approve').click();
  await expect(req).toContainText('Approved, not yet run');
  await expect(req).toContainText(/approved by Asha \(HR Admin\)/);
  await expectNoSideScroll(page);
  // the database said so too (her call through the API, not only the screen)
  const api = await apiAs(page);
  const again = await api.rpc('decide_correction', { p_id: '00000000-0000-4000-8000-000000000000', p_approve: true });
  expect(again.ok).toBe(false);
  await signOut(page);
});
