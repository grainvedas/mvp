// Migration 51 (Veda, 15 Oct 2026: the operator-stages brief, release 4: set-up lists, A14, A15). The database's rules
// are tested in tests/45_setup_lists.sql; these hold the screens' mirrors of them to the migration's own text, the words
// of the ledger banner and the roster pool, and every new refusal in plain English and Hindi.
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  blocksOf, districtListed, districtsOf, elsewhereLine, gpsProblem, ledgerBanner, LIST_FIELDS, listProblems, listRow, MATERIALS, normPlace,
  parseGps, placeIsNew, poolGroups, profileProblem, profileVersions, shelfLifeMap, validGps, villagesOf, type LibraryParam, type MarketProfile, type Place,
} from '../src/lib/setup';
import { plainWords } from '../src/lib/plainErrors';
import { registerDictionary, translate } from '../src/lib/i18n';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { setupTabs } from '../src/pages/setup/SetupLists';

registerDictionary('en', en); registerDictionary('hi', hi);
const tEn = (k: string, v?: Record<string, string | number>, f?: string) => translate('en', k, v, f);
const tHi = (k: string, v?: Record<string, string | number>, f?: string) => translate('hi', k, v, f);
const migration = readFileSync(join(__dirname, '../../supabase/migrations/20261026000100_setup_lists.sql'), 'utf8');
const src = (f: string) => readFileSync(join(__dirname, '../src', f), 'utf8');

describe('the GPS point and the places (Part B: farmer additions)', () => {
  it('a point in India, as the database checks it (app.valid_gps)', () => {
    expect(migration).toContain('(p_lat between 6 and 37.5 and p_lng between 68 and 97.5)');
    expect(validGps(27.2, 83.0)).toBe(true);
    expect(validGps(6, 68)).toBe(true); expect(validGps(37.5, 97.5)).toBe(true);
    expect(validGps(5.99, 80)).toBe(false); expect(validGps(37.51, 80)).toBe(false); expect(validGps(28, 67.99)).toBe(false); expect(validGps(28, 97.51)).toBe(false);
    expect(validGps(51.5, -0.12)).toBe(false);                       // London
    expect(validGps(null, null)).toBe(true); expect(validGps(27, null)).toBe(false);
  });
  it('a point pasted from a map app fills both boxes; a half point or a point abroad is said before the save', () => {
    expect(parseGps('27.2105, 82.9531')).toEqual({ lat: 27.2105, lng: 82.9531 });
    expect(parseGps('27,21; 82,95')).toEqual({ lat: 27.21, lng: 82.95 });
    expect(parseGps('27.2')).toBeNull();
    expect(gpsProblem('', '')).toBeNull();
    expect(gpsProblem('27.2', '')).toBe('set.gps_pair');
    expect(gpsProblem('x', '83')).toBe('set.gps_number');
    expect(gpsProblem('51.5', '-0.1')).toBe('set.gps_india');
    expect(gpsProblem('27.2', '83.0')).toBeNull();
  });
  it('the same place written differently is the same place (app.norm_place)', () => {
    expect(migration.includes('app.norm_place') && /regexp_replace\(coalesce\(p, ''\), '\[\^A-Za-z\]', '', 'g'\)/.test(readFileSync(join(__dirname, '../../supabase/migrations/20261024000100_trust_numbers.sql'), 'utf8'))).toBe(true);
    expect(normPlace('Siddharth Nagar')).toBe(normPlace('siddharthnagar'));
    expect(normPlace(' -- ')).toBeNull();
  });
  it('the district from the state\'s list; a new block or village is added before the farmer is saved', () => {
    const P: Place[] = [
      { id: '1', state_id: 'UP', district: 'Siddharthnagar', block: null, village: null },
      { id: '2', state_id: 'UP', district: 'Basti', block: null, village: null },
      { id: '3', state_id: 'UP', district: 'Siddharthnagar', block: 'Bansi', village: null },
      { id: '4', state_id: 'UP', district: 'Siddharthnagar', block: 'Bansi', village: 'Rampur' },
    ];
    expect(districtsOf(P, 'UP')).toEqual(['Basti', 'Siddharthnagar']);
    expect(blocksOf(P, 'UP', 'siddharth nagar')).toEqual(['Bansi']);
    expect(villagesOf(P, 'UP', 'Siddharthnagar', 'BANSI')).toEqual(['Rampur']);
    expect(districtListed(P, 'UP', 'Siddharth-nagar')).toBe(true);
    expect(districtListed(P, 'UP', 'District 1')).toBe(false);
    expect(districtListed(P, 'AS', 'anything')).toBe(true);           // a state with no list accepts what is typed
    expect(placeIsNew(P, 'UP', 'Siddharthnagar', 'Bansi', 'Rampur')).toBe(false);
    expect(placeIsNew(P, 'UP', 'Siddharthnagar', 'Bansi', 'Naugarh')).toBe(true);
    expect(placeIsNew(P, 'UP', 'Siddharthnagar', 'Itwa', '')).toBe(true);
    expect(placeIsNew(P, 'UP', 'Siddharthnagar', '', '')).toBe(false);
    const form = src('pages/farmers/Farmers.tsx');
    // migration 54 (Veda, 16 Oct: villages "entered in database before hand … list only"): the farmer form picks the
    // village from the list and never adds a place itself (Set-up lists, Places, does)
    expect(form).not.toContain("rpc('add_place'");
    expect(form).toContain('villageListed(pl.places, stateId, f.district, f.block, f.village)');
    expect(form).toContain('farm_lat: f.farm_lat.trim()');          // a farmer with an ID: through app.change_farmer
    expect(form).toContain("rpc<{ status: 'missing' | 'not_enough' | 'near' | 'far'");
  });
});

describe('the lists (Part B)', () => {
  it('the shapes the tables check, before the save', () => {
    expect(migration).toContain("fssai_licence ~ '^[0-9]{14}$'");
    expect(migration).toContain("gstin ~ '^[0-9]{2}[A-Z0-9]{13}$'");
    expect(migration).toContain("check (country <> 'IN' or gstin is not null or fssai_licence is not null)");
    expect(migration).toContain("check (kind = 'in_house' or accreditation_no is not null)");
    expect(listProblems('buyers', { name: 'Gulf Foods', country: 'AE', address: 'Dubai, UAE' })).toEqual([]);
    expect(listProblems('buyers', { name: 'Delhi Mart', country: 'IN', address: 'Chandni Chowk' })).toEqual(['set.buyer_domestic']);
    expect(listProblems('buyers', { name: 'Delhi Mart', country: 'IN', address: 'Chandni Chowk', gstin: '07abcde1234f1z5' })).toEqual([]);   // typed in small letters: sent in capitals
    expect(listProblems('buyers', { name: 'X', country: 'IN', address: 'Delhi 6', gstin: '7ABC' })).toEqual(expect.arrayContaining(['set.short_name', 'set.bad_gstin']));
    expect(listProblems('packing_units', { name: 'Unit 1', place: 'Basti', ownership: 'own', fssai_licence: '1234' })).toEqual(['set.bad_fssai']);
    expect(listProblems('labs', { name: 'Agri Lab', kind: 'external', location: 'Lucknow' })).toEqual(['set.lab_accreditation']);
    expect(listProblems('labs', { name: 'Own lab', kind: 'in_house', location: 'Basti' })).toEqual([]);
    expect(listProblems('collection_points', { name: 'Bansi centre', kind: 'centre', district: 'Siddharthnagar', lat: '51.5', lng: '0' })).toEqual(['set.gps_india']);
    expect(listProblems('pack_skus', { size: '0', unit: 'kg', material: 'jute', market: 'domestic', label_type: 'sticker' })).toEqual(['set.bad_size']);
  });
  it('the row the table takes: blanks are nulls, the GPS in its two columns, codes in capitals', () => {
    expect(listRow('collection_points', { name: ' Bansi ', kind: 'centre', district: 'Siddharthnagar', block: '', lat: '27.18', lng: '82.93' }))
      .toEqual({ name: 'Bansi', kind: 'centre', district: 'Siddharthnagar', block: null, village: null, lat: 27.18, lng: 82.93 });
    expect(listRow('buyers', { name: 'Gulf', country: 'ae', gstin: '', address: 'Dubai', importer_id: '' })).toMatchObject({ country: 'AE', gstin: null });
    expect(listRow('pack_skus', { size: '0,5', unit: 'kg', material: 'pouch', market: 'any', label_type: 'tag' })).toMatchObject({ size: 0.5 });
  });
  it('every field, option and material has its words in both languages', () => {
    for (const k of Object.keys(LIST_FIELDS) as (keyof typeof LIST_FIELDS)[]) {
      for (const f of LIST_FIELDS[k]) {
        expect(en[`set.f_${f.key}`], f.key).toBeTruthy(); expect(hi[`set.f_${f.key}`], f.key).toBeTruthy();
        if (f.required && f.type !== 'gps') { expect(en[`set.need_${f.key}`], f.key).toBeTruthy(); expect(hi[`set.need_${f.key}`], f.key).toBeTruthy(); }
        for (const o of f.options ?? []) { const key = f.key === 'material' ? `mat.${o}` : `set.o_${o}`; expect(en[key], key).toBeTruthy(); expect(hi[key], key).toBeTruthy(); }
      }
      expect(en[`set.add_${k}`]).toBeTruthy(); expect(hi[`set.add_${k}`]).toBeTruthy();
    }
    // the migration's own lists of options are the screens'
    expect(migration).toContain("kind in ('centre', 'field_point', 'store')");
    expect(migration).toContain(`material in (${MATERIALS.map((m) => `'${m}'`).join(', ')})`);
  });
  it('who sees which part: the Client Manager his client\'s lists, the State Manager labs and profiles, everyone the library', () => {
    expect(setupTabs({ cm: true, sm: false, admin: false })).toEqual(['lists', 'places', 'library']);
    expect(setupTabs({ cm: false, sm: true, admin: false })).toEqual(['lists', 'places', 'labs', 'profiles', 'library']);
    expect(setupTabs({ cm: false, sm: false, admin: false })).toEqual(['library']);
  });
});

describe('the crop: shelf life per material, market profiles', () => {
  it('shelf life per material: whole days 1 to 3650, empty boxes left out (app.shelf_life_ok)', () => {
    expect(migration).toContain('between 1 and 3650');
    expect(shelfLifeMap({ jute: '270', pouch: '', vacuum: '365' })).toEqual({ map: { jute: 270, vacuum: 365 }, bad: [] });
    expect(shelfLifeMap({ jute: '0', carton: '4000' }).bad).toEqual(['jute', 'carton']);
  });
  const lib: LibraryParam[] = [
    { param: 'aflatoxin_b1', name: 'Aflatoxin B1', unit: 'µg/kg', type: 'number', method: null, done_by: 'lab', grp: 'safety', sort_order: 1 },
    { param: 'grade', name: 'Grade', unit: null, type: 'grade', method: null, done_by: 'in_house', grp: 'basic', sort_order: 2 },
    { param: 'gmo_free', name: 'GMO free', unit: null, type: 'yesno', method: null, done_by: 'lab', grp: 'authenticity', sort_order: 3 },
  ];
  it('a profile\'s parameters are judged as the server judges them (app.profile_params_problems)', () => {
    expect(profileProblem([{ param: 'aflatoxin_b1', operator: '<=', limit: 2 }, { param: 'grade', pass: ['A'] }, { param: 'gmo_free', pass: true }], lib)).toBeNull();
    expect(profileProblem([{ param: 'colour_x' }], lib)).toEqual({ key: 'set.prof_not_in_library', vars: { param: 'colour_x' } });
    expect(profileProblem([{ param: 'aflatoxin_b1', operator: '<=' }], lib)?.key).toBe('set.prof_limit');
    expect(profileProblem([{ param: 'grade', pass: [] }], lib)?.key).toBe('set.prof_grades');
    expect(profileProblem([{ param: 'gmo_free' }], lib)?.key).toBe('set.prof_yesno');
    expect(profileProblem([{ param: 'grade', pass: ['A'] }, { param: 'grade', pass: ['B'] }], lib)?.key).toBe('set.prof_twice');
    for (const m of ['is not in the parameter library', 'is listed twice', 'needs an operator and a number limit', 'needs the grades that pass', 'needs the answer that passes'])
      expect(migration, m).toContain(m);
  });
  it('the version in use, the draft, the older ones', () => {
    const p = (version: number, status: MarketProfile['status']) => ({ id: `v${version}`, crop_id: 'c', code: 'eu', name: 'EU', version, status, params: [], export_docs: [], source_file_id: null, source_note: null, created_at: '', activated_at: null });
    const v = profileVersions([p(1, 'retired'), p(3, 'draft'), p(2, 'active')], 'c', 'eu');
    expect(v.versions.map((x) => x.version)).toEqual([3, 2, 1]);
    expect(v.active?.version).toBe(2); expect(v.draft?.version).toBe(3);
  });
});

describe('A14 the ledger banner; A15 the roster pool', () => {
  const now = Date.parse('2026-10-16T10:00:00Z');
  it('"Last full check …: 18 blocks intact · 34 blocks added since"', () => {
    const s = { checked_at: '2026-10-15T20:30:00Z', ok: true, blocks: 18, source: 'nightly', blocks_now: 52, added_since: 34 };
    expect(ledgerBanner(s, now)).toEqual({ key: 'led.since', tone: 'muted' });
    expect(tEn('led.since', { at: '16 Oct, 2:00 am', n: 18, added: 34 })).toBe('Last full ledger check 16 Oct, 2:00 am: 18 blocks intact · 34 blocks added since.');
    expect(ledgerBanner({ ...s, added_since: 0 }, now).key).toBe('led.none_since');
    expect(ledgerBanner({ ...s, ok: false }, now)).toEqual({ key: 'home.ledger_bad', tone: 'error' });
    expect(ledgerBanner({ ...s, checked_at: '2026-10-13T00:00:00Z' }, now).key).toBe('home.ledger_stale');
    expect(ledgerBanner({ ...s, checked_at: null }, now).key).toBe('led.never');
    expect(src('pages/dashboard/parts.tsx')).toContain("rpc<LedgerStatus>('ledger_status')");
  });
  it('free people first; "mt1 · Milling on KH26 · gkp (active)"; the soft note', () => {
    const e = { scope_id: 's', label: 'KH26 · gkp', status: 'active', client: 'Prasaadam', stages: ['milling'] };
    expect(elsewhereLine(e, tEn)).toBe('Milling on KH26 · gkp (active)');
    expect(elsewhereLine(e, tHi)).not.toBe(elsewhereLine(e, tEn));
    const g = poolGroups([{ id: '1', name: 'a', elsewhere: [e] }, { id: '2', name: 'b' }, { id: '3', name: 'c', elsewhere: [] }]);
    expect(g.free.map((p) => p.id)).toEqual(['2', '3']); expect(g.busy.map((p) => p.id)).toEqual(['1']);
    expect(tEn('pool.soft_note', { name: 'mt1', work: elsewhereLine(e, tEn) })).toBe('mt1 already holds Milling on KH26 · gkp (active); he will have two work queues.');
    const people = src('pages/people/People.tsx');
    expect(people).toContain("t('pool.busy')"); expect(people).toContain('pool-soft-note');
    expect(migration).toContain("'elsewhere', app.work_elsewhere(u.id, sc.id)");
  });
});

describe('every new word in both languages; every new refusal in plain words', () => {
  it('each key the release adds has its Hindi, and it is not the English', () => {
    const added = Object.keys(en).filter((k) => /^(set|fl|led|pool|mat)\./.test(k) || ['menu.setup', 'act.farmers_gps', 'sh.multi_scope', 'sh.multi_scope_n', 'sh.multi_scope_none'].includes(k));
    expect(added.length).toBeGreaterThan(150);
    for (const k of added) { expect(hi[k], k).toBeTruthy(); if (!/^(GPS|GSTIN|IN|kg|g)$/.test(en[k])) expect(hi[k], k).not.toBe(en[k]); }
  });
  const msgs = [
    'places are added by the State Manager, the Client Manager or Procurement of this state',
    'the district Nowhere is not on the list of this state (the State Manager adds districts)',
    'name the block',
    'the State Manager of the crop\'s state keeps its documents',
    'the file is not filed under this crop',
    'market profile not found',
    'the State Manager of the crop\'s state keeps its market profiles',
    'market profile: colour_x is not in the parameter library',
    'market profile: Grade is listed twice',
    'market profile: Aflatoxin B1 needs an operator and a number limit',
    'market profile: Grade needs the grades that pass',
    'market profile: GMO free needs the answer that passes',
    'market profile: the parameters are a list',
    'market profile: list the parameters it tests',
    'market profile: attach the document the limits come from',
    'there is a draft of this profile already: change that one',
    'only a draft is activated (this one is retired)',
    'a crop that is not a GI crop (no GI registration number) has no GI area',
    'the reference photo is a photo filed under this crop',
    'add the farm\'s GPS location before the farmer is verified',
    'the district Sidharth Ngr is not on the list of the farmer\'s state: pick it from the list',
    'no access to this state',
    'new row for relation "farmers" violates check constraint "farmers_gps_shape"',
    'new row for relation "collection_points" violates check constraint "collection_points_check"',
    'new row for relation "buyers" violates check constraint "buyers_check"',
    'new row for relation "labs" violates check constraint "labs_check"',
    'new row for relation "packing_units" violates check constraint "packing_units_fssai_licence_check"',
    'new row for relation "crops" violates check constraint "crops_shelf_life_by_material_shape"',
    'duplicate key value violates unique constraint "collection_points_name"',
    'duplicate key value violates unique constraint "pack_skus_unique"',
  ];
  it.each(msgs)('%s', (m) => {
    const e = plainWords(m, tEn), h = plainWords(m, tHi);
    expect(e).toBeTruthy(); expect(h).toBeTruthy(); expect(h).not.toBe(e);
    expect(e).not.toMatch(/\{[a-z]+\}/); expect(h).not.toMatch(/\{[a-z]+\}/);
  });
  it('every message the migration raises for people is one of them', () => {
    const own = migration.slice(0, migration.indexOf('Patches of the current definitions'));
    const raised = [...own.matchAll(/raise exception '([^']+(?:''[^']*)*)'/g)].map((m) => m[1].replace(/''/g, '\''))
      .filter((m) => !/^(sign in first|farmer not found)/.test(m));
    expect(raised.length).toBeGreaterThanOrEqual(18);
    for (const r of raised) expect(msgs.some((m) => m.startsWith(r.split('%')[0].slice(0, 25))), r).toBe(true);
  });
});
