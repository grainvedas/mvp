// Edge Function logic: make the LOGIN for a person HR has just created (identity layer, migrations 31–33).
// Runtime-neutral: Supabase runs it through index.ts (Deno.serve); the local stack runs it with Node.
//
// Who may create whom is NOT decided here. The person is created by a database function called AS THE CALLER
// (app.add_joiner: HR and the admin; app.add_client_viewer: whoever manages that client), which checks, writes the
// row and the audit line. Only the Auth admin call needs the service key, and it runs after the database has said yes.
// This function grants no access: a joiner starts with no scope, no client and no state. Access is given afterwards,
// by a manager, as an assignment.
//
// POST { kind: 'joiner', full_name, personal_email, join_date, phone?, employment_type?, designation_band?, department?,
//        job_title?, reports_to?, buddy?, template_id?, system_role? }
// POST { kind: 'viewer', client_id, display_name, email }                 (a client's own read-only login)
// 201  { app_user_id, login_id, sign_in, temporary_password, invite_emailed }
//      The temporary password is shown once, to the creator, who hands it over; the person sets their own at first sign-in.
// GET  { function, version }                                    (which build is deployed: scripts/check_functions.mjs)
//
// THIS FUNCTION AND THE DATABASE GO TOGETHER. Since migration 23 the database links a login to a user row only if the
// login carries app_metadata.grainveda_login; since migration 31 nobody inserts a person directly. Every answer carries
// the build in the header x-grainveda-function, the app warns when it is missing or older than it needs, and a link
// that fails says why (FIX_LIST fault 32).
import { mailConfigured, sendMail } from '../_shared/mail.ts';

type Env = Record<string, string | undefined>;

/** The build of the four functions (create-user, reset-password, ledger-check, daily-code). Raise it in all four
 *  whenever one changes in a way the app or the database depends on, and FUNCTIONS_NEEDED in web/src/lib/api.ts with it. */
export const VERSION = '2026-10-06';

const cors = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  'access-control-expose-headers': 'x-grainveda-function',
  'x-grainveda-function': VERSION,
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'content-type': 'application/json' } });

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

const JOINER_FIELDS = ['full_name', 'personal_email', 'phone', 'join_date', 'employment_type', 'designation_band', 'department',
  'job_title', 'reports_to', 'buddy', 'template_id', 'system_role'];

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

  const kind = String(body.kind ?? '');
  if (kind !== 'joiner' && kind !== 'viewer') {
    // The request of an app from before 6 Oct 2026 ({ role, display_name, … }): say what changed instead of a bare 400.
    return json(400, { error: body.role !== undefined
      ? 'people are now added by HR (HR → Add joiner) and given access by a manager afterwards: reload the app to get the new screens'
      : 'kind must be joiner or viewer' });
  }
  const name = String((kind === 'joiner' ? body.full_name : body.display_name) ?? '').trim();
  const email = String((kind === 'joiner' ? body.personal_email : body.email) ?? '').trim().toLowerCase();
  if (!name) return json(400, { error: 'a name is required' });
  // The email is the sign-in. (A phone may be kept on a joiner's record; nobody signs in by it any more.)
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json(400, { error: 'a valid email is required: it is the sign-in' });
  if (kind === 'joiner' && body.phone && !normaliseMobile(String(body.phone))) return json(400, { error: 'phone must be a 10-digit Indian mobile number' });

  const asCaller = { apikey: anon, authorization: `Bearer ${token}`, 'content-type': 'application/json', 'content-profile': 'app' };
  const asService = { apikey: service, authorization: `Bearer ${service}`, 'content-type': 'application/json', prefer: 'return=representation' };
  const rpc = (fn: string, args: unknown) => fetch(`${url}/rest/v1/rpc/${fn}`, { method: 'POST', headers: asCaller, body: JSON.stringify(args) });

  // 1. The database creates the person, as the caller: its rules decide whether they may.
  const made = kind === 'joiner'
    ? await rpc('add_joiner', { p: Object.fromEntries(JOINER_FIELDS.filter((k) => body[k] !== undefined && body[k] !== null && body[k] !== '').map((k) => [k, String(body[k])])) })
    : await rpc('add_client_viewer', { p_client: String(body.client_id ?? ''), p_name: name, p_email: email });
  const madeData = await made.json().catch(() => null);
  if (!made.ok) {
    const msg = dbMessage(madeData, 'refused');
    const status = made.status === 401 ? 401
      : made.status === 403 || /only HR|only the admin|do not manage|sign in first|not allowed/i.test(msg) ? 403
      : /already exists|seat is taken/i.test(msg) ? 409 : 400;
    return json(status, { error: msg });
  }
  const appUserId = kind === 'joiner' ? String((madeData as { id?: string } | null)?.id ?? '') : String(madeData ?? '');
  if (!/^[0-9a-f-]{36}$/i.test(appUserId)) return json(502, { error: 'the database did not say whom it created' });

  // Taking back what was made. Each removal is checked and tried twice: a login without a user row would block that
  // e-mail for the next attempt ("already registered"), a row without a login would show as "no login".
  const gone = async (what: string) => {
    for (let i = 0; i < 2; i++) {
      const r = await fetch(what, { method: 'DELETE', headers: asService }).catch(() => null);
      if (r && (r.ok || r.status === 404)) return true;
    }
    return false;
  };
  const removeRow = () => gone(`${url}/rest/v1/app_users?id=eq.${appUserId}`);       // its checklist, org facts and assignment go with it
  const removeLogin = (id: string) => gone(`${url}/auth/v1/admin/users/${id}`);
  /** Removes the login (if one was made) and the row; says what, if anything, it could not remove. */
  const takeBack = async (loginId: string | null): Promise<string> => {
    const left: string[] = [];
    if (loginId && !(await removeLogin(loginId))) left.push(`login ${loginId}`);
    if (!(await removeRow())) left.push(`user row ${appUserId}`);
    if (left.length === 0) return loginId ? 'both removed' : 'nothing was kept';
    const msg = `COULD NOT REMOVE ${left.join(' and ')}: remove by hand (docs/OPERATIONS.md "A login without a person")`;
    console.error(`create-user: ${msg}`);
    return msg;
  };

  let loginId: string | null = null;
  try {
    // 2. The login (service key). Created confirmed and marked, so the linking trigger attaches it to the row.
    const password = tempPassword();
    const a = await fetch(`${url}/auth/v1/admin/users`, {
      method: 'POST', headers: asService,
      // app_metadata.grainveda_login: only a login made here (service role) can be linked to a user row (migration 23).
      // user_metadata.must_change_password: the app asks for an own password at first sign-in (the creator knows this one).
      body: JSON.stringify({ email, password, email_confirm: true, app_metadata: { grainveda_login: true },
        user_metadata: { display_name: name, must_change_password: true } }),
    });
    const login = await a.json().catch(() => null) as Login | null;
    if (!a.ok || !login?.id) {
      await takeBack(null);
      const msg = dbMessage(login, 'login could not be created');
      return json(/registered|exists/i.test(msg) ? 409 : 502, { error: msg });
    }
    loginId = login.id;

    // 3. Linked? The trigger declines without an error, so read the row back and say why if it did.
    const chk = await fetch(`${url}/rest/v1/app_users?id=eq.${appUserId}&select=auth_uid,active`, { headers: asService });
    const rows = chk.ok ? (await chk.json().catch(() => null)) as UserRow[] | null : null;
    const why = chk.ok && Array.isArray(rows) ? whyNotLinked(login, rows[0], appUserId)
      : `the user row could not be read back with the service key (HTTP ${chk.status})`;
    if (why) {
      console.error(`create-user: login ${login.id} was not linked to user row ${appUserId}: ${why}`);
      const cleaned = await takeBack(login.id);
      return json(500, { error: `login created but not linked: ${why}; ${cleaned}` });
    }

    // 4. The invite. With a sender set up, a note goes to the person (never the password: the creator hands that over).
    let emailed = false;
    if (mailConfigured(env)) {
      const site = (env.APP_URL ?? '').replace(/\/+$/, '');
      emailed = (await sendMail(env, { to: email, subject: 'Your GrainVeda account is ready',
        text: `Hello ${name},\n\nYour GrainVeda account is ready. Sign in${site ? ` at ${site}` : ''} with this email address.\n`
          + 'Your first password will be given to you by the person who set you up; you choose your own when you first sign in.\n' })).ok;
    }
    await rpc('note_invite_sent', { p_employee: appUserId, p_how: emailed ? 'email note + password by hand' : 'password by hand' }).catch(() => null);

    return json(201, { app_user_id: appUserId, login_id: login.id, sign_in: email, temporary_password: password, invite_emailed: emailed });
  } catch (e) {
    // A request that broke half-way (the Auth server or the database did not answer) must not leave half a person.
    const what = e instanceof Error ? e.message : String(e);
    console.error(`create-user: interrupted for user row ${appUserId}: ${what}`);
    const cleaned = await takeBack(loginId);
    return json(502, { error: `the server did not answer while the person was being created (${what}); ${cleaned}` });
  }
}
