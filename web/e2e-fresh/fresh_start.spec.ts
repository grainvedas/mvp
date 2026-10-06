import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { addJoiner, freshEmail, setOwnPassword, signInWith, signOut } from '../e2e/helpers';

// THE FIRST DAY OF A PILOT, from a system with nothing in it: no state, no crop, no client, no person but one admin.
// Every other suite starts from demo rows a seed put in place; this one starts where scripts/staging_fresh_start.ps1
// (or local-stack/fresh_start.sh) leaves a project: the rules, the 16 stage definitions, the standard joining
// checklist, and the first admin with a temporary password in .env.admin-login.
// Run:  local-stack/fresh_start.sh  &&  cd web && npx playwright test -c playwright.fresh.config.ts
// It empties nothing itself and it cannot run twice on the same system (the admin's temporary password is used up).
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const adminLogin = () => {
  const text = readFileSync(join(ROOT, '.env.admin-login'), 'utf8');
  return { email: /^ADMIN_EMAIL=(.+)$/m.exec(text)![1].trim(), temp: /^ADMIN_TEMPORARY_PASSWORD=(.+)$/m.exec(text)![1].trim() };
};
const u = Date.now().toString().slice(-6);
const PW = { admin: `Admin-${u}-first`, hr: `Hr-${u}-first`, manager: `Manager-${u}-first`, buy: `Kharid-${u}-first`, lab: `Jaanch-${u}-first`, seal: `Mohar-${u}-first` };

test('From an empty system to the first sealed lot: state, crop, client, HR seat, people, scope, farmer, lot', async ({ page }) => {
  test.setTimeout(600_000);
  const admin = adminLogin();
  const main = page.locator('main');
  const reviewSave = async (pattern: RegExp) => {
    await expect(page.getByTestId('preview-ok')).toBeVisible();
    await page.getByRole('button', { name: 'Review' }).click();
    await page.getByLabel('I have checked these numbers against the lot').check();
    await page.getByRole('button', { name: 'Save record' }).click();
    await expect(page.getByTestId('saved')).toBeVisible();
    return (await page.getByTestId('saved').textContent())!.match(pattern)![0];
  };
  const verify = async (lot: string) => {
    await page.getByTestId('incoming-row').filter({ hasText: lot }).click();
    for (const box of await page.getByRole('checkbox').all()) await box.check();
    await page.getByRole('button', { name: 'Verify this lot' }).click();
    await expect(page.locator('.alert.ok', { hasText: 'Verified' })).toBeVisible();
  };

  // 1. The admin's first sign-in: the temporary password, an own password, and a first screen that copes with nothing
  await signInWith(page, admin.email, admin.temp);
  await setOwnPassword(page, PW.admin);
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
  await expect(page.locator('.alert.error')).toHaveCount(0);
  for (const path of ['/people', '/scopes', '/farmers', '/hr', '/state', '/system/audit', '/flags']) {
    await page.goto(path);
    await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
    await expect(main.locator('.alert.error'), `an error on ${path} of an empty system`).toHaveCount(0);
  }

  // 2. A state
  await page.goto('/states');
  await page.getByPlaceholder('State name').fill('Uttar Pradesh');
  await page.getByPlaceholder('Code (e.g. BR)').fill('up');
  await page.getByRole('button', { name: 'Create' }).click();
  await expect(main.locator('li', { hasText: 'Uttar Pradesh' })).toContainText('UP');

  // 3. A crop with its three limits (decimals must stay decimals) and the processing stages it may go through
  await page.goto('/crops');
  await page.getByRole('button', { name: 'Create' }).click();
  await page.getByLabel('Name').fill('Kalanamak rice');
  await page.getByLabel('Code').fill('knm');
  await page.getByLabel('GI tag').fill('GI 280');
  await page.getByLabel('Origin').fill('Eastern UP Terai belt (Siddharthnagar)');
  const limits = [['moisture_pct', 'Moisture', '13', '12'], ['broken_pct', 'Broken grains', '5', '3'], ['foreign_matter_pct', 'Foreign matter', '1', '0.5']];
  for (const [i, [key, label, domestic, exp]] of limits.entries()) {
    await page.getByRole('button', { name: '+ limit' }).click();
    const row = page.locator('tbody tr').nth(i);
    await row.getByLabel('key').fill(key);
    await row.getByLabel('label').fill(label);
    await row.getByLabel('domestic limit').fill(domestic);
    await row.getByLabel('export limit').fill(exp);
  }
  for (const stage of ['Milling', 'Sorting', 'Grading']) await page.getByLabel(stage, { exact: true }).check();
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(main.locator('li', { hasText: 'Kalanamak rice' })).toContainText('KNM');
  await main.locator('li', { hasText: 'Kalanamak rice' }).getByRole('button', { name: 'Edit' }).click();
  await expect(page.locator('tbody tr').nth(2).getByLabel('export limit')).toHaveValue('0.5');
  await page.getByRole('button', { name: 'Cancel' }).click();

  // 4. The first client
  await page.goto('/clients');
  await page.locator('form').getByLabel('Name').fill('Prasaadam');
  await page.locator('form').getByLabel('Code').fill('prsdm');
  await page.locator('form').getByLabel('State').selectOption({ label: 'Uttar Pradesh' });
  await page.locator('form').getByRole('button', { name: 'Create' }).click();
  await expect(page.getByRole('row').filter({ hasText: 'Prasaadam' })).toContainText('PRSDM');

  // 5. Nobody is HR yet: the admin adds the first HR person, marks them joined, and gives them the HR Admin seat
  const hr = { name: `Asha HR ${u}`, email: freshEmail('hr') };
  const hrMade = await addJoiner(page, { ...hr, type: 'full_time', title: 'HR Lead', systemRole: 'hr_resource' });
  await page.getByTestId('activate').click();
  await expect(page.getByTestId('activate')).toHaveCount(0);
  await page.goto('/system/seats');
  await expect(page.getByTestId('seat-vacant')).toBeVisible();
  await page.locator('#seat-pick').selectOption(hrMade.id);
  await expect(page.locator('#seat-pick option:checked')).toHaveText(`${hr.name} (HR)`);
  page.once('dialog', (d) => d.accept());
  await page.getByTestId('appoint').click();
  await expect(page.getByTestId('seat-hr-admin')).toContainText(hr.name);
  await expect(page.getByTestId('seat-vacant')).toHaveCount(0);
  await signOut(page);

  // 6. The HR Admin: own password, then four people, as identities only
  await signInWith(page, hr.email, hrMade.temp);
  await setOwnPassword(page, PW.hr);
  const who = {
    manager: { name: `Client Lead ${u}`, email: freshEmail('manager'), type: 'full_time', title: 'Client Lead' },
    buy: { name: `Kharid ${u}`, email: freshEmail('kharid'), type: 'contract', title: 'Field Associate' },
    lab: { name: `Jaanch ${u}`, email: freshEmail('jaanch'), type: 'contract', title: 'Lab Technician' },
    seal: { name: `Mohar ${u}`, email: freshEmail('mohar'), type: 'contract', title: 'Field Associate' },
  };
  const made: Record<string, { id: string; temp: string }> = {};
  for (const [k, p] of Object.entries(who)) {
    made[k] = await addJoiner(page, p);
    await page.getByTestId('activate').click();
    await expect(page.getByTestId('activate')).toHaveCount(0);
  }
  await signOut(page);

  // 7. The admin gives one of them the client's account (there is no State Manager yet; the admin may give anything)
  await signInWith(page, admin.email, PW.admin);
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
  await page.goto(`/people/${made.manager.id}`);
  await page.getByTestId('give-assignment').click();
  await page.getByRole('tab', { name: "A client's account" }).click();
  await page.getByLabel('Client', { exact: true }).selectOption({ label: 'Prasaadam' });
  await page.getByTestId('assign-save').click();
  await expect(page.getByTestId('assignment')).toContainText('Prasaadam');
  await signOut(page);

  // 8. The Client Manager: a scope with the shortest chain, a person at each stage, activate; then a farmer
  await signInWith(page, who.manager.email, made.manager.temp);
  await setOwnPassword(page, PW.manager);
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
  await page.goto('/scopes/new');
  await page.getByLabel(/Geography/).fill('Siddharthnagar');
  await expect(page.locator('#wz-state option:checked')).toHaveText("Uttar Pradesh (client's home state)");
  await page.getByRole('button', { name: 'Next' }).click();
  await page.getByLabel('Crop').selectOption({ label: 'Kalanamak rice' });
  await page.getByRole('button', { name: 'Next' }).click();
  await expect(page.getByTestId('chain-preview')).toContainText('Procurement (farm-gate) → Quality Control → QR Activation (seal)');
  await page.getByRole('button', { name: /Save draft/ }).click();
  await expect(page.getByRole('heading', { name: /Siddharthnagar/ })).toContainText('Draft');
  for (const [label, k] of [['Assign Procurement (farm-gate)', 'buy'], ['Assign Quality Control', 'lab'], ['Assign QR Activation (seal)', 'seal']] as const) {
    await page.getByLabel(label).selectOption({ label: who[k].name });
    await expect(page.getByTestId('slots').getByRole('link', { name: who[k].name })).toBeVisible();
  }
  await expect(page.getByTestId('roster-covered')).toBeVisible();
  page.once('dialog', (d) => d.accept());
  await page.getByRole('button', { name: 'Activate scope' }).click();
  await expect(page.getByRole('heading', { name: /Siddharthnagar/ })).toContainText('Active');

  await page.goto('/farmers/new');
  await page.getByLabel('Name *', { exact: true }).fill(`Ramkali ${u}`);
  await page.getByLabel('Father / husband name *').fill('Shri Bhola');
  await page.getByLabel('Village *').fill('Bansi');
  await page.getByLabel('District *').fill('Siddharthnagar');
  await page.getByLabel('Mobile number *').fill(`94${u}41`);
  await page.getByLabel('Land (acres) *').fill('2');
  await page.getByRole('button', { name: 'Submit for verification' }).click();
  await expect(page.getByRole('heading', { name: 'Farmers' })).toBeVisible();
  await signOut(page);

  // 9. The admin verifies the farmer: the very first Farmer ID of the system
  await signInWith(page, admin.email, PW.admin);
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
  await page.goto('/farmers');
  await page.getByRole('tab', { name: 'Ready to verify' }).click();
  await page.getByTestId('farmer-row').filter({ hasText: `Ramkali ${u}` }).getByRole('button', { name: 'Verify and issue Farmer ID' }).click();
  await page.getByRole('tab', { name: 'Active', exact: true }).click();
  await expect(page.getByTestId('farmer-row').filter({ hasText: `Ramkali ${u}` })).toContainText('PRSDM-F-0001');
  await signOut(page);

  // 10. Buy, test against the limits typed in step 3, seal
  await signInWith(page, who.buy.email, made.buy.temp);
  await setOwnPassword(page, PW.buy);
  await page.getByTestId('slot-procurement').click();
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill('Ramkali');
  await page.getByRole('button', { name: new RegExp(`Ramkali ${u}`) }).click();
  await page.getByLabel(/Gross weight/).fill('120');
  await page.getByLabel(/^Bags/).fill('2');
  await page.getByLabel(/Tare per bag/).fill('1');
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('11.7');
  const lot = await reviewSave(/PRSDM-KNM-[A-Z0-9]+-P-0001/);
  await signOut(page);

  await signInWith(page, who.lab.email, made.lab.temp);
  await setOwnPassword(page, PW.lab);
  await page.getByTestId('slot-qc').click();
  await verify(lot);
  await page.getByRole('button', { name: /Record Quality Control/ }).click();
  await page.getByLabel(/Sample drawn/).fill('1');
  await page.getByLabel(/^Moisture \(%\)/).fill('11.7');
  await page.getByLabel(/^Broken grains/).fill('2');
  await page.getByLabel(/^Foreign matter/).fill('0.2');
  const tested = await reviewSave(/PRSDM-KNM-[A-Z0-9]+-QC-0001/);
  await signOut(page);

  await signInWith(page, who.seal.email, made.seal.temp);
  await setOwnPassword(page, PW.seal);
  await page.getByTestId('slot-qr_activation').click();
  await verify(tested);
  await page.getByRole('button', { name: 'Activate and seal' }).click();
  const qr = (await page.getByTestId('sealed').textContent())!.match(/GV-[0-9A-F]{12}/)![0];
  await signOut(page);

  // 11. Anyone with the QR code: the public page of the first lot
  await page.goto(`/verify/${qr}`);
  await expect(page.locator('main, body').first()).toContainText(`Ramkali ${u}`);
  await expect(page.locator('main, body').first()).toContainText('Bansi');
  await expect(page.locator('body')).not.toContainText(`94${u}41`);
});
