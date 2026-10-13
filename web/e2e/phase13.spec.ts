// The State Manager (migration 41, Veda 13 Oct 2026): signed in as the demo UP State Manager ("Ram" in the brief), on a
// 527 px screen. His overview, his menu, the pages he reads but does not build, his state's ledger, his state's people,
// his state's crops; a farmer verified after the Client Manager. Every refusal is also the database's (tests/35).
import { test, expect } from '@playwright/test';
import { signIn, signOut, apiAs, expectNoSideScroll, USERS } from './helpers';
import { hi } from '../src/lib/i18n.hi';

test.use({ viewport: { width: 527, height: 900 } });
const PRSDM = '00000000-0000-4000-8000-000000000201';
const DEMOX = '00000000-0000-4000-8000-000000000202';
const u = String(Date.now()).slice(-6);

test('The State Manager: his state\'s overview, menu, read-only scopes, ledger, people and crops; no States or Health', async ({ page }) => {
  test.setTimeout(240_000);
  await signIn(page, USERS.sm);
  // B · home: "Uttar Pradesh overview · State Manager · <name>", the guide with its checklist, four figures, client cards
  await expect(page.getByTestId('state-home-title')).toHaveText('Uttar Pradesh overview · State Manager · UP State Manager');
  await expect(page.getByTestId('role-guide')).toHaveAttribute('data-role', 'state_manager');
  await expect(page.getByTestId('setup-item')).toHaveCount(5);
  await expect(page.getByTestId('sh-stats').locator('.stat')).toHaveCount(4);
  // E: every client whose home is Uttar Pradesh (the two demo clients, and any an earlier test made), not "0"
  await expect(page.locator('[data-testid="sh-client"][data-client="DEMOX"]')).toBeVisible();
  const cards = await page.getByTestId('sh-client').count();
  expect(cards).toBeGreaterThanOrEqual(2);
  await expect(page.getByTestId('sh-tile-clients').locator('.stat-val')).toHaveText(String(cards));
  await expect(page.getByTestId('sh-crops')).toContainText('Uttar Pradesh');
  await expect(page.locator('[data-testid="sh-client"][data-client="DEMOX"]')).toContainText('none'); // no Client Manager
  await page.getByTestId('sh-tile-action').click();
  await expect(page.getByTestId('sh-panel-action')).toBeVisible();
  await expectNoSideScroll(page);
  // the warning leads to People & access, filtered to that client
  await expect(page.getByTestId('sh-no-manager')).toContainText(/client(s)? (has|have) no Client Manager yet\./);
  await page.getByTestId('sh-give-manager').filter({ hasText: 'Demo Exporter' }).click();
  await expect(page).toHaveURL(/\/people\?client=/);
  await expect(page.locator('#pf-client')).toHaveValue(DEMOX);
  // A3 · People & access: no admin, no HR; the filters are of his state only
  await page.locator('#pf-client').selectOption('');
  await page.locator('#pf-text').fill('Prasaadam');
  await expect(page.getByText('Prasaadam Client Manager').first()).toBeVisible();
  for (const [q, name] of [['Veda', 'Veda (Admin)'], ['Asha', 'Asha (HR Admin)'], ['Imran', 'Imran (HR)']]) {
    await page.locator('#pf-text').fill(q);
    await expect(page.getByText(name, { exact: true })).toHaveCount(0);
  }
  await page.locator('#pf-text').fill('');
  await expect(page.locator('#pf-state option')).toHaveText(['Any state', 'Uttar Pradesh']);
  // the client drill-in: read-only, with Exit
  await page.goto('/');
  await page.locator('[data-testid="sh-client"][data-client="PRSDM"]').getByTestId('sh-open-client').click();
  await expect(page.getByTestId('readonly-banner')).toBeVisible();
  await page.getByTestId('readonly-exit').click();
  await expect(page.getByTestId('state-home-title')).toBeVisible();

  // F · his menu: no States, no Health, no State overview; Overview, Pipeline, Ledger, Season scopes …
  const menu = page.locator('nav[data-menu="state_manager"]');
  await expect(menu).toHaveCount(1);
  for (const to of ['/pipeline', '/system/ledger', '/clients', '/crops', '/scopes', '/farmers', '/people', '/guide', '/help']) await expect(menu.locator(`a[href="${to}"]`)).toHaveCount(1);
  for (const to of ['/states', '/health', '/state']) await expect(menu.locator(`a[href="${to}"]`)).toHaveCount(0);
  // A1, A4 · States and Health do not open for him
  await page.goto('/states');
  await expect(page.getByTestId('state-home-title')).toBeVisible();
  await page.goto('/health');
  await expect(page.getByTestId('state-home-title')).toBeVisible();
  // A2 · Season scopes: read-only, no "New scope"; a scope opens read-only
  await page.goto('/scopes');
  await expect(page.getByTestId('scopes-sm-reads')).toBeVisible();
  await expect(page.getByRole('link', { name: 'New scope' })).toHaveCount(0);
  await page.goto('/scopes/00000000-0000-4000-8000-000000000401');
  await expect(page.getByTestId('scope-readonly')).toBeVisible();
  // B6 · the pipeline of his state
  await page.goto('/pipeline');
  await expect(page.getByTestId('pipe-counts')).toBeVisible();
  await expectNoSideScroll(page);
  // A5 · the ledger of his state, read-only, with the last check of the chain and no button to run one
  await page.goto('/system/ledger');
  await expect(page.getByRole('heading', { name: 'Ledger of your state' })).toBeVisible();
  await expect(page.getByTestId('ledger-check')).toBeVisible();
  await expect(page.getByTestId('ledger-row').first()).toBeVisible();
  await expect(page.getByTestId('ledger-manager-acts')).toHaveCount(0);
  await expect(page.getByTestId('ledger-export')).toBeEnabled();
  // A6 · Farmers: no "New farmer", no "Import"
  await page.goto('/farmers');
  await expect(page.getByTestId('farmers-sm-note')).toBeVisible();
  await expect(page.getByRole('link', { name: 'New farmer' })).toHaveCount(0);
  await expect(page.getByRole('link', { name: 'Import from Excel' })).toHaveCount(0);
  // C · Crops: Kalanamak has no state; editing it sets his state, once
  await page.goto('/crops');
  const knm = page.getByTestId('crop-row').filter({ hasText: 'KNM' });
  await expect(knm).toBeVisible();                                         // the list is in
  if (await knm.getByText('State not set').count()) {                    // on a fresh stack; a second run finds it set
    await knm.getByRole('button', { name: 'Edit' }).click();
    await expect(page.getByTestId('crop-state-field')).toContainText('Uttar Pradesh');
    await page.getByRole('button', { name: 'Save' }).click();
  }
  await expect(page.getByTestId('crop-row').filter({ hasText: 'KNM' }).getByTestId('crop-state')).toHaveText('Uttar Pradesh');
  // Hindi, on the phone
  await page.goto('/');
  await page.getByLabel('Language').selectOption('hi');
  await expect(page.getByTestId('state-home-title')).toContainText(hi['sh.title'].split('{state}')[1].split('·')[0].trim());
  await expectNoSideScroll(page);
  await page.getByLabel('Language').selectOption('en');
  await signOut(page);
});

test('A farmer: the Client Manager adds and verifies first; the State Manager verifies after him', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, USERS.cm);
  const api = await apiAs(page);
  const made = await api.insert('farmers', { client_id: PRSDM, name: `SM Order ${u}`, guardian_name: 'Father', village: 'Bansi', district: 'Siddharthnagar',
    phone: `+9198${u}11`.slice(0, 13), land_area_acres: 1.5, gi_land_acres: 1 });
  expect(made.ok, JSON.stringify(made.data)).toBe(true);
  const id = (made.data as { id: string }[])[0].id;
  expect((await api.rpc('submit_farmer', { p_farmer: id })).ok).toBe(true);
  await signOut(page);
  await signIn(page, USERS.sm);
  // the API refuses him what the screen does not offer
  const sm = await apiAs(page);
  const refused = await sm.insert('farmers', { client_id: PRSDM, name: 'Not his', guardian_name: 'F', village: 'V', district: 'D', phone: '+919812300777', land_area_acres: 1 });
  expect(refused.ok).toBe(false);
  await page.goto('/farmers');
  await page.getByLabel('Client').selectOption(PRSDM);
  await expect(page.getByRole('tab', { name: 'Ready to verify' })).toHaveAttribute('aria-selected', 'true');   // his first tab
  const row = page.getByTestId('farmer-row').filter({ hasText: `SM Order ${u}` });
  await row.getByTestId('farmer-step2').click();
  await expect(row).toHaveCount(0);                                        // issued: it left "Under review"
  const after = (await sm.rows('farmers', `id=eq.${id}`))[0];
  expect(after).toMatchObject({ status: 'active' });
  expect(after.farmer_code).toBeTruthy();
  await signOut(page);
});
