// Edge Function logic: invites (migration 38; Veda's brief "Onboarding at scale", decisions "as recommended", 11 Oct 2026).
// A temporary password handed over in person does not work for 100 people across a state. An invite is a one-time
// link: the joiner opens it, sets their own password, and is signed in. Runtime-neutral like the others: Supabase runs
// it through index.ts (Deno.serve); the local stack runs it with Node. Deployed with --no-verify-jwt: "check" and
// "accept" come from someone who has no sign-in yet; "send" and "reminders" check the caller's sign-in themselves.
//
// POST { action: 'send', employee_ids: [...] }   (HR's own token)
//   The database, asked AS THE CALLER, says whom HR may invite (app.invite_targets). For each: a fresh token (32 random
//   bytes), only its SHA-256 kept (app.record_invite: the old invite is replaced), the link `<app>/invite#<token>`
//   (after the #, so no web server ever logs it). With a mail sender set up, the link goes to the joiner's email;
//   without one (decision 1: none yet) it is "not sent" and HR copies the link and forwards it.
//   → 200 { results: [{ id, name, link, expires_at, sent: 'email' | 'not_sent' | 'failed' }], skipped: [...], mail }
// POST { action: 'check', token }               → 200 { state: 'ok', first_name, email_masked } | { state: 'expired' | 'used' | … }
// POST { action: 'accept', token, password }    → 200 { sign_in }   the joiner's own password; the sign-in is made now
//   if there is none yet (a bulk-imported joiner: decision 4), else its password is set. The invite is used up.
// POST { action: 'reminders' }   (HR's token)  → queues today's reminders and, with a mail sender, sends what is queued
// GET  → { function, version, mail }
//
// Nothing secret is logged: no token, no link, no password, no email address. Answers to the joiner are fixed codes.
import { mailConfigured, maskEmail, sendMail } from '../_shared/mail.ts';

type Env = Record<string, string | undefined>;

/** The build of the six functions; the same value in all (a unit test holds them together). */
export const VERSION = '2026-10-13';

const cors = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  'access-control-expose-headers': 'x-grainveda-function',
  'x-grainveda-function': VERSION,
};
const answer = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'content-type': 'application/json', 'cache-control': 'no-store' } });

export const MIN_PASSWORD = 8;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** 32 random bytes, base64url (43 characters). */
export function newToken(): string {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
export const tokenShape = (t: unknown): t is string => typeof t === 'string' && /^[A-Za-z0-9_-]{43}$/.test(t);
export async function sha256Hex(s: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
  return [...d].map((x) => x.toString(16).padStart(2, '0')).join('');
}
/** Where the app is: APP_URL when set, else the page that asked (its origin), else nothing. */
export function appBase(env: Env, origin: string | null): string {
  const set = (env.APP_URL ?? '').replace(/\/+$/, '');
  if (set) return set;
  return origin && /^https?:\/\/[A-Za-z0-9.-]+(:\d+)?$/.test(origin) ? origin : '';
}
export const inviteLink = (base: string, token: string) => `${base}/invite#${token}`;
export function inviteText(name: string, link: string, expires: string): string {
  const first = name.split(' ')[0] || name;
  const until = new Date(expires).toLocaleString('en-IN', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'Asia/Kolkata' });
  return `Hello ${first},\n\nYou have been invited to GrainVeda. Open this link on your phone to choose your password and sign in:\n${link}\n\n`
    + `The link works once, until ${until}. If it has expired, ask HR for a new one.\n\n`
    + `नमस्ते ${first}, GrainVeda में आपका स्वागत है। ऊपर दिया लिंक खोलकर अपना पासवर्ड चुनें। लिंक एक ही बार चलेगा।\n`;
}

export async function handle(req: Request, env: Env): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method === 'GET') return answer(200, { function: 'invite', version: VERSION, mail: mailConfigured(env) });
  if (req.method !== 'POST') return answer(405, { code: 'POST_ONLY' });
  const url = (env.SUPABASE_URL ?? '').replace(/\/+$/, '');
  const anon = env.SB_PUBLISHABLE_KEY ?? env.SUPABASE_ANON_KEY ?? '';
  const service = env.SB_SECRET_KEY ?? env.SUPABASE_SERVICE_ROLE_KEY ?? '';
  if (!url || !anon || !service) return answer(500, { code: 'NOT_CONFIGURED' });
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return answer(400, { code: 'BAD_REQUEST' }); }
  const asService = { apikey: service, authorization: `Bearer ${service}`, 'content-type': 'application/json', 'content-profile': 'app' };
  const svc = async (fn: string, args: unknown) => {
    const r = await fetch(`${url}/rest/v1/rpc/${fn}`, { method: 'POST', headers: asService, body: JSON.stringify(args) });
    return { ok: r.ok, status: r.status, data: await r.json().catch(() => null) };
  };
  const token = (req.headers.get('authorization') ?? '').replace(/^Bearer\s*/i, '').trim();
  const asCaller = async (fn: string, args: unknown) => {
    const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
      method: 'POST', headers: { apikey: anon, authorization: `Bearer ${token}`, 'content-type': 'application/json', 'content-profile': 'app' },
      body: JSON.stringify(args) });
    return { ok: r.ok, status: r.status, data: await r.json().catch(() => null) };
  };

  try {
    switch (String(body.action ?? '')) {
      case 'send': {
        if (!token || token === anon) return answer(401, { code: 'SIGN_IN' });
        const ids = Array.isArray(body.employee_ids) ? body.employee_ids.map(String).filter((x) => UUID.test(x)) : [];
        if (ids.length === 0 || ids.length > 100) return answer(400, { code: 'BAD_REQUEST' });
        const who = await asCaller('invite_targets', { p_employees: ids });
        if (who.status === 401) return answer(401, { code: 'SIGN_IN' });
        if (!who.ok) return answer(403, { code: 'NOT_ALLOWED' });
        const t = who.data as { actor: string; people: { id: string; name: string; email: string }[]; skipped: unknown[] };
        const base = appBase(env, req.headers.get('origin'));
        const mail = mailConfigured(env);
        const results = [];
        for (const p of t.people) {
          const tok = newToken();
          const rec = await svc('record_invite', { p_employee: p.id, p_actor: t.actor, p_hash: await sha256Hex(tok), p_channel: mail ? 'email' : 'link', p_hours: 72 });
          if (!rec.ok) { results.push({ id: p.id, name: p.name, link: null, sent: 'failed' }); continue; }
          const inv = rec.data as { id: string; expires_at: string };
          const link = inviteLink(base, tok);
          let sent: 'email' | 'not_sent' | 'failed' = 'not_sent';
          if (mail && base) {
            const m = await sendMail(env, { to: p.email, subject: 'Your GrainVeda invitation', text: inviteText(p.name, link, inv.expires_at) });
            sent = m.ok ? 'email' : 'failed';
            await svc('mark_invite_sent', { p_invite: inv.id, p_ok: m.ok });
          }
          results.push({ id: p.id, name: p.name, link, expires_at: inv.expires_at, sent });
        }
        return answer(200, { results, skipped: t.skipped, mail });
      }
      case 'check': {
        if (!tokenShape(body.token)) return answer(200, { state: 'not_found' });
        const r = await svc('invite_lookup', { p_hash: await sha256Hex(body.token) });
        if (!r.ok) return answer(502, { code: 'FAILED' });
        const x = r.data as { state: string; name?: string; email?: string };
        if (x.state !== 'ok') return answer(200, { state: x.state });
        return answer(200, { state: 'ok', first_name: (x.name ?? '').split(' ')[0], email_masked: maskEmail(x.email ?? '') });
      }
      case 'accept': {
        if (!tokenShape(body.token)) return answer(400, { code: 'NOT_FOUND' });
        const pw = typeof body.password === 'string' ? body.password : '';
        if (pw.length < MIN_PASSWORD || pw.length > 72) return answer(400, { code: 'WEAK_PASSWORD' });
        const r = await svc('invite_lookup', { p_hash: await sha256Hex(body.token) });
        if (!r.ok) return answer(502, { code: 'FAILED' });
        const x = r.data as { state: string; invite_id: string; employee_id: string; name: string; email: string; login_id: string | null };
        if (x.state !== 'ok') return answer(410, { code: x.state.toUpperCase() });
        const authAdmin = { apikey: service, authorization: `Bearer ${service}`, 'content-type': 'application/json' };
        if (x.login_id) {
          // A sign-in exists (made by Add joiner with a temporary password): the joiner's own password replaces it.
          const got = await fetch(`${url}/auth/v1/admin/users/${x.login_id}`, { headers: authAdmin });
          const meta = ((await got.json().catch(() => ({}))) as { user_metadata?: Record<string, unknown> }).user_metadata ?? {};
          const put = await fetch(`${url}/auth/v1/admin/users/${x.login_id}`, { method: 'PUT', headers: authAdmin,
            body: JSON.stringify({ password: pw, user_metadata: { ...meta, must_change_password: false } }) });
          if (!put.ok) return answer(502, { code: 'FAILED' });
        } else {
          // No sign-in yet (a bulk-imported joiner): made now, confirmed and marked, so the database links it to the person.
          const made = await fetch(`${url}/auth/v1/admin/users`, { method: 'POST', headers: authAdmin,
            body: JSON.stringify({ email: x.email, password: pw, email_confirm: true, app_metadata: { grainveda_login: true },
              user_metadata: { display_name: x.name, must_change_password: false } }) });
          const login = (await made.json().catch(() => null)) as { id?: string } | null;
          if (!made.ok || !login?.id) return answer(409, { code: 'LOGIN_EXISTS' });
          const chk = await fetch(`${url}/rest/v1/app_users?id=eq.${x.employee_id}&select=auth_uid`, { headers: authAdmin });
          const rows = (await chk.json().catch(() => [])) as { auth_uid: string | null }[];
          if (rows[0]?.auth_uid !== login.id) {
            await fetch(`${url}/auth/v1/admin/users/${login.id}`, { method: 'DELETE', headers: authAdmin }).catch(() => null);
            return answer(502, { code: 'NOT_LINKED' });
          }
        }
        const used = await svc('use_invite', { p_invite: x.invite_id });
        if (!used.ok) return answer(410, { code: 'USED' });
        return answer(200, { sign_in: x.email });
      }
      case 'reminders': {
        if (!token || token === anon) return answer(401, { code: 'SIGN_IN' });
        const may = await asCaller('may_send_messages', {});
        if (may.status === 401) return answer(401, { code: 'SIGN_IN' });
        if (!may.ok || may.data !== true) return answer(403, { code: 'NOT_ALLOWED' });
        const q = await svc('queue_reminders', {});
        const queued = q.ok ? Number(q.data) : 0;
        let sent = 0, failed = 0;
        if (mailConfigured(env)) {
          const base = appBase(env, req.headers.get('origin'));
          const todo = await svc('messages_to_send', { p_limit: 50 });
          for (const m of (todo.data ?? []) as { id: number; to_email: string; subject: string; body: string }[]) {
            const r = await sendMail(env, { to: m.to_email, subject: m.subject, text: m.body.replaceAll('{app}', base) });
            await svc('mark_message', { p_id: m.id, p_ok: r.ok, p_error: r.ok ? null : 'mail service refused' });
            if (r.ok) sent++; else failed++;
          }
        }
        return answer(200, { queued, sent, failed, mail: mailConfigured(env) });
      }
      default:
        return answer(400, { code: 'BAD_REQUEST' });
    }
  } catch {
    return answer(502, { code: 'FAILED' });
  }
}
