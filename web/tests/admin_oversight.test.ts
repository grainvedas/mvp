// Migration 34 (Veda, 10 Oct 2026): the admin oversees. What the database refuses is tested in tests/28_admin_oversight.sql;
// these are the pure rules the screens follow: which first screen, what the menu shows, which farmer buttons appear,
// the counts that must agree, the role guide's words in both languages.
import { describe, expect, it } from 'vitest';
import { firstScreen, queueCount } from '../src/pages/Home';
import { attentionTotal, clientsByState, type OverviewClient } from '../src/pages/admin/Overview';
import { farmerRights } from '../src/pages/farmers/Farmers';
import { blockSubject, LEDGER_EVENTS, type LedgerRow } from '../src/pages/system/Ledger';
import { guideLines } from '../src/shell/RoleGuide';
import { currentScope, type ScopeChoice } from '../src/shell/scope';
import { NAV, type NavWho } from '../src/shell/Layout';
import { holdsClientAccount, isStateManager, managesScope, oversees, supervisesState } from '../src/lib/rights';
import { translate } from '../src/lib/i18n';
import { NO_RIGHTS, type Can, type MyAssignment, type MyContext } from '../src/lib/types';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';

type A = MyAssignment;
const asg = (over: Partial<A>): A => ({ id: 'a', lens: 'scope', op_role: 'operator', scope_id: null, client_id: null, client_name: null, state_id: null, state_name: null,
  stages: [], posting: null, season_code: null, ends_on: null, label: '', ...over } as A);
const ctx = (over: { id?: string; can?: Partial<Can>; assignments?: A[]; scopes?: { scope_id: string; manage: boolean }[] }) => ({
  user: { id: over.id ?? 'me', role: 'operator', display_name: 'X', email: null, phone: null, client_id: null, client_name: null, state_ids: [], can: { ...NO_RIGHTS, ...(over.can ?? {}) } },
  assignments: over.assignments ?? [], slots: [], scopes: (over.scopes ?? []).map((s) => ({ client_id: 'c', client_name: 'C', crop_name: 'R', season_code: 'KH26', geography: 'g', status: 'active', chain: [], ...s })),
}) as unknown as MyContext;

const ADMIN = ctx({ can: { admin: true, oversee: true, assign: true, state_lens: true }, scopes: [{ scope_id: 's1', manage: false }],
  // an admin's own assignments grant nothing on the server; the screens must not offer anything for them either
  assignments: [asg({ lens: 'state', state_id: 'UP' }), asg({ lens: 'client', op_role: 'client_account', client_id: 'c1' })] });
const CM = ctx({ id: 'cm', can: { assign: true }, assignments: [asg({ lens: 'client', op_role: 'client_account', client_id: 'c1' })], scopes: [{ scope_id: 's1', manage: true }] });
const SM_UP = ctx({ id: 'sm', can: { assign: true, state_lens: true }, assignments: [asg({ lens: 'state', state_id: 'UP' })] });
const SM_BR = ctx({ id: 'sm2', can: { assign: true, state_lens: true }, assignments: [asg({ lens: 'state', state_id: 'BR' })] });
const OP = ctx({ id: 'op', assignments: [asg({ lens: 'scope', scope_id: 's1' })] });
const BOTH = ctx({ id: 'both', can: { assign: true, state_lens: true }, assignments: [asg({ lens: 'client', op_role: 'client_account', client_id: 'c1' }), asg({ lens: 'state', state_id: 'UP' })] });

describe('the admin oversees', () => {
  it('first screen: the platform overview; a scope opened from it is the scope screen (read-only)', () => {
    const base = { status: 'active', external: false, hr: false, admin: true, oversee: true, assign: true, scopes: [] as { whole: boolean }[], current: null as { whole: boolean } | null };
    expect(firstScreen(base)).toBe('oversight');
    expect(firstScreen({ ...base, scopes: [{ whole: true }] })).toBe('oversight');
    expect(firstScreen({ ...base, scopes: [{ whole: true }], current: { whole: true } })).toBe('scope');
    // a server before migration 34 sends no `oversee`: the screens as they were
    expect(firstScreen({ ...base, oversee: undefined })).toBe('overall');
  });
  it('with one scope in the system the admin still starts on the overview; a scope opened from it is in force', () => {
    const one = [{ id: 'A' } as ScopeChoice];
    expect(currentScope(one, null, true)).toBeNull();
    expect(currentScope(one, 'A', true)?.id).toBe('A');
    expect(currentScope(one, null)?.id).toBe('A');                        // everyone else: their one scope, as before
  });
  it('rights: the admin manages no scope, holds no client account, supervises no state, whatever it holds', () => {
    expect(oversees(ADMIN)).toBe(true);
    expect(managesScope(ADMIN, 's1')).toBe(false);
    expect(holdsClientAccount(ADMIN, 'c1')).toBe(false);
    expect(supervisesState(ADMIN, 'UP')).toBe(false);
    expect(isStateManager(ADMIN)).toBe(false);
    expect(managesScope(CM, 's1')).toBe(true);
    expect(holdsClientAccount(CM, 'c1')).toBe(true);
    expect(holdsClientAccount(CM, 'c2')).toBe(false);
    expect(supervisesState(SM_UP, 'UP')).toBe(true);
    expect(supervisesState(SM_UP, 'BR')).toBe(false);
  });
  it('menu: the ledger, seats, states, crops and clients (to read); HR · Joiners only while the server says the seat is empty', () => {
    const links = (w: Omit<Partial<NavWho>, 'can'> & { can?: Partial<Can> }) =>
      NAV.filter((n) => n.show({ role: 'operator', farmerSlot: false, joiner: false, employee: true, ...w, can: { ...NO_RIGHTS, ...(w.can ?? {}) } })).map((n) => n.to);
    const filled = links({ role: 'admin', can: { admin: true, oversee: true, audit: true, hr: false, hr_admin: false, assign: true, state_lens: true, hr_seat_filled: true } });
    expect(filled).toEqual(expect.arrayContaining(['/system/ledger', '/system/seats', '/system/audit', '/states', '/crops', '/clients', '/people']));
    expect(filled).not.toContain('/hr');
    const vacant = links({ role: 'admin', can: { admin: true, oversee: true, audit: true, hr: true, hr_admin: true, assign: true, state_lens: true, hr_seat_filled: false } });
    expect(vacant).toContain('/hr');
    // the ledger page is the admin's alone
    expect(links({ role: 'state_manager', can: { assign: true, state_lens: true } })).not.toContain('/system/ledger');
    expect(links({ role: 'state_manager', can: { assign: true, state_lens: true } })).toEqual(expect.arrayContaining(['/crops', '/clients']));
  });
});

describe('two farmer verifications', () => {
  const draft = { client_id: 'c1', status: 'draft' as const, state_id: 'UP', reviewed_by: null };
  const waiting = { client_id: 'c1', status: 'under_review' as const, state_id: 'UP', reviewed_by: 'cm' };
  it('step 1 is the Client Manager of the client; nobody else is offered it', () => {
    expect(farmerRights(CM, draft).step1).toBe(true);
    for (const c of [ADMIN, SM_UP, OP]) expect(farmerRights(c, draft).step1).toBe(false);
  });
  it('step 2 is the State Manager of the farmer\'s state, never the person of step 1', () => {
    expect(farmerRights(SM_UP, waiting).step2).toBe(true);
    expect(farmerRights(SM_BR, waiting).step2).toBe(false);
    for (const c of [ADMIN, CM, OP]) expect(farmerRights(c, waiting).step2).toBe(false);
    const own = { ...waiting, reviewed_by: 'both' };
    expect(farmerRights(BOTH, own).step2).toBe(false);
    expect(farmerRights(BOTH, own).sameHands).toBe(true);
  });
  it('a farmer from before migration 34 (no state): any State Manager, as before', () => {
    const legacy = { client_id: 'c1', status: 'under_review' as const, state_id: null, reviewed_by: null };
    expect(farmerRights(SM_BR, legacy).step2).toBe(true);
    expect(farmerRights(ADMIN, legacy).step2).toBe(false);
  });
  it('after the Farmer ID only that State Manager changes or deactivates the farmer; the admin none', () => {
    const active = { client_id: 'c1', status: 'active' as const, state_id: 'UP', reviewed_by: 'cm' };
    expect(farmerRights(SM_UP, active).afterwards).toBe(true);
    expect(farmerRights(ADMIN, active).afterwards).toBe(false);
    expect(farmerRights(CM, active).afterwards).toBe(false);
  });
});

describe('the counts agree', () => {
  it('the action queue: the card and the title show the same number (they showed 4 and 1)', () => {
    const q = [{ n: 2 }, { n: 1 }, { n: 1 }];
    expect(queueCount(q)).toBe(4);
    expect(queueCount([])).toBe(0);
  });
  it('needs attention is exactly the sum of what its panel lists', () => {
    const a = { open_flags: 1, farmers_step1: 2, farmers_step2: 3, unstaffed: 4, unstaffed_list: [], flags_list: [] };
    expect(attentionTotal(a)).toBe(10);
  });
  it('client cards grouped by state, in state order; one state when chosen', () => {
    const c = (id: string, state_id: string, state_name: string) => ({ id, name: id, state_id, state_name } as OverviewClient);
    const list = [c('a', 'UP', 'Uttar Pradesh'), c('b', 'AS', 'Assam'), c('d', 'UP', 'Uttar Pradesh')];
    expect(clientsByState(list, '').map((g) => [g.state, g.clients.map((x) => x.id)])).toEqual([['Assam', ['b']], ['Uttar Pradesh', ['a', 'd']]]);
    expect(clientsByState(list, 'AS').map((g) => g.state)).toEqual(['Assam']);
  });
});

describe('words', () => {
  it('the admin\'s role guide has its lines in both languages, the override line left out', () => {
    const lines = (lang: 'en' | 'hi') => guideLines('admin', (k, v, f) => translate(lang, k, v, f));
    expect(lines('en')).toHaveLength(4);
    expect(lines('hi')).toHaveLength(4);
    expect(lines('en').join(' ')).not.toMatch(/override/i);
    expect(guideLines('nobody', (k, v, f) => translate('en', k, v, f))).toEqual([]);
  });
  it('every ledger event has a name in both languages', () => {
    for (const e of LEDGER_EVENTS) { expect(en[`event.${e}`], e).toBeTruthy(); expect(hi[`event.${e}`], e).toBeTruthy(); }
  });
  it('a ledger block says what it is about: the record, or what the block says it is', () => {
    const t = (k: string, v?: Record<string, string | number>, f?: string) => translate('en', k, v, f);
    const row = (o: Partial<LedgerRow>) => ({ seq: 1, event: 'supervisory', created_at: '', hash: '', prev_hash: null, footprint_id: null, record: null, stage_type: null,
      what: null, about: null, client: null, scope: null, actor: null, actor_name: null, actor_role: null, actor_summary_role: null, ...o }) as LedgerRow;
    expect(blockSubject(row({ record: 'PR-KNM-KH26-P-0001', what: 'withdraw' }), t)).toBe('PR-KNM-KH26-P-0001 · withdrawn');
    expect(blockSubject(row({ what: 'user_created', about: 'Asha' }), t)).toBe('person added · Asha');
    expect(blockSubject(row({}), t)).toBe('—');
  });
  it('every new English word has its Hindi', () => {
    const fresh = Object.keys(en).filter((k) => /^(ov|ledger|guide|nav\.ledger|farmers\.(admin_reads|drafts_only|verify_step|waits_|location|step1_|the_cm|same_hands|save_)|farmer\.state|clients\.(sm_only|onboard|next_step)|crops\.sm_only|scopes\.(admin_reads|read_only))/.test(k));
    expect(fresh.length).toBeGreaterThan(80);
    for (const k of fresh) expect(hi[k], k).toBeTruthy();
  });
});
