#!/usr/bin/env node
// Logins and people that do not belong together.
//   node scripts/check_logins.mjs               list only (the project of .env.local; ENV_FILE=.env.production for production)
//   node scripts/check_logins.mjs --remove      also delete the logins that belong to no person
// A login (Supabase Auth) and a person (app_users) are made in two steps by the create-user function. When the second
// step fails the function takes both back; if it was cut off, or the Auth server refused the delete, a login without
// a person can stay behind. It opens nothing (a login without a person has no role and sees no data), but it holds
// the phone number or e-mail: the next attempt to create that person answers "already registered".
// Passwords and keys are never printed; phone numbers and e-mails are shown shortened.
import { supabaseConfig } from './lib/env.mjs';

const cfg = supabaseConfig({ needService: true });
const remove = process.argv.includes('--remove');
const svc = { apikey: cfg.service, authorization: `Bearer ${cfg.service}`, 'content-type': 'application/json' };
const short = (s) => !s ? '—' : s.includes('@') ? s.replace(/^(.).*(@.*)$/, '$1…$2') : `…${String(s).slice(-4)}`;

const logins = [];
for (let page = 1; page < 200; page++) {
  const r = await fetch(`${cfg.url}/auth/v1/admin/users?page=${page}&per_page=200`, { headers: svc });
  if (!r.ok) { console.error(`FAIL  the Auth server refused the list (HTTP ${r.status}). Is SUPABASE_SERVICE_ROLE_KEY in the env file the service key of this project?`); process.exit(1); }
  const batch = (await r.json()).users ?? [];
  logins.push(...batch);
  if (batch.length < 200) break;
}
const pr = await fetch(`${cfg.url}/rest/v1/app_users?select=id,display_name,role,active,auth_uid`, { headers: svc });
if (!pr.ok) { console.error(`FAIL  app_users could not be read (HTTP ${pr.status})`); process.exit(1); }
const people = await pr.json();

const claimed = new Set(people.map((p) => p.auth_uid).filter(Boolean));
const known = new Set(logins.map((l) => l.id));
const orphans = logins.filter((l) => !claimed.has(l.id));
const noLogin = people.filter((p) => p.active && (!p.auth_uid || p.auth_uid === p.id || !known.has(p.auth_uid)));

console.log(`project: ${new URL(cfg.url).host}   logins: ${logins.length}   people: ${people.length}`);
console.log(`\nLogins that belong to no person: ${orphans.length}`);
for (const l of orphans) {
  console.log(`  ${l.id}  ${short(l.email || l.phone)}  made ${String(l.created_at).slice(0, 16)}  `
    + `${l.app_metadata?.grainveda_login === true ? 'made by GrainVeda service code' : 'NOT made by GrainVeda service code (a sign-up, the dashboard, or the create-user function before 2 Oct 2026)'}`);
}
console.log(`\nActive people without a login (they cannot sign in): ${noLogin.length}`);
for (const p of noLogin) console.log(`  ${p.display_name} (${p.role})`);

if (remove && orphans.length) {
  let failed = 0;
  for (const l of orphans) {
    const d = await fetch(`${cfg.url}/auth/v1/admin/users/${l.id}`, { method: 'DELETE', headers: svc });
    if (d.ok || d.status === 404) console.log(`removed ${l.id}`); else { failed++; console.log(`FAIL  could not remove ${l.id} (HTTP ${d.status})`); }
  }
  if (failed) process.exit(1);
  console.log('\nLOGINS WITHOUT A PERSON REMOVED');
} else if (orphans.length) {
  console.log('\nTo remove the logins that belong to no person: node scripts/check_logins.mjs --remove');
  process.exit(1);
} else console.log('\nNO LOGIN WITHOUT A PERSON');
