// Migration 60 (Phase 1, release 2 of Veda's combined brief, 19 Oct 2026, Part C: the exports), on a 527 px screen. A lot
// of Siddharthnagar is recorded, checked and sealed; its journey and its season are downloaded: the shareable copy carries
// no person's or farmer's name, the internal copy does and says it is internal; the admin, who holds no part of the scope,
// is offered the shareable copy only; every download is in the Audit log; the journey prints with its own heading. Every
// rule is the database's (tests/55_exports.sql).
import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import readXlsxFile, { readSheetNames } from 'read-excel-file/node';
import { signIn, signOut, expectNoSideScroll, apiAs, procure, recordQc, sealLot, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const S = SCOPES.siddharthnagar;
const id = (n: string) => `00000000-0000-4000-8000-000000000${n}`;

test('the journey and the season: a shareable copy without names, an internal copy for the scope\'s people, each download in the Audit log', async ({ page }) => {
  test.setTimeout(360_000);
  await signIn(page, USERS.procurement);
  const p = await procure(page, S, 'Mohan Lal', '102', '1', '2');
  await signOut(page);
  await signIn(page, USERS.qc);
  const q = await recordQc(page, S, p, '11.8');
  await signOut(page);
  await signIn(page, USERS.qr);
  const qr = await sealLot(page, S, q);
  const seal = (await (await apiAs(page)).rows('qr_seals', `qr_code=eq.${qr}`))[0] as { footprint_id: string };
  await signOut(page);

  // the Client Manager: both copies of the journey
  await signIn(page, USERS.cm);
  const cmName = String(((await (await apiAs(page)).rows('app_users', `id=eq.${id(USERS.cm.key)}&select=display_name`))[0] as { display_name: string }).display_name);
  await page.goto(`/trace/${seal.footprint_id}`);
  await expect(page.getByTestId('trace-steps').locator('> li')).toHaveCount(3);
  await expect(page.getByTestId('trace-print-head')).toHaveCount(1);
  await expect(page.getByTestId('trace-print-head')).toBeHidden();                 // shown only when printed
  await expect(page.getByTestId('trace-copies')).toBeVisible();
  await expectNoSideScroll(page);
  let dl = page.waitForEvent('download');
  await page.getByTestId('trace-csv').click();
  let csv = readFileSync((await (await dl).path())!, 'utf8');
  expect(csv).toContain('Step,Record,Stage,Status');
  expect(csv).toContain('Share (%)');
  expect(csv).toContain(qr);
  expect(csv).not.toContain('Mohan Lal');
  expect(csv).not.toContain(cmName);
  expect(csv).not.toContain('Entered values');
  expect(csv).toMatch(/Shareable copy made by GrainVeda on .* IST\. It holds no personal names and no prices\./);
  dl = page.waitForEvent('download');
  await page.getByTestId('trace-csv-internal').click();
  csv = readFileSync((await (await dl).path())!, 'utf8');
  expect(csv).toContain('Mohan Lal');
  expect(csv).toContain('Recorded by');
  expect(csv.split('\r\n')[0].replace(/^﻿/, '').split(',').at(-1)).toBe('Entered values (raw)');
  expect(csv).toMatch(/INTERNAL COPY: .* Do not forward it\./);

  // the season, internal, as one Excel file
  await page.goto(`/dashboard/${S}`);
  await expect(page.getByTestId('season-xlsx-internal')).toBeVisible();
  await expectNoSideScroll(page);
  dl = page.waitForEvent('download');
  await page.getByTestId('season-xlsx-internal').click();
  const file = (await (await dl).path())!;
  expect(await readSheetNames(file)).toEqual(['Heading', 'Summary', 'Records']);
  const recs = (await readXlsxFile(file, { sheet: 'Records' })) as unknown[][];
  expect(recs[0]).toContain('Farmer');
  expect(recs.some((r) => r.includes('Mohan Lal'))).toBe(true);
  const heading = (await readXlsxFile(file, { sheet: 'Heading' })) as unknown[][];
  expect(heading.some((r) => r[0] === 'Copy' && r[1] === 'Internal copy')).toBe(true);
  await signOut(page);

  // the admin oversees: the shareable copy only, the internal one is not offered
  await signIn(page, USERS.admin);
  await page.goto(`/trace/${seal.footprint_id}`);
  await expect(page.getByTestId('trace-csv')).toBeVisible();
  await expect(page.getByTestId('trace-csv-internal')).toHaveCount(0);
  const api = await apiAs(page);
  const refused = await api.rpc('export_journey', { p_fp: seal.footprint_id, p_copy: 'internal' });
  expect(refused.ok).toBe(false);
  // every download above is in the Audit log
  const logged = await api.rows('audit_log', `action=eq.export_downloaded&target=eq.${seal.footprint_id}&select=detail`);
  expect(logged.map((r) => `${(r.detail as { kind: string }).kind}:${(r.detail as { copy: string }).copy}`).sort()).toEqual(['journey:internal', 'journey:shareable']);
  const season = await api.rows('audit_log', `action=eq.export_downloaded&target=eq.${S}&select=detail&order=id.desc&limit=1`);
  expect((season[0].detail as { copy: string }).copy).toBe('internal');
  await page.goto(`/dashboard/${S}`);
  await expect(page.getByTestId('season-xlsx')).toBeVisible();
  await expect(page.getByTestId('season-xlsx-internal')).toHaveCount(0);
  await signOut(page);
});
