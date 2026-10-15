// Migration 52 (release 5 of the operator-stages plan): C1 Procurement, C2 Collection Batch, the journey forward.
// The phone's mirror of the save's rules (it must refuse what the server refuses, in the server's words, so the same
// plain words come back), the form's fields by the scope's settings, and how the new values are shown.
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { offlinePreview, paymentProblem, type BatchLot } from '../src/engine/offlinePreview';
import { buildPayload, missingRequired, withScopeRules } from '../src/engine/widgets';
import { showComputed, showEntered } from '../src/engine/values';
import { SECTION_ICON } from '../src/engine/icons';
import { plainWords } from '../src/lib/plainErrors';
import { homeState } from '../src/pages/setup/SetupLists';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import type { FieldDef } from '../src/lib/types';

const defs = JSON.parse(readFileSync(join(__dirname, 'fixtures/stage_definitions.json'), 'utf8')) as { stage_type: string; label: string; form_schema: FieldDef[] }[];
const proc = defs.find((d) => d.stage_type === 'procurement')!.form_schema;
const vb = defs.find((d) => d.stage_type === 'village_batch')!;
const t = (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = en[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replace(`{${n}}`, String(x));
  return s;
};
const lot = { gross_kg: 102, bags: 2, tare_kg_per_bag: 1, moisture_pct: [12, 12.2, 12.1] };
const where = { collection_point_id: 'cp-1', gps_lat: 27.21, gps_lng: 82.95, delivered_by: 'farmer' };
const asked = { procurement_details_required: true };

describe('C1 · the farm-gate form', () => {
  it('asks where, the GPS and who delivered where the scope says so; price and payment only where it records them', () => {
    const on = withScopeRules(proc, { procurement_details_required: true, record_price: true });
    const off = withScopeRules(proc, { procurement_details_required: false, record_price: false });
    for (const k of ['collection_point_id', 'gps', 'delivered_by']) {
      expect(on.find((f) => f.key === k)?.required, k).toBe(true);
      expect(off.find((f) => f.key === k)?.required, k).toBe(false);
    }
    expect(on.find((f) => f.key === 'price_per_quintal')?.required).toBe(true);
    expect(off.some((f) => ['price_per_quintal', 'payment_status', 'payment_mode', 'txn_ref'].includes(f.key))).toBe(false);
    expect(missingRequired(on, { gps: { lat: '27.2', lng: '' } })).toContain('GPS where the lot was weighed');
    expect(missingRequired(on, { gps: { lat: '27.2', lng: '83' } })).not.toContain('GPS where the lot was weighed');
  });
  it('the GPS goes to the record as two numbers; half a point is not sent', () => {
    expect(buildPayload(proc, { gps: { lat: '27.21', lng: '82.95' } }).payload).toMatchObject({ gps_lat: 27.21, gps_lng: 82.95 });
    expect(buildPayload(proc, { gps: { lat: '27.21', lng: '' } }).payload).not.toHaveProperty('gps_lat');
    expect(buildPayload(proc, { gps: { lat: '27.21, 82.95', lng: '' } }).payload).not.toHaveProperty('gps_lat');
  });
  it('every new section has its heading and pictogram, in English and Hindi', () => {
    for (const s of ['where', 'optional', 'payment']) { expect(SECTION_ICON[s], s).toBeTruthy(); expect(en[`section.${s}`]).toBeTruthy(); expect(hi[`section.${s}`]).toBeTruthy(); }
  });
});

describe('C1 · the offline mirror refuses what the save refuses', () => {
  const pv = (p: Record<string, unknown>, rules = {}) => offlinePreview('procurement', { ...lot, ...p }, { farmer_id: 'f' }, {}, rules);
  it('asks where, the GPS and who delivered only where the scope says so', () => {
    expect(pv({}).ok).toBe(true);
    expect(pv({}, asked).error).toMatch(/^procurement: say where the lot was weighed/);
    expect(pv({ collection_point_id: 'farm' }, asked).error).toMatch(/GPS of where the lot was weighed is required/);
    expect(pv({ collection_point_id: 'farm', gps_lat: 27.2, gps_lng: 83 }, asked).error).toMatch(/say who delivered the lot/);
    expect(pv(where, asked)).toMatchObject({ ok: true, qty_out: 100 });
  });
  it('a GPS point in India; an agent named; a known condition', () => {
    expect(pv({ ...where, gps_lat: 51.5, gps_lng: -0.1 }).error).toBe('procurement: the GPS point is two numbers in India');
    expect(pv({ ...where, delivered_by: 'agent' }).error).toBe('procurement: name the agent who delivered the lot');
    expect(pv({ ...where, delivered_by: 'agent', agent_name: 'Ramesh' }).ok).toBe(true);
    expect(pv({ ...where, delivered_by: 'cousin' }).error).toMatch(/delivered by the farmer, his family or an agent/);
    expect(pv({ ...where, condition: 'wet' }).error).toMatch(/good, damp, pest or mixed/);
  });
  it('warns (saves) above the crop\'s moisture limit and when the readings are far apart, in the server\'s words', () => {
    const w = pv({ ...where, moisture_pct: [15, 16.2, 17.1] }, { moisture_limit: 14 }).warnings;
    expect(w).toContain('moisture 16.1 % is above the crop\'s limit of 14 %');
    expect(w).toContain('the moisture readings are 2.1 points apart (more than 1.5): read them again');
    expect(pv({ ...where, moisture_pct: [12, 12.5, 13] }, { thresholds: { moisture_spread_pct: 0.5 } }).warnings)
      .toEqual(['the moisture readings are 1.0 points apart (more than 0.5): read them again']);
  });
  it('the place at the farm is named on the record', () => {
    expect(pv({ ...where, collection_point_id: 'farm' }).computed).toMatchObject({ collection_point: 'farm' });
  });
  it('price and payment: only where the scope records them; a transaction ID, never an account number', () => {
    expect(pv({ ...where, price_per_quintal: 3500 }).error).toMatch(/this scope does not record price and payment/);
    expect(offlinePreview('milling', { input_kg: 1, txn_ref: 'UPI-1234' }, {}, {}, { record_price: true }).error).toBe('price and payment are recorded at Procurement');
    const rp = { record_price: true };
    expect(pv({ ...where, price_per_quintal: 3500, payment_status: 'paid', payment_mode: 'upi' }, rp).error).toBe('payment: give the transaction ID of the payment');
    expect(pv({ ...where, price_per_quintal: 3500, payment_status: 'paid', payment_mode: 'bank', txn_ref: 'A/C 1234 5678' }, rp).error).toMatch(/never an account number/);
    expect(pv({ ...where, price_per_quintal: 3500, payment_status: 'paid', payment_mode: 'cash' }, rp).ok).toBe(true);
    expect(paymentProblem({ price_per_quintal: 0 })).toBe('the price per quintal is more than 0');
    expect(paymentProblem({ payment_status: 'paid' })).toBe('say how it was paid (bank, UPI or cash)');
    expect(paymentProblem({ price_per_quintal: 3500, payment_status: 'paid', payment_mode: 'upi', txn_ref: 'UPI-TEST-0001' })).toBeNull();
  });
});

describe('C2 · the Collection Batch, offline', () => {
  const L = (id: string, qty: number, village: string, point = 'cp-1', m: number | null = 12, gi: BatchLot['gi_status'] = 'gi'): BatchLot =>
    ({ id, code: `P-${id}`, qty, point, point_name: point === 'cp-1' ? 'Bansi centre' : point === 'farm' ? null : 'Itwa store', village, farmer_id: `f-${id}`, moisture_avg: m, gi_status: gi });
  const lots = new Map([L('1', 200, 'Bansi', 'cp-1', 12.6), L('2', 200, 'Itwa', 'cp-1', 13.5), L('3', 100, 'Bansi', 'cp-2'), L('4', 50, 'BANSI ', 'cp-1', null, 'non_gi')].map((l) => [l.id, l]));
  const pv = (p: Record<string, unknown>, rules = {}) => offlinePreview('village_batch', p, { prev_footprint_id: 'x' }, {}, { lots, ...rules });
  it('works out the total, the farmers, the villages with their share and the weighted moisture', () => {
    const p = pv({ source_footprint_ids: ['1', '2'], reweighed_kg: 390 });
    expect(p).toMatchObject({ ok: true, provisional: false, qty_in: 400, qty_out: 390,
      computed: { total_kg: 400, farmers: 2, collection_point: 'Bansi centre', moisture_avg: 13.05, loss_kg: 10,
        villages: [{ village: 'Bansi', kg: 200, share_pct: 50 }, { village: 'Itwa', kg: 200, share_pct: 50 }] } });
    expect(p.warnings).toEqual(['the batch weighs 10.0 kg (2.5 %) less than its lots']);
    expect(pv({ source_footprint_ids: ['1', '2'], reweighed_kg: 390 }, { thresholds: { batch_loss_pct: 3 } }).warnings).toEqual([]);
  });
  it('refuses lots of two places, naming them; a single-origin batch from two villages; more weight than the lots', () => {
    expect(pv({ source_footprint_ids: ['1', '3'] }).error)
      .toBe('collection batch: the lots are from different collection points (P-1 Bansi centre, P-3 Itwa store): a batch is the lots at one place');
    expect(pv({ source_footprint_ids: ['1', '2'], single_origin: true }).error).toMatch(/single-origin batch is from one village \(these lots are from Bansi, Itwa\)/);
    expect(pv({ source_footprint_ids: ['1', '2'], reweighed_kg: 401 }).error).toBe('collection batch: the re-weighed total (401 kg) is more than the lots (400 kg)');
    expect(pv({ source_footprint_ids: ['1', '2'], bags: 0 }).error).toBe('collection batch: the bags are 1 or more');
    expect(pv({ source_footprint_ids: ['1', '4'] }).error).toMatch(/^GI and non-GI lots are not batched together/);
  });
  it('the same village written differently is one village', () => {
    const many = new Map([...lots, ['5', L('5', 50, 'BANSI ', 'cp-1')]]);
    const p = offlinePreview('village_batch', { source_footprint_ids: ['1', '5'], single_origin: true }, {}, {}, { lots: many });
    expect(p.ok).toBe(true);
    expect((p.computed as { villages: unknown[] }).villages).toHaveLength(1);
  });
  it('a lot the phone does not know leaves the batch to the server', () => {
    expect(pv({ source_footprint_ids: ['1', 'unknown'] })).toMatchObject({ ok: true, provisional: true });
  });
});

describe('the plain words for every new refusal and warning', () => {
  const said = [
    'procurement: the collection point is not one of this client\'s active points', 'procurement: the GPS point is two numbers in India',
    'procurement: delivered by the farmer, his family or an agent', 'procurement: name the agent who delivered the lot',
    'procurement: the condition is good, damp, pest or mixed', 'procurement: say where the lot was weighed (a collection point, or at the farm)',
    'procurement: the GPS of where the lot was weighed is required', 'procurement: say who delivered the lot (the farmer, his family or an agent)',
    'collection batch: the lots are from different collection points (P-1 Bansi centre, P-3 Itwa store): a batch is the lots at one place',
    'collection batch: a single-origin batch is from one village (these lots are from Bansi, Itwa)', 'collection batch: the bags are 1 or more',
    'collection batch: the re-weighed total is more than 0', 'collection batch: the re-weighed total (401 kg) is more than the lots (400 kg)',
    'payment: the price per quintal is a number', 'payment: the price per quintal is more than 0', 'payment: the payment is paid or pending',
    'payment: the payment is by bank, UPI or cash', 'payment: say how it was paid (bank, UPI or cash)', 'payment: give the transaction ID of the payment',
    'payment: a transaction ID is 4 to 40 letters or digits (never an account number)', 'price and payment are recorded at Procurement',
    'this scope does not record price and payment (its Client Manager turns it on)',
    'the person who recorded the lot or the client\'s Client Manager records its payment', 'not allowed to trace this lot',
    'moisture 16.1 % is above the crop\'s limit of 14 %', 'the moisture readings are 2.1 points apart (more than 1.5): read them again',
    'the batch weighs 10.0 kg (2.5 %) less than its lots',
  ];
  it('each one has its words, in English and Hindi, with what matters carried over', () => {
    for (const m of said) {
      const w = plainWords(m, t);
      expect(w, m).toBeTruthy();
      expect(w, m).not.toMatch(/^err\.|^warn\./);
    }
    expect(plainWords(said[8], t)).toContain('P-1 Bansi centre, P-3 Itwa store');
    expect(plainWords(said[12], t)).toContain('401');
    expect(plainWords(said[25], t)).toBe('The three moisture readings are 2.1 points apart (more than 1.5): read them again.');
    for (const k of Object.keys(en).filter((x) => /^(err|warn)\.(cp_|cb_|pay_|delivered|agent|where|gps_req|condition|trace|moisture_limit|moisture_spread)/.test(x))) expect(hi[k], k).toBeTruthy();
  });
});

describe('how the new values read', () => {
  it('a Collection Batch\'s villages with their shares; a lot weighed at the farm; a GPS point', () => {
    expect(showComputed('villages', [{ village: 'Bansi', kg: 200, share_pct: 50 }, { village: 'Itwa', kg: 100, share_pct: 33.3 }], t))
      .toBe('Bansi 200 kg (50 %) · Itwa 100 kg (33.3 %)');
    expect(showComputed('collection_point', 'farm', t)).toBe('At the farm');
    expect(showEntered(proc.find((f) => f.key === 'collection_point_id'), 'collection_point_id', 'farm', t)).toBe('At the farm');
    expect(showEntered(proc.find((f) => f.key === 'gps'), 'gps', { lat: 27.21, lng: 82.95 }, t)).toBe('27.21, 82.95');
    expect(showEntered(proc.find((f) => f.key === 'delivered_by'), 'delivered_by', 'agent', t)).toBe('An agent');
  });
  it('the Collection Batch is named for one collection point, in both languages; no village is typed', () => {
    expect(vb.label).toBe('Collection Batch (one collection point)');
    expect(en['stage.village_batch']).toBe(vb.label);
    expect(hi['stage.village_batch']).toBeTruthy();
    expect(vb.form_schema.some((f) => f.key === 'village')).toBe(false);
  });
});

describe('Places opens on the person\'s own state (found on staging, 15 Oct)', () => {
  const ctx = (o: object) => ({ user: { client_id: null, state_ids: [] }, scopes: [], assignments: [], slots: [], ...o }) as never;
  it('a State Manager: his state; a Client Manager: the state of his scopes, else of his client', () => {
    expect(homeState(ctx({ assignments: [{ lens: 'state', state_id: 'UP' }] }), {})).toBe('UP');
    expect(homeState(ctx({ scopes: [{ scope_id: 's', state_id: 'UP' }], assignments: [{ lens: 'client', client_id: 'c' }] }), { c: 'BR' })).toBe('UP');
    expect(homeState(ctx({ assignments: [{ lens: 'client', client_id: 'c' }] }), { c: 'UP' })).toBe('UP');
    expect(homeState(ctx({}), {})).toBe('');
  });
});
