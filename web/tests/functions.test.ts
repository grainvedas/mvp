// The server functions and the app's dealings with them (FIX_LIST fault 32, 4 October 2026).
// On staging the database had migration 23 and the create-user function was the build of 1 October: every "New user"
// ended in "login created but not linked; both removed", with no cause named anywhere. Held here:
//   1. the function says WHY a login was not linked, and takes back what it made even when it is interrupted;
//   2. the four functions carry one build, the app knows which it needs and says so when the server is behind.
// Since the identity layer (6 October 2026) create-user makes the LOGIN for a person HR has just created through the
// database (app.add_joiner), or for a client's own login (app.add_client_viewer); it no longer inserts people or stages.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

vi.mock('../src/lib/supabase', () => ({ supabase: { from: () => ({}), auth: {}, storage: {} }, appDb: { rpc: vi.fn() }, SUPABASE_URL: 'http://srv.test', SUPABASE_ANON_KEY: 'public-key',
  configured: true, accessToken: vi.fn(async () => 'user-token') }));

import { handle, whyNotLinked, VERSION } from '../../supabase/functions/create-user/handler';
import { VERSION as RESET_VERSION, handle as handleReset } from '../../supabase/functions/reset-password/handler';
import { VERSION as LEDGER_VERSION } from '../../supabase/functions/ledger-check/handler';
import { VERSION as CODE_VERSION, handle as handleCode } from '../../supabase/functions/daily-code/handler';
import { VERSION as ID_VERSION } from '../../supabase/functions/id-numbers/handler';
import { mailConfigured, maskEmail, sendMail } from '../../supabase/functions/_shared/mail';
import { buildState, callFunction, functionState, FUNCTIONS_NEEDED } from '../src/lib/api';
import { AppError } from '../src/lib/errors';
import { errorText } from '../src/shell/ui';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';

const ROW = 'aaaaaaaa-0000-4000-8000-000000000001', LOGIN = 'bbbbbbbb-0000-4000-8000-000000000002';
const env = { SUPABASE_URL: 'http://srv.test', SUPABASE_ANON_KEY: 'public-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key' };
const post = (body: unknown) => new Request('http://fn/create-user', { method: 'POST', headers: { authorization: 'Bearer user-token', 'content-type': 'application/json' }, body: JSON.stringify(body) });
const operator = { role: 'operator', display_name: 'Sita', phone: '9876543210', client_id: 'c' };       // the request of an app from before 6 Oct
const joiner = { kind: 'joiner', full_name: 'Sita Devi', personal_email: 'Sita@Example.test', join_date: '2026-11-01', phone: '9876543210', employment_type: 'full_time' };
const viewer = { kind: 'viewer', client_id: 'cccccccc-0000-4000-8000-00000000000c', display_name: 'Buyer Desk', email: 'buyer@client.test' };
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
const madeLogin = (extra: Record<string, unknown> = {}) => ({ id: LOGIN, email: 'sita@example.test', email_confirmed_at: '2026-10-04T10:00:00Z', app_metadata: { provider: 'email', grainveda_login: true }, ...extra });

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

describe('create-user makes the login for a person the database has just created, and takes back what it made', () => {
  const routes = (over: Partial<Record<'make' | 'login' | 'check' | 'delLogin' | 'delRow' | 'note' | 'mail', () => Response | 'throw'>> = {}) =>
    (method: string, url: string): Response | 'throw' => {
      if (method === 'POST' && url.endsWith('/rest/v1/rpc/add_joiner')) return over.make?.() ?? answer(200, { id: ROW, tasks: 8, status: 'invited' });
      if (method === 'POST' && url.endsWith('/rest/v1/rpc/add_client_viewer')) return over.make?.() ?? answer(200, ROW);
      if (method === 'POST' && url.endsWith('/rest/v1/rpc/note_invite_sent')) return over.note?.() ?? answer(204, null);
      if (method === 'POST' && url.endsWith('/auth/v1/admin/users')) return over.login?.() ?? answer(200, madeLogin());
      if (method === 'GET' && url.includes('/rest/v1/app_users?id=eq.')) return over.check?.() ?? answer(200, [{ auth_uid: LOGIN, active: true }]);
      if (method === 'DELETE' && url.includes('/auth/v1/admin/users/')) return over.delLogin?.() ?? answer(200, {});
      if (method === 'DELETE' && url.includes('/rest/v1/app_users')) return over.delRow?.() ?? answer(204, null);
      if (method === 'POST' && url === 'http://mail.test/emails') return over.mail?.() ?? answer(200, { id: 'm1' });
      return answer(500, { message: `unexpected ${method} ${url}` });
    };
  const removed = (seen: string[]) => seen.filter((s) => s.startsWith('DELETE'));

  it('a joiner: the database is asked AS THE CALLER, the login is made with the mark, the invite is noted; nothing removed', async () => {
    const sent: Record<string, { body: string; auth: string }> = {};
    const fake = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input), method = init?.method ?? 'GET';
      sent[`${method} ${url.replace('http://srv.test', '')}`] = { body: String(init?.body ?? ''), auth: String((init?.headers as Record<string, string>)?.authorization ?? '') };
      return routes()(method, url) as Response;
    });
    vi.stubGlobal('fetch', fake);
    const res = await handle(post(joiner), env); const body = await res.json();
    expect(res.status).toBe(201);
    expect(body).toMatchObject({ app_user_id: ROW, login_id: LOGIN, sign_in: 'sita@example.test', invite_emailed: false });
    expect(body.temporary_password).toMatch(/^Gv-/);
    // who may create whom is the database's decision: asked with the caller's own token, never the service key
    expect(sent['POST /rest/v1/rpc/add_joiner'].auth).toBe('Bearer user-token');
    expect(JSON.parse(sent['POST /rest/v1/rpc/add_joiner'].body)).toEqual({ p: { full_name: 'Sita Devi', personal_email: 'Sita@Example.test', join_date: '2026-11-01', phone: '9876543210', employment_type: 'full_time' } });
    expect(sent['POST /auth/v1/admin/users'].auth).toBe('Bearer service-key');
    expect(JSON.parse(sent['POST /auth/v1/admin/users'].body)).toMatchObject({ email: 'sita@example.test', email_confirm: true, app_metadata: { grainveda_login: true }, user_metadata: { must_change_password: true } });
    expect(sent['POST /rest/v1/rpc/note_invite_sent'].auth).toBe('Bearer user-token');
    expect(Object.keys(sent).filter((k) => k.startsWith('DELETE'))).toEqual([]);
    // it grants nothing: no stage, no scope, no client is ever written here
    expect(Object.keys(sent).some((k) => /slot_assignments|assignments|rpc\/assign/.test(k))).toBe(false);
    expect(res.headers.get('x-grainveda-function')).toBe(VERSION);
  });
  it('a client login goes through app.add_client_viewer, with the caller\'s token', async () => {
    const seen = server(routes());
    const res = await handle(post(viewer), env);
    expect(res.status).toBe(201); expect(seen).toContain('POST /rest/v1/rpc/add_client_viewer'); expect(seen).not.toContain('POST /rest/v1/rpc/add_joiner');
  });
  it('with a mail sender set up, a note goes to the joiner, and it never carries the password', async () => {
    let mail = '';
    server((m, u, b) => { if (u === 'http://mail.test/emails') mail = b ?? ''; return routes()(m, u); });
    const res = await handle(post(joiner), { ...env, MAIL_API_URL: 'http://mail.test/emails', MAIL_API_KEY: 'k', MAIL_FROM: 'GrainVeda <no-reply@x.test>', APP_URL: 'https://app.x.test/' });
    const body = await res.json();
    expect(body.invite_emailed).toBe(true);
    expect(JSON.parse(mail)).toMatchObject({ to: ['sita@example.test'], from: 'GrainVeda <no-reply@x.test>' });
    expect(mail).toContain('https://app.x.test'); expect(mail).not.toContain(body.temporary_password);
  });
  it('the request of an app from before 6 October is told what changed, and nothing is touched', async () => {
    const seen = server(routes());
    const res = await handle(post(operator), env);
    expect(res.status).toBe(400); expect((await res.json()).error).toMatch(/now added by HR.*reload the app/); expect(seen).toEqual([]);
  });
  it('refused before the database is asked: no name, no valid email, a phone that is not a mobile number', async () => {
    const seen = server(routes());
    for (const bad of [{ ...joiner, full_name: ' ' }, { ...joiner, personal_email: 'sita' }, { ...joiner, phone: '12345' }, { kind: 'nothing' }]) {
      expect((await handle(post(bad), env)).status).toBe(400);
    }
    expect(seen).toEqual([]);
  });
  it('the database says no: its words are passed on with the right status, and no login is made', async () => {
    for (const [msg, status] of [['only HR adds a joiner', 403], ['you do not manage this client', 403], ['a person with this email or phone already exists', 409],
      ['the HR Admin seat is taken: there is exactly one', 409], ['join date is required', 400]] as const) {
      const seen = server(routes({ make: () => answer(400, { message: msg }) }));
      const res = await handle(post(joiner), env);
      expect(res.status, msg).toBe(status); expect((await res.json()).error).toBe(msg);
      expect(seen.some((x) => x.includes('/auth/v1/admin/users'))).toBe(false); expect(removed(seen)).toEqual([]);
    }
  });
  it('not linked: 500 that says why, the login and the row both removed', async () => {
    const seen = server(routes({ check: () => answer(200, [{ auth_uid: null, active: true }]), login: () => answer(200, madeLogin({ app_metadata: { provider: 'email' } })) }));
    const res = await handle(post(joiner), env); const body = await res.json();
    expect(res.status).toBe(500);
    expect(body.error).toMatch(/^login created but not linked: the login does not carry app_metadata\.grainveda_login.*; both removed$/);
    expect(removed(seen)).toEqual([`DELETE /auth/v1/admin/users/${LOGIN}`, `DELETE /rest/v1/app_users?id=eq.${ROW}`]);
    expect(console.error).toHaveBeenCalledWith(expect.stringMatching(new RegExp(`login ${LOGIN} was not linked to user row ${ROW}`)));
  });
  it('the row cannot be read back (the service key was refused): not taken for "linked"; cleaned up', async () => {
    const seen = server(routes({ check: () => answer(401, { message: 'Invalid API key' }) }));
    const res = await handle(post(joiner), env);
    expect(res.status).toBe(500); expect((await res.json()).error).toMatch(/could not be read back with the service key \(HTTP 401\); both removed/);
    expect(removed(seen)).toHaveLength(2);
  });
  it('the server stops answering after the login is made: the login and the row are still removed', async () => {
    const seen = server(routes({ check: () => 'throw' }));
    const res = await handle(post(joiner), env);
    expect(res.status).toBe(502); expect((await res.json()).error).toMatch(/did not answer while the person was being created \(fetch failed\); both removed/);
    expect(removed(seen)).toEqual([`DELETE /auth/v1/admin/users/${LOGIN}`, `DELETE /rest/v1/app_users?id=eq.${ROW}`]);
  });
  it('the Auth server stops answering before a login exists: only the row is removed', async () => {
    const seen = server(routes({ login: () => 'throw' }));
    const res = await handle(post(joiner), env);
    expect(res.status).toBe(502); expect(removed(seen)).toEqual([`DELETE /rest/v1/app_users?id=eq.${ROW}`]);
  });
  it('a login that cannot be removed is tried twice, then named, never passed over in silence', async () => {
    const seen = server(routes({ check: () => answer(200, [{ auth_uid: null, active: true }]), delLogin: () => answer(500, { msg: 'down' }) }));
    const body = await (await handle(post(joiner), env)).json();
    expect(removed(seen).filter((x) => x.includes('/auth/'))).toHaveLength(2);
    expect(body.error).toMatch(new RegExp(`COULD NOT REMOVE login ${LOGIN}: remove by hand`));
    expect(body.error).not.toMatch(/both removed/);
    expect(removed(seen)).toContain(`DELETE /rest/v1/app_users?id=eq.${ROW}`);          // the row still goes
  });
  it('a login the Auth server no longer knows counts as removed', async () => {
    server(routes({ check: () => answer(200, [{ auth_uid: null, active: true }]), delLogin: () => answer(404, { msg: 'User not found' }) }));
    expect((await (await handle(post(joiner), env)).json()).error).toMatch(/both removed$/);
  });
  it('the email is already registered with the Auth server: 409, the row removed, no login to remove', async () => {
    const seen = server(routes({ login: () => answer(422, { msg: 'A user with this email address has already been registered' }) }));
    const res = await handle(post(joiner), env);
    expect(res.status).toBe(409); expect(removed(seen)).toEqual([`DELETE /rest/v1/app_users?id=eq.${ROW}`]);
  });
  it('the audit note failing does not undo a person who was made', async () => {
    const seen = server(routes({ note: () => 'throw' }));
    const res = await handle(post(joiner), env);
    expect(res.status).toBe(201); expect(removed(seen)).toEqual([]);
  });
});

describe('the once-a-day sign-in code: built, and off until a sender exists', () => {
  const mailEnv = { ...env, MAIL_API_URL: 'http://mail.test/emails', MAIL_API_KEY: 'k', MAIL_FROM: 'GrainVeda <no-reply@x.test>' };
  const postCode = (token = 'user-token') => new Request('http://fn/daily-code', { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: '{}' });
  const routes = (over: Partial<Record<'who' | 'draw' | 'mail', () => Response | 'throw'>> = {}) => (method: string, url: string): Response | 'throw' => {
    if (method === 'GET' && url.endsWith('/auth/v1/user')) return over.who?.() ?? answer(200, { id: LOGIN });
    if (method === 'POST' && url.endsWith('/rest/v1/rpc/issue_daily_code')) return over.draw?.() ?? answer(200, { code: '482913', email: 'sita@example.test', name: 'Sita', minutes: 10 });
    if (method === 'POST' && url === 'http://mail.test/emails') return over.mail?.() ?? answer(200, { id: 'm1' });
    return answer(500, { message: `unexpected ${method} ${url}` });
  };
  it('says whether a sender is set up, to anyone who asks', async () => {
    expect(await (await handleCode(new Request('http://fn/daily-code'), env)).json()).toEqual({ function: 'daily-code', version: VERSION, sender: false });
    expect((await (await handleCode(new Request('http://fn/daily-code'), mailEnv)).json()).sender).toBe(true);
    expect(mailConfigured({ MAIL_API_URL: 'x', MAIL_API_KEY: 'y' })).toBe(false);
  });
  it('no sender: 503, and no code is drawn at all', async () => {
    const seen = server(routes());
    const res = await handleCode(postCode(), env);
    expect(res.status).toBe(503); expect(seen.some((x) => x.includes('issue_daily_code'))).toBe(false);
  });
  it('the code is drawn with the service key for the person the token belongs to, mailed, and never returned', async () => {
    const sent: Record<string, { body: string; auth: string }> = {};
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input), method = init?.method ?? 'GET';
      sent[`${method} ${url.replace('http://srv.test', '')}`] = { body: String(init?.body ?? ''), auth: String((init?.headers as Record<string, string>)?.authorization ?? '') };
      return routes()(method, url) as Response;
    }));
    const res = await handleCode(postCode(), mailEnv); const text = await res.text();
    expect(res.status).toBe(200); expect(JSON.parse(text)).toEqual({ sent: true, to: 's•••@example.test', minutes: 10 });
    expect(text).not.toContain('482913');
    expect(sent['GET /auth/v1/user'].auth).toBe('Bearer user-token');
    expect(sent['POST /rest/v1/rpc/issue_daily_code']).toEqual({ body: JSON.stringify({ p_auth_uid: LOGIN }), auth: 'Bearer service-key' });
    expect(JSON.parse(sent['POST http://mail.test/emails'].body)).toMatchObject({ to: ['sita@example.test'], subject: '482913 is your GrainVeda sign-in code' });
    expect(res.headers.get('cache-control')).toBe('no-store');
  });
  it('a token the Auth server does not know: 401, nothing drawn, nothing sent', async () => {
    const seen = server(routes({ who: () => answer(401, { msg: 'invalid JWT' }) }));
    expect((await handleCode(postCode('forged'), mailEnv)).status).toBe(401);
    expect((await handleCode(postCode('public-key'), mailEnv)).status).toBe(401);
    expect(seen.filter((x) => !x.includes('/auth/v1/user'))).toEqual([]);
  });
  it('the database\'s refusals keep their meaning: too soon 429, no email 409, nobody 403', async () => {
    for (const [msg, status] of [['a code was sent less than a minute ago', 429], ['this person has no email to send a code to', 409], ['no such person', 403]] as const) {
      const seen = server(routes({ draw: () => answer(400, { message: msg }) }));
      expect((await handleCode(postCode(), mailEnv)).status, msg).toBe(status);
      expect(seen.some((x) => x.includes('mail.test'))).toBe(false);
    }
  });
  it('the mail service fails: 502 that says so (the person asks again)', async () => {
    server(routes({ mail: () => answer(500, {}) }));
    const res = await handleCode(postCode(), mailEnv);
    expect(res.status).toBe(502); expect((await res.json()).error).toMatch(/could not be sent: the mail service answered 500/);
    server(routes({ mail: () => 'throw' }));
    expect((await sendMail(mailEnv, { to: 'a@b.c', subject: 's', text: 't' })).ok).toBe(false);
  });
  it('an address is masked for the screen', () => {
    expect(maskEmail('grainvedas+hr@gmail.com')).toBe('g•••@gmail.com'); expect(maskEmail('nonsense')).toBe('•••');
  });
});

describe('one build for the five functions, known to the app', () => {
  it('the five handlers carry the same build, and it is the one the app needs', () => {
    expect(ID_VERSION).toBe(VERSION); expect(RESET_VERSION).toBe(VERSION); expect(LEDGER_VERSION).toBe(VERSION); expect(CODE_VERSION).toBe(VERSION);
    expect(VERSION).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(VERSION >= FUNCTIONS_NEEDED, 'the app must not need a newer build than the repository holds').toBe(true);
  });
  it('every answer says which build it is, and a page may read it', async () => {
    for (const [h, name] of [[handle, 'create-user'], [handleReset, 'reset-password'], [handleCode, 'daily-code']] as const) {
      const get = await h(new Request('http://fn/x'), env);
      expect(get.status).toBe(200); expect(await get.json()).toMatchObject({ function: name, version: VERSION });
      for (const res of [get, await h(new Request('http://fn/x', { method: 'OPTIONS' }), env), await h(new Request('http://fn/x', { method: 'POST', body: '{}' }), env)]) {
        expect(res.headers.get('x-grainveda-function')).toBe(VERSION);
        expect(res.headers.get('access-control-expose-headers')).toContain('x-grainveda-function');
      }
    }
  });
  it('the check script and the deploy steps name all five', () => {
    const script = readFileSync(join(__dirname, '..', '..', 'scripts', 'check_functions.mjs'), 'utf8');
    for (const n of ['create-user', 'reset-password', 'ledger-check', 'daily-code', 'id-numbers']) expect(script).toContain(`'${n}'`);
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
  it('the Add joiner page asks before anyone fills in the form', async () => {
    server(() => answer(405, { error: 'POST only' })); expect(await functionState('create-user')).toBe('outdated');
    server(() => answer(200, { function: 'create-user', version: FUNCTIONS_NEEDED })); expect(await functionState('create-user')).toBe('ok');   // read from the answer when the header is withheld
    server(() => answer(200, {}, { 'x-grainveda-function': FUNCTIONS_NEEDED })); expect(await functionState('create-user')).toBe('ok');
  });
});
