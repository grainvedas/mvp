// The HR requirements brief (Veda, 14 Oct 2026, "GrainVeda MVP — HR requirements list and staffing a scope"), on a 527 px
// screen. Part F first: a reopened draft reaches step 4 and is activated by clicks only (no typed link); "Save draft →
// People" moves to step 4 or shows the server's words; the step names open the steps; the Roster offers Activate.
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, apiAs, expectNoSideScroll, USERS } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const menu = (page: Page) => page.getByRole('navigation', { name: 'Main' });
const PRSDM = '00000000-0000-4000-8000-000000000201';
const KALANAMAK = '00000000-0000-4000-8000-000000000101';

test('F: a reopened draft reaches step 4 by clicks and is activated; the Roster offers Activate', async ({ page }) => {
  test.setTimeout(180_000);
  const u = String(Date.now()).slice(-6);
  const GEO = `Reopened ${u}`;
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  const made = await cm.insert('scopes', { client_id: PRSDM, crop_id: KALANAMAK, season_code: 'RB28', geography: GEO,
    chain: ['procurement', 'qc', 'qr_activation'], status: 'draft' });
  expect(made.ok, JSON.stringify(made.data)).toBe(true);
  const scope = (made.data as { id: string }[])[0].id;
  for (const [who, st] of [['00000000-0000-4000-8000-000000000305', 'procurement'], ['00000000-0000-4000-8000-000000000306', 'qc'], ['00000000-0000-4000-8000-000000000307', 'qr_activation']] as const)
    expect((await cm.rpc('assign', { p_employee: who, p_lens: 'scope', p_target: scope, p_op_role: 'operator', p_stages: [st], p_posting: '', p_ends_on: null })).ok).toBe(true);

  // the Roster of a draft: every stage has someone, and the way to activate
  await page.goto(`/scopes/${scope}/roster`);
  await expect(page.getByTestId('roster-activation')).toContainText('Every stage has someone.');
  await expect(page.getByTestId('roster-activate')).toBeVisible();

  // clicks only: the menu, the scope, the step names
  await page.goto('/');
  await menu(page).getByRole('link', { name: 'Season Scopes' }).click();
  await page.getByRole('link', { name: GEO }).click();
  await expect(page.locator('.stepper [aria-current="step"]')).toContainText('4');     // a saved draft opens on People
  await expect(page.getByTestId('activate')).toBeEnabled();
  await page.getByTestId('step-3').click();                                              // back to the chain by its name
  await expect(page.getByTestId('chain-preview')).toBeVisible();
  await page.getByRole('button', { name: /Save draft/ }).click();
  await expect(page.locator('.stepper [aria-current="step"]')).toContainText('4');     // before: it stayed on step 3
  await expectNoSideScroll(page);
  page.once('dialog', (d) => d.accept());
  await page.getByTestId('activate').click();
  await expect(page.getByRole('heading', { name: new RegExp(GEO) })).toContainText('Active');
  await signOut(page);
});

// A–E: the Client Manager saves the People step of a five-stage draft; HR sees five Requested lines (the menu's badge,
// her figure), publishes the scope in one act as one opening "Requested by" him; he sees Published on each empty stage;
// he asks for two more by hand, HR returns it with a question, he answers, HR declines it with a reason. The openings
// page says where each opening came from. One person on Procurement and Packing, and on two stages in a row: allowed,
// with the warning in the approved words. The State Manager's home lists the open requirements.
test('A–E: requirements raised by the People step, published by HR in one act; one person on several stages', async ({ page }) => {
  test.setTimeout(240_000);
  const u = String(Date.now()).slice(-6);
  const GEO = `gkp ${u}`;
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  const made = await cm.insert('scopes', { client_id: PRSDM, crop_id: KALANAMAK, season_code: 'KH26', geography: GEO,
    chain: ['procurement', 'qc', 'milling', 'packing', 'qr_activation'], status: 'draft' });
  expect(made.ok, JSON.stringify(made.data)).toBe(true);
  const scope = (made.data as { id: string }[])[0].id;

  // 1 · the People step: nothing asked yet; "Save People step" asks HR for the five empty stages
  await page.goto(`/scopes/${scope}`);
  await expect(page.locator('.stepper [aria-current="step"]')).toContainText('4');
  await expect(page.getByTestId('req-stage')).toHaveCount(5);
  await expect(page.getByTestId('req-stage').first().getByTestId('req-status')).toHaveAttribute('data-status', 'none');
  await page.getByTestId('save-people').click();
  await expect(page.locator('[data-testid="req-stage"][data-status="requested"]')).toHaveCount(5);
  // the missing-stages list links to each stage's status
  await expect(page.getByTestId('lack-link').first()).toHaveAttribute('href', '#req-procurement');
  await expectNoSideScroll(page);

  // 2 · one person on Procurement and Packing, then on QC next to Procurement: allowed, the warning in the brief's words
  const pick = (st: string) => page.getByRole('combobox', { name: `Assign ${st}` });
  await pick('Procurement (farm-gate)').selectOption({ label: 'Procurement Op (field)' });
  await expect(page.getByTestId('slot-holder-procurement')).toContainText('Procurement Op (field)');
  await expect(page.locator('[data-testid="req-stage"][data-stage="procurement"]')).toHaveCount(0);   // staffed: its line closed
  await pick('Packing').selectOption({ label: 'Procurement Op (field)' });
  await expect(page.getByTestId('slot-holder-packing')).toContainText('Procurement Op (field)');
  await expect(page.getByTestId('assign-warnings')).toContainText('Procurement Op (field) holds several stages here: Procurement (farm-gate), Packing.');
  await pick('Quality Control').selectOption({ label: 'Procurement Op (field)' });
  await expect(page.getByTestId('assign-warnings')).toContainText('Procurement Op (field) also holds Procurement (farm-gate). At Quality Control he will verify his own procurement records.');
  // take QC away again: QC is HR's to fill
  page.once('dialog', (d) => d.accept());
  await page.getByRole('button', { name: 'Remove: Procurement Op (field) · Quality Control' }).click();
  await expect(page.locator('[data-testid="req-stage"][data-stage="qc"]')).toHaveAttribute('data-status', 'requested');
  // three empty stages left: QC, Milling, QR (Procurement and Packing filled from the pool)
  await expect(page.getByTestId('req-stage')).toHaveCount(3);
  // he asks for two millers more by hand
  await page.getByTestId('request-people').click();
  await page.getByTestId('rp-stage').selectOption({ label: 'Milling' });
  await page.getByTestId('rp-positions').fill('2');
  await page.getByLabel('Note').fill(`second shift ${u}`);
  await page.getByTestId('rp-send').click();
  await expect(page.getByTestId('req-other')).toContainText('2 × Operator · Milling');
  await expectNoSideScroll(page);
  await signOut(page);

  // 3 · HR (Uttar Pradesh): Requirements first in her menu, with its badge; her figure; the scope's lines
  await signIn(page, USERS.hr);
  const first = menu(page).getByRole('link').filter({ hasText: /Requirements|HR|Openings|People/ }).first();
  await expect(first).toContainText('Requirements');
  await expect(menu(page).getByTestId('nav-badge')).toBeVisible();
  await expect(page.getByTestId('req-figure')).toContainText(/new requirements? · oldest 0 days/);
  await menu(page).getByRole('link', { name: /Requirements/ }).click();
  const card = page.getByTestId('req-card').filter({ hasText: GEO });
  await expect(card.getByTestId('req-line')).toHaveCount(4);                 // QC, Milling, QR raised; the two millers by hand
  await expectNoSideScroll(page);
  // the hand-made line: a question first
  const byHand = card.getByTestId('req-line').filter({ hasText: `second shift ${u}` });
  await byHand.getByTestId('req-return').click();
  await expect(byHand.getByTestId('req-confirm')).toBeDisabled();
  await byHand.getByTestId('req-why').fill('Two millers, or one for two shifts?');
  await byHand.getByTestId('req-confirm').click();
  await expect(byHand).toHaveAttribute('data-status', 'returned');            // it waits on him now
  // publish the scope's three raised lines in one act
  await card.getByTestId('req-publish-all').click();
  await expect(card.getByTestId('req-made')).toContainText(/Opening made: UP-OPR-\d{3}, UP-OPR-\d{3}, UP-OPR-\d{3}/);
  // the openings page: one opening group for the scope, from the requirement, "Requested by" him
  await page.goto('/hr/openings');
  await expect(page.getByTestId('openings-scope').filter({ hasText: GEO })).toContainText('one opening · 3 stages');
  await expect(page.getByTestId('opening-source').filter({ hasText: 'From requirement by Prasaadam Client Manager' }).first()).toBeVisible();
  // a new opening by hand: the scope fills its state and client; two of its stages ticked at once
  await page.getByTestId('new-opening').click();
  await page.getByTestId('of-anyscope').selectOption({ label: `Uttar Pradesh · KH26 · ${GEO} (not active yet)` });
  await expect(page.locator('#of-state')).toHaveValue(/[0-9a-f-]{36}/);
  await page.locator('#of-stage').selectOption('qc');
  await page.getByTestId('of-stage-qr_activation').check();
  await page.getByTestId('of-positions').fill('1');
  await page.getByTestId('save-opening').click();
  await expect(page.getByTestId('opening-form')).toHaveCount(0);
  await expect(page.getByTestId('openings-scope').filter({ hasText: GEO }).filter({ hasText: 'one opening · 2 stages' })).toBeVisible();
  expect(await page.getByTestId('opening-source').filter({ hasText: 'Created by HR' }).count()).toBeGreaterThanOrEqual(2);
  await expectNoSideScroll(page);
  await signOut(page);

  // 4 · the Client Manager: Published on each empty stage; he answers HR's question
  await signIn(page, USERS.cm);
  await page.goto(`/scopes/${scope}/roster`);
  await expect(page.locator('[data-testid="req-stage"][data-status="published"]')).toHaveCount(3);
  await expect(page.locator('[data-testid="req-stage"][data-stage="qc"]')).toContainText(/UP-OPR-\d{3}/);
  const asked = page.getByTestId('req-other').filter({ hasText: 'Two millers, or one for two shifts?' });
  await expect(asked.getByTestId('req-status')).toHaveAttribute('data-status', 'returned');
  await asked.getByTestId('req-answer').click();
  await asked.getByTestId('req-answer-text').fill('Two: one per shift');
  await asked.getByTestId('req-answer-send').click();
  await expect(page.getByTestId('req-other').filter({ hasText: `second shift ${u}` }).getByTestId('req-status')).toHaveAttribute('data-status', 'requested');
  await expectNoSideScroll(page);
  await signOut(page);

  // 5 · HR declines it, with the reason; the State Manager reads the scope's open lines on his home
  await signIn(page, USERS.hr);
  await page.goto('/hr/requirements');
  const again = page.getByTestId('req-card').filter({ hasText: GEO }).getByTestId('req-line').filter({ hasText: `second shift ${u}` });
  await again.getByTestId('req-decline').click();
  await again.getByTestId('req-why').fill('One miller is enough for this lot size');
  await again.getByTestId('req-confirm').click();
  await expect(page.getByTestId('req-card').filter({ hasText: GEO })).toHaveCount(0);   // nothing open left for her here
  await signOut(page);
  await signIn(page, USERS.sm);
  await expect(page.getByTestId('sh-requirements')).toBeVisible();
  await expect(page.getByTestId('sh-req').filter({ hasText: GEO }).getByTestId('sh-req-line')).toHaveCount(3);
  await expectNoSideScroll(page);
  await signOut(page);
});
