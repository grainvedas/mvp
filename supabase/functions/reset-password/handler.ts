// Edge Function logic: a manager resets the password of someone they manage (Phase 4: operators sign in by phone and
// password until SMS is registered, so "forgot my password" needs a person, not an e-mail).
// Runtime-neutral like create-user: Supabase runs it through index.ts (Deno.serve); the local stack runs it with Node.
//
// Who may reset whom is NOT decided here: app.reset_login_allowed() makes a real, no-op UPDATE of the target row AS
// THE CALLER, so the users_update policy and the app_users guard (migration 10) are the rule. Only the Auth admin call
// needs the service key, and it runs after the database has said yes.
//
// POST { app_user_id }
// 200  { app_user_id, sign_in, temporary_password }   (shown once, to the manager; the user must set an own password)

type Env = Record<string, string | undefined>;

const cors = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info',
  'access-control-allow-methods': 'POST, OPTIONS',
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'content-type': 'application/json' } });

function tempPassword(): string {
  const bytes = new Uint8Array(12);
  crypto.getRandomValues(bytes);
  return 'Gv-' + btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export async function handle(req: Request, env: Env): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'POST only' });

  const url = (env.SUPABASE_URL ?? '').replace(/\/+$/, '');
  // Supabase injects SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY (the legacy keys). When the project moves to the new
  // API keys, set SB_PUBLISHABLE_KEY and SB_SECRET_KEY with `supabase secrets set`; they take precedence.
  const anon = env.SB_PUBLISHABLE_KEY ?? env.SUPABASE_ANON_KEY ?? '';
  const service = env.SB_SECRET_KEY ?? env.SUPABASE_SERVICE_ROLE_KEY ?? '';
  if (!url || !anon || !service) return json(500, { error: 'function is not configured' });

  const token = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (!token || token === anon) return json(401, { error: 'sign in first' });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json(400, { error: 'body must be JSON' }); }
  const target = String(body.app_user_id ?? '');
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(target)) return json(400, { error: 'app_user_id is required' });

  // 1. The database decides, as the caller.
  const may = await fetch(`${url}/rest/v1/rpc/reset_login_allowed`, {
    method: 'POST',
    headers: { apikey: anon, authorization: `Bearer ${token}`, 'content-type': 'application/json', 'content-profile': 'app' },
    body: JSON.stringify({ p_target: target }),
  });
  if (may.status === 401) return json(401, { error: 'sign in first' });
  if (!may.ok || (await may.json().catch(() => false)) !== true) {
    return json(403, { error: 'you may not reset this person\'s password' });
  }

  // 2. The login behind the row (service key).
  const asService = { apikey: service, authorization: `Bearer ${service}`, 'content-type': 'application/json' };
  const row = await fetch(`${url}/rest/v1/app_users?id=eq.${target}&select=auth_uid,phone,email,active`, { headers: asService });
  const u = ((await row.json().catch(() => [])) as Array<{ auth_uid: string | null; phone: string | null; email: string | null; active: boolean }>)[0];
  if (!u) return json(404, { error: 'user not found' });
  if (!u.active) return json(409, { error: 'this user is deactivated; activate them first' });
  const login = u.auth_uid ? await fetch(`${url}/auth/v1/admin/users/${u.auth_uid}`, { headers: asService }) : null;
  if (!login || !login.ok) return json(409, { error: 'this user has no login yet' });
  const meta = ((await login.json().catch(() => ({}))) as { user_metadata?: Record<string, unknown> }).user_metadata ?? {};

  // 3. New temporary password; the app will ask for an own password at the next sign-in.
  const password = tempPassword();
  const put = await fetch(`${url}/auth/v1/admin/users/${u.auth_uid}`, {
    method: 'PUT', headers: asService,
    body: JSON.stringify({ password, user_metadata: { ...meta, must_change_password: true } }),
  });
  if (!put.ok) {
    const d = (await put.json().catch(() => null)) as { msg?: string; message?: string } | null;
    return json(502, { error: d?.msg ?? d?.message ?? 'password could not be reset' });
  }
  return json(200, { app_user_id: target, sign_in: u.email ?? u.phone, temporary_password: password });
}
