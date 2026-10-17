// Migration 58 (release 11; Veda, 16 Oct 2026: "There should a mechanism to choose packs and in future there will be
// more than 1 lakhs packs"; "carton size - cm sets them in the pack list"; carton labels and loading "share suggestion";
// on the HR Admin's screens "report to - it sees all people which should not be the case", "department ... there should
// be drop down"; "proceed with 58"), on a 527 px screen. The Client Manager sets packs per carton on a pack type; Packing
// makes the cartons by itself and prints their labels (A4, 8 a page, or a 100 × 150 mm label printer); the order chooses
// a carton and the oldest free one fills the rest; the Shipment scans two carton codes for 40 packs, and a carton set
// aside for nobody is refused as it comes. HR: Reports to offers the managers of the person's state, the department is
// a list the HR Admin keeps. Every rule is the database's (tests/53_cartons_people_choices.sql).
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, apiAs, openSlot, verifyIncoming, procure, reviewAndSave, USERS, SCOPES, PEOPLE } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const CLIENT = '00000000-0000-4000-8000-000000000201';
const S = SCOPES.bastiMill;
const id = (n: string) => `00000000-0000-4000-8000-000000000${n}`;
const ok = (r: { ok: boolean; data: unknown }) => expect(r.ok, JSON.stringify(r.data)).toBe(true);
const idOf = (r: { ok: boolean; data: unknown }) => { ok(r); return String((r.data as { id: string }[])[0].id); };
const uniq = () => String(Date.now()).slice(-6);
const SHOTS = process.env.SHOTS_DIR;

async function footprint(page: Page, code: string) {
  return (await (await apiAs(page)).rows('footprints', `footprint_code=eq.${code}`))[0] as { id: string; computed: Record<string, unknown> };
}

/** Scope 05 back as the other tests expect it; the test's buyers put away. Run whatever happened. */
test.afterAll(async ({ browser }) => {
  const page = await browser.newPage();
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  await cm.update('scopes', `id=eq.${S}`, { stage_details_required: false, record_price: false });
  for (const r of await cm.rows('buyers', 'name=like.e2e58*&active=eq.true')) await cm.update('buyers', `id=eq.${r.id}`, { active: false });
  await page.close();
});

test('cartons: the pack list sets the size, Packing makes them and prints their labels, an order chooses them, the Shipment scans them', async ({ page }) => {
  test.setTimeout(420_000);
  const u = uniq();
  // the Client Manager: a pack type of his list goes in cartons of 20 (Set-up lists → Packs)
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  const had = await cm.rows('pack_skus', `client_id=eq.${CLIENT}&size=eq.1&unit=eq.kg&material=eq.vacuum&market=eq.domestic`);
  const sku = had.length ? String(had[0].id) : idOf(await cm.insert('pack_skus', { client_id: CLIENT, size: 1, unit: 'kg', material: 'vacuum', market: 'domestic', label_type: 'printed' }));
  ok(await cm.update('pack_skus', `id=eq.${sku}`, { active: true, packs_per_carton: null }));
  const buyer = idOf(await cm.insert('buyers', { client_id: CLIENT, name: `e2e58 Lucknow Stores ${u}`, country: 'IN', address: 'Aminabad, Lucknow', gstin: '09AAACL1234E1Z5' }));
  ok(await cm.update('scopes', `id=eq.${S}`, { stage_details_required: false, record_price: false }));
  await page.goto('/setup?tab=lists');
  await page.getByTestId('set-list-pack_skus').click();
  const row = page.getByTestId('set-row').filter({ hasText: '1 kg Vacuum pack' }).filter({ hasText: 'Domestic' });
  await expect(row).toContainText('Not in cartons');
  await row.getByRole('button', { name: 'Edit' }).click();
  await page.getByTestId('set-pack_skus-packs_per_carton').fill('0');
  await page.getByTestId('set-save').click();
  await expect(page.getByTestId('set-problems')).toContainText('a whole number from 1 to 1,000');
  await page.getByTestId('set-pack_skus-packs_per_carton').fill('20');
  await expectNoSideScroll(page);
  await page.getByTestId('set-save').click();
  await expect(row).toContainText('Packs per carton20');
  await signOut(page);

  // the lot to Packing (the farm-gate record on the phone, the steps between by the API, as phase 29)
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
  const k = await step(USERS.sorting, m, 'packing', { input_kg: 70, packets: [{ sku_id: sku, units: 69, size_kg: 1 }] });

  // Packing: the cartons were made by the save; their labels, on two papers
  await signIn(page, USERS.sorting);
  const kRow = await footprint(page, k);
  const cartons = (await (await apiAs(page)).rows('cartons', `footprint_id=eq.${kRow.id}&order=seq`)).map((c) => ({ code: String(c.code), n: Number(c.n) }));
  expect(cartons.map((c) => c.n)).toEqual([20, 20, 20, 9]);                                   // 69 packs: three of 20, the last holds what is left
  const [c1, c2, c3] = cartons.map((c) => c.code);
  await page.goto(`/records/${kRow.id}/labels`);
  await page.getByTestId('labels-cartons').click();
  await expect(page.getByTestId('labels-cartons')).toHaveText('Carton labels (4)');
  await expect(page.getByTestId('cartons-make')).toContainText('4 cartons');
  await page.getByTestId('cartons-go').click();
  await expect(page.getByTestId('carton-label')).toHaveCount(4);
  await expect(page.getByTestId('carton-sheet')).toHaveAttribute('data-paper', 'a4_8');
  const first = page.getByTestId('carton-label').first();
  await expect(first).toContainText(c1);
  await expect(first).toContainText('20 packs · 1 kg vacuum');
  await expect(first).toContainText('Packs 0001 to 0020');
  await expect(first.locator('img')).toHaveAttribute('alt', `QR ${c1}`);
  await expect(page.getByTestId('carton-label').last()).toContainText('9 packs');
  await expectNoSideScroll(page);
  if (SHOTS) { await page.setViewportSize({ width: 390, height: 844 }); await page.screenshot({ path: `${SHOTS}/58_carton_labels_a4_390.png`, fullPage: true }); await page.setViewportSize({ width: 527, height: 900 }); }
  await page.getByRole('button', { name: 'Change the paper' }).click();
  await page.getByTestId('labels-paper').selectOption('label_100x150');
  await page.getByTestId('cartons-go').click();
  await expect(page.getByTestId('carton-sheet')).toHaveAttribute('data-paper', 'label_100x150');
  await expectNoSideScroll(page);
  if (SHOTS) await page.getByTestId('carton-label').first().screenshot({ path: `${SHOTS}/58_carton_label_100x150.png` });
  await page.getByTestId('labels-packs').click();
  await expect(page.getByTestId('labels-make')).toBeVisible();                              // the pack labels as before
  await signOut(page);

  // Commercial: an order of 40 packs; it chooses the third carton, the oldest free one fills the rest
  await signIn(page, USERS.commercial);
  ok(await (await apiAs(page)).rpc('verify_footprint', { p_fp: kRow.id }));
  await signOut(page);
  await signIn(page, USERS.cm);
  ok(await (await apiAs(page)).update('scopes', `id=eq.${S}`, { stage_details_required: true }));
  await signOut(page);
  await signIn(page, USERS.commercial);
  await openSlot(page, 'commercial', S);
  await page.getByTestId('incoming-row').filter({ hasText: k }).click();
  await page.getByRole('button', { name: /Record Commercial Clearance for this lot/ }).click();
  await page.getByTestId('pick-buyer_id').selectOption({ label: `e2e58 Lucknow Stores ${u} · IN` });
  await page.getByLabel(/^Market/).selectOption('domestic');
  await page.getByLabel(/^Order or contract number/).fill(`PO58-${u}`);
  await page.getByTestId('order-units-0').fill('40');
  const oc = page.getByTestId('order-cartons');
  await expect(oc.getByTestId('oc-sku')).toContainText('4 free cartons · 69 packs · 20 per carton');
  await expect(oc.getByTestId('oc-oldest')).toBeVisible();
  await oc.getByTestId('oc-choose').check();
  await oc.getByTestId('oc-from').fill(c3);
  await oc.getByTestId('oc-to').fill(c3.slice(-2));
  await oc.getByTestId('oc-add').click();
  await expect(oc.getByTestId('oc-chosen')).toContainText(c3);
  await expect(oc.getByTestId('oc-sku-n')).toContainText('20 of the 40 packs in the cartons chosen');
  await expectNoSideScroll(page);
  if (SHOTS) { await page.setViewportSize({ width: 390, height: 844 }); await oc.screenshot({ path: `${SHOTS}/58_order_cartons_390.png` }); await page.setViewportSize({ width: 527, height: 900 }); }
  const d = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?CM-\d{4}/);
  const dRow = await footprint(page, d);
  expect((dRow.computed.units as { code: string; kind: string }[]).map((x) => x.code)).toEqual([c3, c1]);
  await page.goto(`/records/${dRow.id}`);
  await expect(page.locator('[data-computed="units"]')).toHaveText('2 cartons (40 packs)');
  await signOut(page);

  // Shipment: two carton codes for 40 packs; a carton not set aside is said as it comes
  await signIn(page, USERS.shipment);
  await openSlot(page, 'shipment', S);
  await verifyIncoming(page, d);
  await page.getByRole('button', { name: /Record Shipment for this lot/ }).click();
  await page.getByTestId('order-units-0').fill('40');
  await page.getByTestId('serials').fill([c3, c2].join('\n'));
  await expect(page.getByTestId('pc-bad')).toContainText('Not set aside for this order');
  await expect(page.getByTestId('pc-progress')).toContainText('20 of 40 packs loaded · 1 carton');
  await page.getByRole('button', { name: `Remove: ${c2}` }).click();
  await page.getByTestId('serials').fill([c3, c1].join('\n'));
  await expect(page.getByTestId('pc-bad')).toHaveCount(0);
  await expect(page.getByTestId('pc-progress')).toContainText('40 of 40 packs loaded · 2 cartons');
  await expect(page.getByTestId('pc-run').first()).toContainText('20 packs');
  await page.getByLabel(/^Vehicle number/).fill('UP53AB1234');
  await page.getByLabel(/^Transporter/).fill('Basti Roadways');
  await page.getByLabel(/^Dispatch date/).fill(new Date().toISOString().slice(0, 10));
  await page.getByLabel(/^Destination \*/).fill('Lucknow');
  await page.getByLabel(/^Invoice number/).fill(`INV58-${u}`);
  await page.getByLabel(/^LR number/).fill(`LR58-${u}`);
  await expectNoSideScroll(page);
  if (SHOTS) { await page.setViewportSize({ width: 390, height: 844 }); await page.getByTestId('pack-codes').screenshot({ path: `${SHOTS}/58_pack_codes_cartons_390.png` }); await page.setViewportSize({ width: 527, height: 900 }); }
  const sh = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?SH-\d{4}/);
  expect((await footprint(page, sh)).computed).toMatchObject({ serials_count: 40, cartons_count: 2 });
  await signOut(page);
});

test('HR: Reports to offers the managers of the person\'s state; the department is the HR Admin\'s list', async ({ page }) => {
  test.setTimeout(240_000);
  const u = uniq();
  await signIn(page, USERS.hrAdmin);
  // the HR Admin's list (Templates page): a department added, then retired
  await page.goto('/hr/templates');
  const deps = page.getByTestId('departments');
  await expect(deps.getByTestId('department-row').first()).toContainText('Operations');
  await deps.getByTestId('dep-new').fill(`e2e58 Seed Unit ${u}`);
  await deps.getByTestId('dep-add').click();
  const mine = deps.getByTestId('department-row').filter({ hasText: `e2e58 Seed Unit ${u}` });
  await expect(mine).toHaveAttribute('data-active', 'yes');
  await expectNoSideScroll(page);
  // Add joiner: the choices follow the state the person is based in
  await page.goto('/hr/joiners/new');
  await page.locator('#j-base').selectOption({ label: 'Uttar Pradesh' });
  const reports = page.locator('#j-reports');
  await expect(reports.locator('option', { hasText: 'UP State Manager · State Manager, Senior Manager' })).toHaveCount(1);
  await expect(reports.locator('option', { hasText: 'Prasaadam Client Manager' })).toHaveCount(1);
  for (const not of ['Procurement Op (field)', 'Ravi Kumar', 'QC Technician']) await expect(reports.locator('option', { hasText: not })).toHaveCount(0);
  await expect(page.locator('#j-buddy option', { hasText: 'QC Technician' })).toHaveCount(1);
  await expect(page.locator('#j-dept option', { hasText: `e2e58 Seed Unit ${u}` })).toHaveCount(1);
  await expect(page.locator('#j-dept')).toHaveJSProperty('tagName', 'SELECT');
  await page.locator('#j-base').selectOption({ label: 'Assam' });
  await expect(reports.locator('option', { hasText: 'UP State Manager' })).toHaveCount(0);   // not a manager of Assam
  await expect(reports.locator('option', { hasText: 'Veda (Admin)' })).toHaveCount(1);        // head office, for everyone
  await expectNoSideScroll(page);
  if (SHOTS) { await page.setViewportSize({ width: 390, height: 844 }); await page.locator('#j-reports').screenshot({ path: `${SHOTS}/58_reports_to_390.png` }); await page.setViewportSize({ width: 527, height: 900 }); }
  // a person's record: the department from the list, Reports to among UP's managers
  await page.goto(`/hr/joiners/${PEOPLE.ravi}`);
  await page.getByTestId('edit-org').click();
  await expect(page.locator('#o-dept')).toHaveValue('Operations');
  await page.locator('#o-dept').selectOption(`e2e58 Seed Unit ${u}`);
  await expect(page.locator('#o-reports option', { hasText: 'Ravi Kumar' })).toHaveCount(0);
  await page.locator('#o-reports').selectOption({ label: 'UP State Manager · State Manager, Senior Manager' });
  await page.getByRole('form', { name: 'About the person' }).getByRole('button', { name: 'Save' }).click();
  await expect(page.getByTestId('org-facts')).toContainText(`e2e58 Seed Unit ${u}`);
  await expect(page.getByTestId('org-facts')).toContainText('UP State Manager');
  // put back; the test's department retired (never deleted)
  ok(await (await apiAs(page)).rpc('update_joiner', { p_employee: PEOPLE.ravi, p: { department: 'Operations', reports_to: id('303') } }));
  await page.goto('/hr/templates');
  await page.getByTestId('departments').getByTestId('department-row').filter({ hasText: `e2e58 Seed Unit ${u}` }).getByRole('button', { name: 'Retire' }).click();
  await expect(page.getByTestId('departments').getByTestId('department-row').filter({ hasText: `e2e58 Seed Unit ${u}` })).toHaveAttribute('data-active', 'no');
  await signOut(page);
});
