// Migration 61 (Phase 1, release 3 of Veda's combined brief of 19 Oct 2026: release 2's corrections; the shown parts of
// E2.2 to E2.5), on a 527 px screen. Two farmers of two villages sell at the farm gate in Bansi; their Collection Batch
// weighs 2 kg less; QC takes 195 kg and the 3 kg left are closed as floor loss; the lot is sealed. The journey page shows
// the closure and the batch's floor loss, and prints a heading with client, crop, season and place; the journey's
// shareable CSV has the closure as its own line; the dashboard shows each stage's mass balance; the public page says
// "Collection Batch", "2 farmers from 2 villages" and one line for both purchases. Every rule is the database's
// (tests/56_export_corrections.sql).
import { test, expect, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { signIn, signOut, expectNoSideScroll, apiAs, procure, sealLot, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const S = SCOPES.bansiBatch;
const CLIENT = '00000000-0000-4000-8000-000000000201';
const id = (n: string) => `00000000-0000-4000-8000-000000000${n}`;
const ok = (r: { ok: boolean; data: unknown }) => expect(r.ok, JSON.stringify(r.data)).toBe(true);
async function footprint(page: Page, code: string) {
  return (await (await apiAs(page)).rows('footprints', `footprint_code=eq.${code}`))[0] as { id: string; qty_out: number; footprint_code: string };
}

test('a collection batch with a closure: the trace, the CSV line, the mass balance, the public page', async ({ page }) => {
  test.setTimeout(360_000);
  await signIn(page, USERS.procurement);
  const p1 = await procure(page, S, 'Ram Achal', '102', '2', '1');
  const p2 = await procure(page, S, 'Mohan Lal', '102', '2', '1');
  await signOut(page);

  // the batch (by API: its form is tested in phase24 and phase26), re-weighed 2 kg less
  await signIn(page, USERS.villageBatch);
  const vbApi = await apiAs(page);
  const l1 = await footprint(page, p1), l2 = await footprint(page, p2);
  for (const l of [l1, l2]) ok(await vbApi.rpc('verify_footprint', { p_fp: l.id }));
  const vbr = await vbApi.insert('footprints', { scope_id: S, client_id: CLIENT, stage_type: 'village_batch', prev_footprint_id: l1.id, created_by: id('315'),
    payload: { source_footprint_ids: [l1.id, l2.id], reweighed_kg: 198 } });
  ok(vbr);
  const vb = (vbr.data as { id: string; footprint_code: string }[])[0];
  await signOut(page);

  // QC takes 195 kg (by API: its form is tested in every chain); the 3 kg left are closed as floor loss
  await signIn(page, USERS.qc);
  const qcApi = await apiAs(page);
  ok(await qcApi.rpc('verify_footprint', { p_fp: vb.id }));
  const qr = await qcApi.insert('footprints', { scope_id: S, client_id: CLIENT, stage_type: 'qc', prev_footprint_id: vb.id, created_by: id('306'),
    payload: { qty_kg: 195, sample_qty_kg: 1, readings: { moisture_pct: 11.8, broken_pct: 2, foreign_matter_pct: 0.2 } } });
  ok(qr);
  const qc = (qr.data as { id: string; footprint_code: string }[])[0];
  ok(await qcApi.rpc('close_lot', { p_fp: vb.id, p_reason: 'Practice (test): swept from the floor, not fit to mill' }));
  await signOut(page);
  await signIn(page, USERS.qr);
  const code = await sealLot(page, S, qc.footprint_code);
  const seal = (await (await apiAs(page)).rows('qr_seals', `qr_code=eq.${code}`))[0] as { footprint_id: string };
  await signOut(page);

  // the Client Manager: the journey page and its CSV
  await signIn(page, USERS.cm);
  await page.goto(`/trace/${seal.footprint_id}`);
  await expect(page.getByTestId('trace-closure')).toBeVisible();
  await expect(page.getByTestId('trace-closure')).toContainText('Closed as floor loss: 3 kg');
  await expect(page.getByTestId('trace-parts').filter({ hasText: 'Floor loss 2 kg' })).toBeVisible();
  await expect(page.getByTestId('trace-print-scope')).toBeHidden();                     // printed only
  await expect(page.getByTestId('trace-print-scope')).toHaveText(/ · Kalanamak rice · KH26 · Bansi batch, Uttar Pradesh$/);
  await expectNoSideScroll(page);
  const dl = page.waitForEvent('download');
  await page.getByTestId('trace-csv').click();
  const csv = readFileSync((await (await dl).path())!, 'utf8');
  const lines = csv.split('\r\n');
  expect(lines[0]).toContain('Floor loss (kg)');
  expect(lines[0]).not.toContain('Raw values');
  expect(lines.some((l) => l.startsWith(`,${vb.footprint_code},Closed as floor loss,`))).toBe(true);
  expect(csv).not.toContain('Ram Achal');
  expect(csv).toMatch(/No prices, no farmers' names or phones, no internal IDs\./);

  // the dashboard: each stage's mass balance
  await page.goto(`/dashboard/${S}`);
  const vbRow = page.getByTestId('balance-row').and(page.locator('[data-stage="village_batch"]'));
  await expect(vbRow).toBeVisible();
  await expect(vbRow).toHaveAttribute('data-balanced', 'yes');
  await expectNoSideScroll(page);
  await signOut(page);

  // the public page
  await page.goto(`/verify/${code}`);
  await expect(page.getByTestId('pv-bought-from')).toHaveText('Bought from 2 farmers: 200 kg');
  await expect(page.getByTestId('pv-bought-villages')).toHaveText(/^(Bansi|Domariyaganj) 50 % · (Bansi|Domariyaganj) 50 %$/);
  await expect(page.getByTestId('pv-batch-farmers')).toHaveText('2 farmers from 2 villages');
  await expect(page.getByText('Collection Batch', { exact: true })).toBeVisible();
  await expect(page.getByText('Village batch')).toHaveCount(0);
  await expectNoSideScroll(page);
});
