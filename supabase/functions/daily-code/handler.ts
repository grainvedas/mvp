// Edge Function logic: send today's sign-in code (identity layer: password every time, a code once per calendar day).
// BUILT AND TESTED, SWITCHED OFF (decision 5 Oct 2026): the database asks nobody for a code until the admin switches
// it on (System → Seats), and that is only offered once this function reports a sender.
// Runtime-neutral like create-user: Supabase runs it through index.ts (Deno.serve); the local stack runs it with Node.
//
// GET   { function, version, sender }       sender: are MAIL_API_URL, MAIL_API_KEY and MAIL_FROM set?
// POST  (the person's own token)  → 200 { sent: true, to: "g•••@gmail.com", minutes: 10 }
//       The code is drawn by the database (app.issue_daily_code, service key only, which keeps only its hash), mailed
//       to the address on the person's record, and never returned to the caller.
import { mailConfigured, maskEmail, sendMail } from '../_shared/mail.ts';

type Env = Record<string, string | undefined>;

/** The build of the four functions; the same value as in create-user/handler.ts (a unit test holds them together). */
export const VERSION = '2026-10-12';

const cors = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  'access-control-expose-headers': 'x-grainveda-function',
  'x-grainveda-function': VERSION,
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'content-type': 'application/json', 'cache-control': 'no-store' } });

export async function handle(req: Request, env: Env): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method === 'GET') return json(200, { function: 'daily-code', version: VERSION, sender: mailConfigured(env) });
  if (req.method !== 'POST') return json(405, { error: 'POST only' });

  const url = (env.SUPABASE_URL ?? '').replace(/\/+$/, '');
  const anon = env.SB_PUBLISHABLE_KEY ?? env.SUPABASE_ANON_KEY ?? '';
  const service = env.SB_SECRET_KEY ?? env.SUPABASE_SERVICE_ROLE_KEY ?? '';
  if (!url || !anon || !service) return json(500, { error: 'function is not configured' });

  const token = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (!token || token === anon) return json(401, { error: 'sign in first' });
  // Whose token is it? Asked of the Auth server, so a forged or expired token gets no code sent anywhere.
  const who = await fetch(`${url}/auth/v1/user`, { headers: { apikey: anon, authorization: `Bearer ${token}` } });
  const uid = who.ok ? ((await who.json().catch(() => null)) as { id?: string } | null)?.id : null;
  if (!uid) return json(401, { error: 'sign in first' });

  if (!mailConfigured(env)) return json(503, { error: 'no sender is set up for sign-in codes: ask the admin to switch the code off' });

  const r = await fetch(`${url}/rest/v1/rpc/issue_daily_code`, {
    method: 'POST',
    headers: { apikey: service, authorization: `Bearer ${service}`, 'content-type': 'application/json', 'content-profile': 'app' },
    body: JSON.stringify({ p_auth_uid: uid }),
  });
  const d = (await r.json().catch(() => null)) as { code?: string; email?: string; name?: string; minutes?: number; message?: string } | null;
  if (!r.ok || !d?.code || !d.email) {
    const msg = d?.message ?? 'a code could not be drawn';
    return json(/less than a minute/.test(msg) ? 429 : /no email/.test(msg) ? 409 : /no such person/.test(msg) ? 403 : 502, { error: msg });
  }
  const sent = await sendMail(env, { to: d.email, subject: `${d.code} is your GrainVeda sign-in code`,
    text: `Hello ${d.name ?? ''},\n\nYour GrainVeda sign-in code for today is ${d.code}.\nIt works for ${d.minutes ?? 10} minutes and once only.\n\n`
      + 'If you did not just sign in, someone else knows your password: change it and tell the admin.\n' });
  if (!sent.ok) return json(502, { error: `the code could not be sent: ${sent.error}` });
  return json(200, { sent: true, to: maskEmail(d.email), minutes: d.minutes ?? 10 });
}
