// Migration 38 (brief "Onboarding at scale", decisions "as recommended"): the invite server function. The token is never
// sent to the database (only its SHA-256), never put where a web server logs it (the link carries it after #), never
// logged; a joiner without a sign-in gets one when they accept (a bulk-imported joiner, decision 4).
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { appBase, handle, inviteLink, inviteText, newToken, sha256Hex, tokenShape, VERSION } from '../../supabase/functions/invite/handler';
import { VERSION as CREATE_VERSION } from '../../supabase/functions/create-user/handler';

const env = { SUPABASE_URL: 'http://srv.test', SUPABASE_ANON_KEY: 'public-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key' };
const mailEnv = { ...env, MAIL_API_URL: 'http://mail.test/emails', MAIL_API_KEY: 'mk', MAIL_FROM: 'GrainVeda <no-reply@x.test>' };
const P1 = 'aaaaaaaa-0000-4000-8000-000000000001', P2 = 'aaaaaaaa-0000-4000-8000-000000000002', HR = 'bbbbbbbb-0000-4000-8000-000000000017';
const req = (body: unknown, token = 'hr-token', origin = 'https://app.test') =>
  new Request('http://fn/invite', { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', origin }, body: JSON.stringify(body) });

type Seen = { url: string; method: string; body: string; headers: string };
function server(routes: Record<string, (body: Record<string, unknown>, method: string) => Response>) {
  const seen: Seen[] = [];
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input), body = typeof init?.body === 'string' ? init.body : '';
    seen.push({ url, method: init?.method ?? 'GET', body, headers: JSON.stringify(init?.headers ?? {}) });
    const key = Object.keys(routes).find((k) => url.includes(k));
    if (!key) return new Response('{}', { status: 404 });
    return routes[key](body ? JSON.parse(body) : {}, init?.method ?? 'GET');
  }));
  return seen;
}
const ok = (x: unknown) => new Response(JSON.stringify(x), { status: 200 });

let logs: unknown[][] = [];
beforeEach(() => { logs = []; for (const m of ['log', 'info', 'warn', 'error', 'debug'] as const) vi.spyOn(console, m).mockImplementation((...a: unknown[]) => { logs.push(a); }); });
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });

describe('tokens and links', () => {
  it('a token is 32 random bytes, base64url; two are never alike', () => {
    const a = newToken(), b = newToken();
    expect(tokenShape(a)).toBe(true); expect(a).not.toBe(b);
    for (const bad of ['', 'short', 'x'.repeat(44), 42, null, 'a/b+c'.padEnd(43, 'x')]) expect(tokenShape(bad), String(bad)).toBe(false);
  });
  it('SHA-256 in hex', async () => expect(await sha256Hex('abc')).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'));
  it('the link carries the token after #, so no web server receives it', () => {
    expect(inviteLink('https://app.test', 'T'.repeat(43))).toBe(`https://app.test/invite#${'T'.repeat(43)}`);
  });
  it('the app is APP_URL when set, else the asking page\'s origin (a real one only)', () => {
    expect(appBase({ APP_URL: 'https://grainveda.test/' }, 'https://other.test')).toBe('https://grainveda.test');
    expect(appBase({}, 'http://127.0.0.1:5173')).toBe('http://127.0.0.1:5173');
    expect(appBase({}, 'javascript:alert(1)')).toBe(''); expect(appBase({}, null)).toBe('');
  });
  it('the email: first name, the link, until when, and a Hindi line', () => {
    const t = inviteText('Sita Devi', 'https://app.test/invite#x', '2026-10-15T06:30:00Z');
    expect(t).toContain('Hello Sita,'); expect(t).toContain('https://app.test/invite#x'); expect(t).toContain('15 Oct 2026'); expect(t).toContain('नमस्ते Sita');
  });
});

describe('send', () => {
  const routes = (extra: Record<string, (b: Record<string, unknown>) => Response> = {}) => ({
    'rpc/invite_targets': () => ok({ actor: HR, people: [{ id: P1, name: 'Sita Devi', email: 'sita@x.test' }, { id: P2, name: 'Ram Lal', email: 'ram@x.test' }],
                                       skipped: [{ id: 'z', reason: 'not_joining' }] }),
    'rpc/record_invite': () => ok({ id: 'inv-1', expires_at: '2026-10-15T06:30:00Z' }),
    'rpc/mark_invite_sent': () => ok(null),
    'mail.test': () => ok({ id: 'm' }),
    ...extra,
  });
  it('the database decides whom, as the caller; one link each; the token never reaches the database', async () => {
    const seen = server(routes());
    const res = await handle(req({ action: 'send', employee_ids: [P1, P2] }), env);
    expect(res.status).toBe(200);
    const body = await res.json() as { results: { id: string; link: string; sent: string }[]; skipped: unknown[]; mail: boolean };
    expect(body.results.map((r) => r.sent)).toEqual(['not_sent', 'not_sent']);                // no sender: HR copies the links
    expect(body.mail).toBe(false); expect(body.skipped).toHaveLength(1);
    const target = seen.find((s) => s.url.endsWith('rpc/invite_targets'))!;
    expect(target.headers).toContain('Bearer hr-token'); expect(target.headers).not.toContain('service-key');
    for (const r of body.results) {
      const tok = r.link.split('#')[1];
      expect(r.link).toBe(`https://app.test/invite#${tok}`); expect(tokenShape(tok)).toBe(true);
      for (const s of seen) expect(s.url + s.body, 'the token went to the database').not.toContain(tok);
      const rec = seen.find((s) => s.url.endsWith('rpc/record_invite') && JSON.parse(s.body).p_employee === r.id)!;
      expect(JSON.parse(rec.body).p_hash).toBe(await sha256Hex(tok)); expect(rec.headers).toContain('Bearer service-key');
    }
    expect(logs).toHaveLength(0);
  });
  it('with a sender: the link goes to the joiner by email, and the invite is marked sent', async () => {
    const seen = server(routes());
    const body = await (await handle(req({ action: 'send', employee_ids: [P1, P2] }), mailEnv)).json() as { results: { link: string; sent: string }[] };
    expect(body.results.map((r) => r.sent)).toEqual(['email', 'email']);
    const mails = seen.filter((s) => s.url.includes('mail.test'));
    expect(mails).toHaveLength(2); expect(mails[0].body).toContain(body.results[0].link); expect(JSON.parse(mails[0].body).to).toEqual(['sita@x.test']);
    expect(seen.filter((s) => s.url.endsWith('rpc/mark_invite_sent'))).toHaveLength(2);
  });
  it('the mail service fails: "failed", and HR still has the link', async () => {
    server(routes({ 'mail.test': () => new Response('{}', { status: 500 }) }));
    const body = await (await handle(req({ action: 'send', employee_ids: [P1] }), mailEnv)).json() as { results: { link: string; sent: string }[] };
    expect(body.results[0].sent).toBe('failed'); expect(body.results[0].link).toMatch(/#/);
  });
  it('signed out, not HR, nobody, or too many at once: refused before anything is made', async () => {
    let seen = server(routes());
    expect((await handle(req({ action: 'send', employee_ids: [P1] }, ''), env)).status).toBe(401);
    expect((await handle(req({ action: 'send', employee_ids: [P1] }, 'public-key'), env)).status).toBe(401);
    expect((await handle(req({ action: 'send', employee_ids: [] }), env)).status).toBe(400);
    expect((await handle(req({ action: 'send', employee_ids: Array(101).fill(P1) }), env)).status).toBe(400);
    expect(seen).toHaveLength(0);
    seen = server(routes({ 'rpc/invite_targets': () => new Response(JSON.stringify({ message: 'only HR sends invites' }), { status: 403 }) }));
    expect(await (await handle(req({ action: 'send', employee_ids: [P1] }), env)).json()).toEqual({ code: 'NOT_ALLOWED' });
    expect(seen.some((s) => s.url.includes('record_invite'))).toBe(false);
  });
});

describe('check and accept', () => {
  const tok = 'A'.repeat(43);
  const lookup = (state: string, login: string | null = null) => ok({ state, invite_id: 'inv-1', employee_id: P1, name: 'Sita Devi', email: 'sita@x.test', login_id: login });
  it('check: the first name and the address masked, nothing more; the lookup is by hash', async () => {
    const seen = server({ 'rpc/invite_lookup': () => lookup('ok') });
    const r = await (await handle(req({ action: 'check', token: tok }, ''), env)).json();
    expect(r).toEqual({ state: 'ok', first_name: 'Sita', email_masked: 's•••@x.test' });
    expect(JSON.parse(seen[0].body).p_hash).toBe(await sha256Hex(tok)); expect(seen[0].body).not.toContain(tok);
  });
  it('check: a used, expired or replaced link says so; a malformed one is "not found" without asking', async () => {
    for (const st of ['used', 'expired', 'revoked', 'not_found']) {
      server({ 'rpc/invite_lookup': () => lookup(st) });
      expect((await (await handle(req({ action: 'check', token: tok }, ''), env)).json()).state).toBe(st);
    }
    const seen = server({});
    expect(await (await handle(req({ action: 'check', token: 'nope' }, ''), env)).json()).toEqual({ state: 'not_found' });
    expect(seen).toHaveLength(0);
  });
  it('accept, no sign-in yet (bulk import): the sign-in is made with the joiner\'s password, linked, the invite used', async () => {
    let made: Record<string, unknown> = {};
    const seen = server({
      'rpc/invite_lookup': () => lookup('ok'),
      'auth/v1/admin/users': (b) => { made = b; return ok({ id: 'login-9' }); },
      'rest/v1/app_users': () => ok([{ auth_uid: 'login-9' }]),
      'rpc/use_invite': () => ok(null),
    });
    const r = await handle(req({ action: 'accept', token: tok, password: 'Own-pass-123' }, ''), env);
    expect(r.status).toBe(200); expect(await r.json()).toEqual({ sign_in: 'sita@x.test' });
    expect(made).toMatchObject({ email: 'sita@x.test', email_confirm: true, app_metadata: { grainveda_login: true }, user_metadata: { must_change_password: false } });
    expect(seen.map((s) => s.url.replace('http://srv.test', ''))).toContain('/rest/v1/rpc/use_invite');
    expect(JSON.stringify(logs)).not.toContain('Own-pass-123');
  });
  it('accept, a sign-in exists (Add joiner): its password is replaced by the joiner\'s own', async () => {
    const seen = server({
      'rpc/invite_lookup': () => lookup('ok', 'login-7'),
      'auth/v1/admin/users/login-7': (_b, m) => ok(m === 'GET' ? { user_metadata: { display_name: 'Sita' } } : {}),
      'rpc/use_invite': () => ok(null),
    });
    expect((await handle(req({ action: 'accept', token: tok, password: 'Own-pass-123' }, ''), env)).status).toBe(200);
    const put = seen.find((s) => s.method === 'PUT')!;
    expect(JSON.parse(put.body)).toEqual({ password: 'Own-pass-123', user_metadata: { display_name: 'Sita', must_change_password: false } });
  });
  it('accept: the sign-in made but not linked is taken back', async () => {
    const seen = server({
      'rpc/invite_lookup': () => lookup('ok'),
      'auth/v1/admin/users': (_b, m) => ok(m === 'DELETE' ? {} : { id: 'login-9' }),
      'rest/v1/app_users': () => ok([{ auth_uid: null }]),
    });
    const r = await handle(req({ action: 'accept', token: tok, password: 'Own-pass-123' }, ''), env);
    expect(r.status).toBe(502); expect(await r.json()).toEqual({ code: 'NOT_LINKED' });
    expect(seen.some((s) => s.method === 'DELETE' && s.url.endsWith('/admin/users/login-9'))).toBe(true);
    expect(seen.some((s) => s.url.includes('use_invite'))).toBe(false);
  });
  it('accept: a short password, or a dead link, is refused before any sign-in is touched', async () => {
    let seen = server({ 'rpc/invite_lookup': () => lookup('ok') });
    expect(await (await handle(req({ action: 'accept', token: tok, password: 'short' }, ''), env)).json()).toEqual({ code: 'WEAK_PASSWORD' });
    expect(seen).toHaveLength(0);
    seen = server({ 'rpc/invite_lookup': () => lookup('expired') });
    const r = await handle(req({ action: 'accept', token: tok, password: 'Own-pass-123' }, ''), env);
    expect(r.status).toBe(410); expect(await r.json()).toEqual({ code: 'EXPIRED' });
    expect(seen.some((s) => s.url.includes('/auth/v1/'))).toBe(false);
  });
});

describe('reminders, and the build', () => {
  it('only HR starts a round; with no sender nothing is sent', async () => {
    let seen = server({ 'rpc/may_send_messages': () => ok(false) });
    expect((await handle(req({ action: 'reminders' }), env)).status).toBe(403);
    expect(seen.some((s) => s.url.includes('queue_reminders'))).toBe(false);
    seen = server({ 'rpc/may_send_messages': () => ok(true), 'rpc/queue_reminders': () => ok(3) });
    expect(await (await handle(req({ action: 'reminders' }), env)).json()).toEqual({ queued: 3, sent: 0, failed: 0, mail: false });
    expect(seen.some((s) => s.url.includes('messages_to_send'))).toBe(false);
  });
  it('with a sender: what is queued is sent, {app} filled in, each marked', async () => {
    const seen = server({ 'rpc/may_send_messages': () => ok(true), 'rpc/queue_reminders': () => ok(1),
      'rpc/messages_to_send': () => ok([{ id: 5, to_email: 'sita@x.test', subject: 's', body: 'open {app}/onboarding' }]),
      'mail.test': () => ok({}), 'rpc/mark_message': () => ok(null) });
    expect(await (await handle(req({ action: 'reminders' }), mailEnv)).json()).toEqual({ queued: 1, sent: 1, failed: 0, mail: true });
    expect(seen.find((s) => s.url.includes('mail.test'))!.body).toContain('open https://app.test/onboarding');
  });
  it('GET: the build and whether a sender is set up; the same build as the other five', async () => {
    expect(await (await handle(new Request('http://fn/invite'), env)).json()).toEqual({ function: 'invite', version: VERSION, mail: false });
    expect(VERSION).toBe(CREATE_VERSION);
  });
  it('the function writes no log line (nothing secret can end up in one)', () => {
    const src = readFileSync(join(__dirname, '..', '..', 'supabase', 'functions', 'invite', 'handler.ts'), 'utf8');
    expect(src.split('\n').filter((l) => !l.trim().startsWith('//')).join('\n')).not.toMatch(/console\./);
  });
});
