// Migration 45 (Veda, 14 Oct 2026: "when in production … can such thing happen and not recorded?"): the pure rules of
// the Safeguards page. What the database refuses is tested in tests/39_production_safeguards.sql.
import { describe, expect, it } from 'vitest';
import { mayDecide, PATHS, shortHash } from '../src/pages/system/Safeguards';
import { ROLE_MENUS } from '../src/shell/Layout';
import { translate } from '../src/lib/i18n';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';

describe('Safeguards (migration 45)', () => {
  it('a fingerprint is shown by its first and last six characters', () => {
    expect(shortHash('a'.repeat(6) + 'b'.repeat(52) + 'c'.repeat(6))).toBe('aaaaaa…cccccc');
    expect(shortHash(null)).toBe('—');
    expect(shortHash('short')).toBe('short');
  });
  it('a second person decides a request, never the one who asked, and only while it waits', () => {
    expect(mayDecide({ status: 'requested', mine: false }, true)).toBe(true);
    expect(mayDecide({ status: 'requested', mine: true }, true)).toBe(false);
    expect(mayDecide({ status: 'approved', mine: false }, true)).toBe(false);
    expect(mayDecide({ status: 'requested', mine: false }, false)).toBe(false);
  });
  it('the admin finds it under Audit, beside Health', () => {
    expect(ROLE_MENUS.admin.audit.map((m) => m.to)).toEqual(['/system/ledger', '/system/audit', '/health', '/system/safeguards']);
    expect(ROLE_MENUS.state_manager.audit.map((m) => m.to)).not.toContain('/system/safeguards');
  });
  it('every word in English and Hindi, with the same blanks; every way a change came has a name', () => {
    const t = (k: string, v?: Record<string, string | number>) => translate('en', k, v);
    for (const p of PATHS) expect(t(`sg.path_${p}`)).not.toBe(`sg.path_${p}`);
    expect(t('sg.log_ok', { n: 1 })).toBe('Change log intact: 1 line.');
    const keys = Object.keys(en).filter((k) => k.startsWith('sg.') || k === 'nav.safeguards');
    expect(keys.length).toBeGreaterThan(45);
    const vars = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
    for (const k of keys) { expect(hi[k], k).toBeTruthy(); expect(vars(hi[k]), k).toEqual(vars(en[k])); }
    expect(en['sg.log_note']).toMatch(/never a value/);           // the log copies no phone or ID number, and says so
  });
});
