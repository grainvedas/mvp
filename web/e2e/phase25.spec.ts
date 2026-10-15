// Migration 53 (Veda, 15 Oct 2026: the operator-stages brief, release 6: C4 Milling, C5 Quality Control, C6 Packing), on
// a 527 px screen. The Client Manager turns on, for an active scope, the stage details (the scope page). The client's
// mill, packing unit and packs are on its lists and the state's lab on the state's list. Quality Control verifies the
// lot and draws the sample first ("sent to the lab, awaiting results", with its counter-sample), then records its
// results on that sample; the lab record shows a verdict per market. Milling names the mill, the line clearance and
// the operator, and types head rice, broken, husk and bran (the loss and the recovery are worked out); the 3 kg left
// of the lab lot is closed as floor loss. Packing takes the packs from the client's list (the wastage is worked out);
// the system picks 5 packs, one weighed short fails the check, weighed again it passes, and only then does
// Commercial verify the packs. Every rule is the database's (tests/47_milling_qc_packing.sql).
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, apiAs, openSlot, verifyIncoming, reviewAndSave, procure, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const uniq = () => String(Date.now()).slice(-6);
const CLIENT = '00000000-0000-4000-8000-000000000201';
const UP = '00000000-0000-4000-8000-000000000001';
const S = SCOPES.bastiMill;

/** Scope 05 back as the other tests expect it (seed 09: no stage details), the test's list rows put away. Run whatever happened. */
test.afterAll(async ({ browser }) => {
  const page = await browser.newPage();
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  await cm.update('scopes', `id=eq.${S}`, { stage_details_required: false, market_codes: ['domestic', 'export'] });
  for (const t of ['mills', 'packing_units']) for (const r of await cm.rows(t, 'name=like.e2e53*&active=eq.true')) await cm.update(t, `id=eq.${r.id}`, { active: false });
  for (const r of await cm.rows('pack_skus', `client_id=eq.${CLIENT}&label_type=eq.tag&active=eq.true`)) await cm.update('pack_skus', `id=eq.${r.id}`, { active: false });
  await signOut(page);
  await signIn(page, USERS.sm);
  const sm = await apiAs(page);
  for (const r of await sm.rows('labs', 'name=like.e2e53*&active=eq.true')) await sm.update('labs', `id=eq.${r.id}`, { active: false });
  await page.close();
});

const idOf = (r: { ok: boolean; data: unknown }) => { expect(r.ok, JSON.stringify(r.data)).toBe(true); return String((r.data as { id: string }[])[0].id); };
async function footprintId(page: Page, code: string) {
  const api = await apiAs(page);
  return String((await api.rows('footprints', `footprint_code=eq.${code}`))[0].id);
}

test('C4–C6: the sample before the lab results, the mill and its outputs, a lot closed, packs from the list, the net weight check', async ({ page }) => {
  test.setTimeout(300_000);
  const u = uniq();

  // 1 · the lists: the client's mill, packing unit and packs (Client Manager); the state's lab (State Manager)
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  const mill = idOf(await cm.insert('mills', { client_id: CLIENT, name: `e2e53 Basti mill ${u}`, place: 'Basti', ownership: 'own' }));
  const unit = idOf(await cm.insert('packing_units', { client_id: CLIENT, name: `e2e53 Basti packing ${u}`, place: 'Basti', ownership: 'own' }));
  // a pack size is once on a client's list (put away after a run before: taken back)
  const sku = async (size: number, unit: string) => {
    const had = await cm.rows('pack_skus', `client_id=eq.${CLIENT}&size=eq.${size}&unit=eq.${unit}&material=eq.pouch&market=eq.domestic`);
    if (!had.length) return idOf(await cm.insert('pack_skus', { client_id: CLIENT, size, unit, material: 'pouch', market: 'domestic', label_type: 'tag' }));
    expect((await cm.update('pack_skus', `id=eq.${had[0].id}`, { active: true })).ok).toBe(true);
    return String(had[0].id);
  };
  const kg1 = await sku(1, 'kg');
  const g500 = await sku(500, 'g');
  // the scope asks the details from now on: its page, also once active
  await page.goto(`/scopes/${S}`);
  const box = page.getByTestId('ss-details');
  await expect(page.getByTestId('stage-settings')).toBeVisible();
  if (!(await box.isChecked())) await box.check();
  await expect(box).toBeChecked();
  await expect(box).toBeEnabled();
  await expect(page.getByTestId('ss-market-domestic')).toBeChecked();
  await expect(page.getByTestId('ss-market-export')).toBeChecked();
  await expectNoSideScroll(page);
  expect((await cm.rows('scopes', `id=eq.${S}`))[0]).toMatchObject({ stage_details_required: true });
  await signOut(page);
  await signIn(page, USERS.sm);
  const lab = idOf(await (await apiAs(page)).insert('labs', { state_id: UP, name: `e2e53 Lucknow lab ${u}`, kind: 'external', accreditation_no: `TC-${u}`, location: 'Lucknow' }));
  await signOut(page);

  // 2 · a lot bought at the farm gate
  await signIn(page, USERS.procurement);
  const p = await procure(page, S, 'Suresh Yadav', '199', '2', '2');
  await signOut(page);

  // 3 · Quality Control: verifies the lot, draws the sample (to the lab, with its counter-sample), then records its results
  await signIn(page, USERS.qc);
  await openSlot(page, 'qc', S);
  await verifyIncoming(page, p);
  const smp = page.getByTestId('samples-panel');
  await expect(smp).toBeVisible();
  await smp.getByTestId('sample-draw').click();
  await smp.getByTestId('sample-qty').fill('1');
  await smp.getByTestId('sample-lab').selectOption(lab);
  await smp.getByTestId('sample-seal').fill(`CS-${u}`);
  await smp.getByTestId('sample-where').fill('QC store, shelf 3');
  await expectNoSideScroll(page);
  await smp.getByTestId('sample-save').click();
  const row = smp.getByTestId('sample-row');
  await expect(row).toHaveAttribute('data-status', 'sent');
  await expect(row).toContainText('sent to the lab, awaiting results');
  await expect(row).toContainText(`CS-${u}`);
  await page.getByRole('button', { name: /Record Quality Control for this lot/ }).click();
  await expect(page.getByLabel(/Sample drawn/)).toHaveCount(0);                       // the sample is chosen, not typed
  const pick = page.getByTestId('pick-sample');
  await expect(pick.locator('option')).toHaveCount(2);
  await pick.selectOption({ index: 1 });
  await page.getByLabel(/^Moisture \(%\)/).fill('11.8');
  await page.getByLabel(/^Broken grains/).fill('2');
  await page.getByLabel(/^Foreign matter/).fill('0.2');
  await expectNoSideScroll(page);
  const q = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?QC-\d{4}/);
  const qId = await footprintId(page, q);
  const qApi = await apiAs(page);
  expect((await qApi.rows('qc_samples', `footprint_id=eq.${await footprintId(page, p)}`))[0]).toMatchObject({ status: 'results_in', qc_footprint_id: qId });
  // the lab record: a verdict per market of the scope
  await page.goto(`/records/${qId}`);
  const pv = page.getByTestId('profile-verdicts');
  await expect(pv).toBeVisible();
  await expect(pv.locator('[data-market="domestic"]')).toHaveCount(1);
  await expect(pv.locator('[data-market="export"]')).toHaveCount(1);
  await expectNoSideScroll(page);
  await signOut(page);

  // 4 · Milling: the mill from the list, how the line was cleared, the operator; head rice, broken, husk and bran
  await signIn(page, USERS.mill);
  await openSlot(page, 'milling', S);
  await verifyIncoming(page, q);
  await page.getByRole('button', { name: /Record Milling/ }).click();
  await expect(page.getByLabel(/Paddy in/)).toHaveValue('194');
  await page.getByTestId('pick-mill_id').selectOption(mill);
  await page.getByLabel(/^Line clearance/).selectOption('fully_cleaned');
  await page.getByLabel(/^Mill operator/).fill('Ramesh');
  await page.getByLabel(/Paddy in/).fill('191');                                      // 3 kg of the lab lot stays behind
  await page.getByLabel(/^Head rice/).fill('125'); await page.getByLabel(/^Broken rice/).fill('5');
  await page.getByLabel(/^Husk/).fill('48'); await page.getByLabel(/^Bran/).fill('10');
  await expect(page.getByTestId('preview-ok')).toBeVisible();
  await expectNoSideScroll(page);
  const m = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?M-\d{4}/);
  const mApi = await apiAs(page);
  const mRow = (await mApi.rows('footprints', `footprint_code=eq.${m}`))[0] as { qty_out: number; computed: Record<string, unknown> };
  expect(Number(mRow.qty_out)).toBe(125);                                              // head rice goes forward
  expect(mRow.computed).toMatchObject({ mill: `e2e53 Basti mill ${u}`, line_clearance: 'fully_cleaned', loss_kg: 3, recovery_pct: 68.06 });
  // the 3 kg left of the lab lot (1.5 %): closed by the stage that took it, as floor loss
  await page.goto(`/records/${qId}`);
  const close = page.getByTestId('close-lot');
  await expect(close).toContainText('3 kg');
  await close.getByTestId('close-why').fill('Swept from the floor, not fit to mill');
  await close.getByTestId('close-go').click();
  await expect(page.getByTestId('lot-closure')).toContainText('Swept from the floor');
  await expectNoSideScroll(page);
  await signOut(page);

  // 5 · Packing: the packing unit, the packs from the client's list; the wastage is worked out
  await signIn(page, USERS.sorting);
  await openSlot(page, 'packing', S);
  await verifyIncoming(page, m);
  await page.getByRole('button', { name: /Record Packing/ }).click();
  await expect(page.getByLabel(/^Input/)).toHaveValue('125');
  await page.getByTestId('pick-packing_unit_id').selectOption(unit);
  await page.getByTestId('sku-0').selectOption(kg1); await page.getByTestId('sku-units-0').fill('100');
  await page.getByRole('button', { name: '+ packet size' }).click();
  await page.getByTestId('sku-1').selectOption(g500); await page.getByTestId('sku-units-1').fill('48');
  await expect(page.getByTestId('preview-ok')).toContainText('124 kg');
  await expectNoSideScroll(page);
  const pk = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?PK-\d{4}/);
  const pkId = await footprintId(page, pk);
  // the net weight check: 5 packs picked by the system; one weighed short fails, weighed again it passes
  await page.goto(`/records/${pkId}`);
  const nw = page.getByTestId('net-weight');
  await nw.getByTestId('nw-pick').click();
  await expect(nw.getByTestId('nw-g')).toHaveCount(5);
  const api = await apiAs(page);
  const check = (await api.rows('net_weight_checks', `footprint_id=eq.${pkId}`))[0] as { serials: string[] };
  const size = async (s: string) => Number((await api.rows('packs', `serial=eq.${s}`))[0].size_kg) * 1000;
  const grams = [] as number[];
  for (const s of check.serials) grams.push(await size(s));
  for (const [i, g] of grams.entries()) await nw.getByTestId('nw-g').nth(i).fill(String(i === 0 ? g - 40 : g + 2));
  await nw.getByTestId('nw-save').click();
  await expect(nw).toHaveAttribute('data-result', 'fail');
  for (const [i, g] of grams.entries()) await nw.getByTestId('nw-g').nth(i).fill(String(g + 2));
  await nw.getByTestId('nw-save').click();
  await expect(nw).toHaveAttribute('data-result', 'pass');
  await expect(nw.getByTestId('nw-result')).toContainText('Passed');
  await expectNoSideScroll(page);
  await signOut(page);

  // 6 · Commercial counts the packs per size and verifies them (the check has passed)
  await signIn(page, USERS.commercial);
  await openSlot(page, 'commercial', S);
  await page.getByTestId('incoming-row').filter({ hasText: pk }).click();
  await expect(page.getByText('Pack count per size matches the packing record')).toBeVisible();
  for (const b of await page.getByRole('checkbox').all()) await b.check();
  await page.getByRole('button', { name: 'Verify this lot' }).click();
  await expect(page.locator('.alert.ok', { hasText: 'Verified' })).toBeVisible();
  await expectNoSideScroll(page);
  await signOut(page);
});
