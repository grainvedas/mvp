#!/usr/bin/env node
// REMOVES EVERY LOGIN AND EVERY STORED FILE of the practice system. Part of the fresh start
// (scripts/staging_fresh_start.ps1): the database is emptied first, then this, then the first admin is made again.
// NOT REVERSIBLE. Never on production.
//
//   node scripts/fresh_start/clear_logins_and_files.mjs --empty-staging
//   ENV_FILE=.env.stack node scripts/fresh_start/clear_logins_and_files.mjs --empty-staging
//
// Refuses: without the flag; on the production project; while the database still holds a person (a login is only
// removed when nobody is left for it to belong to: run the database step first).
// Prints counts, never an address or a file name.
import { supabaseConfig, client, assertNotProduction } from '../lib/env.mjs';

if (!process.argv.includes('--empty-staging')) {
  console.error('usage: node scripts/fresh_start/clear_logins_and_files.mjs --empty-staging   (removes every login and stored file; not reversible)');
  process.exit(2);
}
const cfg = supabaseConfig({ needService: true });
await assertNotProduction(cfg, 'removing every login and stored file');
const svc = client(cfg, { key: cfg.service });
const headers = { apikey: cfg.service, Authorization: `Bearer ${cfg.service}`, 'Content-Type': 'application/json' };
console.log(`project: ${new URL(cfg.url).host}`);

const people = await svc.get('app_users', 'select=id&limit=1');
if (!people.ok) { console.error(`cannot read app_users (HTTP ${people.status}).`); process.exit(1); }
if (people.data.length > 0) {
  console.error('REFUSED: the database still holds people. Nothing was removed. Empty the database first (scripts/fresh_start/empty_staging.sql).');
  process.exit(3);
}

// 1. logins
const listLogins = async () => {
  const all = [];
  for (let page = 1; ; page++) {
    const r = await fetch(`${cfg.url}/auth/v1/admin/users?page=${page}&per_page=200`, { headers });
    const d = await r.json().catch(() => null);
    if (!r.ok) throw new Error(`listing logins failed: HTTP ${r.status}`);
    all.push(...(d?.users ?? []));
    if ((d?.users ?? []).length < 200) break;
  }
  return all;
};
let logins = await listLogins();
let removed = 0, failed = 0;
for (const l of logins) {
  const r = await fetch(`${cfg.url}/auth/v1/admin/users/${l.id}`, { method: 'DELETE', headers });
  if (r.ok || r.status === 404) removed++; else { failed++; console.log(`FAIL  a login could not be removed (HTTP ${r.status})`); }
}
logins = await listLogins();
console.log(`logins removed: ${removed}   left: ${logins.length}`);
if (failed || logins.length > 0) { console.error('NOT ALL LOGINS REMOVED. Run this again.'); process.exit(1); }

// 2. stored files: evidence photos and HR documents
let bad = 0;
for (const bucket of ['evidence', 'hr-docs']) {
  const e = await fetch(`${cfg.url}/storage/v1/bucket/${bucket}/empty`, { method: 'POST', headers, body: '{}' });
  const text = await e.text();
  if (!e.ok) {
    if (e.status === 404 || /not found/i.test(text)) { console.log(`store ${bucket}: does not exist on this project`); continue; }
    bad++; console.log(`FAIL  store ${bucket}: could not be emptied (HTTP ${e.status})`); continue;
  }
  // emptying a large store is finished in the background: look until nothing is listed (up to a minute)
  let left = -1;
  for (let i = 0; i < 12; i++) {
    const l = await fetch(`${cfg.url}/storage/v1/object/list/${bucket}`, { method: 'POST', headers, body: JSON.stringify({ prefix: '', limit: 10, offset: 0 }) });
    const d = await l.json().catch(() => null);
    if (!l.ok || !Array.isArray(d)) { left = -1; break; }
    left = d.length;
    if (left === 0) break;
    await new Promise((r) => setTimeout(r, 5000));
  }
  if (left === 0) console.log(`store ${bucket}: empty`);
  else { bad++; console.log(left < 0 ? `FAIL  store ${bucket}: emptied, but its contents could not be listed to make sure` : `FAIL  store ${bucket}: still holds files`); }
}
if (bad) { console.error('STORED FILES NOT ALL REMOVED. Run this again.'); process.exit(1); }
console.log('\nLOGINS AND FILES REMOVED');
