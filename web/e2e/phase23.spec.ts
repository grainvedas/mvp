// Migration 51 (Veda, 15 Oct 2026: the operator-stages brief, release 4, Part B "set-up lists", A14, A15), on a 527 px
// screen. The Client Manager keeps his client's lists (a point with its GPS pasted, a buyer in India only with a GSTIN or
// an FSSAI licence, a pack, one retired); the State Manager keeps a lab and a market profile (a new version activated
// only with its source document) and the crop's shelf life per material; a farmer is registered with a district from the
// state's list, a new block (added to the list) and the farm's GPS, which the Client Manager needs before step 1 and the
// State Manager sees checked at step 2. The ledger banner counts the blocks added since the last full check; the roster
// pool lists free people first, then those already on other scopes with their work, and says so when one is picked.
// Every rule is the database's (tests/45_setup_lists.sql).
import { test, expect } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, apiAs, fillFarmerPlace, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const uniq = () => String(Date.now()).slice(-6);
/** A place's name counts its letters only (app.norm_place): a unique one is spelt in letters. */
const letters = (u: string) => u.replace(/\d/g, (d) => 'abcdefghij'[Number(d)]);
const PDF = (what: string) => ({ name: `${what}.pdf`, mimeType: 'application/pdf', buffer: Buffer.from(`%PDF-1.4\n% ${what} ${Date.now()}\n%%EOF\n`) });

test('the Client Manager\'s lists: a collection point, a buyer, a pack, one retired', async ({ page }) => {
  test.setTimeout(180_000);
  const u = uniq();
  await signIn(page, USERS.cm);
  await page.goto('/setup');
  await expect(page.getByTestId('set-tab-lists')).toBeVisible();
  await expect(page.getByTestId('set-tab-labs')).toHaveCount(0);           // labs and profiles are the State Manager's
  // a collection point, its GPS pasted from a map app into the first box
  await page.getByTestId('set-add').click();
  await page.getByTestId('set-collection_points-name').fill(`Bansi centre ${u}`);
  await page.getByTestId('set-collection_points-kind').selectOption('centre');
  await page.getByTestId('set-collection_points-district').fill('Siddharthnagar');
  await page.getByLabel('Latitude').fill('51.5, -0.12');                     // London: refused before the save
  await page.getByLabel('Latitude').blur();                                   // a pair is split when the box is left (staging, 15 Oct)
  await page.getByTestId('set-save').click();
  await expect(page.getByTestId('set-problems')).toContainText('not in India');
  await page.getByLabel('Latitude').fill('27.1823, 82.9312');
  await page.getByLabel('Latitude').blur();
  await expect(page.getByLabel('Longitude')).toHaveValue('82.9312');
  await page.getByTestId('set-save').click();
  const point = page.getByTestId('set-row').filter({ hasText: `Bansi centre ${u}` });
  await expect(point).toContainText('27.1823, 82.9312');
  await expectNoSideScroll(page);
  // a buyer in India needs a GSTIN or an FSSAI licence (said before the save, and the table refuses it too)
  await page.getByTestId('set-list-buyers').click();
  await page.getByTestId('set-add').click();
  await page.getByTestId('set-buyers-name').fill(`Delhi Mart ${u}`);
  await page.getByTestId('set-buyers-address').fill('Chandni Chowk, Delhi');
  await page.getByTestId('set-save').click();
  await expect(page.getByTestId('set-problems')).toContainText('GSTIN or an FSSAI licence');
  await page.getByTestId('set-buyers-gstin').fill('07abcde1234f1z5');
  await page.getByTestId('set-save').click();
  await expect(page.getByTestId('set-row').filter({ hasText: `Delhi Mart ${u}` })).toContainText('07ABCDE1234F1Z5');
  // a pack: 500 g pouch for the domestic market; then retired (never deleted)
  await page.getByTestId('set-list-pack_skus').click();
  await page.getByTestId('set-add').click();
  await page.getByTestId('set-pack_skus-size').fill(`5${u.slice(-2)}`);
  await page.getByTestId('set-pack_skus-unit').selectOption('g');
  await page.getByTestId('set-pack_skus-material').selectOption('pouch');
  await page.getByTestId('set-save').click();
  const pack = page.getByTestId('set-row').filter({ hasText: `5${u.slice(-2)} g Pouch` });
  await expect(pack).toContainText('Domestic');
  await pack.getByTestId('set-flip').click();
  await expect(pack).toHaveAttribute('data-active', 'no');
  await expect(pack).toContainText('Retired');
  await expectNoSideScroll(page);
  await signOut(page);

  // the State Manager reads the client's lists, changes none
  await signIn(page, USERS.sm);
  await page.goto('/setup?tab=lists');
  await page.locator('#client-pick').selectOption('00000000-0000-4000-8000-000000000201');
  await expect(page.getByTestId('set-readonly')).toBeVisible();
  await expect(page.getByTestId('set-row').filter({ hasText: `Bansi centre ${u}` })).toBeVisible();
  await expect(page.getByTestId('set-add')).toHaveCount(0);
  await signOut(page);
});

test('the State Manager: a lab, a market profile with its source document, shelf life per material', async ({ page }) => {
  test.setTimeout(180_000);
  const u = uniq();
  await signIn(page, USERS.sm);
  await page.goto('/setup?tab=labs');
  await page.getByTestId('set-add').click();
  await page.getByTestId('set-labs-name').fill(`Agri Test Lab ${u}`);
  await page.getByTestId('set-labs-kind').selectOption('external');
  await page.getByTestId('set-labs-location').fill('Lucknow');
  await page.getByTestId('set-save').click();
  await expect(page.getByTestId('set-problems')).toContainText('accreditation');
  await page.getByTestId('set-labs-accreditation_no').fill(`TC-${u}`);
  await page.getByTestId('set-save').click();
  await expect(page.getByTestId('set-row').filter({ hasText: `Agri Test Lab ${u}` })).toContainText('External');

  // the parameter library: read-only, loaded once
  await page.getByTestId('set-tab-library').click();
  await expect(page.getByTestId('library-row').filter({ hasText: 'Aflatoxin' }).first()).toBeVisible();

  // market profiles of Kalanamak: Domestic and Export carried from the crop's limits; a new one, activated with its source
  await page.getByTestId('set-tab-profiles').click();
  await expect(page.getByTestId('profile-card').filter({ hasText: 'Domestic' })).toContainText('Version 1 in use');
  const code = `eu${u.slice(-4)}`;
  await page.getByTestId('np-code').fill(code);
  await page.getByTestId('np-name').fill(`EU ${u}`);
  await page.getByTestId('np-start').click();
  const card = page.locator(`[data-testid="profile-card"][data-code="${code}"]`);
  await expect(card).toContainText('Version 1 draft');
  await card.getByTestId('profile-add-param').click();
  await card.getByTestId('profile-param').locator('select').first().selectOption({ label: 'Aflatoxin B1 (µg/kg)' });
  await expect(card.getByTestId('profile-activate')).toBeDisabled();          // no source document yet
  await card.getByTestId('profile-limit').fill('2');
  await card.getByTestId('profile-save').click();
  await expect(card.getByTestId('profile-activate')).toBeDisabled();
  await card.getByTestId('profile-source-file').setInputFiles(PDF(`EU-2023-915-${u}`));
  await expect(card.getByTestId('profile-source')).toContainText(`EU-2023-915-${u}.pdf`);
  await card.getByTestId('profile-activate').click();
  await expect(card).toContainText('Version 1 in use');
  await expect(card.getByTestId('profile-params')).toContainText('Aflatoxin B1 ≤ 2 µg/kg');
  // a change is a new version; the one in use stays until it is activated
  await card.getByTestId('profile-change').click();
  await expect(card).toContainText('Version 2 draft');
  await expect(card).toContainText('Version 1 in use');
  await expectNoSideScroll(page);

  // the crop: shelf life per material; a crop without a GI number has no GI area to give
  await page.goto('/crops');
  await page.getByTestId('crop-row').filter({ hasText: 'Kalanamak' }).first().getByRole('button', { name: 'Edit' }).click();
  await page.getByTestId('crop-shelf-jute').fill('270');
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.getByTestId('crop-row').filter({ hasText: 'Kalanamak' }).first().getByTestId('crop-shelf-material')).toContainText('Jute bag 270 days');
  await expect(page.getByTestId('crop-row').filter({ hasText: 'Kalanamak' }).first().getByTestId('crop-gi-crop')).toContainText('Yes');
  await signOut(page);
});

test('a farmer from the lists, with the farm\'s GPS; the GPS check at step 2; the ledger banner; the roster pool', async ({ page }) => {
  test.setTimeout(300_000);
  const u = uniq();
  // A14: a full check now; what comes after it is counted
  await signIn(page, USERS.admin);
  await page.goto('/health');
  await page.getByTestId('check-now').click();
  await expect(page.getByTestId('ledger-added-since')).toContainText(/\d+ blocks were added after the last full check \(\d+ in the ledger now\)/);
  await signOut(page);

  await signIn(page, USERS.cm);
  await page.goto('/');
  await expect(page.getByTestId('ledger-health')).toContainText(/Last full ledger check .*: \d+ blocks intact · (nothing added since|\d+ blocks added since)/);
  const before = Number(await page.getByTestId('ledger-health').getAttribute('data-added'));
  // Needs my action: the demo farmers have no farm GPS yet (registered before: asked, not refused)
  await expect(page.getByTestId('needs-action-line').filter({ hasText: 'no farm GPS yet' })).toBeVisible();
  await page.getByTestId('needs-action-line').filter({ hasText: 'no farm GPS yet' }).getByRole('link').click();
  await expect(page.getByTestId('farmers-no-gps')).toBeChecked();
  await expect(page.getByTestId('farmer-no-gps').first()).toBeVisible();

  // a new farmer: the district from the state's list, a new block, the farm's GPS before step 1
  await page.goto('/farmers/new');
  await page.getByLabel('Name *', { exact: true }).fill(`Phoolmati ${u}`);
  await page.getByLabel('Father / husband name *').fill('Shri Jagdish');
  await expect(page.getByTestId('farmer-district')).toBeVisible();
  expect(await page.getByTestId('farmer-district').locator('option').count()).toBeGreaterThan(70);   // the 75 districts of UP
  await fillFarmerPlace(page, 'Siddharthnagar', `Gaon ${letters(u)}`, null);
  await page.getByTestId('farmer-block').fill(`Block ${letters(u)}`);
  await page.getByLabel('Mobile number *').fill(`93${u}51`);
  await page.getByLabel('Land (acres) *').fill('2');
  await page.getByTestId('farmer-gi-land').fill('1');
  await expect(page.getByTestId('farmer-needs-gps')).toBeVisible();
  await expect(page.getByTestId('farmer-save-verify')).toBeDisabled();
  await page.getByTestId('farmer-lat').pressSequentially('27.3, 82.9');      // typed key by key: not split while typing
  await expect(page.getByTestId('farmer-lat')).toHaveValue('27.3, 82.9');
  await expect(page.getByTestId('farmer-lng')).toHaveValue('');
  await page.getByTestId('farmer-lat').blur();                                // left: both boxes
  await expect(page.getByTestId('farmer-lat')).toHaveValue('27.3');
  await expect(page.getByTestId('farmer-lng')).toHaveValue('82.9');
  await expectNoSideScroll(page);
  await page.getByTestId('farmer-save-verify').click();
  await expect(page.getByRole('heading', { name: 'Farmers' })).toBeVisible();
  // the new block and village are on the state's list now
  const api = await apiAs(page);
  const placed = await api.rows('places', `block=eq.${encodeURIComponent(`Block ${letters(u)}`)}`);
  expect(placed).toEqual(expect.arrayContaining([expect.objectContaining({ district: 'Siddharthnagar', block: `Block ${letters(u)}`, village: `Gaon ${letters(u)}` })]));
  // A14: blocks were added since the full check
  await page.goto('/');
  await expect(page.getByTestId('ledger-health')).toContainText(/\d+ blocks added since/);
  expect(Number(await page.getByTestId('ledger-health').getAttribute('data-added'))).toBeGreaterThan(before);
  await signOut(page);

  // step 2: the State Manager sees the GPS check (the district's other farms have no GPS: too few to compare)
  await signIn(page, USERS.sm);
  await page.goto('/farmers');
  await page.locator('#client-pick').selectOption('00000000-0000-4000-8000-000000000201');
  await page.getByRole('tab', { name: 'Ready to verify' }).click();
  const row = page.getByTestId('farmer-row').filter({ hasText: `Phoolmati ${u}` });
  await expect(row.getByTestId('farmer-gps-check')).toHaveAttribute('data-status', /not_enough|near|far/);
  // A15: the overview counts the people holding stages on more than one scope
  await page.goto('/');
  await expect(page.getByTestId('sh-multi-scope')).toContainText('People holding stages on more than one scope');
  await signOut(page);

  // A15: the roster pool: free people first, then "Already on other scopes" with their work; picking one says so
  await signIn(page, USERS.cm);
  page.on('dialog', (d) => void d.accept());
  await page.goto(`/scopes/${SCOPES.siddharthnagar}/roster`);
  const pick = page.getByLabel('Assign Procurement (farm-gate)', { exact: true });
  await expect(pick.locator('optgroup[label="Already on other scopes"] option').first()).toBeAttached();
  const busy = pick.locator('optgroup[label="Already on other scopes"] option').filter({ hasText: /^QC Technician · .*Quality Control on/ }).first();
  await expect(busy).toHaveText(/ · .* on .* \((active|being set up)\)/);
  const who = (await busy.getAttribute('value'))!;
  const name = (await busy.textContent())!.split(' · ')[0];
  await pick.selectOption(who);
  await expect(page.getByTestId('pool-soft-note')).toContainText(`${name} already holds`);
  await expect(page.getByTestId('pool-soft-note')).toContainText('he will have two work queues');
  // taken back: the roster is as it was
  await page.getByRole('button', { name: `Remove: ${name} · Procurement (farm-gate)` }).click();
  await expect(page.getByRole('button', { name: `Remove: ${name} · Procurement (farm-gate)` })).toHaveCount(0);
  await expectNoSideScroll(page);
  await signOut(page);
});
