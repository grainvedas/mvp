// Migration 61 (Phase 1, release 3 of Veda's combined brief of 19 Oct 2026: release 2's corrections and the shown parts
// of E2.2 to E2.5). The rules are the database's (tests/56_export_corrections.sql); these hold the browser's side: the new
// columns' words, the closure line, the brief's footer, the Summary's mass balance with a difference in red, the
// dashboard's balance, the trace's parts and printed heading, the public page's purchases line and village counts, the
// best-before date on the pack page, the plain words of the shelf-life refusal.
import { afterEach, describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { balanceParts, cellValue, columnLabel, footerLines, seasonSheets, type ExportTable, type SeasonExport, type StageBalance } from '../src/lib/exports';
import { MassBalance } from '../src/pages/dashboard/ScopeDashboard';
import { partsLine, printScope } from '../src/pages/trace/LotTrace';
import { JourneyView, PackNotReleased, farmersFrom } from '../src/pages/public/PublicVerify';
import type { Journey, JourneyStep } from '../src/pages/public/journey';
import { plainWords } from '../src/lib/plainErrors';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';

const root = join(__dirname, '../..');
const migration = readFileSync(join(root, 'supabase/migrations/20261105000100_export_corrections.sql'), 'utf8');
const tr = (d: Record<string, string>) => (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = d[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replaceAll(`{${n}}`, String(x));
  return s;
};
const T = tr({ ...enPublic, ...en });
const H = tr({ ...hiPublic, ...hi });
afterEach(() => cleanup());

const head = { client: 'Test Client UP', client_code: 'TCUP', crop: 'Kalanamak Rice', gi_tag: 'GI 280', season: 'KH26', geography: 'Bansi', state: 'Uttar Pradesh',
  status: 'active', data_note: null };
const bal = (o: Partial<StageBalance>): StageBalance => ({ stage: 'milling', pos: 3, records: 1, pending: 0, verified: 1, kg_in: 243, kg_out: 150, by_products_kg: 90,
  other_kg: 0, floor_loss_kg: 3, transit_loss_kg: 0, closed_kg: 0, handed_on_kg: 150, left_kg: 0, difference_kg: 0, balanced: true, last: false, ...o });

describe('C1/E2 · the new columns and values, in the reader\'s language', () => {
  it('by-products and floor loss with their units; names for the lists', () => {
    expect(columnLabel('husk_pct', {}, T)).toBe('Husk (% of input)');
    expect(columnLabel('floor_loss_kg', {}, T)).toBe('Floor loss (kg)');
    expect(columnLabel('fssai_licence', {}, H)).toBe('FSSAI लाइसेंस');
    expect(columnLabel('raw_values', {}, T)).toContain('raw_values');
  });
  it('the closure line, an old pack\'s best-before, a choice\'s words', () => {
    expect(cellValue('stage', 'floor_loss_closure', T)).toBe('Closed as floor loss');
    expect(cellValue('best_before', 'not_recorded', T)).toBe('not recorded (old data)');
    expect(cellValue('best_before', 'not_recorded', H)).toBe('दर्ज नहीं (पुराना डेटा)');
    expect(cellValue('best_before', '2027-10-16', T)).toBe('2027-10-16');
    expect(cellValue('collection_point', 'farm', T)).toBe(en['opt.farm']);
    expect(cellValue('collection_point', 'Bansi centre', T)).toBe('Bansi centre');
    expect(cellValue('line_clearance', 'fully_cleaned', T)).toBe(en['opt.fully_cleaned']);
    expect(cellValue('market', 'domestic', H)).toBe('घरेलू');
  });
  it('the shareable copy\'s footer says what it leaves out (the brief\'s words)', () => {
    const e: ExportTable = { columns: [], rows: [], copy: 'shareable', generated_at: '2026-10-20 10:00', units: {}, scope: head };
    expect(footerLines(e, T, 'https://x.test')[0]).toBe('Shareable copy made by GrainVeda on 2026-10-20 10:00 IST. No prices, no farmers\' names or phones, no internal IDs.');
    expect(footerLines({ ...e, copy: 'internal' }, H, 'https://x.test')[0]).toBe('आंतरिक: इसमें व्यक्तिगत और व्यावसायिक जानकारी है। आगे न भेजें।');
  });
});

describe('C2/E2.5 · the season\'s Summary is the mass balance', () => {
  const season: SeasonExport = { columns: ['code'], rows: [['X']], copy: 'shareable', generated_at: '2026-10-20 10:00', generated_by: 'Lucky', units: {}, scope: head,
    kind: 'season', summary: [bal({ stage: 'village_batch', pos: 2, kg_in: 250, kg_out: 247, by_products_kg: 0, floor_loss_kg: 3, closed_kg: 4, handed_on_kg: 238,
                                    difference_kg: 5, balanced: false }), bal({})],
    totals: { farmers: 2, kg_in: 250, gi_kg: 250, gi_pct: 100, farm_verified_kg: 250, by_products: { head_rice_kg: 150, broken_kg: 20, husk_kg: 50, bran_kg: 20, reject_kg: 0, foreign_matter_kg: 0 },
              by_products_kg: 90, floor_loss_kg: 6, transit_loss_kg: 0, closed_kg: 4, differences: 1, sealed_lots: 1, packs: 150, open_flags: 0, records: 5 },
    batches: [{ batch_code: 'B1', packs: 150, void: 0, first: 'B1-0001', last: 'B1-0150', by_size: '150 × 1 kg pouch', best_before: 'not_recorded' }] };
  const text = (s: unknown[][]) => s.map((r) => (r ?? []).map((c) => (c as { value?: unknown } | null)?.value ?? '').join('|')).join('\n');
  it('each stage: in, out, by-products, floor loss, closed, went on, left, difference; a difference in red', () => {
    const { sheets } = seasonSheets(season, T);
    expect(text(sheets[1])).toContain('|250|247|0|0|3|0|4|238|0|5');
    const row = sheets[1][1] as ({ value: unknown; color?: string } | null)[];
    expect(row.at(-1)).toMatchObject({ value: 5, color: '#B42318' });
    expect((sheets[1][2] as ({ color?: string } | null)[]).at(-1)?.color).toBeUndefined();
    expect(text(sheets[1])).toContain(en['exp.s.balance_note']);
  });
  it('the by-products apart from the losses; batches by size; who made it', () => {
    const { sheets } = seasonSheets(season, T);
    expect(text(sheets[1])).toContain('By-products of the season (kg)\nHead rice (kg)|150\nBroken rice (kg)|20\nHusk (kg)|50\nBran (kg)|20\nFloor loss, all stages (kg)|6');
    expect(text(sheets[1])).toContain('Closed as floor loss, all stages (kg)|4');
    expect(text(sheets[1])).toContain('B1|150|0|B1-0001|B1-0150|150 × 1 kg pouch|not recorded (old data)');
    expect(text(sheets[0])).toContain('Made by|Lucky');
  });
});

describe('E2.5 · the dashboard\'s mass balance', () => {
  it('a stage that closes says so; one that does not shows its difference', () => {
    render(<MassBalance rows={[bal({}), bal({ stage: 'village_batch', pos: 2, balanced: false, difference_kg: 5 })]} stageLabel={(s) => T(`stage.${s}`)} />);
    const rows = screen.getAllByTestId('balance-row');
    expect(rows.map((r) => r.getAttribute('data-balanced'))).toEqual(['yes', 'no']);
    expect(screen.getByTestId('balance-diff').textContent).toBe('Difference 5 kg');
    expect(screen.getAllByTestId('balance-figures')[0].textContent).toBe('In 243 kg · went on 150 kg · by-products 90 kg · floor loss 3 kg · left 0 kg');
    expect(balanceParts(bal({ other_kg: 1, transit_loss_kg: 2 }))).toEqual({ byp: 91, loss: 5 });
  });
});

describe('C4/E2.2 · the trace page', () => {
  it('the printed heading names client, crop, season and place; a step\'s by-products and floor loss', () => {
    expect(printScope(head, T)).toBe('Test Client UP · Kalanamak Rice · KH26 · Bansi, Uttar Pradesh');
    expect(partsLine({ in: 243, out: 150, by_products: 90, other: 0, floor_loss: 3, transit_in: 0, transit_up: 0 }, 'milling', T)).toBe('By-products 90 kg · Floor loss 3 kg');
    expect(partsLine({ in: 100, out: 100, by_products: 0, other: 0, floor_loss: 0, transit_in: 0, transit_up: 0 }, 'procurement', T)).toBe('');
  });
});

describe('E2.3/E2.4 · the public pages', () => {
  const step = (o: Partial<JourneyStep>): JourneyStep => ({ stage: 'qc', code: 'Q', qty_in_kg: 0, qty_out_kg: 0, verified_at: null, created_at: '2026-11-12T05:00:00Z', ...o });
  const j: Journey = { qr_code: 'GV-ABCDEF123456', sealed_at: '2026-12-02T05:00:00Z', ledger_hash: 'a'.repeat(64), batch_codes: [], season: 'KH26', geography: 'Bansi',
    crop: { name: 'Kalanamak rice', gi_tag: '280', origin: 'Siddharthnagar' }, client: { name: 'Test Client UP', type: 'trade' }, gi_status: 'gi', farmer_count: 2,
    verdict: { domestic: 'pass', export: 'pass', overridden: false }, independent: false,
    journey: [step({ stage: 'purchases', code: 'VB-1:purchases', qty_out_kg: 250, farmers_n: 2,
                     villages: [{ village: 'Itwa', district: 'Siddharthnagar', farmers: 1, qty_kg: 150, share_pct: 60 }, { village: 'Bansi', district: 'Siddharthnagar', farmers: 1, qty_kg: 100, share_pct: 40 }] }),
              step({ stage: 'village_batch', code: 'VB-1', qty_out_kg: 247, villages_n: 2,
                     farmers: [{ village: 'Itwa', district: 'Siddharthnagar', qty_kg: 150 }, { village: 'Bansi', district: 'Siddharthnagar', qty_kg: 100 }] })] };
  it('"Collection Batch", "2 farmers from 2 villages", and one line for both purchases with the villages\' shares', () => {
    render(<MemoryRouter><JourneyView j={j} /></MemoryRouter>);
    expect(screen.getByText('Collection Batch')).toBeTruthy();
    expect(screen.getByTestId('pv-batch-farmers').textContent).toBe('2 farmers from 2 villages');
    expect(screen.getByTestId('pv-bought-from').textContent).toBe('Bought from 2 farmers: 250 kg');
    expect(screen.getByTestId('pv-bought-villages').textContent).toBe('Itwa 60 % · Bansi 40 %');
    expect(farmersFrom({ farmers: [{ village: 'A', district: 'D', qty_kg: 1 }, { village: 'A', district: 'D', qty_kg: 2 }] }, H)).toBe('1 गाँव के 2 किसान');
    expect(hiPublic['pv.stage_village_batch']).toBe('संग्रह बैच');
  });
  it('the pack page before release: its best-before date, or "not recorded (old data)"; none on a voided pack', () => {
    const p = { released: false as const, crop: { name: 'Kalanamak rice' }, pack: { serial: 'B1-0150', batch_code: 'B1', packed_on: '2026-10-16', best_before: '2027-10-16' } };
    render(<MemoryRouter><PackNotReleased p={p} /></MemoryRouter>);
    expect(screen.getByTestId('pv-best-before').textContent).toBe('16 Oct 2027');
    cleanup();
    render(<MemoryRouter><PackNotReleased p={{ ...p, pack: { ...p.pack, best_before: null } }} /></MemoryRouter>);
    expect(screen.getByTestId('pv-best-before').textContent).toBe('not recorded (old data)');
    cleanup();
    render(<MemoryRouter><PackNotReleased p={{ ...p, pack: { ...p.pack, void: true } }} /></MemoryRouter>);
    expect(screen.queryByTestId('pv-best-before')).toBeNull();
  });
});

describe('E2.4 · the shelf-life refusal in plain words; the rules are the server\'s', () => {
  it('names the material, or the crop', () => {
    expect(plainWords('packing: ask the State Manager to set the shelf life for this crop and pack material (jute)', T)).toBe(
      'Ask the State Manager to set the shelf life for this crop and pack material (jute).');
    expect(plainWords('packing: ask the State Manager to set the shelf life for this crop', H)).toBe(hi['err.pk_shelf_life_crop']);
  });
  it('the migration holds the rules; every new word has its Hindi', () => {
    expect(migration).toContain("raise exception 'packing: ask the State Manager to set the shelf life for this crop and pack material (%)', v_mat");
    expect(migration).toContain('create or replace function app.stage_balance(p_scope uuid) returns jsonb');
    for (const k of ['exp.closure_line', 'exp.bb_old', 'dash.balance', 'trace.closure', 'pk.best_before_old', 'err.pk_shelf_life']) expect(hi[k], k).toBeTruthy();
    for (const k of Object.keys(enPublic)) expect(hiPublic[k], k).toBeTruthy();
  });
});
