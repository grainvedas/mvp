// Migration 57 (release 10; Veda, 16 Oct 2026: G21 "this line should not appear", "make a good UI", G22, the
// shipment's pack codes; "rest all ok and proceed with 57"), on a 527 px screen. A sealed lot of packs: its public pack
// page in the new look (the villages, the journey with "checked by another person" where true, the lab readings, the
// pack's scans) says nothing of one person recording and checking a step, and nothing of a domestic dispatch's place.
// The Collection Batch operator: two counts that do not contradict, a card per waiting lot with the village filter and
// the search, the short stage name, the tabs in one row; the filters on two rows below 420 px. Every rule is the
// database's (tests/52_people_public_page_packs.sql); G20 (another client's people) is tests/52 and tests/50.
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, apiAs, openSlot, verifyIncoming, procure, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const CLIENT = '00000000-0000-4000-8000-000000000201';
const S = SCOPES.bastiMill;
const B = SCOPES.bansiBatch;
const id = (n: string) => `00000000-0000-4000-8000-000000000${n}`;
const ok = (r: { ok: boolean; data: unknown }) => expect(r.ok, JSON.stringify(r.data)).toBe(true);
const idOf = (r: { ok: boolean; data: unknown }) => { ok(r); return String((r.data as { id: string }[])[0].id); };
const SHOTS = process.env.SHOTS_DIR;

async function footprint(page: Page, code: string) {
  return (await (await apiAs(page)).rows('footprints', `footprint_code=eq.${code}`))[0] as { id: string };
}

test('the public pack page, new look: villages, the journey checked where true, the lab, the scans; no same-person line', async ({ page, browser }) => {
  test.setTimeout(360_000);
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  const had = await cm.rows('pack_skus', `client_id=eq.${CLIENT}&size=eq.1&unit=eq.kg&material=eq.pouch&market=eq.domestic`);
  const kg1 = had.length ? String(had[0].id) : idOf(await cm.insert('pack_skus', { client_id: CLIENT, size: 1, unit: 'kg', material: 'pouch', market: 'domestic', label_type: 'tag' }));
  if (had.length) ok(await cm.update('pack_skus', `id=eq.${kg1}`, { active: true }));
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
    const code = String((r.data as { footprint_code: string; id: string }[])[0].footprint_code);
    const fid = String((r.data as { footprint_code: string; id: string }[])[0].id);
    if (stage === 'qr_activation') ok(await api.rpc('seal_lot', { p_qr_fp: fid }));
    await signOut(page);
    return code;
  };
  const q = await step(USERS.qc, p, 'qc', { qty_kg: 100, sample_qty_kg: 1, readings: { moisture_pct: 11.8, broken_pct: 2, foreign_matter_pct: 0.2 } });
  const m = await step(USERS.mill, q, 'milling', { input_kg: 99, head_rice_kg: 70, broken_kg: 4, husk_kg: 20, bran_kg: 5 });
  const k = await step(USERS.sorting, m, 'packing', { input_kg: 70, packets: [{ sku_id: kg1, units: 69, size_kg: 1 }] });
  const c = await step(USERS.commercial, k, 'commercial', { buyer: 'e2e57 Typed Buyer', market: 'domestic', qty_kg: 69 });
  const sh = await step(USERS.shipment, c, 'shipment', { shipped_kg: 69, vehicle_or_container: 'UP53AB1234', dispatch_date: new Date().toISOString().slice(0, 10), destination: 'Delhi Azadpur' });
  await step(USERS.qr, sh, 'qr_activation', {});
  await signIn(page, USERS.cm);
  const cm2 = await apiAs(page);
  const serial = String((await cm2.rows('packs', `footprint_id=eq.${(await footprint(page, k)).id}&order=serial&limit=1`))[0].serial);
  ok(await cm2.rpc('record_scan_at', { p_code: serial, p_city: 'Gorakhpur', p_region: 'UP', p_country: 'IN', p_lat: 26.76, p_lng: 83.37 }));
  ok(await cm2.rpc('record_scan_at', { p_code: serial, p_city: 'Lucknow', p_region: 'UP', p_country: 'IN', p_lat: 26.85, p_lng: 80.95 }));
  await signOut(page);

  // a buyer's phone, nobody signed in
  const ctx = await browser.newContext({ viewport: { width: 527, height: 900 } });
  const bp = await ctx.newPage();
  await bp.goto(`/p/${serial}`);
  const pub = bp.getByTestId('public-journey');
  await expect(pub).toBeVisible();
  await expect(bp.getByTestId('pv-hero')).toContainText('Genuine pack, sealed record');
  await expect(bp.getByTestId('pv-hero')).toContainText(serial);
  await expect(bp.getByTestId('pv-scans')).toContainText('Gorakhpur');
  await expect(bp.getByTestId('pv-scans')).toContainText('No copies');
  await expect(bp.getByTestId('pv-villages')).toContainText('Shohratgarh, Siddharthnagar');
  await expect(bp.getByTestId('pv-villages')).toContainText('100 % · 1 farmer');
  await expect(pub).toContainText('Grown in Shohratgarh, Siddharthnagar');
  await expect(bp.getByTestId('pv-checked')).toHaveCount(6);                              // farm gate to the shipment, each checked by the next person
  await expect(bp.getByTestId('pv-reading').filter({ hasText: 'Moisture' })).toContainText('11.8 %');
  await expect(bp.getByTestId('pv-pack')).toContainText('Prasaadam');
  await expect(bp.getByTestId('pv-how')).toContainText('checked by the next person');
  const text = await pub.innerText();
  expect(text).not.toMatch(/same person|recorded and checked by/i);                      // G21
  expect(text).not.toContain('Suresh Yadav');                                             // never a farmer's name
  expect(text).not.toContain('Delhi Azadpur');                                            // nothing of a domestic dispatch's place
  expect(text).not.toContain('UP53AB1234');
  await expectNoSideScroll(bp);
  await bp.getByLabel('Language').selectOption('hi');
  await expect(bp.getByTestId('pv-scans')).toContainText('बार यह पैक स्कैन हुआ');
  await expect(bp.getByTestId('pv-villages')).toContainText('कहाँ उगाया गया');
  await expectNoSideScroll(bp);
  await bp.getByLabel('Language').selectOption('en');
  if (SHOTS) {
    await bp.setViewportSize({ width: 390, height: 844 });
    await bp.screenshot({ path: `${SHOTS}/57_public_pack_390.png`, fullPage: true });
  }
  await ctx.close();
});

test('the Collection Batch operator: two counts, a card per lot with the village filter and the search, short names, one row of tabs', async ({ page }) => {
  test.setTimeout(300_000);
  await signIn(page, USERS.procurement);
  const a = await procure(page, B, 'Ram Achal', '71', '1', '1');
  const s = await procure(page, B, 'Sita Devi', '72', '1', '1');
  await signOut(page);
  await signIn(page, USERS.villageBatch);
  // the first screen: lots to check in and lots ready, never one number against another
  await expect(page.getByTestId('incoming-count')).toContainText(/\d+ to check in/);
  await openSlot(page, 'village_batch', B);
  await expect(page.getByRole('heading', { level: 1 })).toHaveText(/Collection Batch$/);
  await expect(page.getByTestId('stage-sub')).toContainText('One collection point');
  const tabs = page.getByRole('tab');
  await expect(page.getByRole('tab', { name: /^Waiting from / })).toContainText(/^Waiting · \d+$/);
  const ys = await Promise.all((await tabs.all()).map(async (x) => Math.round((await x.boundingBox())!.y)));
  expect(new Set(ys).size).toBe(1);                                                         // one row
  // a card per lot: its number, farmer · village, kg; the village filter and the search
  const card = page.getByTestId('incoming-row').filter({ hasText: a });
  await expect(card).toContainText('Ram Achal · Bansi');
  await expect(card).toContainText('To check in');
  await page.getByTestId('inc-f-village').selectOption((await page.getByTestId('inc-f-village').locator('option', { hasText: 'Itwa' }).getAttribute('value'))!);
  await expect(page.getByTestId('incoming-row').filter({ hasText: s })).toBeVisible();
  await expect(page.getByTestId('incoming-row').filter({ hasText: a })).toHaveCount(0);
  await page.getByTestId('inc-f-village').selectOption('');
  await page.getByTestId('inc-f-text').fill(a);
  await expect(page.getByTestId('incoming-row')).toHaveCount(1);
  await page.getByTestId('inc-f-text').fill('');
  await expectNoSideScroll(page);
  if (SHOTS) {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.screenshot({ path: `${SHOTS}/57_waiting_390.png`, fullPage: true });
  }
  // below 420 px the village box and the search stand on two rows (they were cut)
  await page.setViewportSize({ width: 390, height: 844 });
  const vy = (await page.getByTestId('inc-f-village').boundingBox())!.y, ty = (await page.getByTestId('inc-f-text').boundingBox())!.y;
  expect(ty).toBeGreaterThan(vy + 20);
  await expectNoSideScroll(page);
  await page.setViewportSize({ width: 527, height: 900 });
  // checked in: the counts move
  await verifyIncoming(page, a);
  await page.goto('/');
  await expect(page.getByTestId('incoming-count')).toContainText(/checked in, ready/);
  if (SHOTS) {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.screenshot({ path: `${SHOTS}/57_home_390.png`, fullPage: true });
  }
  await signOut(page);
});
