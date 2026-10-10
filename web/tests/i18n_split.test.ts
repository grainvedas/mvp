// FIX_LIST K13: the public verify page loads only lib/i18n.public.ts. Every key its files use must be there, in both
// languages; and the full dictionaries still hold every key (the signed-in app registers them).
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { enPublic, hiPublic } from '../src/lib/i18n.public';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';

const PUBLIC_FILES = ['src/pages/public/PublicVerify.tsx', 'src/pages/public/journey.ts', 'src/shell/ui.tsx', 'src/shell/PracticeStrip.tsx',
  'src/shell/ErrorBoundary.tsx', 'src/App.tsx'];
const src = (f: string) => readFileSync(join(__dirname, '..', f), 'utf8');

describe('the public page\'s own words', () => {
  it('every literal key the public files use is in the public dictionary, in English and Hindi', () => {
    const keys = new Set<string>();
    for (const f of PUBLIC_FILES) for (const m of src(f).matchAll(/\bt\('([a-z][a-zA-Z0-9_]*\.[a-zA-Z0-9_.]+)'/g)) keys.add(m[1]);
    expect(keys.size).toBeGreaterThan(20);
    for (const k of keys) { expect(enPublic[k], k).toBeTruthy(); expect(hiPublic[k], k).toBeTruthy(); }
  });
  it('the keys the public page builds (verdicts, stages, badges) are there too', () => {
    for (const v of ['pass', 'fail', 'pending']) if (en[`pv.v_${v}`]) expect(enPublic[`pv.v_${v}`], v).toBeTruthy();
    for (const k of Object.keys(en).filter((x) => /^(pv|badge)\./.test(x))) expect(enPublic[k], k).toBe(en[k]);
  });
  it('the full dictionaries still hold every public word', () => {
    for (const [k, v] of Object.entries(enPublic)) expect(en[k], k).toBe(v);
    for (const [k, v] of Object.entries(hiPublic)) expect(hi[k], k).toBe(v);
  });
  it('the public bundle does not import the full dictionaries', () => {
    expect(src('src/lib/i18n.tsx')).not.toMatch(/from '\.\/i18n\.(en|hi)'/);
    for (const f of PUBLIC_FILES) expect(src(f), f).not.toMatch(/i18n\.(en|hi)'/);
    expect(src('src/PrivateApp.tsx')).toMatch(/registerDictionary\('hi', hi\)/);
  });
});
