// Edge Function: on-demand ledger check for an uptime monitor (PRD §9 tamper evidence and evidence integrity).
// The nightly check runs inside Postgres (pg_cron, migration 21). This endpoint lets an external monitor (UptimeRobot,
// Better Stack, …) poll the same check and alert on a non-200, so a broken chain reaches a human the same day.
//
// GET/POST  header x-check-token: <LEDGER_CHECK_TOKEN>      (a long random secret set with `supabase secrets set`)
//   ?evidence=1   also re-hash the newest evidence files (up to EVIDENCE_LIMIT) against the SHA-256 recorded at upload
// 200 { ok: true, blocks, evidence_checked }   · 500 { ok: false, first_bad_seq, problem, evidence_bad }   · 401 bad token
//
// Runtime-neutral like create-user: Supabase runs it through index.ts (Deno.serve); the local stack runs it with Node.

type Env = Record<string, string | undefined>;
const EVIDENCE_LIMIT = 200;

/** The build of the four functions; the same value as in create-user/handler.ts (a unit test holds them together). */
export const VERSION = '2026-10-06';

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-grainveda-function': VERSION } });

function sameSecret(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function sha256Hex(buf: ArrayBuffer): Promise<string> {
  const h = await crypto.subtle.digest('SHA-256', buf);
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export async function handle(req: Request, env: Env): Promise<Response> {
  // SB_SECRET_KEY: the new-style secret key, set by hand once the legacy service_role key is retired (it takes precedence)
  const url = env.SUPABASE_URL, key = env.SB_SECRET_KEY ?? env.SUPABASE_SERVICE_ROLE_KEY, token = env.LEDGER_CHECK_TOKEN;
  if (!url || !key || !token) return json(500, { ok: false, problem: 'function not configured (SUPABASE_URL, service key, LEDGER_CHECK_TOKEN)' });
  if (!sameSecret(req.headers.get('x-check-token') ?? '', token)) return json(401, { ok: false, problem: 'bad token' });

  const svc = { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' };
  const r = await fetch(`${url}/rest/v1/rpc/run_ledger_check`, {
    method: 'POST', headers: { ...svc, 'content-profile': 'app' }, body: JSON.stringify({ p_source: 'monitor' }),
  });
  const check = await r.json().catch(() => null) as { ok?: boolean; blocks?: number; first_bad_seq?: number; problem?: string } | null;
  if (!r.ok || !check) return json(500, { ok: false, problem: `ledger check did not run (${r.status})` });

  const evidenceBad: { id: string; problem: string }[] = [];
  let evidenceChecked = 0;
  if (new URL(req.url).searchParams.get('evidence') === '1') {
    const a = await fetch(`${url}/rest/v1/attachments?select=id,storage_path,sha256&order=created_at.desc&limit=${EVIDENCE_LIMIT}`, { headers: svc });
    const rows = (await a.json().catch(() => [])) as { id: string; storage_path: string; sha256: string }[];
    for (const row of Array.isArray(rows) ? rows : []) {
      const f = await fetch(`${url}/storage/v1/object/evidence/${row.storage_path.split('/').map(encodeURIComponent).join('/')}`, { headers: svc });
      if (!f.ok) { evidenceBad.push({ id: row.id, problem: `file missing (${f.status})` }); continue; }
      evidenceChecked++;
      if ((await sha256Hex(await f.arrayBuffer())) !== row.sha256) evidenceBad.push({ id: row.id, problem: 'sha256 mismatch' });
    }
  }

  const ok = check.ok === true && evidenceBad.length === 0;
  return json(ok ? 200 : 500, {
    ok, blocks: check.blocks, first_bad_seq: check.first_bad_seq ?? null, problem: check.problem ?? null,
    evidence_checked: evidenceChecked, evidence_bad: evidenceBad,
  });
}
