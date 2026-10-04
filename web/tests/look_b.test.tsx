// Decision G8 = B (4 October 2026): the prototype's frame, first screens and form sections. The arithmetic and the
// tables behind those screens, tested without a browser. The screens themselves: e2e/phase6.spec.ts.
import { describe, expect, it, vi } from 'vitest';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import type { StageDefinition, StageType } from '../src/lib/types';
import defs from './fixtures/stage_definitions.json';

vi.mock('../src/lib/supabase', () => ({ supabase: { from: () => ({}), auth: {}, storage: {} }, appDb: { rpc: vi.fn() }, SUPABASE_URL: '', SUPABASE_ANON_KEY: '',
  configured: true, accessToken: vi.fn() }));
vi.mock('../src/offline/idb', () => ({ available: () => false, idbGet: vi.fn(), idbPut: vi.fn(), idbDel: vi.fn(), idbAll: vi.fn(async () => []), idbClear: vi.fn() }));

import { scopeFigures, unassigned, type PipeRow } from '../src/pages/Home';
import { groupSections, FULL_WIDTH } from '../src/engine/widgets';
import { SECTION_ICON, STAGE_ICON } from '../src/engine/icons';
import { currentScope, pageScopeId, scopeChoices, shownScope } from '../src/shell/scope';
import { initials } from '../src/shell/Layout';

const stages = defs as unknown as StageDefinition[];
const row = (stage: string, chain_pos: number, records: number, pending: number, verified: number, kg_out: number): PipeRow =>
  ({ stage, chain_pos, records, pending, verified, kg_out, kg_available: 0 });

describe('the numbers on a scope\'s first screen', () => {
  const rows = [row('procurement', 1, 5, 2, 3, 600), row('qc', 2, 3, 0, 3, 597), row('milling', 3, 2, 1, 1, 150), row('qr_activation', 4, 1, 0, 1, 150)];
  const f = scopeFigures(rows);
  it('procured = what the first stage has verified; output = the last stage before the seal', () => {
    expect(f.procured).toBe(600); expect(f.output).toBe(150); expect(f.yieldPct).toBe(25);
  });
  it('the queue counts records waiting to be verified, and names the stage with the most', () => {
    expect(f.pending).toBe(3); expect(f.bottleneck?.stage).toBe('procurement');
  });
  it('completed = lots that reached the QR stage; records in the chain do not count the seal', () => {
    expect(f.completed).toBe(1); expect(f.records).toBe(10);
  });
  it('no yield before anything has come out of the last stage, and none for a chain with one working stage', () => {
    expect(scopeFigures([row('procurement', 1, 2, 0, 2, 300), row('qc', 2, 0, 0, 0, 0), row('qr_activation', 3, 0, 0, 0, 0)]).yieldPct).toBeNull();
    expect(scopeFigures([row('procurement', 1, 2, 0, 2, 300), row('qr_activation', 2, 1, 0, 1, 300)]).yieldPct).toBeNull();
  });
  it('nothing pending: no bottleneck; no rows at all: zeros, not NaN', () => {
    expect(scopeFigures([row('procurement', 1, 2, 0, 2, 300)]).bottleneck).toBeNull();
    expect(scopeFigures([])).toMatchObject({ procured: 0, output: 0, pending: 0, completed: 0, records: 0, yieldPct: null, bottleneck: null });
  });
  it('the database sends numbers as text now and then: they are still added, not joined', () => {
    const asText = [{ ...row('procurement', 1, 2, 1, 1, 100), pending: '1' as unknown as number, kg_out: '100.5' as unknown as number },
      { ...row('qc', 2, 1, 2, 0, 0), pending: '2' as unknown as number }];
    expect(scopeFigures(asText).pending).toBe(3); expect(scopeFigures(asText).procured).toBe(100.5);
  });
  it('stages nobody holds', () => {
    expect(unassigned(['procurement', 'qc', 'qr_activation'], ['qc'])).toEqual(['procurement', 'qr_activation']);
    expect(unassigned(['procurement'], ['procurement', 'procurement'])).toEqual([]);
  });
});

describe('stage forms in sections', () => {
  it('consecutive fields with one section form one block; a registry without sections gives one block', () => {
    const f = (key: string, section?: string) => ({ key, label: key, type: 'number', section });
    expect(groupSections([f('a', 'x'), f('b', 'x'), f('c', 'y'), f('d', 'x')]).map((g) => [g.section, g.fields.length])).toEqual([['x', 2], ['y', 1], ['x', 1]]);
    expect(groupSections([f('a'), f('b')])).toEqual([{ section: null, fields: [f('a'), f('b')] }]);
    expect(groupSections([])).toEqual([]);
  });
  it('every field of every stage has a section, and a section is one block (its fields stand together)', () => {
    for (const s of stages) {
      expect(s.form_schema.filter((fd) => !fd.section).map((fd) => `${s.stage_type}.${fd.key}`)).toEqual([]);
      const blocks = groupSections(s.form_schema).map((g) => g.section);
      expect(new Set(blocks).size, `${s.stage_type}: a section is split in two`).toBe(blocks.length);
    }
  });
  it('every section has a name in English and Hindi, and a pictogram', () => {
    const used = new Set(stages.flatMap((s) => s.form_schema.map((fd) => fd.section!)));
    for (const sec of used) {
      expect(en[`section.${sec}`], `English name of ${sec}`).toBeTruthy();
      expect(hi[`section.${sec}`], `Hindi name of ${sec}`).toBeTruthy();
      expect(SECTION_ICON[sec], `pictogram of ${sec}`).toBeTruthy();
    }
  });
  it('lists, pickers, files and groups of inputs take the whole width of a two-column form', () => {
    for (const t of ['number[3]', 'attachment', 'readings', 'farmer', 'breakdown', 'packets[]', 'footprint[]']) expect(FULL_WIDTH.has(t)).toBe(true);
    for (const t of ['number', 'integer', 'text', 'select', 'date']) expect(FULL_WIDTH.has(t)).toBe(false);
  });
  it('every stage type has a pictogram', () => {
    for (const s of stages) expect(STAGE_ICON[s.stage_type as StageType], s.stage_type).toBeTruthy();
  });
});

describe('the scope a person works in', () => {
  const scope = (id: string, status = 'active') => ({ scope_id: id, client_id: 'c', client_name: 'Client', crop_name: 'Kalanamak rice', season_code: 'KH26', geography: id, status, chain: ['procurement', 'qc', 'qr_activation'] as StageType[] });
  const slot = (id: string, stage: StageType) => ({ scope_id: id, stage_type: stage, stage_label: stage, scope_label: `Kalanamak rice · KH26 · ${id}`, client_name: 'Client', chain: ['procurement', 'qc', 'qr_activation'] as StageType[], scope_status: 'active' });
  it('a manager chooses among the scopes they can read; closed ones are not offered', () => {
    const c = scopeChoices({ user: { role: 'client_manager' }, slots: [], scopes: [scope('A'), scope('B', 'draft'), scope('C', 'closed')] });
    expect(c.map((x) => [x.id, x.status])).toEqual([['A', 'active'], ['B', 'draft']]);
    expect(c[0].label).toBe('Kalanamak rice · KH26 · A');
  });
  it('an operator chooses among the scopes they hold a stage in, each once', () => {
    const c = scopeChoices({ user: { role: 'operator' }, slots: [slot('A', 'procurement'), slot('A', 'qc'), slot('B', 'qc')], scopes: [] });
    expect(c.map((x) => x.id)).toEqual(['A', 'B']);
  });
  it('one scope: that one, whatever was stored. Several: the stored choice if it is still there, else none ("Overall")', () => {
    const [a, b] = scopeChoices({ user: { role: 'client_manager' }, slots: [], scopes: [scope('A'), scope('B')] });
    expect(currentScope([a], null)?.id).toBe('A'); expect(currentScope([a], 'gone')?.id).toBe('A');
    expect(currentScope([a, b], 'B')?.id).toBe('B'); expect(currentScope([a, b], 'gone')).toBeNull(); expect(currentScope([a, b], null)).toBeNull();
    expect(currentScope([], 'A')).toBeNull();
  });
  it('nobody signed in: nothing to choose', () => expect(scopeChoices(null)).toEqual([]));
  it('a stage page and a scope\'s dashboard belong to a scope; other pages to none', () => {
    expect(pageScopeId('/work/abc/procurement')).toBe('abc'); expect(pageScopeId('/dashboard/abc')).toBe('abc');
    for (const p of ['/', '/farmers', '/records/abc', '/scopes/abc', '/workshop/abc']) expect(pageScopeId(p), p).toBeNull();
  });
  it('the frame shows the page\'s scope over the chosen one, and never a scope the person cannot work in', () => {
    const [a, b] = scopeChoices({ user: { role: 'client_manager' }, slots: [], scopes: [scope('A'), scope('B')] });
    expect(shownScope([a, b], null, '/work/B/qc')?.id).toBe('B');           // "Overall" chosen, working in B
    expect(shownScope([a, b], a, '/dashboard/B')?.id).toBe('B');            // A chosen, looking at B
    expect(shownScope([a, b], a, '/farmers')?.id).toBe('A');
    expect(shownScope([a, b], null, '/')).toBeNull();
    expect(shownScope([a, b], a, '/work/Z/qc')?.id).toBe('A');              // not one of this person's scopes
  });
});

describe('the frame', () => {
  it('initials in the top bar: the first letters of the first two words; brackets and signs are not letters', () => {
    expect(initials('Prasaadam Client Manager')).toBe('PC');
    expect(initials('Veda (Admin)')).toBe('VA');
    expect(initials('  sita ')).toBe('S');
    expect(initials('सीता देवी')).toBe('सद');
    expect(initials('')).toBe('');
  });
  it('the menu carries the prototype\'s names, in both languages', () => {
    expect([en['nav.home'], en['nav.scopes'], en['nav.users'], en['nav.crops'], en['nav.farmers']]).toEqual(['Dashboard', 'Season Scopes', 'Users & Roles', 'Crop Registry', 'Farmers']);
    for (const k of ['nav.section_overview', 'nav.section_registry', 'nav.section_operations', 'nav.section_system', 'nav.section_support']) {
      expect(en[k]).toBeTruthy(); expect(hi[k]).toBeTruthy();
    }
  });
  it('status chips use the prototype\'s words', () => {
    expect(en['badge.pending']).toBe('Pending verification'); expect(en['badge.verified']).toBe('Approved'); expect(en['badge.superseded']).toBe('Withdrawn');
  });
});
