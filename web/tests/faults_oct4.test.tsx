// Faults found on 4 October 2026 while the built system was compared with the prototype (docs/FIX_LIST.md items 6 to 16).
// `before` is the expression the screens used until then; each case shows what it printed and what is printed now.
import { describe, expect, it, vi } from 'vitest';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { translate } from '../src/lib/i18n';
import { num } from '../src/lib/format';
import { capturedAt, computedLabel, leftAfter, orderedComputed, showComputed, showEntered } from '../src/engine/values';
import { limitInput, limitTyping } from '../src/pages/admin/Admin';
import { farmerNote } from '../src/pages/farmers/Farmers';
import { stepDate } from '../src/pages/public/journey';
import { SEASON_HEADER, seasonRow, type SeasonRow } from '../src/pages/dashboard/ScopeDashboard';
import { TRACE_HEADER, traceRows, type Trace } from '../src/pages/trace/LotTrace';
import type { FieldDef, StageDefinition } from '../src/lib/types';
import defs from './fixtures/stage_definitions.json';

vi.mock('../src/lib/supabase', () => {
  const insert = vi.fn();
  const chain = { insert: (row: unknown) => ({ select: () => ({ abortSignal: () => ({ single: () => insert(row) }) }) }),
    select: () => ({ eq: () => ({ abortSignal: () => ({ single: () => Promise.resolve({ data: null, error: null }) }) }) }) };
  return { supabase: { from: () => chain, auth: {}, storage: {} }, appDb: { rpc: vi.fn() }, SUPABASE_URL: '', SUPABASE_ANON_KEY: '', configured: true,
    accessToken: vi.fn(), __insert: insert };
});
vi.mock('../src/offline/idb', () => ({ available: () => false, idbGet: vi.fn(), idbPut: vi.fn(), idbDel: vi.fn(), idbAll: vi.fn(async () => []), idbClear: vi.fn() }));

const stages = defs as unknown as StageDefinition[];
const tEn = (k: string, v?: Record<string, string | number>, f?: string) => translate('en', k, v, f);
const tHi = (k: string, v?: Record<string, string | number>, f?: string) => translate('hi', k, v, f);
/** What the review step, the arrival check and the record page did with a worked-out value until 4 October. */
const before = (v: unknown) => (typeof v === 'object' ? JSON.stringify(v) : num(v as number, 3));

// every key app.reconcile can put into footprints.computed (migration 4, lines 340–450)
const COMPUTED_KEYS = ['net_kg', 'moisture_avg', 'moisture_min', 'moisture_max', 'variance_kg', 'variance_pct', 'source_count', 'clean_kg',
  'reject_kg', 'reject_reasons', 'grade_split', 'yield_pct', 'bran_kg', 'loss_kg', 'expected_out_kg', 'water_removed_kg', 'grain_loss_kg',
  'pop_rate_pct', 'weight_yield_pct', 'foreign_matter_kg', 'water_uptake_kg', 'spoilage_kg', 'packed_kg', 'wastage_kg', 'batch_code',
  'sample_qty_kg', 'forwarding_kg', 'market', 'buyer', 'transit_loss_kg', 'final_kg', 'grade'];

describe('worked-out values on the screens (items 6, 10, 11)', () => {
  it('text is shown as text: a batch code, a buyer, a market, a grade were printed as "NaN"', () => {
    for (const [k, v] of [['batch_code', 'KNM-KH26-B0142'], ['buyer', 'Amira Foods BV'], ['market', 'export'], ['grade', 'A']] as const) {
      expect(before(v), `before: ${k}`).toBe('NaN');
      expect(showComputed(k, v, tEn)).toBe(v);
    }
    expect(showComputed('market', 'export', tHi)).toBe('निर्यात');
  });
  it('lists are shown in words: reject reasons and the grade split were printed as code text', () => {
    const reasons = [{ kg: 4, reason: 'discoloured grains' }, { kg: 2, reason: 'stones and chaff' }];
    expect(before(reasons)).toBe('[{"kg":4,"reason":"discoloured grains"},{"kg":2,"reason":"stones and chaff"}]');
    expect(showComputed('reject_reasons', reasons, tEn)).toBe('discoloured grains 4 kg · stones and chaff 2 kg');
    expect(before({ A: 240, B: 80, C: 22 })).toBe('{"A":240,"B":80,"C":22}');
    expect(showComputed('grade_split', { A: 240, B: 80, C: 22 }, tEn)).toBe('A 240 kg · B 80 kg · C 22 kg');
  });
  it('numbers carry their unit', () => {
    expect(showComputed('net_kg', 515, tEn)).toBe('515 kg');
    expect(showComputed('yield_pct', 67.12, tEn)).toBe('67.12 %');
    expect(showComputed('moisture_avg', 12.5, tEn)).toBe('12.5 %');
    expect(showComputed('source_count', 2, tEn)).toBe('2');
    expect(showComputed('bran_kg', null, tEn)).toBe('—');
  });
  it('no value of any kind comes out as "NaN" or as code text', () => {
    const samples: unknown[] = ['text', 'export', 12.5, 0, true, [], [{ reason: 'x', kg: 1 }], [{ units: 3, size_kg: 0.5 }], { A: 1 }, {}];
    for (const k of COMPUTED_KEYS) for (const v of samples) {
      const out = showComputed(k, v, tEn);
      expect(out, `${k} = ${JSON.stringify(v)}`).not.toMatch(/NaN|[{}[\]"]/);
    }
  });
  it('every worked-out value has a name in English and in Hindi (English showed the internal key: "Net Kg", "Moisture Avg")', () => {
    for (const k of COMPUTED_KEYS) {
      expect(en[`computed.${k}`], `English name of ${k}`).toBeTruthy();
      expect(hi[`computed.${k}`], `Hindi name of ${k}`).toBeTruthy();
    }
    expect(computedLabel('net_kg', tEn)).toBe('Net weight');
    expect(hi['computed.grain_loss_kg']).toBeTruthy();                // was missing: Hindi screens showed "Grain Loss Kg"
  });
  it('are listed in one order, with or without a network (offline the order was Avg, Min, Max; online Avg, Max, Min)', () => {
    const online = { net_kg: 98, moisture_avg: 12, moisture_max: 12.1, moisture_min: 11.9 };
    const offline = { net_kg: 98, moisture_avg: 12, moisture_min: 11.9, moisture_max: 12.1 };
    expect(orderedComputed(online).map(([k]) => k)).toEqual(orderedComputed(offline).map(([k]) => k));
  });
  it('one English name per stage, the registry\'s own (lists said "Qc" and "Qr Activation")', () => {
    for (const s of stages) expect(en[`stage.${s.stage_type}`], s.stage_type).toBe(s.label);
    expect(tEn('stage.qc', undefined, 'Qc')).toBe('Quality Control');
  });
  it('a withdrawn record is called withdrawn (the badge said "Superseded", the card under it "Withdrawn")', () => {
    expect(tEn('badge.superseded', undefined, 'Superseded')).toBe('Withdrawn');
  });
});

describe('entered values on the record page (item 10: they were shown as code text)', () => {
  const field = (stage: string, key: string) => stages.find((s) => s.stage_type === stage)!.form_schema.find((f) => f.key === key) as FieldDef;
  it('each kind of field in words', () => {
    expect(showEntered(field('procurement', 'gross_kg'), 'gross_kg', 520, tEn)).toBe('520 kg');
    expect(showEntered(field('procurement', 'moisture_pct'), 'moisture_pct', [12.4, 12.6, 12.5], tEn)).toBe('12.4 · 12.6 · 12.5 %');
    expect(showEntered(field('packing', 'packets'), 'packets', [{ units: 300, size_kg: 1 }, { units: 80, size_kg: 0.5 }], tEn)).toBe('300 × 1 kg · 80 × 0.5 kg');
    expect(showEntered(field('sorting', 'reject_reasons'), 'reject_reasons', [{ reason: 'stones', kg: 2 }], tEn)).toBe('stones 2 kg');
    expect(showEntered(field('qc', 'readings'), 'readings', { moisture_pct: 11.8, broken_pct: 2.1 }, tEn,
      [{ param: 'moisture_pct', label: 'Moisture', unit: '%', operator: '<=', domestic_limit: 13, export_limit: 12 }]))
      .toBe('Moisture 11.8 % · Broken 2.1 %');
    expect(showEntered(field('village_batch', 'source_footprint_ids'), 'source_footprint_ids', ['a', 'b'], tEn)).toBe('2 lots');
    expect(showEntered(field('commercial', 'market'), 'market', 'export', tHi)).toBe('निर्यात');
    expect(showEntered(field('grading', 'split_into_grades'), 'split_into_grades', true, tEn)).toBe('Yes');
    expect(showEntered(field('shipment', 'dispatch_date'), 'dispatch_date', '2026-11-20', tEn)).toMatch(/20 Nov 2026/);
  });
  it('a value the form does not know is still shown, never dropped', () => {
    expect(showEntered(undefined, 'something_new', 'kept', tEn)).toBe('kept');
  });
});

describe('quality limits typed by the admin (item 7)', () => {
  it('"12.5" typed key by key stays 12.5 (the box turned "12." into 12 and the next key made it 125)', () => {
    let stored = 0, shown = '';
    for (const key of '12.5') {                                         // what the box holds after each key, and the limit kept so far
      shown += key;
      const n = limitInput(shown);
      if (n !== null) stored = n;
      expect(limitTyping(shown), shown).toBe(true);
    }
    expect(shown).toBe('12.5');
    expect(stored).toBe(12.5);
    // the same keys through the old box: Number() at every key, and the box shows the number
    let old = '';
    for (const key of '12.5') old = String(Number(old + key));
    expect(old).toBe('125');
  });
  it('what is not a number is not saved as one', () => {
    for (const bad of ['', ' ', '12.', 'abc', '1,5', '1.2.3', '-3']) expect(limitInput(bad), JSON.stringify(bad)).toBeNull();
    expect(limitTyping('12.')).toBe(true);                              // still being typed: no complaint yet
    expect(limitTyping('1,5')).toBe(false);
    expect(limitInput('0.5')).toBe(0.5); expect(limitInput('.5')).toBe(0.5); expect(limitInput('13')).toBe(13);
  });
});

describe('the time a record was captured (item 8)', () => {
  it('a save that waited on the phone is sent with the time it was captured', async () => {
    const mod = await import('../src/lib/supabase') as unknown as { __insert: ReturnType<typeof vi.fn> };
    const { insertWithCaptureTime } = await import('../src/offline/outbox');
    mod.__insert.mockReset();
    mod.__insert.mockResolvedValueOnce({ data: { id: 'r1' }, error: null });
    await insertWithCaptureTime({ row: { stage_type: 'procurement' }, id: 'save-1', captured_at: '2026-10-05T04:30:00.000Z' });
    expect(mod.__insert).toHaveBeenCalledTimes(1);
    expect(mod.__insert.mock.calls[0][0]).toMatchObject({ stage_type: 'procurement', client_ref: 'save-1', captured_at: '2026-10-05T04:30:00.000Z' });
  });
  it('a server that does not have the column yet still gets the save (an app deployed ahead of its database)', async () => {
    const mod = await import('../src/lib/supabase') as unknown as { __insert: ReturnType<typeof vi.fn> };
    const { insertWithCaptureTime } = await import('../src/offline/outbox');
    mod.__insert.mockReset();
    mod.__insert.mockResolvedValueOnce({ data: null, error: { code: 'PGRST204', message: "Could not find the 'captured_at' column of 'footprints' in the schema cache" } });
    mod.__insert.mockResolvedValueOnce({ data: { id: 'r2' }, error: null });
    const rec = await insertWithCaptureTime({ row: { stage_type: 'procurement' }, id: 'save-2', captured_at: '2026-10-05T04:30:00.000Z' });
    expect(rec).toEqual({ id: 'r2' });
    expect(mod.__insert.mock.calls[1][0]).toEqual({ stage_type: 'procurement', client_ref: 'save-2' });
  });
  it('any other refusal is passed on, not retried', async () => {
    const mod = await import('../src/lib/supabase') as unknown as { __insert: ReturnType<typeof vi.fn> };
    const { insertWithCaptureTime } = await import('../src/offline/outbox');
    mod.__insert.mockReset();
    mod.__insert.mockResolvedValueOnce({ data: null, error: { code: '23514', message: 'milling: input (148) must equal rice + bran + loss (158)' } });
    await expect(insertWithCaptureTime({ row: {}, id: 'save-3', captured_at: 'x' })).rejects.toMatchObject({ code: '23514' });
    expect(mod.__insert).toHaveBeenCalledTimes(1);
  });
  it('the record page says when it was captured and, if it waited, when it was sent', () => {
    expect(capturedAt({ created_at: '2026-10-07T04:00:00Z', captured_at: '2026-10-05T04:30:00Z' })).toEqual({ at: '2026-10-05T04:30:00Z', sentLater: true });
    expect(capturedAt({ created_at: '2026-10-05T04:30:20Z', captured_at: '2026-10-05T04:30:00Z' }).sentLater).toBe(false);
    expect(capturedAt({ created_at: '2026-10-05T04:30:00Z' })).toEqual({ at: '2026-10-05T04:30:00Z', sentLater: false });   // older server
  });
  it('the public page dates a step by the day it was recorded (it showed the day the next stage verified it)', () => {
    const step = { captured_at: '2026-10-05T04:30:00Z', created_at: '2026-10-07T04:00:00Z', verified_at: '2026-10-09T06:00:00Z' };
    expect(step.verified_at ?? step.created_at).toBe('2026-10-09T06:00:00Z');   // before
    expect(stepDate(step)).toBe('2026-10-05T04:30:00Z');
    expect(stepDate({ created_at: '2026-10-07T04:00:00Z' })).toBe('2026-10-07T04:00:00Z');
  });
  it('the journey export gives both times', () => {
    const tr: Trace = { footprint_id: '1', generated_at: 'now', steps: [{ id: '1', code: 'X-P-0001', stage: 'procurement', stage_label: 'Procurement', status: 'verified',
      prev_id: null, qty_in_kg: 100, qty_out_kg: 98, grade: null, payload: {}, computed: {}, warnings: [], farmer: null, created_at: 'sent', captured_at: 'captured',
      created_by: 'Op', verified_at: null, verified_by: null, qc: null, seal: null, flags: [], evidence: [], ledger: [] }] };
    const row = traceRows(tr)[0];
    expect(row).toHaveLength(TRACE_HEADER.length);
    expect(row[TRACE_HEADER.indexOf('recorded_at')]).toBe('captured');
    expect(row[TRACE_HEADER.indexOf('received_by_server_at')]).toBe('sent');
  });
  it('the season export gives both times; a record from a server without the column keeps the one it has', () => {
    const r: SeasonRow = { footprint_code: 'X-P-0001', stage_type: 'procurement', status: 'verified', qty_in: 100, qty_out: 98, grade: null,
      lot_closed: false, warnings: ['a', 'b'], created_at: 'sent', captured_at: 'captured', verified_at: null, farmer_id: 'f', payload: { batch_code: 'B1' } };
    const row = seasonRow(r, { farmer_code: 'X-F-0001', name: 'Ram', village: 'Bansi' });
    expect(row).toHaveLength(SEASON_HEADER.length);
    expect(row[SEASON_HEADER.indexOf('recorded_at')]).toBe('captured');
    expect(row[SEASON_HEADER.indexOf('received_by_server_at')]).toBe('sent');
    expect(row[SEASON_HEADER.indexOf('warnings')]).toBe('a | b');
    expect(row[SEASON_HEADER.indexOf('farmer')]).toBe('Ram');
    const { captured_at: _none, ...old } = r;
    expect(seasonRow(old)[SEASON_HEADER.indexOf('recorded_at')]).toBe('sent');
    // the columns that existed before keep their places: only the name of the time column changed, the new one is last
    expect(SEASON_HEADER.slice(0, 13).join(',')).toBe('code,stage,status,qty_in_kg,qty_out_kg,grade,lot_closed,farmer_id,farmer,village,batch_code,buyer,market');
    expect(SEASON_HEADER.slice(13)).toEqual(['recorded_at', 'verified_at', 'warnings', 'received_by_server_at']);
  });
});

describe('smaller ones (item 16)', () => {
  it('what will be left on the source lot, not what it holds before this record', () => {
    expect(leftAfter({ qty_in: 200, available_on_prev: 340 }, false)).toBe(140);     // the panel said "340 kg still available"
    expect(leftAfter({ qty_in: 515, available_on_prev: 515 }, false)).toBe(0);
    expect(leftAfter({ qty_in: 289, available_on_prev: 164.5 }, true)).toBeNull();   // a batch of several lots: no single figure
    expect(leftAfter({ qty_in: 10 }, false)).toBeNull();
  });
  it('a farmer waiting for verification is not called verified', () => {
    expect(farmerNote('under_review')).toBe('farmers.waiting_note');
    expect(farmerNote('active')).toBe('farmers.change_recorded');
    expect(en['farmers.waiting_note']).toMatch(/waiting for verification/);
  });
  it('a refusal reported from a phone names its stage once', async () => {
    const { refusalText } = await import('../src/offline/outbox');
    expect(refusalText('Milling', 'Milling: input (148) must equal rice + bran + loss (158)')).toBe('Milling: input (148) must equal rice + bran + loss (158)');
    expect(refusalText('Procurement (farm-gate)', 'procurement: farmer is not active')).toBe('procurement: farmer is not active');
    expect(refusalText('Packing', 'Not allowed for your role or stage.')).toBe('Packing: Not allowed for your role or stage.');
  });
  it('the role in the top bar has a Hindi word', () => {
    for (const r of ['admin', 'state_manager', 'client_manager', 'client_view', 'operator']) {
      expect(en[`role.${r}`]).toBeTruthy(); expect(hi[`role.${r}`]).toBeTruthy();
    }
  });
});
