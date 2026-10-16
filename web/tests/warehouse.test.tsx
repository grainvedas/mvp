// Migration 55 (release 8 of the operator-stages plan; Veda, 16 Oct 2026, "yes proceed"): C3, the Warehouse. Where it
// sits in a chain the wizard builds, its form (sent and received, the reason, the place), the record page's panel
// (days, bags, inspections; who may record them), "Needs my action" (an inspection due or overdue; stored but not
// recorded), the public page's days in storage, the plain words of the new refusals in English and Hindi, and a
// domestic order without the export fields.
import { afterEach, describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { cleanup, render, fireEvent } from '@testing-library/react';
import { assembleChain, splitChain } from '../src/lib/crops';
import { withScopeRules, withValueRules, groupSections, missingRequired, PREFILL_FROM_SOURCE, SUPPORTED } from '../src/engine/widgets';
import { orderedComputed, showComputed } from '../src/engine/values';
import { STAGE_ICON, SECTION_ICON } from '../src/engine/icons';
import { plainWords } from '../src/lib/plainErrors';
import { actionLines } from '../src/pages/NeedsMyAction';
import { WarehousePanel, inspectionLine, INSPECTION_CONDITIONS } from '../src/pages/records/Warehouse';
import { I18nProvider } from '../src/lib/i18n';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';
import type { FieldDef, Footprint, MyActions, StageType, WarehouseInfo } from '../src/lib/types';

const defs = JSON.parse(readFileSync(join(__dirname, 'fixtures/stage_definitions.json'), 'utf8')) as
  { stage_type: string; is_processing: boolean; sort_order: number; form_schema: FieldDef[]; handoff_checks: string[]; physical_checks: string[] }[];
const form = (s: string) => defs.find((d) => d.stage_type === s)!;
const migration = readFileSync(join(__dirname, '../../supabase/migrations/20261030000100_warehouse.sql'), 'utf8');
const t = (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = en[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replace(`{${n}}`, String(x));
  return s;
};
const keys = (fs: FieldDef[]) => fs.map((f) => f.key);
afterEach(cleanup);
const isProc = (s: StageType) => !!defs.find((d) => d.stage_type === s)?.is_processing;

describe('C3 · the Warehouse in a chain', () => {
  it('is the 17th stage, between the Collection Batch and Milling, not a processing stage', () => {
    expect(defs).toHaveLength(17);
    const w = form('warehouse');
    expect(w.is_processing).toBe(false);
    expect(w.sort_order).toBeGreaterThan(form('village_batch').sort_order);
    expect(w.sort_order).toBeLessThan(form('milling').sort_order);
    expect(STAGE_ICON.warehouse).toBeTruthy();
  });
  it('the wizard puts it right after the entry, or after the Collection Batch', () => {
    const base = { entry: 'procurement' as StageType, villageBatch: false, before: [] as StageType[], after: [] as StageType[], commercial: false, shipment: false };
    expect(assembleChain({ ...base, warehouse: true })).toEqual(['procurement', 'warehouse', 'qc', 'qr_activation']);
    expect(assembleChain({ ...base, villageBatch: true, warehouse: true, before: ['milling'] })).toEqual(['procurement', 'village_batch', 'warehouse', 'milling', 'qc', 'qr_activation']);
    expect(assembleChain({ ...base, entry: 'lot_inward', villageBatch: true, warehouse: true })).toEqual(['lot_inward', 'warehouse', 'qc', 'qr_activation']);
    expect(assembleChain(base)).toEqual(['procurement', 'qc', 'qr_activation']);
  });
  it('a saved chain reads back with its Warehouse (and the Warehouse is never a "processing" choice)', () => {
    const p = splitChain(['procurement', 'village_batch', 'warehouse', 'milling', 'qc', 'qr_activation'], isProc);
    expect(p).toMatchObject({ entry: 'procurement', villageBatch: true, warehouse: true, before: ['milling'] });
    expect(assembleChain(p)).toEqual(['procurement', 'village_batch', 'warehouse', 'milling', 'qc', 'qr_activation']);
    expect(splitChain(['procurement', 'qc', 'qr_activation'], isProc).warehouse).toBe(false);
  });
  it('the database refuses it anywhere else, and the wizard says so in plain words', () => {
    expect(migration).toContain("'the warehouse comes right after the entry stage (or the Collection Batch)'");
    expect(plainWords('the warehouse comes right after the entry stage (or the Collection Batch)', t)).toBe(en['err.chain_warehouse']);
  });
});

describe('C3 · the Warehouse form', () => {
  const w = form('warehouse').form_schema;
  it('arrival: sent (from the lot), received, the reason, the condition, the bags; then where it is kept', () => {
    expect(keys(w)).toEqual(['declared_kg', 'received_kg', 'discrepancy_reason', 'condition', 'bags_in', 'location', 'stack', 'photo']);
    expect(groupSections(w).map((g) => g.section)).toEqual(['arrival', 'stored']);
    expect(w.find((f) => f.key === 'condition')?.options).toEqual(['good', 'damp', 'pest', 'mixed']);
    expect(missingRequired(withScopeRules(w, {}), {})).toEqual(expect.arrayContaining(['Sent (what the lot holds)', 'Received (weighed here)', 'Warehouse or location']));
    expect(w.every((f) => SUPPORTED.has(f.type))).toBe(true);
    for (const s of ['arrival', 'stored']) { expect(SECTION_ICON[s]).toBeTruthy(); expect(en[`section.${s}`]).toBeTruthy(); }
  });
  it('what was sent opens with what the lot holds', () => {
    expect(PREFILL_FROM_SOURCE).toContain('declared_kg');
  });
  it('the hand-off and the check-in name what the Warehouse counts', () => {
    expect(form('warehouse').handoff_checks).toEqual(['Received weight recorded; any difference explained', 'Location and stack recorded', 'Bags counted in']);
    for (const c of [...form('warehouse').handoff_checks, ...form('warehouse').physical_checks]) expect(hi[`check.${c}`], c).toBeTruthy();
  });
  it('the record lists the difference, the condition, the bags and the place, in that order', () => {
    const c = { stack: 'S-3', location: 'Bansi godown 2', bags_in: 4, condition: 'good', discrepancy_pct: 3.06, discrepancy_kg: 6 };
    expect(orderedComputed(c).map(([k]) => k)).toEqual(['discrepancy_kg', 'discrepancy_pct', 'condition', 'bags_in', 'location', 'stack']);
    expect(showComputed('discrepancy_kg', 6, t)).toBe('6 kg');
    expect(showComputed('discrepancy_pct', 3.06, t)).toBe('3.06 %');
    expect(showComputed('condition', 'damp', t)).toBe('Damp');
    for (const k of Object.keys(c)) { expect(en[`computed.${k}`], k).toBeTruthy(); expect(hi[`computed.${k}`], k).toBeTruthy(); }
  });
});

describe('a domestic order without the export fields (Veda, 16 Oct)', () => {
  const c = withScopeRules(form('commercial').form_schema, { stage_details_required: true, record_price: true });
  it('the export market, the destination country and the Incoterms only for an export order', () => {
    const exportOnly = ['market_code', 'destination_country', 'incoterms'];
    expect(keys(withValueRules(c, { market: 'domestic' }))).not.toEqual(expect.arrayContaining([exportOnly[0]]));
    for (const k of exportOnly) {
      expect(keys(withValueRules(c, { market: 'domestic' }))).not.toContain(k);
      expect(keys(withValueRules(c, { market: '' }))).not.toContain(k);
      expect(keys(withValueRules(c, { market: 'export' }))).toContain(k);
    }
    expect(keys(withValueRules(c, { market: 'domestic' }))).toEqual(expect.arrayContaining(['buyer_id', 'market', 'order_no', 'price_per_kg', 'currency']));
  });
});

const fp = (over: Partial<Footprint> = {}) => ({
  id: 'w1', scope_id: 's1', stage_type: 'warehouse', status: 'verified', happened_on: '2026-10-01', created_at: '2026-10-01T05:00:00Z',
  computed: { bags_in: 4 }, payload: {}, ...over,
}) as unknown as Footprint;
const info = (over: Partial<WarehouseInfo> = {}): WarehouseInfo => ({
  days: 15, bags_in: 4, bags_out: 1, moves: [{ on: '2026-10-10', bags: 1, note: 'to the mill', by: 'Mill Operator' }],
  inspections: [{ on: '2026-10-05', condition: 'minor', note: 'a few damp bags', by: 'Grading Operator' }],
  inspection: { interval_days: 10, last_on: '2026-10-05', next_due: '2026-10-15', state: 'overdue', last_condition: 'minor' }, ...over,
});
const panel = (w: WarehouseInfo, mayInspect: boolean, mayMove: boolean, f = fp()) =>
  render(<I18nProvider><WarehousePanel f={f} w={w} mayInspect={mayInspect} mayMove={mayMove} onDone={() => undefined} /></I18nProvider>);

describe('C3 · the record page of a stored lot', () => {
  it('days in storage, bags in, out and left, the next inspection and its state', () => {
    const r = panel(info(), true, true);
    expect(r.getByTestId('wp-days').textContent).toBe('15 days');
    expect(r.getByTestId('wp-bags').textContent).toBe('4 in · 1 out · 3 left');
    expect(r.getByTestId('warehouse-panel').dataset.state).toBe('overdue');
    expect(r.getByTestId('wp-badge').textContent).toBe('Overdue');
    expect(r.getByTestId('wp-next').textContent).toContain('was due on');
    expect(r.getByTestId('wp-inspections').textContent).toContain('Minor deterioration');
    expect(r.getByTestId('wp-moves').textContent).toContain('1 bags out');
  });
  it('who keeps it inspects and records bags out; the stage that takes it only bags out; others neither', () => {
    let r = panel(info(), true, true);
    expect(r.queryByTestId('wp-inspect')).not.toBeNull(); expect(r.queryByTestId('wp-out')).not.toBeNull(); r.unmount();
    r = panel(info(), false, true);
    expect(r.queryByTestId('wp-inspect')).toBeNull(); expect(r.queryByTestId('wp-out')).not.toBeNull(); r.unmount();
    r = panel(info(), false, false);
    expect(r.queryByTestId('wp-inspect')).toBeNull(); expect(r.queryByTestId('wp-out')).toBeNull();
  });
  it('an inspection that found anything is saved only with what was found; bags out only up to what is left', () => {
    const r = panel(info(), true, true);
    fireEvent.click(r.getByTestId('wp-inspect'));
    const save = r.getByTestId('wp-inspect-save') as HTMLButtonElement;
    expect(save.disabled).toBe(true);
    fireEvent.change(r.getByTestId('wp-cond'), { target: { value: 'pest' } });
    expect(save.disabled).toBe(true);
    fireEvent.change(r.getByTestId('wp-note'), { target: { value: 'weevils in two bags' } });
    expect(save.disabled).toBe(false);
    fireEvent.change(r.getByTestId('wp-cond'), { target: { value: 'good' } });
    fireEvent.change(r.getByTestId('wp-note'), { target: { value: '' } });
    expect(save.disabled).toBe(false);
    fireEvent.click(r.getByTestId('wp-out'));
    const out = r.getByTestId('wp-out-save') as HTMLButtonElement;
    fireEvent.change(r.getByTestId('wp-bags-n'), { target: { value: '4' } });
    expect(out.disabled).toBe(true);
    fireEvent.change(r.getByTestId('wp-bags-n'), { target: { value: '3' } });
    expect(out.disabled).toBe(false);
  });
  it('nothing left in storage: no more inspections, no bags out', () => {
    const w = info({ bags_out: 4, inspection: { interval_days: 10, last_on: '2026-10-05', next_due: '2026-10-15', state: 'done', last_condition: 'minor' } });
    const r = panel(w, true, true);
    expect(r.queryByTestId('wp-inspect')).toBeNull(); expect(r.queryByTestId('wp-out')).toBeNull();
    expect(inspectionLine(w, t)).toBe('nothing is left in storage');
  });
  it('every condition has its words', () => {
    for (const c of INSPECTION_CONDITIONS) { expect(en[`insp.${c}`]).toBeTruthy(); expect(hi[`insp.${c}`]).toBeTruthy(); }
    expect(inspectionLine(info({ inspection: { interval_days: 10, last_on: null, next_due: '2026-10-20', state: 'due', last_condition: null } }), t)).toBe('by 20 Oct 2026 (every 10 days)');
  });
});

describe('C3 · Needs my action', () => {
  const a: MyActions = { returned: [], to_verify: [], proposals: 0, farmers_to_verify: 0, requirement_lines: 0, flags: 0, conditions: 0,
    inspections: [{ id: 'w1', code: 'WH-0001', scope: 'Kalanamak · KH26 · Bansi', state: 'overdue', next_due: '2026-10-15' },
      { id: 'w2', code: 'WH-0002', scope: 'Kalanamak · KH26 · Bansi', state: 'due', next_due: '2026-10-17' }],
    stored_unrecorded: [{ id: 'q1', code: 'QC-0007', scope: 'Kalanamak · KH26 · Basti', days: 16 }] };
  it('an inspection due or overdue, and a lot stored but not recorded, each open its record', () => {
    const l = actionLines(a, t);
    expect(l.map((x) => x.to)).toEqual(['/records/w1', '/records/w2', '/records/q1']);
    expect(l[0].text).toBe('WH-0001: inspection overdue (due 15 Oct 2026)');
    expect(l[1].text).toBe('WH-0002: inspection due by 17 Oct 2026');
    expect(l[2].text).toContain('QC-0007: waiting 16 days for Milling');
  });
  it('an older server sends neither: nothing is listed', () => {
    expect(actionLines({ ...a, inspections: undefined, stored_unrecorded: undefined }, t)).toEqual([]);
  });
});

describe('C3 · the public page', () => {
  it('names the Warehouse step and its days in storage, in English and Hindi', () => {
    for (const d of [enPublic, hiPublic]) { expect(d['pv.stage_warehouse']).toBeTruthy(); expect(d['pv.days_in_storage']).toContain('{n}'); }
    const j = migration.slice(migration.indexOf('FUNCTION app.public_lot_journey'));
    expect(j).toContain("'days_in_storage', app.storage_days(cur.id)");
    expect(j.slice(0, j.indexOf('$function$;'))).not.toContain('computed');
  });
});

describe('C3 · plain words for the new refusals', () => {
  const cases: [string, string, Record<string, string>?][] = [
    ['warehouse: what was sent is more than 0 kg', 'err.wh_sent'],
    ['warehouse: what was received is more than 0 kg', 'err.wh_received'],
    ['warehouse: the received weight (197 kg) is more than was sent (196 kg)', 'err.wh_over', { got: '197', sent: '196' }],
    ['warehouse: say why 6 kg less was received than sent (at least 5 characters)', 'err.wh_reason', { kg: '6' }],
    ['warehouse: the condition on arrival is good, damp, pest or mixed', 'err.wh_condition'],
    ['warehouse: the bags in are a whole number, 1 or more', 'err.wh_bags'],
    ['warehouse: name the warehouse or location', 'err.wh_location'],
    ['new row for relation "scopes" violates check constraint "scopes_warehouse_inspection_days"', 'err.wh_interval'],
    ['an inspection is of a lot in the warehouse', 'err.wi_stage'],
    ['a stored lot is inspected by the Warehouse or a manager of the scope', 'err.wi_who'],
    ['this lot is superseded', 'err.wh_lot_status', { status: 'superseded' }],
    ["inspection: the date is between the lot's arrival (26 Sep 2026) and today", 'err.wi_date', { date: '26 Sep 2026' }],
    ['inspection: the condition is good, minor deterioration, significant deterioration, or pest found', 'err.wi_condition'],
    ['inspection: say what was found (at least 5 characters)', 'err.wi_note'],
    ['bags out are of a lot in the warehouse', 'err.wb_stage'],
    ['bags out are recorded by the Warehouse, the stage that takes the lot, or a manager of the scope', 'err.wb_who'],
    ["bags out: the date is between the lot's arrival (26 Sep 2026) and today", 'err.wb_date', { date: '26 Sep 2026' }],
    ['bags out: the number of bags is a whole number, 1 or more', 'err.wb_bags'],
    ['bags out: only 1 bags of 4 are still in the warehouse', 'err.wb_left', { n: '1', m: '4' }],
  ];
  it.each(cases)('%s', (raw, key, vars) => {
    expect(plainWords(raw, t)).toBe(t(key, vars));
    expect(hi[key]).toBeTruthy();
  });
  it('every refusal of the migration has its rule', () => {
    const raised = [...migration.matchAll(/raise exception '((?:[^']|'')*)'/g)].map((m) => m[1].replace(/''/g, "'"))
      .filter((r) => /^(warehouse:|inspection:|bags out|an inspection|a stored lot|the warehouse comes)/.test(r));
    expect(raised.length).toBeGreaterThan(12);
    for (const r of raised) expect(plainWords(r.replace(/%/g, '1'), t), r).not.toBeNull();
  });
});
