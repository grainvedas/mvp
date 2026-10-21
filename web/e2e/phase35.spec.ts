// Migration 63 (Phase 1, release 5 of Veda's combined brief of 19 Oct 2026: Part D, close a scope and the season report),
// on a 527 px screen, scope Gorakhpur mandi (Lot Inward → QC → QR; no spec after this one uses it). A lot is received and
// left unverified: the Client Manager's "Close scope…" shows the closing check blocked by it; once QC has verified it,
// the check lists its kilograms left, the Client Manager writes them off with a reason and requests the close. The State
// Manager confirms: the scope is closed, the final report is issued and its files are made in the browser (PDF and Excel,
// English and Hindi, both copies) and stored. A downloaded PDF is the file whose SHA-256 the verify page shows ("Valid").
// The client's own login downloads (the internal copy too) and is offered no close. The State Manager reopens with a
// reason; the Client Manager makes an interim report. Every rule is the database's (tests/58_close_scope_report.sql).
import { test, expect, type Page } from '@playwright/test';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { signIn, signOut, expectNoSideScroll, apiAs, reviewAndSave, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const S = SCOPES.gorakhpurMandi;
const card = (page: Page) => page.getByTestId('season-report');

test('close a scope: the check, the request, the confirmation, the final report and its files, verify, reopen, interim', async ({ page }) => {
  test.setTimeout(420_000);

  // a lot received and not yet checked
  await signIn(page, USERS.lotInward);
  await page.getByTestId('slot-lot_inward').click();
  await page.getByLabel(/Declared quantity/).fill('100');
  await page.getByLabel(/Actual weighed/).fill('100');
  await page.getByLabel(/Source type/).selectOption('fpo');
  await page.getByLabel(/Source name/).fill('Deoria FPO (practice)');
  await page.getByLabel(/Crop declared/).fill('Kalanamak');
  await page.getByLabel(/Moisture baseline/).fill('12');
  const li = (await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?LI-\d{4}/)).match(/PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?LI-\d{4}/)![0];
  await signOut(page);

  // the Client Manager: the closing check is blocked by the record still to verify
  await signIn(page, USERS.cm);
  await page.goto(`/dashboard/${S}`);
  await card(page).getByTestId('close-open').click();
  await expect(card(page).getByTestId('close-blocked')).toBeVisible();
  await expect(card(page).locator('[data-key="pending"]')).toHaveAttribute('data-ok', 'no');
  await expect(card(page).locator('[data-key="pending"]')).toContainText(li);
  await expect(card(page).getByTestId('close-request')).toBeDisabled();
  await expectNoSideScroll(page);
  await signOut(page);

  // QC verifies it (its form is tested elsewhere); its 100 kg are now left on the lot
  await signIn(page, USERS.qc);
  const qcApi = await apiAs(page);
  const lot = (await qcApi.rows('footprints', `footprint_code=eq.${li}`))[0] as { id: string };
  const v = await qcApi.rpc('verify_footprint', { p_fp: lot.id });
  expect(v.ok, JSON.stringify(v.data)).toBe(true);
  await signOut(page);

  // the Client Manager writes the 100 kg off with a reason and requests the close
  await signIn(page, USERS.cm);
  await page.goto(`/dashboard/${S}`);
  await card(page).getByTestId('close-open').click();
  const kgGroup = card(page).locator('[data-key="kg"]');
  await expect(kgGroup).toHaveAttribute('data-ok', 'no');
  await expect(kgGroup).toContainText(li);
  await expect(kgGroup).toContainText('100 kg');
  await kgGroup.getByTestId('close-reason').fill('short');
  await card(page).getByTestId('close-recheck').click();
  await expect(kgGroup).toHaveAttribute('data-ok', 'no');                                  // fewer than 10 characters answers nothing
  await kgGroup.getByTestId('close-reason').fill('the FPO took the lot back unsold (practice)');
  // any other blocker of the practice data (an open flag, a held pack) is answered the same way
  for (const box of await card(page).getByTestId('close-reason').all()) if (!(await box.inputValue())) await box.fill('practice data: carried over at the close');
  await card(page).getByTestId('close-recheck').click();
  await expect(card(page).getByTestId('close-clear')).toBeVisible();
  await expectNoSideScroll(page);
  await card(page).getByTestId('close-request').click();
  await expect(card(page).getByTestId('close-requested')).toBeVisible();
  await expect(card(page).getByTestId('close-confirm')).toHaveCount(0);                  // the Client Manager does not confirm
  await signOut(page);

  // the State Manager confirms: closed; the final report and its eight files
  await signIn(page, USERS.sm);
  await page.goto(`/dashboard/${S}`);
  await card(page).getByTestId('close-confirm').click();
  await expect(card(page).getByTestId('scope-closed')).toBeVisible({ timeout: 30_000 });
  const row = card(page).getByTestId('report-row').first();
  await expect(row).toHaveAttribute('data-status', 'valid');
  const ref = (await row.getAttribute('data-ref'))!;
  expect(ref).toMatch(/^GV-SR-\d{6}$/);
  // the files are made in this browser: wait for all eight, then for the progress line to go
  await expect(row.getByTestId('report-files').getByRole('button')).toHaveCount(8, { timeout: 180_000 });
  await expect(card(page).getByTestId('report-progress')).toHaveCount(0, { timeout: 60_000 });
  await expect(row.getByTestId('report-make')).toHaveCount(0);
  await expect(card(page).getByTestId('reopen-open')).toBeVisible();
  await expectNoSideScroll(page);
  const dl = page.waitForEvent('download');
  await row.getByTestId('file-pdf_hi_shareable').click();
  const file = await dl;
  expect(file.suggestedFilename()).toBe(`grainveda-season-report-${ref}-shareable-hi.pdf`);
  const bytes = readFileSync((await file.path())!);
  expect(bytes.subarray(0, 5).toString()).toBe('%PDF-');
  const sha = createHash('sha256').update(bytes).digest('hex');
  await signOut(page);

  // Verify this document, nobody signed in: Valid, the downloaded file's SHA-256 among its files
  await page.goto(`/d/${ref}`);
  await expect(page.getByTestId('dv-status')).toHaveAttribute('data-status', 'valid');
  await expect(page.getByTestId('dv-file')).toHaveCount(8);
  await expect(page.getByTestId('dv-files')).toContainText(sha);
  await expectNoSideScroll(page);

  // the client's own login: downloads, both copies; offered no close and no reopen
  await signIn(page, USERS.view);
  await page.goto(`/dashboard/${S}`);
  await expect(card(page).getByTestId('report-row').first()).toHaveAttribute('data-ref', ref);
  await expect(card(page).getByTestId('close-open')).toHaveCount(0);
  await expect(card(page).getByTestId('reopen-open')).toHaveCount(0);
  await expect(card(page).getByTestId('interim-go')).toHaveCount(0);
  const dl2 = page.waitForEvent('download');
  await card(page).getByTestId('report-row').first().getByTestId('file-xlsx_en_internal').click();
  expect((await dl2).suggestedFilename()).toBe(`grainveda-season-report-${ref}-internal-en.xlsx`);
  await signOut(page);

  // the State Manager reopens with a reason; the Client Manager makes an interim report
  await signIn(page, USERS.sm);
  await page.goto(`/dashboard/${S}`);
  await card(page).getByTestId('reopen-open').click();
  await card(page).getByTestId('reopen-why').fill('practice: reopened to show an interim report');
  await card(page).getByTestId('reopen-go').click();
  await expect(card(page)).toHaveAttribute('data-status', 'active');
  await signOut(page);
  await signIn(page, USERS.cm);
  await page.goto(`/dashboard/${S}`);
  await card(page).getByTestId('interim-go').click();
  const interim = card(page).getByTestId('report-row').first();
  await expect(interim).toContainText('Interim report 1', { timeout: 30_000 });
  await expect(interim.getByTestId('report-files').getByRole('button')).toHaveCount(8, { timeout: 180_000 });
  await expect(card(page).getByTestId('report-progress')).toHaveCount(0, { timeout: 60_000 });
  await expect(card(page).getByTestId('report-row').filter({ hasText: ref })).toHaveAttribute('data-status', 'valid');   // until the next close
  await expectNoSideScroll(page);
});
