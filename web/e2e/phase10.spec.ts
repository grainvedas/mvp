// Migration 37 (Veda's brief of 11 Oct 2026, "Joiner checklist and HR data improvements"), through the screens.
//   A1  a PAN, Aadhaar or UAN already on someone's record is refused, the joiner told in neutral words, HR told whose;
//       a bank account on another record is saved and HR warned, and may accept it with a reason (flagged).
//       The full number goes from the phone to the id-numbers function and nowhere else: the last test of the first
//       case searches everything the local stack wrote (database dump, PostgreSQL log with every statement logged, the
//       services' logs, the stored files) and the browser's own storage for the numbers typed, with planted controls.
//   A2  the masked Aadhaar only; HR says masked or not; "not masked" deletes the image and asks the joiner again.
//   A3  Personal details; A4 the phone at Add joiner; B1 nothing overdue on the day a person is added;
//   B3–B7 the joiner's words, Help page, guide and first-day details, in English and Hindi, at phone width.
// The same rules are tested at the database in tests/31_joiner_hr_data.sql and in web/tests/id_numbers.test.ts.
import { test, expect, type Page, type Browser } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { signIn, signInWith, signOut, setOwnPassword, freshEmail, addJoiner, expectNoSideScroll, apiAs, localStack, todayIST,
  freshPan, freshAadhaar, freshAccount, freshUan, USERS } from './helpers';
import { supabaseConfig } from '../../scripts/lib/env.mjs';
import { hi } from '../src/lib/i18n.hi';

const uniq = () => String(Date.now()).slice(-6);
const DESK = { viewport: { width: 1366, height: 768 }, isMobile: false, hasTouch: false, deviceScaleFactor: 1 } as const;
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64');
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const spaced = (a: string) => `${a.slice(0, 4)} ${a.slice(4, 8)} ${a.slice(8)}`;

/** A joiner's first sign-in on the phone: the temporary password, then their own. */
async function firstSignIn(page: Page, mail: string, temp: string, pw: string) {
  await signInWith(page, mail, temp);
  await setOwnPassword(page, pw);
  await expect(page.getByTestId('joiner-home')).toBeVisible();
}
const openStep = async (page: Page, code: string) => {
  await page.goto('/onboarding');
  await page.getByTestId(`row-${code}`).getByTestId('start-task').click();
};
const alertBox = (page: Page) => page.locator('main').getByRole('alert');

/** Everything under a directory, as text (binary files too: a number written into them shows as its digits). */
function filesUnder(dir: string): { path: string; text: string }[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = join(dir, e.name);
    if (e.isDirectory()) return filesUnder(p);
    if (!e.isFile() || statSync(p).size > 50e6) return [];
    return [{ path: p, text: readFileSync(p).toString('latin1') }];
  });
}
/** What the browser keeps for this page: localStorage, sessionStorage and every IndexedDB store. */
const browserStorage = (page: Page) => page.evaluate(async () => {
  const out: Record<string, unknown> = { local: { ...localStorage }, session: { ...sessionStorage } };
  const dbs = (await indexedDB.databases?.()) ?? [];
  for (const d of dbs) {
    if (!d.name) continue;
    const db = await new Promise<IDBDatabase>((ok, no) => { const r = indexedDB.open(d.name!); r.onsuccess = () => ok(r.result); r.onerror = () => no(r.error); });
    for (const s of [...db.objectStoreNames]) {
      out[`${d.name}/${s}`] = await new Promise((ok) => { const r = db.transaction(s).objectStore(s).getAll(); r.onsuccess = () => ok(r.result); r.onerror = () => ok(null); });
    }
    db.close();
  }
  return JSON.stringify(out);
});

const dbUrl = () => (supabaseConfig().env as Record<string, string | undefined>).SUPABASE_DB_URL ?? '';
const psql = (sql: string) => execFileSync('psql', [dbUrl(), '-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1', '-c', sql], { encoding: 'utf8' });
const PG_LOG = process.env.GV_PG_LOG ?? '/var/tmp/gvpg/pg.log';

// ── A1: duplicates, and where the numbers went ──────────────────────────────────────────────────────────────────────
test('Duplicates: a PAN, Aadhaar or UAN on another record is refused in neutral words and HR sees whose; a shared bank account is saved, warned and accepted with a reason; the numbers typed are nowhere the stack wrote', async ({ page, browser }) => {
  test.setTimeout(420_000);
  const stack = localStack();
  test.skip(!stack || !dbUrl(), 'needs the local stack (the search reads its database, logs and files)');
  const u = uniq();
  const A = { name: `Asha Dup ${u}`, mail: freshEmail('asha') }, B = { name: `Bina Dup ${u}`, mail: freshEmail('bina') };
  const PAN = freshPan(), AAD = freshAadhaar(), UAN = freshUan(), ACCT = freshAccount(), PAN_B = freshPan();
  const CTL = `GVCTL${u}${Date.now() % 1e4}`;                      // planted: must be FOUND, or the search proves nothing
  // every statement and its parameters into the PostgreSQL log, for the length of this test
  psql("alter system set log_statement = 'all'");
  psql('select pg_reload_conf()');
  const office = await browser.newContext(DESK); const hr = await office.newPage();
  try {
    await signIn(hr, USERS.hr);
    const a = await addJoiner(hr, { name: A.name, email: A.mail, type: 'full_time', title: 'Field Associate' });
    const b = await addJoiner(hr, { name: B.name, email: B.mail, type: 'full_time', title: 'Field Associate' });

    // A: PAN and Aadhaar, the UAN on the PF step, the bank account: all saved
    await firstSignIn(page, A.mail, a.temp, `Asha-${u}x`);
    await openStep(page, 'identity');
    await page.locator('#t-pan').fill(PAN);
    await page.locator('#t-aadhaar').fill(spaced(AAD));
    await page.locator('#t-file').setInputFiles({ name: 'masked.png', mimeType: 'image/png', buffer: Buffer.concat([PNG, Buffer.from(CTL)]) });
    await page.getByTestId('task-done').click();
    await expect(page.getByTestId('row-identity')).toHaveAttribute('data-state', 'done');
    await openStep(page, 'pf_gratuity');
    await page.locator('#t-nominee').fill('Ramesh');
    await page.locator('#t-relation').fill('father');
    await page.locator('#t-uan').fill(UAN);
    await page.getByTestId('task-done').click();
    await expect(page.getByTestId('row-pf_gratuity')).toHaveAttribute('data-state', 'done');
    await openStep(page, 'bank');
    await page.locator('#t-bank').fill('State Bank of India');
    await page.locator('#t-ifsc').fill('SBIN0001234');
    await page.locator('#t-account').fill(ACCT);
    await page.getByTestId('task-done').click();
    await expect(page.getByTestId('row-bank')).toHaveAttribute('data-state', 'done');
    const storedA = await browserStorage(page);
    await signOut(page);

    // B types A's numbers: refused, in words that name nobody
    await firstSignIn(page, B.mail, b.temp, `Bina-${u}x`);
    for (const [step, fill] of [['identity', async () => page.locator('#t-pan').fill(PAN)], ['identity', async () => page.locator('#t-aadhaar').fill(AAD)],
      ['pf_gratuity', async () => { await page.locator('#t-nominee').fill('Mohan'); await page.locator('#t-relation').fill('husband'); await page.locator('#t-uan').fill(UAN); }]] as const) {
      await openStep(page, step);
      await fill();
      await page.getByTestId('task-done').click();
      await expect(alertBox(page)).toHaveText('This number is already registered. HR has been told.');
      await expect(page.locator('main')).not.toContainText(A.name);
      await expectNoSideScroll(page);
      await page.goto('/onboarding');
      await expect(page.getByTestId(`row-${step}`)).toHaveAttribute('data-state', 'open');
    }
    // the same account at another branch of the same bank: saved (the joiner is not told; HR is)
    await openStep(page, 'bank');
    await page.locator('#t-bank').fill('State Bank of India');
    await page.locator('#t-ifsc').fill('SBIN0009999');
    await page.locator('#t-account').fill(ACCT);
    await page.getByTestId('task-done').click();
    await expect(page.getByTestId('row-bank')).toHaveAttribute('data-state', 'done');
    // and in Hindi, the same refusal
    await openStep(page, 'identity');
    await page.getByLabel('Language').selectOption('hi');
    await page.locator('#t-pan').fill(PAN);
    await page.getByTestId('task-done').click();
    await expect(alertBox(page)).toHaveText(hi['id.duplicate']);
    await page.getByLabel('Language').selectOption('en');
    // her own PAN: saved
    await page.locator('#t-pan').fill(PAN_B);
    await page.getByTestId('task-done').click();
    await expect(page.getByTestId('row-identity')).toHaveAttribute('data-state', 'done');
    const storedB = await browserStorage(page);

    // HR: whose numbers they were; the bank warning, accepted with a reason
    await hr.goto(`/hr/joiners/${b.id}`);
    await expect(hr.getByTestId('match-pan')).toHaveCount(2);                                      // typed twice (English, then Hindi): two refusals
    for (const k of ['pan', 'aadhaar', 'uan']) {
      for (const m of await hr.getByTestId(`match-${k}`).all()) {
        await expect(m).toHaveAttribute('data-outcome', 'refused');
        await expect(m).toContainText(`already on ${A.name}'s record`);
      }
    }
    await expect(hr.getByTestId('match-pan').first()).toContainText(`•••• ${PAN.slice(-4)}`);
    const bank = hr.getByTestId('match-bank');
    await expect(bank).toContainText(`This bank account is also on ${A.name}'s record.`);
    await expect(bank.getByTestId('accept-bank')).toBeDisabled();                                  // a reason is required
    await bank.getByTestId('accept-reason').fill('Joint account with her sister, checked on the passbook');
    await bank.getByTestId('accept-bank').click();
    await expect(bank).toContainText('Accepted by');
    await expect(bank).toContainText('Joint account with her sister');
    for (const k of ['pan', 'bank']) await expect(hr.getByTestId(`checked-${k}`)).toHaveText('checked for duplicates');
    for (const n of [PAN, AAD, UAN, ACCT]) await expect(hr.locator('main')).not.toContainText(n);
    // the warning is on the record of the person who gave the number second; A's record is unchanged
    await hr.goto(`/hr/joiners/${a.id}`);
    await expect(hr.getByTestId('masked-docs')).toContainText(`•••• ${ACCT.slice(-4)}`);
    await expect(hr.getByTestId('match-bank')).toHaveCount(0);
    await signOut(hr);

    // the HR Admin's log: the refusals and the acceptance are flagged
    await signIn(hr, USERS.hrAdmin);
    await hr.goto('/system/audit');
    await hr.getByTestId('flagged-only').check();
    await expect(hr.locator('[data-testid="audit-flagged"][data-action="bank_duplicate_accepted"]').filter({ hasText: B.name })).toHaveCount(1);
    expect(await hr.locator('[data-testid="audit-flagged"][data-action="id_number_refused"]').filter({ hasText: B.name }).count()).toBeGreaterThanOrEqual(3);

    // ── the search: the full numbers, in every shape they were typed, anywhere ──────────────────────────────────
    const shapes = [PAN, PAN.toLowerCase(), AAD, spaced(AAD), UAN, ACCT, PAN_B];
    psql(`select '${CTL}' as planted_in_the_log`);                                                // control for the PostgreSQL log
    const dump = execFileSync('pg_dump', [dbUrl(), '--no-owner'], { maxBuffer: 1 << 30 }).toString('latin1');
    const run = filesUnder(join(ROOT, 'local-stack', 'run'));
    const pgLog = existsSync(PG_LOG) ? readFileSync(PG_LOG).toString('latin1') : null;
    const places: { where: string; text: string }[] = [
      { where: 'database dump', text: dump }, ...run.map((f) => ({ where: f.path, text: f.text })),
      { where: 'browser storage (A)', text: storedA }, { where: 'browser storage (B)', text: storedB },
      ...(pgLog === null ? [] : [{ where: PG_LOG, text: pgLog }]),
    ];
    // the controls: the search sees what is there
    expect(dump, 'control: the dump holds the joiner\'s name').toContain(A.name);
    expect(dump, 'control: the dump holds the last four').toContain(PAN.slice(-4));
    expect(run.some((f) => f.path.includes(`${join('local-stack', 'run', 'storage')}`) && f.text.includes(CTL)), 'control: the stored image was searched').toBe(true);
    expect(run.filter((f) => f.path.endsWith('.log')).length, 'the services\' logs were searched').toBeGreaterThanOrEqual(5);
    if (pgLog !== null) {
      expect(pgLog, 'control: the PostgreSQL log holds a planted statement').toContain(CTL);
      expect(pgLog, 'control: the log holds the joiner\'s statements with their parameters').toMatch(/record_id_number|complete_task/);
    } else test.info().annotations.push({ type: 'not searched', description: `PostgreSQL log not found at ${PG_LOG} (set GV_PG_LOG)` });
    const found = places.flatMap((p) => shapes.filter((s) => p.text.includes(s)).map(() => p.where));
    expect(found, 'a full number was found in these places').toEqual([]);
    test.info().annotations.push({ type: 'searched', description: `${places.length} places, ${Math.round(places.reduce((n, p) => n + p.text.length, 0) / 1e6)} MB, ${shapes.length} shapes` });
  } finally {
    psql('alter system reset log_statement'); psql('select pg_reload_conf()');
    await office.close();
  }
});

// ── A2, A4, B1 ────────────────────────────────────────────────────────────────────────────────────────────────────
test('HR: Add joiner needs a phone; nothing is overdue on the day a person is added; a masked Aadhaar that is not masked is deleted and the joiner asked again', async ({ page, browser }) => {
  test.setTimeout(240_000);
  const u = uniq(); const name = `Chanda Mask ${u}`; const mail = freshEmail('chanda');
  const office = await browser.newContext(DESK); const hr = await office.newPage();
  try {
    await signIn(hr, USERS.hr);
    // A4: the form will not go without a phone, and the server says so too
    await hr.goto('/hr/joiners/new');
    await hr.getByLabel('Full name').fill(name);
    await hr.getByLabel('Join date').fill(todayIST());
    await hr.getByLabel('Personal email').fill(mail);
    await hr.getByRole('button', { name: 'Save and create sign-in' }).click();
    await expect(hr.locator('#j-phone:invalid')).toHaveCount(1);
    await expect(hr.getByTestId('temp-password')).toHaveCount(0);
    await hr.locator('#j-phone').evaluate((el) => el.removeAttribute('required'));
    await hr.getByRole('button', { name: 'Save and create sign-in' }).click();
    await expect(hr.locator('form').getByRole('alert')).toContainText(/phone is required/i);
    await expect(hr.getByTestId('temp-password')).toHaveCount(0);

    // B1: joining today, added today: every step due in three days at the earliest, none overdue
    const made = await addJoiner(hr, { name, email: mail, type: 'intern', title: 'Field Intern' });
    const rows = hr.getByTestId('joiner-tasks').locator('tbody tr');
    await expect(rows).toHaveCount(8);
    await expect(hr.getByTestId('joiner-tasks')).not.toContainText('overdue');
    await hr.goto('/hr');
    await expect(hr.getByTestId('pipeline-row').filter({ hasText: name })).not.toContainText('overdue');
    const tasks = ((await (await apiAs(hr)).rpc('joiner_detail', { p_employee: made.id })).data as { tasks: { due_on: string }[] }).tasks;
    const in3 = new Date(Date.parse(todayIST()) + 3 * 864e5).toISOString().slice(0, 10);
    for (const k of tasks) expect(k.due_on >= in3, `due ${k.due_on}, added ${todayIST()}`).toBe(true);

    // the joiner: a masked Aadhaar image with the identity step
    await firstSignIn(page, mail, made.temp, `Chanda-${u}x`);
    await openStep(page, 'identity');
    await page.locator('#t-pan').fill(freshPan());
    await page.locator('#t-file').setInputFiles({ name: 'aadhaar.png', mimeType: 'image/png', buffer: PNG });
    await page.getByTestId('task-done').click();
    await expect(page.getByTestId('row-identity')).toHaveAttribute('data-state', 'done');
    const file = (await (await apiAs(page)).rows('employee_files'))[0] as { storage_path: string };

    // HR: not masked. The image is deleted, the record kept, the step opened again with a note
    await hr.goto(`/hr/joiners/${made.id}`);
    const img = hr.getByTestId('hr-file').filter({ hasText: 'aadhaar.png' });
    await expect(img).toContainText('Masked Aadhaar');
    hr.once('dialog', (d) => d.accept());
    await img.getByTestId('masked-no').click();
    await expect(img).toContainText('image deleted');
    await expect(img.getByTestId('masked-no')).toHaveCount(0);
    expect((await (await apiAs(hr)).signedUrlIn('hr-docs', file.storage_path)).ok, 'the image is gone from the store').toBe(false);
    await expect(hr.getByTestId('task-identity')).toContainText('Open');

    await page.goto('/onboarding');
    await expect(page.getByTestId('row-identity')).toHaveAttribute('data-state', 'open');
    await page.getByTestId('row-identity').getByTestId('start-task').click();
    await expect(page.getByTestId('task-note')).toContainText('asked again: a masked Aadhaar');
    await expect(page.getByTestId('id-on-file')).toContainText('PAN ••••');                     // the PAN stays: no need to type it again
    await page.locator('#t-file').setInputFiles({ name: 'aadhaar masked.png', mimeType: 'image/png', buffer: PNG });
    await page.getByTestId('task-done').click();
    await expect(page.getByTestId('row-identity')).toHaveAttribute('data-state', 'done');
    await expectNoSideScroll(page);
  } finally { await office.close(); }
});

// ── B3–B7 ─────────────────────────────────────────────────────────────────────────────────────────────────────────
async function joinerWords(page: Page, browser: Browser) {
  const u = uniq(); const name = `Deepa Help ${u}`; const mail = freshEmail('deepa');
  const office = await browser.newContext(DESK); const hr = await office.newPage();
  try {
    // an HR joiner, with first-day details set by HR
    await signIn(hr, USERS.hrAdmin);
    const made = await addJoiner(hr, { name, email: mail, type: 'full_time', title: 'HR Associate', systemRole: 'hr_resource' });
    await hr.getByTestId('edit-first-day').click();
    await hr.locator('#fd-time').fill('09:30');
    await hr.locator('#fd-place').fill('Lucknow office, second floor');
    await hr.locator('#fd-ask').fill('Minal at the front desk');
    await hr.locator('#fd-bring').fill('PAN card, two photos');
    await hr.getByTestId('save-first-day').click();
    await expect(hr.getByTestId('first-day-hr')).toContainText('Lucknow office, second floor');

    await firstSignIn(page, mail, made.temp, `Deepa-${u}x`);
    // B3: the date, not "joined N days ago"; B4: HR words; B5: the guide card
    await expect(page.getByTestId('join-countdown')).toHaveText(/^Your joining date: \d{1,2} [A-Z][a-z]{2} \d{4}$/);
    await expect(page.getByTestId('no-access-yet')).toHaveText('Once HR marks you as joined you will see the HR pages.');
    await expect(page.getByTestId('role-guide')).toHaveAttribute('data-role', 'joiner');
    await expect(page.getByTestId('role-guide')).toContainText('Your joining');
    await expectNoSideScroll(page);
    // B5: Help, from the menu and from the home screen
    await page.getByTestId('joiner-help').click();
    await expect(page.getByTestId('help-joiner')).toBeVisible();
    await expect(page.getByTestId('help-contact-hr-admin')).toContainText('@');
    await expect(page.getByTestId('help-steps')).toContainText('Personal details');
    await expect(page.getByTestId('help-after')).toContainText('HR · Joiners');
    await expectNoSideScroll(page);
    // B6: the first day as HR set it; B4 on that page
    await page.goto('/welcome');
    const day = page.getByTestId('first-day');
    for (const s of ['09:30', 'Lucknow office, second floor', 'Minal at the front desk', 'PAN card, two photos']) await expect(day).toContainText(s);
    await expect(page.getByTestId('day1-after')).toHaveText('Once you have joined you will see the HR pages.');
    await expectNoSideScroll(page);

    // the same in Hindi
    await page.getByLabel('Language').selectOption('hi');
    await expect(day).toContainText(hi['day1.details'], { useInnerText: true });
    await expect(page.getByTestId('day1-after')).toHaveText(hi['day1.after_joining_hr']);
    await expectNoSideScroll(page);
    await page.goto('/');
    await expect(page.getByTestId('join-countdown')).toContainText(hi['mine.join.date'].split('{d}')[0].trim());
    await expect(page.getByTestId('no-access-yet')).toHaveText(hi['mine.no_access_yet_hr']);
    await expect(page.getByTestId('role-guide')).toContainText(hi['guide.joiner.title']);
    await expectNoSideScroll(page);
    await page.goto('/help');
    await expect(page.getByTestId('help-joiner')).toContainText(hi['help.joiner.who'], { useInnerText: true });
    await expect(page.getByTestId('help-after')).toContainText(hi['help.joiner.after_hr'], { useInnerText: true });
    await expectNoSideScroll(page);
    // B7 in Hindi; A3 in Hindi
    await openStep(page, 'identity');
    const a = freshAadhaar();
    await page.locator('#t-aadhaar').fill(a.slice(0, 11) + String((Number(a[11]) + 1) % 10));
    await expect(page.getByTestId('task-problem')).toHaveText(hi['mine.bad_aadhaar']);
    await expect(page.getByTestId('masked-howto')).toHaveText(hi['mine.masked_howto']);
    await expectNoSideScroll(page);
    await openStep(page, 'personal');
    await expect(page.getByTestId('personal-form')).toContainText(hi['mine.personal_body'], { useInnerText: true });
    await expect(page.getByTestId('task-problem')).toHaveText(hi['mine.need_dob']);
    await expectNoSideScroll(page);
    await page.getByLabel('Language').selectOption('en');
  } finally { await office.close(); }
}
test('A joiner on a phone, in English and Hindi: the joining date, words for an HR joiner, the Help page with contacts, the guide, the first-day details', async ({ page, browser }) => {
  test.setTimeout(240_000);
  await joinerWords(page, browser);
});

// ── other roles: what was not to change ───────────────────────────────────────────────────────────────────────────
test('Other roles are as they were: the field employee and the admin see no joiner Help entry and no new steps', async ({ page }) => {
  await signIn(page, USERS.ravi);                                                                     // active, nobody has assigned him
  await expect(page.getByTestId('no-assignment')).toBeVisible();
  await expect(page.getByTestId('role-guide').and(page.locator('[data-role="joiner"]'))).toHaveCount(0);
  await signOut(page);
  await signIn(page, USERS.admin);
  await expect(page.getByRole('heading', { name: 'Platform overview' })).toBeVisible();
  await page.goto('/help');
  await expect(page.getByTestId('help-joiner')).toHaveCount(0);
  await signOut(page);
});
