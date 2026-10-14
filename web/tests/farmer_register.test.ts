// Migration 43 (Veda, 13 Oct 2026, State Manager brief part D): the farmer register's pure rules as the screens follow them.
// What the database refuses is tested in tests/37_farmer_register.sql; these hold the mirrors and the words in both languages.
import { describe, expect, it } from 'vitest';
import { giLandProblem, maskedPhone, needsGiLand, NO_FILTER, PAGE, REGISTER_FLAGS, registerParams, yieldLevel, yieldShare } from '../src/lib/farmers';
import { TEMPLATE_COLUMNS } from '../src/pages/farmers/FarmerImport';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';

describe('the farmer register (migration 43)', () => {
  it('asks one page, leaving out the filters not set', () => {
    expect(registerParams('S', NO_FILTER, 0)).toEqual({ state: 'S', limit: PAGE, offset: 0 });
    expect(registerParams('S', { ...NO_FILTER, flag: 'duplicate', q: '  Ram ', district: 'Basti' }, 2))
      .toEqual({ state: 'S', limit: PAGE, offset: 2 * PAGE, flag: 'duplicate', q: 'Ram', district: 'Basti' });
    expect(registerParams('S', NO_FILTER, -1).offset).toBe(0);
  });
  it('shows a phone only as its last four digits', () => {
    expect(maskedPhone('0002')).toBe('••••••0002');
    expect(maskedPhone('9870000002')).toBe('••••••0002');
    expect(maskedPhone(null)).toBe('—');
    expect(maskedPhone('')).toBe('—');
  });
  it('the yield: sold against GI land × yield per acre; above 100 % a warning only (migration 44)', () => {
    expect(yieldShare(294, 100)).toBe(294);
    expect(yieldShare(98, 90)).toBe(109);
    expect(yieldShare(50, 0)).toBeNull();                 // nothing expected: no GI land, or no yield on the crop
    expect(yieldShare(null, 100)).toBeNull();
    expect(yieldShare('120', '100')).toBe(120);
    expect([null, 80, 100, 101, 120, 121].map(yieldLevel)).toEqual(['none', 'within', 'within', 'above', 'above', 'above']);
  });
  it('the GI land: empty on a draft; else more than 0 and not more than the land', () => {
    expect(giLandProblem('', '2')).toBeNull();
    expect(giLandProblem('1,5', '2')).toBeNull();
    expect(giLandProblem('2', '2')).toBeNull();
    expect(giLandProblem('0', '2')).toBe('gi_positive');
    expect(giLandProblem('abc', '2')).toBe('gi_positive');
    expect(giLandProblem('2.5', '2')).toBe('gi_over_land');
    expect(needsGiLand({ gi_land_acres: null })).toBe(true);
    expect(needsGiLand({})).toBe(true);
    expect(needsGiLand({ gi_land_acres: 1.5 })).toBe(false);
  });
  it('the import template has the GI land column', () => {
    expect(TEMPLATE_COLUMNS).toContain('gi_land_acres');
    expect(TEMPLATE_COLUMNS.indexOf('gi_land_acres')).toBe(TEMPLATE_COLUMNS.indexOf('land_area_acres') + 1);
  });
  it('every word in English and Hindi', () => {
    const keys = ['menu.farmer_register', 'reg.title', 'reg.sub', 'reg.note', 'reg.not_same', 'reg.why_distinct', 'reg.deactivate_this',
      'reg.deactivate_coded', 'reg.deactivate_uncoded', 'reg.phone', 'reg.sold', 'reg.no_gi', 'reg.page', 'farmer.gi_land', 'farmer.gi_land_hint',
      'farmer.gi_positive', 'farmer.gi_over_land', 'farmers.needs_gi', 'sh.act_duplicates', 'sh.act_over_yield', 'sh.act_no_gi',
      'audit.farmer_duplicate_cleared', ...REGISTER_FLAGS.map((f) => `reg.flag_${f}`),
      ...['active', 'under_review', 'draft', 'inactive'].map((s) => `reg.st_${s}`)];
    for (const k of keys) { expect(en[k], k).toBeTruthy(); expect(hi[k], k).toBeTruthy(); expect(hi[k], k).not.toBe(en[k]); }
    for (const k of Object.keys(en).filter((x) => x.startsWith('reg.'))) {
      const vars = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
      expect(vars(hi[k]), k).toEqual(vars(en[k]));
    }
  });
});
