// The server functions and the app's dealings with them (FIX_LIST fault 32, 4 October 2026).
// On staging the database had migration 23 and the create-user function was the build of 1 October: every "New user"
// ended in "login created but not linked; both removed", with no cause named anywhere. Held here:
//   1. the function says WHY a login was not linked, and takes back what it made even when it is interrupted;
//   2. the three functions carry one build, the app knows which it needs and says so when the server is behind.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

vi.mock('../src/lib/supabase', () => ({ supabase: { from: () => ({}), auth: {}, storage: {} }, appDb: { rpc: vi.fn() }, SUPABASE_URL: 'http://srv.test', SUPABASE_ANON_KEY: 'public-key',
  configured: true, accessToken: vi.fn(async () => 'user-token') }));

import { handle, whyNotLinked, VERSION } from '../../supabase/functions/create-user/handler';
import { VERSION as RESET_VERSION, handle as handleReset } from '../../supabase/functions/reset-password/handler';
import { VERSION as LEDGER_VERSION } from '../../supabase/functions/ledger-check/handler';
import { buildState, callFunction, functionState, FUNCTIONS_NEEDED } from '../src/lib/api';
import { AppError } from '../src/lib/errors';
import { errorText } from '../src/shell/ui';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';

const ROW = 'aaaaaaaa-0000-4000-8000-000000000001', LOGIN = 'bbbbbbbb-0000-4000-8000-000000000002';
const env = { SUPABASE_URL: 'http://srv.test', SUPABASE_ANON_KEY: 'public-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key' };
const post = (body: unknown) => new Request('http://fn/create-user', { method: 'POST', headers: { authorization: 'Bearer user-token', 'content-type': 'application/json' }, body: JSON.stringify(body) });
const operator = { role: 'operator', display_name: 'Sita', phone: '9876543210', client_id: 'c' };
const answer = (status: number, body: unknown, headers: Record<string, string> = {}) => new Response(body === null ? null : JSON.stringify(body), { status, headers });

/** A server made of the answers a test gives it. Every request is kept, so a test can ask what was removed. */
function server(routes: (method: string, url: string, body: string | null) => Response | Promise<Response> | 'throw') {
  const seen: string[] = [];
  const fake = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input), method = init?.method ?? 'GET';
    seen.push(`${method} ${url.replace('http://srv.test', '')}`);
    const r = routes(method, url, typeof init?.body === 'string' ? init.body : null);
    if (r === 'throw') throw new TypeError('fetch failed');
    return r;
  });
  vi.stubGlobal('fetch', fake);
  return seen;
}
const madeLogin = (extra: Record<string, unknown> = {}) => ({ id: LOGIN, phone: '919876543210', phone_confirmed_at: '2026-10-04T10:00:00Z', app_metadata: { provider: 'phone', grainveda_login: true }, ...extra });

beforeEach(() => { vi.spyOn(console, 'error').mockImplementation(() => {}); });
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });

describe('why a login was not linked (the database declines without an error)', () => {
  const login = madeLogin();
  it('linked: nothing to say', () => expect(whyNotLinked(login, { auth_uid: LOGIN, active: true }, ROW)).toBeNull());
  it('the fault of 4 October: a login without the mark, as the function of 1 October made it', () => {
    expect(whyNotLinked({ ...login, app_metadata: { provider: 'phone' } }, { auth_uid: null, active: true }, ROW)).toMatch(/does not carry app_metadata\.grainveda_login.*migration 23/);
    expect(whyNotLinked({ ...login, app_metadata: null }, { auth_uid: ROW, active: true }, ROW)).toMatch(/grainveda_login/);
    expect(whyNotLinked({ ...login, app_metadata: { grainveda_login: 'true' } }, { auth_uid: null, active: true }, ROW)).toMatch(/grainveda_login/);   // the mark is the boolean
  });
  it('each other reason, in the order the trigger checks them', () => {
    expect(whyNotLinked({ id: LOGIN, phone: '91…', app_metadata: { grainveda_login: true } }, { auth_uid: null, active: true }, ROW)).toMatch(/no confirmed phone or email/);
    expect(whyNotLinked(login, { auth_uid: null, active: false }, ROW)).toMatch(/not active/);
    expect(whyNotLinked(login, { auth_uid: 'cccccccc-0000-4000-8000-000000000003', active: true }, ROW)).toMatch(/already linked to another login/);
    expect(whyNotLinked(login, { auth_uid: null, active: true }, ROW)).toMatch(/declined the link.*Postgres log/);
    expect(whyNotLinked(login, { auth_uid: ROW, active: true }, ROW)).toMatch(/declined the link/);      // the seed's placeholder (auth_uid = id) is "unlinked"
    expect(whyNotLinked(login, undefined, ROW)).toMatch(/could not be read back/);
  });
});

describe('create-user takes back what it made', () => {
  const routes = (over: Partial<Record<'slot' | 'login' | 'check' | 'delLogin' | 'delRow', () => Response | 'throw'>> = {}) =>
    (method: string, url: string): Response | 'throw' => {
      if (method === 'POST' && url.endsWith('/rest/v1/app_users')) return answer(201, [{ id: ROW }]);
      if (method === 'POST' && url.endsWith('/rest/v1/slot_assignments')) return over.slot?.() ?? answer(201, [{}]);
      if (method === 'POST' && url.endsWith('/auth/v1/admin/users')) return over.login?.() ?? answer(200, madeLogin());
      if (method === 'GET' && url.includes('/rest/v1/app_users?id=eq.')) return over.check?.() ?? answer(200, [{ auth_uid: LOGIN, active: true }]);
      if (method === 'DELETE' && url.includes('/auth/v1/admin/users/')) return over.delLogin?.() ?? answer(200, {});
      if (method === 'DELETE' && url.includes('/rest/v1/app_users')) return over.delRow?.() ?? answer(204, null);
      return answer(500, { message: `unexpected ${method} ${url}` });
    };
  const removed = (seen: string[]) => seen.filter((s) => s.startsWith('DELETE'));

  it('linked: 201, nothing removed, and the login was made with the mark', async () => {
    let sent = '';
    const seen = server((m, u, b) => { if (m === 'POST' && u.endsWith('/auth/v1/admin/users')) sent = b ?? ''; return routes()(m, u); });
    const res = await handle(post(operator), env);
    expect(res.status).toBe(201); expect(removed(seen)).toEqual([]);
    expect(JSON.parse(sent)).toMatchObject({ phone: '919876543210', phone_confirm: true, app_metadata: { grainveda_login: true }, user_metadata: { must_change_password: true } });
    expect(res.headers.get('x-grainveda-function')).toBe(VERSION);
  });
  it('not linked: 500 that says why, the login and the row both removed', async () => {
    const seen = server(routes({ check: () => answer(200, [{ auth_uid: null, active: true }]), login: () => answer(200, madeLogin({ app_metadata: { provider: 'phone' } })) }));
    const res = await handle(post(operator), env); const body = await res.json();
    expect(res.status).toBe(500);
    expect(body.error).toMatch(/^login created but not linked: the login does not carry app_metadata\.grainveda_login.*; both removed$/);
    expect(removed(seen)).toEqual([`DELETE /auth/v1/admin/users/${LOGIN}`, `DELETE /rest/v1/app_users?id=eq.${ROW}`]);
    expect(console.error).toHaveBeenCalledWith(expect.stringMatching(new RegExp(`login ${LOGIN} was not linked to user row ${ROW}`)));
  });
  it('the row cannot be read back (the service key was refused): not taken for "linked"; cleaned up', async () => {
    const seen = server(routes({ check: () => answer(401, { message: 'Invalid API key' }) }));
    const res = await handle(post(operator), env);
    expect(res.status).toBe(500); expect((await res.json()).error).toMatch(/could not be read back with the service key \(HTTP 401\); both removed/);
    expect(removed(seen)).toHaveLength(2);
  });
  it('the server stops answering after the login is made: the login and the row are still removed', async () => {
    const seen = server(routes({ check: () => 'throw' }));
    const res = await handle(post(operator), env);
    expect(res.status).toBe(502); expect((await res.json()).error).toMatch(/did not answer while the person was being created \(fetch failed\); both removed/);
    expect(removed(seen)).toEqual([`DELETE /auth/v1/admin/users/${LOGIN}`, `DELETE /rest/v1/app_users?id=eq.${ROW}`]);
  });
  it('the Auth server stops answering before a login exists: only the row is removed', async () => {
    const seen = server(routes({ login: () => 'throw' }));
    const res = await handle(post(operator), env);
    expect(res.status).toBe(502); expect(removed(seen)).toEqual([`DELETE /rest/v1/app_users?id=eq.${ROW}`]);
  });
  it('a login that cannot be removed is tried twice, then named, never passed over in silence', async () => {
    const seen = server(routes({ check: () => answer(200, [{ auth_uid: null, active: true }]), delLogin: () => answer(500, { msg: 'down' }) }));
    const body = await (await handle(post(operator), env)).json();
    expect(removed(seen).filter((s) => s.includes('/auth/'))).toHaveLength(2);
    expect(body.error).toMatch(new RegExp(`COULD NOT REMOVE login ${LOGIN}: remove by hand`));
    expect(body.error).not.toMatch(/both removed/);
    expect(removed(seen)).toContain(`DELETE /rest/v1/app_users?id=eq.${ROW}`);          // the row still goes
  });
  it('a login the Auth server no longer knows counts as removed', async () => {
    server(routes({ check: () => answer(200, [{ auth_uid: null, active: true }]), delLogin: () => answer(404, { msg: 'User not found' }) }));
    expect((await (await handle(post(operator), env)).json()).error).toMatch(/both removed$/);
  });
  it('the phone is already registered: 409, the row removed, no login to remove', async () => {
    const seen = server(routes({ login: () => answer(422, { msg: 'Phone number already registered by another user' }) }));
    const res = await handle(post(operator), env);
    expect(res.status).toBe(409); expect(removed(seen)).toEqual([`DELETE /rest/v1/app_users?id=eq.${ROW}`]);
  });
  it('a refused stage assignment: 403, the row removed, no login made', async () => {
    const seen = server(routes({ slot: () => answer(403, { message: 'new row violates row-level security policy' }) }));
    const res = await handle(post({ ...operator, slot: { scope_id: 's', stage_type: 'qc' } }), env);
    expect(res.status).toBe(403); expect(seen.some((s) => s.includes('/auth/v1/admin/users'))).toBe(false);
    expect(removed(seen)).toEqual([`DELETE /rest/v1/app_users?id=eq.${ROW}`]);
  });
});

describe('one build for the three functions, known to the app', () => {
  it('the three handlers carry the same build, and it is the one the app needs', () => {
    expect(RESET_VERSION).toBe(VERSION); expect(LEDGER_VERSION).toBe(VERSION);
    expect(VERSION).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(VERSION >= FUNCTIONS_NEEDED, 'the app must not need a newer build than the repository holds').toBe(true);
  });
  it('every answer says which build it is, and a page may read it', async () => {
    for (const [h, name] of [[handle, 'create-user'], [handleReset, 'reset-password']] as const) {
      const get = await h(new Request('http://fn/x'), env);
      expect(get.status).toBe(200); expect(await get.json()).toEqual({ function: name, version: VERSION });
      for (const res of [get, await h(new Request('http://fn/x', { method: 'OPTIONS' }), env), await h(new Request('http://fn/x', { method: 'POST', body: '{}' }), env)]) {
        expect(res.headers.get('x-grainveda-function')).toBe(VERSION);
        expect(res.headers.get('access-control-expose-headers')).toContain('x-grainveda-function');
      }
    }
  });
  it('the check script and the deploy steps name all three', () => {
    const script = readFileSync(join(__dirname, '..', '..', 'scripts', 'check_functions.mjs'), 'utf8');
    for (const n of ['create-user', 'reset-password', 'ledger-check']) expect(script).toContain(`'${n}'`);
  });
  it('what an answer says about the build', () => {
    expect(buildState(FUNCTIONS_NEEDED)).toBe('ok'); expect(buildState('2099-01-01')).toBe('ok');
    for (const old of [null, undefined, '', '2026-10-01', 'yes']) expect(buildState(old), String(old)).toBe('outdated');
  });
});

describe('the app, with a server whose functions were left behind', () => {
  const OLD = 'login created but not linked; both removed';
  it('the function of 1 October fails inside: the person is told it is the server, with the function\'s own words kept', async () => {
    server((m) => m === 'POST' ? answer(500, { error: OLD }) : answer(405, { error: 'POST only' }));
    const e = await callFunction('create-user', operator).catch((x) => x) as AppError;
    expect(e).toBeInstanceOf(AppError); expect(e.kind).toBe('setup'); expect(e.code).toBe('FN_OUTDATED');
    const shown = errorText(e, (k) => en[k]);
    expect(shown).toContain('Nothing is wrong with what you entered'); expect(shown).toContain('run-sheet step A6'); expect(shown).toContain(OLD);
    expect(errorText(e, (k) => hi[k])).toContain('रन-शीट चरण A6');
  });
  it('a function that is not deployed looks like "no network" to a browser: told apart by asking the server', async () => {
    server((_m, url) => url.includes('/functions/v1/') ? 'throw' : answer(200, {}));
    const e = await callFunction('reset-password', {}).catch((x) => x) as AppError;
    expect(e.kind).toBe('setup'); expect(e.code).toBe('FN_MISSING'); expect(errorText(e, (k) => en[k])).toContain('not installed');
    expect(await functionState('reset-password')).toBe('missing');
  });
  it('really no network: still "no connection", and the state is unknown, not "missing"', async () => {
    server(() => 'throw');
    const e = await callFunction('create-user', operator).catch((x) => x) as AppError;
    expect(e.kind).toBe('network'); expect(await functionState('create-user')).toBe('unknown');
  });
  it('a current function\'s own failure, and any refusal of the person\'s request, are shown as they are', async () => {
    server(() => answer(500, { error: 'login created but not linked: the user row is not active; both removed' }, { 'x-grainveda-function': FUNCTIONS_NEEDED }));
    expect((await callFunction('create-user', operator).catch((x) => x) as AppError).kind).toBe('other');
    server((m) => m === 'POST' ? answer(409, { error: 'a user with this phone or email already exists' }) : answer(405, {}));
    const dup = await callFunction('create-user', operator).catch((x) => x) as AppError;
    expect(dup.kind).not.toBe('setup'); expect(dup.message).toMatch(/already exists/);
  });
  it('the Users page asks before anyone fills in the form', async () => {
    server(() => answer(405, { error: 'POST only' })); expect(await functionState('create-user')).toBe('outdated');
    server(() => answer(200, { function: 'create-user', version: FUNCTIONS_NEEDED })); expect(await functionState('create-user')).toBe('ok');   // read from the answer when the header is withheld
    server(() => answer(200, {}, { 'x-grainveda-function': FUNCTIONS_NEEDED })); expect(await functionState('create-user')).toBe('ok');
  });
});
