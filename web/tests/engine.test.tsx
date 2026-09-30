import { describe, it, expect } from 'vitest';
import { render } from '@testing-library/react';
import defs from './fixtures/stage_definitions.json';
import { Widget, SUPPORTED, buildPayload, missingRequired } from '../src/engine/widgets';
import { assembleChain } from '../src/pages/scopes/Scopes';
import { rowsFromSheet } from '../src/pages/farmers/FarmerImport';
import { toAppError } from '../src/lib/errors';
import type { FieldDef, StageDefinition } from '../src/lib/types';

const stages = defs as unknown as StageDefinition[];
const PHASE2_TYPES = new Set(['footprint[]', 'breakdown', 'packets[]']);

describe('generic engine', () => {
  it('has all 16 stage definitions', () => expect(stages).toHaveLength(16));

  it.each(stages.map((s) => [s.stage_type, s] as const))('renders every field of %s without stage-specific code', (_t, s) => {
    for (const f of s.form_schema) {
      const { container, unmount } = render(<Widget id={`x-${f.key}`} field={f} value={null} onChange={() => {}} qualityParams={[]} clientId="c" />);
      expect(container.firstChild).not.toBeNull();
      unmount();
    }
  });

  it('every field type is either supported now or explicitly a Phase 2 widget', () => {
    const types = new Set(stages.flatMap((s) => s.form_schema.map((f) => f.type)));
    for (const t of types) expect(SUPPORTED.has(t) || PHASE2_TYPES.has(t), `unknown field type ${t}`).toBe(true);
  });

  it('procurement: farmer goes to the column, the rest to the payload, numbers parsed', () => {
    const proc = stages.find((s) => s.stage_type === 'procurement')!;
    const { payload, columns } = buildPayload(proc.form_schema, {
      farmer_id: 'f1', gross_kg: '150', bags: '1', tare_kg_per_bag: '2.5', moisture_pct: ['11.9', '11.8', '12'] });
    expect(columns).toEqual({ farmer_id: 'f1' });
    expect(payload).toEqual({ gross_kg: 150, bags: 1, tare_kg_per_bag: 2.5, moisture_pct: [11.9, 11.8, 12] });
  });

  it('QC readings become numbers; empty readings dropped', () => {
    const qc = stages.find((s) => s.stage_type === 'qc')!;
    const { payload } = buildPayload(qc.form_schema, { qty_kg: '147.5', sample_qty_kg: '0.5', readings: { moisture_pct: '11.9', broken_pct: '' } });
    expect(payload).toEqual({ qty_kg: 147.5, sample_qty_kg: 0.5, readings: { moisture_pct: 11.9 } });
  });

  it('reports missing required fields by label', () => {
    const f: FieldDef[] = [{ key: 'a', label: 'A', type: 'number', required: true }, { key: 'm', label: 'Moisture', type: 'number[3]', required: true }];
    expect(missingRequired(f, { a: '1', m: ['1', '', '2'] })).toEqual(['Moisture']);
  });
});

describe('scope chain builder', () => {
  it('assembles entry, processing around QC, exits, QR', () => {
    expect(assembleChain({ entry: 'procurement', villageBatch: false, before: ['sorting', 'grading'], after: [], commercial: false, shipment: false }))
      .toEqual(['procurement', 'sorting', 'grading', 'qc', 'qr_activation']);
    expect(assembleChain({ entry: 'procurement', villageBatch: true, before: [], after: ['milling'], commercial: true, shipment: true }))
      .toEqual(['procurement', 'village_batch', 'qc', 'milling', 'commercial', 'shipment', 'qr_activation']);
    expect(assembleChain({ entry: 'lot_inward', villageBatch: true, before: [], after: [], commercial: false, shipment: false }))
      .toEqual(['lot_inward', 'qc', 'qr_activation']);
  });
});

describe('Excel import parsing', () => {
  it('normalises headers, numbers rows as in the sheet, skips blank rows', () => {
    const rows = rowsFromSheet([['Name', 'Guardian Name', 'Phone', 'Land (acres)'], ['A', 'G', 9876500001, 1.5], [null, '', null, null], ['B', 'H', '9876500002', 2]]);
    expect(rows).toEqual([
      { row: 2, name: 'A', guardian_name: 'G', phone: 9876500001, land_acres: 1.5 },
      { row: 4, name: 'B', guardian_name: 'H', phone: '9876500002', land_acres: 2 },
    ]);
  });
});

describe('error display', () => {
  it('turns database refusals into plain words without internal ids', () => {
    const e = toAppError({ code: '42501', message: 'user 00000000-0000-4000-8000-000000000306 may not create at stage procurement in this scope' });
    expect(e.kind).toBe('permission');
    expect(e.message).not.toMatch(/[0-9a-f]{8}-/);
    expect(toAppError({ code: '42501', message: 'new row violates row-level security policy' }).message).toBe('Not allowed for your role or stage.');
    expect(toAppError({ code: '23514', message: 'milling: input (194) must equal rice + bran + loss (184)' }).kind).toBe('rule');
    expect(toAppError(new TypeError('Failed to fetch')).kind).toBe('network');
  });
});

describe('Phase 2 widgets', () => {
  it('packets and reject breakdown become typed rows; empty rows dropped', () => {
    const f: FieldDef[] = [{ key: 'packets', label: 'Packets', type: 'packets[]', required: true },
      { key: 'reject_reasons', label: 'Reject reasons', type: 'breakdown' }];
    const { payload } = buildPayload(f, {
      packets: [{ units: '100', size_kg: '1' }, { units: '58', size_kg: '0.5' }, { units: '', size_kg: '' }] as unknown as string[],
      reject_reasons: [{ reason: 'discoloured', kg: '6' }] as unknown as string[] });
    expect(payload).toEqual({ packets: [{ units: 100, size_kg: 1 }, { units: 58, size_kg: 0.5 }], reject_reasons: [{ reason: 'discoloured', kg: 6 }] });
  });
  it('a lot picker that sets prev puts the first lot in prev_footprint_id', () => {
    const vb = stages.find((s) => s.stage_type === 'village_batch')!;
    const { payload, columns } = buildPayload(vb.form_schema, { source_footprint_ids: ['a', 'b', 'c'], village: 'Bansi' });
    expect(payload).toEqual({ source_footprint_ids: ['a', 'b', 'c'], village: 'Bansi' });
    expect(columns).toEqual({ prev_footprint_id: 'a' });
  });
  it('grading split is a column, not payload', () => {
    const g = stages.find((s) => s.stage_type === 'grading')!;
    const { payload, columns } = buildPayload(g.form_schema, { input_kg: '170', grade_a_kg: '100', grade_b_kg: '50', grade_c_kg: '15',
      reject_kg: '3', loss_kg: '2', split_into_grades: true });
    expect(columns).toEqual({ split_into_grades: true });
    expect(payload).not.toHaveProperty('split_into_grades');
  });
  it('packets required: a row needs units and size', () => {
    expect(missingRequired([{ key: 'p', label: 'Packets', type: 'packets[]', required: true }], { p: [{ units: '5', size_kg: '' }] as unknown as string[] })).toEqual(['Packets']);
  });
});
