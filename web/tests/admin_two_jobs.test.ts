// Migration 35 (Veda, 10 Oct 2026): "admin can only add HR admin. and add state … rest he will just look onto data".
// What the database refuses is tested in tests/29_admin_two_jobs.sql; these are the screens' own pure rules: the menu by
// heading, who is offered "Assign", the password words, the public page's sentence, the dashboard's arithmetic.
import { describe, expect, it } from 'vitest';
import { HEADINGS, ROLE_MENUS, type NavWho } from '../src/shell/Layout';
import { givesAssignments, oversees, seatsStateManagers } from '../src/lib/rights';
import { passwordRuleKey } from '../src/auth/SetPassword';
import { howKey } from '../src/pages/public/PublicVerify';
import { changePct, niceMax } from '../src/pages/admin/charts';
import { pipelineInShort, weekLabel, type PipelineStage } from '../src/pages/admin/Overview';
import { fromOverview, fromScope } from '../src/pages/admin/Pipeline';
import { helpRole } from '../src/pages/Help';
import { NO_RIGHTS, type Can, type MyContext } from '../src/lib/types';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';

const ctx = (can: Partial<Can>, system_role = 'operational') => ({
  user: { id: 'me', role: 'operator', system_role, display_name: 'X', can: { ...NO_RIGHTS, ...can } }, assignments: [], slots: [], scopes: [],
}) as unknown as MyContext;
const ADMIN = ctx({ admin: true, oversee: true, assign: true, state_lens: true, hr_seat_filled: true }, 'admin');
const HR_ADMIN = ctx({ hr: true, hr_admin: true, audit: true, state_seat: true }, 'hr_admin');
const HR = ctx({ hr: true }, 'hr_resource');
const SM = ctx({ assign: true, state_lens: true });
const OP = ctx({});

describe('the admin has two jobs', () => {
  it('menu: five headings in order, each page once; Pipeline, My guide and Help are new; HR only while the seat is empty', () => {
    expect(HEADINGS).toEqual(['watch', 'audit', 'master', 'access', 'me']);
    const who = (hr: boolean) => ({ role: 'admin', farmerSlot: false, joiner: false, employee: true, can: { ...NO_RIGHTS, admin: true, oversee: true, hr } }) as NavWho;
    const shown = (hr: boolean) => HEADINGS.flatMap((h) => ROLE_MENUS.admin[h].filter((m) => !m.show || m.show(who(hr))).map((m) => m.to));
    expect(ROLE_MENUS.admin.watch.map((m) => m.to)).toEqual(['/', '/pipeline', '/state', '/flags']);
    expect(ROLE_MENUS.admin.audit.map((m) => m.to)).toEqual(['/system/ledger', '/system/audit', '/health']);
    expect(ROLE_MENUS.admin.master.map((m) => m.to)).toEqual(['/states', '/clients', '/crops', '/scopes', '/farmers']);
    expect(ROLE_MENUS.admin.me.map((m) => m.to)).toEqual(['/account', '/guide', '/help']);
    expect(shown(false)).not.toContain('/hr');
    expect(shown(true)).toContain('/hr');
    expect(new Set(shown(true)).size).toBe(shown(true).length);
    expect(shown(false)).not.toContain('/overrides');                       // no override (Veda: "no override required")
  });
  it('every heading and menu word is in both languages', () => {
    for (const h of HEADINGS) { expect(en[`menu.${h}`], h).toBeTruthy(); expect(hi[`menu.${h}`], h).toBeTruthy(); }
    for (const m of HEADINGS.flatMap((h) => ROLE_MENUS.admin[h])) { expect(en[m.key], m.key).toBeTruthy(); expect(hi[m.key], m.key).toBeTruthy(); }
    expect(hi['menu.read_only']).toBeTruthy();
  });
  it('"Assign" is offered to State and Client Managers and to the HR Admin (a state only); never to the admin', () => {
    expect(oversees(ADMIN)).toBe(true);
    expect(givesAssignments(ADMIN)).toBe(false);                            // even though can.assign is true for him
    expect(givesAssignments(HR_ADMIN)).toBe(true);
    expect(seatsStateManagers(HR_ADMIN)).toBe(true);
    expect(seatsStateManagers(ADMIN)).toBe(false);
    expect(givesAssignments(SM)).toBe(true);
    expect(givesAssignments(HR)).toBe(false);
    expect(givesAssignments(OP)).toBe(false);
  });
  it('help: the admin, the HR Admin, HR and everyone else each read who helps them', () => {
    expect(helpRole(ADMIN)).toBe('admin');
    expect(helpRole(HR_ADMIN)).toBe('hr_admin');
    expect(helpRole(HR)).toBe('hr');
    expect(helpRole(OP)).toBe('any');
    for (const r of ['admin', 'hr_admin', 'hr', 'any']) { expect(en[`help.${r}.1`], r).toBeTruthy(); expect(hi[`help.${r}.1`], r).toBeTruthy(); }
  });
});

describe('words that must not mislead', () => {
  it('My account: who gives a forgotten password back, by role (check 2)', () => {
    expect(passwordRuleKey('admin')).toBe('account.rule_admin');
    expect(passwordRuleKey('hr_admin')).toBe('account.rule_hr_admin');
    expect(passwordRuleKey('operational')).toBe('account.rule');
    expect(passwordRuleKey(undefined)).toBe('account.rule');
    expect(en['account.rule_admin']).toMatch(/another admin/);
    expect(en['account.rule_admin']).not.toMatch(/HR can/);
    expect(en['account.rule_hr_admin']).toMatch(/only the admin/);
    expect(hi['account.rule_admin'] && hi['account.rule_hr_admin']).toBeTruthy();
  });
  it('public page: "checked by the next person" only when the server says every step had that check (brief 1b)', () => {
    expect(howKey(true)).toBe('pv.how');
    expect(howKey(false)).toBe('pv.how_mixed');
    expect(howKey(undefined)).toBe('pv.how_basic');
    expect(en['pv.how']).toMatch(/next person/);
    expect(en['pv.how_mixed']).toMatch(/not checked by the next person/);
    expect(en['pv.how_basic']).not.toMatch(/next person|checked/);
    for (const k of ['pv.how_mixed', 'pv.how_basic']) expect(hi[k], k).toBeTruthy();
  });
  it('no word about an override is shown to the admin as his to do', () => {
    expect(`${en['seats.admin_note']} ${en['guide.admin.1']} ${en['guide.admin.2']}`).not.toMatch(/override/i);
    expect(en['seats.admin_note']).toMatch(/two jobs/);
    expect(en['seats.hr_admin_note']).toMatch(/seats State Managers/);
    expect(en['ov.setup_sm']).toMatch(/HR Admin/);
  });
});

describe('dashboard arithmetic', () => {
  it('niceMax: an axis top of 1, 2 or 5 × 10ⁿ at or above the largest value', () => {
    expect(niceMax([])).toBe(1);
    expect(niceMax([0, 0])).toBe(1);
    expect(niceMax([3])).toBe(5);
    expect(niceMax([10])).toBe(10);
    expect(niceMax([11])).toBe(20);
    expect(niceMax([1450, 30])).toBe(2000);
    expect(niceMax([0.4])).toBe(0.5);
  });
  it('changePct: last four weeks against the four before; nothing to compare is null, not 0% or infinity', () => {
    expect(changePct([1, 1, 1, 1, 2, 2, 2, 2])).toBe(100);
    expect(changePct([0, 0, 0, 0, 0, 0, 4, 0, 4, 4, 0, 0])).toBe(100);
    expect(changePct([4, 4, 4, 4, 1, 1, 1, 1])).toBe(-75);
    expect(changePct([0, 0, 0, 0, 5, 0, 0, 0])).toBeNull();
    expect(changePct([1, 2, 3])).toBeNull();
  });
  const st = (o: Partial<PipelineStage>): PipelineStage => ({ stage_type: 'x', label: 'X', sort_order: 1, position: 0, pending: 0, done: 0, kg_pending: 0, kg_done: 0, oldest_pending: null, ...o });
  it('pipeline in short: what waits, where most of it waits, and the oldest', () => {
    const rows = [st({ stage_type: 'procurement', pending: 2, done: 9, oldest_pending: '2026-10-03T05:00:00Z' }),
      st({ stage_type: 'qc', pending: 5, done: 3, oldest_pending: '2026-10-01T05:00:00Z' }), st({ stage_type: 'qr_activation', pending: 0, done: 1 })];
    const s = pipelineInShort(rows);
    expect(s.waiting).toBe(7);
    expect(s.most?.stage_type).toBe('qc');
    expect(s.oldest).toBe('2026-10-01T05:00:00Z');
    expect(pipelineInShort([st({})]).most).toBeNull();
  });
  it('the Pipeline page keeps the server\'s chain order for all scopes, and the scope\'s own chain for one', () => {
    const all = fromOverview([st({ stage_type: 'procurement', done: 2, kg_done: 100 }), st({ stage_type: 'qc' }), st({ stage_type: 'qr_activation' })]);
    expect(all.map((r) => [r.step, r.stage])).toEqual([[1, 'procurement'], [2, 'qc'], [3, 'qr_activation']]);
    expect(all[0].kg_done).toBe(100);
    const one = fromScope([{ stage: 'milling', chain_pos: 2, records: 1, pending: 1, verified: 0, kg_out: 0, kg_available: 0 },
      { stage: 'procurement', chain_pos: 0, records: 3, pending: 0, verified: 3, kg_out: 300, kg_available: 0 },
      { stage: 'qc', chain_pos: 1, records: 2, pending: 1, verified: 1, kg_out: 90, kg_available: 0 }]);
    expect(one.map((r) => r.stage)).toEqual(['procurement', 'qc', 'milling']);
    expect(one.map((r) => r.step)).toEqual([1, 2, 3]);
    expect(Object.keys(one[0])).not.toContain('records');                // brief 2.4: no "Records" column
  });
  it('a week is labelled by its Monday', () => {
    expect(weekLabel('2026-10-05')).toMatch(/5.*Oct/);
  });
});
