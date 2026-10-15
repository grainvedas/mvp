// The farmer register (migration 43, Veda 13 Oct 2026, State Manager brief part D; the model of migration 44, 14 Oct), on a
// 527 px screen: the GI land is optional on a draft and needed before the state farmer ID; a change to a farmer with a
// client farmer ID needs a reason; records waiting with the same phone are flagged on Ram's register and he decides at
// step 2 (the same person: link; another: a new state ID with the reason) or deactivates one record with a reason; a lot
// past the farmer's expected yield is a warning; the phone shows only its last four digits; the admin reads. Every rule is
// also the database's (tests/37_farmer_register.sql, tests/38_rules_and_farmer_ids.sql). The other client's records are
// seeded on the local stack only (no Client Manager of a second client on the demo).
import { test, expect } from '@playwright/test';
import { signIn, signOut, apiAs, expectNoSideScroll, localStack, refusal, USERS, SCOPES, fillFarmerPlace } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const PRSDM = '00000000-0000-4000-8000-000000000201';
const DEMOX = '00000000-0000-4000-8000-000000000202';
const u = String(Date.now()).slice(-6);
const NAME = `Register ${u}`;
const PHONE = `93${u}12`;                       // ten digits
const PHONE2 = `93${u}34`;

test('The farmer register: GI land, a possible duplicate, the yield check, the masked phone', async ({ page }) => {
  test.setTimeout(240_000);
  const stack = localStack();
  // a register card by its farmer's own name (another card names him in its duplicate line)
  const card = (name: string) => page.getByTestId('reg-row').filter({ has: page.locator('strong', { hasText: new RegExp(`^${name}$`) }) });
  // 1 · the Client Manager: a draft may go without GI land; more than the land is refused on the form
  await signIn(page, USERS.cm);
  await page.goto('/farmers/new');
  await page.getByLabel('Name *', { exact: true }).fill(NAME);
  await page.getByLabel('Father / husband name *').fill('Shri Raghu');
  await fillFarmerPlace(page, 'Siddharthnagar', 'Itwa');
  await page.getByLabel('Mobile number *').fill(PHONE);
  await page.getByLabel('Land (acres) *').fill('2');
  await page.getByTestId('farmer-gi-land').fill('3');
  await expect(page.getByTestId('farmer-gi-problem')).toHaveText('Not more than the land.');
  await expect(page.getByTestId('farmer-save-verify')).toBeDisabled();
  await page.getByTestId('farmer-gi-land').fill('');
  await expectNoSideScroll(page);
  await page.getByTestId('farmer-save-verify').click();
  await expect(page.getByRole('heading', { name: 'Farmers' })).toBeVisible();
  await signOut(page);
  // another client of the state has a record waiting with this phone (and a second pair for the other answer)
  const waiting = { status: 'under_review', gi_land_acres: 1, reviewed_by: '00000000-0000-4000-8000-000000000303' };
  if (stack) {
    await stack.seedFarmer({ client_id: DEMOX, ...waiting, name: `Same Phone ${u}`, guardian_name: 'F', village: 'Itwa', district: 'Siddharthnagar', phone: `+91${PHONE}`, land_area_acres: 1 });
    await stack.seedFarmer({ client_id: PRSDM, ...waiting, name: `Pair One ${u}`, guardian_name: 'F', village: 'Bansi', district: 'Siddharthnagar', phone: `+91${PHONE2}`, land_area_acres: 1 });
    await stack.seedFarmer({ client_id: DEMOX, ...waiting, name: `Pair Two ${u}`, guardian_name: 'F', village: 'Bansi', district: 'Siddharthnagar', phone: `+91${PHONE2}`, land_area_acres: 1 });
  }

  // 2 · Ram: no state farmer ID without the GI land; he adds it, with a reason (the farmer has a client farmer ID)
  await signIn(page, USERS.sm);
  await page.goto('/farmers');
  await page.getByLabel('Client').selectOption(PRSDM);
  let row = page.getByTestId('farmer-row').filter({ hasText: NAME });
  await expect(row).toContainText(/PRSDM-F-\d{4}/);                       // given at step 1 (migration 44)
  await expect(row.getByTestId('farmer-needs-gi')).toBeVisible();
  await expect(row.getByTestId('farmer-step2')).toBeDisabled();
  await row.getByRole('link', { name: 'Add it' }).click();
  await expect(page.getByLabel('Name *', { exact: true })).toHaveValue(NAME);    // the record is in the form
  await page.getByTestId('farmer-gi-land').fill('0.1');                   // 100 kg of Kalanamak a season
  await expect(page.getByRole('button', { name: 'Save', exact: true })).toBeDisabled();
  await page.getByTestId('farmer-why').fill('GI land from the land record');
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Farmers' })).toBeVisible();
  if (stack) {
    // 3 · the register: the records waiting with one phone are flagged, each naming the other; the phone masked
    await page.goto('/');
    await page.getByTestId('sh-tile-action').click();
    await expect(page.getByTestId('act-duplicates')).toContainText(/Possible duplicate farmers \(same phone\): [1-9]/);
    await page.getByTestId('act-duplicates').getByRole('link').click();
    await expect(page.getByTestId('farmer-register')).toBeVisible();
    await expect(page.getByTestId('reg-flag')).toHaveValue('duplicate');
    await page.getByTestId('reg-search').fill(u);
    const mine = card(NAME);
    await expect(mine.getByTestId('reg-flag-duplicate')).toBeVisible();
    await expect(mine.getByTestId('reg-dup')).toContainText(`Same Phone ${u}`);
    await expect(mine.getByTestId('reg-dup-verify')).toBeVisible();          // he decides when he verifies it
    await expect(mine.getByTestId('reg-phone')).toHaveText(`Phone ••••••${PHONE.slice(-4)}`);
    await expect(page.getByTestId('farmer-register')).not.toContainText(PHONE);     // never the whole number
    await expectNoSideScroll(page);
    // the other answer: deactivate one record of the second pair, with a reason
    const two = card(`Pair Two ${u}`);
    await two.getByTestId('reg-dup-deactivate').click();
    await expect(two).toContainText('has no state farmer ID yet: once deactivated');
    await expect(two.getByTestId('reg-dup-deactivate-confirm')).toBeDisabled();
    await two.getByTestId('reg-dup-reason').fill('Entered twice by mistake');
    await two.getByTestId('reg-dup-deactivate-confirm').click();
    await expect(card(`Pair One ${u}`)).toHaveCount(0);
    await page.getByTestId('reg-flag').selectOption('');
    await page.getByTestId('reg-status').selectOption('inactive');
    await expect(card(`Pair Two ${u}`)).toHaveCount(1);
    await page.getByTestId('reg-status').selectOption('');
  }
  // 4 · step 2: a new state farmer ID (nobody in the state has one with this phone yet)
  await page.goto('/farmers');
  await page.getByLabel('Client').selectOption(PRSDM);
  await page.getByTestId('farmer-row').filter({ hasText: NAME }).getByTestId('farmer-step2').click();
  await page.getByRole('tab', { name: 'Active', exact: true }).click();
  await expect(page.getByTestId('farmer-row').filter({ hasText: NAME }).getByTestId('farmer-state-id')).toHaveText(/^F-UP-\d{5}$/);
  const stateId = (await page.getByTestId('farmer-row').filter({ hasText: NAME }).getByTestId('farmer-state-id').textContent())!;
  if (stack) {
    // the other client's record with this phone: "not the same person" needs a reason, and gives a new state farmer ID
    await page.getByLabel('Client').selectOption(DEMOX);
    await page.getByRole('tab', { name: 'Ready to verify' }).click();
    const other = page.getByTestId('farmer-row').filter({ hasText: `Same Phone ${u}` });
    await expect(other.getByTestId('farmer-same-phone')).toContainText(`Same phone as ${stateId}`);
    await other.getByTestId('farmer-not-same').click();
    await expect(other.getByTestId('farmer-new-id')).toBeDisabled();
    await other.getByTestId('farmer-not-same-why').fill('Brothers sharing one phone');
    await other.getByTestId('farmer-new-id').click();
    await page.getByRole('tab', { name: 'Active', exact: true }).click();
    const given = page.getByTestId('farmer-row').filter({ hasText: `Same Phone ${u}` }).getByTestId('farmer-state-id');
    await expect(given).toHaveText(/^F-UP-\d{5}$/);
    expect(await given.textContent()).not.toBe(stateId);
  }
  const farmer = (await (await apiAs(page)).rows('farmers', `name=eq.${encodeURIComponent(NAME)}`))[0] as { id: string };
  await signOut(page);

  // 5 · Procurement: two lots of about 98 kg against 100 kg expected: the second is warned
  await signIn(page, USERS.procurement);
  const op = await apiAs(page);
  const lot = () => op.insert('footprints', { scope_id: SCOPES.siddharthnagar, client_id: PRSDM, stage_type: 'procurement', farmer_id: farmer.id,
    created_by: '00000000-0000-4000-8000-000000000305', payload: { gross_kg: 100, bags: 2, tare_kg_per_bag: 1, moisture_pct: [12, 12, 12] } });
  const first = await lot();
  expect(first.ok, refusal(first)).toBe(true);
  expect((first.data as { warnings: string[] }[])[0].warnings.some((w) => w.startsWith('above the expected yield'))).toBe(false);
  const second = await lot();
  expect(second.ok, refusal(second)).toBe(true);
  expect((second.data as { warnings: string[] }[])[0].warnings).toContain('above the expected yield: 196 of 100 kg this season (0.10 acres of GI land)');
  await signOut(page);

  // 6 · past the expected yield: a warning on Ram's register (not a flag: not his to decide), with his share
  await signIn(page, USERS.sm);
  await page.goto('/farmers/register');
  await page.getByTestId('reg-season').selectOption('KH26');
  await page.getByTestId('reg-flag').selectOption('above_yield');
  await page.getByTestId('reg-search').fill(u);
  const flagged = card(NAME);
  await expect(flagged.getByTestId('reg-warn-above_yield')).toBeVisible();
  await expect(flagged.getByTestId('reg-flag-duplicate')).toHaveCount(0);
  await expect(flagged.getByTestId('reg-yield')).toContainText('(196%)');
  await expect(flagged.getByTestId('reg-land')).toHaveText('0.1 acres of GI land of 2');
  await expectNoSideScroll(page);
  await signOut(page);

  // 7 · the admin reads the register and decides nothing
  await signIn(page, USERS.admin);
  await page.goto('/farmers/register');
  await expect(page.getByTestId('reg-readonly')).toBeVisible();
  await page.getByTestId('reg-state').selectOption({ label: 'Uttar Pradesh' });       // he picks the state
  await page.getByTestId('reg-season').selectOption('KH26');
  await page.getByTestId('reg-search').fill(u);
  await expect(card(NAME)).toBeVisible();
  await expect(page.getByTestId('reg-dup-deactivate')).toHaveCount(0);
  await signOut(page);
});
