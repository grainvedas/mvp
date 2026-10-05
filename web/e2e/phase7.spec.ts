// FIX_LIST fault 32 (4 October 2026): on staging "New user" failed every time with "Login created but not linked; both
// removed". The database had migration 23, the create-user function was the build of 1 October, reset-password was not
// deployed at all. Here the browser is given the answers staging gave that day (read from it), and the Users page has
// to say what is wrong with the server, before and after the form is used. With the real local functions: no warning.
import { test, expect } from '@playwright/test';
import { signIn, signOut, USERS } from './helpers';

const uniq = () => String(Date.now()).slice(-6);

test.use({ viewport: { width: 1366, height: 768 }, isMobile: false, hasTouch: false, deviceScaleFactor: 1 });

test('Server functions left behind: the Users page says so, and a failed "New user" names the server, not the person', async ({ page }) => {
  // create-user as deployed on 1 Oct: no build header; GET is refused; a new user ends in the unlinked message.
  await page.route('**/functions/v1/create-user', (route) => {
    const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'POST, OPTIONS' };
    const m = route.request().method();
    if (m === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
    if (m === 'POST') return route.fulfill({ status: 500, headers: cors, contentType: 'application/json', body: JSON.stringify({ error: 'login created but not linked; both removed' }) });
    return route.fulfill({ status: 405, headers: cors, contentType: 'application/json', body: JSON.stringify({ error: 'POST only' }) });
  });
  // reset-password not deployed: the gateway's 404 carries no CORS headers, so the browser reports a failed request.
  await page.route('**/functions/v1/reset-password', (route) => route.abort('failed'));

  await signIn(page, USERS.cm);
  await page.goto('/users');
  const warning = page.getByTestId('functions-warning');
  // (soft: the form below must be reached also by an app that has no warning, so that the fault itself is shown)
  await expect.soft(warning).toBeVisible();
  await expect.soft(warning).toContainText('"create-user" is older than this app', { useInnerText: true, timeout: 3000 });
  await expect.soft(warning).toContainText('"reset-password" is not installed', { useInnerText: true, timeout: 3000 });
  await expect.soft(warning).toContainText('run-sheet step A6', { useInnerText: true, timeout: 3000 });

  const u = uniq();
  await page.getByLabel('Name').fill(`Nobody ${u}`);
  await page.getByLabel('Mobile').fill(`96${u}22`);
  await page.getByRole('button', { name: 'Create' }).click();
  const error = page.locator('form').getByRole('alert');
  await expect(error).toBeVisible();
  await expect.soft(error).toContainText('The server is not up to date with this app', { useInnerText: true, timeout: 3000 });
  await expect.soft(error).toContainText('Nothing is wrong with what you entered', { useInnerText: true, timeout: 3000 });
  await expect(error).toContainText('ogin created but not linked; both removed', { useInnerText: true });   // the function's own words are kept
  await expect(page.getByTestId('temp-password')).toHaveCount(0);

  // Reset password, with the function missing: not "No connection"
  const row = page.getByTestId('user-row').filter({ hasText: 'QC Technician' });
  await row.getByTestId('reset-password').click();
  await row.getByTestId('reset-confirm').click();
  await expect(row.getByTestId('reset-confirm')).toHaveCount(0);                        // the attempt is over
  await expect.soft(page.getByText('No connection to the server')).toHaveCount(0);
  await expect(page.getByRole('alert').filter({ hasText: 'reset-password' })).toContainText('A part of the server is not installed', { useInnerText: true });

  // The real functions of this repository: no warning, and the same form works.
  await page.unroute('**/functions/v1/create-user');
  await page.unroute('**/functions/v1/reset-password');
  const asked = page.waitForResponse((r) => r.url().endsWith('/functions/v1/reset-password') && r.request().method() === 'GET');
  await page.reload();
  expect((await asked).headers()['x-grainveda-function']).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  await expect(page.getByTestId('user-row').first()).toBeVisible();
  await expect(warning).toHaveCount(0);
  await page.getByLabel('Name').fill(`Somebody ${u}`);
  await page.getByLabel('Mobile').fill(`96${u}22`);
  await page.getByRole('button', { name: 'Create' }).click();
  await expect(page.getByTestId('temp-password')).toContainText(`+9196${u}22`);
  await expect(page.getByTestId('user-row').filter({ hasText: `Somebody ${u}` })).toContainText('linked');
  await signOut(page);
});

// FIX_LIST fault 33 (5 October 2026, reported by Veda from the deployed app): Admin → Clients → Create answered "Not
// allowed for your role or stage." for the admin. No client had ever been created from the screen: the demo clients
// come from a seed. The read rule on clients could not see a row in the statement that inserts it (migration 30).
test('An admin adds a client from the screen; a State Manager adds one in the own state; the new client can be given a manager', async ({ page }) => {
  test.setTimeout(120_000);
  const u = uniq(); const code = `C${u.slice(-4)}`; const name = `Terai Exports ${u}`;
  await signIn(page, USERS.admin);
  await page.goto('/clients');
  const form = page.locator('form');
  await form.getByLabel('Name').fill(name);
  await form.getByLabel('Code').fill(code.toLowerCase());                       // typed small: stored in capitals
  await form.getByLabel('Type').selectOption('exporter');
  await form.getByLabel('State').selectOption({ label: 'Uttar Pradesh' });
  await form.getByRole('button', { name: 'Create' }).click();
  await expect.soft(page.getByText('Not allowed for your role or stage.')).toHaveCount(0);
  const row = page.getByRole('row').filter({ hasText: name });
  await expect(row).toBeVisible();
  await expect(row).toContainText(code);
  await expect(row).toContainText('Uttar Pradesh');
  await expect(form.getByLabel('Name')).toHaveValue('');                      // the form is ready for the next one
  // the same code again is refused in plain words, and nothing is added twice
  await form.getByLabel('Name').fill(`${name} again`);
  await form.getByLabel('Code').fill(code);
  await form.getByLabel('State').selectOption({ label: 'Uttar Pradesh' });
  await form.getByRole('button', { name: 'Create' }).click();
  await expect(form.getByRole('alert')).toContainText('This already exists');
  await expect(page.getByRole('row').filter({ hasText: code })).toHaveCount(1);
  // the new client can be given its Client Manager
  await page.goto('/users');
  await page.getByLabel('Role').selectOption('client_manager');
  await page.getByLabel('Name').fill(`Manager ${u}`);
  await page.getByLabel('Email').fill(`manager${u}@example.test`);
  await page.getByLabel('Client').selectOption({ label: name });
  await page.getByRole('button', { name: 'Create' }).click();
  await expect(page.getByTestId('temp-password')).toContainText(`manager${u}@example.test`);
  await expect(page.getByTestId('user-row').filter({ hasText: `Manager ${u}` })).toContainText(name);
  await signOut(page);

  await signIn(page, USERS.sm);
  await page.goto('/clients');
  await form.getByLabel('Name').fill(`Purvanchal FPO ${u}`);
  await form.getByLabel('Code').fill(`F${u.slice(-4)}`);
  await form.getByLabel('Type').selectOption('fpo');
  await form.getByLabel('State').selectOption({ label: 'Uttar Pradesh' });
  await form.getByRole('button', { name: 'Create' }).click();
  await expect(page.getByRole('row').filter({ hasText: `Purvanchal FPO ${u}` })).toBeVisible();
  await expect(page.getByRole('row').filter({ hasText: name })).toBeVisible();   // the admin's new client, same state
  await signOut(page);
});

// Everything before this test ran on demo data that a seed puts in place: the client, its scopes and its people were
// never made from the screens. Both faults Veda reported from staging (32, 33) were in exactly that: setting a client
// up by hand. This is that path from nothing, through the screens only: a new client, its manager, a scope, three
// new people, a farmer, and the first lot to its public page.
test('A brand-new client, set up from the screens only: manager, scope, people, farmer, first lot sealed', async ({ page }) => {
  test.setTimeout(300_000);
  const u = uniq(); const code = `N${u.slice(-4)}`; const client = `Naya Client ${u}`; const mail = `naya${u}@example.test`;
  const temp = async () => (await page.getByTestId('temp-password').textContent())!.match(/: (Gv-[A-Za-z0-9_-]+) —/)![1];
  const firstSignIn = async (id: { email?: string; phone?: string }, tempPw: string, own: string) => {
    await page.goto('/'); await page.evaluate(() => localStorage.clear()); await page.goto('/');
    if (id.email) await page.getByRole('tab', { name: /Email/ }).click();
    await page.getByLabel(id.email ? 'Email' : 'Phone').fill(id.email ?? id.phone!);
    await page.getByLabel('Password').fill(tempPw);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page.getByTestId('must-change')).toBeVisible();
    await page.getByLabel('New password', { exact: true }).fill(own);
    await page.getByLabel('New password again').fill(own);
    await page.getByRole('button', { name: 'Set password' }).click();
    await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
  };
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

  // 1. admin: the client and its manager
  await signIn(page, USERS.admin);
  await page.goto('/clients');
  await page.locator('form').getByLabel('Name').fill(client);
  await page.locator('form').getByLabel('Code').fill(code);
  await page.locator('form').getByLabel('State').selectOption({ label: 'Uttar Pradesh' });
  await page.locator('form').getByRole('button', { name: 'Create' }).click();
  await expect(page.getByRole('row').filter({ hasText: client })).toBeVisible();
  await page.goto('/users');
  await page.getByLabel('Role').selectOption('client_manager');
  await page.getByLabel('Name').fill(`Naya Manager ${u}`);
  await page.getByLabel('Email').fill(mail);
  await page.getByLabel('Client').selectOption({ label: client });
  await page.getByRole('button', { name: 'Create' }).click();
  const managerTemp = await temp();
  await signOut(page);

  // 2. the manager: own password, a scope with the shortest chain, a new person at each stage, activate
  await firstSignIn({ email: mail }, managerTemp, `Manager-${u}`);
  await expect(page.getByTestId('tb-context')).toHaveText(client);
  await page.goto('/scopes/new');
  await page.getByLabel(/Geography/).fill(`Maharajganj ${u}`);
  await page.getByRole('button', { name: 'Next' }).click();
  await page.getByLabel('Crop').selectOption({ label: 'Kalanamak rice' });
  await page.getByRole('button', { name: 'Next' }).click();
  await expect(page.getByTestId('chain-preview')).toContainText('Procurement (farm-gate) → Quality Control → QR Activation (seal)');
  await page.getByRole('button', { name: /Save draft/ }).click();
  await expect(page.getByRole('heading', { name: new RegExp(`Maharajganj ${u}`) })).toContainText('Draft');
  const people: Record<string, { phone: string; temp: string }> = {};
  for (const [stage, label, n] of [['procurement', /Procurement/, '31'], ['qc', /Quality Control/, '32'], ['qr', /QR Activation/, '33']] as const) {
    await page.getByRole('row', { name: label }).getByRole('button', { name: '+ new person' }).click();
    await page.getByLabel('Name').fill(`Naya ${stage} ${u}`);
    await page.getByLabel('Mobile').fill(`95${u}${n}`);
    await page.getByRole('button', { name: 'Create' }).click();
    await expect(page.getByRole('row', { name: label })).toContainText(`Naya ${stage} ${u}`);
    people[stage] = { phone: `9195${u}${n}`, temp: await temp() };
  }
  page.once('dialog', (d) => d.accept());
  await page.getByRole('button', { name: 'Activate scope' }).click();
  await expect(page.getByRole('heading', { name: new RegExp(`Maharajganj ${u}`) })).toContainText('Active');

  // 3. the manager registers a farmer; the State Manager verifies; the Farmer ID carries the new client's code
  await page.goto('/farmers/new');
  await page.getByLabel('Name *', { exact: true }).fill(`Ramkali ${u}`);
  await page.getByLabel('Father / husband name *').fill('Shri Bhola');
  await page.getByLabel('Village *').fill('Nichlaul');
  await page.getByLabel('District *').fill('Maharajganj');
  await page.getByLabel('Mobile number *').fill(`94${u}41`);
  await page.getByLabel('Land (acres) *').fill('2');
  await page.getByRole('button', { name: 'Submit for verification' }).click();
  await expect(page.getByRole('heading', { name: 'Farmers' })).toBeVisible();
  await signOut(page);
  await signIn(page, USERS.sm);
  await page.goto('/farmers');
  await page.getByLabel('Client').selectOption({ label: client });
  await page.getByRole('tab', { name: 'Ready to verify' }).click();
  await page.getByTestId('farmer-row').filter({ hasText: `Ramkali ${u}` }).getByRole('button', { name: 'Verify and issue Farmer ID' }).click();
  await page.getByRole('tab', { name: 'Active', exact: true }).click();
  await expect(page.getByTestId('farmer-row').filter({ hasText: `Ramkali ${u}` })).toContainText(new RegExp(`${code}-F-0001`));
  await signOut(page);

  // 4. the three new people, each with an own password: buy, test, seal
  await firstSignIn({ phone: people.procurement.phone }, people.procurement.temp, `Kharid-${u}`);
  await page.getByTestId('slot-procurement').click();
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill('Ramkali');
  await page.getByRole('button', { name: new RegExp(`Ramkali ${u}`) }).click();
  await page.getByLabel(/Gross weight/).fill('120');
  await page.getByLabel(/^Bags/).fill('2');
  await page.getByLabel(/Tare per bag/).fill('1');
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('11.7');
  const lot = await reviewSave(new RegExp(`${code}-KNM-[A-Z0-9]+-P-0001`));
  await signOut(page);

  await firstSignIn({ phone: people.qc.phone }, people.qc.temp, `Jaanch-${u}`);
  await page.getByTestId('slot-qc').click();
  await verify(lot);
  await page.getByRole('button', { name: /Record Quality Control/ }).click();
  await page.getByLabel(/Sample drawn/).fill('1');
  await page.getByLabel(/^Moisture \(%\)/).fill('11.7');
  await page.getByLabel(/^Broken grains/).fill('2');
  await page.getByLabel(/^Foreign matter/).fill('0.2');
  const tested = await reviewSave(new RegExp(`${code}-KNM-[A-Z0-9]+-QC-0001`));
  await signOut(page);

  await firstSignIn({ phone: people.qr.phone }, people.qr.temp, `Mohar-${u}`);
  await page.getByTestId('slot-qr_activation').click();
  await verify(tested);
  await page.getByRole('button', { name: 'Activate and seal' }).click();
  const qr = (await page.getByTestId('sealed').textContent())!.match(/GV-[0-9A-F]{12}/)![0];
  await signOut(page);

  // 5. anyone with the QR: the public page of the new client's first lot
  await page.goto(`/verify/${qr}`);
  await expect(page.locator('main, body').first()).toContainText(`Ramkali ${u}`);
  await expect(page.locator('main, body').first()).toContainText('Nichlaul');
  await expect(page.locator('body')).not.toContainText(`94${u}41`);              // never the farmer's phone
});

// 5 Oct 2026: operators can sign in with email + password, so a pilot works without enabling the Twilio-gated Phone
// provider. The number stays optional. Here an admin makes an operator with an email (no number) and the operator
// signs in on the Email tab. Before this change the create-user function refused an operator without a phone.
test('An operator can be created with an email and sign in on the Email tab (no phone number, no SMS)', async ({ page }) => {
  test.setTimeout(120_000);
  const u = uniq();
  const mail = `operator${u}@grainveda.in`;
  const temp = async () => (await page.getByTestId('temp-password').textContent())!.match(/: (Gv-[A-Za-z0-9_-]+) —/)![1];

  await signIn(page, USERS.admin);
  await page.goto('/users');
  await page.getByLabel('Role').selectOption('operator');
  await page.getByLabel('Name').fill(`Email Operator ${u}`);
  await page.getByLabel('Email').fill(mail);                       // the operator's email; the Mobile box is left empty
  await page.getByLabel('Client').selectOption({ label: 'GrainVeda (Prasaadam trade scope)' });
  await page.getByRole('button', { name: 'Create' }).click();
  await expect(page.getByTestId('temp-password')).toContainText(mail);
  const tempPw = await temp();
  await expect(page.getByTestId('user-row').filter({ hasText: `Email Operator ${u}` })).toContainText('linked');
  await signOut(page);

  // sign in on the Email tab with the temporary password, then choose an own one
  await page.goto('/'); await page.evaluate(() => localStorage.clear()); await page.goto('/');
  await page.getByRole('tab', { name: /Email/ }).click();
  await page.getByLabel('Email').fill(mail);
  await page.getByLabel('Password').fill(tempPw);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByTestId('must-change')).toBeVisible();
  await page.getByLabel('New password', { exact: true }).fill(`Khet-${u}`);
  await page.getByLabel('New password again').fill(`Khet-${u}`);
  await page.getByRole('button', { name: 'Set password' }).click();
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
  await page.goto('/account');
  await expect(page.getByTestId('account-me')).toContainText('Operator');
  await signOut(page);
});
