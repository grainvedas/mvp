// Migration 71 (Phase 3, release 4 of Veda's combined brief: Part E1, the evidence pack), on a 527 px screen. A domestic
// shipment of Basti mill's 1 kg packs is sealed at QR: the server issues the shipment's pack. The Client Manager finds it
// on the shipment's record (version 1, made at the seal), stores its files (the PDF in English and Hindi and the JSON, of
// both copies), downloads the stored PDF; the verify page says Valid with the six files' SHA-256. He makes version 2; the
// verify page of version 1 says Superseded by it. The scope dashboard and the admin's count list the packs; the client's
// own login reads them in its scope view; the buyer's page draws the shareable PDF and it is, byte for byte, the file
// GrainVeda stored (its SHA-256 is the verify page's). The rules (who issues, who reads which copy, the order's pack with
// one section per scope, the billing count) are the database's (tests/66_evidence_pack.sql).
import { test, expect, type Page } from '@playwright/test';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { signIn, signOut, expectNoSideScroll, apiAs, procure, sealLot, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 }, acceptDownloads: true });
const uniq = () => String(Date.now()).slice(-6);
const CLIENT = '00000000-0000-4000-8000-000000000201';
const S = SCOPES.bastiMill;
const id = (n: string) => `00000000-0000-4000-8000-000000000${n}`;
const idOf = (r: { ok: boolean; data: unknown }) => { expect(r.ok, JSON.stringify(r.data)).toBe(true); return String((r.data as { id: string }[])[0].id); };
const ok = (r: { ok: boolean; data: unknown }) => expect(r.ok, JSON.stringify(r.data)).toBe(true);
const sha = (b: Buffer) => createHash('sha256').update(b).digest('hex');
async function footprint(page: Page, code: string) {
  return (await (await apiAs(page)).rows('footprints', `footprint_code=eq.${code}`))[0] as { id: string; qty_out: number; computed: Record<string, unknown> };
}
async function download(page: Page, click: () => Promise<void>) {
  const [d] = await Promise.all([page.waitForEvent('download'), click()]);
  return { name: d.suggestedFilename(), bytes: readFileSync((await d.path())!) };
}

test('the evidence pack: issued at the seal, its files stored and checked, a new version, read by the client and the buyer', async ({ page, browser }) => {
  test.setTimeout(480_000);
  const u = uniq();
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);
  const had = await cm.rows('pack_skus', `client_id=eq.${CLIENT}&size=eq.1&unit=eq.kg&material=eq.pouch&market=eq.domestic`);
  const kg1 = had.length ? String(had[0].id) : idOf(await cm.insert('pack_skus', { client_id: CLIENT, size: 1, unit: 'kg', material: 'pouch', market: 'domestic', label_type: 'tag' }));
  if (had.length) ok(await cm.update('pack_skus', `id=eq.${kg1}`, { active: true }));
  const buyer = idOf(await cm.insert('buyers', { client_id: CLIENT, name: `e2e71 Delhi Wholesale ${u}`, country: 'IN', gstin: '09AAACG1234F1Z5', address: 'Azadpur Mandi, Delhi' }));
  ok(await cm.update('scopes', `id=eq.${S}`, { stage_details_required: false, record_price: false }));
  await signOut(page);

  // a domestic shipment of six 1 kg packs, recorded stage by stage by Basti mill's own people
  await signIn(page, USERS.procurement);
  const p = await procure(page, S, 'Suresh Yadav', '104', '2', '2');
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
  const q = await step(USERS.qc, p, 'qc', { qty_kg: 100, sample_qty_kg: 1, readings: { moisture_pct: 11.8, broken_pct: 2, foreign_matter_pct: 0.2, aflatoxin_ppb: 1 } });
  const m = await step(USERS.mill, q, 'milling', { input_kg: 99, head_rice_kg: 70, broken_kg: 4, husk_kg: 20, bran_kg: 5 });
  const k = await step(USERS.sorting, m, 'packing', { input_kg: 30, packets: [{ sku_id: kg1, units: 30, size_kg: 1 }] });
  await signIn(page, USERS.commercial);
  ok(await (await apiAs(page)).rpc('verify_footprint', { p_fp: (await footprint(page, k)).id }));
  await signOut(page);
  await signIn(page, USERS.cm);
  ok(await (await apiAs(page)).update('scopes', `id=eq.${S}`, { stage_details_required: true }));
  const codes = (await (await apiAs(page)).rows('packs', `footprint_id=eq.${(await footprint(page, k)).id}&status=eq.packed&order=serial&limit=6`)).map((x) => String(x.serial));
  expect(codes).toHaveLength(6);
  await signOut(page);
  const d = await step(USERS.commercial, k, 'commercial', { buyer_id: buyer, market: 'domestic', order_no: `PO-e2e71-${u}`, packs: [{ sku_id: kg1, units: 6 }] }, true);
  const sh = await step(USERS.shipment, d, 'shipment', { packs: [{ sku_id: kg1, units: 6 }], vehicle_no: 'UP53AB1234', transporter: 'Basti Roadways',
    dispatch_date: new Date().toISOString().slice(0, 10), destination: 'Delhi', invoice_no: `INV-e2e71-${u}`, lr_no: `LR-${u}`, serials: codes });

  // 1 · QR seals the lot: the server issues the shipment's pack (the QR operator does not read the whole scope: no card)
  await signIn(page, USERS.qr);
  const qrCode = await sealLot(page, S, sh);
  expect(qrCode).toMatch(/^GV-[0-9A-F]{12}$/);
  await expect(page.getByTestId('evidence-packs')).toHaveCount(0);
  await signOut(page);

  // 2 · the Client Manager: the shipment's record has its pack, version 1, made at the seal; he stores its files
  await signIn(page, USERS.cm);
  const shRow = await footprint(page, sh);
  await page.goto(`/records/${shRow.id}`);
  const card = page.getByTestId('evidence-packs');
  await expect(card).toBeVisible();
  const row = card.getByTestId('pack-row');
  await expect(row).toHaveCount(1);
  await expect(row).toContainText('Version 1');
  await expect(row).toContainText('made at the seal');
  const ref = (await row.getAttribute('data-ref'))!;
  expect(ref).toMatch(/^GV-EP-\d{6}$/);
  await expect(row.getByTestId('pack-file-pdf_en_shareable')).toHaveAttribute('data-stored', 'no');
  await expect(row.getByTestId('pack-file-pdf_hi_internal')).toBeVisible();                  // the Client Manager reads the internal copy
  await expectNoSideScroll(page);
  await row.getByTestId('pack-store').click();
  await expect(row.getByTestId('pack-file-json_en_internal')).toHaveAttribute('data-stored', 'yes', { timeout: 90_000 });
  await expect(row.getByTestId('pack-store')).toHaveCount(0);
  const pdf = await download(page, () => row.getByTestId('pack-file-pdf_en_shareable').click());
  expect(pdf.name).toBe(`grainveda-evidence-pack-${ref}-shareable-en.pdf`);
  expect(pdf.bytes.subarray(0, 5).toString()).toBe('%PDF-');
  const json = await download(page, () => row.getByTestId('pack-file-json_en_shareable').click());
  const j = JSON.parse(json.bytes.toString('utf8')) as { ref: string; copy: string; pdf_files: { lang: string; sha256: string }[]; data: Record<string, unknown> };
  expect(j).toMatchObject({ ref, copy: 'shareable' });
  expect(j.pdf_files.find((f) => f.lang === 'en')!.sha256).toBe(sha(pdf.bytes));               // the JSON keeps the PDF's fingerprint
  expect(JSON.stringify(j.data)).not.toContain('Suresh Yadav');                                // no farmer's name in the shareable copy
  expect(JSON.stringify(j.data)).not.toMatch(/price_per_kg/);

  // 3 · the verify page: Valid, a shipment's pack, its six files with their SHA-256
  await page.goto(`/d/${ref}`);
  await expect(page.getByTestId('dv-status')).toHaveAttribute('data-status', 'valid');
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Verified traceability statement: evidence pack');
  await expect(page.getByTestId('dv-subject')).toHaveText(`Shipment ${sh}`);
  await expect(page.getByTestId('dv-file')).toHaveCount(6);
  await expect(page.getByTestId('dv-files')).toContainText(`SHA-256 ${sha(pdf.bytes)}`);
  await expectNoSideScroll(page);

  // 4 · a new version on request: version 1 kept, superseded by it
  await page.goto(`/records/${shRow.id}`);
  await page.getByTestId('pack-issue').click();
  await expect(page.getByTestId('pack-issue-confirm')).toContainText('Makes version 2');
  await page.getByTestId('pack-issue-go').click();
  const cur = page.getByTestId('pack-list').getByTestId('pack-row');
  await expect(cur).toHaveCount(1);
  await expect(cur).toContainText('Version 2');
  await expect(cur).toContainText('made on request');
  const ref2 = (await cur.getAttribute('data-ref'))!;
  await expect(page.getByTestId('pack-earlier')).toContainText('Earlier versions (1)');
  await expectNoSideScroll(page);
  await page.goto(`/d/${ref}`);
  await expect(page.getByTestId('dv-status')).toHaveAttribute('data-status', 'superseded');
  await expect(page.getByTestId('dv-status')).toContainText(`replaced by ${ref2}`);

  // 5 · the scope dashboard lists the scope's packs
  await page.goto(`/dashboard/${S}`);
  const sc = page.getByTestId('evidence-packs');
  await expect(sc).toBeVisible();
  await expect(sc.locator(`[data-ref="${ref2}"]`)).toContainText(`Shipment ${sh}`);
  await expectNoSideScroll(page);

  // 6 · a buyer link for the shipment: the buyer's page draws the shareable PDF, the very file GrainVeda stored
  const link = await (await apiAs(page)).rpc('create_buyer_link', { p_fp: shRow.id, p_days: 7, p_note: 'e2e71' });
  ok(link);
  const token = (link.data as { token: string }).token;
  await signOut(page);
  // the stored files of version 2 first, so the buyer's copy is checked against them
  await signIn(page, USERS.cm);
  await page.goto(`/records/${shRow.id}`);
  await page.getByTestId('pack-list').getByTestId('pack-store').click();
  await expect(page.getByTestId('pack-list').getByTestId('pack-file-pdf_en_shareable')).toHaveAttribute('data-stored', 'yes', { timeout: 90_000 });
  const stored = await download(page, () => page.getByTestId('pack-list').getByTestId('pack-file-pdf_en_shareable').click());
  await signOut(page);
  const buyerCtx = await browser.newContext({ viewport: { width: 527, height: 900 }, acceptDownloads: true });
  const bp = await buyerCtx.newPage();
  await bp.goto(`/b#${token}`);
  const bpack = bp.getByTestId('bv-pack');
  await expect(bpack).toBeVisible();
  await expect(bpack).toContainText(ref2);
  await expectNoSideScroll(bp);
  const mine = await download(bp, () => bpack.getByTestId('bv-pack-pdf-en').click());
  expect(sha(mine.bytes)).toBe(sha(stored.bytes));
  const bj = await download(bp, () => bpack.getByTestId('bv-pack-json').click());
  expect(JSON.stringify(JSON.parse(bj.bytes.toString('utf8')).data)).not.toContain('Suresh Yadav');
  await buyerCtx.close();

  // 7 · the client's own login: the scope view lists the packs with their files
  await signIn(page, USERS.view);
  await page.goto(`/portfolio/scope/${S}`);
  const cv = page.getByTestId('evidence-packs');
  await expect(cv).toBeVisible();
  await expect(cv.locator(`[data-ref="${ref2}"]`)).toBeVisible();
  await expect(cv.locator(`[data-ref="${ref2}"]`).getByTestId('pack-file-pdf_en_shareable')).toHaveAttribute('data-stored', 'yes');
  await expect(cv.getByTestId('pack-store')).toHaveCount(0);                                  // a client account stores no file
  await expect(cv.getByTestId('pack-issue')).toHaveCount(0);
  await expectNoSideScroll(page);
  await signOut(page);

  // 8 · the admin's count of what was issued: the evidence packs column
  await signIn(page, USERS.admin);
  await page.goto('/');
  const t = page.getByTestId('ov-reports-table');
  await expect(t).toBeVisible();
  const n = Number(await t.locator('tr', { hasText: /Prasaadam/ }).first().getByTestId('ov-reports-packs').textContent());
  expect(n).toBeGreaterThanOrEqual(2);
  await expectNoSideScroll(page);
  await signOut(page);

  // the test's list rows put away; Basti mill as the other tests expect it
  await signIn(page, USERS.cm);
  const cm2 = await apiAs(page);
  for (const r of await cm2.rows('buyers', 'name=like.e2e71*&active=eq.true')) await cm2.update('buyers', `id=eq.${r.id}`, { active: false });
  await cm2.update('scopes', `id=eq.${S}`, { stage_details_required: false, record_price: false });
  await signOut(page);
});
