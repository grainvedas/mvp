// Migration 56 (Veda, 16 Oct 2026, "proceed with 56": the operator-stages plan, release 9: Part F, D5–D6, and her two
// points: "check that one client data should not be visible to another client" and "during collection there can be
// filter use such as village"), on a 527 px screen. The Client Manager shares a shipment with its buyer: a link that
// lasts 7 days, shown once. The buyer opens it without signing in: the order, the papers, the lab result, the villages'
// shares; no price and no farmer's name; he opens the lab report and downloads the evidence pack; every view is on the
// Client Manager's list; a revoked link opens nothing. A pack's code scanned in Delhi and then in Rotterdam: a flag in
// "Needs my action" and on the Flags page, a warning on the pack's public page until it is cleared. The Collection
// Batch filters its lots by village and by a farmer's name or a lot code. Every rule is the database's
// (tests/51_buyer_link_scans.sql, tests/50_client_isolation.sql).
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, apiAs, openSlot, verifyIncoming, reviewAndSave, procure, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const uniq = () => String(Date.now()).slice(-6);
const CLIENT = '00000000-0000-4000-8000-000000000201';
const S = SCOPES.bastiMill;
const B = SCOPES.bansiBatch;
const id = (n: string) => `00000000-0000-4000-8000-000000000${n}`;
// its own bytes: since migration 59 one file attached as two kinds of document (another spec's POD) asks a reason
const PDF = Buffer.from(`%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\n% phase28 lab report ${Date.now()}\ntrailer<</Root 1 0 R>>\n%%EOF\n`);
const ok = (r: { ok: boolean; data: unknown }) => expect(r.ok, JSON.stringify(r.data)).toBe(true);
const idOf = (r: { ok: boolean; data: unknown }) => { ok(r); return String((r.data as { id: string }[])[0].id); };

/** Scope 05 back as the other tests expect it (seed 09), the test's rows put away. Run whatever happened. */
test.afterAll(async ({ browser }) => {
  const page = await browser.newPage();
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  await cm.update('scopes', `id=eq.${S}`, { stage_details_required: false, record_price: false, market_codes: ['domestic', 'export'] });
  for (const r of await cm.rows('buyers', 'name=like.e2e56*&active=eq.true')) await cm.update('buyers', `id=eq.${r.id}`, { active: false });
  for (const r of await cm.rows('pack_skus', `client_id=eq.${CLIENT}&label_type=eq.tag&active=eq.true`)) await cm.update('pack_skus', `id=eq.${r.id}`, { active: false });
  await page.close();
});

async function footprint(page: Page, code: string) {
  return (await (await apiAs(page)).rows('footprints', `footprint_code=eq.${code}`))[0] as { id: string; qty_out: number; computed: Record<string, unknown> };
}

test('Part F and D5–D6: a buyer link (what it shows, every view, revoked); a copied pack code flagged, warned, cleared', async ({ page, browser }) => {
  test.setTimeout(420_000);
  const u = uniq();
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  const had = await cm.rows('pack_skus', `client_id=eq.${CLIENT}&size=eq.1&unit=eq.kg&material=eq.pouch&market=eq.domestic`);
  const kg1 = had.length ? String(had[0].id) : idOf(await cm.insert('pack_skus', { client_id: CLIENT, size: 1, unit: 'kg', material: 'pouch', market: 'domestic', label_type: 'tag' }));
  if (had.length) ok(await cm.update('pack_skus', `id=eq.${kg1}`, { active: true }));
  const buyer = idOf(await cm.insert('buyers', { client_id: CLIENT, name: `e2e56 Amira Foods ${u}`, country: 'IN', gstin: '09AAACG1234F1Z5', address: 'Azadpur Mandi, Delhi' }));
  ok(await cm.update('scopes', `id=eq.${S}`, { stage_details_required: false, record_price: false }));
  await signOut(page);

  // the lot: the farm gate; Quality Control with its lab report (the file the buyer will open); Milling and Packing
  await signIn(page, USERS.procurement);
  const p = await procure(page, S, 'Suresh Yadav', '104', '2', '2');
  await signOut(page);
  await signIn(page, USERS.qc);
  await openSlot(page, 'qc', S);
  await verifyIncoming(page, p);
  await page.getByRole('button', { name: /Record Quality Control/ }).click();
  await page.getByLabel(/Sample drawn/).fill('1');
  await page.getByLabel(/^Moisture \(%\)/).fill('11.8');
  await page.getByLabel(/^Broken grains/).fill('2');
  await page.getByLabel(/^Foreign matter/).fill('0.2');
  await page.getByLabel(/^Lab report/).setInputFiles({ name: 'lab-report.pdf', mimeType: 'application/pdf', buffer: PDF });
  const q = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?QC-\d{4}/);
  await expect.poll(async () => (await apiAs(page)).rows('attachments', `footprint_id=eq.${(await footprint(page, q)).id}&label=eq.lab_report`).then((r) => r.length), { timeout: 30_000 }).toBe(1);
  await signOut(page);
  const step = async (who: typeof USERS.qc, verify: string, stage: string, payload: Record<string, unknown>, verified = false) => {
    await signIn(page, who);
    const api = await apiAs(page);
    if (!verified) ok(await api.rpc('verify_footprint', { p_fp: (await footprint(page, verify)).id }));
    const r = await api.insert('footprints', { scope_id: S, client_id: CLIENT, stage_type: stage, prev_footprint_id: (await footprint(page, verify)).id, created_by: id(who.key), payload });
    ok(r);
    await signOut(page);
    return String((r.data as { footprint_code: string }[])[0].footprint_code);
  };
  const m = await step(USERS.mill, q, 'milling', { input_kg: 99, head_rice_kg: 70, broken_kg: 4, husk_kg: 20, bran_kg: 5 });
  const k = await step(USERS.sorting, m, 'packing', { input_kg: 70, packets: [{ sku_id: kg1, units: 69, size_kg: 1 }] });
  // Commercial takes the packs (as phase26: before the scope asks the details); the order and its shipment with them
  await signIn(page, USERS.commercial);
  ok(await (await apiAs(page)).rpc('verify_footprint', { p_fp: (await footprint(page, k)).id }));
  await signOut(page);
  await signIn(page, USERS.cm);
  ok(await (await apiAs(page)).update('scopes', `id=eq.${S}`, { stage_details_required: true }));
  // migration 57: a domestic shipment of packs carries the codes loaded too
  const codes = (await (await apiAs(page)).rows('packs', `footprint_id=eq.${(await footprint(page, k)).id}&status=eq.packed&order=serial&limit=20`)).map((x) => String(x.serial));
  expect(codes).toHaveLength(20);
  await signOut(page);
  const d = await step(USERS.commercial, k, 'commercial', { buyer_id: buyer, market: 'domestic', order_no: `PO-${u}`, packs: [{ sku_id: kg1, units: 20 }] }, true);
  const sh = await step(USERS.shipment, d, 'shipment', { packs: [{ sku_id: kg1, units: 20 }], vehicle_no: 'UP53AB1234', transporter: 'Basti Roadways',
    dispatch_date: new Date().toISOString().slice(0, 10), destination: 'Delhi', invoice_no: `INV-${u}`, lr_no: `LR-${u}`, serials: codes });

  // Part F · the Client Manager makes a link for the shipment: 7 days, a note; it is shown once
  await signIn(page, USERS.cm);
  const shRow = await footprint(page, sh);
  await page.goto(`/records/${shRow.id}`);
  const panel = page.getByTestId('buyer-share');
  await expect(panel).toBeVisible();
  await panel.getByTestId('bk-new').click();
  await panel.getByTestId('bk-days').selectOption('7');
  await panel.getByTestId('bk-note').fill('for Amira quality desk');
  await expectNoSideScroll(page);
  await panel.getByTestId('bk-create').click();
  const url = await panel.getByTestId('bk-url').inputValue();
  expect(url).toMatch(/\/b#[0-9a-f]{48}$/);
  await expect(panel.getByTestId('bk-whatsapp')).toHaveAttribute('href', new RegExp(`^https://wa\\.me/\\?text=.*${encodeURIComponent(url).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`));
  await expect(panel.getByTestId('bk-row')).toHaveCount(1);
  await expect(panel.getByTestId('bk-row')).toHaveAttribute('data-state', 'active');
  await expect(panel.getByTestId('bk-views')).toHaveText('opened 0 times');
  await expectNoSideScroll(page);

  // the buyer: no sign-in, a phone
  const buyerCtx = await browser.newContext({ viewport: { width: 527, height: 900 }, acceptDownloads: true });
  const bp = await buyerCtx.newPage();
  await bp.goto(url);
  const view = bp.getByTestId('buyer-view');
  await expect(view).toBeVisible();
  await expect(bp.getByTestId('bv-order')).toContainText(`PO-${u}`);
  await expect(bp.getByTestId('bv-order')).toContainText(`e2e56 Amira Foods ${u}`);
  await expect(bp.getByTestId('bv-order')).toContainText('20 kg');
  await expect(bp.getByTestId('bv-shipment')).toContainText(`INV-${u}`);
  await expect(bp.getByTestId('bv-shipment')).not.toContainText('UP53AB1234');   // migration 57: the vehicle number stays with the seller
  await expect(bp.getByTestId('bv-shipment')).toContainText(`LR-${u}`);
  await expect(bp.getByTestId('bv-lab')).toContainText('Domestic');
  await expect(bp.getByTestId('bv-origin')).toContainText('Shohratgarh');
  await expect(bp.getByTestId('bv-origin')).toContainText('100 %');
  const text = await view.innerText();
  expect(text).not.toContain('Suresh Yadav');                                             // never a farmer's name
  expect(text).not.toMatch(/price|INR|₹/i);                                               // never a price
  expect(text).not.toContain(p);                                                          // nor the farm-gate record
  await expectNoSideScroll(bp);
  // the lab report: through the buyer-file function, a short signed download
  const files = bp.getByTestId('bv-file');
  await expect(files).toHaveCount(1);
  await expect(files).toContainText('Lab report');
  const signed = buyerCtx.waitForEvent('request', { predicate: (r) => r.url().includes('/storage/v1/object/sign/evidence/'), timeout: 20_000 });
  await files.getByTestId('bv-open').click();
  expect((await (await signed).response())?.status()).toBe(200);              // the file itself, through its signed address
  for (const other of buyerCtx.pages()) if (other !== bp) await other.close();
  // the evidence pack
  const [dl] = await Promise.all([bp.waitForEvent('download', { predicate: (x) => x.suggestedFilename().startsWith('evidence-') }), bp.getByTestId('bv-evidence').click()]);
  expect(dl.suggestedFilename()).toBe(`evidence-${sh}.json`);

  // every view, on the Client Manager's list; then revoked with a reason: the link opens nothing
  await expect.poll(async () => {
    await page.reload();
    return page.getByTestId('bk-views').textContent();
  }, { timeout: 20_000 }).toBe('opened 3 times');
  const row = page.getByTestId('bk-row');
  await row.locator('summary').click();
  await expect(row.getByTestId('bk-log')).toContainText('page opened');
  await expect(row.getByTestId('bk-log')).toContainText('a file opened');
  await expect(row.getByTestId('bk-log')).toContainText('evidence pack downloaded');
  await row.getByTestId('bk-revoke').click();
  await row.getByTestId('bk-why').fill('sent to the wrong person');
  await expectNoSideScroll(page);
  await row.getByTestId('bk-revoke-save').click();
  await expect(page.getByTestId('bk-row')).toHaveAttribute('data-state', 'revoked');
  await bp.reload();
  await expect(bp.getByTestId('bv-gone')).toBeVisible();
  await expect(bp.getByTestId('buyer-view')).toHaveCount(0);

  // D5–D6 · one of the packs scanned in Delhi, then in Rotterdam: a flag, the warning on its public page
  const serial = String((await cm.rows('packs', `footprint_id=eq.${(await footprint(page, k)).id}&order=serial&limit=1`))[0].serial);
  ok(await cm.rpc('record_scan_at', { p_code: serial, p_city: 'New Delhi', p_region: 'DL', p_country: 'IN', p_lat: 28.61, p_lng: 77.21 }));
  const far = await cm.rpc('record_scan_at', { p_code: serial, p_city: 'Rotterdam', p_region: 'ZH', p_country: 'NL', p_lat: 51.92, p_lng: 4.48 });
  ok(far);
  expect(far.data).toMatchObject({ counted: true, copy_warning: true });
  await page.goto('/');
  await expect(page.getByTestId('needs-action-line').filter({ hasText: 'scanned far apart or very often' })).toBeVisible();
  await page.goto('/flags');
  const sf = page.getByTestId('sf-row').filter({ hasText: serial });
  await expect(sf).toHaveCount(1);
  await expect(sf.getByTestId('sf-text')).toContainText('New Delhi, IN and Rotterdam, NL');
  await expectNoSideScroll(page);
  await bp.goto(`/p/${serial}`);
  // migration 59 (A1): the lot is not released yet, so the page names no seller; the warning stays
  await expect(bp.getByTestId('pv-copy-warning')).toContainText('It may be a copy');
  await expect(bp.getByTestId('pv-copy-warning')).not.toContainText('GrainVeda');
  await expectNoSideScroll(bp);
  // cleared with a reason: the warning goes
  await sf.getByTestId('sf-decide').click();
  await sf.getByTestId('sf-outcome').selectOption('cleared');
  await sf.getByTestId('sf-reason').fill('the buyer took one pack to Rotterdam');
  await sf.getByTestId('sf-save').click();
  await expect(page.getByTestId('sf-row').filter({ hasText: serial })).toHaveCount(0);
  await bp.reload();
  await expect(bp.getByTestId('pv-pack')).toBeVisible();
  await expect(bp.getByTestId('pv-copy-warning')).toHaveCount(0);
  await buyerCtx.close();
  await signOut(page);
});

test('the Collection Batch: lots filtered by village, by a farmer or a lot code; all shown chosen; chosen lots hidden are said', async ({ page }) => {
  test.setTimeout(300_000);
  // three lots at the farm gate: two of Ram Achal (Bansi), one of Sita Devi (Itwa)
  await signIn(page, USERS.procurement);
  const a1 = await procure(page, B, 'Ram Achal', '61', '1', '1');
  const a2 = await procure(page, B, 'Ram Achal', '62', '1', '1');
  const s1 = await procure(page, B, 'Sita Devi', '63', '1', '1');
  await signOut(page);
  await signIn(page, USERS.villageBatch);
  await openSlot(page, 'village_batch', B);
  for (const c of [a1, a2, s1]) { await verifyIncoming(page, c); await page.getByRole('button', { name: 'Back' }).click(); }
  await page.getByRole('tab', { name: /New Collection Batch/ }).click();
  const lots = page.getByTestId('batch-lots');
  await expect(lots).toContainText(a1);
  await expect(page.getByTestId('batch-filter')).toBeVisible();
  // a village
  await page.getByTestId('batch-f-village').selectOption('itwa');
  await expect(lots).toContainText(s1);
  await expect(lots).not.toContainText(a1);
  for (const t of await lots.locator('label.check').allInnerTexts()) expect(t).toContain('Itwa');
  // a lot code within all villages: one lot; choose the one shown
  await page.getByTestId('batch-f-village').selectOption('');
  await page.getByTestId('batch-f-text').fill(a2);
  await expect(lots.locator('label.check')).toHaveCount(1);
  await expect(page.getByTestId('batch-f-count')).toContainText('1 of');
  await page.getByTestId('batch-f-all').click();
  await expect(page.getByRole('checkbox', { name: new RegExp(a2) })).toBeChecked();
  // a farmer's name: his lots; the chosen one stays chosen; then another village: the chosen lot is hidden, and said
  await page.getByTestId('batch-f-text').fill('ram achal');
  await expect(lots).toContainText(a1);
  await expect(lots).toContainText(a2);
  await expect(lots).not.toContainText(s1);
  await expect(page.getByRole('checkbox', { name: new RegExp(a2) })).toBeChecked();
  await page.getByTestId('batch-f-text').fill('');
  await page.getByTestId('batch-f-village').selectOption('itwa');
  await expect(page.getByTestId('batch-f-hidden')).toContainText('1 chosen lots are hidden by the filter');
  await expectNoSideScroll(page);
  await signOut(page);
});
