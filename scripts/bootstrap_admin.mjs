#!/usr/bin/env node
// Creates the FIRST admin of a project (production go-live, or a fresh staging project). Run once, from the repo root:
//   ENV_FILE=.env.production node scripts/bootstrap_admin.mjs --email veda@example.com --name "Veda"
// ENV_FILE names the git-ignored file that holds that project's SUPABASE_URL, anon key and service-role key.
//
// - Refuses if the project already has an admin (people are added by HR in the app: HR · Joiners → Add joiner).
//   To add another admin on purpose: --additional. That is also the BREAK-GLASS tool when every admin is locked out
//   (docs/OPERATIONS.md "Seats, and break glass"): nothing in the app can make an admin.
// - Since the identity layer (migration 31) the admin is a system role. The row is written the way a seed writes it
//   (role = admin, no signed-in person); the database turns it into the root seat and notes it in the audit log.
// - The login is created confirmed through the Auth admin API (no e-mail is sent), marked as made by the service
//   role (login linking, migration 23) and marked "must set an own password".
// - The temporary password is NOT printed. It is written to .env.admin-login (git-ignored by `.env.*`): open the file,
//   sign in, set your own password when the app asks, then delete the file.
import { randomBytes } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { supabaseConfig, client, environmentOf, ROOT } from './lib/env.mjs';

const arg = (name) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : undefined; };
const email = (arg('email') ?? '').trim().toLowerCase();
const name = (arg('name') ?? '').trim();
const additional = process.argv.includes('--additional');
if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !name) {
  console.error('usage: ENV_FILE=<env file> node scripts/bootstrap_admin.mjs --email <address> --name "<display name>" [--additional]');
  process.exit(2);
}

const cfg = supabaseConfig({ needService: true });
const svc = client(cfg, { key: cfg.service });
const authHeaders = { apikey: cfg.service, Authorization: `Bearer ${cfg.service}`, 'Content-Type': 'application/json' };
const env = await environmentOf(cfg);
console.log(`project: ${cfg.url}  (environment: ${env})`);

// (role is the summary the database keeps in step with the system role: it reads the same before and after migration 31)
const admins = await svc.get('app_users', 'role=eq.admin&active=is.true&select=id,display_name,active');
if (!admins.ok) { console.error(`cannot read app_users (${admins.status}). Are all migrations pushed and is the service key right?`); process.exit(1); }
if (admins.data.length > 0 && !additional) {
  console.error(`REFUSED: this project already has ${admins.data.length} admin(s). People are added in the app (HR · Joiners → Add joiner). To add another admin on purpose (break glass): --additional.`);
  process.exit(3);
}
const taken = await svc.get('app_users', `email=ilike.${encodeURIComponent(email)}&select=id`);
if (taken.ok && taken.data.length > 0) { console.error('REFUSED: a user with this e-mail already exists.'); process.exit(3); }

// 1. the user row (the service role is not subject to the app_users guard)
const row = await svc.insert('app_users', { role: 'admin', display_name: name, email });
if (!row.ok) { console.error(`user row not created: ${row.status} ${JSON.stringify(row.data)}`); process.exit(1); }
const appUserId = row.data[0].id;
const undo = () => svc.raw('DELETE', `/rest/v1/app_users?id=eq.${appUserId}`);

// 2. the login
const password = `Gv-${randomBytes(15).toString('base64url')}`;
const res = await fetch(`${cfg.url}/auth/v1/admin/users`, { method: 'POST', headers: authHeaders,
  body: JSON.stringify({ email, password, email_confirm: true, app_metadata: { grainveda_login: true },
    user_metadata: { display_name: name, must_change_password: true } }) });
const login = await res.json().catch(() => null);
if (!res.ok || !login?.id) {
  await undo();
  console.error(`login not created: ${res.status} ${login?.msg ?? login?.message ?? ''} (user row removed again)`);
  process.exit(1);
}

// 3. linked?
const chk = await svc.get('app_users', `id=eq.${appUserId}&select=auth_uid`);
if (chk.data?.[0]?.auth_uid !== login.id) {
  await fetch(`${cfg.url}/auth/v1/admin/users/${login.id}`, { method: 'DELETE', headers: authHeaders });
  await undo();
  console.error('login created but not linked to the user row (is migration 23 pushed?). Both removed again.');
  process.exit(1);
}

const file = join(ROOT, '.env.admin-login');
writeFileSync(file, `# First admin of ${cfg.url}. Git-ignored. Sign in, set your own password, then DELETE this file.\nADMIN_EMAIL=${email}\nADMIN_TEMPORARY_PASSWORD=${password}\n`);
console.log(`ADMIN CREATED AND LINKED: ${name} <${email}>`);
console.log('temporary password: in .env.admin-login (not shown here). Sign in, set your own password, then delete that file.');
