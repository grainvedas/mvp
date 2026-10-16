// Migration 55 (Veda, 16 Oct 2026, "yes proceed": the operator-stages brief, release 8, C3), on a 527 px screen. The
// Client Manager chooses a Warehouse when he builds a scope (right after the Collection Batch); the Warehouse person
// checks the batch in and records its arrival: what was sent (taken from the lot), what was received, the reason for
// the difference (above 2 % a flag for the manager), the condition, the bags, the place and stack. The record page shows
// the days in storage, the bags and the inspections; an inspection that found anything says what; the Client Manager
// sets the interval and an inspection that is due shows in "Needs my action". Milling records the bags out and takes
// the lot. Every rule is the database's (tests/49_warehouse.sql).
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, apiAs, openSlot, verifyIncoming, reviewAndSave, procure, USERS } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const uniq = () => String(Date.now()).slice(-6);
const CLIENT = '00000000-0000-4000-8000-000000000201';
const KALANAMAK = '00000000-0000-4000-8000-000000000101';
const id = (n: string) => `00000000-0000-4000-8000-000000000${n}`;
const ok = (r: { ok: boolean; data: unknown }) => expect(r.ok, JSON.stringify(r.data)).toBe(true);
let testScope: string | null = null;
const madeScope = (id: string) => { testScope = id; };

/** The people of the test's scope are taken off it again, whatever happened: other tests count a person's stages (T5:
 *  the Grading operator holds one) and open a person's only stage directly. */
test.afterAll(async ({ browser }) => {
  if (!testScope) return;
  const page = await browser.newPage();
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  for (const a of await cm.rows('assignments', `scope_id=eq.${testScope}&active=eq.true`)) ok(await cm.rpc('end_assignment', { p_assignment: a.id, p_reason: 'e2e phase27: the test scope is done' }));
  expect(await cm.rows('assignments', `scope_id=eq.${testScope}&active=eq.true`)).toHaveLength(0);
  await page.close();
});

async function footprint(page: Page, code: string) {
  return (await (await apiAs(page)).rows('footprints', `footprint_code=eq.${code}`))[0] as { id: string; qty_in: number; qty_out: number; computed: Record<string, unknown>; status: string };
}

test('C3: a scope with a Warehouse; the arrival, its flag, an inspection, the interval, bags out and Milling', async ({ page }) => {
  test.setTimeout(420_000);
  const u = uniq();
  const GEO = `Bansi godown ${u}`;
  // the Client Manager builds the scope: the Warehouse right after the Collection Batch (the wizard's chain step)
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  const made = await cm.insert('scopes', { client_id: CLIENT, crop_id: KALANAMAK, season_code: 'KH26', geography: GEO,
    chain: ['procurement', 'village_batch', 'milling', 'qc', 'qr_activation'], status: 'draft',
    procurement_details_required: false, stage_details_required: false, qc_report_required: false });
  ok(made);
  const scope = (made.data as { id: string }[])[0].id;
  madeScope(scope);
  await page.goto(`/scopes/${scope}?step=chain`);
  await expect(page.getByTestId('chain-preview')).toContainText('Procurement (farm-gate) → Collection Batch');
  await expect(page.getByTestId('chain-preview')).not.toContainText('Warehouse');
  await page.getByTestId('wz-warehouse').check();
  await expect(page.getByTestId('chain-preview')).toContainText(/Collection Batch[^→]*→ Warehouse → Milling/);
  await expect(page.locator('.alert.ok', { hasText: 'This chain is valid.' })).toBeVisible();
  await expectNoSideScroll(page);
  await page.getByRole('button', { name: /Save draft/ }).click();
  await expect(page.locator('.stepper [aria-current="step"]')).toContainText('4');
  expect((await cm.rows('scopes', `id=eq.${scope}`))[0].chain).toEqual(['procurement', 'village_batch', 'warehouse', 'milling', 'qc', 'qr_activation']);
  for (const [who, st] of [['305', 'procurement'], ['315', 'village_batch'], ['310', 'warehouse'], ['308', 'milling'], ['306', 'qc'], ['307', 'qr_activation']] as const)
    ok(await cm.rpc('assign', { p_employee: id(who), p_lens: 'scope', p_target: scope, p_op_role: 'operator', p_stages: [st], p_posting: '', p_ends_on: null }));
  ok(await cm.update('scopes', `id=eq.${scope}`, { status: 'active' }));
  await signOut(page);

  // two lots at the farm gate, and their Collection Batch (by API: their forms are tested in phase24 and phase26)
  await signIn(page, USERS.procurement);
  const p1 = await procure(page, scope, 'Suresh Yadav', '102', '2', '1');
  const p2 = await procure(page, scope, 'Ram Achal', '102', '2', '1');
  await signOut(page);
  await signIn(page, USERS.villageBatch);
  const vbApi = await apiAs(page);
  const l1 = await footprint(page, p1), l2 = await footprint(page, p2);
  for (const l of [l1, l2]) ok(await vbApi.rpc('verify_footprint', { p_fp: l.id }));
  const vbr = await vbApi.insert('footprints', { scope_id: scope, client_id: CLIENT, stage_type: 'village_batch', prev_footprint_id: l1.id, created_by: id('315'),
    payload: { source_footprint_ids: [l1.id, l2.id] } });
  ok(vbr);
  const vb = String((vbr.data as { footprint_code: string }[])[0].footprint_code);
  expect(Number((await footprint(page, vb)).qty_out)).toBe(200);
  await signOut(page);

  // the Warehouse checks the batch in and records its arrival: 200 kg sent, 194 kg received (3 %): a reason, a flag
  await signIn(page, USERS.grading);
  await openSlot(page, 'warehouse', scope);
  await verifyIncoming(page, vb);
  await page.getByRole('button', { name: /Record Warehouse for this lot/ }).click();
  await expect(page.locator('[data-section="arrival"]')).toBeVisible();
  await expect(page.getByLabel(/^Sent \(what the lot holds\)/)).toHaveValue('200');
  await page.getByLabel(/^Received \(weighed here\)/).fill('194');
  await page.getByLabel(/^Condition on arrival/).selectOption('good');
  await page.getByLabel(/^Bags in/).fill('4');
  await page.getByLabel(/^Warehouse or location/).fill('Bansi godown 2');
  await page.getByLabel(/^Stack or row/).fill('S-3');
  await expect(page.getByTestId('preview-error')).toContainText('Say why 6 kg less was received than sent');
  await page.getByLabel(/^Why less was received/).fill('dried in the sun on the way');
  await expect(page.getByTestId('preview-ok')).toContainText('194 kg');
  await expectNoSideScroll(page);
  const wh = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?WH-\d{4}/);
  const whRow = await footprint(page, wh);
  expect(whRow.computed).toMatchObject({ discrepancy_kg: 6, discrepancy_pct: 3, condition: 'good', bags_in: 4, location: 'Bansi godown 2', stack: 'S-3' });
  // the record page: the difference, the flag, the days, the bags
  await page.goto(`/records/${whRow.id}`);
  await expect(page.locator('[data-computed="discrepancy_kg"]')).toHaveText('6 kg');
  await expect(page.locator('[data-computed="discrepancy_pct"]')).toHaveText('3 %');
  await expect(page.locator('.alert.warn')).toContainText('flagged for the manager');
  await expect(page.getByText(/Warehouse: received 194 kg, 3 % less than was sent \(200 kg\)/)).toBeVisible();
  const panel = page.getByTestId('warehouse-panel');
  await expect(panel.getByTestId('wp-days')).toHaveText('0 days');
  await expect(panel.getByTestId('wp-bags')).toHaveText('4 in · 0 out · 4 left');
  await expect(panel.getByTestId('wp-badge')).toHaveText(/On time/i);
  // an inspection that found something says what
  await panel.getByTestId('wp-inspect').click();
  await panel.getByTestId('wp-cond').selectOption('minor');
  await expect(panel.getByTestId('wp-inspect-save')).toBeDisabled();
  await panel.getByTestId('wp-note').fill('a few damp bags at the bottom');
  await expectNoSideScroll(page);
  await panel.getByTestId('wp-inspect-save').click();
  await expect(panel.getByTestId('wp-inspections')).toContainText('Minor deterioration');
  await expect(panel.getByTestId('wp-inspections')).toContainText('Grading Operator');
  await signOut(page);

  // the Client Manager sees the flag and sets the interval: every day, so the next inspection is due now
  await signIn(page, USERS.cm);
  const cm2 = await apiAs(page);
  expect((await cm2.rows('flags', `footprint_id=eq.${whRow.id}&status=eq.open`)).map((f) => String(f.text))).toEqual([expect.stringMatching(/^Warehouse: received 194/)]);
  await page.goto(`/scopes/${scope}`);
  await page.getByTestId('ss-every').fill('1');
  await expectNoSideScroll(page);
  await page.getByTestId('ss-every-save').click();
  await expect.poll(async () => (await cm2.rows('scopes', `id=eq.${scope}`))[0].warehouse_inspection_days).toBe(1);
  await page.goto('/');
  await expect(page.getByTestId('needs-action-line').filter({ hasText: `${wh}: inspection due by` })).toBeVisible();
  await signOut(page);

  // Milling checks the stored lot in, records the bags out and takes it
  await signIn(page, USERS.mill);
  await openSlot(page, 'milling', scope);
  await verifyIncoming(page, wh);
  await page.goto(`/records/${whRow.id}`);
  const p = page.getByTestId('warehouse-panel');
  await expect(p.getByTestId('wp-inspect')).toHaveCount(0);                               // Milling does not inspect
  await p.getByTestId('wp-out').click();
  await p.getByTestId('wp-bags-n').fill('5');
  await expect(p.getByTestId('wp-out-save')).toBeDisabled();                               // only 4 came in
  await p.getByTestId('wp-bags-n').fill('4');
  await p.getByLabel(/^Where to/).fill('to the mill');
  await p.getByTestId('wp-out-save').click();
  await expect(p.getByTestId('wp-bags')).toHaveText('4 in · 4 out · 0 left');
  await expect(p.getByTestId('wp-moves')).toContainText('4 bags out');
  await expectNoSideScroll(page);
  const mApi = await apiAs(page);
  ok(await mApi.insert('footprints', { scope_id: scope, client_id: CLIENT, stage_type: 'milling', prev_footprint_id: whRow.id, created_by: id('308'),
    payload: { input_kg: 194, head_rice_kg: 140, broken_kg: 15, husk_kg: 32, bran_kg: 7 } }));
  await page.reload();
  await expect(page.getByTestId('warehouse-panel')).toHaveAttribute('data-state', 'done');
  await signOut(page);
});
