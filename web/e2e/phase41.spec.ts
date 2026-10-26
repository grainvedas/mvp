// Migration 70 (Phase 3, release 3 of Veda's combined brief: Part D), on a 527 px screen. Commercial makes a client
// order (one buyer, one order number, one invoice) from Client orders in his menu; at Commercial in Basti mill he
// records a part from a packed batch by choosing the order: the order's buyer, market and number replace the form's
// fields; the order's page then has Basti mill's section; the Shipment form takes the order's invoice. The client's own
// login lists the order in Portfolio → Across scopes. A part from a second state, the parts refused (GI, market, the
// client not Active), the one invoice across states and who reads which section are the database's
// (tests/65_client_orders.sql): the local stack has one state with a mill.
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, apiAs, openSlot, reviewAndSave, procure, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const uniq = () => String(Date.now()).slice(-6);
const CLIENT = '00000000-0000-4000-8000-000000000201';
const S = SCOPES.bastiMill;
const id = (n: string) => `00000000-0000-4000-8000-000000000${n}`;
const idOf = (r: { ok: boolean; data: unknown }) => { expect(r.ok, JSON.stringify(r.data)).toBe(true); return String((r.data as { id: string }[])[0].id); };
const ok = (r: { ok: boolean; data: unknown }) => expect(r.ok, JSON.stringify(r.data)).toBe(true);
async function footprint(page: Page, code: string) {
  return (await (await apiAs(page)).rows('footprints', `footprint_code=eq.${code}`))[0] as { id: string; qty_out: number; computed: Record<string, unknown>; payload: Record<string, unknown> };
}

test('one order drawing on several scopes: made, a part chosen at Commercial, its page by scope, its invoice at Shipment', async ({ page }) => {
  test.setTimeout(360_000);
  const u = uniq();
  // the client's lists: a pack type and a buyer; Basti mill without the stage details (as phase26 builds its lot)
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  const had = await cm.rows('pack_skus', `client_id=eq.${CLIENT}&size=eq.1&unit=eq.kg&material=eq.pouch&market=eq.domestic`);
  const kg1 = had.length ? String(had[0].id) : idOf(await cm.insert('pack_skus', { client_id: CLIENT, size: 1, unit: 'kg', material: 'pouch', market: 'domestic', label_type: 'tag' }));
  if (had.length) ok(await cm.update('pack_skus', `id=eq.${kg1}`, { active: true }));
  const buyer = `e2e70 Delhi Wholesale ${u}`;
  idOf(await cm.insert('buyers', { client_id: CLIENT, name: buyer, country: 'IN', gstin: '09AAACG1234F1Z5', address: 'Azadpur Mandi, Delhi' }));
  await cm.update('scopes', `id=eq.${S}`, { stage_details_required: false, record_price: false });
  await signOut(page);

  // a batch of 1 kg pouches in Basti mill, by its own operators
  await signIn(page, USERS.procurement);
  const p = await procure(page, S, 'Suresh Yadav', '104', '2', '2');
  await signOut(page);
  const step = async (who: typeof USERS.qc, verify: string, stage: string, payload: Record<string, unknown>) => {
    await signIn(page, who);
    const api = await apiAs(page);
    ok(await api.rpc('verify_footprint', { p_fp: (await footprint(page, verify)).id }));
    const r = await api.insert('footprints', { scope_id: S, client_id: CLIENT, stage_type: stage, prev_footprint_id: (await footprint(page, verify)).id, created_by: id(who.key), payload });
    expect(r.ok, JSON.stringify(r.data)).toBe(true);
    await signOut(page);
    return String((r.data as { footprint_code: string }[])[0].footprint_code);
  };
  const q = await step(USERS.qc, p, 'qc', { qty_kg: 100, sample_qty_kg: 1, readings: { moisture_pct: 11.8, broken_pct: 2, foreign_matter_pct: 0.2, aflatoxin_ppb: 1 } });
  const m = await step(USERS.mill, q, 'milling', { input_kg: 99, head_rice_kg: 70, broken_kg: 4, husk_kg: 20, bran_kg: 5 });
  const k = await step(USERS.sorting, m, 'packing', { input_kg: 30, packets: [{ sku_id: kg1, units: 30, size_kg: 1 }] });

  // 1 · Commercial: Client orders in his menu; a new order (the client and crop, the buyer, domestic, its number and invoice)
  await signIn(page, USERS.commercial);
  ok(await (await apiAs(page)).rpc('verify_footprint', { p_fp: (await footprint(page, k)).id }));
  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: /Client orders/ }).click();
  await expect(page).toHaveURL(/\/orders$/);
  await page.getByTestId('ord-new-open').click();
  if (await page.getByTestId('ord-cc').count()) {
    const cc = await page.getByTestId('ord-cc').locator('option', { hasText: /Kalanamak/ }).first().getAttribute('value');
    await page.getByTestId('ord-cc').selectOption(cc!);
  }
  await page.getByTestId('ord-buyer').selectOption({ label: `${buyer} · IN` });
  await page.getByTestId('ord-market').selectOption('domestic');
  await expect(page.getByTestId('ord-dest')).toHaveCount(0);                                  // a domestic order has no destination
  await page.getByTestId('ord-no').fill(`PO-e2e70-${u}`);
  await page.getByTestId('ord-inv').fill(`INV-e2e70-${u}`);
  await expectNoSideScroll(page);
  await page.getByTestId('ord-save').click();
  await expect(page.getByTestId('order-page')).toBeVisible();
  const orderUrl = page.url();
  const orderId = orderUrl.split('/orders/')[1];
  const code = (await page.locator('h1').textContent())!.trim();
  expect(code).toMatch(/^ORD-PRSDM-\d{4}$/);
  await expect(page.getByTestId('ord-invoice')).toContainText(`INV-e2e70-${u}`);
  await expect(page.getByTestId('ord-section')).toHaveCount(0);
  await expect(page.getByTestId('ord-cancel')).toBeVisible();                                  // no part yet: it could be cancelled
  await expectNoSideScroll(page);

  // 2 · at Commercial in Basti mill: "Part of a client order"; the order's fields hide; the packs stay
  await openSlot(page, 'commercial', S);
  await page.getByTestId('incoming-row').filter({ hasText: k }).click();
  await page.getByRole('button', { name: /Record Commercial Clearance for this lot/ }).click();
  const picker = page.getByTestId('pick-client-order').locator('select');
  await expect(picker.locator('option', { hasText: code })).toHaveCount(1);
  await expect(page.getByLabel(/^Market/)).toHaveCount(1);
  await picker.selectOption(orderId);
  await expect(page.getByTestId('client-order-chosen')).toContainText(buyer);
  await expect(page.getByTestId('client-order-chosen')).toContainText(`INV-e2e70-${u}`);
  await expect(page.getByLabel(/^Market/)).toHaveCount(0);                                     // the order's market, written by the server
  await expect(page.getByLabel(/^Order or contract number/)).toHaveCount(0);
  await expect(page.getByLabel(/^Buyer/)).toHaveCount(0);
  await page.getByTestId('order-units-0').fill('6');
  await expectNoSideScroll(page);
  const part = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?CM-\d{4}/);
  const row = await footprint(page, part);
  expect(Number(row.qty_out)).toBe(6);
  expect(row.computed).toMatchObject({ client_order: code, buyer, order_no: `PO-e2e70-${u}`, market: 'domestic' });
  await page.goto(`/records/${row.id}`);
  await expect(page.locator('[data-computed="client_order"]')).toContainText(code);

  // 3 · the order's page: Basti mill's section, the part, its batch; nothing to cancel now
  await page.goto(orderUrl);
  await expect(page.getByTestId('ord-section')).toHaveCount(1);
  await expect(page.getByTestId('ord-section')).toContainText('Basti mill');
  await expect(page.getByTestId('ord-part')).toContainText(part);
  await expect(page.getByTestId('ord-part')).toContainText('6 × 1 kg');
  await expect(page.getByTestId('ord-cancel')).toHaveCount(0);
  await expectNoSideScroll(page);
  await signOut(page);

  // 4 · Shipment: the form says the order's one invoice and fills it in
  await signIn(page, USERS.shipment);
  ok(await (await apiAs(page)).rpc('verify_footprint', { p_fp: row.id }));
  await openSlot(page, 'shipment', S);
  await page.getByTestId('incoming-row').filter({ hasText: part }).click();
  await page.getByRole('button', { name: /Record Shipment for this lot/ }).click();
  await expect(page.getByTestId('part-order-note')).toContainText(`INV-e2e70-${u}`);
  await expectNoSideScroll(page);
  await signOut(page);

  // 5 · the client's own login: Portfolio → Across scopes lists the client order with its part
  await signIn(page, USERS.view);
  await page.goto('/portfolio?tab=across');
  const co = page.getByTestId('cv-client-order').filter({ hasText: code });
  await expect(co).toBeVisible();
  await expect(co).toContainText(`PO-e2e70-${u}`);
  await expect(page.getByTestId('cv-order').filter({ hasText: `PO-e2e70-${u}` })).toContainText(`part of ${code}`);
  await expectNoSideScroll(page);
  await co.getByRole('link').click();
  await expect(page.getByTestId('order-page')).toBeVisible();
  await expect(page.getByTestId('ord-section')).toHaveCount(1);
  await expect(page.getByTestId('ord-invoice-form')).toHaveCount(0);                          // a client account changes nothing
  await signOut(page);

  // the test's list rows put away; Basti mill as the other tests expect it
  await signIn(page, USERS.cm);
  const cm2 = await apiAs(page);
  for (const r of await cm2.rows('buyers', 'name=like.e2e70*&active=eq.true')) await cm2.update('buyers', `id=eq.${r.id}`, { active: false });
  await cm2.update('scopes', `id=eq.${S}`, { stage_details_required: false, record_price: false });
  await signOut(page);
});
