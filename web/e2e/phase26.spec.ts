// Migration 54 (Veda, 16 Oct 2026: the operator-stages brief, release 7: C7 Commercial, C8 Shipment, and her four points
// on release 6's checks), on a 527 px screen. The Client Manager keeps a lab of the client's own (QC picks it beside the
// state's); the farm-gate farmer is picked by his village, then from that village's farmers; a Collection Batch names
// its collection point and is offered only that point's lots. Commercial sells packs by type to a buyer from the list,
// with the order number and the price kept apart; an export order names its market's profile and keeps its documents
// (one received with its file, the others not required with why). Shipment ships a domestic order with the vehicle and
// the LR, and an export order with the container, its seal, the shipping bill, the pack codes scanned and the loading
// photo; the bill of lading comes later. Every rule is the database's (tests/48_commercial_shipment.sql).
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, apiAs, openSlot, verifyIncoming, reviewAndSave, procure, pickFarmer, fillWhere, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const uniq = () => String(Date.now()).slice(-6);
const CLIENT = '00000000-0000-4000-8000-000000000201';
const S = SCOPES.bastiMill;
const B = SCOPES.bansiBatch;
const id = (n: string) => `00000000-0000-4000-8000-000000000${n}`;
const PDF = Buffer.from('%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n');
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');

/** Scopes 05 and 06 back as the other tests expect them (seed 09), the test's list rows put away. Run whatever happened. */
test.afterAll(async ({ browser }) => {
  const page = await browser.newPage();
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  await cm.update('scopes', `id=eq.${S}`, { stage_details_required: false, record_price: false, market_codes: ['domestic', 'export'] });
  await cm.update('scopes', `id=eq.${B}`, { stage_details_required: false });
  for (const t of ['labs', 'buyers', 'collection_points']) for (const r of await cm.rows(t, 'name=like.e2e54*&active=eq.true')) await cm.update(t, `id=eq.${r.id}`, { active: false });
  for (const r of await cm.rows('pack_skus', `client_id=eq.${CLIENT}&label_type=eq.tag&active=eq.true`)) await cm.update('pack_skus', `id=eq.${r.id}`, { active: false });
  await page.close();
});

const idOf = (r: { ok: boolean; data: unknown }) => { expect(r.ok, JSON.stringify(r.data)).toBe(true); return String((r.data as { id: string }[])[0].id); };
const ok = (r: { ok: boolean; data: unknown }) => expect(r.ok, JSON.stringify(r.data)).toBe(true);
async function footprint(page: Page, code: string) {
  return (await (await apiAs(page)).rows('footprints', `footprint_code=eq.${code}`))[0] as { id: string; qty_out: number; computed: Record<string, unknown>; status: string };
}

test('Veda\'s points 1–4: a lab of the client\'s own, the farmer by his village, a batch of one collection point', async ({ page }) => {
  test.setTimeout(300_000);
  const u = uniq();
  // 4 · the Client Manager adds a lab of the client's own (Set-up lists, Lists, Labs)
  await signIn(page, USERS.cm);
  await page.goto('/setup?tab=lists');
  await page.getByTestId('set-list-labs').click();
  await page.getByTestId('set-add').click();
  await page.getByTestId('set-labs-name').fill(`e2e54 Client lab ${u}`);
  await page.getByTestId('set-labs-kind').selectOption('external');
  await page.getByTestId('set-labs-accreditation_no').fill(`TC-${u}`);
  await page.getByTestId('set-labs-location').fill('Basti');
  await expectNoSideScroll(page);
  await page.getByTestId('set-save').click();
  await expect(page.getByTestId('set-row').filter({ hasText: `e2e54 Client lab ${u}` })).toBeVisible();
  const cm = await apiAs(page);
  expect((await cm.rows('labs', `name=eq.${encodeURIComponent(`e2e54 Client lab ${u}`)}`))[0]).toMatchObject({ client_id: CLIENT, state_id: id('001') });
  const point = idOf(await cm.insert('collection_points', { client_id: CLIENT, name: `e2e54 Itwa store ${u}`, kind: 'store', district: 'Siddharthnagar' }));
  await cm.update('scopes', `id=eq.${B}`, { stage_details_required: true });
  await signOut(page);

  // 3 · the farm-gate farmer: his village first, then the farmers of that village only
  await signIn(page, USERS.procurement);
  const lots: string[] = [];
  for (const [farmer, gross, where] of [[/Ram Achal/, '82', point], [/Sita Devi/, '92', point], [/Geeta Kumari/, '72', 'farm']] as const) {
    await openSlot(page, 'procurement', B);
    await expect(page.getByTestId('pick-farmer')).toHaveCount(0);                        // no farmer before his village
    await pickFarmer(page, farmer);
    await expect(page.getByTestId('farmer-picked')).toContainText(farmer);
    await page.getByLabel(/Gross weight/).fill(gross); await page.getByLabel(/^Bags/).fill('1'); await page.getByLabel(/Tare per bag/).fill('1');
    for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('12');
    await fillWhere(page, where);
    if (await page.getByLabel(/^Price per quintal/).count()) { await page.getByLabel(/^Price per quintal/).fill('3500'); await page.getByLabel(/^Payment/).selectOption('pending'); }
    await expectNoSideScroll(page);
    lots.push(await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?P-\d{4}/));
  }
  // the village list: each village once, the farmer list only that village's
  await openSlot(page, 'procurement', B);
  const village = page.getByTestId('pick-village');
  await expect(village.locator('option').nth(1)).toBeAttached();
  const names = await village.locator('option').allTextContents();
  expect(new Set(names).size).toBe(names.length);
  await village.selectOption({ index: 1 });
  const vName = names[1].replace(/ \(\d+\)$/, '');
  const api = await apiAs(page);
  const inVillage = (await api.rows('farmers', `client_id=eq.${CLIENT}&status=eq.active`)).filter((f) => String(f.village).toLowerCase().replace(/[^a-z]/g, '') === vName.toLowerCase().replace(/[^a-z]/g, ''));
  await expect(page.getByTestId('pick-farmer').locator('option')).toHaveCount(inVillage.length + 1);
  await signOut(page);
  const [a, b, c] = lots;

  // 2 · the Collection Batch names its point; only that point's lots are offered
  await signIn(page, USERS.villageBatch);
  await openSlot(page, 'village_batch', B);
  for (const x of lots) { await verifyIncoming(page, x); await page.getByRole('button', { name: 'Back' }).click(); }
  await page.getByRole('tab', { name: /New Collection Batch/ }).click();
  const form = page.locator('form');
  await expect(form.locator('[data-section="batch"] .field').first().locator('#f-collection_point_id')).toBeVisible();   // the first field
  await page.locator('#f-collection_point_id').selectOption(point);
  await expect(page.getByTestId('batch-lots')).toContainText(a);
  await expect(page.getByTestId('batch-lots')).toContainText(b);
  await expect(page.getByTestId('batch-lots')).not.toContainText(c);                     // weighed at the farm: not offered here
  await page.locator('#f-collection_point_id').selectOption('farm');
  await expect(page.getByTestId('batch-lots')).toContainText(c);
  await expect(page.getByTestId('batch-lots')).not.toContainText(a);
  await page.locator('#f-collection_point_id').selectOption(point);
  await page.getByRole('checkbox', { name: new RegExp(a) }).check();
  await page.getByRole('checkbox', { name: new RegExp(b) }).check();
  await page.getByLabel(/^Bags in the batch/).fill('2');
  await expect(page.getByTestId('preview-ok')).toContainText('172 kg');
  await expectNoSideScroll(page);
  const vb = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?VB-\d{4}/);
  expect((await footprint(page, vb)).computed).toMatchObject({ collection_point: `e2e54 Itwa store ${u}`, total_kg: 172 });
  await signOut(page);

  // 4 · Quality Control picks the lab from the state's and the client's (the sample of the batch)
  await signIn(page, USERS.qc);
  const qc = await apiAs(page);
  ok(await qc.rpc('verify_footprint', { p_fp: (await footprint(page, vb)).id }));
  await page.goto(`/records/${(await footprint(page, vb)).id}`);
  await page.getByTestId('samples-panel').getByTestId('sample-draw').click();
  const labs = await page.getByTestId('sample-lab').locator('option').allTextContents();
  expect(labs.some((l) => l.startsWith(`e2e54 Client lab ${u}`) && l.includes("client's own"))).toBe(true);
  expect(labs.length).toBeGreaterThan(1);
  await expectNoSideScroll(page);
  await signOut(page);
});

test('C7 and C8: an order by packs and an export order with its documents; a domestic and an export shipment; the bill of lading later', async ({ page }) => {
  test.setTimeout(420_000);
  const u = uniq();
  // the client's lists: two pack types, a buyer in India, a buyer in the Netherlands
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  const sku = async (size: number, unit: string) => {
    const had = await cm.rows('pack_skus', `client_id=eq.${CLIENT}&size=eq.${size}&unit=eq.${unit}&material=eq.pouch&market=eq.domestic`);
    if (!had.length) return idOf(await cm.insert('pack_skus', { client_id: CLIENT, size, unit, material: 'pouch', market: 'domestic', label_type: 'tag' }));
    ok(await cm.update('pack_skus', `id=eq.${had[0].id}`, { active: true }));
    return String(had[0].id);
  };
  const kg1 = await sku(1, 'kg'), g500 = await sku(500, 'g');
  idOf(await cm.insert('buyers', { client_id: CLIENT, name: `e2e54 Delhi Wholesale ${u}`, country: 'IN', gstin: '09AAACG1234F1Z5', address: 'Azadpur Mandi, Delhi' }));
  idOf(await cm.insert('buyers', { client_id: CLIENT, name: `e2e54 Rotterdam Foods ${u}`, country: 'NL', importer_id: `NL-${u}`, address: 'Haven 12, Rotterdam' }));
  await cm.update('scopes', `id=eq.${S}`, { stage_details_required: false, record_price: false });
  await signOut(page);

  // the lot up to its packs (the stages of release 6, by their own operators, as tests/48 builds them)
  await signIn(page, USERS.procurement);
  const p = await procure(page, S, 'Suresh Yadav', '104', '2', '2');
  await signOut(page);
  const step = async (who: typeof USERS.qc, verify: string, stage: string, payload: Record<string, unknown>) => {
    await signIn(page, who);
    const api = await apiAs(page);
    const prev = await footprint(page, verify);
    ok(await api.rpc('verify_footprint', { p_fp: prev.id }));
    const r = await api.insert('footprints', { scope_id: S, client_id: CLIENT, stage_type: stage, prev_footprint_id: prev.id, created_by: id(who.key), payload });
    const code = String((r.data as { footprint_code: string }[])[0]?.footprint_code ?? '');
    expect(r.ok, JSON.stringify(r.data)).toBe(true);
    await signOut(page);
    return code;
  };
  const q = await step(USERS.qc, p, 'qc', { qty_kg: 100, sample_qty_kg: 1, readings: { moisture_pct: 11.8, broken_pct: 2, foreign_matter_pct: 0.2, aflatoxin_ppb: 1 } });
  const m = await step(USERS.mill, q, 'milling', { input_kg: 99, head_rice_kg: 70, broken_kg: 4, husk_kg: 20, bran_kg: 5 });
  const k = await step(USERS.sorting, m, 'packing', { input_kg: 70, packets: [{ sku_id: kg1, units: 55, size_kg: 1 }, { sku_id: g500, units: 28, size_kg: 0.5 }] });
  await signIn(page, USERS.commercial);
  ok(await (await apiAs(page)).rpc('verify_footprint', { p_fp: (await footprint(page, k)).id }));
  await signOut(page);
  // from here on the scope asks the details and records the price; the codes of ten 1 kg packs, as the loaders scan them
  await signIn(page, USERS.cm);
  const cm2 = await apiAs(page);
  ok(await cm2.update('scopes', `id=eq.${S}`, { stage_details_required: true, record_price: true }));
  const serials = (await cm2.rows('packs', `footprint_id=eq.${(await footprint(page, k)).id}&sku_id=eq.${kg1}&status=eq.packed&order=serial&limit=10`)).map((x) => String(x.serial));
  expect(serials).toHaveLength(10);
  await signOut(page);

  // C7 · a domestic order by packs: the buyer from the list, the order number, the price kept apart
  await signIn(page, USERS.commercial);
  await openSlot(page, 'commercial', S);
  await page.getByTestId('incoming-row').filter({ hasText: k }).click();
  await page.getByRole('button', { name: /Record Commercial Clearance for this lot/ }).click();
  await expect(page.getByLabel(/^Buyer \*$/)).toHaveCount(0);                              // typed buyer: not where the details are asked
  await expect(page.getByLabel(/^Quantity to this buyer/)).toHaveCount(0);                 // the packs, not the kilograms
  await page.getByTestId('pick-buyer_id').selectOption({ label: `e2e54 Delhi Wholesale ${u} · IN` });
  await page.getByLabel(/^Market/).selectOption('domestic');
  // migration 55 (Veda, 16 Oct): a domestic order shows no export market, destination country or Incoterms
  for (const l of [/^Destination country/, /^Incoterms/]) await expect(page.getByLabel(l)).toHaveCount(0);
  await expect(page.getByTestId('pick-market_code')).toHaveCount(0);
  await page.getByLabel(/^Order or contract number/).fill(`PO-${u}`);
  await page.getByLabel(/^Sale route/).selectOption('own_brand');
  await expect(page.getByTestId('order-line-0')).toContainText('55 left');
  await page.getByTestId('order-units-0').fill('10');
  await page.getByTestId('order-units-1').fill('4');
  await expect(page.getByTestId('order-kg')).toContainText('12 kg');
  await page.getByLabel(/^Price/).fill('120');
  await page.getByLabel(/^Currency/).selectOption('INR');
  await expectNoSideScroll(page);
  const d = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?CM-\d{4}/);
  const dRow = await footprint(page, d);
  expect(Number(dRow.qty_out)).toBe(12);
  expect(dRow.computed).toMatchObject({ buyer: `e2e54 Delhi Wholesale ${u}`, order_no: `PO-${u}`, market: 'domestic', sale_route: 'own_brand' });
  await page.goto(`/records/${dRow.id}`);
  await expect(page.locator('[data-computed="packs"]')).toContainText('10 × 1 kg pouch · 4 × 500 g pouch');
  await expect(page.getByTestId('sale-value')).toContainText(/INR 1,?440/);
  await expect(page.getByTestId('export-docs')).toHaveCount(0);                           // a domestic order has none

  // C7 · an export order: the market's profile, the destination, Incoterms; its documents
  await openSlot(page, 'commercial', S);
  await page.getByTestId('incoming-row').filter({ hasText: k }).click();
  await page.getByRole('button', { name: /Record Commercial Clearance for this lot/ }).click();
  await page.getByTestId('pick-buyer_id').selectOption({ label: `e2e54 Rotterdam Foods ${u} · NL` });
  await page.getByLabel(/^Market/).selectOption('export');
  await expect(page.getByTestId('pick-market_code').locator('option', { hasText: /Export \(general\) · /i })).toHaveCount(1);
  await page.getByTestId('pick-market_code').selectOption('export');
  await page.getByLabel(/^Destination country/).fill('Netherlands');
  await page.getByLabel(/^Order or contract number/).fill(`EX-${u}`);
  await expect(page.getByTestId('order-line-0')).toContainText('45 left');                 // what the domestic order left
  await page.getByTestId('order-units-0').fill('10');
  await page.getByLabel(/^Price/).fill('2.5');
  await page.getByLabel(/^Currency/).selectOption('USD');
  await page.getByLabel(/^Incoterms/).selectOption('FOB');
  const e = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?CM-\d{4}/);
  const eRow = await footprint(page, e);
  expect(eRow.computed).toMatchObject({ market: 'export', market_code: 'export', destination_country: 'Netherlands', buyer_country: 'NL' });
  await page.goto(`/records/${eRow.id}`);
  const docs = page.getByTestId('export-docs');
  await expect(docs).toHaveAttribute('data-done', 'no');
  const n = await docs.locator('[data-testid^="export-doc-"][data-status]').count();
  expect(n).toBeGreaterThan(1);
  // the first received, with its file; the others not required, with why
  await docs.getByTestId('export-doc-edit-0').click();
  await docs.getByTestId('export-doc-status-0').selectOption('received');
  await docs.getByTestId('export-doc-file-0').setInputFiles({ name: 'certificate.pdf', mimeType: 'application/pdf', buffer: PDF });
  await expectNoSideScroll(page);
  await docs.getByTestId('export-doc-save-0').click();
  await expect(docs.getByTestId('export-doc-0')).toHaveAttribute('data-status', 'received');
  for (let i = 1; i < n; i++) {
    await docs.getByTestId(`export-doc-edit-${i}`).click();
    await docs.getByTestId(`export-doc-status-${i}`).selectOption('not_required');
    await docs.getByTestId(`export-doc-note-${i}`).fill('not asked by this buyer (practice)');
    await docs.getByTestId(`export-doc-save-${i}`).click();
    await expect(docs.getByTestId(`export-doc-${i}`)).toHaveAttribute('data-status', 'not_required');
  }
  await expect(docs).toHaveAttribute('data-done', 'yes');
  await expect(page.locator('[data-label="export_doc"]')).toHaveCount(1);                  // the file, in the record's evidence
  await signOut(page);

  // C8 · a domestic shipment: the packs of the order, the vehicle, the LR, the invoice
  await signIn(page, USERS.shipment);
  await openSlot(page, 'shipment', S);
  await verifyIncoming(page, d);
  await page.getByRole('button', { name: /Record Shipment for this lot/ }).click();
  await expect(page.getByLabel(/^Container number/)).toHaveCount(0);                        // the export papers are not asked
  await expect(page.getByTestId('serials')).toHaveCount(0);
  await page.getByTestId('order-units-0').fill('10');
  await page.getByTestId('order-units-1').fill('4');
  await page.getByLabel(/^Vehicle number/).fill('UP53AB1234');
  await page.getByLabel(/^Transporter/).fill('Basti Roadways');
  await page.getByLabel(/^Dispatch date/).fill(new Date().toISOString().slice(0, 10));
  await page.getByLabel(/^Destination \*/).fill('Delhi');
  await page.getByLabel(/^Invoice number/).fill(`INV-D-${u}`);
  await page.getByLabel(/^LR number/).fill(`LR-${u}`);
  await expectNoSideScroll(page);
  const sd = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?SH-\d{4}/);
  expect((await footprint(page, sd)).computed).toMatchObject({ market: 'domestic', invoice_no: `INV-D-${u}` });

  // C8 · the export shipment: container, seal, shipping bill; the pack codes scanned; the loading photo
  await openSlot(page, 'shipment', S);
  await verifyIncoming(page, e);
  await page.getByRole('button', { name: /Record Shipment for this lot/ }).click();
  await expect(page.getByLabel(/^Vehicle number/)).toHaveCount(0);                          // the domestic papers are not asked
  await page.getByTestId('order-units-0').fill('10');
  await page.getByTestId('serials').fill(serials.slice(0, 9).join('\n'));
  await expect(page.getByTestId('serials-count')).toContainText('9 pack codes');
  await page.getByLabel(/^Container number/).fill('MSKU 123456-7');
  await page.getByLabel(/^Container seal number/).fill(`SL-${u}`);
  await page.getByLabel(/^Shipping bill number/).fill('1234567');
  await page.getByLabel(/^Port of loading/).fill('Nhava Sheva');
  await page.getByLabel(/^Dispatch date/).fill(new Date().toISOString().slice(0, 10));
  await page.getByLabel(/^Destination \*/).fill('Rotterdam');
  await page.getByLabel(/^Invoice number/).fill(`INV-E-${u}`);
  await page.getByLabel(/^Loading photo/).setInputFiles({ name: 'seal.png', mimeType: 'image/png', buffer: PNG });
  await expect(page.getByTestId('preview-error')).toContainText('The codes scanned do not match the packs shipped');   // 9 codes for 10 packs
  await page.getByTestId('serials').fill(serials.join('\n'));
  await expectNoSideScroll(page);
  const se = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?SH-\d{4}/);
  const seRow = await footprint(page, se);
  expect(seRow.computed).toMatchObject({ market: 'export', serials_count: 10, container_no: 'MSKU1234567', bl_pending: true });
  // the bill of lading, after the ship sailed
  await page.goto(`/records/${seRow.id}`);
  await expect(page.locator('[data-label="loading_photo"]')).toHaveCount(1);
  await expect(page.locator('[data-computed="bl_pending"]')).toHaveText('Yes');
  await page.getByTestId('bl-no').fill(`MAEU${u}9`);
  await expectNoSideScroll(page);
  await page.getByTestId('bl-save').click();
  await expect(page.getByTestId('record-bl')).toContainText(`MAEU${u}9`);
  await expect(page.locator('[data-computed="bl_pending"]')).toHaveText('No');
  await expect(page.getByTestId('bl-panel')).toHaveCount(0);                                // once only
  await signOut(page);
});
