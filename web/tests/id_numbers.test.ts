// Migration 37 (brief of 11 Oct 2026, part A1 and the joiner screens): the id-numbers function and the rules around it.
// The test that matters most here: whatever happens, the full number typed by a person does not leave the function in
// any request to the database, in any answer, or in any log line; and on the app side, never in an error.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { handle, hmacHex, hmacInput, keyUsable, normalise, verhoeffOk, VERSION } from '../../supabase/functions/id-numbers/handler';
import { idCodeKey, IdNumberError, sendIdNumber } from '../src/lib/idNumbers';
import { joinWords, joinerTrack } from '../src/lib/people';
import { scrubNumbers } from '../src/pages/Help';
import { personalProblem } from '../src/pages/onboarding/Onboarding';
import { maskCheck } from '../src/pages/hr/Hr';
import type { HrFile } from '../src/lib/people';
import { errorText } from '../src/shell/ui';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';

const TASK = 'aaaaaaaa-0000-4000-8000-000000000001', ACTOR = 'bbbbbbbb-0000-4000-8000-000000000002', EMP = 'cccccccc-0000-4000-8000-000000000003';
const KEY = 'k'.repeat(40);
const env = { SUPABASE_URL: 'http://srv.test', SUPABASE_ANON_KEY: 'public-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key', ID_HMAC_KEY: KEY, ID_HMAC_KEY_ID: 'k1' };

/** A 12-digit Aadhaar-shaped number whose last digit is a valid Verhoeff check digit. */
function aadhaar(first11: string): string {
  for (let d = 0; d <= 9; d++) if (verhoeffOk(first11 + d)) return first11 + d;
  throw new Error('no check digit');
}
const PAN = 'ABCDE1234F', AAD = aadhaar('23456789012'), UAN = '100200300400', ACCT = '123456789012345', IFSC = 'SBIN0001234';

/** Every request the function makes, with its body, so a test can look for the number in it. */
function server(answers: { target?: () => Response; record?: (body: Record<string, unknown>) => Response } = {}) {
  const seen: { url: string; body: string; headers: string }[] = [];
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input), body = typeof init?.body === 'string' ? init.body : '';
    seen.push({ url, body, headers: JSON.stringify(init?.headers ?? {}) });
    if (url.endsWith('/rpc/id_number_target')) return answers.target?.() ?? new Response(JSON.stringify({ employee_id: EMP, actor_id: ACTOR }), { status: 200 });
    if (url.endsWith('/rpc/record_id_number')) return answers.record?.(JSON.parse(body)) ?? new Response(JSON.stringify({ outcome: 'saved' }), { status: 200 });
    return new Response('{}', { status: 404 });
  }));
  return seen;
}
const post = (body: unknown, token = 'user-token') =>
  new Request('http://fn/id-numbers', { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(body) });

let logs: unknown[][] = [];
beforeEach(() => {
  logs = [];
  for (const m of ['log', 'info', 'warn', 'error', 'debug'] as const) vi.spyOn(console, m).mockImplementation((...a: unknown[]) => { logs.push(a); });
});
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });

/** The number in any of the shapes it might be written: as typed, without spaces, the digits only. */
const shapes = (n: string) => [n, n.replace(/\s/g, ''), n.toLowerCase()];
function expectNowhere(n: string, ...places: string[]) {
  for (const p of places) for (const s of shapes(n)) expect(p.includes(s), `the number was found in: ${p.slice(0, 120)}`).toBe(false);
}

describe('the rules for each number', () => {
  it('PAN: five letters, four digits, a letter; spaces and lower case are tidied', () => {
    expect(normalise('pan', 'abcde 1234 f')).toEqual({ value: PAN, ifsc: null });
    for (const bad of ['ABCD1234F', 'ABCDE12345', '1BCDE1234F', '', 42, null]) expect(normalise('pan', bad), String(bad)).toBeNull();
  });
  it('Aadhaar: 12 digits, not starting 0 or 1, with a valid check digit (B7)', () => {
    expect(normalise('aadhaar', `${AAD.slice(0, 4)} ${AAD.slice(4, 8)} ${AAD.slice(8)}`)?.value).toBe(AAD);
    const wrong = AAD.slice(0, 11) + String((Number(AAD[11]) + 1) % 10);
    expect(normalise('aadhaar', wrong)).toBeNull();
    expect(normalise('aadhaar', '0' + AAD.slice(1))).toBeNull();
    expect(normalise('aadhaar', AAD.slice(0, 11))).toBeNull();
  });
  it('UAN: 12 digits', () => {
    expect(normalise('uan', UAN)?.value).toBe(UAN); expect(normalise('uan', '12345')).toBeNull(); expect(normalise('uan', 'ABCDEFGHIJKL')).toBeNull();
  });
  it('bank: 9 to 18 digits with a valid IFSC; the IFSC is kept upper case', () => {
    expect(normalise('bank', ACCT, 'sbin0001234')).toEqual({ value: ACCT, ifsc: IFSC });
    expect(normalise('bank', ACCT)).toBeNull(); expect(normalise('bank', '12345678', IFSC)).toBeNull(); expect(normalise('bank', ACCT, 'SBIN1001234')).toBeNull();
  });
  it('a very long input is refused before anything else', () => expect(normalise('uan', '1'.repeat(41))).toBeNull());
});

describe('the HMAC', () => {
  it('is over "<kind>:<number>", and for a bank over the first 4 letters of the IFSC and the account', () => {
    expect(hmacInput('pan', PAN, null)).toBe(`pan:${PAN}`);
    expect(hmacInput('bank', ACCT, IFSC)).toBe(`bank:SBIN:${ACCT}`);
    expect(hmacInput('bank', ACCT, 'SBIN0009999')).toBe(hmacInput('bank', ACCT, IFSC));   // another branch of the same bank: the same account
  });
  it('is HMAC-SHA256 (RFC 4231 test case 2), hex', async () => {
    expect(await hmacHex('Jefe', 'what do ya want for nothing?')).toBe('5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843');
  });
  it('an Aadhaar and a UAN with the same digits do not match each other; another key gives another HMAC', async () => {
    const same = '234567890123';
    expect(await hmacHex(KEY, hmacInput('aadhaar', same, null))).not.toBe(await hmacHex(KEY, hmacInput('uan', same, null)));
    expect(await hmacHex(KEY, `pan:${PAN}`)).not.toBe(await hmacHex('x'.repeat(40), `pan:${PAN}`));
    expect(await hmacHex(KEY, `pan:${PAN}`)).toMatch(/^[0-9a-f]{64}$/);
  });
  it('a key shorter than 32 characters is not used', () => {
    expect(keyUsable({ ID_HMAC_KEY: 'short' })).toBe(false); expect(keyUsable({})).toBe(false); expect(keyUsable({ ID_HMAC_KEY: KEY })).toBe(true);
  });
});

describe('the function: answers', () => {
  it('GET says its build and whether the key is set (never the key)', async () => {
    const r = await (await handle(new Request('http://fn/id-numbers'), env)).json();
    expect(r).toEqual({ function: 'id-numbers', version: VERSION, configured: true });
    expect(await (await handle(new Request('http://fn/id-numbers'), { ...env, ID_HMAC_KEY: '' })).json()).toMatchObject({ configured: false });
    expect(JSON.stringify(r)).not.toContain(KEY);
  });
  it('no key: NOT_CONFIGURED, and nothing is asked of the database', async () => {
    const seen = server();
    const res = await handle(post({ task_id: TASK, kind: 'pan', number: PAN }), { ...env, ID_HMAC_KEY: undefined as unknown as string });
    expect(res.status).toBe(500); expect(await res.json()).toEqual({ code: 'NOT_CONFIGURED' }); expect(seen).toHaveLength(0);
  });
  it('signed out or with the public key only: SIGN_IN', async () => {
    server();
    expect((await handle(post({ task_id: TASK, kind: 'pan', number: PAN }, ''), env)).status).toBe(401);
    expect((await handle(post({ task_id: TASK, kind: 'pan', number: PAN }, 'public-key'), env)).status).toBe(401);
  });
  it('a malformed number: BAD_FORMAT, and the database is not asked', async () => {
    const seen = server();
    const res = await handle(post({ task_id: TASK, kind: 'aadhaar', number: '234567890120' === AAD ? '234567890121' : '234567890120' }), env);
    expect(res.status).toBe(400); expect(await res.json()).toEqual({ code: 'BAD_FORMAT', kind: 'aadhaar' }); expect(seen).toHaveLength(0);
  });
  it('a bad kind or task: BAD_REQUEST', async () => {
    server();
    expect(await (await handle(post({ task_id: TASK, kind: 'passport', number: PAN }), env)).json()).toEqual({ code: 'BAD_REQUEST' });
    expect(await (await handle(post({ task_id: 'x', kind: 'pan', number: PAN }), env)).json()).toEqual({ code: 'BAD_REQUEST' });
  });
  it('not the caller\'s step: NOT_ALLOWED; a closed step: STEP_CLOSED; and no HMAC is recorded', async () => {
    let seen = server({ target: () => new Response(JSON.stringify({ message: 'not allowed' }), { status: 403 }) });
    expect(await (await handle(post({ task_id: TASK, kind: 'pan', number: PAN }), env)).json()).toEqual({ code: 'NOT_ALLOWED' });
    expect(seen.map((s) => s.url)).toEqual(['http://srv.test/rest/v1/rpc/id_number_target']);
    seen = server({ target: () => new Response(JSON.stringify({ message: 'step is not open' }), { status: 400 }) });
    expect(await (await handle(post({ task_id: TASK, kind: 'pan', number: PAN }), env)).json()).toEqual({ code: 'STEP_CLOSED' });
    expect(seen).toHaveLength(1);
  });
  it('saved: the whose-number question goes as the caller, the record with the service key', async () => {
    const seen = server();
    const res = await handle(post({ task_id: TASK, kind: 'pan', number: 'abcde1234f' }), env);
    expect(res.status).toBe(200); expect(await res.json()).toEqual({ ok: true, kind: 'pan', last4: '234F', outcome: 'saved' });
    expect(seen[0].headers).toContain('Bearer user-token'); expect(seen[0].headers).not.toContain('service-key');
    expect(seen[1].headers).toContain('Bearer service-key');
    const rec = JSON.parse(seen[1].body);
    expect(rec).toMatchObject({ p_task: TASK, p_actor: ACTOR, p_kind: 'pan', p_last4: '234F', p_key: 'k1', p_ifsc: null });
    expect(rec.p_hmac).toBe(await hmacHex(KEY, `pan:${PAN}`));
  });
  it('duplicate PAN, Aadhaar or UAN: DUPLICATE with nothing else (the joiner is not told whose)', async () => {
    server({ record: () => new Response(JSON.stringify({ outcome: 'refused', match: 'Someone Else' }), { status: 200 }) });
    const res = await handle(post({ task_id: TASK, kind: 'uan', number: UAN }), env);
    expect(res.status).toBe(409); const body = await res.json();
    expect(body).toEqual({ code: 'DUPLICATE' }); expect(JSON.stringify(body)).not.toContain('Someone');
  });
  it('a bank account on another record: saved, outcome warned', async () => {
    server({ record: () => new Response(JSON.stringify({ outcome: 'warned' }), { status: 200 }) });
    expect(await (await handle(post({ task_id: TASK, kind: 'bank', number: ACCT, ifsc: IFSC }), env)).json()).toEqual({ ok: true, kind: 'bank', last4: '2345', outcome: 'warned' });
  });
  it('the key id is kept with each HMAC; a strange key id falls back to k1', async () => {
    let seen = server(); await handle(post({ task_id: TASK, kind: 'pan', number: PAN }), { ...env, ID_HMAC_KEY_ID: 'local' });
    expect(JSON.parse(seen[1].body).p_key).toBe('local');
    seen = server(); await handle(post({ task_id: TASK, kind: 'pan', number: PAN }), { ...env, ID_HMAC_KEY_ID: 'bad key; drop' });
    expect(JSON.parse(seen[1].body).p_key).toBe('k1');
  });
  it('the database fails or throws: NOT_SAVED or FAILED, never the reason', async () => {
    server({ record: () => new Response(JSON.stringify({ message: 'duplicate key value violates unique constraint' }), { status: 409 }) });
    expect(await (await handle(post({ task_id: TASK, kind: 'pan', number: PAN }), env)).json()).toEqual({ code: 'NOT_SAVED' });
    vi.stubGlobal('fetch', vi.fn(async () => { throw new Error(`boom ${PAN}`); }));
    const r = await handle(post({ task_id: TASK, kind: 'pan', number: PAN }), env);
    expect(r.status).toBe(502); expect(await r.json()).toEqual({ code: 'FAILED' });
  });
});

describe('the full number never leaves the function (A1)', () => {
  const cases: [string, Record<string, unknown>, string][] = [
    ['pan', { kind: 'pan', number: PAN }, PAN], ['aadhaar', { kind: 'aadhaar', number: AAD }, AAD],
    ['uan', { kind: 'uan', number: UAN }, UAN], ['bank', { kind: 'bank', number: ACCT, ifsc: IFSC }, ACCT],
  ];
  for (const [name, body, n] of cases) {
    for (const outcome of ['saved', 'warned', 'refused', 'db-error', 'throws'] as const) {
      it(`${name}, ${outcome}: not in any request to the database, not in the answer, not in any log`, async () => {
        const seen = outcome === 'throws'
          ? (() => { const s: { url: string; body: string; headers: string }[] = []; vi.stubGlobal('fetch', vi.fn(async (u: RequestInfo | URL, i?: RequestInit) => { s.push({ url: String(u), body: String(i?.body ?? ''), headers: '' }); throw new Error('network'); })); return s; })()
          : server({ record: () => outcome === 'db-error' ? new Response(JSON.stringify({ message: 'error' }), { status: 500 }) : new Response(JSON.stringify({ outcome }), { status: 200 }) });
        const res = await handle(post({ task_id: TASK, ...body }), env);
        const text = await res.text();
        expectNowhere(n, text, ...seen.map((s) => s.url + s.body + s.headers), JSON.stringify(logs));
        expect(logs, 'the function writes no log line').toHaveLength(0);
      });
    }
  }
  it('the source of the function has no console call and no URL built from the body', () => {
    const src = readFileSync(join(__dirname, '..', '..', 'supabase', 'functions', 'id-numbers', 'handler.ts'), 'utf8');
    const code = src.split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');
    expect(code).not.toMatch(/console\./);
    expect(code).not.toMatch(/\$\{[^}]*(number|body|n\.value)[^}]*\}[^`]*`\s*,\s*\{/);   // no fetch(`...${number}...`)
    const index = readFileSync(join(__dirname, '..', '..', 'supabase', 'functions', 'id-numbers', 'index.ts'), 'utf8');
    expect(index).not.toMatch(/console\./);
  });
});

describe('the app side: sending a number', () => {
  it('the number goes once, in the body, to the id-numbers function only, not cached', async () => {
    const calls: { url: string; init?: RequestInit }[] = [];
    vi.stubGlobal('fetch', vi.fn(async (u: RequestInfo | URL, init?: RequestInit) => {
      calls.push({ url: String(u), init });
      return new Response(JSON.stringify({ ok: true, kind: 'pan', last4: '234F', outcome: 'saved' }), { status: 200 });
    }));
    expect(await sendIdNumber(TASK, 'pan', PAN)).toEqual({ last4: '234F', outcome: 'saved' });
    const fnCalls = calls.filter((c) => c.url.includes('/functions/v1/id-numbers'));
    expect(fnCalls).toHaveLength(1); expect(fnCalls[0].url).not.toContain(PAN);
    expect(fnCalls[0].init?.cache).toBe('no-store'); expect(String(fnCalls[0].init?.body)).toContain(PAN);
    for (const c of calls.filter((x) => !x.url.includes('/functions/v1/id-numbers'))) expectNowhere(PAN, c.url, String(c.init?.body ?? ''));
  });
  it('a refusal becomes words from the dictionary; the error carries no number', async () => {
    for (const [code, key] of [['DUPLICATE', 'id.duplicate'], ['BAD_FORMAT', 'id.bad_format'], ['STEP_CLOSED', 'id.step_closed'], ['WHATEVER', 'id.failed']]) {
      vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ code }), { status: 409 })));
      const e = await sendIdNumber(TASK, 'aadhaar', AAD).catch((x) => x) as IdNumberError;
      expect(e).toBeInstanceOf(IdNumberError); expect(e.message).toBe(key); expect(e.idCode).toBe(code);
      expectNowhere(AAD, e.message, String(e.stack ?? ''), JSON.stringify(e));
      expect(errorText(e, (k) => en[k])).toBe(en[key]); expect(errorText(e, (k) => hi[k])).toBe(hi[key]);
    }
  });
  it('the network fails: NETWORK, in words', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => { throw new TypeError('fetch failed'); }));
    const e = await sendIdNumber(TASK, 'uan', UAN).catch((x) => x) as IdNumberError;
    expect(e.idCode).toBe('NETWORK'); expect(e.message).toBe('id.network');
  });
  it('the joiner\'s words for a duplicate are the brief\'s, in both languages', () => {
    expect(en['id.duplicate']).toBe('This number is already registered. HR has been told.');
    expect(hi['id.duplicate']).toBeTruthy(); expect(hi['id.duplicate']).not.toBe(en['id.duplicate']);
    for (const c of ['DUPLICATE', 'BAD_FORMAT', 'SIGN_IN', 'NOT_ALLOWED', 'STEP_CLOSED', 'NOT_CONFIGURED', 'NETWORK', 'FAILED']) {
      expect(en[idCodeKey(c)], c).toBeTruthy(); expect(hi[idCodeKey(c)], c).toBeTruthy();
    }
  });
  it('B7: the Aadhaar check-digit words', () => {
    expect(en['mine.bad_aadhaar']).toBe("This doesn't match an Aadhaar number (the last digit is a check digit). Please copy it again from your card.");
    expect(hi['mine.bad_aadhaar']).toBeTruthy();
  });
});

describe('free text loses anything that looks like a number before it is kept', () => {
  it('PAN, Aadhaar (with spaces), UAN, account', () => {
    const s = scrubNumbers(`my pan ABCDE1234F and aadhaar 2345 6789 0123 uan 100200300400 acct 123456789012345 ok`);
    for (const n of ['ABCDE1234F', '2345 6789 0123', '100200300400', '123456789012345']) expect(s).not.toContain(n);
    expect(s).toContain('[number removed]'); expect(s).toContain('my pan');
  });
  it('ordinary text and short numbers stay', () => {
    expect(scrubNumbers('Page 3 failed at 10:45 on 2 Oct 2026, phone ends 3210')).toBe('Page 3 failed at 10:45 on 2 Oct 2026, phone ends 3210');
  });
});

describe('the joiner screens: pure rules', () => {
  const t = (k: string) => k;
  const ok = { dob: '1995-01-01', relative_name: 'Ram', present: 'Village X', permanent: '', same: true, em_name: 'Sita', em_relation: 'mother', em_phone: '98765 43210' };
  it('Personal details: each missing part is named; a full form may be sent', () => {
    expect(personalProblem(ok, t)).toBeNull();
    expect(personalProblem({ ...ok, dob: '' }, t)).toBe('mine.need_dob');
    expect(personalProblem({ ...ok, relative_name: ' ' }, t)).toBe('mine.need_relative');
    expect(personalProblem({ ...ok, same: false }, t)).toBe('mine.need_address');
    expect(personalProblem({ ...ok, em_relation: '' }, t)).toBe('mine.need_emergency');
    expect(personalProblem({ ...ok, em_phone: '12345' }, t)).toBe('mine.bad_em_phone');
    expect(personalProblem({ ...ok, em_phone: '+91 9876543210' }, t)).toBeNull();
  });
  it('B3: while joining, a joining date today or past reads as the date, not "joined N days ago"', () => {
    expect(joinWords('onboarding', 0)).toBe('join.date'); expect(joinWords('invited', -3)).toBe('join.date');
    expect(joinWords('onboarding', 5)).toBe('join.in_days'); expect(joinWords('active', -3)).toBe('join.days_ago');
    expect(en['mine.join.date']).toContain('{d}'); expect(hi['mine.join.date']).toContain('{d}');
  });
  it('B4: an HR joiner reads HR words, others field words', () => {
    expect(joinerTrack('hr_admin')).toBe('hr'); expect(joinerTrack('hr_resource')).toBe('hr');
    expect(joinerTrack('operational')).toBe('field'); expect(joinerTrack(null)).toBe('field');
  });
  it('A2: a masked Aadhaar image waits for HR until confirmed masked; a removed one does not', () => {
    const f = (x: Partial<HrFile>) => ({ kind: 'aadhaar_masked', masked: null, removed_at: null, ...x }) as HrFile;
    expect(maskCheck(f({}))).toBe(true); expect(maskCheck(f({ masked: 'yes' as HrFile['masked'] }))).toBe(false);
    expect(maskCheck(f({ masked: 'no' as HrFile['masked'] }))).toBe(true);
    expect(maskCheck(f({ masked: 'no' as HrFile['masked'], removed_at: '2026-10-12T10:00:00Z' }))).toBe(false);
    expect(maskCheck(f({ kind: 'offer_letter' as HrFile['kind'] }))).toBe(false);
  });
});
