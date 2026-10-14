// Onboarding at scale (migration 38, Veda's brief of 11 October 2026), the "Done means" run on a phone-sized screen
// (527 px, as the brief says HR may work from a phone): an opening, a 205-row spreadsheet with errors, the same file
// again (nothing twice), invite links for a page of people and one joiner accepting on a phone, Mine / filters / paging,
// the gate on Mark as joined, a whole page marked as joined at once, 40 people given a stage in one act, the opening's
// numbers at every point, and the admin's overview giving the same totals. LOCAL STACK ONLY: it adds 205 people.
// Timings are printed (`TIMING …`) for the report; they are of the local stack, not of a hosted project.
import { test, expect, type Page } from '@playwright/test';
import writeXlsxFile from 'write-excel-file/node';
import { signIn, signOut, apiAs, expectNoSideScroll, markJoined, todayIST, USERS, localStack } from './helpers';
import { hi } from '../src/lib/i18n.hi';

test.use({ viewport: { width: 527, height: 900 } });

const u = String(Date.now()).slice(-6);
const run4 = String(Date.now() % 10000).padStart(4, '0');
const addDays = (d: string, n: number) => new Date(Date.parse(`${d}T00:00:00Z`) + n * 864e5).toISOString().slice(0, 10);
const JOIN = addDays(todayIST(), 7);
const timings: string[] = [];
async function timed<T>(what: string, fn: () => Promise<T>): Promise<T> {
  const t0 = Date.now(); const r = await fn(); const ms = Date.now() - t0;
  timings.push(`${what}: ${ms} ms`); console.log(`TIMING ${what}: ${ms} ms`); return r;
}
const num = async (page: Page, testid: string) => Number((await page.getByTestId(testid).innerText()).trim());

/** 200 contract operators (A…, joining in a week), 5 full-time (Z…, joining today; they have the statutory step), and 3 rows that cannot be added. */
async function sheet(code: string) {
  const head = ['full_name', 'personal_email', 'phone', 'join_date', 'employment_type', 'opening'];
  const rows: (string | number)[][] = [];
  for (let i = 1; i <= 200; i++) rows.push([`Scale A${u} ${String(i).padStart(3, '0')}`, `scale.a${u}.${i}@example.com`, `6${run4}${String(i).padStart(5, '0')}`, JOIN, 'contract', code]);
  for (let i = 1; i <= 5; i++) rows.push([`Scale Z${u} ${i}`, `scale.z${u}.${i}@example.com`, `6${run4}${String(500 + i).padStart(5, '0')}`, todayIST(), 'full_time', code]);
  rows.push([`Scale Bad${u} 1`, 'not-an-email', `6${run4}00901`, JOIN, 'contract', code]);         // bad email
  rows.push(['', `scale.bad${u}.2@example.com`, `6${run4}00902`, JOIN, 'contract', code]);           // no name
  rows.push([`Scale Bad${u} 3`, `scale.bad${u}.3@example.com`, `6${run4}00903`, 'next week', 'contract', code]);   // not a date
  const data = [head.map((value) => ({ value })), ...rows.map((r) => r.map((value) => ({ value })))];
  return (await writeXlsxFile(data, { buffer: true })) as Buffer;
}

test('Onboarding at scale: 205 joiners from one spreadsheet to 40 on a stage, the numbers right at every step, on a phone', async ({ page, browser }) => {
  test.skip(!localStack(), 'adds 205 people: local stack only (the brief: no load on the practice system)');
  test.setTimeout(600_000);

  // ── A0. The Client Manager drafts a new scope (its own, so the demo scopes the other tests count stay as they are)
  await signIn(page, USERS.cm);
  await page.goto('/scopes/new');
  await page.getByLabel(/Geography/).fill(`Scale ${u}`);
  await page.getByRole('button', { name: 'Next' }).click();
  await page.getByLabel('Crop').selectOption({ label: 'Kalanamak rice' });
  await page.getByRole('button', { name: 'Next' }).click();
  await page.getByRole('button', { name: /Save draft/ }).click();
  await expect(page.getByRole('heading', { name: new RegExp(`Scale ${u}`) })).toContainText('Draft');
  const scopeId = new URL(page.url()).pathname.match(/[0-9a-f-]{36}/)![0];
  await signOut(page);

  // ── A. HR makes an opening: Uttar Pradesh, operators for Procurement in that scope, 205 positions
  await signIn(page, USERS.hr);
  await page.goto('/hr/openings');
  await expectNoSideScroll(page);
  await page.getByTestId('new-opening').click();
  const form = page.getByTestId('opening-form');
  await form.locator('#of-state').selectOption({ label: 'Uttar Pradesh' });
  await form.locator('#of-role').selectOption('operator');
  await form.locator('#of-pos').fill('205');
  await form.locator('#of-client').selectOption({ label: 'GrainVeda (Prasaadam trade scope)' });
  await form.locator('#of-scope').selectOption(scopeId);
  await form.locator('#of-stage').selectOption('procurement');
  await form.locator('#of-title').fill(`Scale test ${u}`);
  await timed('save an opening (screen)', async () => { await page.getByTestId('save-opening').click(); await expect(form).toHaveCount(0); });
  const api = await apiAs(page);
  const op = (await api.rows('openings', `title=eq.${encodeURIComponent(`Scale test ${u}`)}&select=id,code`))[0] as { id: string; code: string };
  expect(op.code).toMatch(/^UP-OPR-\d{3}$/);
  const n = (k: string) => num(page, `n-${op.code}-${k}`);
  await expect(page.getByTestId(`n-${op.code}-positions`)).toHaveText('205');
  expect(await n('vacant')).toBe(205);
  expect(await n('joining')).toBe(0);
  await expect(page.locator(`[data-testid="opening-row"][data-code="${op.code}"]`)).toContainText('not active yet');   // a draft scope
  await expectNoSideScroll(page);

  // ── B. The spreadsheet: preview with reasons, add only the good rows, then the same file again adds nobody
  const file = { name: `joiners_${u}.xlsx`, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', buffer: await sheet(op.code) };
  await page.goto('/hr/import');
  await expectNoSideScroll(page);
  await timed('import preview, 208 rows (screen)', async () => {
    await page.locator('#imp-file').setInputFiles(file);
    await expect(page.getByTestId('imp-result')).toHaveAttribute('data-dry', 'true');
  });
  expect(await num(page, 'imp-n-ready') + await num(page, 'imp-n-warning')).toBe(205);
  await expect(page.getByTestId('imp-n-error')).toHaveText('3');
  const bad = page.locator('[data-testid="imp-row"][data-status="error"]');
  await expect(bad).toHaveCount(3);                                           // "problems" shows the three with their reasons
  await expect(bad.nth(0)).toContainText('email');
  await expect(bad.nth(2)).toContainText('date');
  await expectNoSideScroll(page);
  await timed('import commit, 205 people (screen)', async () => {
    await page.getByTestId('imp-commit').click();
    await expect(page.getByTestId('imp-result')).toHaveAttribute('data-dry', 'false', { timeout: 60_000 });
  });
  await expect(page.getByTestId('imp-n-created')).toHaveText('205');
  // the same file again: everyone is already there, nothing is added twice
  await page.goto('/hr/import');
  await page.locator('#imp-file').setInputFiles(file);
  await expect(page.getByTestId('imp-result')).toHaveAttribute('data-dry', 'true');
  await expect(page.getByTestId('imp-n-skipped')).toHaveText('205');
  await expect(page.getByTestId('imp-n-ready')).toHaveText('0');
  await expect(page.getByTestId('imp-commit')).toHaveCount(0);
  expect((await api.rows('employee_org', `opening_id=eq.${op.id}&select=id`)).length).toBe(205);
  await page.goto('/hr/openings');
  expect(await n('joining')).toBe(205);
  expect(await n('vacant')).toBe(0);

  // ── C. The joiners list: by opening, paged on the server, Mine; invite links for a whole page at once
  await timed('joiners list, filtered by opening (screen)', async () => {
    await page.goto(`/hr?opening=${op.id}`);
    await expect(page.getByTestId('pager-text')).toHaveText('Page 1 of 5 · 205 people');
  });
  await expect(page.getByTestId('pipeline-row')).toHaveCount(50);
  await expect(page.getByTestId('pipeline-row').first().getByTestId('pipeline-role')).toContainText(op.code);
  await expect(page.getByTestId('pipeline-row').last().getByTestId('pipeline-when')).toContainText('joins in 7 days');
  await expectNoSideScroll(page);
  expect(Number(await page.getByTestId('kpi-mine').locator('.stat-val').innerText())).toBeGreaterThanOrEqual(205);   // the importer owns them
  await page.getByRole('button', { name: 'Next' }).click();
  await expect(page.getByTestId('pager-text')).toHaveText('Page 2 of 5 · 205 people');
  await page.getByRole('button', { name: 'Previous' }).click();
  await page.locator('#jf-q').fill(`Z${u}`);
  await expect(page.getByTestId('pipeline-row')).toHaveCount(5);
  await expect(page.getByTestId('pipeline-row').first().getByTestId('pipeline-when')).toHaveText(/^joining date: /);   // H1: joining today
  await page.locator('#jf-q').fill('');
  await expect(page.getByTestId('pipeline-row')).toHaveCount(50);
  await page.getByTestId('select-page').check();
  await timed('invite links for 50 people (screen)', async () => {
    await page.getByTestId('bulk-invite').click();
    await expect(page.getByTestId('invite-row')).toHaveCount(50, { timeout: 60_000 });
  });
  // the local stack has a mail stand-in (a sender is "set up"): each link also went by email; on the practice system,
  // with no sender, the same screen says so and the links are copied by hand
  await expect(page.getByTestId('invite-results')).toContainText('Emailed to 50 of them');
  await expect(page.locator('[data-testid="invite-row"][data-sent="email"]')).toHaveCount(50);
  await expectNoSideScroll(page);
  const link = await page.getByTestId('invite-link').first().inputValue();
  const who = (await page.getByTestId('invite-row').first().locator('strong').innerText()).trim();
  expect(link).toMatch(/\/invite#[A-Za-z0-9_-]{43}$/);
  await page.getByTestId('bulk-clear').click();

  // one joiner opens the link on a phone and chooses a password: signed in, on their checklist
  const phone = await browser.newContext({ viewport: { width: 390, height: 844 } });
  try {
    const p = await phone.newPage();
    await p.goto(`/invite${new URL(link).hash}`);
    await expect(p.getByTestId('invite-hello')).toContainText(who.split(' ')[0]);
    expect(new URL(p.url()).hash).toBe('');                                    // the token left the address bar at once
    const pw = `Gv-${Math.random().toString(36).slice(2)}${Math.random().toString(36).slice(2)}`;
    await p.getByTestId('invite-pw').fill(pw);
    await p.getByTestId('invite-pw2').fill(pw);
    await p.getByTestId('invite-submit').click();
    await expect(p.getByTestId('joiner-home').or(p.getByTestId('checklist')).first()).toBeVisible({ timeout: 30_000 });
    await expectNoSideScroll(p);
    // the same link a second time: used
    const again = await phone.newPage();
    await again.goto(`/invite${new URL(link).hash}`);
    await expect(again.getByTestId('invite-dead')).toBeVisible();
  } finally { await phone.close(); }
  await page.locator('#jf-q').fill(who);
  await expect(page.getByTestId('pipeline-row')).toHaveCount(1);
  await expect(page.getByTestId('pipeline-invite')).toHaveText('invite accepted');
  await page.locator('#jf-q').fill('');

  // ── D. The gate: a full-time joiner's statutory step blocks Mark as joined until HR records it; then the page says so at once
  await page.locator('#jf-q').fill(`Z${u} 1`);
  await page.getByTestId('pipeline-row').getByRole('link').click();
  await expect(page.getByTestId('gate-statutory')).toBeVisible();
  await expect(page.getByTestId('activate')).toBeDisabled();
  await expectNoSideScroll(page);
  await markJoined(page, 'Joined on the day; forms follow by Friday');
  await expect(page.getByTestId('joined-now')).toBeVisible();                 // G2: no reload needed
  await expect(page.locator('main p.row').first()).toContainText('Active');

  // ── E. Mark as joined for many at once, through the same gate: the full-time ones are refused (statutory open), a whole
  //       page of contract operators is marked with one reason (each one logged)
  await page.goto(`/hr?opening=${op.id}&status=joining`);
  await page.locator('#jf-q').fill(`Z${u}`);
  await expect(page.getByTestId('pipeline-row')).toHaveCount(4);
  await page.getByTestId('select-page').check();
  await page.getByTestId('bulk-join').click();
  await page.getByTestId('bulk-reason').fill('Joined on the day, papers follow');
  await page.getByTestId('bulk-go').click();
  await expect(page.getByTestId('bulk-outcome')).toContainText('Done for 0 of 4.');
  await expect(page.getByTestId('bulk-outcome')).toContainText('a statutory step is still open');
  await page.getByTestId('bulk-clear').click();
  await page.locator('#jf-q').fill(`A${u}`);
  await expect(page.getByTestId('pager-text')).toHaveText('Page 1 of 4 · 200 people');
  await page.getByTestId('select-page').check();
  await page.getByTestId('bulk-join').click();
  await page.getByTestId('bulk-reason').fill('Joined on the day, papers follow');
  await timed('mark as joined, 50 people (screen)', async () => {
    await page.getByTestId('bulk-go').click();
    await expect(page.getByTestId('bulk-outcome')).toHaveText('Done for 50 of 50.', { timeout: 60_000 });
  });
  await expect(page.getByTestId('pager-text')).toHaveText('Page 1 of 3 · 150 people');   // the list is asked again
  await page.goto('/hr/openings');
  expect(await n('joined')).toBe(51);
  expect(await n('joining')).toBe(154);
  expect(await n('waiting_wave')).toBe(51);                                  // "joined, waiting for their wave"
  expect(await n('ready')).toBe(0);                                         // the scope is still a draft
  expect(await n('assigned')).toBe(0);
  // Hindi, on the phone
  await page.getByLabel('Language').selectOption('hi');
  await expect(page.getByRole('heading', { level: 1 })).toContainText(hi['open.title']);
  await expectNoSideScroll(page);
  await page.getByLabel('Language').selectOption('en');
  await signOut(page);

  // ── F. The Client Manager staffs the draft from the joined people, activates it: the rest are "ready to assign", and
  //       40 of them get Procurement in one act (one log line per person)
  await signIn(page, USERS.cm);
  await page.goto(`/scopes/${scopeId}?step=people`);
  for (const [k, label] of [['050', 'Assign Procurement (farm-gate)'], ['049', 'Assign Quality Control'], ['048', 'Assign QR Activation (seal)']] as const) {
    await page.getByTestId('roster-find').fill(`A${u} ${k}`);
    await expect(page.getByLabel(label).locator('option', { hasText: `A${u} ${k}` })).toHaveCount(1);
    // migration 46: joined on this scope's opening, they come first in the pool, marked with the stage they were hired for
    await page.getByLabel(label).selectOption({ label: `Scale A${u} ${k} · ready for Procurement (farm-gate)` });
    await expect(page.getByTestId('slots').getByRole('link', { name: `Scale A${u} ${k}` })).toBeVisible();
  }
  await expect(page.getByTestId('roster-covered')).toBeVisible();
  // (the joined people are offered on a draft's roster too: that is how a draft is staffed before it is activated;
  //  the opening counts them as "ready" only once the scope is active)
  page.once('dialog', (d) => d.accept());
  await page.getByRole('button', { name: 'Activate scope' }).click();
  await expect(page.getByRole('heading', { name: new RegExp(`Scale ${u}`) })).toContainText('Active');
  await page.reload();
  const ready = page.getByTestId('ready-to-assign');
  await expect(ready).toBeVisible();
  await ready.getByTestId('ready-stage').selectOption('procurement');
  const ours = ready.locator('li').filter({ hasText: op.code });
  await expect(ours).toHaveCount(48);
  for (let i = 0; i < 40; i++) await ours.nth(i).getByTestId('ready-person').check();
  await expect(ready.locator('[data-testid="ready-person"]:checked')).toHaveCount(40);
  await timed('assign 40 people to one stage (screen)', async () => {
    await ready.getByTestId('ready-assign').click();
    await expect(ready.getByTestId('bulk-outcome')).toHaveText('Done for 40 of 40.', { timeout: 60_000 });
  });
  await expect(ready.locator('li').filter({ hasText: op.code })).toHaveCount(8);
  await expect(page.getByTestId('slot-holder-procurement')).toHaveCount(41);
  await expectNoSideScroll(page);
  await signOut(page);

  // ── G. The numbers: the opening, HR's totals and the admin's overview agree
  await signIn(page, USERS.hr);
  await page.goto('/hr/openings');
  expect(await n('assigned')).toBe(43);                                      // 40 + the three who staffed the draft
  expect(await n('waiting_wave')).toBe(0);                                  // the scope is active: nobody waits for a wave
  expect(await n('ready')).toBe(8);                                         // the same 8 the roster offers
  expect(await n('joined')).toBe(51);
  expect(await n('vacant')).toBe(0);
  const totals: Record<string, number> = {};
  for (const k of ['positions', 'joining', 'joined', 'assigned', 'waiting_wave', 'ready', 'vacant']) totals[k] = await num(page, `overall-${k}`);
  await signOut(page);
  await signIn(page, USERS.admin);
  await expect(page.getByTestId('ov-openings')).toBeVisible();
  for (const [k, v] of Object.entries(totals)) await expect(page.getByTestId(`ov-open-${k}`), k).toHaveText(String(v));
  const audit = await (await apiAs(page)).rpc('audit_page', { p: { action: 'assigned', q: `A${u}`, limit: 100 } });
  expect((audit.data as { total: number }).total, JSON.stringify(audit.data).slice(0, 200)).toBe(43);   // one log line per person
  await signOut(page);
  console.log(`TIMINGS\n${timings.join('\n')}`);
});
