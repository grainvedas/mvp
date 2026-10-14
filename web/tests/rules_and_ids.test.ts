// Migration 44 (Veda, 14 Oct 2026, the follow-up brief, Release 4): the pure rules the screens follow. What the database
// refuses is tested in tests/38_rules_and_farmer_ids.sql; these hold the State Manager's first screen with one scope, whose
// guide "My guide" opens, the activation checklist, the farmer's history lines, "Needs my action", and the words.
import { describe, expect, it } from 'vitest';
import { currentScope, type ScopeChoice } from '../src/shell/scope';
import { guideRole } from '../src/pages/Help';
import { activationLacks } from '../src/pages/scopes/Scopes';
import { historyLine } from '../src/pages/farmers/Farmers';
import { needsMyAction, type StateHomeData } from '../src/pages/state/StateHome';
import { guideLines } from '../src/shell/RoleGuide';
import { translate } from '../src/lib/i18n';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { NO_RIGHTS, type Can, type MyAssignment, type MyContext } from '../src/lib/types';

const t = (k: string, v?: Record<string, string | number>, f?: string) => translate('en', k, v, f);
const asg = (over: Partial<MyAssignment>) => ({ id: 'a', lens: 'scope', op_role: 'operator', scope_id: null, client_id: null, client_name: null,
  state_id: null, state_name: null, stages: [], posting: null, season_code: null, ends_on: null, label: '', ...over }) as MyAssignment;
const ctx = (user: Record<string, unknown>, can: Partial<Can> = {}, assignments: MyAssignment[] = []) =>
  ({ user: { id: 'me', role: 'operator', display_name: 'X', status: 'active', ...user, can: { ...NO_RIGHTS, ...can } }, assignments, slots: [], scopes: [] }) as unknown as MyContext;

describe('Release 4 (migration 44)', () => {
  it('D1: the State Manager with one (draft) scope stays on his state\'s overview, like the admin', () => {
    const one = [{ id: 'A', whole: true } as unknown as ScopeChoice];
    expect(currentScope(one, null, true)).toBeNull();                 // the third argument: oversee, or (now) a State Manager
    expect(currentScope(one, 'A', true)?.id).toBe('A');              // a scope he opens on purpose
    expect(currentScope(one, null)?.id).toBe('A');                    // everyone else: their one scope, as before
  });
  it('D2: "My guide" opens the guide of every role', () => {
    expect(guideRole(ctx({}, { oversee: true, admin: true }))).toBe('admin');
    expect(guideRole(ctx({ status: 'onboarding' }))).toBe('joiner');
    expect(guideRole(ctx({ system_role: 'hr_admin' }))).toBe('hr_admin');
    expect(guideRole(ctx({ system_role: 'hr_resource' }))).toBe('hr_resource');
    expect(guideRole(ctx({}, { state_manager: true }))).toBe('state_manager');
    expect(guideRole(ctx({}, { assign: true }, [asg({ lens: 'client', op_role: 'client_account', client_id: 'c' })]))).toBe('client_manager');
    expect(guideRole(ctx({ external: true }))).toBe('client_view');
    expect(guideRole(ctx({}))).toBe('operator');
    for (const r of ['admin', 'joiner', 'hr_admin', 'hr_resource', 'state_manager', 'client_manager', 'client_view', 'operator']) {
      expect(guideLines(r, t).length, r).toBeGreaterThan(0);
      expect(guideLines(r, (k, v, f) => translate('hi', k, v, f)).length, `${r} (hi)`).toBe(guideLines(r, t).length);
    }
    expect(guideLines('hr_resource', t).join(' ')).not.toMatch(/invite/i);   // G8: no invite wording until a sender is chosen
    expect(guideLines('hr_admin', t)[1]).not.toMatch(/^Send invite/);
  });
  it('A3: what still stops activation, crop first, then every stage with nobody', () => {
    const label = (x: string) => ({ procurement: 'Procurement', qr_activation: 'QR Activation' } as Record<string, string>)[x] ?? x;
    expect(activationLacks(null, label, t)).toEqual([]);                // a server before 44: nothing listed, as before
    expect(activationLacks({ crop: [], retired: false, stages: [] }, label, t)).toEqual([]);
    expect(activationLacks({ crop: ['yield'], retired: false, stages: ['procurement', 'qr_activation'] } as never, label, t))
      .toEqual(['the crop still needs: yield per acre (its State Manager completes it)', 'nobody yet at Procurement', 'nobody yet at QR Activation']);
  });
  it('E3: the farmer\'s history in words', () => {
    const e = (over: Record<string, unknown>) => ({ seq: 1, at: '', kind: '', by: null, role: null, before: null, after: null, reason: null,
      farmer_code: 'TCUP-F-0001', state_farmer_code: 'F-UP-00001', linked: false, ...over }) as never;
    expect(historyLine(e({ kind: 'farmer_verified_client' }), t)).toBe('Verified by the Client Manager: client farmer ID TCUP-F-0001');
    expect(historyLine(e({ kind: 'farmer_verified_state' }), t)).toBe('Verified by the State Manager: new state farmer ID F-UP-00001');
    expect(historyLine(e({ kind: 'farmer_verified_state', linked: true }), t)).toBe('Verified by the State Manager: the same person as state farmer F-UP-00001');
    expect(historyLine(e({ kind: 'farmer_changed', after: { gi_land_acres: 1.5, phone: 'changed' } }), t)).toBe('Changed: GI land, mobile');
  });
  it('E4, E6: "Needs my action" counts changes to accept, never the yield warning', () => {
    const a = { no_manager: 0, no_manager_list: [], farmers_waiting: 0, farmers_list: [], unstaffed: 0, unstaffed_list: [], open_flags: 0, flags_list: [] } as StateHomeData['attention'];
    expect(needsMyAction({ ...a, duplicates: 1, changes: 2, above_yield: 7, no_gi_land: 3 })).toBe(3);
    expect(needsMyAction({ ...a, duplicates: 1, over_yield: 1 })).toBe(2);   // a server of migration 43, as before
  });
  it('every new word in English and Hindi, with the same blanks', () => {
    const keys = Object.keys(en).filter((k) => /^(wrole|fh|wizard\.lack|guide\.(client_manager|operator|client_view)|farmers\.(same_phone|link_to|new_state_id|why_|id_consent|client_id|state_id)|reg\.(warn_|flag_changed|changed_line|dup_state|dup_decide|dup_wait|to_verify|review|c_flags_sub2)|sh\.act_(changes|above_yield)|farmer\.f_|roster\.me)/.test(k));
    expect(keys.length).toBeGreaterThan(60);
    const vars = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
    for (const k of keys) {
      expect(hi[k], k).toBeTruthy();
      expect(vars(hi[k]), k).toEqual(vars(en[k]));
    }
  });
});
