// Setting a client up by hand, through the screens only. Three faults Veda reported from staging were all in this
// path (FIX_LIST 32, 33, and "Phone logins are disabled"); demo data from a seed never walks it.
//
// Since the identity layer (migrations 31–33, 6 October 2026) the path has two separate acts:
//   HR        adds a person ONCE, as an identity with a sign-in. Gives no access.
//   a manager gives that person an assignment: a scope and stages, a client's account, or a state.
// The old "Users" page (one form: role + client + state + login) is gone; `/users` now lands on People & access.
import { test, expect } from '@playwright/test';
import { signIn, signInWith, signOut, setOwnPassword, freshEmail, freshPhone, addJoiner, markJoined, todayIST, fillLabReport, USERS, fillFarmerPlace, fillWhere, pickFarmer,
  fakePan, onboardClient, approveClient } from './helpers';

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

  const u = uniq(); const mail = freshEmail('nobody'); const phone = freshPhone();
  await page.getByLabel('Full name').fill(`Nobody ${u}`);
  await page.getByLabel('Join date').fill(todayIST());
  await page.getByLabel('Personal email').fill(mail);
  await page.locator('#j-phone').fill(phone);
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
  await page.locator('#j-phone').fill(phone);
  await page.getByRole('button', { name: 'Save and create sign-in' }).click();
  await expect(page.getByTestId('temp-password')).toContainText(mail);
  await expect(page.getByTestId('joiner-made')).toContainText(/invite sent · awaiting first sign-in/i, { useInnerText: true });   // (a badge: shown in capitals)
  await signOut(page);
});

// FIX_LIST fault 33 (5 October 2026, reported by Veda from the deployed app): Admin → Clients → Create answered "Not
// allowed for your role or stage." for the admin. No client had ever been created from the screen: the demo clients
// come from a seed. The read rule on clients could not see a row in the statement that inserts it (migration 30).
// Since migration 34 (Veda, 10 October 2026) the State Manager onboards clients, in a state they hold; the admin reads.
// Since migration 64 (Phase 2, the registry) the State Manager types the PAN first; the code is made by the system; a PAN
// already registered gives "Already registered with GrainVeda" and no second client (e2e/phase36 has the gates).
test('A State Manager adds a client from the screen, PAN first, in the own state; the admin is offered no form', async ({ page }) => {
  test.setTimeout(120_000);
  const u = uniq(); const name = `Terai Exports ${u}`; const pan = fakePan();
  await signIn(page, USERS.admin);
  await page.goto('/clients');
  await expect(page.getByTestId('clients-readonly')).toBeVisible();
  await expect(page.getByTestId('client-new')).toHaveCount(0);
  // the old one-form "Users" page is gone: its address lands on People & access, which creates nobody
  await page.goto('/users');
  await expect(page.getByRole('heading', { name: /People & access/ })).toBeVisible();
  await expect(page.getByLabel('Role', { exact: true })).toHaveCount(0);
  await signOut(page);

  await signIn(page, USERS.sm);
  await page.goto('/clients');
  await page.getByTestId('client-new').click();
  await page.getByLabel('Entity type').selectOption('company');
  await page.getByLabel(/^PAN/).fill(pan.toLowerCase());                         // typed small: stored in capitals
  await page.getByLabel(/^Legal name/).fill(name);
  await page.getByTestId('pan-check').click();
  const g1 = page.getByTestId('gate1-form');
  await expect(g1.getByLabel('State it starts in').locator('option', { hasText: 'Assam' })).toHaveCount(0);   // only the states the manager holds
  await g1.getByLabel('State it starts in').selectOption({ label: 'Uttar Pradesh' });
  await g1.getByLabel('Name', { exact: true }).fill('Ravi Shukla');
  await g1.getByLabel('Designation').fill('Director');
  await g1.getByLabel('Phone').fill('9000012345');
  await g1.getByLabel('Email').fill('ravi@terai.test');
  await g1.getByTestId('crops-of-interest').getByLabel('Kalanamak rice').check();
  await g1.getByTestId('client-create').click();
  await expect.soft(page.getByText('Not allowed for your role or stage.')).toHaveCount(0);
  await expect(page.getByTestId('client-page')).toBeVisible();
  await expect(page.getByRole('heading', { level: 1 })).toContainText(name);
  await expect(page.getByTestId('client-state-card').filter({ hasText: 'Uttar Pradesh' })).toHaveAttribute('data-status', 'prospect');
  const code = (await page.getByRole('heading', { level: 1 }).locator('.mono').textContent())!.trim();
  expect(code).toMatch(/^[A-Z]{3,5}$/);
  // the same PAN again: "Already registered with GrainVeda", and nothing is added twice
  await page.goto('/clients/new');
  await page.getByLabel('Entity type').selectOption('company');
  await page.getByLabel(/^PAN/).fill(pan);
  await page.getByLabel(/^Legal name/).fill(`${name} again`);
  await page.getByTestId('pan-check').click();
  await expect(page.getByTestId('already-registered')).toContainText('Already registered with GrainVeda');
  await expect(page.getByTestId('shared-identity')).toContainText(`${pan.slice(0, 5)}****${pan.slice(9)}`);
  await expect(page.getByTestId('gate1-form')).toHaveCount(0);
  await page.goto('/clients');
  await expect(page.getByTestId('client-row').filter({ hasText: code })).toHaveCount(1);
  await signOut(page);
});

// Everything before this test ran on demo data that a seed puts in place: the client, its scopes and its people were
// never made from the screens. This is that path from nothing, through the screens only, in the order the identity
// order Veda set (10 October 2026): the State Manager makes the client; HR adds four people (and gives them nothing);
// the State Manager gives one of them the client's account; that manager opens a scope and gives the other three their
// stages; a farmer verified by that manager and then by the State Manager; the first lot to its public page.
test('A brand-new client from nothing: HR adds the people, managers give them access, the first lot is sealed', async ({ page }) => {
  test.setTimeout(420_000);
  const u = uniq(); const client = `Naya Client ${u}`; let code = '';
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

  // 1. the State Manager: the client, through its three gates (migration 64; the screens are e2e/phase36's), and the
  //    admin's approval of its first Active
  await signIn(page, USERS.sm);
  const reg = await onboardClient(page, { name: client });
  code = reg.code;
  await page.goto('/clients');
  await expect(page.getByTestId('client-row').filter({ hasText: client })).toContainText('waiting for the admin');
  await signOut(page);
  await signIn(page, USERS.admin);
  await approveClient(page, reg.id);
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
    await markJoined(page);                                 // "Mark as joined": the person is an employee now
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
  await expect(page.getByRole('tab', { name: 'A scope' })).toHaveCount(0);       // migration 44: "A client's account" is all he gives
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
  await expect(page.getByTestId('wz-state')).toContainText('Uttar Pradesh');                 // migration 41: the client's own state, not a choice
  await page.getByRole('button', { name: 'Next' }).click();
  await page.getByLabel('Crop').selectOption({ label: 'Kalanamak rice' });
  await page.getByRole('button', { name: 'Next' }).click();
  await expect(page.getByTestId('chain-preview')).toContainText('Procurement (farm-gate) → Quality Control → QR Activation (seal)');
  await page.getByRole('button', { name: /Save draft/ }).click();
  await expect(page.getByRole('heading', { name: new RegExp(`Maharajganj ${u}`) })).toContainText('Draft');
  // migration 53 (C5): a new scope asks the sample drawn first (from a lab on the state's list); this test is the new client's first lot
  // with the lab record typed as before, and e2e/phase25 tests the sample path. Saved at once, from the scope's page.
  await page.getByTestId('ss-details').uncheck();
  await expect(page.getByTestId('ss-details')).toBeEnabled();
  await expect(page.getByTestId('roster-gaps')).toContainText('3 stage(s) with nobody');
  await expect(page.getByRole('button', { name: '+ new person' })).toHaveCount(0);                 // a manager creates nobody
  for (const [label, k] of [['Assign Procurement (farm-gate)', 'procurement'], ['Assign Quality Control', 'qc'], ['Assign QR Activation (seal)', 'qr']] as const) {
    await page.getByTestId('roster-find').fill(who[k].name);         // the pool lists the first 100 by name; a search finds anyone
    await expect(page.getByLabel(label).locator('option', { hasText: who[k].name })).toHaveCount(1);
    await page.getByLabel(label).selectOption({ label: who[k].name });
    await expect(page.getByTestId('slots').getByRole('link', { name: who[k].name })).toBeVisible();
  }
  await expect(page.getByTestId('roster-covered')).toBeVisible();
  page.once('dialog', (d) => d.accept());
  await page.getByRole('button', { name: 'Activate scope' }).click();
  await expect(page.getByRole('heading', { name: new RegExp(`Maharajganj ${u}`) })).toContainText('Active');

  // 6. the manager registers a farmer and verifies it (step 1); the State Manager verifies its location (step 2); the
  //    Farmer ID carries the new client's code
  await page.goto('/farmers/new');
  await page.getByLabel('Name *', { exact: true }).fill(`Ramkali ${u}`);
  await page.getByLabel('Father / husband name *').fill('Shri Bhola');
  await fillFarmerPlace(page, 'Maharajganj', 'Nichlaul');
  await page.getByLabel('Mobile number *').fill(`94${u}41`);
  await page.getByLabel('Land (acres) *').fill('2');
  await page.getByTestId('farmer-gi-land').fill('1');                       // migration 43: needed before the Farmer ID
  await page.getByTestId('farmer-save-verify').click();
  await expect(page.getByRole('heading', { name: 'Farmers' })).toBeVisible();
  await signOut(page);
  await signIn(page, USERS.sm);
  await page.goto('/farmers');
  await page.getByLabel('Client').selectOption({ label: client });
  await page.getByRole('tab', { name: 'Ready to verify' }).click();
  await expect(page.getByTestId('farmer-row').filter({ hasText: `Ramkali ${u}` })).toContainText(`Verified by Naya Manager ${u}`);
  await page.getByTestId('farmer-row').filter({ hasText: `Ramkali ${u}` }).getByTestId('farmer-step2').click();
  await page.getByRole('tab', { name: 'Active', exact: true }).click();
  await expect(page.getByTestId('farmer-row').filter({ hasText: `Ramkali ${u}` })).toContainText(new RegExp(`${code}-F-0001`));
  await signOut(page);

  // 7. the three people, each with an own password, each holding one stage of one scope: buy, test, seal
  await signInWith(page, who.procurement.email, `Kharid-${u}`);
  await page.getByTestId('slot-procurement').click();
  await pickFarmer(page, new RegExp(`Ramkali ${u}`));
  await page.getByLabel(/Gross weight/).fill('120');
  await page.getByLabel(/^Bags/).fill('2');
  await page.getByLabel(/Tare per bag/).fill('1');
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('11.7');
  await fillWhere(page);                                                       // migration 52: a new scope asks where, GPS, who
  const lot = await reviewSave(new RegExp(`${code}-KNM-[A-Z0-9]+-(?:[A-Z]{2,4}-)?P-0001`));
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
  await fillLabReport(page, u);                                      // migration 50 (C5): a new scope asks for the lab report
  const tested = await reviewSave(new RegExp(`${code}-KNM-[A-Z0-9]+-(?:[A-Z]{2,4}-)?QC-0001`));
  await signOut(page);

  await signInWith(page, who.qr.email, made.qr.temp);
  await setOwnPassword(page, `Mohar-${u}`);
  await page.getByTestId('slot-qr_activation').click();
  await verify(tested);
  await page.getByTestId('release-read').check();   // migration 50 (G9): the summary is read first
  await page.getByRole('button', { name: 'Activate and seal' }).click();
  const qr = (await page.getByTestId('sealed').textContent())!.match(/GV-[0-9A-F]{12}/)![0];
  await signOut(page);

  // 8. anyone with the QR: the public page of the new client's first lot
  await page.goto(`/verify/${qr}`);
  // migration 50 (Part D): the village and the district, never the farmer's name
  await expect(page.locator('main, body').first()).not.toContainText(`Ramkali ${u}`);
  await expect(page.locator('main, body').first()).toContainText('Nichlaul');
  await expect(page.locator('body')).not.toContainText(`94${u}41`);              // never the farmer's phone
});
