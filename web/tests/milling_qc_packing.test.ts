// Migration 53 (release 6 of the operator-stages plan): C4 Milling, C5 Quality Control, C6 Packing. The forms by the
// scope's setting, the packs from the client's list, the plain words of the save's new refusals and warnings, the new
// words in English and Hindi, and the scope's settings card, the record's panels and the public page's market verdicts.
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { buildPayload, missingRequired, withScopeRules, groupSections, skuKg } from '../src/engine/widgets';
import { orderedComputed, showComputed, showEntered } from '../src/engine/values';
import { SECTION_ICON } from '../src/engine/icons';
import { plainWords, PLAIN_RULES } from '../src/lib/plainErrors';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';
import type { FieldDef } from '../src/lib/types';

const defs = JSON.parse(readFileSync(join(__dirname, 'fixtures/stage_definitions.json'), 'utf8')) as { stage_type: string; form_schema: FieldDef[]; handoff_checks: string[]; physical_checks: string[] }[];
const form = (s: string) => defs.find((d) => d.stage_type === s)!;
const src = (f: string) => readFileSync(join(__dirname, '../src', f), 'utf8');
const migration = readFileSync(join(__dirname, '../../supabase/migrations/20261028000100_milling_qc_packing.sql'), 'utf8');
const t = (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = en[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replace(`{${n}}`, String(x));
  return s;
};
const on = { stage_details_required: true };
const off = { stage_details_required: false };

describe('C4 · the milling form', () => {
  const m = form('milling').form_schema;
  it('asks the mill where the scope says so; the outputs are head rice, broken, husk and bran (the loss is worked out)', () => {
    expect(withScopeRules(m, on).find((f) => f.key === 'mill_id')?.required).toBe(true);
    expect(withScopeRules(m, off).find((f) => f.key === 'mill_id')?.required).toBe(false);
    expect(m.map((f) => f.key)).toEqual(expect.arrayContaining(['line_clearance', 'mill_operator', 'input_kg', 'sent_kg', 'head_rice_kg', 'broken_kg', 'husk_kg', 'bran_kg', 'polish']));
    expect(m.some((f) => ['rice_out_kg', 'loss_kg'].includes(f.key))).toBe(false);
    expect(m.find((f) => f.key === 'line_clearance')?.options).toEqual(['fully_cleaned', 'quick_clean', 'same_crop']);
  });
  it('the worked-out values come in their order, in plain words', () => {
    const c = orderedComputed({ loss_kg: 3, recovery_pct: 68.2, mill: 'Basti mill', head_rice_kg: 600, line_clearance: 'dedicated' }).map(([k]) => k);
    expect(c.slice(0, 4)).toEqual(['mill', 'line_clearance', 'head_rice_kg', 'recovery_pct']);
    expect(showComputed('line_clearance', 'dedicated', t)).toBe('Dedicated to this crop');
    expect(showComputed('recovery_pct', 68.2, t)).toBe('68.2 %');
    expect(showEntered({ key: 'mill_id', type: 'mill', label: 'Mill' }, 'mill_id', 'uuid-1', t)).toBe('from the list');
  });
});

describe('C5 · the lab record', () => {
  const q = form('qc').form_schema;
  it('where the scope asks the details: the sample drawn first replaces the typed sample and lab name', () => {
    const a = withScopeRules(q, on).map((f) => f.key);
    const b = withScopeRules(q, off).map((f) => f.key);
    expect(a).toContain('sample_ref'); expect(a).not.toContain('sample_qty_kg'); expect(a).not.toContain('lab_name');
    expect(b).not.toContain('sample_ref'); expect(b).toContain('sample_qty_kg'); expect(b).toContain('lab_name');
    expect(withScopeRules(q, on).find((f) => f.key === 'sample_ref')?.required).toBe(true);
    expect(missingRequired(withScopeRules(q, on), {})).toContain('Sample (drawn and sent to the lab)');
  });
  it('the sample stands with the lot quantity: every section is one block', () => {
    const blocks = groupSections(q).map((g) => g.section);
    expect(new Set(blocks).size).toBe(blocks.length);
  });
  it('the counter-sample is checked at the hand-off', () => {
    expect(form('qc').physical_checks).toEqual(expect.arrayContaining(['Counter-sample stored']));
  });
});

describe('C6 · the packing form', () => {
  const p = form('packing').form_schema;
  it('packs from the client\'s list where the scope asks the details; typed sizes elsewhere; the wastage is worked out', () => {
    const a = withScopeRules(p, on), b = withScopeRules(p, off);
    expect(a.filter((f) => f.key === 'packets').map((f) => f.type)).toEqual(['sku_packs']);
    expect(b.filter((f) => f.key === 'packets').map((f) => f.type)).toEqual(['packets[]']);
    expect(a.find((f) => f.key === 'packing_unit_id')?.required).toBe(true);
    expect(p.some((f) => f.key === 'wastage_kg')).toBe(false);
  });
  it('a pack from the list goes to the record with its own size; a row half filled is not sent', () => {
    const a = withScopeRules(p, on);
    const rows = [{ sku_id: 'k1', units: '40', size_kg: String(skuKg({ size: 500, unit: 'g' })) }, { sku_id: '', units: '3', size_kg: '' }];
    expect(buildPayload(a, { input_kg: '20.5', packing_unit_id: 'u1', packets: rows as never }).payload)
      .toMatchObject({ packets: [{ sku_id: 'k1', units: 40, size_kg: 0.5 }], packing_unit_id: 'u1' });
    expect(missingRequired(a, { input_kg: '20', packing_unit_id: 'u1', packets: [{ sku_id: 'k1', units: '', size_kg: '1' }] as never })).toContain('Packs (from the pack list)');
    expect(skuKg({ size: 5, unit: 'kg' })).toBe(5);
  });
  it('Commercial counts the packs per size before it accepts them', () => {
    expect(form('packing').physical_checks).toContain('Pack count per size matches the packing record');
  });
});

describe('the save\'s new refusals and warnings, in plain words', () => {
  const cases: [string, string][] = [
    ['milling: say which mill (from the client\'s list)', "Say which mill (from the client's list)."],
    ['milling: the outputs (1020 kg) are more than the paddy in (1000 kg)', 'The outputs (1020 kg) are more than the paddy in (1000 kg).'],
    ['milling: the mill received (510 kg) more than was sent (500 kg)', 'The mill received 510 kg, more than was sent (500 kg).'],
    ['packing: the wastage is 3.5 % of the input (more than 2 %): say why', 'The wastage is 3.5 % of the input (more than 2 %): say why.'],
    ['packing: a pack from the list keeps its own size (500 g)', 'A pack from the list keeps its own size (500 g).'],
    ['qc: choose the sample drawn from this lot (draw it first: it goes to the lab)', "Choose the sample drawn from this lot. Draw it first, on the lot's record: it goes to the lab."],
    ['qc: Aflatoxin is a lab test: it is read at an accredited external lab', 'Aflatoxin is a lab test: it is read at an accredited external lab.'],
    ['sample: drawn between the lot\'s date (2026-10-01) and today', "The sample is drawn between the lot's date (2026-10-01) and today."],
    ['the counter-sample is kept until 2027-10-01: before then only a manager disposes of it', 'The counter-sample is kept until 2027-10-01. Before then only a manager disposes of it.'],
    ['only a lot with 2 % or less left is closed (30 kg of 1000 kg is left)', 'Only a lot with 2 % or less left is closed (30 kg of 1000 kg is left).'],
    ['weigh pack TC-0001 (its weight in grams)', 'Weigh pack TC-0001 (its weight in grams).'],
    ['packing: weigh the packs the system picked (net weight check) before this record is verified', 'Weigh the packs the system picked (net weight check) before this record is verified.'],
    ['an export release names the client\'s authorising person, their title and the date of the acceptance', "An export release names the client's authorising person, their title and the date of the acceptance."],
    ['recovery 61 % is outside the usual range of this mill (66 to 70 %, from 5 verified runs)', 'Recovery 61 % is outside the usual range of this mill (66 to 70 %, from 5 verified runs)'],
    ['wastage 3.5 % is above 2 %: spill at the hopper', 'Wastage 3.5 % is above 2 %: spill at the hopper'],
  ];
  it.each(cases)('%s', (raw, plain) => { expect(plainWords(raw, t)).toBe(plain); });
  it('every refusal the migration raises for these stages has its plain words', () => {
    const raised = [...migration.matchAll(/raise exception '((?:milling|packing|qc|sample): (?:[^']|'')+)'/g)].map((m) => m[1].replace(/''/g, "'"))
      .filter((s) => !/payload\.|batch_code|Σ packets|sample must be smaller|readings|report/.test(s));
    expect(raised.length).toBeGreaterThan(20);
    for (const s of raised) expect(plainWords(s.replace(/%%/g, '\u0000').replace(/%/g, '1').replace(/\u0000/g, '%'), t), s).not.toBeNull();
  });
  it('every rule has English and Hindi', () => {
    for (const r of PLAIN_RULES) { expect(en[r.key], r.key).toBeTruthy(); expect(hi[r.key], r.key).toBeTruthy(); }
  });
});

describe('the new words, in English and Hindi', () => {
  const keysIn = (f: string) => [...src(f).matchAll(/\bt\('((?:smp|nw|cl|ss|qcm|ov|pk)\.[a-z_]+)'/g)].map((m) => m[1]);
  it('the record\'s panels, the scope\'s settings and the pickers', () => {
    const ks = [...keysIn('pages/records/RecordDetail.tsx'), ...keysIn('pages/records/Samples.tsx'), ...keysIn('pages/scopes/Scopes.tsx'), ...keysIn('engine/widgets.tsx'),
      ...['sent', 'results_in', 'disposed'].map((s) => `smp.st_${s}`), 'nw.pass', 'nw.fail', 'nw.again', 'nw.save'];
    expect(ks.length).toBeGreaterThan(40);
    for (const k of ks) { expect(en[k], k).toBeTruthy(); expect(hi[k], k).toBeTruthy(); }
  });
  it('every field, option, check and section of the three forms', () => {
    for (const s of ['milling', 'qc', 'packing']) {
      const d = form(s);
      for (const f of d.form_schema) {
        const k = en[`field.${s}.${f.key}`] ? `field.${s}.${f.key}` : `field.${f.key}`;
        expect(en[k], k).toBeTruthy(); expect(hi[k], k).toBeTruthy();
        if (f.section) { expect(hi[`section.${f.section}`], f.section).toBeTruthy(); expect(SECTION_ICON[f.section], f.section).toBeTruthy(); }
        for (const o of f.options ?? []) expect(hi[`opt.${o}`], o).toBeTruthy();
      }
      for (const c of [...d.handoff_checks, ...d.physical_checks]) expect(hi[`check.${c}`], c).toBeTruthy();
    }
  });
  it('the worked-out values', () => {
    for (const k of ['mill', 'line_clearance', 'head_rice_kg', 'broken_kg', 'husk_kg', 'recovery_pct', 'head_rice_pct', 'sample_code', 'lab', 'lab_kind', 'packing_unit', 'wastage_pct']) {
      expect(en[`computed.${k}`], k).toBeTruthy(); expect(hi[`computed.${k}`], k).toBeTruthy();
    }
  });
  it('the public page says the verdict per market, from its own small dictionary', () => {
    expect(enPublic['pv.by_market']).toBeTruthy(); expect(hiPublic['pv.by_market']).toBeTruthy();
    expect(src('pages/public/PublicVerify.tsx')).toContain("data-testid=\"pv-markets\"");
  });
});

describe('the screens', () => {
  it('the scope\'s settings: the details and the markets, saved at once and put back if refused', () => {
    const s = src('pages/scopes/Scopes.tsx');
    expect(s).toContain('function StageSettings');
    expect(s).toContain('save({ stage_details_required: v }');
    expect(s).toContain('save({ market_codes: next }');
  });
  it('the record: samples before QC, the net weight check at Packing, closing a lot with little left', () => {
    const r = src('pages/records/RecordDetail.tsx') + src('pages/records/Samples.tsx');
    for (const x of ['<SamplesPanel', '<NetWeightPanel', '<ClosePanel', "rpc('draw_sample'", "rpc('dispose_sample'", "rpc('pick_net_weight'", "rpc('record_net_weights'", "rpc('close_lot'"])
      expect(r, x).toContain(x);
    // and on the QC screen, where the lot is verified (the sample comes before its results)
    expect(src('engine/StagePage.tsx')).toContain("form.scope.stage_details_required === true && <SamplesPanel f={source} />");
    expect(r).toContain('client_person'); expect(r).toContain('accepted_on');
  });
  it('the public page never reads the worked-out values', () => {
    const low = migration.toLowerCase();
    const at = low.indexOf('create or replace function app.public_lot_journey');
    expect(at).toBeGreaterThan(0);
    const body = low.slice(at, low.indexOf('$function$', low.indexOf('$function$', at) + 10));
    expect(body.length).toBeGreaterThan(500);
    expect(body).not.toContain('computed');
  });
  it('a long menu line never runs into the next (release 52 finding on a laptop)', () => {
    expect(src('styles.css')).toContain('.nav > * { flex-shrink: 0; }');
  });
});
