#!/usr/bin/env node
// ledger-check Edge Function, end to end. Safe on the live project (it only reads, and records one check row).
//   node tests/remote_ledger_check.mjs                         live: needs LEDGER_CHECK_TOKEN in .env.local
//   ENV_FILE=.env.stack node tests/remote_ledger_check.mjs --tamper-local
//       local stack only: also alters one ledger block through psql (PGHOST/PGPORT/PGUSER, DB grainveda_stack),
//       expects HTTP 500 naming that block, then puts the original value back and expects 200 again.
import { execFileSync } from 'node:child_process';
import { loadEnv, supabaseConfig } from '../scripts/lib/env.mjs';

const cfg = supabaseConfig();
const token = loadEnv().LEDGER_CHECK_TOKEN;
if (!token) { console.error('LEDGER_CHECK_TOKEN is not set (.env.local on the live project, .env.stack locally)'); process.exit(2); }
let passes = 0, failures = 0;
const ok = (c, n, d = '') => { if (c) { passes++; console.log(`ok    ${n}`); } else { failures++; console.log(`FAIL  ${n}  -> ${d}`); } };
const call = async (tok, q = '') => {
  const h = { apikey: cfg.anon, authorization: `Bearer ${cfg.anon}` };
  if (tok !== null) h['x-check-token'] = tok;
  const r = await fetch(`${cfg.url}/functions/v1/ledger-check${q}`, { headers: h });
  return { status: r.status, data: await r.json().catch(() => null) };
};

let r = await call(null);
ok(r.status === 401, 'no token → 401', JSON.stringify(r));
r = await call('x'.repeat(token.length));
ok(r.status === 401, 'wrong token → 401', JSON.stringify(r));
r = await call(token);
ok(r.status === 200 && r.data?.ok === true && r.data.blocks > 0, `right token → 200, chain intact (${r.data?.blocks} blocks)`, JSON.stringify(r));
r = await call(token, '?evidence=1');
ok(r.status === 200 && Array.isArray(r.data?.evidence_bad) && r.data.evidence_bad.length === 0,
   `evidence re-hash → 200 (${r.data?.evidence_checked} files checked)`, JSON.stringify(r));

if (process.argv.includes('--tamper-local')) {
  if (!/127\.0\.0\.1|localhost/.test(cfg.url)) { console.error('--tamper-local is for the local stack only'); process.exit(2); }
  const psql = (sql) => execFileSync('psql', ['-d', process.env.STACK_DB ?? 'grainveda_stack', '-Atqc', sql], { encoding: 'utf8' }).trim();
  const [seq, orig] = psql('select seq, payload_hash from public.ledger order by seq desc offset 2 limit 1').split('|');
  const set = (v) => psql(`begin; set local session_replication_role = replica; update public.ledger set payload_hash = '${v}' where seq = ${seq}; commit;`);
  set('0'.repeat(64));
  try {
    r = await call(token);
    ok(r.status === 500 && r.data?.ok === false && String(r.data.first_bad_seq) === seq && r.data.problem === 'payload_hash mismatch',
       `altered block ${seq} → 500 naming that block`, JSON.stringify(r));
  } finally { set(orig); }
  r = await call(token);
  ok(r.status === 200 && r.data?.ok === true, 'original value restored → 200 again', JSON.stringify(r));
}

console.log(`\n${passes} passed, ${failures} failed`);
console.log(failures ? 'LEDGER CHECK TEST FAILED' : 'LEDGER CHECK TEST PASSED');
process.exit(failures ? 1 : 0);
