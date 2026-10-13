// The farmer register (migration 43, Veda 13 Oct 2026, State Manager brief part D), on a 527 px screen: the GI land is
// optional on a draft and needed before the Farmer ID; a possible duplicate (the same phone on another client's record
// in the state) stops the Farmer ID until Ram decides on the register — "Not the same person" with a reason, or
// deactivate one record; a lot that takes a farmer past his expected yield is warned, past 120 % he is flagged; the phone
// shows only its last four digits; the admin reads. Every rule is also the database's (tests/37_farmer_register.sql).
// The other client's record is seeded on the local stack only (no Client Manager of a second client on the demo).
import { test, expect } from '@playwright/test';
import { signIn, signOut, apiAs, expectNoSideScroll, localStack, refusal, USERS, SCOPES } from './helpers';

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
  await page.getByLabel('Village *').fill('Itwa');
  await page.getByLabel('District *').fill('Siddharthnagar');
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
  // another client of the state already has a record with this phone (and a second pair for the other answer)
  if (stack) {
    await stack.seedFarmer({ client_id: DEMOX, status: 'draft', name: `Same Phone ${u}`, guardian_name: 'F', village: 'Itwa', district: 'Siddharthnagar', phone: `+91${PHONE}`, land_area_acres: 1 });
    await stack.seedFarmer({ client_id: PRSDM, status: 'draft', name: `Pair One ${u}`, guardian_name: 'F', village: 'Bansi', district: 'Siddharthnagar', phone: `+91${PHONE2}`, land_area_acres: 1 });
    await stack.seedFarmer({ client_id: DEMOX, status: 'draft', name: `Pair Two ${u}`, guardian_name: 'F', village: 'Bansi', district: 'Siddharthnagar', phone: `+91${PHONE2}`, land_area_acres: 1 });
  }

  // 2 · Ram: no Farmer ID without the GI land; he adds it at step 2
  await signIn(page, USERS.sm);
  await page.goto('/farmers');
  await page.getByLabel('Client').selectOption(PRSDM);
  let row = page.getByTestId('farmer-row').filter({ hasText: NAME });
  await expect(row.getByTestId('farmer-needs-gi')).toBeVisible();
  await expect(row.getByTestId('farmer-step2')).toBeDisabled();
  await row.getByRole('link', { name: 'Add it' }).click();
  await expect(page.getByLabel('Name *', { exact: true })).toHaveValue(NAME);    // the record is in the form
  await page.getByTestId('farmer-gi-land').fill('0.1');                   // 100 kg of Kalanamak a season
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Farmers' })).toBeVisible();
  await page.getByLabel('Client').selectOption(PRSDM);
  row = page.getByTestId('farmer-row').filter({ hasText: NAME });
  await expect(row.getByTestId('farmer-step2')).toBeEnabled();
  if (stack) {
    await row.getByTestId('farmer-step2').click();
    await expect(row).toContainText('possible duplicate (same phone)');   // refused until he decides on the register

    // 3 · the register: both records flagged, each naming the other; the phone masked
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
    await expect(mine.getByTestId('reg-phone')).toHaveText(`Phone ••••••${PHONE.slice(-4)}`);
    await expect(page.getByTestId('farmer-register')).not.toContainText(PHONE);     // never the whole number
    await expectNoSideScroll(page);
    // "Not the same person": a reason is needed, and it is logged
    await mine.getByTestId('reg-dup-distinct').click();
    await expect(mine.getByTestId('reg-dup-save')).toBeDisabled();
    await mine.getByTestId('reg-dup-reason').fill('Brothers sharing one phone');
    await mine.getByTestId('reg-dup-save').click();
    await expect(card(NAME)).toHaveCount(0);   // no longer flagged
    // the other answer: deactivate one record of the second pair
    const two = card(`Pair Two ${u}`);
    await two.getByTestId('reg-dup-deactivate').click();
    await expect(two).toContainText('has no Farmer ID yet: once deactivated');
    await two.getByTestId('reg-dup-deactivate-confirm').click();
    await expect(card(`Pair One ${u}`)).toHaveCount(0);
    await page.getByTestId('reg-flag').selectOption('');
    await page.getByTestId('reg-status').selectOption('inactive');
    await expect(card(`Pair Two ${u}`)).toHaveCount(1);
    await page.getByTestId('reg-status').selectOption('');

    // 4 · now the Farmer ID
    await page.goto('/farmers');
    await page.getByLabel('Client').selectOption(PRSDM);
    await page.getByTestId('farmer-row').filter({ hasText: NAME }).getByTestId('farmer-step2').click();
    await page.getByRole('tab', { name: 'Active', exact: true }).click();
    await expect(page.getByTestId('farmer-row').filter({ hasText: NAME })).toContainText(/PRSDM-F-\d{4}/);
  } else {
    await row.getByTestId('farmer-step2').click();
    await page.getByRole('tab', { name: 'Active', exact: true }).click();
    await expect(page.getByTestId('farmer-row').filter({ hasText: NAME })).toContainText(/PRSDM-F-\d{4}/);
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

  // 6 · past 120 %: flagged on Ram's register, with his share of the expected yield
  await signIn(page, USERS.sm);
  await page.goto('/farmers/register');
  await page.getByTestId('reg-season').selectOption('KH26');
  await page.getByTestId('reg-flag').selectOption('over_yield');
  await page.getByTestId('reg-search').fill(u);
  const flagged = card(NAME);
  await expect(flagged.getByTestId('reg-flag-over_yield')).toBeVisible();
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
  await expect(page.getByTestId('reg-dup-distinct')).toHaveCount(0);
  await signOut(page);
});
