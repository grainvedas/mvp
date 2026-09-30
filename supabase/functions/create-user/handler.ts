// Edge Function logic: create a login for a new user (execution plan B5). Runtime-neutral: Supabase runs it through
// index.ts (Deno.serve); the local stack runs it with Node (local-stack/functions.mjs).
//
// Who may create whom is NOT decided here. The app_users row and the slot are inserted AS THE CALLER, so the same RLS
// policies and the app_users guard (migrations 5 and 10) decide: admin > state manager > client manager > view/operator.
// Only the Auth admin call needs the service key, and it runs after the database has accepted the caller's request.
//
// POST { role, display_name, email? | phone?, client_id?, state_ids?, slot?: { scope_id, stage_type } }
// 201  { app_user_id, login_id, sign_in, temporary_password }   (temporary password shown once, to the creator)

type Env = Record<string, string | undefined>;

const cors = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info',
  'access-control-allow-methods': 'POST, OPTIONS',
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

function dbMessage(data: unknown, fallback: string): string {
  const d = data as { message?: string; msg?: string; error_description?: string } | null;
  return d?.message ?? d?.msg ?? d?.error_description ?? fallback;
}

export async function handle(req: Request, env: Env): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'POST') return json(405, { error: 'POST only' });

  const url = (env.SUPABASE_URL ?? '').replace(/\/+$/, '');
  const anon = env.SUPABASE_ANON_KEY ?? '';
  const service = env.SUPABASE_SERVICE_ROLE_KEY ?? '';
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
  if (role === 'operator' && !phone) return json(400, { error: 'operators sign in by phone: phone is required' });
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

  const undo = async () => {
    await fetch(`${url}/rest/v1/app_users?id=eq.${appUser.id}`, { method: 'DELETE', headers: asService });
  };

  // 2. Optional slot, also as the caller (slots_write policy: must manage the scope's client).
  const slot = body.slot as { scope_id?: string; stage_type?: string } | undefined;
  if (slot?.scope_id && slot?.stage_type) {
    const s = await fetch(`${url}/rest/v1/slot_assignments`, {
      method: 'POST', headers: asCaller,
      body: JSON.stringify({ user_id: appUser.id, scope_id: slot.scope_id, stage_type: slot.stage_type }),
    });
    if (!s.ok) { const d = await s.json().catch(() => null); await undo(); return json(403, { error: dbMessage(d, 'slot refused') }); }
  }

  // 3. The login (service key). Created confirmed, so the linking trigger (migration 9) attaches it to the row.
  const password = tempPassword();
  const cred = email ? { email, password, email_confirm: true } : { phone: phone!.replace('+', ''), password, phone_confirm: true };
  const a = await fetch(`${url}/auth/v1/admin/users`, {
    method: 'POST', headers: asService, body: JSON.stringify({ ...cred, user_metadata: { display_name: displayName } }),
  });
  const login = await a.json().catch(() => null) as { id?: string } | null;
  if (!a.ok || !login?.id) {
    await undo();
    const msg = dbMessage(login, 'login could not be created');
    return json(/registered|exists/i.test(msg) ? 409 : 502, { error: msg });
  }

  // 4. Linked?
  const chk = await fetch(`${url}/rest/v1/app_users?id=eq.${appUser.id}&select=auth_uid`, { headers: asService });
  const linked = ((await chk.json().catch(() => [])) as Array<{ auth_uid: string }>)[0]?.auth_uid === login.id;
  if (!linked) {
    await fetch(`${url}/auth/v1/admin/users/${login.id}`, { method: 'DELETE', headers: asService });
    await undo();
    return json(500, { error: 'login created but not linked; both removed' });
  }

  return json(201, { app_user_id: appUser.id, login_id: login.id, sign_in: email ?? phone, temporary_password: password });
}
