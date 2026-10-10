// The identity and authorization layer (migrations 31–33, 6 October 2026), through the screens.
//   Onboarding   HR creates a person once, as an identity. Grants no access.
//   Assignment   a manager attaches that person to a scope (role, stages), a client's account, or a state.
// What is held here: the joiner's own path on a phone; identity numbers kept as last four only; the pool and its two
// lenses; the wall between clients inside the directory; who may assign; warnings that do not block; assignments that
// only move forward; suspend / offboard / re-hire; the two seats; the audit log; the once-a-day sign-in code.
// The same rules are tested at the database (tests/23–27) and over the API (tests/remote_create_user.mjs,
// tests/remote_rls.mjs); this file is the person's side of them.
import { test, expect, type Page } from '@playwright/test';
import { signIn, signInOnly, signInWith, signOut, setOwnPassword, freshEmail, addJoiner, todayIST, expectNoSideScroll, apiAs, localStack,
  freshPan, freshAadhaar, freshAccount,
  USERS, PEOPLE, SCOPES } from './helpers';
import { hi } from '../src/lib/i18n.hi';

const uniq = () => String(Date.now()).slice(-6);
const DESK = { viewport: { width: 1366, height: 768 }, isMobile: false, hasTouch: false, deviceScaleFactor: 1 } as const;
const NAGAON = '00000000-0000-4000-8000-000000000407';      // the same client's scope in Assam (seed 06): draft, nobody on it
const ASSAM = '00000000-0000-4000-8000-000000000002';
const UP = '00000000-0000-4000-8000-000000000001';
const ID = (n: number) => `00000000-0000-4000-8000-000000000${n}`;
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64');
const menu = (page: Page) => page.getByRole('navigation', { name: 'Main' });
/** A row of the directory, by the person's name (a name can also be someone's job title or buddy). */
const person = (page: Page, name: string) => page.getByTestId('person-row').filter({ has: page.getByRole('link', { name, exact: true }) });
const status = (page: Page) => page.locator('main .band .badge, main p.row .badge').first();
const leaveNoAccess = async (page: Page) => {
  await expect(page.getByTestId('no-access')).toContainText('This sign-in opens nothing', { useInnerText: true });
  await expect(menu(page)).toHaveCount(0);
  await page.getByTestId('no-access').getByRole('button', { name: 'Sign out' }).click();
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
};

// ── the joiner, on a phone ────────────────────────────────────────────────────────────────────────────────────────
test('A joiner from invite to first day, on a phone: own password with the sign-in locked, steps in any order, numbers only to the id-numbers function, then HR\'s turn', async ({ page, browser }) => {
  test.setTimeout(300_000);
  const u = uniq(); const name = `Kiran Test ${u}`; const mail = freshEmail('kiran');
  const office = await browser.newContext(DESK); const hr = await office.newPage();
  try {
    // HR at a desk: an intern, so the statutory step is left out
    await signIn(hr, USERS.hr);
    await hr.goto('/hr/joiners/new');
    await hr.getByLabel('Employment type').selectOption('intern');
    await expect(hr.getByTestId('statutory-hint')).toBeVisible();
    const made = await addJoiner(hr, { name, email: mail, type: 'intern', title: 'Field Intern' });
    expect(made.said).toContain('The statutory task (PF & gratuity) was left out');
    expect(made.said).toMatch(/invite sent · awaiting first sign-in/i);            // (a badge: shown in capitals)
    await expect(hr.getByTestId('joiner-tasks').locator('tbody tr')).toHaveCount(8);
    await expect(hr.getByTestId('task-pf_gratuity')).toHaveCount(0);
    await expect(status(hr)).toHaveText('Invited');

    // the joiner's phone: the sign-in is the address HR typed and cannot be changed; the password is their own
    await signInWith(page, mail, made.temp);
    await expect(page.getByTestId('locked-sign-in')).toHaveValue(mail);
    await expect(page.getByTestId('locked-sign-in')).toBeDisabled();
    await expectNoSideScroll(page);
    await setOwnPassword(page, `Kiran-${u}`);
    await expect(page.getByTestId('joiner-home')).toContainText('Welcome, Kiran', { useInnerText: true });
    await expect(page.getByTestId('join-countdown')).toHaveText(/^Your joining date: \d{1,2} [A-Z][a-z]{2} \d{4}$/);   // B3: not "joined", while joining
    await expectNoSideScroll(page);
    // not an employee yet: the menu has the checklist and nothing of the work
    await expect(menu(page).getByRole('link', { name: 'My joining checklist' })).toBeVisible();
    for (const item of ['Farmers', 'Season Scopes', 'People & access', 'HR · Joiners']) await expect(menu(page).getByRole('link', { name: item })).toHaveCount(0);

    await page.getByRole('link', { name: 'Open my checklist' }).click();
    await expect(page.getByTestId('checklist-progress')).toHaveText('0 of 8 done');                  // with Personal details (migration 37)
    for (const code of ['offer_nda', 'identity', 'personal', 'bank']) await expect(page.getByTestId(`row-${code}`)).toHaveAttribute('data-state', 'open');
    await expect(page.getByTestId('row-countersign')).toHaveAttribute('data-state', 'ours');
    await expect(page.getByTestId('row-countersign')).toContainText("We're on it", { useInnerText: true });
    await expect(page.getByTestId('start-task')).toHaveCount(4);                                    // no order unless the template sets one (B2)
    await expectNoSideScroll(page);

    // every request the phone makes from here on, with its body: a full number may go to the id-numbers function only
    const sent: { url: string; body: string }[] = [];
    page.on('request', (r) => { if (r.method() !== 'GET') sent.push({ url: r.url(), body: r.postData() ?? '' }); });
    const PAN = freshPan(), AAD = freshAadhaar(), ACCT = freshAccount();
    const spaced = `${AAD.slice(0, 4)} ${AAD.slice(4, 8)} ${AAD.slice(8)}`;

    // bank first: nothing makes it wait for identity
    await page.getByTestId('row-bank').getByTestId('start-task').click();
    await page.locator('#t-bank').fill('State Bank of India');
    await page.locator('#t-ifsc').fill('sbin0001');
    await expect(page.getByTestId('task-problem')).toContainText('IFSC is 11 characters');
    await page.locator('#t-ifsc').fill('sbin0001234');
    await page.locator('#t-account').fill(ACCT);
    await page.getByTestId('task-done').click();
    await expect(page.getByTestId('checklist-progress')).toHaveText('1 of 8 done');

    // read and sign
    await page.getByTestId('row-offer_nda').getByTestId('start-task').click();
    await expect(page.getByTestId('task-done')).toBeDisabled();
    await expect(page.getByTestId('task-problem')).toHaveText('Tick the box to say you have read and signed.');
    await page.getByLabel('I have read and signed the offer letter and the NDA').check();
    await page.getByTestId('task-done').click();
    await expect(page.getByTestId('checklist-progress')).toHaveText('2 of 8 done');

    // identity: checked in full on the phone, sent once to the id-numbers function, the masked Aadhaar only
    await page.getByTestId('row-identity').getByTestId('start-task').click();
    await expect(page.getByTestId('task-problem')).toHaveText('Give your PAN or your Aadhaar number.');
    await page.locator('#t-pan').fill(PAN.slice(0, 9).toLowerCase());
    await expect(page.getByTestId('task-problem')).toContainText('does not look like a PAN');
    await page.locator('#t-pan').fill(PAN.toLowerCase());
    await expect(page.locator('#t-pan')).toHaveValue(PAN);
    await page.locator('#t-aadhaar').fill(spaced.slice(0, -1) + String((Number(AAD[11]) + 1) % 10));   // twelve digits, wrong check digit
    await expect(page.getByTestId('task-problem')).toHaveText("This doesn't match an Aadhaar number (the last digit is a check digit). Please copy it again from your card.");
    await page.locator('#t-aadhaar').fill(spaced);
    await expect(page.getByTestId('task-problem')).toHaveCount(0);
    await expect(page.getByTestId('masked-howto')).toContainText('myaadhaar.uidai.gov.in');
    await expect(page.getByText('Masked Aadhaar (only the last 4 digits visible)')).toBeVisible();
    await expect(page.locator('main')).not.toContainText('PAN card photo');
    await page.locator('#t-file').setInputFiles({ name: 'masked aadhaar.png', mimeType: 'image/png', buffer: PNG });
    await expect(page.getByTestId('t-file-name')).toHaveText('masked aadhaar.png');
    await expectNoSideScroll(page);
    await page.getByTestId('task-done').click();
    await expect(page.getByTestId('checklist-progress')).toHaveText('3 of 8 done');

    // personal details (A3)
    await page.getByTestId('row-personal').getByTestId('start-task').click();
    await page.locator('#p-dob').fill('2001-04-12');
    await page.locator('#p-rn').fill('Ramesh Kumar');
    await page.locator('#p-pa').fill('House 4, Village Lakhimpur, UP 262701');
    await page.getByTestId('same-address').check();
    await page.locator('#p-en').fill('Sunita Devi');
    await page.locator('#p-er').fill('mother');
    await page.locator('#p-ep').fill('98765 43210');
    await expectNoSideScroll(page);
    await page.getByTestId('task-done').click();
    await expect(page.getByTestId('checklist-progress')).toHaveText('4 of 8 done');
    await expect(page.getByTestId('start-task')).toHaveCount(0);                                    // the rest is HR's and IT's

    // where the numbers went: the id-numbers function, and nowhere else
    const toFn = sent.filter((r) => r.url.includes('/functions/v1/id-numbers'));
    expect(toFn.map((r) => JSON.parse(r.body).kind).sort()).toEqual(['aadhaar', 'bank', 'pan']);
    for (const r of sent.filter((x) => !x.url.includes('/functions/v1/id-numbers'))) {
      for (const n of [PAN, AAD, spaced, ACCT]) expect(`${r.url} ${r.body}`, `a full number went to ${r.url}`).not.toContain(n);
    }
    expect(sent.some((r) => r.url.includes('rpc/complete_task'))).toBe(true);
    // what the database holds, read with the joiner's own token
    const me = await apiAs(page);
    const docs = await me.rows('employee_docs');
    expect(docs).toHaveLength(1);
    expect(docs[0].pan_last4).toBe(PAN.slice(-4));
    expect(docs[0].aadhaar_last4).toBe(AAD.slice(-4));
    expect(docs[0].bank_last4).toBe(ACCT.slice(-4));
    for (const n of [PAN, AAD, ACCT]) expect(JSON.stringify(docs)).not.toContain(n);
    const files = await me.rows('employee_files');
    expect(files).toHaveLength(1);
    expect(files[0].kind).toBe('aadhaar_masked');
    const path = String(files[0].storage_path);
    expect((await me.signedUrlIn('hr-docs', path)).ok, 'the joiner can open the stored document again').toBe(false);

    // HR's turn: masked numbers, checked for duplicates, the image to confirm as masked, four steps of its own
    await hr.reload();
    await expect(status(hr)).toHaveText('Joining');
    await expect(hr.getByTestId('masked-docs')).toContainText(`•••• ${PAN.slice(-4)}`);
    await expect(hr.getByTestId('masked-docs')).toContainText(`•••• ${AAD.slice(-4)}`);
    await expect(hr.getByTestId('masked-docs')).toContainText(`State Bank of India · SBIN0001234 · •••• ${ACCT.slice(-4)}`);
    for (const k of ['pan', 'aadhaar', 'bank']) await expect(hr.getByTestId(`checked-${k}`)).toHaveText('checked for duplicates');
    for (const n of [PAN, AAD, ACCT]) await expect(hr.getByTestId('masked-docs')).not.toContainText(n);
    await expect(hr.getByTestId('personal-card')).toContainText('Ramesh Kumar');
    await expect(hr.getByTestId('personal-card')).toContainText('Sunita Devi');
    const img = hr.getByTestId('hr-file').filter({ hasText: 'masked aadhaar.png' });
    await expect(img).toBeVisible();
    expect((await (await apiAs(hr)).signedUrlIn('hr-docs', path)).ok, 'HR can open the stored document').toBe(true);
    await img.getByTestId('masked-yes').click();
    await expect(img).toContainText('masked · checked by');
    await expect(img.getByTestId('masked-yes')).toHaveCount(0);
    await hr.getByTestId('record-pan-seen').click();
    await expect(hr.getByTestId('pan-card-seen')).toContainText('seen by');
    await expect(hr.getByTestId('waiting-on-you')).toContainText('Waiting on you (4)');
    await hr.getByTestId('do-countersign').click();
    await expect(hr.getByTestId('our-countersign')).toHaveCount(0);
    await hr.getByTestId('do-it_setup').click();
    await expect(hr.getByTestId('our-it_setup')).toHaveCount(0);
    await expect(hr.getByTestId('do-buddy')).toBeDisabled();                                        // a buddy has to be named
    await hr.getByTestId('our-buddy').getByLabel('Buddy').selectOption({ label: 'QC Technician' });
    await hr.getByTestId('do-buddy').click();
    await expect(hr.getByTestId('our-buddy')).toHaveCount(0);
    await expect(status(hr)).toHaveText('Joining');                                                 // one step still open
    const goals = hr.getByTestId('our-goals');
    await goals.getByLabel('First 30 days').fill('Learn the farm-gate form');
    await goals.getByLabel('First 60 days').fill('Run a collection day alone');
    await goals.getByLabel('First 90 days').fill('Train the next joiner');
    await hr.getByTestId('do-goals').click();
    await expect(hr.getByTestId('waiting-on-you')).toHaveCount(0);
    await expect(status(hr)).toHaveText('Active');                                                  // the last step done: an employee, without a button
    await expect(hr.getByTestId('activate')).toHaveCount(0);

    // the joiner again: an employee nobody has assigned yet. Calm, and says who to ask.
    await page.goto('/');
    await expect(page.getByTestId('no-assignment')).toContainText("You're all set, Kiran", { useInnerText: true });
    await expect(page.getByTestId('no-assignment')).toContainText('A manager will assign you to your work soon', { useInnerText: true });
    await expectNoSideScroll(page);
    await page.getByRole('link', { name: 'Your first day' }).click();
    await expect(page.getByRole('heading', { level: 1 })).toHaveText('Welcome to GrainVeda, Kiran');
    await expect(page.locator('main').getByText('QC Technician', { exact: true })).toBeVisible();   // the buddy HR named
    await expect(page.getByTestId('day1-work')).toContainText('A manager will assign you to your work soon');
    await expectNoSideScroll(page);
    await page.getByRole('link', { name: 'My 30-60-90 goals' }).click();
    for (const g of ['Learn the farm-gate form', 'Run a collection day alone', 'Train the next joiner']) await expect(page.getByTestId('goals')).toContainText(g, { useInnerText: true });
    await expectNoSideScroll(page);
  } finally { await office.close(); }
});

test('The new screens on a phone and in Hindi: a joiner\'s checklist, the waiting screen, HR\'s pipeline, the directory', async ({ page }) => {
  test.setTimeout(120_000);
  // Meera (seed 06): full-time, joins in five days, the first step done. Nothing is changed here.
  await signIn(page, USERS.meera);
  await expect(page.getByTestId('join-countdown')).toContainText(/You join (in \d+ days|tomorrow)/);   // five days on the day the stack was built
  await page.getByRole('link', { name: 'Open my checklist' }).click();
  await expect(page.getByTestId('checklist-progress')).toHaveText('1 of 9 done');                  // Personal details added to her open checklist (37)
  await expect(page.getByTestId('row-offer_nda')).toHaveAttribute('data-state', 'done');
  await expect(page.getByTestId('row-identity')).toHaveAttribute('data-state', 'open');
  await expect(page.getByTestId('row-personal')).toHaveAttribute('data-state', 'open');
  await expect(page.getByTestId('row-pf_gratuity')).toHaveAttribute('data-state', 'open');         // full-time: the statutory step is there, and not behind identity
  await page.getByLabel('Language').selectOption('hi');
  await expect(page.getByRole('heading', { level: 1 })).toHaveText(hi['mine.welcome'].replace('{name}', 'Meera'));
  await expect(page.getByTestId('checklist-progress')).toHaveText(hi['mine.progress'].replace('{total}', '9').replace('{done}', '1'));
  await expect(page.getByTestId('row-identity')).toContainText(hi['task.identity'], { useInnerText: true });
  await expect(page.getByTestId('row-countersign')).toContainText(hi['mine.we_are_on_it'], { useInnerText: true });
  await expect(menu(page).getByRole('link', { name: hi['nav.onboarding'] })).toBeVisible();
  await expectNoSideScroll(page);
  await page.getByTestId('row-identity').getByTestId('start-task').click();
  await expect(page.getByTestId('task-problem')).toHaveText(hi['mine.need_id']);
  await expect(page.getByTestId('masked-howto')).toHaveText(hi['mine.masked_howto']);
  await expectNoSideScroll(page);
  await page.getByLabel('Language').selectOption('en');
  await signOut(page);

  // Ravi (seed 06): active, nobody has assigned him
  await signIn(page, USERS.ravi);
  await expect(page.getByTestId('no-assignment')).toContainText("You're all set, Ravi", { useInnerText: true });
  await expect(page.getByTestId('no-assignment')).toContainText('ask Prasaadam Client Manager', { useInnerText: true });   // the person he reports to
  await page.getByLabel('Language').selectOption('hi');
  await expect(page.getByTestId('no-assignment')).toContainText(hi['hold.body'], { useInnerText: true });
  await expectNoSideScroll(page);
  await page.getByLabel('Language').selectOption('en');
  await signOut(page);

  // HR on a phone: the pipeline says whose turn it is
  await signIn(page, USERS.hr);
  await expect(page.getByTestId('hr-stats')).toBeVisible();                                         // HR's first screen is the pipeline
  const row = page.getByTestId('pipeline-row').filter({ hasText: 'Meera Joshi' });
  await expect(row.getByTestId('pipeline-pct')).toContainText('1 of 9 done');
  await expect(row.getByTestId('pipeline-waiting')).toContainText('Joiner');
  await expect(row.getByTestId('pipeline-waiting')).toContainText('Identity (PAN or Aadhaar)');
  await expectNoSideScroll(page);
  await page.getByLabel('Language').selectOption('hi');
  await expect(page.getByRole('heading', { level: 1 })).toContainText(hi['hr.pipeline_title']);
  await expect(row.getByTestId('pipeline-waiting')).toContainText(hi['task.identity'], { useInnerText: true });
  await page.goto('/people');
  await expect(page.getByRole('heading', { level: 1 })).toContainText(hi['people.title']);
  await expect(page.getByTestId('person-row').first()).toBeVisible();
  await expectNoSideScroll(page);
  await page.goto(`/people/${PEOPLE.qc}`);
  await expect(page.getByTestId('axis-org')).toContainText(hi['axis.org_note'], { useInnerText: true });
  await expectNoSideScroll(page);
  await page.getByLabel('Language').selectOption('en');
  await signOut(page);
});

// ── the once-a-day sign-in code (built; switched off everywhere) ──────────────────────────────────────────────────
test('The once-a-day sign-in code: after the password, a code by email; wrong one refused; asked once per day; no email, no way in', async ({ page }) => {
  const stack = localStack();
  test.skip(!stack, 'needs the local stack with its mail stand-in: on any other system the code stays off and is not touched');
  test.setTimeout(120_000);
  await stack!.emptyOutbox();
  await stack!.forgetCodes();
  try {
    await stack!.signInCode(true);
    await signInOnly(page, USERS.ravi);
    await expect(page.getByTestId('daily-code')).toBeVisible();
    await expect(menu(page)).toHaveCount(0);                                                        // nothing opens until the code is in
    await expect(page.getByTestId('code-sent')).toContainText('@gmail.com');
    await expect(page.getByTestId('code-sent')).not.toContainText('grainvedas+ravi');              // the address is masked
    await expectNoSideScroll(page);
    let code: string | null = null;
    await expect.poll(async () => (code = await stack!.codeFor(USERS.ravi.email))).toMatch(/^\d{6}$/);
    await expect(page.locator('body')).not.toContainText(code!);                                    // the code is in the mail, not on the page
    await page.locator('#daily-code-input').fill(code === '000000' ? '111111' : '000000');
    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page.getByRole('alert').filter({ hasText: 'That is not the code' })).toBeVisible();
    await expect(page.getByTestId('daily-code')).toBeVisible();
    await page.locator('#daily-code-input').fill(code!);
    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page.getByTestId('no-assignment')).toBeVisible();                                  // Ravi's own first screen
    await signOut(page);
    await signIn(page, USERS.ravi);                                                                 // the same day: the password is enough
    await expect(page.getByTestId('daily-code')).toHaveCount(0);
    await signOut(page);
    // a person who signs in by phone and has no email could never get a code: which is why the admin's switch refuses
    await signInOnly(page, USERS.qc);
    await expect(page.getByTestId('daily-code')).toBeVisible();
    await expect(page.getByTestId('code-no-email')).toContainText('no email address');
    await expect(page.getByTestId('code-resend')).toBeDisabled();
    await page.getByRole('button', { name: 'Sign out' }).click();
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  } finally {
    await stack!.signInCode(false);
    await stack!.forgetCodes();
  }
  await signIn(page, USERS.qc);                                                                     // off again: as before
  await expect(page.getByTestId('daily-code')).toHaveCount(0);
  await signOut(page);
});

// ── at a desk: the pool, assignments, lifecycle, seats ────────────────────────────────────────────────────────────
test.describe('at a desk', () => {
  test.use(DESK);

  test('People & access: one pool, two lenses, the wall between clients, and who may assign', async ({ page }) => {
    test.setTimeout(180_000);
    const u = uniq(); const buyer = freshEmail('buyer');
    await signIn(page, USERS.cm);
    await menu(page).getByRole('link', { name: 'People & access' }).click();
    await expect(page.getByTestId('people')).toBeVisible();
    // grey describes; colour grants
    const qc = person(page, 'QC Technician');
    await expect(qc.locator('.org-line')).toHaveText('QC Technician · Executive · Quality · Full-time');
    await expect(qc.getByTestId('access-badges').locator('.badge.lens-scope')).toHaveCount(6);
    await expect(person(page, 'Prasaadam Client Manager').getByTestId('access-badges').locator('.badge.lens-client')).toHaveText('Client account: GrainVeda (Prasaadam trade scope)');
    // the wall: someone with access outside what this manager manages is a number, not a place
    const sm = person(page, 'UP State Manager');
    await expect(sm.getByTestId('elsewhere')).toHaveText('+1 elsewhere');
    await expect(sm.getByTestId('access-badges')).not.toContainText('State supervisor');
    await expect(sm.getByTestId('access-badges').locator('.badge.lens-state')).toHaveCount(0);
    // the lenses offered are the ones this reader's view reaches
    await expect(page.locator('#pf-client option')).toHaveText(['Any client', 'GrainVeda (Prasaadam trade scope)']);
    await page.locator('#pf-state').selectOption({ label: 'Uttar Pradesh' });
    await expect(qc).toBeVisible();
    await expect(person(page, 'Ravi Kumar')).toHaveCount(0);
    await page.locator('#pf-state').selectOption('');
    await page.getByLabel('Unassigned only').check();
    await expect(person(page, 'Ravi Kumar').getByTestId('unassigned')).toBeVisible();
    await expect(qc).toHaveCount(0);
    await page.getByLabel('Unassigned only').uncheck();
    await page.locator('#pf-text').fill('quality associate');                                       // an org fact finds a person; it opens nothing
    await expect(page.getByTestId('person-row')).toHaveCount(1);
    await expect(person(page, 'Meera Joshi')).toContainText('Joining');
    // a manager assigns, and creates nobody
    await expect(page.getByRole('link', { name: 'Assign: Meera Joshi' })).toBeVisible();
    await expect(page.getByText('People are added by HR')).toBeVisible();
    await expect(page.getByRole('link', { name: 'Add joiner' })).toHaveCount(0);
    await expect(menu(page).getByRole('link', { name: 'HR · Joiners' })).toHaveCount(0);
    await page.locator('#pf-text').fill('');

    // a client's own read-only login is not an employee: made here by whoever manages the client, never by HR
    await page.getByRole('tab', { name: /Client logins/ }).click();
    await expect(person(page, 'Prasaadam Client View')).toBeVisible();
    await expect(qc).toHaveCount(0);
    const form = page.getByRole('form', { name: 'New client login' });
    await expect(form.getByLabel('Client')).toHaveValue(ID(201));                                   // the only client this manager has
    await form.getByLabel('Full name').fill(`Buyer ${u}`);
    await form.getByLabel('Personal email').fill(buyer);
    await form.getByRole('button', { name: 'Create' }).click();
    await expect(form.getByTestId('temp-password')).toContainText(buyer);
    const temp = (await form.getByTestId('temp-password').textContent())!.match(/: (Gv-[A-Za-z0-9_-]+) —/)![1];
    await expect(person(page, `Buyer ${u}`).getByTestId('access-badges')).toHaveText('Client login (read-only): GrainVeda (Prasaadam trade scope)');
    await signOut(page);
    await signInWith(page, buyer, temp);
    await setOwnPassword(page, `Buyer-${u}`);
    await expect(page.getByTestId('tb-context')).toHaveText('GrainVeda (Prasaadam trade scope)');
    for (const item of ['People & access', 'HR · Joiners', 'My joining checklist']) await expect(menu(page).getByRole('link', { name: item })).toHaveCount(0);
    await signOut(page);

    // HR sees the pool and may assign nobody
    await signIn(page, USERS.hr);
    await page.goto('/people');
    await expect(person(page, 'QC Technician')).toBeVisible();
    await expect(page.getByRole('link', { name: /^Assign:/ })).toHaveCount(0);
    await expect(page.getByRole('link', { name: 'Add joiner' })).toBeVisible();
    await page.goto(`/people/${PEOPLE.ravi}`);
    await expect(page.getByTestId('axis-identity')).toBeVisible();
    await expect(page.getByTestId('give-assignment')).toHaveCount(0);
    const refused = await (await apiAs(page)).rpc('assign', { p_employee: PEOPLE.ravi, p_lens: 'scope', p_target: SCOPES.siddharthnagar, p_op_role: 'operator', p_stages: ['procurement'], p_posting: '', p_ends_on: null });
    expect(refused.ok, 'HR gave someone a scope through the API').toBe(false);
    await signOut(page);

    // an operator has no directory at all
    await signIn(page, USERS.qc);
    await expect(menu(page).getByRole('link', { name: 'People & access' })).toHaveCount(0);
    expect((await (await apiAs(page)).rpc('people_directory')).ok).toBe(false);
    await signOut(page);
  });

  test('Assigning: one place at a time, warnings that do not block, nothing opens before HR says joined; stages changed, moved forward, ended', async ({ page }) => {
    test.setTimeout(360_000);
    const u = uniq(); const name = `Sunil Test ${u}`; const mail = freshEmail('sunil');
    const card = (place: string) => page.getByTestId('assignment').filter({ hasText: place });
    await signIn(page, USERS.hr);
    const made = await addJoiner(page, { name, email: mail, type: 'contract', title: 'Field Associate' });
    await signOut(page);
    try {
      await signIn(page, USERS.cm);
      await page.goto(`/people/${made.id}`);
      await expect(page.getByTestId('no-assignments')).toBeVisible();
      await page.getByTestId('give-assignment').click();
      // a client's manager gives scopes of the own client: no client lens, no state lens
      await expect(page.getByRole('tab', { name: "A client's account" })).toHaveCount(0);
      await expect(page.getByRole('tab', { name: 'A state' })).toHaveCount(0);
      await expect(page.getByTestId('assign-save')).toBeDisabled();
      await page.locator('#a-scope').selectOption(SCOPES.siddharthnagar);
      await page.getByRole('checkbox', { name: /^Procurement/ }).check();
      await expect(page.getByTestId('assign-warnings')).toContainText('still Invited');             // HR has not marked them joined
      await page.getByRole('checkbox', { name: /^Quality Control/ }).check();
      await expect(page.getByTestId('assign-warnings')).toContainText('Procurement (farm-gate) and Quality Control follow each other');
      await expect(page.getByTestId('assign-save')).toBeEnabled();                                  // a warning, not a wall
      await page.getByRole('checkbox', { name: /^Quality Control/ }).uncheck();
      await expect(page.getByTestId('assign-warnings')).not.toContainText('follow each other');
      await page.getByLabel(/Posting/).fill('Bansi collection centre');
      await page.getByTestId('assign-save').click();
      await expect(card('Siddharthnagar')).toContainText('Procurement (farm-gate)');
      await expect(card('Siddharthnagar')).toContainText('Posting: Bansi collection centre');
      await expect(card('Siddharthnagar')).toContainText('by Prasaadam Client Manager');
      // a second place is a second assignment; the form says the person is already somewhere
      await page.getByTestId('give-assignment').click();
      await page.locator('#a-scope').selectOption(SCOPES.gorakhpur);
      await page.getByRole('checkbox', { name: /^Sorting/ }).check();
      await expect(page.getByTestId('assign-warnings')).toContainText('Already working at another place this season');
      await page.getByTestId('assign-save').click();
      await expect(page.getByTestId('assignment')).toHaveCount(2);
      // the same client in another state: allowed through the client lens, and said
      await page.getByTestId('give-assignment').click();
      await page.locator('#a-scope').selectOption(NAGAON);
      await page.getByRole('checkbox', { name: /^Procurement/ }).check();
      await expect(page.getByTestId('assign-warnings')).toContainText('Already working in another state');
      await page.getByTestId('assign-save').click();
      await expect(page.getByTestId('assignment')).toHaveCount(3);
      // the same place twice is refused, in the server's words
      await page.getByTestId('give-assignment').click();
      await page.locator('#a-scope').selectOption(SCOPES.siddharthnagar);
      await page.getByRole('checkbox', { name: /^QR Activation/ }).check();
      await page.getByTestId('assign-save').click();
      await expect(page.locator('form').getByRole('alert')).toContainText('already assigned here', { useInnerText: true });
      await signOut(page);

      // assigned, but HR has not marked them joined: the assignment opens nothing
      await signInWith(page, mail, made.temp);
      await setOwnPassword(page, `Sunil-${u}`);
      await expect(page.getByTestId('joiner-home')).toBeVisible();
      await expect(page.getByTestId('pick-scope')).toHaveCount(0);
      await expect(page.locator('[data-testid^="slot-"]')).toHaveCount(0);
      expect(await (await apiAs(page)).rows('scopes')).toHaveLength(0);
      await signOut(page);
      await signIn(page, USERS.hr);
      await page.goto(`/hr/joiners/${made.id}`);
      await page.getByTestId('activate').click();
      await expect(status(page)).toHaveText('Active');
      await signOut(page);

      // joined: more than one place, so the person says where they are working today
      await signInWith(page, mail, `Sunil-${u}`);
      const pick = (id: string) => page.locator(`[data-testid="pick-scope"][data-scope="${id}"]`);
      await expect(pick(SCOPES.siddharthnagar)).toBeVisible();
      await expect(pick(SCOPES.gorakhpur)).toBeVisible();
      await expect(page.locator('[data-testid^="slot-"]')).toHaveCount(0);
      await pick(SCOPES.siddharthnagar).click();
      await expect(page.getByTestId('slot-procurement')).toBeVisible();
      await expect(page.getByTestId('slot-sorting')).toHaveCount(0);                                // one scope at a time
      await page.getByTestId('change-scope').click();
      await pick(SCOPES.gorakhpur).click();
      await expect(page.getByTestId('slot-sorting')).toBeVisible();
      await expect(page.getByTestId('slot-procurement')).toHaveCount(0);
      await signOut(page);

      // the manager changes what was given. Nothing is rewritten: an assignment grows, shrinks, ends, or is replaced.
      await signIn(page, USERS.cm);
      await page.goto(`/people/${made.id}`);
      await card('Siddharthnagar').getByRole('button', { name: 'Change stages' }).click();
      await page.getByTestId('confirm').getByRole('checkbox', { name: 'QR Activation (seal)' }).check();
      await page.getByTestId('confirm-yes').click();
      await expect(card('Siddharthnagar')).toContainText('QR Activation (seal)');
      await card('Gorakhpur').getByRole('button', { name: 'Move' }).click();
      await expect(page.getByTestId('confirm-yes')).toBeDisabled();                                 // where to, and which stage
      await page.getByTestId('confirm').getByLabel('Move to').selectOption(SCOPES.basti);
      await page.getByTestId('confirm').getByRole('checkbox', { name: 'Milling' }).check();
      await page.getByTestId('confirm').getByLabel(/Reason/).fill('needed at the mill');
      await page.getByTestId('confirm-yes').click();
      await expect(card('Basti')).toContainText('Milling');
      const old = page.getByTestId('assignment-ended').filter({ hasText: 'Gorakhpur' });
      await expect(old).toContainText('needed at the mill');
      await expect(old.getByRole('button')).toHaveCount(0);                                         // forward only: an ended one is never reopened
      // ending the only holder of a stage: said before, not after
      await card('Nagaon').getByRole('button', { name: /^End/ }).click();
      await expect(page.getByTestId('coverage-warning')).toHaveText('This will leave nobody at: Procurement (farm-gate).');
      await page.getByTestId('confirm').getByLabel(/Reason/).fill('season over');
      await page.getByTestId('confirm-yes').click();
      await expect(page.getByTestId('assignment-ended').filter({ hasText: 'Nagaon' })).toContainText('season over');
      await expect(page.getByTestId('assignment')).toHaveCount(2);
      await signOut(page);

      // every one of those acts is a line in the audit log
      await signIn(page, USERS.hrAdmin);
      await menu(page).getByRole('link', { name: 'Audit log' }).click();
      const lines = page.getByTestId('audit-feed').locator('li').filter({ hasText: name });
      for (const action of ['identity_created', 'assigned', 'activated', 'stages_changed', 'reassigned', 'revoked']) {
        await expect(lines.and(page.locator(`[data-action="${action}"]`)).first()).toBeVisible();
      }
      await expect(lines.and(page.locator('[data-action="assigned"]'))).toHaveCount(4);          // three given, and the one the move began
      await expect(lines.and(page.locator('[data-action="reassigned"]'))).toContainText('needed at the mill');
    } finally {
      // leave the demo scopes as they were: HR ends whatever this person still holds (the admin no longer may, once the
      // HR Admin seat is filled: migration 34)
      await signIn(page, USERS.hrAdmin);
      await (await apiAs(page)).rpc('offboard_person', { p_employee: made.id, p_exit_date: todayIST(), p_reason: 'end of test', p_final_settlement: '', p_form16_ref: '' });
      await signOut(page);
    }
  });

  test('Suspend freezes and reinstate restores; offboarding ends everything and keeps the record; the same person is re-hired', async ({ page }) => {
    test.setTimeout(360_000);
    const u = uniq(); const name = `Farida Test ${u}`; const mail = freshEmail('farida');
    await signIn(page, USERS.hr);
    const made = await addJoiner(page, { name, email: mail, type: 'contract', title: 'Field Associate' });
    await page.getByTestId('activate').click();
    await expect(status(page)).toHaveText('Active');
    await signOut(page);
    await signIn(page, USERS.cm);
    await page.goto(`/people/${made.id}/assign`);
    await page.locator('#a-scope').selectOption(SCOPES.siddharthnagar);
    await page.getByRole('checkbox', { name: /^Procurement/ }).check();
    await page.getByTestId('assign-save').click();
    await expect(page.getByTestId('assignment')).toHaveCount(1);
    // a manager gives and takes access; freezing or ending a person is HR's
    for (const b of ['Suspend', 'Offboard', 'Reset password']) await expect(page.getByTestId('profile-actions').getByRole('button', { name: b })).toHaveCount(0);
    expect((await (await apiAs(page)).rpc('suspend_person', { p_employee: made.id, p_reason: 'x' })).ok).toBe(false);
    await signOut(page);
    await signInWith(page, mail, made.temp);
    await setOwnPassword(page, `Farida-${u}`);
    await expect(page.getByTestId('slot-procurement')).toBeVisible();
    await signOut(page);

    // suspend: access frozen at once, the assignment kept
    await signIn(page, USERS.hr);
    await page.goto(`/people/${made.id}`);
    await page.getByTestId('profile-actions').getByRole('button', { name: 'Suspend' }).click();
    await expect(page.getByTestId('confirm-yes')).toBeDisabled();                                   // a reason is asked for
    await page.getByTestId('confirm').getByLabel(/Reason/).fill('pending an inquiry');
    await page.getByTestId('confirm-yes').click();
    await expect(status(page)).toHaveText('Suspended');
    await expect(page.getByTestId('assignment')).toHaveCount(1);
    await signOut(page);
    await signInWith(page, mail, `Farida-${u}`);
    await leaveNoAccess(page);
    await signIn(page, USERS.hr);
    await page.goto(`/people/${made.id}`);
    await page.getByTestId('profile-actions').getByRole('button', { name: 'Reinstate' }).click();
    await expect(status(page)).toHaveText('Active');
    await signOut(page);
    await signInWith(page, mail, `Farida-${u}`);
    await expect(page.getByTestId('slot-procurement')).toBeVisible();                               // everything is back
    await signOut(page);

    // offboard: every assignment ends, the sign-in opens nothing, the record stays
    await signIn(page, USERS.hr);
    await page.goto(`/people/${made.id}`);
    await page.getByTestId('profile-actions').getByRole('button', { name: 'Offboard' }).click();
    await expect(page.getByTestId('offboard-preview')).toContainText('1 assignment(s) will end.');
    const box = page.getByTestId('confirm');
    await expect(box.getByLabel('Exit date')).toHaveValue(/^\d{4}-\d{2}-\d{2}$/);
    await box.getByLabel('Exit date').fill(todayIST());
    await box.getByLabel(/Reason/).fill('contract over');
    await box.getByLabel('Final settlement').fill('paid 30 Sep');
    await box.getByLabel('Form 16 reference').fill('F16-2026-0042');
    await page.getByTestId('confirm-yes').click();
    await expect(status(page)).toHaveText('Left');
    await expect(page.getByTestId('assignment')).toHaveCount(0);
    await expect(page.getByTestId('assignment-ended')).toHaveCount(1);
    await expect(page.getByTestId('axis-identity')).toContainText('contract over');
    await expect(page.getByRole('button', { name: /delete|remove/i })).toHaveCount(0);              // a person is never deleted
    await page.getByRole('link', { name: 'HR record' }).click();
    await expect(page.locator('main')).toContainText('paid 30 Sep');
    await expect(page.getByTestId('masked-docs')).toContainText('F16-2026-0042');
    await signOut(page);
    await signInWith(page, mail, `Farida-${u}`);
    await leaveNoAccess(page);

    // re-hire: the same record, a fresh checklist, the old assignments stay ended
    await signIn(page, USERS.hr);
    await page.goto(`/people/${made.id}`);
    await page.getByTestId('profile-actions').getByRole('button', { name: 'Re-hire' }).click();
    await page.getByTestId('confirm').getByLabel('Join date').fill(todayIST());
    await page.getByTestId('confirm-yes').click();
    await expect(status(page)).toHaveText('Joining');
    await expect(page.getByTestId('assignment')).toHaveCount(0);
    await expect(page.getByTestId('assignment-ended')).toHaveCount(1);
    await page.getByRole('link', { name: 'HR record' }).click();
    expect(new URL(page.url()).pathname).toBe(`/hr/joiners/${made.id}`);
    await expect(page.getByTestId('joiner-tasks').locator('tbody tr').filter({ hasText: 'Open' })).toHaveCount(8);
    await signOut(page);
    await signInWith(page, mail, `Farida-${u}`);                                                    // the same sign-in, the password they chose
    await expect(page.getByTestId('joiner-home')).toBeVisible();
    await expect(page.locator('[data-testid^="slot-"]')).toHaveCount(0);
    await signOut(page);

    // the offboarding is flagged for the HR Admin
    await signIn(page, USERS.hrAdmin);
    await page.goto('/system/audit');
    await page.getByTestId('flagged-only').check();
    await expect(page.getByTestId('audit-line')).toHaveCount(0);
    const flag = page.locator('[data-testid="audit-flagged"][data-action="offboarded"]').filter({ hasText: name });
    await expect(flag).toContainText('offboarding');
    await expect(flag).toContainText('1 assignment(s) ended');
    await signOut(page);
  });

  test('A state at a glance across its scopes; a roster shows the stages nobody holds; each lens stops where it should', async ({ page }) => {
    test.setTimeout(120_000);
    // the state lens: every scope in Uttar Pradesh, none in Assam
    await signIn(page, USERS.sm);
    await menu(page).getByRole('link', { name: 'State overview' }).click();
    await expect(page.getByRole('heading', { level: 1 })).toContainText('State overview: Uttar Pradesh');
    await expect(page.getByTestId('state-stats')).toBeVisible();
    const rows = page.getByTestId('state-scope-row');
    await expect(rows.filter({ hasText: 'Bansi batch' })).toContainText('all 4 staffed');
    expect(await rows.count()).toBeGreaterThanOrEqual(6);
    await expect(rows.filter({ hasText: 'Nagaon' })).toHaveCount(0);
    await rows.filter({ hasText: 'Siddharthnagar' }).getByRole('link', { name: 'Roster' }).click();
    await expect(page.getByTestId('roster-covered')).toBeVisible();
    await expect(page.getByTestId('slot-holder-procurement').filter({ hasText: 'Procurement Op (field)' })).toBeVisible();
    await expect(page.getByTestId('roster-managers')).toContainText('Prasaadam Client Manager Client account');
    await expect(page.getByTestId('roster-managers')).toContainText('UP State Manager State supervisor');
    await expect(page.getByRole('combobox', { name: 'Assign Procurement (farm-gate)' })).toBeVisible();   // may assign in the own state
    // … and stops at the border
    await page.goto(`/scopes/${NAGAON}/roster`);
    await expect(page.getByRole('alert').first()).toBeVisible();
    await expect(page.getByTestId('slots')).toHaveCount(0);
    const api = await apiAs(page);
    expect((await api.rpc('state_overview', { p_state: ASSAM })).ok).toBe(false);
    expect((await api.rpc('assign', { p_employee: PEOPLE.ravi, p_lens: 'scope', p_target: NAGAON, p_op_role: 'operator', p_stages: ['procurement'], p_posting: '', p_ends_on: null })).ok).toBe(false);
    // the state seat is given by the admin only
    expect((await api.rpc('assign', { p_employee: PEOPLE.ravi, p_lens: 'state', p_target: UP, p_op_role: 'state_supervisor', p_stages: [], p_posting: '', p_ends_on: null })).ok).toBe(false);
    await signOut(page);

    // the client lens crosses states: the same client's scope in Assam, with nobody on it
    await signIn(page, USERS.cm);
    await expect(menu(page).getByRole('link', { name: 'State overview' })).toHaveCount(0);
    await page.goto(`/scopes/${NAGAON}/roster`);
    await expect(page.locator('.page-hd .sub')).toContainText('Assam');
    await expect(page.getByTestId('roster-gaps')).toContainText('3 stage(s) with nobody');
    for (const s of ['procurement', 'qc', 'qr_activation']) await expect(page.getByTestId(`gap-${s}`)).toBeVisible();
    await page.goto('/state');
    await expect(page.getByText('You supervise no state.')).toBeVisible();
    await signOut(page);

    // the admin: any state
    await signIn(page, USERS.admin);
    await page.goto(`/state/${ASSAM}`);
    await expect(page.getByRole('heading', { level: 1 })).toContainText('State overview: Assam');
    const nagaon = page.getByTestId('state-scope-row').filter({ hasText: 'Nagaon' });
    await expect(nagaon).toContainText('3 unstaffed');
    await expect(nagaon).toHaveClass(/gap-row/);
    await expect(page.locator('#st-pick option')).toHaveText(['Assam', 'Uttar Pradesh']);
    await signOut(page);
  });

  test('The two seats: break-glass note, the HR Admin seat moved and moved back, the code switch refuses; HR made by HR is flagged; the log cannot be edited', async ({ page }) => {
    test.setTimeout(240_000);
    const u = uniq(); const name = `Nadia Test ${u}`;
    await signIn(page, USERS.admin);
    await menu(page).getByRole('link', { name: 'Seats' }).click();
    await expect(page.getByTestId('seat-admin')).toContainText('Veda (Admin)');
    await expect(page.getByTestId('break-glass')).toContainText('scripts/bootstrap_admin.mjs');
    const seat = page.getByTestId('seat-hr-admin');
    const holder = seat.locator('ul').first();
    await expect(holder).toContainText('Asha (HR Admin)');
    await expect(page.getByTestId('seat-vacant')).toHaveCount(0);
    try {
      // exactly one seat: giving it to someone else makes the present holder an HR resource
      await page.locator('#seat-pick').selectOption(ID(317));
      page.once('dialog', (d) => d.accept());
      await page.getByTestId('appoint').click();
      await expect(holder).toContainText('Imran (HR)');
      await expect(holder.locator('li')).toHaveCount(1);
      await expect(seat.locator('ul').nth(1)).toContainText('Asha (HR Admin)');
    } finally {
      await page.goto('/system/seats');
      if (!(await holder.textContent())?.includes('Asha')) {
        await page.locator('#seat-pick').selectOption(ID(316));
        page.once('dialog', (d) => d.accept());
        await page.getByTestId('appoint').click();
      }
      await expect(holder).toContainText('Asha (HR Admin)');
    }
    // the once-a-day code: built, off, and the switch says why it stays off here
    const code = page.getByTestId('daily-code-card');
    await expect(code.getByRole('heading')).toContainText('OFF');
    await expect(page.getByTestId('code-sender')).toHaveText('set up');                             // the local mail stand-in
    expect(Number(await page.getByTestId('code-no-email').textContent())).toBeGreaterThanOrEqual(11);
    page.once('dialog', (d) => d.accept());
    await page.getByTestId('code-switch-on').click();
    await expect(page.getByTestId('code-refused')).toContainText('Not switched on');
    await expect(page.getByTestId('code-refused')).toContainText('QC Technician');
    await expect(code.getByRole('heading')).toContainText('OFF');
    // the admin's own profile offers nothing that could empty the root seat
    await page.goto(`/people/${ID(301)}`);
    await expect(page.getByTestId('axis-system-role')).toContainText('Admin');
    for (const b of ['Suspend', 'Offboard']) await expect(page.getByTestId('profile-actions').getByRole('button', { name: b })).toHaveCount(0);
    await expect(page.locator('#sysrole')).toHaveCount(0);
    await signOut(page);

    // an HR resource may add another HR resource; the menu shows neither seats nor the log
    await signIn(page, USERS.hr);
    for (const item of ['Seats', 'Audit log']) await expect(menu(page).getByRole('link', { name: item })).toHaveCount(0);
    await page.goto('/hr/joiners/new');
    await page.getByLabel('System role').selectOption('hr_resource');
    await expect(page.getByText('made by another HR resource is flagged')).toBeVisible();
    await expect(page.getByLabel('System role').locator('option')).toHaveText(['Operational', 'HR']);   // never Admin from here
    const made = await addJoiner(page, { name, email: freshEmail('nadia'), systemRole: 'hr_resource' });
    expect((await (await apiAs(page)).rpc('audit_feed', { p_limit: 10, p_flagged: false })).ok).toBe(false);
    await signOut(page);

    // the HR Admin reads the log: that act is flagged, and so are the two moves of the seat
    await signIn(page, USERS.hrAdmin);
    await expect(menu(page).getByRole('link', { name: 'Seats' })).toHaveCount(0);
    await menu(page).getByRole('link', { name: 'Audit log' }).click();
    await expect(page.getByTestId('audit-feed')).toBeVisible();
    await page.getByTestId('flagged-only').check();
    await expect(page.getByTestId('audit-line')).toHaveCount(0);
    const byHr = page.locator('[data-testid="audit-flagged"][data-action="hr_resource_created"]').filter({ hasText: name });
    await expect(byHr).toContainText('Imran (HR)');
    await expect(byHr).toContainText('HR made by HR');
    expect(await page.locator('[data-testid="audit-flagged"][data-action="hr_admin_appointed"]').count()).toBeGreaterThanOrEqual(2);
    // append-only, for the HR Admin too
    const api = await apiAs(page);
    const upd = await api.update('audit_log', 'flagged=is.true', { flagged: false });
    expect(upd.ok && Array.isArray(upd.data) && upd.data.length > 0, 'an audit line was changed through the API').toBe(false);
    const ins = await api.insert('audit_log', { action: 'made_up', detail: {} });
    expect(ins.ok, 'an audit line was written through the API').toBe(false);
    expect((await api.rows('audit_log', 'flagged=is.true&limit=5')).length).toBeGreaterThan(0);
    // tidy: the test's HR resource leaves (the HR Admin manages HR resources; that, too, is a flagged line)
    expect((await api.rpc('offboard_person', { p_employee: made.id, p_exit_date: todayIST(), p_reason: 'end of test', p_final_settlement: '', p_form16_ref: '' })).ok).toBe(true);
    await signOut(page);
  });
});
