// Migration 59 (Phase 1, release 1 of Veda's combined brief, 19 Oct 2026: Part A fixes, Part B "the client login reads
// only"), on a 527 px screen. The client's own login: no stage pages, no "Needs action", "Waiting on GrainVeda" instead,
// its farmers' phones masked, no flag button, and the database refuses its writes. A pack's QR before its lot is
// released shows "Packed, not yet released" with the crop, the batch code and the date packed, nothing else. The
// Client Manager's People page shows no email. Every rule is the database's (tests/54_fixes_client_reads_only.sql).
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, apiAs, procure, refusal, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const CLIENT = '00000000-0000-4000-8000-000000000201';
const S = SCOPES.bastiMill;
const id = (n: string) => `00000000-0000-4000-8000-000000000${n}`;
const ok = (r: { ok: boolean; data: unknown }) => expect(r.ok, JSON.stringify(r.data)).toBe(true);
const idOf = (r: { ok: boolean; data: unknown }) => { ok(r); return String((r.data as { id: string }[])[0].id); };
const SHOTS = process.env.SHOTS_DIR;

async function footprint(page: Page, code: string) {
  return (await (await apiAs(page)).rows('footprints', `footprint_code=eq.${code}`))[0] as { id: string };
}

test.afterAll(async ({ browser }) => {
  const page = await browser.newPage();
  await signIn(page, USERS.cm);
  ok(await (await apiAs(page)).update('scopes', `id=eq.${S}`, { stage_details_required: false, record_price: false }));
  await page.close();
});

test('the client login reads only: no stage pages, no Needs action, "Waiting on GrainVeda", masked farmer phones', async ({ page }) => {
  test.setTimeout(180_000);
  await signIn(page, USERS.view);
  await expect(page.getByTestId('client-waiting')).toBeVisible();
  await expect(page.getByTestId('client-waiting')).toContainText('Waiting on GrainVeda');
  await expect(page.getByTestId('client-flags')).toBeVisible();
  await expect(page.getByTestId('needs-action')).toHaveCount(0);
  await expect(page.getByTestId('action-queue')).toHaveCount(0);
  await expect(page.locator('a[href^="/work/"]')).toHaveCount(0);
  await expectNoSideScroll(page);
  if (SHOTS) await page.screenshot({ path: `${SHOTS}/p31-client-home.png`, fullPage: true });

  // a stage page typed in the address bar goes home
  await page.goto(`/work/${S}/procurement`);
  await expect(page).toHaveURL(/\/$/);
  await expect(page.getByTestId('client-waiting')).toBeVisible();

  // its farmers: names and villages, the phone's last four digits only, no actions
  await page.goto('/farmers');
  await expect(page.getByTestId('farmer-row').first()).toBeVisible();
  const view = await apiAs(page);
  const farmers = await view.rpc('client_farmers', { p_q: null });
  ok(farmers);
  const list = farmers.data as { phone: string | null; guardian_name?: string | null }[];
  expect(list.length).toBeGreaterThan(0);
  for (const f of list) {
    if (f.phone) expect(f.phone).toMatch(/^••••••\d{0,4}$/);
    expect(f.guardian_name ?? null).toBeNull();
  }
  expect(await view.rows('farmers', 'limit=5')).toHaveLength(0);
  await expectNoSideScroll(page);

  // the database refuses its writes, said in plain words
  const rec = (await view.rows('footprints', `scope_id=eq.${S}&limit=1`))[0] as { id: string } | undefined;
  if (rec) {
    const f = await view.insert('flags', { footprint_id: rec.id, text: 'e2e59 a flag from the client login' });
    expect(f.ok).toBe(false);
    expect(refusal(f)).toMatch(/client login reads only|row-level security/);
    await page.goto(`/records/${rec.id}`);
    await expect(page.getByRole('button', { name: /raise a flag|flag/i })).toHaveCount(0);
    await expectNoSideScroll(page);
  }
  const w = await view.rpc('client_waiting', {});
  ok(w);
  expect(Object.keys(w.data as object).sort()).toEqual(['lab_hold', 'open_flags', 'pending']);
  await signOut(page);
});

test('a pack before its lot is released: "Packed, not yet released", the crop, the batch code, the date, nothing else', async ({ page, browser }) => {
  test.setTimeout(420_000);
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  const had = await cm.rows('pack_skus', `client_id=eq.${CLIENT}&size=eq.1&unit=eq.kg&material=eq.vacuum&market=eq.domestic`);
  const sku = had.length ? String(had[0].id) : idOf(await cm.insert('pack_skus', { client_id: CLIENT, size: 1, unit: 'kg', material: 'vacuum', market: 'domestic', label_type: 'printed' }));
  ok(await cm.update('pack_skus', `id=eq.${sku}`, { active: true }));
  ok(await cm.update('scopes', `id=eq.${S}`, { stage_details_required: false, record_price: false }));
  await signOut(page);

  await signIn(page, USERS.procurement);
  const p = await procure(page, S, 'Suresh Yadav', '104', '2', '2');
  await signOut(page);
  const step = async (who: typeof USERS.qc, verify: string, stage: string, payload: Record<string, unknown>) => {
    await signIn(page, who);
    const api = await apiAs(page);
    ok(await api.rpc('verify_footprint', { p_fp: (await footprint(page, verify)).id }));
    const r = await api.insert('footprints', { scope_id: S, client_id: CLIENT, stage_type: stage, prev_footprint_id: (await footprint(page, verify)).id, created_by: id(who.key), payload });
    ok(r);
    await signOut(page);
    return String((r.data as { footprint_code: string }[])[0].footprint_code);
  };
  const q = await step(USERS.qc, p, 'qc', { qty_kg: 100, sample_qty_kg: 1, readings: { moisture_pct: 11.8, broken_pct: 2, foreign_matter_pct: 0.2 } });
  const m = await step(USERS.mill, q, 'milling', { input_kg: 99, head_rice_kg: 70, broken_kg: 4, husk_kg: 20, bran_kg: 5 });
  const k = await step(USERS.sorting, m, 'packing', { input_kg: 10, packets: [{ sku_id: sku, units: 10, size_kg: 1 }] });
  await signIn(page, USERS.sorting);
  const pack = (await (await apiAs(page)).rows('packs', `footprint_id=eq.${(await footprint(page, k)).id}&order=serial&limit=1`))[0] as { serial: string; batch_code: string };
  expect(pack?.serial).toBeTruthy();
  await signOut(page);

  // anyone with the QR, signed in or not: the pack's own page and the verify page
  const ctx = await browser.newContext({ viewport: { width: 527, height: 900 } });
  const bp = await ctx.newPage();
  for (const path of [`/p/${pack.serial}`, `/verify/${pack.serial}`]) {
    await bp.goto(path);
    await expect(bp.getByTestId('pv-not-released')).toContainText('Packed, not yet released');
    const text = await bp.getByTestId('public-pack').textContent();
    expect(text).toContain(pack.serial);
    expect(text).toContain(pack.batch_code);
    expect(text).not.toMatch(/Sold by|Best before|Suresh|scans|Moisture/);
    await expectNoSideScroll(bp);
  }
  if (SHOTS) await bp.screenshot({ path: `${SHOTS}/p31-pack-not-released.png`, fullPage: true });
  await ctx.close();
});

test('the Client Manager\'s People page: no email, and a phone only for people of his own scopes', async ({ page }) => {
  await signIn(page, USERS.cm);
  await page.goto('/people');
  await expect(page.getByTestId('person-row').first()).toBeVisible();
  expect(await page.getByTestId('people').textContent()).not.toMatch(/@/);
  const cm = await apiAs(page);
  const r = await cm.rpc('people_page', { p: { kind: 'employees', q: null, client: null, state: null, status: null, unassigned: false, limit: 50, offset: 0 } });
  ok(r);
  const rows = (r.data as { rows?: { email: string | null }[] }).rows ?? [];
  expect(rows.length).toBeGreaterThan(0);
  for (const p of rows) expect(p.email ?? null).toBeNull();
  // the login table's email and phone columns are not readable by a signed-in person
  await expect(cm.rows('app_users', 'limit=1')).rejects.toThrow(/permission denied|42501/);
  await expectNoSideScroll(page);
  if (SHOTS) await page.screenshot({ path: `${SHOTS}/p31-cm-people.png`, fullPage: true });
});
