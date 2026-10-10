// Edge Function logic: check a PAN, Aadhaar, UAN or bank account number for duplicates WITHOUT keeping it (migration 37,
// Veda's brief of 11 Oct 2026, part A1). Runtime-neutral like the others: Supabase runs it through index.ts (Deno.serve);
// the local stack runs it with Node.
//
// POST (the person's own token) { task_id, kind: 'pan' | 'aadhaar' | 'uan' | 'bank', number, ifsc? }
//   1. the database is asked, AS THE CALLER, whose number this is (app.id_number_target): the joiner's own open step of
//      the right kind, or HR for a person HR manages. The number is not sent there.
//   2. the number is normalised (upper case, no spaces) and validated here too: PAN five letters, four digits, a letter;
//      Aadhaar 12 digits with a valid Verhoeff check digit; UAN 12 digits; account 9 to 18 digits (with the IFSC).
//   3. HMAC-SHA256 with ID_HMAC_KEY, a secret held only in this function's settings (supabase secrets), over
//      "<kind>:<number>" (bank: "bank:<first 4 letters of the IFSC>:<account>", as account numbers are unique only within
//      a bank). Only that HMAC and the last 4 go to the database (app.record_id_number, service key only).
//   → 200 { ok, kind, last4, outcome: 'saved' | 'warned' }      warned: a bank account also on another person's record
//   → 409 { code: 'DUPLICATE' }      PAN, Aadhaar or UAN already on another person's record: not saved; HR sees whose
//   → 400 { code: 'BAD_FORMAT' | 'BAD_REQUEST' } · 401 { code: 'SIGN_IN' } · 403 { code: 'NOT_ALLOWED' } · 5xx { code: … }
// GET → { function, version, configured }
//
// THE FULL NUMBER IS NEVER WRITTEN ANYWHERE. It lives in this request's memory only. It is never logged (this file has
// no console call that takes the request, the number or a database answer), never put in a URL, never sent to the
// database, and never part of an answer: every answer is a fixed code. A unit test (web/tests/id_numbers.test.ts)
// holds these rules; an end-to-end test searches everything the local stack wrote for the numbers it typed.

type Env = Record<string, string | undefined>;

/** The build of the server functions (the same value in all five; a unit test holds them together). */
export const VERSION = '2026-10-12';

const cors = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  'access-control-expose-headers': 'x-grainveda-function',
  'x-grainveda-function': VERSION,
};
const answer = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'content-type': 'application/json', 'cache-control': 'no-store' } });

export type IdKind = 'pan' | 'aadhaar' | 'uan' | 'bank';
const KINDS: IdKind[] = ['pan', 'aadhaar', 'uan', 'bank'];

const VD = [[0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 2, 3, 4, 0, 6, 7, 8, 9, 5], [2, 3, 4, 0, 1, 7, 8, 9, 5, 6], [3, 4, 0, 1, 2, 8, 9, 5, 6, 7],
  [4, 0, 1, 2, 3, 9, 5, 6, 7, 8], [5, 9, 8, 7, 6, 0, 4, 3, 2, 1], [6, 5, 9, 8, 7, 1, 0, 4, 3, 2], [7, 6, 5, 9, 8, 2, 1, 0, 4, 3],
  [8, 7, 6, 5, 9, 3, 2, 1, 0, 4], [9, 8, 7, 6, 5, 4, 3, 2, 1, 0]];
const VP = [[0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 5, 7, 6, 2, 8, 3, 0, 9, 4], [5, 8, 0, 3, 7, 9, 6, 1, 4, 2], [8, 9, 1, 6, 0, 4, 3, 5, 2, 7],
  [9, 4, 5, 3, 1, 2, 6, 8, 7, 0], [4, 2, 8, 6, 5, 7, 3, 9, 0, 1], [2, 7, 9, 3, 8, 0, 6, 4, 1, 5], [7, 0, 4, 6, 9, 1, 3, 2, 5, 8]];
/** A Verhoeff check digit that holds. */
export function verhoeffOk(digits: string): boolean {
  let c = 0;
  [...digits].reverse().forEach((ch, i) => { c = VD[c][VP[i % 8][Number(ch)]]; });
  return c === 0;
}

/** Pure: the number as it is kept for comparing (upper case, no spaces or dashes), or null when it is not one. */
export function normalise(kind: IdKind, raw: unknown, ifscRaw?: unknown): { value: string; ifsc: string | null } | null {
  if (typeof raw !== 'string' || raw.length > 40) return null;
  const v = raw.replace(/[\s-]/g, '').toUpperCase();
  switch (kind) {
    case 'pan': return /^[A-Z]{5}[0-9]{4}[A-Z]$/.test(v) ? { value: v, ifsc: null } : null;
    case 'aadhaar': return /^[2-9][0-9]{11}$/.test(v) && verhoeffOk(v) ? { value: v, ifsc: null } : null;
    case 'uan': return /^[0-9]{12}$/.test(v) ? { value: v, ifsc: null } : null;
    case 'bank': {
      const ifsc = typeof ifscRaw === 'string' ? ifscRaw.replace(/\s/g, '').toUpperCase() : '';
      return /^[0-9]{9,18}$/.test(v) && /^[A-Z]{4}0[A-Z0-9]{6}$/.test(ifsc) ? { value: v, ifsc } : null;
    }
  }
}

/** Pure: what the HMAC is computed over. The kind keeps an Aadhaar and a UAN (both 12 digits) apart. */
export const hmacInput = (kind: IdKind, value: string, ifsc: string | null) =>
  kind === 'bank' ? `bank:${(ifsc ?? '').slice(0, 4)}:${value}` : `${kind}:${value}`;

/** HMAC-SHA256, hex, with WebCrypto (Deno and Node 20+). The key is the text of ID_HMAC_KEY. */
export async function hmacHex(key: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey('raw', enc.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(message)));
  return [...sig].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** A key long enough to be a secret (at least 32 characters); the key's name (ID_HMAC_KEY_ID) is kept with each HMAC. */
export const keyUsable = (env: Env) => (env.ID_HMAC_KEY ?? '').length >= 32;

export async function handle(req: Request, env: Env): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method === 'GET') return answer(200, { function: 'id-numbers', version: VERSION, configured: keyUsable(env) });
  if (req.method !== 'POST') return answer(405, { code: 'POST_ONLY' });
  try {
    const url = (env.SUPABASE_URL ?? '').replace(/\/+$/, '');
    const anon = env.SB_PUBLISHABLE_KEY ?? env.SUPABASE_ANON_KEY ?? '';
    const service = env.SB_SECRET_KEY ?? env.SUPABASE_SERVICE_ROLE_KEY ?? '';
    if (!url || !anon || !service || !keyUsable(env)) return answer(500, { code: 'NOT_CONFIGURED' });
    const keyId = /^[a-z0-9_-]{1,20}$/.test(env.ID_HMAC_KEY_ID ?? '') ? env.ID_HMAC_KEY_ID! : 'k1';

    const token = (req.headers.get('authorization') ?? '').replace(/^Bearer\s*/i, '').trim();
    if (!token || token === anon) return answer(401, { code: 'SIGN_IN' });

    let body: Record<string, unknown>;
    try { body = await req.json(); } catch { return answer(400, { code: 'BAD_REQUEST' }); }
    const kind = String(body?.kind ?? '') as IdKind;
    const task = String(body?.task_id ?? '');
    if (!KINDS.includes(kind) || !/^[0-9a-f-]{36}$/i.test(task)) return answer(400, { code: 'BAD_REQUEST' });

    const n = normalise(kind, body.number, body.ifsc);
    if (!n) return answer(400, { code: 'BAD_FORMAT', kind });

    // 1. whose number: asked as the caller; the number is not sent
    const who = await fetch(`${url}/rest/v1/rpc/id_number_target`, {
      method: 'POST',
      headers: { apikey: anon, authorization: `Bearer ${token}`, 'content-type': 'application/json', 'content-profile': 'app' },
      body: JSON.stringify({ p_task: task, p_kind: kind }),
    });
    if (who.status === 401) return answer(401, { code: 'SIGN_IN' });
    const target = (await who.json().catch(() => null)) as { employee_id?: string; actor_id?: string } | null;
    if (!who.ok || !target?.employee_id || !target.actor_id) return answer(who.status === 400 ? 409 : 403, { code: who.status === 400 ? 'STEP_CLOSED' : 'NOT_ALLOWED' });

    // 2. the HMAC; only it and the last 4 leave this function
    const mac = await hmacHex(env.ID_HMAC_KEY!, hmacInput(kind, n.value, n.ifsc));
    const last4 = n.value.slice(-4);
    const rec = await fetch(`${url}/rest/v1/rpc/record_id_number`, {
      method: 'POST',
      headers: { apikey: service, authorization: `Bearer ${service}`, 'content-type': 'application/json', 'content-profile': 'app' },
      body: JSON.stringify({ p_task: task, p_actor: target.actor_id, p_kind: kind, p_hmac: mac, p_last4: last4, p_key: keyId, p_ifsc: n.ifsc }),
    });
    const out = (await rec.json().catch(() => null)) as { outcome?: string } | null;
    if (!rec.ok || !out?.outcome) return answer(502, { code: 'NOT_SAVED' });
    if (out.outcome === 'refused') return answer(409, { code: 'DUPLICATE' });
    return answer(200, { ok: true, kind, last4, outcome: out.outcome });
  } catch {
    // Whatever went wrong, the answer and the log say nothing of the request: a fixed code only.
    return answer(502, { code: 'FAILED' });
  }
}
