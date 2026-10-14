#!/usr/bin/env node
// The daily outside copy of the ledger's fingerprint (migration 45, Veda 14 Oct 2026: "when in production … can such
// thing happen and not recorded?"). Run by .github/workflows/ledger-anchor.yml (installed from
// scripts/templates/ledger-anchor.yml) once a day, or by hand.
//
//   1. reads the copies kept so far (a CSV file on the ledger-anchors branch, one line a day);
//   2. asks the project whether every earlier copy still matches (app.anchor_check): a ledger or change log rewritten
//      since, even with every hash recomputed, no longer matches what was copied out on the day;
//   3. adds today's fingerprints (app.ledger_head).
// A mismatch ends with exit code 1 and "ANCHOR MISMATCH": GitHub then marks the run failed and emails the person who
// set up the schedule. It uses the public key only (the two functions return hashes, nothing else).
//
// Environment: GV_TARGET (a name: staging, production), GV_SUPABASE_URL, GV_SUPABASE_ANON_KEY, ANCHOR_FILE.
// It prints no key.
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';

const target = process.env.GV_TARGET || 'staging';
const url = (process.env.GV_SUPABASE_URL || '').replace(/\/+$/, '');
const key = process.env.GV_SUPABASE_ANON_KEY || '';
const file = process.env.ANCHOR_FILE || `anchors/${target}.csv`;
const HEADER = 'date_utc,environment,ledger_seq,ledger_hash,change_seq,change_hash';

if (!url || !key) { console.log(`${target}: not set up (GV_SUPABASE_URL / GV_SUPABASE_ANON_KEY missing): skipped`); process.exit(0); }

async function call(fn, body) {
  const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', 'Content-Profile': 'app', 'Accept-Profile': 'app' },
    body: JSON.stringify(body ?? {}),
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`${fn}: HTTP ${r.status} ${text.slice(0, 200)}`);
  return JSON.parse(text);
}

const lines = existsSync(file) ? readFileSync(file, 'utf8').split(/\r?\n/).filter((l) => l && !l.startsWith('date_utc')) : [];
const copies = [];
for (const l of lines) {
  const [, , ls, lh, cs, ch] = l.split(',');
  if (ls && lh) copies.push({ kind: 'ledger', seq: Number(ls), hash: lh });
  if (cs && ch) copies.push({ kind: 'change_log', seq: Number(cs), hash: ch });
}
let checked = 0;
for (let i = 0; i < copies.length; i += 400) {
  const res = await call('anchor_check', { p: copies.slice(i, i + 400) });
  checked += Number(res.checked ?? 0);
  if (!res.ok) {
    console.log(`ANCHOR MISMATCH (${target}): the ${res.kind === 'ledger' ? 'ledger block' : 'change-log line'} #${res.seq} is ${res.problem} `
      + `from the copy kept outside the database. Someone changed the ${res.kind === 'ledger' ? 'ledger' : 'change log'} after it was copied. `
      + 'Do not repair anything: tell the database owners and keep this run.');
    process.exit(1);
  }
}
const head = await call('ledger_head', {});
if (!existsSync(file)) writeFileSync(file, HEADER + '\n');
const day = new Date().toISOString().slice(0, 10);
const last = lines[lines.length - 1]?.split(',') ?? [];
const same = last[2] === String(head.ledger?.seq ?? '') && last[4] === String(head.change_log?.seq ?? '');
if (!same) {
  appendFileSync(file, [day, head.environment ?? '', head.ledger?.seq ?? '', head.ledger?.hash ?? '', head.change_log?.seq ?? '', head.change_log?.hash ?? ''].join(',') + '\n');
}
console.log(`ANCHOR OK (${target}): ${checked} earlier fingerprints still match; today: ledger #${head.ledger?.seq ?? '—'}, `
  + `change log #${head.change_log?.seq ?? '—'}${same ? ' (unchanged since the last copy: not added again)' : ' (added)'}`);
