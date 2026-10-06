// Setting a client up by hand, through the screens only. Three faults Veda reported from staging were all in this
// path (FIX_LIST 32, 33, and "Phone logins are disabled"); demo data from a seed never walks it.
//
// Since the identity layer (migrations 31–33, 6 October 2026) the path has two separate acts:
//   HR        adds a person ONCE, as an identity with a sign-in. Gives no access.
//   a manager gives that person an assignment: a scope and stages, a client's account, or a state.
// The old "Users" page (one form: role + client + state + login) is gone; `/users` now lands on People & access.
import { test, expect } from '@playwright/test';
import { signIn, signInWith, signOut, setOwnPassword, freshEmail, addJoiner, todayIST, USERS } from './helpers';

const uniq = () => String(Date.now()).slice(-6);

test.use({ viewport: { width: 1366, height: 768 }, isMobile: false, hasTouch: false, deviceScaleFactor: 1 });

// FIX_LIST fault 32 (4 October 2026): on staging "New user" failed every time with "Login created but not linked; both
// removed". The database was ahead of the server functions. Here the browser is given the answers staging gave that
// day, and the page that needs the function has to say what is wrong with the server, before and after the form is used.
test('Server functions left behind: the Add joiner page says so, and a failed save names the server, not the person', async ({ page }) => {
  await page.route('**/functions/v1/create-user', (route) => {
    const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'POST, OPTIONS' };
    const m = route.request().method();
    if (m === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
    if (m === 'POST') return route.fulfill({ status: 500, headers: cors, contentType: 'application/json', body: JSON.stringify({ error: 'login created but not linked; both removed' }) });
    return route.fulfill({ status: 405, headers: cors, contentType: 'application/json', body: JSON.stringify({ error: 'POST only' }) });
  });
  // reset-password not deployed: the gateway's 404 carries no CORS headers, so the browser reports a failed request.
  await page.route('**/functions/v1/reset-password', (route) => route.abort('failed'));

  await signIn(page, USERS.hr);
  await page.goto('/hr/joiners/new');
  const warning = page.getByTestId('functions-warning');
  // (soft: the form below must be reached also by an app that has no warning, so that the fault itself is shown)
  await expect.soft(warning).toBeVisible();
  await expect.soft(warning).toContainText('"create-user" is older than this app', { useInnerText: true, timeout: 3000 });
  await expect.soft(warning).toContainText('run-sheet step A6', { useInnerText: true, timeout: 3000 });

  const u = uniq(); const mail = freshEmail('nobody');
  await page.getByLabel('Full name').fill(`Nobody ${u}`);
  await page.getByLabel('Join date').fill(todayIST());
  await page.getByLabel('Personal email').fill(mail);
  await page.getByRole('button', { name: 'Save and create sign-in' }).click();
  const error = page.locator('form').getByRole('alert');
  await expect(error).toBeVisible();
  await expect.soft(error).toContainText('The server is not up to date with this app', { useInnerText: true, timeout: 3000 });
  await expect.soft(error).toContainText('Nothing is wrong with what you entered', { useInnerText: true, timeout: 3000 });
  await expect(error).toContainText('ogin created but not linked; both removed', { useInnerText: true });   // the function's own words are kept
  await expect(page.getByTestId('temp-password')).toHaveCount(0);

  // Reset password, with the function missing: not "No connection"
  await page.goto('/people/00000000-0000-4000-8000-000000000306');
  page.once('dialog', (d) => d.accept());
  await page.getByTestId('profile-actions').getByRole('button', { name: 'Reset password' }).click();
  await expect(page.getByRole('alert').filter({ hasText: 'reset-password' })).toContainText('A part of the server is not installed', { useInnerText: true });
  await expect.soft(page.getByText('No connection to the server')).toHaveCount(0);
  await expect(page.getByTestId('temp-password')).toHaveCount(0);

  // The real functions of this repository: no warning, and the same form works.
  await page.unroute('**/functions/v1/create-user');
  await page.unroute('**/functions/v1/reset-password');
  const asked = page.waitForResponse((r) => r.url().endsWith('/functions/v1/create-user') && r.request().method() === 'GET');
  await page.goto('/hr/joiners/new');
  expect((await asked).headers()['x-grainveda-function']).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  await expect(page.getByLabel('Full name')).toBeVisible();
  await expect(warning).toHaveCount(0);
  await page.getByLabel('Full name').fill(`Somebody ${u}`);
  await page.getByLabel('Join date').fill(todayIST());
  await page.getByLabel('Personal email').fill(mail);
  await page.getByRole('button', { name: 'Save and create sign-in' }).click();
  await expect(page.getByTestId('temp-password')).toContainText(mail);
  await expect(page.getByTestId('joiner-made')).toContainText(/invite sent · awaiting first sign-in/i, { useInnerText: true });   // (a badge: shown in capitals)
  await signOut(page);
});

// FIX_LIST fault 33 (5 October 2026, reported by Veda from the deployed app): Admin → Clients → Create answered "Not
// allowed for your role or stage." for the admin. No client had ever been created from the screen: the demo clients
// come from a seed. The read rule on clients could not see a row in the statement that inserts it (migration 30).
test('An admin adds a client from the screen; a State Manager adds one in the own state', async ({ page }) => {
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
  // the old one-form "Users" page is gone: its address lands on People & access, which creates nobody
  await page.goto('/users');
  await expect(page.getByRole('heading', { name: /People & access/ })).toBeVisible();
  await expect(page.getByLabel('Role', { exact: true })).toHaveCount(0);
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
// never made from the screens. This is that path from nothing, through the screens only, in the order the identity
// layer prescribes: the admin makes the client; HR adds four people (and gives them nothing); the State Manager gives
// one of them the client's account; that manager opens a scope and gives the other three their stages; a farmer; the
// first lot to its public page.
test('A brand-new client from nothing: HR adds the people, managers give them access, the first lot is sealed', async ({ page }) => {
  test.setTimeout(420_000);
  const u = uniq(); const code = `N${u.slice(-4)}`; const client = `Naya Client ${u}`;
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

  // 1. the admin: the client
  await signIn(page, USERS.admin);
  await page.goto('/clients');
  await page.locator('form').getByLabel('Name').fill(client);
  await page.locator('form').getByLabel('Code').fill(code);
  await page.locator('form').getByLabel('State').selectOption({ label: 'Uttar Pradesh' });
  await page.locator('form').getByRole('button', { name: 'Create' }).click();
  await expect(page.getByRole('row').filter({ hasText: client })).toBeVisible();
  await signOut(page);

  // 2. HR: four people, once each, as identities. The form has no field that could give access to anything.
  await signIn(page, USERS.hr);
  await page.goto('/hr/joiners/new');
  await expect(page.getByLabel('Full name')).toBeVisible();
  for (const label of ['Client', 'Scope', 'State', 'Role', 'Stages']) await expect(page.getByLabel(label, { exact: true })).toHaveCount(0);
  const who = {
    manager: { name: `Naya Manager ${u}`, email: freshEmail('manager'), type: 'full_time', title: 'Client Lead' },
    procurement: { name: `Naya Kharid ${u}`, email: freshEmail('kharid'), type: 'contract', title: 'Field Associate' },
    qc: { name: `Naya Jaanch ${u}`, email: freshEmail('jaanch'), type: 'contract', title: 'Field Associate' },
    qr: { name: `Naya Mohar ${u}`, email: freshEmail('mohar'), type: 'contract', title: 'Field Associate' },
  };
  const made: Record<string, { id: string; temp: string }> = {};
  for (const [k, p] of Object.entries(who)) {
    made[k] = await addJoiner(page, p);
    await page.getByTestId('activate').click();                                 // "Mark as joined": the person is an employee now
    await expect(page.getByTestId('activate')).toHaveCount(0);
    await expect(page.locator('main p.row').first()).toContainText('Active');
  }
  // HR sees the people it made and has no way to assign them
  await page.goto(`/people/${made.procurement.id}`);
  await expect(page.getByTestId('no-assignments')).toBeVisible();
  await expect(page.getByTestId('give-assignment')).toHaveCount(0);
  await signOut(page);

  // 3. an employee nobody has assigned: signs in, chooses a password, and is told calmly to wait
  await signInWith(page, who.procurement.email, made.procurement.temp);
  await setOwnPassword(page, `Kharid-${u}`);
  await expect(page.getByTestId('no-assignment')).toContainText('A manager will assign you to your work soon', { useInnerText: true });
  await expect(page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Farmers' })).toHaveCount(0);
  await expect(page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: /Scopes/ })).toHaveCount(0);
  await signOut(page);

  // 4. the State Manager gives one of them the new client's account (the client is homed in the manager's state)
  await signIn(page, USERS.sm);
  await page.goto(`/people/${made.manager.id}`);
  await page.getByTestId('give-assignment').click();
  await page.getByRole('tab', { name: "A client's account" }).click();
  await page.getByLabel('Client', { exact: true }).selectOption({ label: client });
  await page.getByTestId('assign-save').click();
  await expect(page.getByTestId('assignment')).toContainText(client);
  await expect(page.getByTestId('assignment')).toContainText('Client account');
  await signOut(page);

  // 5. that manager: own password, a scope with the shortest chain, a person from the pool at each stage, activate
  await signInWith(page, who.manager.email, made.manager.temp);
  await setOwnPassword(page, `Manager-${u}`);
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
  await expect(page.getByTestId('tb-context')).toHaveText(client);
  await page.goto('/scopes/new');
  await page.getByLabel(/Geography/).fill(`Maharajganj ${u}`);
  await expect(page.locator('#wz-state option:checked')).toHaveText("Uttar Pradesh (client's home state)");
  await page.getByRole('button', { name: 'Next' }).click();
  await page.getByLabel('Crop').selectOption({ label: 'Kalanamak rice' });
  await page.getByRole('button', { name: 'Next' }).click();
  await expect(page.getByTestId('chain-preview')).toContainText('Procurement (farm-gate) → Quality Control → QR Activation (seal)');
  await page.getByRole('button', { name: /Save draft/ }).click();
  await expect(page.getByRole('heading', { name: new RegExp(`Maharajganj ${u}`) })).toContainText('Draft');
  await expect(page.getByTestId('roster-gaps')).toContainText('3 stage(s) with nobody');
  await expect(page.getByRole('button', { name: '+ new person' })).toHaveCount(0);                 // a manager creates nobody
  for (const [label, k] of [['Assign Procurement (farm-gate)', 'procurement'], ['Assign Quality Control', 'qc'], ['Assign QR Activation (seal)', 'qr']] as const) {
    await page.getByLabel(label).selectOption({ label: who[k].name });
    await expect(page.getByTestId('slots').getByRole('link', { name: who[k].name })).toBeVisible();
  }
  await expect(page.getByTestId('roster-covered')).toBeVisible();
  page.once('dialog', (d) => d.accept());
  await page.getByRole('button', { name: 'Activate scope' }).click();
  await expect(page.getByRole('heading', { name: new RegExp(`Maharajganj ${u}`) })).toContainText('Active');

  // 6. the manager registers a farmer; the State Manager verifies; the Farmer ID carries the new client's code
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

  // 7. the three people, each with an own password, each holding one stage of one scope: buy, test, seal
  await signInWith(page, who.procurement.email, `Kharid-${u}`);
  await page.getByTestId('slot-procurement').click();
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill('Ramkali');
  await page.getByRole('button', { name: new RegExp(`Ramkali ${u}`) }).click();
  await page.getByLabel(/Gross weight/).fill('120');
  await page.getByLabel(/^Bags/).fill('2');
  await page.getByLabel(/Tare per bag/).fill('1');
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('11.7');
  const lot = await reviewSave(new RegExp(`${code}-KNM-[A-Z0-9]+-P-0001`));
  await signOut(page);

  await signInWith(page, who.qc.email, made.qc.temp);
  await setOwnPassword(page, `Jaanch-${u}`);
  await page.getByTestId('slot-qc').click();
  await verify(lot);
  await page.getByRole('button', { name: /Record Quality Control/ }).click();
  await page.getByLabel(/Sample drawn/).fill('1');
  await page.getByLabel(/^Moisture \(%\)/).fill('11.7');
  await page.getByLabel(/^Broken grains/).fill('2');
  await page.getByLabel(/^Foreign matter/).fill('0.2');
  const tested = await reviewSave(new RegExp(`${code}-KNM-[A-Z0-9]+-QC-0001`));
  await signOut(page);

  await signInWith(page, who.qr.email, made.qr.temp);
  await setOwnPassword(page, `Mohar-${u}`);
  await page.getByTestId('slot-qr_activation').click();
  await verify(tested);
  await page.getByRole('button', { name: 'Activate and seal' }).click();
  const qr = (await page.getByTestId('sealed').textContent())!.match(/GV-[0-9A-F]{12}/)![0];
  await signOut(page);

  // 8. anyone with the QR: the public page of the new client's first lot
  await page.goto(`/verify/${qr}`);
  await expect(page.locator('main, body').first()).toContainText(`Ramkali ${u}`);
  await expect(page.locator('main, body').first()).toContainText('Nichlaul');
  await expect(page.locator('body')).not.toContainText(`94${u}41`);              // never the farmer's phone
});
