// Migration 47 (Veda, 14 Oct 2026): what Procurement proposes for a verified farmer. The rules are the database's
// (tests/41_farmer_proposals.sql); this is the form's own pure part.
import { describe, expect, it } from 'vitest';
import { changedFields, PROPOSAL_FIELDS } from '../src/pages/farmers/FarmerPractice';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';

describe('farmer corrections proposed', () => {
  it('only what differs is proposed; an emptied box is no change, never an erase', () => {
    const was = { name: 'Ram Achal', village: 'Bansi', land_area_acres: 2, gi_land_acres: null, notes: '' };
    expect(changedFields({ name: 'Ram Achal ', village: 'Bansi Kalan', land_area_acres: '2', gi_land_acres: '0.5', notes: '' }, was))
      .toEqual({ village: 'Bansi Kalan', gi_land_acres: '0.5' });
    expect(changedFields({ name: '', village: '' }, was)).toEqual({});
  });
  it('the fields are the ones the database accepts, each with its words in English and Hindi', () => {
    expect([...PROPOSAL_FIELDS]).toEqual(['name', 'guardian_name', 'village', 'district', 'phone', 'land_area_acres', 'gi_land_acres', 'notes']);
    const keys = Object.keys(en).filter((k) => k.startsWith('fp.'));
    expect(keys.length).toBeGreaterThanOrEqual(29);
    expect(keys.filter((k) => !(k in hi))).toEqual([]);
  });
});
