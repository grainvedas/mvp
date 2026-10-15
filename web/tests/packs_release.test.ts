// Migration 50 (Veda, 15 Oct 2026: the operator-stages brief, release 3, "packs, proof and blocks"). The database's
// rules are tested in tests/44_packs_and_release.sql; these hold the screens' part: the lab report fields required where
// the scope asks for them, the release summary in words, one label per pack, the public page without farmer names, and
// every new refusal in plain English and Hindi.
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { missingFiles, missingRequired, withScopeRules } from '../src/engine/widgets';
import { plainWords } from '../src/lib/plainErrors';
import { registerDictionary, translate } from '../src/lib/i18n';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';
import { sheetRange, packUrl, LABELS_PER_SHEET } from '../src/pages/records/PackLabels';
import { farmPlace } from '../src/pages/public/PublicVerify';
import { relVars } from '../src/engine/StagePage';
import type { FieldDef } from '../src/lib/types';

registerDictionary('en', en); registerDictionary('hi', hi);
const tEn = (k: string, v?: Record<string, string | number>, f?: string) => translate('en', k, v, f);
const tHi = (k: string, v?: Record<string, string | number>, f?: string) => translate('hi', k, v, f);
const migration = readFileSync(join(__dirname, '../../supabase/migrations/20261025000100_packs_and_release.sql'), 'utf8');
const src = (f: string) => readFileSync(join(__dirname, '../src', f), 'utf8');
const fixture = JSON.parse(readFileSync(join(__dirname, 'fixtures/stage_definitions.json'), 'utf8')) as { stage_type: string; form_schema: FieldDef[] }[];

describe('the lab proof (C5)', () => {
  const qc = fixture.find((d) => d.stage_type === 'qc')!.form_schema;
  it('the lab record asks the lab, the report number, its date and the file only where the scope asks for the report', () => {
    const asked = withScopeRules(qc, { qc_report_required: true });
    const notAsked = withScopeRules(qc, { qc_report_required: false });
    for (const k of ['lab_name', 'report_no', 'report_date', 'report_file']) {
      expect(asked.find((f) => f.key === k)?.required, k).toBe(true);
      expect(notAsked.find((f) => f.key === k)?.required, k).toBe(false);
    }
    expect(asked.find((f) => f.key === 'sample_id')?.required).toBe(false);
    expect(missingRequired(asked, {})).toEqual(expect.arrayContaining(['Lab', 'Report number', 'Report date']));
    expect(missingFiles(asked, {})).toEqual(['Lab report (PDF or photo)']);
    expect(missingFiles(asked, { report_file: new File(['x'], 'r.pdf', { type: 'application/pdf' }) })).toEqual([]);
    expect(missingFiles(notAsked, {})).toEqual([]);
  });
  it('the report file is registered as the lab report (the server asks for it before verification)', () => {
    expect(qc.find((f) => f.key === 'report_file')?.label_as).toBe('lab_report');
    expect(src('engine/StagePage.tsx')).toContain('uploadEvidence(rec, file, field.label_as)');
    expect(src('engine/evidence.ts')).toContain("rpc('register_labelled_attachment'");
  });
  it('the forms no longer ask for the batch code nor the transit loss (G1, G12)', () => {
    expect(fixture.find((d) => d.stage_type === 'packing')!.form_schema.some((f) => f.key === 'batch_code')).toBe(false);
    expect(fixture.find((d) => d.stage_type === 'shipment')!.form_schema.some((f) => f.key === 'transit_loss_kg')).toBe(false);
  });
  it('every new field and every kind of document has its words in both languages', () => {
    for (const k of ['lab_name', 'report_no', 'report_date', 'sample_id', 'report_file']) { expect(en[`field.${k}`], k).toBeTruthy(); expect(hi[`field.${k}`], k).toBeTruthy(); }
    const labels = /label in \(([^)]+)\)/.exec(migration)![1].match(/'([a-z_]+)'/g)!.map((x) => x.slice(1, -1));
    expect(labels).toEqual(['lab_report', 'acceptance', 'pod', 'loading_photo', 'document']);
    for (const l of labels) { expect(en[`att.${l}`], l).toBeTruthy(); expect(hi[`att.${l}`], l).toBeTruthy(); }
  });
});

describe('the summary before release (G9)', () => {
  const fn = migration.slice(migration.indexOf('create or replace function app.release_preview'), migration.indexOf('create or replace function app.set_release_status'));
  it('every line the server sends has its words in both languages', () => {
    const keys = [...new Set([...fn.matchAll(/'key', '([a-z_]+)'/g)].map((m) => m[1]))];
    expect(keys.length).toBeGreaterThanOrEqual(7);
    for (const k of [...keys, 'lab_verdict_released']) { expect(en[`rel.${k}`], k).toBeTruthy(); expect(hi[`rel.${k}`], k).toBeTruthy(); }
  });
  it('a verdict and a GI status are shown in the reader\'s words, never as the database writes them', () => {
    expect(relVars({ domestic: 'pass', export: 'fail', released: true }, tHi)).toEqual({ domestic: tHi('pv.v_pass'), export: tHi('pv.v_fail'), released: tHi('common.yes') });
    expect(relVars({ status: 'non_gi', codes: '' }, tEn)).toEqual({ status: tEn('gi.non_gi'), codes: '—' });
  });
  it('the seal waits until the summary is read', () => {
    expect(src('engine/StagePage.tsx')).toContain('(!!summary.data && !readSummary)');
  });
});

describe('one label per pack (G8, Part D)', () => {
  it('labels come in sheets the phone can draw; each opens its own pack page', () => {
    expect(sheetRange(0, 0)).toEqual({ from: 0, to: 0 });
    expect(sheetRange(0, 156)).toEqual({ from: 0, to: LABELS_PER_SHEET });
    expect(sheetRange(1, 156)).toEqual({ from: LABELS_PER_SHEET, to: 156 });
    expect(sheetRange(9, 156)).toEqual({ from: LABELS_PER_SHEET, to: 156 });        // past the end: the last sheet
    expect(packUrl('https://x.app', 'TCUP-KNM-KH26-B0001-0007')).toBe('https://x.app/p/TCUP-KNM-KH26-B0001-0007');
    expect(src('App.tsx')).toContain('path="/p/:serial"');
  });
});

describe('the public page (Part D)', () => {
  it('names the village and the district, never the farmer', () => {
    expect(farmPlace({ village: 'Bansi', district: 'Siddharthnagar', name: 'Ram Achal' } as never)).toBe('Bansi, Siddharthnagar');
    const pv = src('pages/public/PublicVerify.tsx');
    expect(pv).not.toMatch(/farmer\.name|f\.name/);
    expect(pv).not.toContain("'pv.grown_by'");
  });
  it('an export released on acceptance is never called passed; a recall stands above everything', () => {
    expect(enPublic['pv.override']).toMatch(/not a lab pass/);
    expect(enPublic['pv.override']).not.toMatch(/\bpassed\b/);
    for (const k of ['pv.rel_recalled', 'pv.rel_under_investigation', 'pv.not_released', 'pv.pack_void', 'pv.grown_in', 'pv.packs', 'pv.best_before', 'pv.pack', 'pv.packed_on', 'pv.pack_not_found', 'pv.rel_reason']) {
      expect(enPublic[k], k).toBeTruthy(); expect(hiPublic[k], k).toBeTruthy(); expect(hiPublic[k]).not.toBe(enPublic[k]);
    }
  });
});

describe('every new refusal in plain words (A4/G13)', () => {
  const msgs = [
    'qc: the lab, the report number and the report date are required',
    'qc: the report date (17 Oct 2026) is in the future',
    'qc: the report date (01 Oct 2026) is before the lot it tests (PRSDM-KNM-KH26-BSTA-QC-0002 on 05 Oct 2026)',
    'qc: report r-1 of this lab is on PRSDM-KNM-KH26-BSTA-QC-0002 already (the same report twice needs the same sample ID)',
    'qc: the lab report file is attached before the lab record is verified',
    'GI and non-GI lots are not batched together (PRSDM-KNM-KH26-BNS-P-0001 gi, PRSDM-KNM-KH26-BNS-P-0002 non-gi)',
    'an export release needs the client\'s written acceptance attached to the lab record first',
    'these labels were printed before: say why they are printed again',
    'say why the pack is void (at least 10 characters)',
    'a recalled release stays recalled',
    'the release is under investigation already',
    'the Client Manager of the client (or the State Manager of the state) changes a release\'s status',
    'say why (at least 10 characters)',
    'what arrived is between 0 and the 128.000 kg shipped',
    'the delivery date is between the dispatch and today',
    'for export, the proof of delivery is attached first',
    'the delivery is confirmed already',
    'at most 20000 packs in one packing record (20001 given)',
    'labels are printed at Packing (or by a manager of this scope)',
    'a pack is voided at Packing (or by a manager of this scope)',
    'this pack is void already',
    'the delivery is confirmed at Shipment (or by a manager of this scope)',
    'this shipment is superseded',
    'unknown kind of document',
    'whether the lab report is asked is set before the scope is activated',
  ];
  it.each(msgs)('%s', (m) => {
    const e = plainWords(m, tEn), h = plainWords(m, tHi);
    expect(e).toBeTruthy(); expect(h).toBeTruthy(); expect(h).not.toBe(e);
    expect(e).not.toMatch(/\{[a-z]+\}/); expect(h).not.toMatch(/\{[a-z]+\}/);
  });
  it('every message the migration raises for people is one of them', () => {
    // the functions this migration adds (the patched ones keep their older messages, which have their rules already)
    const own = migration.slice(0, migration.indexOf('Patches of the current definitions'));
    const raised = [...own.matchAll(/raise exception '([^']+)'/g)].map((m) => m[1])
      .filter((m) => !/^(village_batch|override authoriser|record not found|release not found|pack not found|attachment not found|active, under_investigation)/.test(m));
    for (const r of raised) expect(msgs.some((m) => m.startsWith(r.split('%')[0].replace(/''/g, '\'').slice(0, 25))), r).toBe(true);
  });
});
