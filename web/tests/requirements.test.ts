// Migration 46 (Veda, 14 Oct 2026, "GrainVeda MVP — HR requirements list and staffing a scope"): the pure rules the
// screens share; every rule that decides is the database's (tests/40_requirements.sql).
import { describe, expect, it } from 'vitest';
import { groupQueue, inSentence, lineForStage, publishable, shownBadge, type RequirementLine } from '../src/lib/requirements';
import { groupOpenings, type Opening } from '../src/lib/scale';
import { howKey } from '../src/pages/public/PublicVerify';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';

const line = (p: Partial<RequirementLine>): RequirementLine => ({ id: 'x', requirement_id: 'r', role: 'operator', stage: 'qc', positions: 1, posting: null,
  needed_by: '2026-10-28', note: null, auto: true, status: 'requested', reason: null, status_at: '', status_by: null, opening: null, shown: 'requested',
  ready: [], joining: [], created_at: '2026-10-14T10:00:00Z', overdue: false, ...p });

describe('requirements', () => {
  it('a stage speaks through its open raised line first, then any open one, then the newest closed', () => {
    const closed = line({ id: 'c', status: 'withdrawn', created_at: '2026-10-14T09:00:00Z' });
    const byHand = line({ id: 'h', auto: false, created_at: '2026-10-14T11:00:00Z' });
    const raised = line({ id: 'a' });
    expect(lineForStage([closed, byHand, raised], 'qc')?.id).toBe('a');
    expect(lineForStage([closed, byHand], 'qc')?.id).toBe('h');
    expect(lineForStage([closed], 'qc')?.id).toBe('c');
    expect(lineForStage([closed], 'milling')).toBeNull();
  });
  it('HR publishes what is requested or held, never a returned or published line', () => {
    expect(publishable([line({ id: '1' }), line({ id: '2', status: 'held' }), line({ id: '3', status: 'returned' }), line({ id: '4', status: 'published' })]).map((l) => l.id)).toEqual(['1', '2']);
  });
  it('the queue reads state → client → scope', () => {
    const g = (state: string, client: string | null, id: string) => ({ id, kind: 'scope' as const, state_id: state, state_name: state, client_id: client, client_name: client,
      scope_id: id, scope_name: id, raised_by: null, raised_at: '', mine: false, lines: [] });
    const q = groupQueue([g('Assam', 'PRSDM', 's1'), g('Uttar Pradesh', 'PRSDM', 's2'), g('Uttar Pradesh', 'PRSDM', 's3'), g('Uttar Pradesh', null, 's4')]);
    expect(q.map((s) => s.state)).toEqual(['Assam', 'Uttar Pradesh']);
    expect(q[1].clients.map((c) => [c.client, c.reqs.length])).toEqual([['PRSDM', 2], [null, 1]]);
  });
  it('statuses have their colours; Ready to assign and Filled read as done', () => {
    expect(shownBadge('ready')).toBe('verified'); expect(shownBadge('filled')).toBe('verified');
    expect(shownBadge('returned')).toBe('fail'); expect(shownBadge('requested')).toBe('pending');
  });
  it('a stage label inside a sentence: "Procurement (farm-gate)" → "procurement"', () => {
    expect(inSentence('Procurement (farm-gate)')).toBe('procurement');
    expect(inSentence('Milling')).toBe('milling');
  });
});

describe('openings by client and scope (section D)', () => {
  const o = (p: Partial<Opening>): Opening => ({ id: p.code ?? 'x', code: 'UP-OPR-001', state_id: 's', state_name: 'UP', role: 'operator', stage: 'qc', client_id: 'c',
    client_name: 'PRSDM', scope_id: 'sc', scope_name: 'KH26 gkp', target_join: null, status: 'open', title: null, note: null, ready_target: true,
    positions: 1, joining: 0, joined: 0, assigned: 0, waiting_wave: 0, ready: 0, vacant: 1, ...p });
  it('groups a scope\'s openings (or a requirement\'s group) with a subtotal of the open ones', () => {
    const g = groupOpenings([o({ code: 'A', group_id: 'g1', group_title: 'Kalanamak · KH26 · gkp', positions: 2, vacant: 2 }), o({ code: 'B', group_id: 'g1', group_title: 'Kalanamak · KH26 · gkp' }),
      o({ code: 'C', scope_id: null, scope_name: null }), o({ code: 'D', client_name: 'DEMOX', client_id: 'd' }), o({ code: 'E', group_id: 'g1', status: 'closed', positions: 9 })]);
    expect(g.map((c) => c.client)).toEqual(['PRSDM', 'DEMOX']);
    const grp = g[0].scopes.find((s) => s.key === 'g1')!;
    expect(grp.group).toBe(true);
    expect(grp.rows.map((r) => r.code)).toEqual(['A', 'B', 'E']);
    expect(grp.total.positions).toBe(3);           // the closed one plans nothing
    expect(g[0].scopes.find((s) => s.key === '')!.rows.map((r) => r.code)).toEqual(['C']);
  });
});

describe('one person on two stages in a row (section E)', () => {
  it('migration 57 (G21, Veda: "this line should not appear"): the public page never says one person recorded and checked a step', () => {
    expect(howKey(true)).toBe('pv.how');
    expect(howKey(false)).toBe('pv.how_basic');
    for (const d of [enPublic, hiPublic]) {
      expect(d['pv.how_same_person']).toBeUndefined();
      expect(d['pv.how_mixed']).toBeUndefined();
      // migration 59 (A2, Veda's brief of 19 Oct 2026): only the step's own sentence, never a lot-wide one
      expect(Object.entries(d).filter(([k, v]) => k !== 'pv.same_person' && /same person|एक ही व्यक्ति/.test(v)).map(([k]) => k)).toEqual([]);
    }
  });
  it('the warning says who and what it means, in English and Hindi', () => {
    expect(en['warn.adjacent_stages']).toBe('{name} also holds {first}. At {second} he will verify his own {first_lower} records.');
    expect(hi['warn.adjacent_stages']).toContain('{name}');
  });
  it('every new word has its Hindi', () => {
    const keys = Object.keys(en).filter((k) => /^(req|sp)\./.test(k) || ['open.from_req', 'open.by_hr', 'ledger.same_person', 'warn.several_stages'].includes(k));
    expect(keys.length).toBeGreaterThan(60);
    expect(keys.filter((k) => !(k in hi))).toEqual([]);
  });
});
