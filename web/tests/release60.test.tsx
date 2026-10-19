// Migration 60 (Phase 1, release 2 of Veda's combined brief, 19 Oct 2026, Part C: the exports). The rules are the
// database's (tests/55_exports.sql: what each copy holds, who takes which, the Audit line); these hold the browser's side:
// the columns in the reader's language with units, the values' words, the footers, the season's three sheets, the lab
// on the public page.
import { afterEach, describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { cellValue, columnLabel, footerLines, seasonSheets, tableOf, type ExportTable, type SeasonExport } from '../src/lib/exports';
import { JourneyView, labsOf } from '../src/pages/public/PublicVerify';
import type { Journey, JourneyStep } from '../src/pages/public/journey';
import { plainWords } from '../src/lib/plainErrors';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';

const root = join(__dirname, '../..');
const migration = readFileSync(join(root, 'supabase/migrations/20261104000100_exports.sql'), 'utf8');
const tr = (d: Record<string, string>) => (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = d[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replaceAll(`{${n}}`, String(x));
  return s;
};
const T = tr({ ...enPublic, ...en });
const H = tr({ ...hiPublic, ...hi });
afterEach(() => cleanup());

const head = { client: 'Test Client UP', client_code: 'TCUP', crop: 'Kalanamak Rice', gi_tag: 'GI 280', season: 'KH26', geography: 'Bansi', state: 'Uttar Pradesh',
  status: 'active', data_note: 'practice_old_data' };
const table = (o: Partial<ExportTable> = {}): ExportTable => ({ columns: ['step', 'code', 'stage', 'same_person', 'gi_status', 'r:aflatoxin', 'data_note', 'entered_values'],
  rows: [[1, 'X-P-0001', 'procurement', 'yes', 'gi', null, 'practice_old_data', { gross_kg: 104 }]], copy: 'internal', generated_at: '2026-10-19 18:30',
  units: { aflatoxin: 'µg/kg' }, scope: head, ...o });

describe('C2 · readable columns, in the reader\'s language', () => {
  it('a column\'s name, a reading with its unit from the server', () => {
    expect(columnLabel('loss_kg', {}, T)).toBe('Loss on the floor (kg)');
    expect(columnLabel('share_pct', {}, H)).toBe('हिस्सा (%)');
    expect(columnLabel('r:aflatoxin', { aflatoxin: 'µg/kg' }, T)).toMatch(/Aflatoxin \(µg\/kg\)$/);
    expect(columnLabel('r:moisture_pct', {}, T)).toMatch(/\(%\)$/);
  });
  it('the values as words: a stage, yes, GI status, the old-data note; the raw values as text', () => {
    const { header, rows } = tableOf(table(), T);
    expect(header[0]).toBe('Step');
    expect(rows[0]).toEqual([1, 'X-P-0001', en['stage.procurement'] ?? 'Procurement', 'Yes', en['gi.gi'], null, 'Practice (old data)', '{"gross_kg":104}']);
    expect(cellValue('status', 'superseded', T)).toBe('Replaced by a correction');
    expect(cellValue('farm_verified', 'no', H)).toBe(hi['common.no']);
  });
});

describe('C4 · each copy says what it is', () => {
  it('the internal copy: for the client and the scope\'s people only, not to be forwarded, in the Audit log', () => {
    const f = footerLines(table(), T, 'https://example.test');
    // migration 61: the brief's own words first
    expect(f[0]).toBe('Internal: contains personal and commercial data. Do not forward.');
    expect(f[1]).toMatch(/^For Test Client UP .* Made on 2026-10-19 18:30 IST\.$/);
    expect(f[2]).toMatch(/Audit log/);
  });
  it('the shareable copy: no names, no prices; where to check a lot', () => {
    const f = footerLines(table({ copy: 'shareable' }), H, 'https://example.test');
    expect(f[0]).toContain('साझा करने योग्य'); expect(f[1]).toContain('https://example.test/verify/');
  });
  it('a refused internal copy in plain words', () => {
    const raw = 'the internal copy is for the people of this scope and the client\'s own login: take the shareable copy';
    expect(plainWords(raw, T)).toMatch(/Take the shareable copy/);
    expect(plainWords(raw, H)).toMatch(/आंतरिक प्रति/);
  });
});

describe('C1/C3 · the season: one Excel file, three sheets', () => {
  const season: SeasonExport = { ...table({ copy: 'shareable', columns: ['code', 'stage'], rows: [['X-P-0001', 'procurement']] }), kind: 'season',
    // migration 61: the summary is the stage's mass balance
    summary: [{ stage: 'procurement', pos: 1, records: 2, pending: 0, verified: 2, kg_in: 300, kg_out: 300, by_products_kg: 0, other_kg: 0, floor_loss_kg: 0,
                transit_loss_kg: 0, closed_kg: 0, handed_on_kg: 199, left_kg: 101, difference_kg: 0, balanced: true, last: false },
              { stage: 'milling', pos: 2, records: 1, pending: 0, verified: 1, kg_in: 199, kg_out: 180, by_products_kg: 0, other_kg: 0, floor_loss_kg: 19,
                transit_loss_kg: 0, closed_kg: 0, handed_on_kg: 0, left_kg: 180, difference_kg: 0, balanced: true, last: false }],
    totals: { farmers: 2, kg_in: 300, gi_kg: 200, gi_pct: 66.7, farm_verified_kg: 300, by_products: { broken_kg: 0, husk_kg: 0, bran_kg: 0, reject_kg: 0, foreign_matter_kg: 0 },
              by_products_kg: 0, floor_loss_kg: 19, transit_loss_kg: 0, closed_kg: 0, differences: 0, sealed_lots: 0, packs: 150, open_flags: 0, records: 3 },
    batches: [{ batch_code: 'TCUP-KNM-KH26-B0004', packs: 150, void: 0, first: 'TCUP-KNM-KH26-B0004-0001', last: 'TCUP-KNM-KH26-B0004-0150' }] };
  it('heading, summary (stages, the season\'s totals, batches with serial ranges), records; each ends with the footer', () => {
    const { sheets, names } = seasonSheets(season, T);
    expect(names).toEqual(['Heading', 'Summary', 'Records']);
    const text = (s: unknown[][]) => s.map((r) => (r ?? []).map((c) => (c as { value?: unknown } | null)?.value ?? '').join('|')).join('\n');
    expect(text(sheets[0])).toContain('Client|Test Client UP');
    expect(text(sheets[0])).toContain('Copy|Shareable copy');
    expect(text(sheets[0])).toMatch(/Data note\|Practice \(old data\)/);
    expect(text(sheets[1])).toContain('2. ' + (en['stage.milling'] ?? 'Milling') + '|1|0|1|199|180|0|0|19|0|0|0|180|0');
    expect(text(sheets[1])).toContain('From the GI area (kg, share)|200|66.7 %');
    expect(text(sheets[1])).toContain('TCUP-KNM-KH26-B0004|150|0|TCUP-KNM-KH26-B0004-0001|TCUP-KNM-KH26-B0004-0150');   // by size, best before: none given
    for (const s of sheets) expect(text(s).trim().split('\n').at(-1)).toMatch(/verify/);
    expect(seasonSheets(season, H).names).toEqual(['शीर्षक', 'सारांश', 'रिकॉर्ड']);
  });
});

describe('A5 · the public lot page names the lab', () => {
  const step = (o: Partial<JourneyStep>): JourneyStep => ({ stage: 'qc', code: 'Q', qty_in_kg: 0, qty_out_kg: 0, verified_at: null, created_at: '2026-11-12T05:00:00Z', ...o });
  const j: Journey = { qr_code: 'GV-ABCDEF123456', sealed_at: '2026-12-02T05:00:00Z', ledger_hash: 'a'.repeat(64), batch_codes: [], season: 'KH26', geography: 'Bansi',
    crop: { name: 'Kalanamak rice', gi_tag: '280', origin: 'Siddharthnagar' }, client: { name: 'Test Client UP', type: 'trade' }, gi_status: 'gi', farmer_count: 1,
    verdict: { domestic: 'pass', export: 'pass', overridden: false }, independent: false,
    journey: [step({ code: 'Q1', lab: { name: 'Gorakhpur Grain Lab', accreditation_no: 'TC-5521' } }), step({ code: 'Q2', lab: { name: 'Gorakhpur Grain Lab', accreditation_no: 'TC-5521' } })] };
  it('"Tested by …" once per lab, with its accreditation number', () => {
    expect(labsOf(j.journey)).toHaveLength(1);
    render(<MemoryRouter><JourneyView j={j} /></MemoryRouter>);
    expect(screen.getAllByTestId('pv-lab-name').map((e) => e.textContent)).toEqual(['Tested by Gorakhpur Grain Lab (accreditation TC-5521).']);
    expect(hiPublic['pv.tested_by_acc']).toContain('{lab}');
  });
});

describe('the server makes them', () => {
  it('both exports and the Audit line are in the migration; every new string has its Hindi', () => {
    expect(migration).toContain("create or replace function app.export_journey(p_fp uuid, p_copy text default 'shareable')");
    expect(migration).toContain("perform app.audit('export_downloaded', p_scope,");
    for (const k of Object.keys(en).filter((x) => x.startsWith('exp.') || x === 'err.internal_copy')) expect(hi[k], k).toBeTruthy();
  });
});
