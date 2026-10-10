// Migration 36 (Veda, 10 Oct 2026): the admin marks the HR Admin seat holder as joined, and only her. The database half is
// tests/30_hr_admin_joined.sql; this is the screen's rule for the button, and the new words in both languages.
import { describe, expect, it } from 'vitest';
import { mayActivate } from '../src/pages/hr/Hr';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';

describe('Mark as joined', () => {
  it('follows the server when it says (can_activate), whatever HR may otherwise manage', () => {
    expect(mayActivate({ can_manage: true, can_activate: false, person: { status: 'onboarding' } })).toBe(false);   // the admin, another joiner
    expect(mayActivate({ can_manage: true, can_activate: true, person: { status: 'invited' } })).toBe(true);        // the admin, the HR Admin
    expect(mayActivate({ can_manage: false, can_activate: true, person: { status: 'onboarding' } })).toBe(true);
  });
  it('an older server that does not say: the HR rule as before', () => {
    expect(mayActivate({ can_manage: true, person: { status: 'onboarding' } })).toBe(true);
    expect(mayActivate({ can_manage: true, person: { status: 'active' } })).toBe(false);
    expect(mayActivate({ can_manage: false, person: { status: 'invited' } })).toBe(false);
  });
  it('the new words are in English and Hindi, and the audit line says what the brief asked', () => {
    for (const k of ['seats.hr_admin_not_joined', 'seats.open_joiner_page', 'seats.hr_admin_joined', 'audit.hr_admin_activated_by_admin', 'audit.flag_hr_admin_activated_by_admin']) {
      expect(en[k], k).toBeTruthy(); expect(hi[k], k).toBeTruthy();
    }
    expect(en['audit.flag_hr_admin_activated_by_admin']).toBe('Admin marked the HR Admin as joined');
  });
});
