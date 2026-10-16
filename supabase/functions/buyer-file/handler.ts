// Edge Function: a file of a buyer's page (migration 56, Part F: Veda, 16 Oct 2026, "proceed with 56"). A buyer opens a
// sale or a shipment through his link (/b/<token>) without a sign-in. The page lists the files he may open: the lab
// reports, the export documents received, the loading photos and proofs of delivery. Evidence files are private, so
// this function asks the database (app.buyer_file, the service role only) whether the link is live and the file is one
// of its page's; if so it signs a download that lasts two minutes. Every file opened is logged by the database.
//
// POST { token, file }   → 200 { url, label, sha256 }   · 404 { problem: 'link' | 'file' }   · 400 a malformed request
// GET                    → { function, version }
//
// Nothing secret is logged: no token, no signed address. Runtime-neutral like the others: Supabase runs it through
// index.ts (Deno.serve); the local stack runs it with Node.
type Env = Record<string, string | undefined>;

/** The build of this function. (The six older functions keep their own common build; this one is deployed apart.) */
export const VERSION = '2026-10-16';
export const SIGNED_SECONDS = 120;

const cors = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  'access-control-expose-headers': 'x-grainveda-function',
  'x-grainveda-function': VERSION,
};
const answer = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'content-type': 'application/json', 'cache-control': 'no-store' } });

export const tokenShape = (t: unknown): t is string => typeof t === 'string' && /^[0-9a-f]{48}$/.test(t);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function handle(req: Request, env: Env): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method === 'GET') return answer(200, { function: 'buyer-file', version: VERSION });
  if (req.method !== 'POST') return answer(405, { problem: 'method' });
  const url = env.SUPABASE_URL, key = env.SB_SECRET_KEY ?? env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return answer(500, { problem: 'function not configured (SUPABASE_URL, service key)' });
  const body = (await req.json().catch(() => null)) as { token?: unknown; file?: unknown } | null;
  if (!body || !tokenShape(body.token) || typeof body.file !== 'string' || !UUID.test(body.file)) return answer(400, { problem: 'request' });

  const svc = { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' };
  const r = await fetch(`${url}/rest/v1/rpc/buyer_file`, {
    method: 'POST', headers: { ...svc, 'content-profile': 'app' }, body: JSON.stringify({ p_token: body.token, p_file: body.file }),
  });
  const f = (await r.json().catch(() => null)) as { ok?: boolean; problem?: string; path?: string; sha256?: string; label?: string } | null;
  if (!r.ok || !f) return answer(502, { problem: 'database' });
  if (!f.ok || !f.path) return answer(404, { problem: f.problem === 'file' ? 'file' : 'link' });

  const path = f.path.split('/').map(encodeURIComponent).join('/');
  const s = await fetch(`${url}/storage/v1/object/sign/evidence/${path}`, { method: 'POST', headers: svc, body: JSON.stringify({ expiresIn: SIGNED_SECONDS }) });
  const signed = (await s.json().catch(() => null)) as { signedURL?: string } | null;
  if (!s.ok || !signed?.signedURL) return answer(404, { problem: 'file' });
  return answer(200, { url: `${url}/storage/v1${signed.signedURL}`, label: f.label ?? null, sha256: f.sha256 ?? null });
}
