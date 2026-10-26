// Migration 68 (Phase 3, release 2 of Veda's combined brief: Parts C and E4, with item 65), on a 527 px screen. The
// client's own login opens its Portfolio from the menu: the totals, by state and crop, each scope; one scope (the
// pipeline, lots, QC, documents, the people by name and role); across scopes; the farmers. Each view downloads as Excel
// or CSV, the shareable copy by default (no price, no farmer's name or phone). The admin opens the same client's
// portfolio from its page and takes the internal copy; each download is in the Audit log. Every rule and figure is the
// database's (tests/63_client_views.sql).
import { readFileSync } from 'node:fs';
import { test, expect } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, apiAs, USERS } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const CLIENT = '00000000-0000-4000-8000-000000000201';
const PHONE = /(\+91[\s-]?)?\b[6-9]\d{9}\b/;

test('client views: the portfolio, one scope, across scopes and the farmers; each view downloads', async ({ page }) => {
  test.setTimeout(240_000);

  // 1 · the client's own login: Portfolio in its menu
  await signIn(page, USERS.view);
  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: /Portfolio/ }).click();
  await expect(page).toHaveURL(/\/portfolio$/);
  await expect(page.getByTestId('cv-totals')).toBeVisible();
  expect(await page.getByTestId('cv-scope').count()).toBeGreaterThan(0);
  await expect(page.getByTestId('cv-group').first()).toBeVisible();
  await expectNoSideScroll(page);
  const internalOffered = await page.getByTestId('cv-copy').count() > 0;      // a viewer: no; the same login made owner (phase37): yes
  const v = await apiAs(page);
  const me = (await v.rpc('my_context')).data as { user: { client_account: { kind: string; internal_copies: boolean } | null } };
  const ca = me.user.client_account!;
  expect(internalOffered).toBe(ca.kind === 'owner' || ca.internal_copies);

  const dl = page.waitForEvent('download');
  await page.getByTestId('cv-xlsx-portfolio').click();
  expect((await dl).suggestedFilename()).toBe('grainveda-portfolio-PRSDM-shareable.xlsx');

  // 2 · one scope
  await page.getByTestId('cv-scope').first().getByRole('link').first().click();
  await expect(page.getByTestId('cv-scope-view')).toBeVisible();
  for (const id of ['cv-pipeline', 'cv-lots', 'cv-qc', 'cv-documents', 'cv-reports', 'cv-people']) await expect(page.getByTestId(id)).toBeVisible();
  await expectNoSideScroll(page);
  const dl2 = page.waitForEvent('download');
  await page.getByTestId('cv-csv-scope').click();
  const f2 = await dl2;
  expect(f2.suggestedFilename()).toMatch(/^grainveda-scope-.+-shareable\.csv$/);
  const csv = readFileSync((await f2.path())!, 'utf8');
  expect(csv).toContain('Pipeline by stage');
  expect(csv).toContain('People on each stage');
  expect(csv).toContain('No prices, no farmers');                                                  // the shareable copy's footer
  expect(csv).not.toMatch(PHONE);

  // 3 · across scopes; the farmers (the shareable copy: no names, never a phone)
  await page.goto('/portfolio?tab=across');
  for (const id of ['cv-orders', 'cv-buyers', 'cv-scans', 'cv-flags', 'cv-recalls', 'cv-outputs']) await expect(page.getByTestId(id)).toBeVisible();
  await expectNoSideScroll(page);
  await page.getByTestId('cv-tab-farmers').click();
  await expect(page.getByTestId('cv-farmers')).toBeVisible();
  if (internalOffered) await page.getByTestId('cv-copy').selectOption('shareable');
  const dl3 = page.waitForEvent('download');
  await page.getByTestId('cv-csv-farmers').click();
  const farmers = readFileSync((await (await dl3).path())!, 'utf8');
  expect(farmers).toContain('Farmer ID');
  expect(farmers).not.toMatch(/(^|,)Name(,|$)/m);
  expect(farmers).not.toMatch(PHONE);
  await expectNoSideScroll(page);

  // the server refuses this login another client's portfolio and any internal copy it is not allowed
  expect((await v.rpc('client_portfolio', { p_client: '00000000-0000-4000-8000-000000000202' })).status).toBe(403);
  if (!internalOffered) {
    expect((await v.rpc('export_client_view', { p_view: 'across', p_client: CLIENT, p_scope: null, p_copy: 'internal' })).status).toBe(403);
  }
  await signOut(page);

  // 4 · the admin, from the client's page: the internal copy, with its footer; each download in the Audit log
  await signIn(page, USERS.admin);
  await page.goto(`/clients/${CLIENT}`);
  await page.getByTestId('open-portfolio').click();
  await expect(page).toHaveURL(new RegExp(`/portfolio/${CLIENT}$`));
  await page.getByTestId('cv-tab-across').click();
  await page.getByTestId('cv-copy').selectOption('internal');
  const dl4 = page.waitForEvent('download');
  await page.getByTestId('cv-csv-across').click();
  const f4 = await dl4;
  expect(f4.suggestedFilename()).toBe('grainveda-across-PRSDM-internal.csv');
  expect(readFileSync((await f4.path())!, 'utf8')).toContain('Internal: contains personal and commercial data');
  await expectNoSideScroll(page);
  const a = await apiAs(page);
  const log = (await a.rpc('audit_page', { p: { action: 'export_downloaded', limit: 20 } }));
  expect(log.ok).toBe(true);
  expect(JSON.stringify(log.data)).toContain('client_view');
  await page.goto('/system/audit');
  await expect(page.getByTestId('audit-line').filter({ hasText: "the client's view" }).first()).toBeVisible();
  await signOut(page);
});
