// Migration 41 (Veda, 13 Oct 2026, "State Manager role"): the pure rules the screens follow. What the database refuses
// is tested in tests/35_state_manager.sql; these hold the first screen, the menu, the overview's figures and checklist,
// who is offered "New scope", "New farmer" and crop edits, and the words of the guide in both languages.
import { describe, expect, it } from 'vitest';
import { firstScreen } from '../src/pages/Home';
import { needsMyAction, stateSetup, type StateHomeData } from '../src/pages/state/StateHome';
import { groupedMenu, HEADINGS, ROLE_MENUS } from '../src/shell/Layout';
import { cropsFor } from '../src/pages/admin/Admin';
import { helpRole } from '../src/pages/Help';
import { actsAsStateManager, addsFarmers, buildsScope, buildsScopes, myStateIds } from '../src/lib/rights';
import { guideLines } from '../src/shell/RoleGuide';
import { translate } from '../src/lib/i18n';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { NO_RIGHTS, type Can, type MyAssignment, type MyContext } from '../src/lib/types';

type A = MyAssignment;
const asg = (over: Partial<A>): A => ({ id: 'a', lens: 'scope', op_role: 'operator', scope_id: null, client_id: null, client_name: null, state_id: null, state_name: null,
  stages: [], posting: null, season_code: null, ends_on: null, label: '', ...over } as A);
const ctx = (over: { can?: Partial<Can>; assignments?: A[]; scopes?: { scope_id: string; client_id?: string; manage: boolean; build?: boolean }[]; slots?: { scope_id: string; stage_type: string }[] }) => ({
  user: { id: 'me', role: 'operator', display_name: 'Ram', email: null, phone: null, client_id: null, client_name: null, state_ids: [], can: { ...NO_RIGHTS, ...(over.can ?? {}) } },
  assignments: over.assignments ?? [], slots: over.slots ?? [],
  scopes: (over.scopes ?? []).map((s) => ({ client_id: 'c1', client_name: 'C', crop_name: 'R', season_code: 'KH26', geography: 'g', status: 'active', chain: [], ...s })),
}) as unknown as MyContext;

const RAM = ctx({ can: { assign: true, state_lens: true, state_manager: true, build_scope: false }, assignments: [asg({ lens: 'state', state_id: 'UP', state_name: 'Uttar Pradesh' })],
  scopes: [{ scope_id: 's1', manage: true, build: false }] });
const CM = ctx({ can: { assign: true, build_scope: true, state_manager: false }, assignments: [asg({ lens: 'client', op_role: 'client_account', client_id: 'c1' })],
  scopes: [{ scope_id: 's1', manage: true, build: true }] });
const PROC = ctx({ assignments: [asg({ lens: 'scope', scope_id: 's1' })], scopes: [{ scope_id: 's1', manage: false }], slots: [{ scope_id: 's1', stage_type: 'procurement' }] });
const ADMIN = ctx({ can: { admin: true, oversee: true, assign: true, state_lens: true } });

const data = (over: Partial<StateHomeData> = {}): StateHomeData => ({
  state: { id: 'UP', name: 'Uttar Pradesh', code: 'UP' }, managers: ['Ram'],
  clients: { total: 2, active: 1, without_manager: 1, list: [] }, crops: { total: 1, state_not_set: 0, list: [] },
  scopes: { active: 1, setup: 1, closed: 0, qr_issued: 4, list: [] }, farmers: { total: 3, active: 2 },
  attention: { no_manager: 1, no_manager_list: [], farmers_waiting: 2, farmers_list: [], unstaffed: 3, unstaffed_list: [], open_flags: 1, flags_list: [] },
  pipeline: [], ...over,
});

describe('the State Manager (migration 41)', () => {
  it('first screen: the overview of his state; a scope he chose is the scope screen', () => {
    const base = { status: 'active', external: false, hr: false, admin: false, stateManager: true, assign: true, scopes: [{ whole: true }], current: null as { whole: boolean } | null };
    expect(firstScreen(base)).toBe('state');
    expect(firstScreen({ ...base, scopes: [] })).toBe('state');                         // a new state: no scope yet
    expect(firstScreen({ ...base, current: { whole: true } })).toBe('scope');
    expect(firstScreen({ ...base, stateManager: false })).toBe('overall');              // a Client Manager, as before
    expect(firstScreen({ ...base, status: 'onboarding' })).toBe('joiner');              // not yet joined: his checklist first
  });
  it('his menu: Watch, Audit, Master data, Access, Me; no States, no Health, no State overview', () => {
    expect(groupedMenu(RAM)).toBe('state_manager');
    expect(groupedMenu(ADMIN)).toBe('admin');
    expect(groupedMenu(CM)).toBe('client_manager');                                     // migration 48 (D4): his own grouped menu
    const all = HEADINGS.flatMap((h) => ROLE_MENUS.state_manager[h]).map((m) => m.to);
    expect(all).toEqual(['/', '/pipeline', '/orders', '/flags', '/system/ledger', '/clients', '/crops', '/setup', '/scopes', '/farmers', '/farmers/register', '/people', '/onboarding', '/account', '/guide', '/help']);
    for (const gone of ['/states', '/health', '/state', '/system/seats', '/system/audit', '/hr']) expect(all).not.toContain(gone);
    const checklist = ROLE_MENUS.state_manager.me.find((m) => m.to === '/onboarding')!;
    expect(checklist.show!({ joiner: true } as never)).toBe(true);
    expect(checklist.show!({ joiner: false } as never)).toBe(false);                      // only while it has open steps
    for (const h of HEADINGS) for (const m of ROLE_MENUS.state_manager[h]) { expect(en[m.key], m.key).toBeTruthy(); expect(hi[m.key], m.key).toBeTruthy(); }
  });
  it('"Needs my action" is the sum of the four lists it opens', () => {
    expect(needsMyAction(data().attention)).toBe(1 + 2 + 3 + 1);
    expect(needsMyAction({ ...data().attention, no_manager: 0, farmers_waiting: 0, unstaffed: 0, open_flags: 0 })).toBe(0);
    // migration 43: possible duplicates and farmers past 120 % are his to decide; farmers without GI land are shown, not counted
    expect(needsMyAction({ ...data().attention, duplicates: 2, over_yield: 1, no_gi_land: 9 })).toBe(1 + 2 + 3 + 1 + 2 + 1);
  });
  it('the set-up checklist ticks itself from his state\'s numbers', () => {
    expect(stateSetup(data()).map((i) => i.done)).toEqual([true, true, false, true, false]);
    expect(stateSetup(data({ clients: { total: 2, active: 2, without_manager: 0, list: [] }, attention: { ...data().attention, farmers_waiting: 0 } })).map((i) => i.done))
      .toEqual([true, true, true, true, true]);
    expect(stateSetup(data({ crops: { total: 0, state_not_set: 1, list: [] }, clients: { total: 0, active: 0, without_manager: 0, list: [] }, scopes: { active: 0, setup: 0, closed: 0, qr_issued: 0, list: [] }, farmers: { total: 0, active: 0 } })).map((i) => i.done))
      .toEqual([false, false, false, false, false]);                                       // a new state: nothing is ticked, "no clients" is not "all managed"
  });
  it('who is offered what: New scope to the Client Manager; New farmer to him and procurement; neither to Ram or the admin', () => {
    expect(actsAsStateManager(RAM)).toBe(true);
    expect(myStateIds(RAM)).toEqual(['UP']);
    expect(buildsScopes(RAM)).toBe(false); expect(buildsScope(RAM, 's1')).toBe(false);
    expect(buildsScopes(CM)).toBe(true); expect(buildsScope(CM, 's1')).toBe(true);
    expect(buildsScopes(ADMIN)).toBe(false);
    expect(addsFarmers(RAM, 'c1')).toBe(false);
    expect(addsFarmers(CM, 'c1')).toBe(true);
    expect(addsFarmers(PROC, 'c1')).toBe(true);
    expect(addsFarmers(PROC, 'c2')).toBe(false);
    expect(addsFarmers(ADMIN, 'c1')).toBe(false);
  });
  it('crops: he works with his state\'s and those with no state yet; everyone else sees all', () => {
    const list = [{ id: 'k', state_id: null }, { id: 'u', state_id: 'UP' }, { id: 'a', state_id: 'AS' }];
    expect(cropsFor(list, ['UP']).map((c) => c.id)).toEqual(['k', 'u']);
    expect(cropsFor(list, null).map((c) => c.id)).toEqual(['k', 'u', 'a']);
  });
  it('his guide and his help, in English and Hindi', () => {
    expect(helpRole(RAM)).toBe('state_manager');
    expect(helpRole(CM)).toBe('any');
    for (const lang of ['en', 'hi'] as const) {
      const t = (k: string, v?: Record<string, string | number>, f?: string) => translate(lang, k, v, f);
      expect(guideLines('state_manager', t)).toHaveLength(5);
      expect(t('guide.state_manager.title')).not.toBe('guide.state_manager.title');
      for (let i = 1; i <= 4; i++) expect(t(`help.state_manager.${i}`)).not.toBe(`help.state_manager.${i}`);
    }
    const fresh = Object.keys(en).filter((k) => /^(sh\.|guide\.state_manager|help\.state_manager|ledger\.(state_|check_)|crops\.state_|audit\.crop_)/.test(k));
    expect(fresh.length).toBeGreaterThan(40);
    for (const k of fresh) expect(hi[k], k).toBeTruthy();
    expect(translate('en', 'sh.title', { state: 'Uttar Pradesh', name: 'Ram' })).toBe('Uttar Pradesh overview · State Manager · Ram');
    expect(translate('en', 'sh.no_manager', { n: 1 })).toBe('1 client has no Client Manager yet.');
    expect(translate('en', 'sh.no_manager', { n: 2 })).toBe('2 clients have no Client Manager yet.');
  });
});
