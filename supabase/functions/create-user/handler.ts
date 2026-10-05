// Edge Function logic: create a login for a new user (execution plan B5). Runtime-neutral: Supabase runs it through
// index.ts (Deno.serve); the local stack runs it with Node (local-stack/functions.mjs).
//
// Who may create whom is NOT decided here. The app_users row and the slot are inserted AS THE CALLER, so the same RLS
// policies and the app_users guard (migrations 5 and 10) decide: admin > state manager > client manager > view/operator.
// Only the Auth admin call needs the service key, and it runs after the database has accepted the caller's request.
//
// POST { role, display_name, email? | phone?, client_id?, state_ids?, slot?: { scope_id, stage_type } }
// 201  { app_user_id, login_id, sign_in, temporary_password }   (temporary password shown once, to the creator)
// GET  { function, version }                                    (which build is deployed: scripts/check_functions.mjs)
//
// THIS FUNCTION AND THE DATABASE GO TOGETHER. Since migration 23 the database links a login to a user row only if the
// login carries app_metadata.grainveda_login. On 4 Oct 2026 staging had migration 23 and the function of 1 Oct, which
// does not set that mark: every "New user" ended in "login created but not linked; both removed" (FIX_LIST fault 32).
// Every answer now carries the build in the header x-grainveda-function, the app warns when it is missing or older
// than it needs, and a link that fails says why.

type Env = Record<string, string | undefined>;

/** The build of the three functions (create-user, reset-password, ledger-check). Raise it in all three whenever one
 *  changes in a way the app or the database depends on, and FUNCTIONS_NEEDED in web/src/lib/api.ts with it. */
export const VERSION = '2026-10-05';

const cors = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  'access-control-expose-headers': 'x-grainveda-function',
  'x-grainveda-function': VERSION,
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'content-type': 'application/json' } });

const MANAGER_ROLES = ['admin', 'state_manager', 'client_manager', 'client_view'];
const ALL_ROLES = [...MANAGER_ROLES, 'operator'];

export function normaliseMobile(p: string): string | null {
  const d = (p ?? '').replace(/[^0-9]/g, '');
  if (d.length === 10 && /^[6-9]/.test(d)) return `+91${d}`;
  if (d.length === 12 && /^91[6-9]/.test(d)) return `+${d}`;
  if (d.length === 11 && /^0[6-9]/.test(d)) return `+91${d.slice(1)}`;
  return null;
}

function tempPassword(): string {
  const bytes = new Uint8Array(12);
  crypto.getRandomValues(bytes);
  return 'Gv-' + btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

interface Login { id?: string; phone?: string | null; email?: string | null; phone_confirmed_at?: string | null; email_confirmed_at?: string | null;
  app_metadata?: Record<string, unknown> | null }
interface UserRow { auth_uid: string | null; active: boolean }

/**
 * Why did the database not link this login to this user row? The linking trigger (app.link_login, migrations 9 and 23)
 * declines without an error, so the reason has to be read off the two records. null = it is linked.
 * The order is the trigger's own: a confirmed channel, the service mark, an active and unclaimed row.
 */
export function whyNotLinked(login: Login, row: UserRow | null | undefined, userId: string): string | null {
  if (!row) return 'the user row could not be read back (deleted meanwhile, or the service key cannot read app_users)';
  if (row.auth_uid === login.id) return null;
  if (!login.phone_confirmed_at && !login.email_confirmed_at) return 'the login has no confirmed phone or email';
  if (login.app_metadata?.grainveda_login !== true)
    return 'the login does not carry app_metadata.grainveda_login, and since migration 23 the database links only logins that do';
  if (!row.active) return 'the user row is not active';
  if (row.auth_uid && row.auth_uid !== userId) return 'the user row is already linked to another login';
  return 'the database declined the link: another user row has the same phone or email, or the trigger grainveda_link_login is missing '
    + '(Postgres log: "login linking failed" or "matches … app users")';
}

function dbMessage(data: unknown, fallback: string): string {
  const d = data as { message?: string; msg?: string; error_description?: string } | null;
  return d?.message ?? d?.msg ?? d?.error_description ?? fallback;
}

export async function handle(req: Request, env: Env): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method === 'GET') return json(200, { function: 'create-user', version: VERSION });
  if (req.method !== 'POST') return json(405, { error: 'POST only' });

  const url = (env.SUPABASE_URL ?? '').replace(/\/+$/, '');
  // Supabase injects SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY (the legacy keys). When the project moves to the new
  // API keys, set SB_PUBLISHABLE_KEY and SB_SECRET_KEY with `supabase secrets set`; they take precedence.
  const anon = env.SB_PUBLISHABLE_KEY ?? env.SUPABASE_ANON_KEY ?? '';
  const service = env.SB_SECRET_KEY ?? env.SUPABASE_SERVICE_ROLE_KEY ?? '';
  if (!url || !anon || !service) return json(500, { error: 'function is not configured' });

  const auth = req.headers.get('authorization') ?? '';
  const token = auth.replace(/^Bearer\s+/i, '');
  if (!token || token === anon) return json(401, { error: 'sign in first' });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json(400, { error: 'body must be JSON' }); }

  const role = String(body.role ?? '');
  const displayName = String(body.display_name ?? '').trim();
  const email = body.email ? String(body.email).trim().toLowerCase() : null;
  const phone = body.phone ? normaliseMobile(String(body.phone)) : null;
  if (!ALL_ROLES.includes(role)) return json(400, { error: `role must be one of ${ALL_ROLES.join(', ')}` });
  if (!displayName) return json(400, { error: 'display_name is required' });
  if (body.phone && !phone) return json(400, { error: 'phone must be a 10-digit Indian mobile number' });
  // An operator signs in by phone + password OR email + password (5 Oct 2026: email added so operators can sign in
  // without the Twilio-gated Phone provider). A manager always has an email. Everyone needs at least one of the two.
  if (!phone && !email) return json(400, { error: 'a phone number or an email is required to sign in' });
  if (role !== 'operator' && !email) return json(400, { error: 'managers sign in by email: email is required' });
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json(400, { error: 'email is not valid' });

  const asCaller = { apikey: anon, authorization: `Bearer ${token}`, 'content-type': 'application/json', prefer: 'return=representation' };
  const asService = { apikey: service, authorization: `Bearer ${service}`, 'content-type': 'application/json', prefer: 'return=representation' };

  // 1. The caller inserts the user row: RLS + guard decide whether they may.
  const row = {
    role, display_name: displayName, email, phone,
    client_id: body.client_id ?? null,
    state_ids: Array.isArray(body.state_ids) ? body.state_ids : [],
  };
  const ins = await fetch(`${url}/rest/v1/app_users`, { method: 'POST', headers: asCaller, body: JSON.stringify(row) });
  const insData = await ins.json().catch(() => null);
  if (!ins.ok) {
    const msg = dbMessage(insData, 'refused');
    const status = ins.status === 401 || ins.status === 403 || /row-level security|may only manage/i.test(msg) ? 403
      : /duplicate key|already exists/i.test(msg) ? 409 : 400;
    return json(status, { error: status === 409 ? 'a user with this phone or email already exists' : msg });
  }
  const appUser = (insData as Array<{ id: string }>)[0];

  // Taking back what was made. Each removal is checked and tried twice: a login without a user row would block that
  // phone or e-mail for the next attempt ("already registered"), a row without a login would show as "no login".
  const gone = async (what: string) => {
    for (let i = 0; i < 2; i++) {
      const r = await fetch(what, { method: 'DELETE', headers: asService }).catch(() => null);
      if (r && (r.ok || r.status === 404)) return true;
    }
    return false;
  };
  const removeRow = () => gone(`${url}/rest/v1/app_users?id=eq.${appUser.id}`);
  const removeLogin = (id: string) => gone(`${url}/auth/v1/admin/users/${id}`);
  /** Removes the login (if one was made) and the row; says what, if anything, it could not remove. */
  const takeBack = async (loginId: string | null): Promise<string> => {
    const left: string[] = [];
    if (loginId && !(await removeLogin(loginId))) left.push(`login ${loginId}`);
    if (!(await removeRow())) left.push(`user row ${appUser.id}`);
    if (left.length === 0) return loginId ? 'both removed' : 'nothing was kept';
    const msg = `COULD NOT REMOVE ${left.join(' and ')}: remove by hand (docs/OPERATIONS.md "A login without a person")`;
    console.error(`create-user: ${msg}`);
    return msg;
  };

  let loginId: string | null = null;
  try {
    // 2. Optional slot, also as the caller (slots_write policy: must manage the scope's client).
    const slot = body.slot as { scope_id?: string; stage_type?: string } | undefined;
    if (slot?.scope_id && slot?.stage_type) {
      const s = await fetch(`${url}/rest/v1/slot_assignments`, {
        method: 'POST', headers: asCaller,
        body: JSON.stringify({ user_id: appUser.id, scope_id: slot.scope_id, stage_type: slot.stage_type }),
      });
      if (!s.ok) { const d = await s.json().catch(() => null); await takeBack(null); return json(403, { error: dbMessage(d, 'slot refused') }); }
    }

    // 3. The login (service key). Created confirmed and marked, so the linking trigger attaches it to the row.
    const password = tempPassword();
    const cred = email ? { email, password, email_confirm: true } : { phone: phone!.replace('+', ''), password, phone_confirm: true };
    const a = await fetch(`${url}/auth/v1/admin/users`, {
      method: 'POST', headers: asService,
      // app_metadata.grainveda_login: only a login made here (service role) can be linked to a user row (migration 23).
      // user_metadata.must_change_password: the app asks for an own password at first sign-in (the creator knows this one).
      body: JSON.stringify({ ...cred, app_metadata: { grainveda_login: true },
        user_metadata: { display_name: displayName, must_change_password: true } }),
    });
    const login = await a.json().catch(() => null) as Login | null;
    if (!a.ok || !login?.id) {
      await takeBack(null);
      const msg = dbMessage(login, 'login could not be created');
      return json(/registered|exists/i.test(msg) ? 409 : 502, { error: msg });
    }
    loginId = login.id;

    // 4. Linked? The trigger declines without an error, so read the row back and say why if it did.
    const chk = await fetch(`${url}/rest/v1/app_users?id=eq.${appUser.id}&select=auth_uid,active`, { headers: asService });
    const rows = chk.ok ? (await chk.json().catch(() => null)) as UserRow[] | null : null;
    const why = chk.ok && Array.isArray(rows) ? whyNotLinked(login, rows[0], appUser.id)
      : `the user row could not be read back with the service key (HTTP ${chk.status})`;
    if (why) {
      console.error(`create-user: login ${login.id} was not linked to user row ${appUser.id}: ${why}`);
      const cleaned = await takeBack(login.id);
      return json(500, { error: `login created but not linked: ${why}; ${cleaned}` });
    }

    return json(201, { app_user_id: appUser.id, login_id: login.id, sign_in: email ?? phone, temporary_password: password });
  } catch (e) {
    // A request that broke half-way (the Auth server or the database did not answer) must not leave half a person.
    const what = e instanceof Error ? e.message : String(e);
    console.error(`create-user: interrupted for user row ${appUser.id}: ${what}`);
    const cleaned = await takeBack(loginId);
    return json(502, { error: `the server did not answer while the person was being created (${what}); ${cleaned}` });
  }
}
