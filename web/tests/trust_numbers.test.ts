// Migration 49 (Veda, 15 Oct 2026: the operator-stages brief, release 2, "numbers you can trust"). The database's rules
// are tested in tests/43_trust_numbers.sql; these hold the screens' part: every check the system sends has its words,
// every physical check its Hindi, warnings in plain words, "GI Tag No. 280", no page reload for a new record.
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { giLabel, giNumber } from '../src/lib/gi';
import { plainWords } from '../src/lib/plainErrors';
import { registerDictionary, translate } from '../src/lib/i18n';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';

registerDictionary('en', en); registerDictionary('hi', hi);
const tEn = (k: string, v?: Record<string, string | number>, f?: string) => translate('en', k, v, f);
const tHi = (k: string, v?: Record<string, string | number>, f?: string) => translate('hi', k, v, f);
const migration = readFileSync(join(__dirname, '../../supabase/migrations/20261024000100_trust_numbers.sql'), 'utf8');
const src = (f: string) => readFileSync(join(__dirname, '../src', f), 'utf8');

describe('what the system checks, and what a person ticks (A2/G3)', () => {
  it('every check key the database sends has its words in both languages', () => {
    const keys = [...new Set([...migration.matchAll(/'key', '([a-z_]+)'/g)].map((m) => m[1]))];
    expect(keys.length).toBeGreaterThanOrEqual(15);
    for (const k of keys) { expect(en[`chk.${k}`], k).toBeTruthy(); expect(hi[`chk.${k}`], k).toBeTruthy(); }
  });
  it('every physical check of every stage has its Hindi', () => {
    const block = migration.slice(migration.indexOf('update public.stage_definitions d set physical_checks'), migration.indexOf('where d.stage_type::text = v.t;'));
    const checks = [...new Set([...block.matchAll(/"([^"]+)"/g)].map((m) => m[1]))];
    expect(checks.length).toBeGreaterThanOrEqual(14);
    for (const c of checks) expect(hi[`check.${c}`], c).toBeTruthy();
    // and the seed carries the same list, so a database built from nothing has it
    expect(readFileSync(join(__dirname, '../../supabase/seeds/01_stage_definitions.sql'), 'utf8')).toContain(block.trim());
  });
  it('the verify step sends the ticks in English (the server compares them), shows them in the reader\'s language', () => {
    const page = src('engine/StagePage.tsx');
    expect(page).toContain("p_checked: physical.filter((_, i) => ticked[i])");
    expect(page).toContain("t(`check.${c}`, undefined, c)");
  });
});

describe('warnings in plain words (A6/G7)', () => {
  it('the outturn ceiling and the learned range, with their numbers, in both languages', () => {
    expect(plainWords("outturn 75.0 % is above the crop's ceiling of 70 %: the State Manager is told", tEn)).toBe("Outturn 75.0 % is above the crop's ceiling of 70 %: the State Manager is told");
    expect(plainWords('outturn 75.0 % is outside the usual range of this crop (63.1 to 68.4 %, from 12 verified runs)', tHi)).toContain('63.1');
    expect(plainWords('declared vs weighed variance exceeds tolerance', tEn)).toBe(en['warn.variance']);
    expect(plainWords('phone clock not plausible: server time used', tHi)).toBe(hi['warn.clock']);
  });
  it('the stage page and the record page show warnings through plain words', () => {
    expect(src('engine/StagePage.tsx').match(/warnings\.map\(\(w\) => plainText\(w, t\)\)/g)?.length).toBe(3);
    expect(src('pages/records/RecordDetail.tsx')).toContain('f.warnings.map((w) => plainText(w, t))');
  });
});

describe('"GI Tag No. 280", never a bare number (G7)', () => {
  it('the number is read from what was typed; other text stays', () => {
    for (const x of ['280', 'GI 280', 'GI Tag 280', 'GI Tag No. 280', 'gi tag no 280']) expect(giNumber(x), x).toBe('280');
    expect(giLabel('280', tEn)).toBe('GI Tag No. 280');
    expect(giLabel('280', tHi)).toBe('GI टैग नं. 280');
    expect(giLabel('GI (Assam)', tEn)).toBe('GI (Assam)');
    expect(enPublic['gi.label']).toBeTruthy(); expect(hiPublic['gi.label']).toBeTruthy();       // the public page shows it too
  });
  it('the public page shows the badge only when the lot is GI, and counts farmers', () => {
    const pv = src('pages/public/PublicVerify.tsx');
    expect(pv).toContain("j.gi_status !== 'non_gi' && j.gi_status !== 'unknown'");
    expect(pv).toContain("t('pv.farmer_count', { n: j.farmer_count })");
    expect(pv).toContain("timeZone: 'Asia/Kolkata'");
  });
});

describe('a new record without reloading the page (A5/G11)', () => {
  it('no full reload and no page jump on the stage page', () => {
    const page = src('engine/StagePage.tsx');
    expect(page).not.toContain('window.location.reload');
    expect(page).not.toContain('window.location.href');
    expect(page).toContain('data-testid="new-record"');
  });
});
