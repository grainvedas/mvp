#!/usr/bin/env node
// B5 create-user Edge Function, end to end with real logins. LOCAL STACK / CI ONLY: it creates users.
//   ENV_FILE=.env.stack node tests/remote_create_user.mjs
import { supabaseConfig, client, signIn, readDemoLogins } from '../scripts/lib/env.mjs';
import { demoUser } from '../scripts/lib/demo-users.mjs';

const cfg = supabaseConfig({ needService: true });
if (!/127\.0\.0\.1|localhost/.test(cfg.url) && !process.argv.includes('--i-know-this-creates-users')) {
  console.error('refusing to run against a non-local project: it creates users. Use the local stack.'); process.exit(2);
}
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

console.log(`\n${passes} passed, ${failures} failed`);
if (failures) process.exit(1);
console.log('CREATE-USER PASSED');
