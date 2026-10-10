// Decision G8 = B (4 October 2026): the prototype's frame, first screens, form sections and status words, on a laptop
// and on a phone. The other spec files run at phone size; this one sets its own sizes.
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, USERS, SCOPES, procure, recordQc, sealLot, apiAs } from './helpers';

const LAPTOP = { viewport: { width: 1366, height: 768 }, isMobile: false, hasTouch: false, deviceScaleFactor: 1 } as const;
const noSideScroll = (page: Page, what: string) => expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth),
  { message: `${what}: px wider than the window` }).toBeLessThanOrEqual(0);
const box = async (page: Page, sel: ReturnType<Page['locator']>) => (await sel.boundingBox())!;

test.describe('on a laptop', () => {
  test.use(LAPTOP);

  test('The frame: top bar, side menu in sections, and no page wider than the window', async ({ page }) => {
    test.setTimeout(120_000);
    await signIn(page, USERS.cm);
    const nav = page.getByRole('navigation', { name: 'Main' });
    const top = page.locator('header.topbar');
    // the menu is a column down the left, 220 px wide, under the top bar; the content is beside it
    const n = await box(page, nav); const m = await box(page, page.locator('main')); const tb = await box(page, top);
    expect(Math.round(n.width)).toBe(220); expect(n.x).toBe(0);
    expect(m.x).toBeGreaterThanOrEqual(220); expect(n.y).toBeGreaterThanOrEqual(tb.y + tb.height - 1);
    expect(Math.round(tb.height), 'top bar, px').toBeLessThanOrEqual(56);
    for (const s of ['Overview', 'Registry', 'People', 'System', 'Support']) await expect(nav.getByText(s, { exact: true })).toBeVisible();
    for (const l of ['Dashboard', 'Farmers', 'Season Scopes', 'People & access', 'Flags & Disputes', 'My account']) await expect(nav.getByRole('link', { name: l })).toBeVisible();
    await expect(nav.getByRole('link', { name: 'Crop Registry' })).toHaveCount(0);          // an admin's item
    await expect(nav.getByRole('link', { name: 'HR · Joiners' })).toHaveCount(0);           // HR's item: a manager assigns people, HR makes them
    // who, for whom
    await expect(page.getByTestId('tb-context')).toHaveText('GrainVeda (Prasaadam trade scope)');
    await expect(page.getByTestId('whoami')).toContainText('Prasaadam Client Manager');
    await expect(page.getByTestId('whoami')).toContainText('Client Manager');
    await expect(top.getByRole('link', { name: 'My account' })).toHaveText('PC');           // initials
    // every kind of page fits the window
    await noSideScroll(page, 'dashboard');
    for (const [name, heading] of [['Farmers', 'Farmers'], ['Season Scopes', 'Season Scopes'], ['People & access', 'People & access'], ['Flags & Disputes', 'Flags & Disputes'], ['My account', 'My account']] as const) {
      await nav.getByRole('link', { name }).click();
      await expect(page.getByRole('heading', { level: 1, name: heading })).toBeVisible();
      await expect(nav.getByRole('link', { name })).toHaveClass(/active/);
      await noSideScroll(page, name);
    }
    await signOut(page);
    await signIn(page, USERS.admin);
    // the admin's own menu, by heading (migration 35, brief part 3)
    for (const h of ['Watch', 'Audit', 'Access', 'Me']) await expect(nav.getByText(h, { exact: true })).toBeVisible();
    await expect(nav.getByText(/^Master data/)).toContainText('read-only, States apart');
    for (const l of ['Overview', 'Pipeline', 'Clients', 'Crops', 'States', 'Health', 'State overview', 'Seats', 'Ledger', 'Audit log', 'My guide', 'Help']) await expect(nav.getByRole('link', { name: l, exact: true })).toBeVisible();
    for (const path of ['/', '/pipeline', '/help']) { await page.goto(path); await expect(page.getByRole('heading', { level: 1 })).toBeVisible(); await noSideScroll(page, `admin ${path}`); }
    await expect(nav.getByRole('link', { name: 'HR · Joiners' })).toHaveCount(0);         // the HR Admin seat is filled: HR adds people
    await signOut(page);
  });

  test('Scope selector: overall, then one scope with its figures, action queue, season flow and stages in the menu', async ({ page }) => {
    test.setTimeout(180_000);
    // something to count: one lot bought and not yet verified, one taken to the seal
    await signIn(page, USERS.procurement);
    await page.getByTestId('scope-switcher').selectOption(SCOPES.siddharthnagar);          // an operator narrows the first screen the same way
    await expect(page.getByTestId('slot-procurement')).toHaveCount(1);
    await expect(page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Procurement (farm-gate)' })).toBeVisible();
    const done = await procure(page, SCOPES.siddharthnagar, 'Sita Devi', '150', '1', '2.5');
    await page.getByRole('link', { name: '← Back to dashboard' }).click();
    const waiting = await procure(page, SCOPES.siddharthnagar, 'Ram Achal', '120', '2', '1');
    await signOut(page);
    await signIn(page, USERS.qc); const q = await recordQc(page, SCOPES.siddharthnagar, done, '11.9'); await signOut(page);
    await signIn(page, USERS.qr); await sealLot(page, SCOPES.siddharthnagar, q); await signOut(page);

    await signIn(page, USERS.cm);
    const nav = page.getByRole('navigation', { name: 'Main' });
    const pick = page.getByTestId('scope-switcher');
    // overall: every scope as a card, no stage in the menu
    await expect(pick).toHaveValue('');
    const api = await apiAs(page);
    const mine = ((await api.rpc('my_context')).data as { scopes: unknown[] }).scopes.length;       // what the server says this person can read
    expect(mine).toBeGreaterThanOrEqual(6);
    await expect(page.locator('.scope-card')).toHaveCount(mine);
    await expect(page.getByTestId('stats')).toContainText('Active scopes');
    await expect(nav.getByText('Operations', { exact: true })).toHaveCount(0);
    // one scope
    await pick.selectOption(SCOPES.siddharthnagar);
    await expect(page.getByRole('heading', { level: 1 })).toHaveText('Kalanamak rice · KH26 · Siddharthnagar');
    await expect(nav.getByText('Operations', { exact: true })).toBeVisible();
    for (const s of ['Procurement (farm-gate)', 'Quality Control', 'QR Activation (seal)']) await expect(nav.getByRole('link', { name: s })).toBeVisible();
    // the figures are the database's own (app.pipeline_summary), not the screen's
    const rows = (await api.rpc('pipeline_summary', { p_scope: SCOPES.siddharthnagar })).data as { stage: string; pending: number; verified: number; records: number; kg_out: number }[];
    const first = rows.find((r) => r.stage === 'procurement')!; const qr = rows.find((r) => r.stage === 'qr_activation')!;
    const pending = rows.filter((r) => r.stage !== 'qr_activation').reduce((s, r) => s + Number(r.pending), 0);
    expect(pending).toBeGreaterThanOrEqual(1); expect(Number(qr.records)).toBeGreaterThanOrEqual(1);
    const stats = page.getByTestId('stats').locator('.stat');
    await expect(stats).toHaveCount(4);
    const kgText = (n: number) => n.toLocaleString('en-IN', { maximumFractionDigits: 3 });
    await expect(stats.nth(0)).toContainText(`${kgText(Number(first.kg_out))} kg`);
    await expect(stats.nth(3).locator('.stat-val')).toHaveText(String(qr.records));
    await expect(page.getByTestId('action-queue')).toContainText(`${pending} record(s) waiting to be verified by the next stage`);
    // the card and the queue's title count the same things (10 Oct 2026: the card said 4, the title "(1)")
    const queued = (await stats.nth(1).locator('.stat-val').textContent())!.trim();
    await expect(page.getByTestId('action-queue').locator('h2')).toHaveText(`Your action queue (${queued})`);
    const flow = page.getByTestId('season-flow').locator('li');
    await expect(flow).toHaveCount(3);
    await expect(flow.nth(0)).toContainText(`✓ ${first.verified}`);
    await expect(flow.nth(0)).toContainText(`${first.pending} pending`);
    await expect(page.getByTestId('team-table')).toContainText('Procurement Op (field)');
    await expect(page.getByTestId('team-table')).toContainText('Verify Procurement (farm-gate)');
    // the flow leads to the stage; the lot that waits is there
    await flow.nth(0).getByRole('link').click();
    await expect(page.getByRole('heading', { level: 1, name: 'Procurement (farm-gate)' })).toBeVisible();
    await expect(page.locator('main')).toContainText(waiting);
    await expect(nav.getByRole('link', { name: 'Procurement (farm-gate)' })).toHaveClass(/active/);
    // the choice is kept on this computer
    await page.reload();
    await expect(pick).toHaveValue(SCOPES.siddharthnagar);
    await pick.selectOption('');
    await expect(page.locator('.scope-card')).toHaveCount(mine);
    await expect(nav.getByText('Operations', { exact: true })).toHaveCount(0);
    await signOut(page);
  });

  test('A stage form is in two columns under section headings; lists and pickers take the whole width', async ({ page }) => {
    await signIn(page, USERS.procurement);
    await expect(page.getByTestId('work-picker')).toBeVisible();                           // five scopes: the first screen asks where
    await page.goto(`/work/${SCOPES.siddharthnagar}/procurement`);                         // a stage opened by its address, with no place chosen
    await page.getByPlaceholder('Name, Farmer ID, phone or village').fill('Sita');
    await page.getByRole('button', { name: /Sita Devi/ }).click();
    const form = page.locator('form');
    await expect(form.locator('.form-section h3')).toHaveText([/Farmer/, /Weighing/, /Moisture readings/, /Evidence/]);
    const gross = await box(page, page.getByLabel(/Gross weight/)); const bags = await box(page, page.getByLabel(/^Bags/)); const tare = await box(page, page.getByLabel(/Tare per bag/));
    expect(Math.abs(gross.y - bags.y), 'gross weight and bags on one line').toBeLessThan(2);
    expect(bags.x).toBeGreaterThan(gross.x + gross.width);
    expect(tare.y).toBeGreaterThan(gross.y + gross.height - 1);
    expect(Math.abs(tare.x - gross.x)).toBeLessThan(2);
    const m1 = await box(page, page.getByLabel('Moisture (3 readings) 1')); const m3 = await box(page, page.getByLabel('Moisture (3 readings) 3'));
    expect(m3.x + m3.width - m1.x, 'the three readings span both columns').toBeGreaterThan(gross.width * 1.8);
    await expect(page.locator('.sign-banner')).toContainText('Signed by Procurement Op (field)');
    await noSideScroll(page, 'procurement form');
    // nothing was chosen ("Overall"), yet this form belongs to one scope: the top bar and the menu say which
    const nav = page.getByRole('navigation', { name: 'Main' });
    await expect(page.getByTestId('scope-switcher')).toHaveValue(SCOPES.siddharthnagar);
    await expect(nav.getByRole('link', { name: 'Procurement (farm-gate)' })).toHaveClass(/active/);
    await page.getByRole('link', { name: '← Back to dashboard' }).click();
    await expect(page.getByTestId('scope-switcher')).toHaveValue('');                      // the choice itself did not change
    // someone who holds stages in five scopes works in one at a time: with none chosen, the first screen asks which
    await expect(page.getByTestId('work-picker').getByTestId('pick-scope')).toHaveCount(5);
    await expect(nav.getByText('Operations', { exact: true })).toHaveCount(0);
    await signOut(page);
  });

  test('Sign-in screen: the dark card, the company line, where to turn for a forgotten password', async ({ page }) => {
    await page.goto('/');
    const card = page.locator('.signin-box');
    await expect(card.getByRole('heading', { name: 'Sign in' })).toBeVisible();
    await expect(card).toContainText('Controlled Traceability Platform');
    await expect(card).toContainText('Forgot your password? Ask HR to reset it.');           // HR resets passwords since the identity layer
    await expect(card).toContainText('GrainVeda Private Limited');
    const b = await box(page, card);
    expect(b.width).toBeLessThanOrEqual(380);
    expect(Math.abs(b.x + b.width / 2 - 1366 / 2), 'centred').toBeLessThan(12);
    expect(await card.evaluate((e) => getComputedStyle(e).backgroundColor)).toBe('rgb(26, 51, 25)');   // the prototype's --g700
  });
});

test.describe('on a phone', () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test('The same screens fold to one column: scope selector on the first screen, sections stacked, cards compact', async ({ page }) => {
    await signIn(page, USERS.procurement);
    // stages held in five scopes: the first screen asks where he is working now (one scope at a time), one tap each
    await expect(page.getByTestId('work-picker').getByTestId('pick-scope')).toHaveCount(5);
    await expect(page.locator('.stage-card')).toHaveCount(0);
    await expect(page.locator('header.topbar').getByTestId('scope-switcher')).toHaveCount(0);      // not in the top bar
    await noSideScroll(page, 'where are you working');
    await page.locator(`[data-testid="pick-scope"][data-scope="${SCOPES.siddharthnagar}"]`).click();
    await expect(page.locator('.stage-card')).toHaveCount(1);
    await page.getByTestId('change-scope').click();                                              // and changing is one tap
    await expect(page.getByTestId('work-picker')).toBeVisible();
    await page.locator('main').getByTestId('scope-switcher').waitFor({ state: 'detached' });
    await page.locator(`[data-testid="pick-scope"][data-scope="${SCOPES.siddharthnagar}"]`).click();
    await expect(page.getByText('My recent records')).toBeVisible();
    await noSideScroll(page, 'operator first screen');
    await page.getByTestId('slot-procurement').click();
    await page.getByPlaceholder('Name, Farmer ID, phone or village').fill('Sita');
    await page.getByRole('button', { name: /Sita Devi/ }).click();
    const gross = await box(page, page.getByLabel(/Gross weight/)); const bags = await box(page, page.getByLabel(/^Bags/));
    expect(bags.y, 'one column: bags under gross weight').toBeGreaterThan(gross.y + gross.height - 1);
    await expect(page.locator('form .form-section h3').first()).toContainText('Farmer');
    await noSideScroll(page, 'procurement form');
    await signOut(page);
    await signIn(page, USERS.cm);
    await page.locator('main').getByTestId('scope-switcher').selectOption(SCOPES.siddharthnagar);
    await expect(page.getByTestId('season-flow').locator('li')).toHaveCount(3);
    await noSideScroll(page, 'manager first screen');
    await signOut(page);
  });
});

test('Status chips carry the prototype\'s words: pending verification, then approved', async ({ page }) => {
  await signIn(page, USERS.procurement);
  const p = await procure(page, SCOPES.siddharthnagar, 'Mohan Lal', '90', '1', '1');
  await page.getByRole('link', { name: `Open ${p}` }).click();
  await expect(page.locator('main .badge').first()).toHaveText('Pending verification');
  const url = page.url();
  await signOut(page);
  await signIn(page, USERS.qc); await recordQc(page, SCOPES.siddharthnagar, p, '11.9');
  await signOut(page);
  await signIn(page, USERS.cm);
  await page.goto(url);
  await expect(page.locator('main .badge').first()).toHaveText('Approved');
  await signOut(page);
});
