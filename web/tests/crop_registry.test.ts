// Migration 42 (Veda, 13 Oct 2026, State Manager brief part C): the crop registry's pure rules as the screens follow
// them. What the database refuses is tested in tests/36_crop_registry.sql; these hold the mirrors (ready, the wizard's
// chain, the farmer's open practices, typed readings) and the words in both languages.
import { describe, expect, it } from 'vitest';
import {
  assembleChain, cropMissing, gapMissing, harvestText, limitSummary, offeredForScope, readingValue, splitChain, type CropFull,
} from '../src/lib/crops';
import { stateSetup, type StateHomeData } from '../src/pages/state/StateHome';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import type { StageType } from '../src/lib/types';

const PROC = new Set(['milling', 'sorting', 'grading', 'drying', 'popping', 'cleaning', 'blanching', 'cold_storage', 'packing']);
const isProc = (s: StageType) => PROC.has(s);
const crop = (over: Partial<CropFull> = {}): CropFull => ({ id: 'c', name: 'Kalanamak rice', code: 'KNM', gi_tag: null, origin: null, primary_unit: 'kg',
  quality_params: [{ param: 'moisture_pct', label: 'Moisture', operator: '<=', domestic_limit: 13, export_limit: 12 }], allowed_stages: ['sorting'],
  yield_per_acre_kg: 1000, recommended_chain: ['procurement', 'qc', 'qr_activation'], ...over });

describe('the crop registry (migration 42)', () => {
  it('ready: a unit, a yield per acre, a limit and a recommended chain (as app.crop_missing)', () => {
    expect(cropMissing(crop())).toEqual([]);
    expect(cropMissing(crop({ yield_per_acre_kg: null, recommended_chain: [] }))).toEqual(['yield', 'chain']);
    expect(cropMissing(crop({ quality_params: [], primary_unit: ' ' }))).toEqual(['unit', 'limits']);
  });
  it('the wizard offers ready crops that are not retired; an older server (no readiness) everything', () => {
    expect(offeredForScope(crop())).toBe(true);
    expect(offeredForScope(crop({ yield_per_acre_kg: null }))).toBe(false);
    expect(offeredForScope(crop({ retired_at: '2026-10-13' }))).toBe(false);
    const old = crop(); delete old.recommended_chain; old.yield_per_acre_kg = undefined;
    expect(offeredForScope(old)).toBe(true);
  });
  it('a recommended chain splits into the wizard\'s choices and builds back the same chain', () => {
    for (const c of [
      ['procurement', 'qc', 'qr_activation'], ['procurement', 'village_batch', 'sorting', 'grading', 'qc', 'packing', 'commercial', 'shipment', 'qr_activation'],
      ['lot_inward', 'qc', 'milling', 'qr_activation'],
    ] as StageType[][]) expect(assembleChain(splitChain(c, isProc))).toEqual(c);
  });
  it('the farmer\'s open practices: required and optional apart; an answer of "no" counts as answered', () => {
    const items = [{ key: 'seed', label: 'Seed source', type: 'choice' as const, options: ['a', 'b'], required: true },
      { key: 'sown', label: 'Sowing date', type: 'date' as const }, { key: 'burnt', label: 'Stubble burnt', type: 'yesno' as const, required: true }];
    expect(gapMissing(items, {})).toEqual({ required: ['Seed source', 'Stubble burnt'], optional: ['Sowing date'] });
    expect(gapMissing(items, { seed: 'a', burnt: false, sown: '' })).toEqual({ required: [], optional: ['Sowing date'] });
  });
  it('typed readings: numbers stay numbers, yes/no become true/false, a grade stays its text', () => {
    expect(readingValue('12.5')).toBe(12.5);
    expect(readingValue('12.')).toBe(12);
    expect(readingValue('yes')).toBe(true);
    expect(readingValue('No')).toBe(false);
    expect(readingValue('A')).toBe('A');
    expect(readingValue('  ')).toBeUndefined();
  });
  it('a limit in words, by its type; the harvest window by month', () => {
    expect(limitSummary({ param: 'm', label: 'M', operator: '<=', domestic_limit: 13, export_limit: 12, unit: '%' }, 'yes', 'no')).toBe('≤ 13 / 12 %');
    expect(limitSummary({ param: 'a', label: 'A', type: 'grade', operator: '<=', domestic_limit: 0, export_limit: 0, options: ['A', 'B'], domestic_pass: ['A', 'B'], export_pass: ['A'] }, 'yes', 'no')).toBe('A, B / A');
    expect(limitSummary({ param: 'i', label: 'I', type: 'yesno', operator: '<=', domestic_limit: 0, export_limit: 0, domestic_pass: false, export_pass: false }, 'yes', 'no')).toBe('no / no');
    expect(harvestText({ harvest_from: 10, harvest_to: 12 }, 'en')).toBe('Oct–Dec');
    expect(harvestText({ harvest_from: null, harvest_to: null }, 'en')).toBe('');
  });
  it('his overview ticks "crops" only once a crop of his state is ready', () => {
    const base = { clients: { total: 1, active: 0, without_manager: 1, list: [] }, scopes: { active: 0, setup: 0, closed: 0, qr_issued: 0, list: [] },
      farmers: { total: 0, active: 0 }, attention: { no_manager: 1, no_manager_list: [], farmers_waiting: 0, farmers_list: [], unstaffed: 0, unstaffed_list: [], open_flags: 0, flags_list: [] } } as unknown as StateHomeData;
    expect(stateSetup({ ...base, crops: { total: 1, state_not_set: 0, ready: 0, list: [] } })[0].done).toBe(false);
    expect(stateSetup({ ...base, crops: { total: 1, state_not_set: 0, ready: 1, list: [] } })[0].done).toBe(true);
    expect(stateSetup({ ...base, crops: { total: 1, state_not_set: 0, list: [] } })[0].done).toBe(true);      // a server before migration 42
  });
  it('every new word in English and Hindi', () => {
    const fresh = Object.keys(en).filter((k) => /^(crops\.|gap\.|audit\.(crop_|farmer_gap|gap_)|wizard\.crop_not_ready|sh\.crops_ready)/.test(k));
    expect(fresh.length).toBeGreaterThan(80);
    for (const k of fresh) expect(hi[k], k).toBeTruthy();
    for (const m of ['unit', 'yield', 'limits', 'chain']) expect(en[`crops.missing_${m}`]).toBeTruthy();
    for (const g of ['yesno', 'date', 'number', 'text', 'choice']) expect(hi[`crops.g_${g}`]).toBeTruthy();
    for (const a of ['retire', 'remove', 'state']) expect(hi[`crops.${a}_explain`]).toBeTruthy();
  });
});
