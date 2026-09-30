// Phase 3 unit checks: Hindi completeness (PRD release criterion "Hindi strings complete for F4–F8"), the offline
// maths mirror, CSV export safety.
import { describe, expect, it } from 'vitest';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { translate } from '../src/lib/i18n';
import { localiseForm } from '../src/engine/localise';
import { offlinePreview } from '../src/engine/offlinePreview';
import { csvCell, toCsv } from '../src/lib/csv';
import type { StageDefinition, StageForm } from '../src/lib/types';
import defs from './fixtures/stage_definitions.json';

const stages = defs as unknown as StageDefinition[];
const vars = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(',');

describe('Hindi dictionary', () => {
  it('has every English key, with the same {placeholders}', () => {
    const missing = Object.keys(en).filter((k) => !hi[k]?.trim());
    expect(missing).toEqual([]);
    const wrongVars = Object.keys(en).filter((k) => vars(en[k]) !== vars(hi[k]));
    expect(wrongVars).toEqual([]);
  });

  it('translates every stage name, form field, option and handoff check of all 16 stages', () => {
    const t = (key: string, v?: Record<string, string | number>, f?: string) => translate('hi', key, v, f);
    const gaps: string[] = [];
    for (const s of stages) {
      const form = { scope: { tolerances: {} }, stage: s, prev_stage: null, next_stage: null, quality_params: [] } as unknown as StageForm;
      const l = localiseForm(form, t);
      if (l.stage.label === s.label) gaps.push(`stage ${s.stage_type}`);
      s.form_schema.forEach((f, i) => { if (l.stage.form_schema[i].label === f.label) gaps.push(`field ${s.stage_type}.${f.key}`); });
      s.handoff_checks.forEach((c, i) => { if (l.stage.handoff_checks[i] === c) gaps.push(`check "${c}"`); });
      s.form_schema.flatMap((f) => f.options ?? []).forEach((o) => { if (!hi[`opt.${o}`]) gaps.push(`option ${o}`); });
    }
    expect(gaps).toEqual([]);
  });

  it('keeps the stage-specific meaning where one key means two things', () => {
    const t = (key: string, v?: Record<string, string | number>, f?: string) => translate('hi', key, v, f);
    const milling = localiseForm({ scope: {}, stage: stages.find((s) => s.stage_type === 'milling')!, prev_stage: null, next_stage: null, quality_params: [] } as unknown as StageForm, t);
    const sorting = localiseForm({ scope: {}, stage: stages.find((s) => s.stage_type === 'sorting')!, prev_stage: null, next_stage: null, quality_params: [] } as unknown as StageForm, t);
    expect(milling.stage.form_schema.find((f) => f.key === 'input_kg')!.label).toBe('धान आया');
    expect(sorting.stage.form_schema.find((f) => f.key === 'input_kg')!.label).toBe('आया माल');
  });

  it('leaves English exactly as the database sends it', () => {
    const t = (key: string, v?: Record<string, string | number>, f?: string) => translate('en', key, v, f);
    const s = stages.find((x) => x.stage_type === 'procurement')!;
    const l = localiseForm({ scope: {}, stage: s, prev_stage: null, next_stage: null, quality_params: [] } as unknown as StageForm, t);
    expect(l.stage.label).toBe(s.label);
    expect(l.stage.form_schema.map((f) => f.label)).toEqual(s.form_schema.map((f) => f.label));
  });
});

describe('offline maths mirror (app.reconcile, procurement and lot inward)', () => {
  it('procurement: net = gross − bags × tare; moisture avg/min/max', () => {
    const p = offlinePreview('procurement', { gross_kg: 126, bags: 3, tare_kg_per_bag: 2, moisture_pct: [12.1, 11.9, 12.4] }, { farmer_id: 'f' });
    expect(p).toMatchObject({ ok: true, qty_in: 120, qty_out: 120, computed: { net_kg: 120, moisture_avg: 12.13, moisture_min: 11.9, moisture_max: 12.4 } });
  });
  it('procurement: refuses what the server refuses', () => {
    expect(offlinePreview('procurement', { gross_kg: 4, bags: 2, tare_kg_per_bag: 2, moisture_pct: [12, 12, 12] }, { farmer_id: 'f' }).error).toMatch(/net weight must be positive/);
    expect(offlinePreview('procurement', { gross_kg: 100, bags: 1, tare_kg_per_bag: 1, moisture_pct: [12, 12] }, { farmer_id: 'f' }).error).toMatch(/3 readings/);
    expect(offlinePreview('procurement', { gross_kg: 100, bags: 1, tare_kg_per_bag: 1, moisture_pct: [12, 12, 12] }, {}).error).toMatch(/farmer_id/);
  });
  it('lot inward: weighed quantity goes forward; variance warning past tolerance', () => {
    const p = offlinePreview('lot_inward', { declared_kg: 500, weighed_kg: 480, source_type: 'fpo', source_name: 'X', moisture_pct: 12.5 }, {}, { lot_inward_variance_pct: 2 });
    expect(p).toMatchObject({ ok: true, qty_out: 480, computed: { variance_kg: 20, variance_pct: 4 }, warnings: ['declared vs weighed variance exceeds tolerance'] });
  });
  it('any other stage offline is provisional: the server decides at sync', () => {
    expect(offlinePreview('milling', { input_kg: 100 }, {})).toMatchObject({ ok: true, provisional: true });
  });
});

describe('CSV export', () => {
  it('quotes commas, quotes and newlines', () => {
    expect(csvCell('a,b')).toBe('"a,b"');
    expect(csvCell('say "hi"')).toBe('"say ""hi"""');
    expect(toCsv(['x'], [['line1\nline2']])).toBe('x\r\n"line1\nline2"\r\n');
  });
  it('defuses spreadsheet formulas typed into free-text fields', () => {
    expect(csvCell('=HYPERLINK("http://x")')).toBe(`"'=HYPERLINK(""http://x"")"`);
    expect(csvCell('+91 98765')).toBe("'+91 98765");
    expect(csvCell(-5)).toBe('-5');
  });
});
