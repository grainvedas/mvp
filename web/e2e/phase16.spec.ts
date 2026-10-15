// Release 4 (migration 44, Veda 14 Oct 2026, the follow-up brief), on a 527 px screen. Her section A as the screens show
// it: the Client Manager's roster pool (people based in Uttar Pradesh and himself; never the admin, HR or the State
// Manager), activation only with every stage staffed; the State Manager's scope without roster controls and his Assign
// page without "A scope"; the Client Manager's People & access; "My guide"; the two farmer IDs, the same person linked
// at step 2, the farmer's history, a change with a reason accepted on the register; the ledger's working role; one
// position on a State Manager opening. Every rule is also the database's (tests/38_rules_and_farmer_ids.sql).
import { test, expect } from '@playwright/test';
import { signIn, signOut, apiAs, expectNoSideScroll, localStack, USERS, fillFarmerPlace, pickFromPool } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const PRSDM = '00000000-0000-4000-8000-000000000201';
const DEMOX = '00000000-0000-4000-8000-000000000202';
const u = String(Date.now()).slice(-6);
const NAME = `Ids ${u}`;
const PHONE = `92${u}17`;

test('Release 4: rosters, activation, people, the guide, two farmer IDs, history and changes', async ({ page }) => {
  test.setTimeout(300_000);
  const stack = localStack();

  // 1 · Lucky (the Client Manager): a draft scope; the pool; activation waits for people
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  const made = await cm.insert('scopes', { client_id: PRSDM, crop_id: '00000000-0000-4000-8000-000000000101', season_code: 'RB28', geography: `Roster ${u}`,
    chain: ['procurement', 'qc', 'qr_activation'], status: 'draft' });
  expect(made.ok, JSON.stringify(made.data)).toBe(true);
  const scope = (made.data as { id: string }[])[0].id;
  await page.goto(`/scopes/${scope}?step=people`);
  await expect(page.getByTestId('activate')).toBeDisabled();
  await expect(page.getByTestId('activation-missing')).toContainText('nobody yet at Procurement');
  const pool = page.getByLabel('Assign Quality Control').locator('option');
  await expect(pool.filter({ hasText: 'Prasaadam Client Manager (you)' })).toHaveCount(1);              // himself, for a small client
  for (const nobody of ['Veda (Admin)', 'Asha (HR Admin)', 'Imran (HR)', 'UP State Manager']) await expect(pool.filter({ hasText: nobody })).toHaveCount(0);
  await expect(pool.filter({ hasText: 'QC Technician' })).toHaveCount(1);
  const refused = await cm.rpc('assign', { p_employee: '00000000-0000-4000-8000-000000000302', p_lens: 'scope', p_target: scope, p_op_role: 'operator', p_stages: ['qc'] });
  expect(String((refused.data as { message: string }).message)).toContain('a State Manager holds no stage');
  const early = await cm.update('scopes', `id=eq.${scope}`, { status: 'active' });
  expect(String((early.data as { message: string }).message)).toContain('every stage needs a person');
  await pickFromPool(page, 'Assign Quality Control', 'Prasaadam Client Manager (you)');
  await expect(page.getByRole('row', { name: /Quality Control/ })).toContainText('Prasaadam Client Manager');
  await expectNoSideScroll(page);
  // People & access: his client's people and his state's pool; no admin, no HR, no State Manager; one state to filter by
  await page.goto('/people');
  await expect(page.getByTestId('person-row').first()).toBeVisible();
  for (const nobody of ['Veda (Admin)', 'Asha (HR Admin)', 'Imran (HR)', 'UP State Manager']) await expect(page.getByTestId('person-row').filter({ hasText: nobody })).toHaveCount(0);
  await expect(page.locator('#pf-state option')).toHaveText(['Any state', 'Uttar Pradesh']);
  // My guide: his own
  await page.goto('/guide');
  await expect(page.getByTestId('guide-page')).toBeVisible();
  await expect(page.getByTestId('role-guide')).toHaveAttribute('data-role', 'client_manager');
  // a farmer: Save and verify gives the client farmer ID
  await page.goto('/farmers/new');
  await page.getByLabel('Name *', { exact: true }).fill(NAME);
  await page.getByLabel('Father / husband name *').fill('Shri Raghu');
  await fillFarmerPlace(page, 'Siddharthnagar', 'Itwa');
  await page.getByLabel('Mobile number *').fill(PHONE);
  await page.getByLabel('Land (acres) *').fill('2');
  await page.getByTestId('farmer-gi-land').fill('1');
  await page.getByTestId('farmer-save-verify').click();
  await expect(page.getByRole('heading', { name: 'Farmers' })).toBeVisible();
  await page.getByRole('tab', { name: 'Ready to verify' }).click();
  await expect(page.getByTestId('farmer-row').filter({ hasText: NAME })).toContainText(/PRSDM-F-\d{4}/);
  await signOut(page);
  // the same person on another client's list (seeded on the local stack only: the demo has no Client Manager for it)
  if (stack) await stack.seedFarmer({ client_id: DEMOX, status: 'under_review', name: NAME, guardian_name: 'Shri Raghu', village: 'Itwa', district: 'Siddharthnagar',
    phone: `+91${PHONE}`, land_area_acres: 2, gi_land_acres: 1, reviewed_by: '00000000-0000-4000-8000-000000000303' });

  // 2 · Ram (the State Manager): no roster controls; no "A scope"; step 2 gives the state farmer ID
  await signIn(page, USERS.sm);
  await page.goto(`/scopes/${scope}`);
  await expect(page.getByTestId('scope-readonly')).toBeVisible();
  await expect(page.getByRole('row', { name: /Quality Control/ })).toContainText('Prasaadam Client Manager');
  await expect(page.getByTestId('slots').locator('select')).toHaveCount(0);
  await expect(page.getByTestId('slots').getByRole('button', { name: /Remove/ })).toHaveCount(0);
  await page.goto('/people/00000000-0000-4000-8000-000000000318/assign');
  await expect(page.getByRole('heading', { name: /Ravi Kumar/ })).toBeVisible();
  await expect(page.getByRole('tab', { name: 'A scope' })).toHaveCount(0);
  await expect(page.locator('#a-scope')).toHaveCount(0);                         // he keeps "A client's account" only
  await page.goto('/farmers');
  await page.getByLabel('Client').selectOption(PRSDM);
  await expect(page.getByTestId('farmer-row').filter({ hasText: NAME })).toContainText(/PRSDM-F-\d{4}/);   // this client's list, not the one before
  await page.getByTestId('farmer-row').filter({ hasText: NAME }).getByTestId('farmer-step2').click();
  await page.getByRole('tab', { name: 'Active', exact: true }).click();
  const row = page.getByTestId('farmer-row').filter({ hasText: NAME });
  await expect(row.getByTestId('farmer-state-id')).toHaveText(/^F-UP-\d{5}$/);
  const stateId = (await row.getByTestId('farmer-state-id').textContent())!;
  if (stack) {
    await page.getByLabel('Client').selectOption(DEMOX);
    await page.getByRole('tab', { name: 'Ready to verify' }).click();
    const second = page.getByTestId('farmer-row').filter({ hasText: NAME });
    await expect(second.getByTestId('farmer-same-phone')).toContainText(`Same phone as ${stateId}`);
    await expect(second.getByTestId('farmer-step2')).toHaveCount(0);                 // the choice, not a plain verification
    await second.getByTestId('farmer-link').click();
    await page.getByRole('tab', { name: 'Active', exact: true }).click();
    await expect(page.getByTestId('farmer-row').filter({ hasText: NAME }).getByTestId('farmer-state-id')).toHaveText(stateId);
  }
  // the farmer's page: both IDs, the history
  await page.getByLabel('Client').selectOption(PRSDM);
  await page.getByRole('tab', { name: 'Active', exact: true }).click();
  await page.getByTestId('farmer-row').filter({ hasText: NAME }).getByRole('link', { name: 'Edit' }).click();
  await expect(page.getByTestId('farmer-client-id')).toHaveText(/PRSDM-F-\d{4}/);
  await expect(page.getByTestId('farmer-state-id')).toHaveText(stateId);
  await expect(page.getByTestId('fh-event')).toHaveCount(2);
  await expect(page.getByTestId('fh-event').nth(0)).toContainText('Verified by the Client Manager');
  await expect(page.getByTestId('fh-event').nth(0)).toContainText('(Client Manager)');
  await expect(page.getByTestId('fh-event').nth(1)).toContainText('Verified by the State Manager');
  await expectNoSideScroll(page);
  const farmerUrl = page.url();
  // the ledger names the role each signer held
  await page.goto('/system/ledger');
  await expect(page.getByRole('cell', { name: 'Client Manager', exact: true }).first()).toBeVisible();
  await expect(page.getByRole('cell', { name: 'State Manager', exact: true }).first()).toBeVisible();
  await signOut(page);

  // 3 · Lucky changes the GI land after verification: a reason; Ram accepts it from the register
  await signIn(page, USERS.cm);
  await page.goto(farmerUrl);
  await expect(page.getByTestId('farmer-client-id')).toHaveText(/PRSDM-F-\d{4}/);
  await page.getByTestId('farmer-gi-land').fill('1.5');
  await expect(page.getByRole('button', { name: 'Save', exact: true })).toBeDisabled();
  await page.getByTestId('farmer-why').fill('measured again at the visit');
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Farmers' })).toBeVisible();
  await signOut(page);
  await signIn(page, USERS.sm);
  await page.goto('/farmers/register?flag=changed');
  await page.getByTestId('reg-search').fill(u);
  const card = page.getByTestId('reg-row').filter({ has: page.locator('strong', { hasText: new RegExp(`^${NAME}$`) }) }).first();
  await expect(card.getByTestId('reg-changed')).toContainText('1 change of GI land or mobile');
  await expectNoSideScroll(page);
  await card.getByTestId('reg-open').click();
  await expect(page.getByTestId('fh-open-changes')).toContainText('GI land: 1.00 → 1.50');
  await expect(page.getByTestId('fh-open-changes')).toContainText('measured again at the visit');
  await page.getByTestId('fh-accept').click();
  await expect(page.getByTestId('fh-open-changes')).toHaveCount(0);
  await expect(page.getByTestId('fh-event').last()).toContainText('Why: measured again at the visit');
  await signOut(page);

  // 4 · HR: one position on a State Manager opening
  await signIn(page, USERS.hrAdmin);
  const hr = await apiAs(page);
  const ten = await hr.rpc('save_opening', { p: { state_id: '00000000-0000-4000-8000-000000000001', role: 'state_manager', positions: 10 } });
  expect(String((ten.data as { message: string }).message)).toContain('one State Manager per state');
  await signOut(page);
});
