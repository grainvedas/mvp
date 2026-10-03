#!/usr/bin/env node
// B5 create-user Edge Function, end to end with real logins. LOCAL STACK / CI ONLY: it creates users.
//   ENV_FILE=.env.stack node tests/remote_create_user.mjs
import { supabaseConfig, client, signIn, readDemoLogins, assertNotProduction } from '../scripts/lib/env.mjs';
import { demoUser } from '../scripts/lib/demo-users.mjs';

const cfg = supabaseConfig({ needService: true });
if (!/127\.0\.0\.1|localhost/.test(cfg.url) && !process.argv.includes('--i-know-this-creates-users')) {
  console.error('refusing to run against a non-local project: it creates users. Use the local stack.'); process.exit(2);
}
await assertNotProduction(cfg, 'the create-user / reset-password test');
const pw = readDemoLogins();
let passes = 0, failures = 0;
const ok = (c, n, d = '') => { if (c) { passes++; console.log(`ok    ${n}`); } else { failures++; console.log(`FAIL  ${n}  -> ${d}`); } };
const token = async (key) => { const u = demoUser(key); return signIn(cfg, { email: u.email, phone: u.phone?.replace(/[^0-9]/g, ''), password: pw[key] }); };
const call = async (tok, body) => {
  const r = await fetch(`${cfg.url}/functions/v1/create-user`, {
    method: 'POST', headers: { apikey: cfg.anon, authorization: `Bearer ${tok}`, 'content-type': 'application/json' }, body: JSON.stringify(body) });
  return { status: r.status, data: await r.json().catch(() => null) };
};
const suffix = String(Date.now()).slice(-6);
const prasaadam = '00000000-0000-4000-8000-000000000201', other = '00000000-0000-4000-8000-000000000202';
const svc = client(cfg, { key: cfg.service });

const cm = await token('303'), qc = await token('306'), sm = await token('302');

let r = await call(cfg.anon, { role: 'operator', display_name: 'x', phone: '9876543210', client_id: prasaadam });
ok(r.status === 401, 'not signed in → 401', JSON.stringify(r));

const phone = `98${suffix}01`;
r = await call(cm, { role: 'operator', display_name: `Test Operator ${suffix}`, phone, client_id: prasaadam,
                     slot: { scope_id: '00000000-0000-4000-8000-000000000401', stage_type: 'procurement' } });
ok(r.status === 201 && r.data?.temporary_password, 'client manager creates an operator with a slot → 201', JSON.stringify(r));
if (r.status === 201) {
  const t = await signIn(cfg, { phone: `91${phone}`, password: r.data.temporary_password });
  const me = client(cfg, { key: cfg.anon, token: t, profile: 'app' });
  const ctx = await me.rpc('my_context');
  ok(ctx.data?.user?.role === 'operator' && ctx.data?.slots?.length === 1 && ctx.data.slots[0].stage_type === 'procurement',
     'the new operator signs in with the temporary password and has the procurement slot', JSON.stringify(ctx.data));
}

r = await call(cm, { role: 'operator', display_name: 'Dup', phone, client_id: prasaadam });
ok(r.status === 409, 'same phone again → 409', JSON.stringify(r));
const dupRows = await svc.get('app_users', `display_name=eq.Dup&select=id`);
ok(dupRows.ok && dupRows.data.length === 0, 'a refused create leaves no user row behind', JSON.stringify(dupRows.data));

r = await call(cm, { role: 'state_manager', display_name: 'Nope', email: `nope${suffix}@example.test`, state_ids: ['00000000-0000-4000-8000-000000000001'] });
ok(r.status === 403, 'client manager cannot create a State Manager → 403', JSON.stringify(r));

r = await call(cm, { role: 'operator', display_name: 'Wrong client', phone: `98${suffix}02`, client_id: other });
ok(r.status === 403, 'client manager cannot create an operator for another client → 403', JSON.stringify(r));

r = await call(qc, { role: 'operator', display_name: 'By operator', phone: `98${suffix}03`, client_id: prasaadam });
ok(r.status === 403, 'an operator cannot create users → 403', JSON.stringify(r));

r = await call(sm, { role: 'client_manager', display_name: `CM ${suffix}`, email: `cm${suffix}@example.test`, client_id: prasaadam });
ok(r.status === 201, 'State Manager creates a Client Manager in own state → 201', JSON.stringify(r));

r = await call(cm, { role: 'operator', display_name: 'Bad phone', phone: '12345', client_id: prasaadam });
ok(r.status === 400, 'invalid phone → 400', JSON.stringify(r));

const orphans = await svc.get('app_users', `display_name=in.("Wrong client","By operator","Bad phone","Nope")&select=id`);
ok(orphans.ok && orphans.data.length === 0, 'no user rows left behind by refused calls', JSON.stringify(orphans.data));

// ---------------------------------------------------------------------------------------------------------------
// Phase 4: first sign-in must set an own password; a manager can reset; a public sign-up can never become a user
// ---------------------------------------------------------------------------------------------------------------
const claims = (jwt) => JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString('utf8'));
const reset = async (tok, id) => {
  const res = await fetch(`${cfg.url}/functions/v1/reset-password`, {
    method: 'POST', headers: { apikey: cfg.anon, authorization: `Bearer ${tok}`, 'content-type': 'application/json' }, body: JSON.stringify({ app_user_id: id }) });
  return { status: res.status, data: await res.json().catch(() => null) };
};
const tryIn = async (cred) => { try { return await signIn(cfg, cred); } catch { return null; } };

const phone2 = `97${suffix}04`;
r = await call(cm, { role: 'operator', display_name: `Password Test ${suffix}`, phone: phone2, client_id: prasaadam });
ok(r.status === 201, 'client manager creates an operator for the password checks', JSON.stringify(r));
const target = r.data?.app_user_id, temp1 = r.data?.temporary_password;
let tok = await tryIn({ phone: `91${phone2}`, password: temp1 });
ok(tok && claims(tok).user_metadata?.must_change_password === true, 'a new login is marked: must set an own password at first sign-in');
ok(tok && claims(tok).app_metadata?.grainveda_login === true, 'a new login carries the service-role mark that login linking requires');

// the user sets an own password (what the app's forced screen does)
const own = `Own-${suffix}-pw`;
let u = await fetch(`${cfg.url}/auth/v1/user`, { method: 'PUT',
  headers: { apikey: cfg.anon, authorization: `Bearer ${tok}`, 'content-type': 'application/json' },
  body: JSON.stringify({ password: own, data: { must_change_password: false } }) });
ok(u.ok, 'the operator sets an own password', `${u.status}`);
ok((await tryIn({ phone: `91${phone2}`, password: temp1 })) === null, 'the temporary password no longer works');
tok = await tryIn({ phone: `91${phone2}`, password: own });
ok(tok && claims(tok).user_metadata?.must_change_password === false, 'the own password works and the mark is cleared');

// reset by a manager
r = await reset(cfg.anon, target);
ok(r.status === 401, 'reset without a login → 401', JSON.stringify(r));
r = await reset(qc, target);
ok(r.status === 403, 'an operator cannot reset a password → 403', JSON.stringify(r));
r = await reset(cm, '00000000-0000-4000-8000-000000000302');
ok(r.status === 403, 'a Client Manager cannot reset the State Manager → 403', JSON.stringify(r));
r = await reset(cm, '00000000-0000-4000-8000-000000000303');
ok(r.status === 403, 'nobody resets their own password this way → 403', JSON.stringify(r));
r = await reset(cm, '00000000-0000-4000-8000-000000000312');
ok(r.status === 403, 'a Client Manager cannot reset another client\'s operator → 403', JSON.stringify(r));
// a session open on the person's phone before the reset (the "lost phone" case)
const openSession = await (await fetch(`${cfg.url}/auth/v1/token?grant_type=password`, { method: 'POST',
  headers: { apikey: cfg.anon, 'content-type': 'application/json' }, body: JSON.stringify({ phone: `91${phone2}`, password: own }) })).json();
const refresh = async (rt) => (await fetch(`${cfg.url}/auth/v1/token?grant_type=refresh_token`, { method: 'POST',
  headers: { apikey: cfg.anon, 'content-type': 'application/json' }, body: JSON.stringify({ refresh_token: rt }) })).status;
r = await reset(cm, target);
ok(r.status === 200 && r.data?.temporary_password && r.data.temporary_password !== temp1, 'the Client Manager resets his operator → 200 with a new temporary password', JSON.stringify({ status: r.status }));
ok((await tryIn({ phone: `91${phone2}`, password: own })) === null, 'after the reset the old own password no longer works');
const refreshed = openSession?.refresh_token ? await refresh(openSession.refresh_token) : 0;
ok(refreshed >= 400, 'a session that was open before the reset cannot be renewed (it ends when its token expires, within the hour)', `refresh answered ${refreshed}`);
tok = await tryIn({ phone: `91${phone2}`, password: r.data?.temporary_password });
ok(tok && claims(tok).user_metadata?.must_change_password === true, 'the new temporary password works and must be changed again');
const ctx2 = tok ? await client(cfg, { key: cfg.anon, token: tok, profile: 'app' }).rpc('my_context') : null;
ok(ctx2?.data?.user?.id === target, 'it is still the same user row');

// a public sign-up with the e-mail of a user row that has no login must not become that user
const ghostMail = `ghost${suffix}@example.test`;
const ghost = await svc.insert('app_users', { role: 'client_view', display_name: `Ghost ${suffix}`, email: ghostMail, client_id: prasaadam });
const su = await fetch(`${cfg.url}/auth/v1/signup`, { method: 'POST', headers: { apikey: cfg.anon, 'content-type': 'application/json' },
  body: JSON.stringify({ email: ghostMail, password: `Pub-${suffix}-signup` }) });
const suData = await su.json().catch(() => ({}));
if (!su.ok) {
  ok(true, `public sign-up is switched off on this project (${su.status})`);
} else {
  const st = suData.access_token ?? await tryIn({ email: ghostMail, password: `Pub-${suffix}-signup` });
  const role = st ? await client(cfg, { key: cfg.anon, token: st, profile: 'app' }).rpc('current_role') : { data: null };
  ok(role.data === null, 'public sign-up is open here, yet a sign-up with a user\'s e-mail gets NO role (before migration 23: that user\'s role)', JSON.stringify(role.data));
  const linked = await svc.get('app_users', `id=eq.${ghost.data?.[0]?.id}&select=auth_uid`);
  ok(linked.data?.[0]?.auth_uid === null, 'the user row stays unlinked', JSON.stringify(linked.data));
  const signedUpId = suData.user?.id ?? suData.id;
  if (signedUpId) await fetch(`${cfg.url}/auth/v1/admin/users/${signedUpId}`, { method: 'DELETE', headers: { apikey: cfg.service, authorization: `Bearer ${cfg.service}` } });
}
await svc.raw('DELETE', `/rest/v1/app_users?id=eq.${ghost.data?.[0]?.id}`);

console.log(`\n${passes} passed, ${failures} failed`);
if (failures) process.exit(1);
console.log('CREATE-USER PASSED');
