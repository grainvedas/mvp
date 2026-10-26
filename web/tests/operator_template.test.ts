// Migration 48 (Veda, 15 Oct 2026: the operator-stages brief, release 1, with the Client Manager's home, menu and
// ledger). The database's rules are tested in tests/42_operator_template.sql; these hold the pure parts of the screens:
// plain words for refusals (A4/G13), times in India's time (fix 2), "Needs my action" (D3), the Client Manager's menu
// (D4), the farmer's history lines (fix 1) and the date bounds of "On" (A9).
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { looksTechnical, plainWords, PLAIN_RULES } from '../src/lib/plainErrors';
import { plainText } from '../src/shell/ui';
import { dateTime, date, istStamp } from '../src/lib/format';
import { actionLines } from '../src/pages/NeedsMyAction';
import { CM_HEADINGS, groupedMenu, ROLE_MENUS } from '../src/shell/Layout';
import { historyLine } from '../src/pages/farmers/Farmers';
import { shiftDay } from '../src/engine/StagePage';
import { translate } from '../src/lib/i18n';
import { registerDictionary } from '../src/lib/i18n';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { NO_RIGHTS, type MyActions, type MyContext } from '../src/lib/types';

registerDictionary('en', en); registerDictionary('hi', hi);
const tEn = (k: string, v?: Record<string, string | number>, f?: string) => translate('en', k, v, f);
const tHi = (k: string, v?: Record<string, string | number>, f?: string) => translate('hi', k, v, f);

describe('plain words for the database\'s refusals (A4/G13)', () => {
  it('every rule has its words in English and Hindi', () => {
    for (const r of PLAIN_RULES) { expect(en[r.key], r.key).toBeTruthy(); expect(hi[r.key], r.key).toBeTruthy(); }
    expect(translate('hi', 'err.generic', { ref: '23514' })).toContain('23514');
  });
  it('the refusals operators meet read in plain words, with their numbers, in both languages', () => {
    expect(plainWords('qty_in 120.000 exceeds available 98.000 on predecessor', tEn)).toBe('120.000 kg is more than the 98.000 kg left on the lot it comes from.');
    expect(plainWords('good farming practice not complete for this farmer (Kalanamak Rice): GAP 1, gap 2', tEn))
      .toBe('This farmer\'s good farming practice for Kalanamak Rice is not complete: GAP 1, gap 2. Fill it in, then save the lot.');
    expect(plainWords('this record was returned to its sender: it is verified after the correction', tHi)).toBe(hi['err.returned']);
    expect(plainWords('user  may not create at stage procurement in this scope', tEn)).toContain('Procurement');
    expect(plainWords('a manager records at a stage he does not hold only with a written reason (at least 10 characters)', tEn)).toBe(en['err.manager_reason']);
  });
  it('the database\'s inside words never reach the screen; its plain sentences do', () => {
    expect(looksTechnical('new row for relation "footprints" violates check constraint "footprints_qty_in_check"')).toBe(true);
    expect(looksTechnical('the Client Manager of this client decides')).toBe(false);
    expect(plainText('insert or update on table "footprints" violates foreign key constraint "footprints_farmer_id_fkey"', tEn, '23503')).toBe(en['err.missing_link']);
    expect(plainText('operator does not exist: jsonb ->> integer', tEn, '42883')).toBe(tEn('err.generic', { ref: '42883' }));
    expect(plainText('the Client Manager of this client decides', tEn)).toBe('The Client Manager of this client decides');
  });
  it('the stage page and the outbox show the refusal through the same words', () => {
    const page = readFileSync(join(__dirname, '../src/engine/StagePage.tsx'), 'utf8');
    expect(page).toContain("{t('engine.refused')} {plainText(preview.error ?? '', t)}");
    expect(page).toContain('plainText(draft.error, t)');
    expect(readFileSync(join(__dirname, '../src/offline/OutboxPage.tsx'), 'utf8')).toContain('plainText(i.error, t)');
  });
});

describe('times in India\'s time, everywhere (fix 2)', () => {
  it('on screen and in exports, whatever the browser\'s zone', () => {
    expect(dateTime('2026-10-15T03:42:00Z')).toMatch(/15 Oct 2026.*9:12.*IST$/i);
    expect(date('2026-10-14T20:00:00Z')).toMatch(/15 Oct 2026/);                     // 01:30 IST is the next day
    expect(istStamp('2026-10-15T03:42:03.123Z')).toBe('2026-10-15 09:12:03 IST');
    expect(istStamp(null)).toBe('');
  });
  it('every export writes its times through istStamp', () => {
    expect(readFileSync(join(__dirname, '../src/pages/system/Ledger.tsx'), 'utf8')).toContain('istStamp(');
    // the journey and the season are made on the server since migration 60 (Part C): their times in IST there
    const mig = readFileSync(join(__dirname, '../../supabase/migrations/20261104000100_exports.sql'), 'utf8');
    for (const col of ['recorded_at', 'verified_at', 'sealed_at', 'received_at']) expect(mig).toMatch(new RegExp(`'${col}', [^\\n]*at time zone 'Asia/Kolkata'`));
    expect(mig).toContain("'generated_at', to_char(now() at time zone 'Asia/Kolkata'");
  });
});

describe('"Needs my action" (D3)', () => {
  const a: MyActions = {
    returned: [{ id: 'f1', code: 'TCUP-KNM-KH26-GKP-P-0001', stage: 'procurement', scope_id: 's1', scope: 'Kalanamak · KH26 · gkp', reason: 'moisture readings look copied', by: 'Lucky', at: '2026-10-15T03:42:00Z', in_place: true }],
    to_verify: [{ scope_id: 's1', scope: 'Kalanamak · KH26 · gkp', stage: 'milling', from_stage: 'procurement', n: 2 }],
    proposals: 1, farmers_to_verify: 0, requirement_lines: 0, flags: 3, conditions: 1,
  };
  it('lines in the order they are dealt with, each with where it opens', () => {
    const l = actionLines(a, tEn);
    expect(l.map((x) => x.key)).toEqual(['r-f1', 'v-s1-milling', 'proposals', 'conditions', 'flags']);
    expect(l[0].to).toBe('/records/f1');
    expect(l[0].detail).toContain('moisture readings look copied');
    expect(l[1].text).toBe('2 from Procurement (farm-gate) waiting for your verification at Milling'.replace('Procurement (farm-gate)', tEn('stage.procurement')).replace('Milling', tEn('stage.milling')));
    expect(l.reduce((s, x) => s + x.n, 0)).toBe(1 + 2 + 1 + 1 + 3);
  });
  it('a record that cannot be corrected in place says "withdraw and record again"', () => {
    expect(actionLines({ ...a, returned: [{ ...a.returned[0], in_place: false }] }, tEn)[0].action).toBe(en['act.withdraw_again']);
  });
});

describe('the Client Manager\'s menu (D4)', () => {
  const cm = { user: { id: 'me', role: 'client_manager', can: { ...NO_RIGHTS, assign: true, build_scope: true } },
    assignments: [{ id: 'a', lens: 'client', op_role: 'client_account', client_id: 'c1' }], slots: [], scopes: [] } as unknown as MyContext;
  it('Watch · My scopes · Farmers · People · Audit · Me, every word in both languages', () => {
    expect(groupedMenu(cm)).toBe('client_manager');
    expect(CM_HEADINGS).toEqual(['watch', 'scopes', 'farmers', 'people', 'audit', 'me']);
    const all = CM_HEADINGS.flatMap((h) => ROLE_MENUS.client_manager[h]);
    expect(all.map((m) => m.to)).toEqual(['/', '/flags', '/scopes', '/orders', '/setup', '/farmers', '/farmers/new', '/people', '/system/ledger', '/onboarding', '/outbox', '/account', '/guide', '/help']);
    for (const m of all) { expect(en[m.key], m.key).toBeTruthy(); expect(hi[m.key], m.key).toBeTruthy(); }
    for (const h of CM_HEADINGS) { expect(en[`menu.${h}`], h).toBeTruthy(); expect(hi[`menu.${h}`], h).toBeTruthy(); }
  });
  it('an operator gets the sectioned menu, as before', () => {
    expect(groupedMenu({ ...cm, assignments: [] } as unknown as MyContext)).toBeNull();
  });
});

describe('the farmer\'s history names every line (fix 1)', () => {
  const e = (over: Record<string, unknown>) => ({ seq: 1, at: '', kind: '', by: 'p', role: 'operator', before: null, after: null, reason: null,
    farmer_code: null, state_farmer_code: null, linked: null, ...over }) as Parameters<typeof historyLine>[0];
  it('practice answered, and the farmer\'s lots', () => {
    expect(historyLine(e({ kind: 'practice_saved', crop: 'Kalanamak Rice' }), tEn)).toBe('Good farming practice answered (Kalanamak Rice)');
    expect(historyLine(e({ kind: 'lot_create', record: 'TCUP-KNM-KH26-GKP-P-0004', stage: 'procurement', qty: 98 }), tEn))
      .toBe(`Lot TCUP-KNM-KH26-GKP-P-0004 recorded at ${tEn('stage.procurement')} (98 kg)`);
    expect(historyLine(e({ kind: 'practice_saved', crop: 'Kalanamak Rice' }), tHi)).toBe('अच्छी खेती पद्धति के उत्तर दिए (Kalanamak Rice)');
  });
  it('no line is blank', () => {
    expect(historyLine(e({ kind: null }), tEn)).toBe(en['fh.other']);
    expect(historyLine(e({ kind: 'something_new' }), tEn)).toBe('Something New');
  });
});

describe('"On": the date it happened (A9)', () => {
  it('31 days back at most, as the server allows', () => {
    expect(shiftDay('2026-10-15', -31)).toBe('2026-09-14');
    expect(shiftDay('2026-03-01', -1)).toBe('2026-02-28');
  });
});
