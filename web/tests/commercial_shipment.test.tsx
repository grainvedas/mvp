// Migration 54 (release 7 of the operator-stages plan; Veda, 16 Oct 2026): C7 Commercial, C8 Shipment, the Collection
// Batch's collection point, a client's own labs, villages from the list, the farmer picked by village. The forms by the
// lot they come from, the packs of an order, the pack codes of an export shipment, the plain words of the save's new
// refusals, the new words in English and Hindi, and the faults found in release 6's checks (yield beside recovery, a
// market profile's own test with "<= undefined").
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { render } from '@testing-library/react';
import { Widget, buildPayload, missingRequired, withScopeRules, withLotRules, groupSections, serialLines, villageGroups, SUPPORTED, FULL_WIDTH } from '../src/engine/widgets';
import { orderedComputed, showComputed, showEntered } from '../src/engine/values';
import { offlinePreview, type BatchLot } from '../src/engine/offlinePreview';
import { SECTION_ICON } from '../src/engine/icons';
import { plainWords } from '../src/lib/plainErrors';
import { CLIENT_LISTS, villageListed, villagesOfDistrict, type Place } from '../src/lib/setup';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import type { FieldDef, QualityParam } from '../src/lib/types';

const defs = JSON.parse(readFileSync(join(__dirname, 'fixtures/stage_definitions.json'), 'utf8')) as { stage_type: string; form_schema: FieldDef[]; physical_checks: string[] }[];
const form = (s: string) => defs.find((d) => d.stage_type === s)!;
const src = (f: string) => readFileSync(join(__dirname, '../src', f), 'utf8');
const migration = readFileSync(join(__dirname, '../../supabase/migrations/20261029000100_commercial_shipment.sql'), 'utf8')
  + readFileSync(join(__dirname, '../../supabase/migrations/20261101000100_people_public_page_packs.sql'), 'utf8');   // migration 57: the pack codes, domestic too
const t = (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = en[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replace(`{${n}}`, String(x));
  return s;
};
const on = { stage_details_required: true, record_price: true };
const off = { stage_details_required: false };
const keys = (fs: FieldDef[]) => fs.map((f) => f.key);

describe('C7 · the Commercial form', () => {
  const c = form('commercial').form_schema;
  it('where the scope asks the details: the buyer from the list, the order number, the export market; the typed buyer otherwise', () => {
    const a = withScopeRules(c, on), b = withScopeRules(c, off);
    expect(keys(a)).toEqual(expect.arrayContaining(['buyer_id', 'market', 'market_code', 'destination_country', 'order_no', 'sale_route', 'packs', 'price_per_kg', 'currency', 'incoterms']));
    expect(keys(a)).not.toContain('buyer');
    expect(keys(b)).toContain('buyer'); expect(keys(b)).not.toContain('buyer_id'); expect(keys(b)).not.toContain('order_no');
    expect(a.find((f) => f.key === 'buyer_id')?.required).toBe(true);
    expect(a.find((f) => f.key === 'order_no')?.required).toBe(true);
    expect(c.find((f) => f.key === 'sale_route')?.options).toEqual(['own_brand', 'white_label', 'bulk', 'prasaadam']);
  });
  it('a batch packed from the pack list is sold by packs; one without packs by the kilogram', () => {
    const a = withLotRules(withScopeRules(c, on), { packs: true });
    const b = withLotRules(withScopeRules(c, on), { packs: false });
    expect(keys(a)).toContain('packs'); expect(keys(a)).not.toContain('qty_kg');
    expect(keys(b)).toContain('qty_kg'); expect(keys(b)).not.toContain('packs');
    expect(missingRequired(b, {})).toContain('Quantity to this buyer');
  });
  it('the price and terms stand in a section of their own, shown where the scope records prices', () => {
    expect(keys(withScopeRules(c, { ...on, record_price: false }))).not.toContain('price_per_kg');
    expect(c.filter((f) => f.section === 'terms').map((f) => f.key)).toEqual(['price_per_kg', 'currency', 'incoterms']);
    const blocks = groupSections(c).map((g) => g.section);
    expect(new Set(blocks).size).toBe(blocks.length);
  });
  it('the hand-off asks the packs handed over', () => {
    expect(form('commercial').physical_checks).toContain('Packs handed over match the order');
  });
});

describe('C8 · the Shipment form', () => {
  const s = form('shipment').form_schema;
  it('a domestic order asks the vehicle, the LR and the e-way bill; an export order the container, seal, shipping bill; both the pack codes (migration 57)', () => {
    const d = keys(withLotRules(withScopeRules(s, on), { market: 'domestic', packs: true, packed: true }));
    const x = keys(withLotRules(withScopeRules(s, on), { market: 'export', packs: true, packed: true }));
    expect(d).toEqual(expect.arrayContaining(['vehicle_no', 'transporter', 'driver_phone', 'lr_no', 'eway_bill_no', 'invoice_no', 'packs']));
    expect(d).not.toEqual(expect.arrayContaining(['container_no'])); expect(d).toContain('serials'); expect(d).not.toContain('shipping_bill_no');
    expect(x).toEqual(expect.arrayContaining(['container_no', 'seal_no', 'shipping_bill_no', 'bl_no', 'vessel', 'port_loading', 'serials', 'invoice_no']));
    expect(x).not.toContain('vehicle_no'); expect(x).not.toContain('lr_no');
    expect(withLotRules(withScopeRules(s, on), { market: 'export', packs: true }).find((f) => f.key === 'container_no')?.required).toBe(true);
  });
  it('a scope without the details keeps the form of before', () => {
    const b = keys(withLotRules(withScopeRules(s, off), { market: 'domestic', packs: false }));
    expect(b).toEqual(expect.arrayContaining(['shipped_kg', 'vehicle_or_container', 'dispatch_date', 'destination']));
    expect(b).not.toContain('invoice_no'); expect(b).not.toContain('serials');
    // migration 62 (E2.1): a packed lot is shipped by its codes in such a scope too, and they are required
    const pk = withLotRules(withScopeRules(s, off), { market: 'domestic', packs: false, packed: true });
    expect(pk.find((f) => f.key === 'serials')?.required).toBe(true); expect(keys(pk)).toContain('shipped_kg');
  });
  it('every section is one block, and every section has its words and pictogram', () => {
    const blocks = groupSections(s).map((g) => g.section);
    expect(new Set(blocks).size).toBe(blocks.length);
    for (const sec of ['terms', 'papers']) { expect(en[`section.${sec}`]).toBeTruthy(); expect(hi[`section.${sec}`]).toBeTruthy(); expect(SECTION_ICON[sec]).toBeTruthy(); }
  });
  it('the loading photo is filed as the loading photo (an export shipment is verified once it is there)', () => {
    expect(s.find((f) => f.key === 'loading_photo')?.label_as).toBe('loading_photo');
  });
});

describe('the packs of an order and the pack codes', () => {
  const packs: FieldDef = { key: 'packs', type: 'order_packs', label: 'Packs sold', required: true };
  const ser: FieldDef = { key: 'serials', type: 'serials', label: 'Pack codes', required: true };
  it('sends the pack types with their counts (never the kilograms: the server works them out)', () => {
    const v = { packs: [{ sku_id: 'a', units: '30' }, { sku_id: 'b', units: '' }, { sku_id: 'c', units: '0' }] as unknown as string[] };
    expect(buildPayload([packs], v).payload).toEqual({ packs: [{ sku_id: 'a', units: 30 }] });
    expect(missingRequired([packs], { packs: [] as unknown as string[] })).toEqual(['Packs sold']);
  });
  it('takes the pack codes one per line (or by commas), in capitals', () => {
    expect(serialLines('k05-b0001-0001\n K05-B0001-0002 ,K05-B0001-0003\n\n')).toEqual(['k05-b0001-0001', 'K05-B0001-0002', 'K05-B0001-0003']);
    expect(buildPayload([ser], { serials: 'k05-b0001-0001\nK05-B0001-0002' }).payload).toEqual({ serials: ['K05-B0001-0001', 'K05-B0001-0002'] });
    expect(missingRequired([ser], { serials: ' \n ' })).toEqual(['Pack codes']);
  });
  it('the new field types render, and the lists take the whole row', () => {
    for (const ty of ['buyer', 'market_profile', 'order_packs', 'serials']) {
      expect(SUPPORTED.has(ty)).toBe(true);
      const { container, unmount } = render(<Widget id={`x-${ty}`} field={{ key: ty, type: ty, label: ty }} value={null} onChange={() => {}} qualityParams={[]} clientId="c" />);
      expect(container.firstChild).not.toBeNull(); unmount();
    }
    expect(FULL_WIDTH.has('order_packs') && FULL_WIDTH.has('serials')).toBe(true);
  });
});

describe('the worked-out values of a sale and a shipment', () => {
  it('in their order, in plain words; the buyer\'s row id is not shown', () => {
    const c = orderedComputed({ packs: [{ sku_id: 'x', name: '1 kg pouch', size_kg: 1, units: 30 }], buyer_id: 'uuid', order_no: 'PO-101', buyer: 'Delhi Wholesale', market: 'domestic' }).map(([k]) => k);
    expect(c).toEqual(['market', 'buyer', 'order_no', 'packs']);
    expect(orderedComputed({ market_code: 'eu', market_name: 'EU' }).map(([k]) => k)).toEqual(['market_name']);   // the name, not the code
    expect(showComputed('packs', [{ sku_id: 'x', name: '1 kg pouch', size_kg: 1, units: 30 }, { sku_id: 'y', name: '500 g pouch', size_kg: 0.5, units: 4 }], t)).toBe('30 × 1 kg pouch · 4 × 500 g pouch');
    expect(showComputed('sale_route', 'own_brand', t)).toBe('Own brand');
    expect(showComputed('bl_pending', true, t)).toBe('Yes');
    expect(showEntered({ key: 'serials', type: 'serials', label: 'x' }, 'serials', ['A', 'B'], t)).toBe('2 pack codes');
  });
  it('every new worked-out key has its words in English and Hindi', () => {
    for (const k of ['buyer_country', 'order_no', 'market_code', 'market_name', 'destination_country', 'sale_route', 'packs', 'invoice_no', 'serials_count', 'container_no', 'bl_pending']) {
      expect(en[`computed.${k}`], k).toBeTruthy(); expect(hi[`computed.${k}`], k).toBeTruthy();
      expect(migration).toContain(`'${k}'`);
    }
  });
  it('a milling run shows its recovery once (found in release 6\'s checks: "Yield" stood beside "Recovery", the same figure)', () => {
    expect(orderedComputed({ recovery_pct: 68, yield_pct: 68, loss_kg: 3 }).map(([k]) => k)).toEqual(['recovery_pct', 'loss_kg']);
    expect(orderedComputed({ yield_pct: 70 }).map(([k]) => k)).toEqual(['yield_pct']);               // a run of before keeps its yield
  });
});

describe('a market profile\'s own test shows its limits (found in release 6\'s checks: "domestic <= undefined")', () => {
  it('the lab form names each market\'s limit', () => {
    const q: QualityParam = { param: 'aflatoxin_ppb', label: 'Aflatoxin', unit: 'ppb', operator: '<=', from_profile: true,
      limits: [{ market: 'EU', operator: '<=', limit: 2 }, { market: 'UAE', operator: '<=', limit: 0.5 }] } as unknown as QualityParam;
    const { container } = render(<Widget id="r" field={{ key: 'readings', type: 'readings', label: 'Readings' }} value={null} onChange={() => {}} qualityParams={[q]} clientId="c" />);
    expect(container.textContent).toContain('EU <= 2 · UAE <= 0.5');
    expect(container.textContent).not.toContain('undefined');
    expect(migration).toContain("'limits', (select coalesce(jsonb_agg(jsonb_build_object('market', m2.name, 'operator'");
  });
});

describe('the Collection Batch names its collection point (Veda, 16 Oct: "there can be more than 1 cc in a scope")', () => {
  const L = (id: string, point: string): BatchLot => ({ id, code: `P-${id}`, qty: 100, point, point_name: point === 'cp-1' ? 'Bansi centre' : 'Itwa store', village: 'Bansi', farmer_id: `f-${id}`, moisture_avg: 12, gi_status: 'gi' });
  const lots = new Map([L('1', 'cp-1'), L('2', 'cp-1'), L('3', 'cp-2')].map((l) => [l.id, l]));
  const pv = (p: Record<string, unknown>, rules = {}) => offlinePreview('village_batch', p, {}, {}, { lots, ...rules });
  it('the point is the first field of the batch, required where the scope asks the details', () => {
    const vb = form('village_batch').form_schema;
    expect(vb[0]).toMatchObject({ key: 'collection_point_id', type: 'collection_point', required_when: 'stage_details_required' });
    expect(withScopeRules(vb, on)[0].required).toBe(true);
  });
  it('offline, as the save: the lots are that point\'s; the point is asked where the scope asks the details', () => {
    expect(pv({ collection_point_id: 'cp-1', source_footprint_ids: ['1', '2'] }).ok).toBe(true);
    expect(pv({ collection_point_id: 'cp-2', source_footprint_ids: ['1', '2'] }).error)
      .toBe('collection batch: P-1, P-2 not weighed at this collection point (a batch is the lots of the point it names)');
    expect(pv({ source_footprint_ids: ['1', '2'] }, { stage_details_required: true }).error).toBe('collection batch: choose the collection point (where the bags are)');
    expect(pv({ source_footprint_ids: ['1', '2'] }).ok).toBe(true);                                     // a scope without the details: as before
    // the same words as the save (app.reconcile)
    expect(migration).toContain("'collection batch: % not weighed at this collection point (a batch is the lots of the point it names)'");
    expect(migration).toContain("'collection batch: choose the collection point (where the bags are)'");
  });
  it('the offline mirror is told the scope\'s setting', () => {
    expect(src('engine/StagePage.tsx')).toContain('stage_details_required: form.scope.stage_details_required === true');
  });
});

describe('the farmer and his village from the lists (Veda, 16 Oct: points 1 and 3)', () => {
  it('the farmer is picked by his village first, then from that village\'s farmers', () => {
    const g = villageGroups([{ village: 'Bansi' }, { village: 'BANSI ' }, { village: 'Itwa' }]);
    expect(g).toEqual([{ key: 'bansi', village: 'BANSI ', n: 2 }, { key: 'itwa', village: 'Itwa', n: 1 }]);
    const w = src('engine/widgets.tsx');
    expect(w).toContain('data-testid="pick-village"'); expect(w).toContain('data-testid="pick-farmer"');
    expect(w).toContain('cached(`farmers:${clientId}`');                                               // still on the phone, offline
  });
  const P: Place[] = [
    { id: '1', state_id: 'UP', district: 'Siddharthnagar', block: null, village: null },
    { id: '2', state_id: 'UP', district: 'Siddharthnagar', block: 'Bansi', village: null },
    { id: '3', state_id: 'UP', district: 'Siddharthnagar', block: 'Bansi', village: 'Itwa' },
    { id: '4', state_id: 'UP', district: 'Siddharthnagar', block: 'Domariyaganj', village: 'Domariyaganj' }];
  it('a village is on the list of its district (and block), as the save asks it; a state with no list as before', () => {
    expect(villagesOfDistrict(P, 'UP', 'siddharth nagar')).toEqual(['Domariyaganj', 'Itwa']);
    expect(villageListed(P, 'UP', 'Siddharthnagar', 'Bansi', 'ITWA')).toBe(true);
    expect(villageListed(P, 'UP', 'Siddharthnagar', 'Bansi', 'Domariyaganj')).toBe(false);
    expect(villageListed(P, 'UP', 'Siddharthnagar', '', 'Domariyaganj')).toBe(true);
    expect(villageListed(P, 'UP', 'Siddharthnagar', '', 'Rampur')).toBe(false);
    expect(villageListed(P, 'AS', 'Kamrup', '', 'anything')).toBe(true);
    expect(migration).toContain("the village % is not on the list of district %: pick it from the list (Set-up lists, Places, adds it first)");
  });
});

describe('labs: the state\'s and the client\'s own (Veda, 16 Oct: point 4)', () => {
  it('the Client Manager keeps labs among his lists; the lab pickers offer the state\'s and the client\'s', () => {
    expect(CLIENT_LISTS).toContain('labs');
    expect(src('engine/widgets.tsx')).toContain('and(client_id.is.null,state_id.eq.${stateId}),client_id.eq.${clientId}');
    expect(src('pages/records/Samples.tsx')).toContain('labsFor(stateId, f.client_id)');
    expect(migration).toContain('((l.client_id is null and l.state_id = s.state_id) or l.client_id = s.client_id)');
    expect(en['set.list_labs']).toBeTruthy(); expect(hi['set.list_labs']).toBeTruthy();
  });
});

describe('the plain words for every new refusal', () => {
  const said: [string, RegExp][] = [
    ['collection batch: P-0001, P-0002 not weighed at this collection point (a batch is the lots of the point it names)', /P-0001, P-0002: not weighed/],
    ['collection batch: choose the collection point (where the bags are)', /Choose the collection point/],
    ['the village Rampur is not on the list of district Siddharthnagar: pick it from the list (Set-up lists, Places, adds it first)', /Rampur is not on the list of district Siddharthnagar/],
    ['qc: the lab is not on this state\'s or this client\'s list', /this state's or this client's list/],
    ['sample: the lab is not on this state\'s or this client\'s list', /this state's or this client's list/],
    ['a lab stays with whoever keeps it (the state or the client)', /stays with whoever keeps it/],
    ['commercial: choose the buyer from the client\'s list', /Choose the buyer/],
    ['commercial: the buyer is not one of this client\'s active buyers', /active buyers/],
    ['commercial: give the order or contract number', /order or contract number/],
    ['commercial: choose the export market (one of this scope\'s market profiles)', /Choose the export market/],
    ['commercial: this batch has not passed QC for UAE (nor carries the client\'s written acceptance)', /not passed QC for UAE/],
    ['commercial: name the destination country', /destination country/],
    ['commercial: choose the packs (by pack type)', /Choose the packs/],
    ['commercial: only 130 packs of 1 kg pouch are left', /Only 130 packs of 1 kg pouch are left/],
    ['commercial: the number of packs is a whole number, 1 or more', /whole number/],
    ['commercial: a pack type chosen is not in this lot', /not in this lot/],
    ['shipment: each pack type once', /Each pack type once/],
    ['the sale price and terms are recorded at Commercial', /recorded at Commercial/],
    ['a received document has its file (attach it first)', /attach it first/],
    ['say why the document is not required (at least 5 characters)', /not required/],
    ['this document is not on the list of the sale\'s market', /not on the list of the sale's market/],
    ['the export documents are kept by Commercial or a manager of the scope', /kept by Commercial/],
    ['shipment: give the invoice number', /invoice number/],
    ['shipment: the export documents of order CO-0002 are not complete (Health certificate): attach their files at Commercial first', /order CO-0002 are not complete \(Health certificate\)/],
    ['shipment: scan or type the codes of the packs loaded (export)', /Scan or type the codes/],
    ['shipment: scan or type the codes of the packs loaded', /Scan or type the codes/],   // migration 57: domestic too
    ['shipment: a pack code is there twice', /twice/],
    ['shipment: NOT-A-PACK not a pack of this order\'s batch (or void)', /NOT-A-PACK: not a pack of this order's batch/],
    ['shipment: K-0001 shipped already', /K-0001: shipped already/],
    ['shipment: the codes scanned do not match the packs shipped (1 kg pouch)', /do not match the packs shipped \(1 kg pouch\)/],
    ['shipment: the container number is 4 letters and 7 digits (e.g. MSKU1234567)', /4 letters and 7 digits/],
    ['shipment: give the container seal number', /seal number/],
    ['shipment: the shipping bill number is 6 to 8 digits', /6 to 8 digits/],
    ['shipment: the vehicle number reads like UP53AB1234', /UP53AB1234/],
    ['shipment: give the LR (lorry receipt) number', /LR/],
    ['shipment: the driver\'s phone is a 10-digit mobile number', /10-digit/],
    ['shipment: an e-way bill number is 12 digits', /12 digits/],
    ['shipment: attach the loading photo (the seal or the vehicle) before this export shipment is verified', /loading photo/],
    ['a bill of lading number is 4 to 30 letters or digits', /4 to 30/],
    ['a bill of lading belongs to an export shipment', /belongs to an export shipment/],
    ['this shipment has its bill of lading already', /already/],
  ];
  // what the save says, as patterns: each `raise exception '…'` of the migration, its % parts standing for anything
  const raised = [...migration.matchAll(/raise exception '((?:[^']|'')*)'/g)].map((m) => new RegExp(`^${m[1].replace(/''/g, "'")
    .replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/%/g, '.+?')}$`));
  it.each(said)('%s', (raw, words) => {
    expect(raised.some((r) => r.test(raw)), `the save says: ${raw}`).toBe(true);
    const w = plainWords(raw, t);
    expect(w).toMatch(words);
  });
  it('(a control: a sentence the save never says is not found)', () => {
    expect(raised.length).toBeGreaterThan(100);
    expect(raised.some((r) => r.test('shipment: the codes are fine'))).toBe(false);
  });
  it('every new plain word has its Hindi', () => {
    for (const k of Object.keys(en).filter((x) => /^err\.(cb_|co_|ord_|xd_|sh_|bl_|lab_|village_listed)/.test(x))) expect(hi[k], k).toBeTruthy();
  });
});
