// Onboarding at scale (migration 38): the small pure rules the new HR screens share, and their words in both languages.
import { describe, expect, it } from 'vitest';
import { HIRE_ROLES, NO_FILTER, bulkError, NUMBER_KEYS, filterArgs, importDate, joinerRows, linksText, overdueMine, pageCount, statusIsJoining } from '../src/lib/scale';
import { activationNeed } from '../src/lib/people';
import { tokenFrom } from '../src/pages/public/Invite';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';

describe('import: dates and columns', () => {
  it('reads the date shapes a spreadsheet gives', () => {
    expect(importDate('2026-11-03')).toBe('2026-11-03');
    expect(importDate('3/11/2026')).toBe('2026-11-03');           // India: day first
    expect(importDate('03.11.2026')).toBe('2026-11-03');
    expect(importDate(46329)).toBe('2026-11-03');                 // Excel day number
    expect(importDate(new Date(Date.UTC(2026, 10, 3)))).toBe('2026-11-03');
    expect(importDate('next week')).toBe('next week');            // left for the server to call "not a date"
    expect(importDate(null)).toBe('');
  });
  it('maps common header names, drops empty rows, keeps phone digits whole', () => {
    const rows = joinerRows([
      ['Name', 'Email', 'Mobile Number', 'Date of joining', 'Opening code', 'Something else'],
      ['Asha Example', 'asha@example.com', 9990001234, '3/11/2026', 'MH-OPR-001', 'x'],
      [null, '', '  ', undefined, null, null],
      ['Ravi Example', null, '99900 01235', 46329, null, null],
    ]);
    expect(rows).toHaveLength(2);
    expect(rows[0]).toEqual({ full_name: 'Asha Example', personal_email: 'asha@example.com', phone: '9990001234', join_date: '2026-11-03', opening: 'MH-OPR-001' });
    expect(rows[1]).toEqual({ full_name: 'Ravi Example', phone: '99900 01235', join_date: '2026-11-03' });
    expect(joinerRows([])).toEqual([]);
  });
});

describe('joiners list', () => {
  it('sends only the filters that are set, trimmed', () => {
    expect(filterArgs(NO_FILTER, 50, 0)).toEqual({ limit: 50, offset: 0 });
    expect(filterArgs({ ...NO_FILTER, q: ' asha ', owner: 'mine', overdue: true }, 50, 100)).toEqual({ limit: 50, offset: 100, q: 'asha', owner: 'mine', overdue: true });
  });
  it('counts pages (never zero)', () => {
    expect(pageCount(0, 50)).toBe(1); expect(pageCount(50, 50)).toBe(1); expect(pageCount(51, 50)).toBe(2); expect(pageCount(203, 50)).toBe(5);
  });
  it('knows who is still joining', () => {
    expect(statusIsJoining('invited')).toBe(true); expect(statusIsJoining('onboarding')).toBe(true); expect(statusIsJoining('active')).toBe(false);
  });
});

describe('invites', () => {
  it('reads a token only in its exact shape', () => {
    const tok = 'A'.repeat(40) + '_-9';
    expect(tokenFrom(`#${tok}`)).toBe(tok);
    expect(tokenFrom(`#t=${tok}`)).toBe(tok);
    expect(tokenFrom('')).toBeNull();
    expect(tokenFrom('#short')).toBeNull();
    expect(tokenFrom(`#${tok}x`)).toBeNull();
    expect(tokenFrom(`#${tok.slice(1)}<`)).toBeNull();
  });
  it('lines for a group message leave out people with no link', () => {
    expect(linksText([{ id: '1', name: 'Asha', link: 'https://x/invite#a', sent: 'not_sent' }, { id: '2', name: 'Ravi', link: null, sent: 'email' }]))
      .toBe('Asha — https://x/invite#a');
  });
});

describe('gate and reminders', () => {
  it('a refusal in a bulk act is said in the reader\'s language', () => {
    expect(bulkError('a statutory step is still open: PF form. Finish it, or record it as received on paper')).toBe('bulk.err_statutory');
    expect(bulkError('steps are still open (6): give a reason to mark as joined now')).toBe('bulk.err_reason');
    expect(bulkError('this person is active already')).toBe('bulk.err_status');
    expect(bulkError('you cannot give this assignment: it is outside what you manage')).toBe('bulk.err_not_allowed');
    expect(bulkError('opening_full')).toBe('bulk.err_opening_full');
    expect(bulkError('something new happened')).toBeNull();
    for (const k of ['bulk.err_statutory', 'bulk.err_reason', 'bulk.err_status', 'bulk.err_not_allowed']) { expect(en[k], k).toBeTruthy(); expect(hi[k], k).toBeTruthy(); }
  });
  it('Mark as joined: statutory blocks, other open steps need a reason', () => {
    expect(activationNeed(undefined)).toBe('none');
    expect(activationNeed({ statutory_open: ['PAN'], open: 3 })).toBe('statutory');
    expect(activationNeed({ statutory_open: [], open: 2 })).toBe('reason');
    expect(activationNeed({ statutory_open: [], open: 0 })).toBe('none');
  });
  it('a joiner sees only their own pending steps past due', () => {
    const t = (owner: string, status: string, due_on: string) => ({ owner, status, due_on, title: owner + due_on });
    const got = overdueMine([t('hire', 'pending', '2026-10-01'), t('hire', 'done', '2026-10-01'), t('hr', 'pending', '2026-10-01'), t('hire', 'pending', '2026-10-11')], '2026-10-11');
    expect(got).toHaveLength(1);
  });
});

describe('words in English and Hindi', () => {
  const D = (k: string) => { expect(en[k], k).toBeTruthy(); expect(hi[k], k).toBeTruthy(); };
  it('every hire role, opening number and status has both', () => {
    for (const r of HIRE_ROLES) D(`role.${r}`);
    for (const k of NUMBER_KEYS) D(`open.n_${k}`);
    for (const s of ['open', 'on_hold', 'closed']) D(`open.status_${s}`);
    for (const s of ['not_sent', 'sent', 'failed', 'accepted', 'expired', 'replaced']) D(`inv.state_${s}`);
    for (const s of ['ready', 'warning', 'error', 'skipped']) D(`imp.s_${s}`);
    for (const s of ['us', 'joiner', 'it']) D(`jl.waiting_${s}`);
    for (const s of ['not_found', 'expired', 'used', 'revoked']) D(`invite.state_${s}`);
  });
  it('every new key family is translated', () => {
    const fresh = Object.keys(en).filter((k) => /^(role|open|imp|inv|invite|jl|bulk|gate|aj|jp|tpl|ready|deputy|guide\.hr_admin|guide\.hr_resource)\./.test(k));
    expect(fresh.length).toBeGreaterThan(200);
    for (const k of fresh) expect(hi[k], k).toBeTruthy();
  });
  it('says State Manager, and that the HR Admin seats them (H4, H5)', () => {
    expect(en['oprole.state_supervisor']).toBe('State Manager');
    expect(hi['oprole.state_supervisor']).toBe('स्टेट मैनेजर');
    expect(Object.entries(en).filter(([k, v]) => !k.startsWith('check.') && /state supervisor/i.test(v)).map(([k]) => k)).toEqual([]);
  });
});
