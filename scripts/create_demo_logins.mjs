#!/usr/bin/env node
// Creates the demo logins in Supabase Auth and checks that migration 9 linked each one to its app_users row.
// Development project only. Run from the repo root:   node scripts/create_demo_logins.mjs
// Options:  --reset   set a new password for logins that already exist (otherwise they are left untouched)
//
// - Logins are created CONFIRMED through the Auth admin API, so no email or SMS is sent.
// - Passwords are random and written to .env.demo-logins (git-ignored by the `.env.*` rule). Never commit that file.
// - Idempotent: an existing login is reused; its password is kept unless --reset.
import { writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { supabaseConfig, client, readDemoLogins, DEMO_LOGINS_FILE, assertNotProduction } from './lib/env.mjs';
import { DEMO_USERS, appUserId } from './lib/demo-users.mjs';

const reset = process.argv.includes('--reset');
const cfg = supabaseConfig({ needService: true });
await assertNotProduction(cfg, 'creating demo logins');
const admin = (method, path, body) =>
  fetch(`${cfg.url}/auth/v1/admin${path}`, {
    method,
    headers: { apikey: cfg.service, Authorization: `Bearer ${cfg.service}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  }).then(async (r) => ({ status: r.status, ok: r.ok, data: await r.json().catch(() => null) }));

const digits = (p) => (p ?? '').replace(/[^0-9]/g, '');
const newPassword = () => `Gv-${randomBytes(12).toString('base64url')}`;

// 1. Existing logins
const existing = [];
for (let page = 1; ; page++) {
  const r = await admin('GET', `/users?page=${page}&per_page=200`);
  if (!r.ok) throw new Error(`listing users failed: ${r.status} ${JSON.stringify(r.data)}`);
  existing.push(...(r.data.users ?? []));
  if ((r.data.users ?? []).length < 200) break;
}
const findLogin = (u) => existing.find((a) =>
  (u.email && a.email?.toLowerCase() === u.email.toLowerCase()) || (u.phone && digits(a.phone) === digits(u.phone)));

// 2. Create or reuse
const passwords = readDemoLogins();
const results = [];
for (const u of DEMO_USERS) {
  let login = findLogin(u);
  let action;
  if (!login) {
    const pw = newPassword();
    const body = u.email ? { email: u.email, password: pw, email_confirm: true }
                         : { phone: digits(u.phone), password: pw, phone_confirm: true };
    // app_metadata.grainveda_login: since migration 23 only a login made by the service role links to a user row
    const r = await admin('POST', '/users', { ...body, app_metadata: { grainveda_login: true }, user_metadata: { display_name: u.name } });
    if (!r.ok) { results.push({ ...u, action: `CREATE FAILED ${r.status} ${r.data?.msg ?? r.data?.message ?? ''}` }); continue; }
    login = r.data; passwords[u.key] = pw; action = 'created';
  } else if (reset || !passwords[u.key]) {
    const pw = newPassword();
    const r = await admin('PUT', `/users/${login.id}`, { password: pw });
    if (!r.ok) { results.push({ ...u, action: `RESET FAILED ${r.status}` }); continue; }
    passwords[u.key] = pw; action = 'existing, password set';
  } else {
    action = 'existing, unchanged';
  }
  results.push({ ...u, loginId: login.id, action });
}

writeFileSync(DEMO_LOGINS_FILE,
  '# Demo login passwords for the DEVELOPMENT project. Git-ignored. Do not share or commit.\n' +
  DEMO_USERS.map((u) => `DEMO_${u.key}_PASSWORD=${passwords[u.key] ?? ''}`).join('\n') + '\n');

// 3. Linking check (migration 9 links a confirmed login to its app_users row)
const svc = client(cfg, { key: cfg.service });
const rows = await svc.get('app_users', 'select=id,display_name,role,auth_uid,email,phone');
if (!rows.ok) throw new Error(`reading app_users failed: ${rows.status} ${JSON.stringify(rows.data)}`);
let bad = 0;
console.log('key  role            login  linked  who');
for (const r of results) {
  const row = rows.data.find((x) => x.id === appUserId(r.key));
  const linked = row && r.loginId && row.auth_uid === r.loginId;
  if (!linked) bad++;
  console.log(`${r.key}  ${r.role.padEnd(14)}  ${(r.loginId ? 'yes' : 'NO').padEnd(5)}  ${(linked ? 'yes' : 'NO').padEnd(6)}  ${r.name} (${r.email ?? r.phone}) — ${r.action}` +
    (row ? '' : '  [no app_users row: run the seeds first]'));
}
console.log(`\npasswords: ${DEMO_LOGINS_FILE}`);
if (bad) { console.error(`\n${bad} login(s) not linked. Check seeds 02–04 are applied and phones/emails match.`); process.exit(1); }
console.log('\nALL DEMO LOGINS CREATED AND LINKED');
