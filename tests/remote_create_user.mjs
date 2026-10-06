#!/usr/bin/env node
// The server functions of the identity layer, end to end with real logins: create-user (HR adds a joiner; a client's
// manager adds the client's own login), reset-password, daily-code. LOCAL STACK / CI ONLY: it creates people and, for
// a minute, switches the once-a-day sign-in code on for the whole stack (do not run it beside the browser tests).
//   ENV_FILE=.env.stack node tests/remote_create_user.mjs
import { supabaseConfig, client, signIn, readDemoLogins, assertNotProduction } from '../scripts/lib/env.mjs';
import { demoUser } from '../scripts/lib/demo-users.mjs';

const cfg = supabaseConfig({ needService: true });
if (!/127\.0\.0\.1|localhost/.test(cfg.url) && !process.argv.includes('--i-know-this-creates-users')) {
  console.error('refusing to run against a non-local project: it creates users. Use the local stack.'); process.exit(2);
}
await assertNotProduction(cfg, 'the create-user / reset-password / daily-code test');
const pw = readDemoLogins();
let passes = 0, failures = 0;
const ok = (c, n, d = '') => { if (c) { passes++; console.log(`ok    ${n}`); } else { failures++; console.log(`FAIL  ${n}  -> ${d}`); } };
const token = async (key) => { const u = demoUser(key); return signIn(cfg, { email: u.email, phone: u.phone?.replace(/[^0-9]/g, ''), password: pw[key] }); };
const fn = async (name, tok, body, method = 'POST') => {
  const r = await fetch(`${cfg.url}/functions/v1/${name}`, {
    method, headers: { apikey: cfg.anon, authorization: `Bearer ${tok}`, 'content-type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) });
  return { status: r.status, data: await r.json().catch(() => null) };
};
const call = (tok, body) => fn('create-user', tok, body);
const as = (tok, profile = 'app') => client(cfg, { key: cfg.anon, token: tok, profile });
const suffix = String(Date.now()).slice(-6);
const prasaadam = '00000000-0000-4000-8000-000000000201', other = '00000000-0000-4000-8000-000000000202';
const svc = client(cfg, { key: cfg.service });
const svcApp = client(cfg, { key: cfg.service, profile: 'app' });
const today = new Date(Date.now() + 5.5 * 3600_000).toISOString().slice(0, 10);
const claims = (jwt) => JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString('utf8'));
const tryIn = async (cred) => { try { return await signIn(cfg, cred); } catch { return null; } };

const admin = await token('301'), sm = await token('302'), cm = await token('303'), qc = await token('306');
const hrAdmin = await token('316'), hr = await token('317');

// ---------------------------------------------------------------------------------------------------------------
// 1 · create-user: HR adds a joiner. An identity, a checklist, a login. No access.
// ---------------------------------------------------------------------------------------------------------------
const joiner = (extra = {}) => ({ kind: 'joiner', full_name: `Joiner ${suffix}`, personal_email: `joiner${suffix}@example.test`, join_date: today,
  employment_type: 'full_time', job_title: 'Sorting Associate', ...extra });

let r = await call(cfg.anon, joiner());
ok(r.status === 401, 'not signed in → 401', JSON.stringify(r));
r = await call(cm, joiner());
ok(r.status === 403 && /only HR/.test(r.data?.error ?? ''), 'a Client Manager can no longer create a person → 403', JSON.stringify(r));
r = await call(sm, joiner());
ok(r.status === 403, 'nor a State Manager → 403', JSON.stringify(r));
r = await call(qc, joiner());
ok(r.status === 403, 'nor an operator → 403', JSON.stringify(r));
r = await call(hr, { role: 'operator', display_name: 'Old app', phone: '9876543210', client_id: prasaadam });
ok(r.status === 400 && /reload the app/.test(r.data?.error ?? ''), 'a request in the old shape (an app from before 6 Oct) is told what changed → 400', JSON.stringify(r));
r = await call(hr, joiner({ personal_email: 'not-an-email' }));
ok(r.status === 400, 'no valid email → 400 (the email is the sign-in)', JSON.stringify(r));
r = await call(hr, joiner({ phone: '12345' }));
ok(r.status === 400, 'invalid phone → 400', JSON.stringify(r));
r = await call(hr, joiner({ system_role: 'admin' }));
ok(r.status === 403, 'HR cannot create an admin → 403', JSON.stringify(r));

r = await call(hr, joiner({ phone: `98${suffix}01`, reports_to: '00000000-0000-4000-8000-000000000303' }));
ok(r.status === 201 && r.data?.temporary_password && r.data?.sign_in === `joiner${suffix}@example.test`, 'an HR resource adds a joiner → 201 with a temporary password', JSON.stringify({ status: r.status, error: r.data?.error }));
const jid = r.data?.app_user_id, temp1 = r.data?.temporary_password;
ok(r.data?.invite_emailed === Boolean(cfg.env.MAIL_OUTBOX_URL), `the answer says whether an invite note was mailed (${cfg.env.MAIL_OUTBOX_URL ? 'a sender is set up here' : 'no sender here'})`, JSON.stringify(r.data?.invite_emailed));
if (cfg.env.MAIL_OUTBOX_URL) {
  const box = await (await fetch(`${cfg.env.MAIL_OUTBOX_URL}?to=joiner${suffix}@example.test`)).json();
  ok(box.length === 1 && /account is ready/.test(box[0].subject) && !box[0].text.includes(temp1), 'the invite note went to the joiner and does NOT carry the password', JSON.stringify(box.map((m) => m.subject)));
}

let row = (await svc.get('app_users', `id=eq.${jid}&select=status,system_role,role,client_id,state_ids,auth_uid,created_by,phone`)).data?.[0];
ok(row?.status === 'invited' && row.system_role === 'operational' && row.client_id === null && row.state_ids.length === 0 && row.auth_uid === r.data?.login_id
   && row.created_by === '00000000-0000-4000-8000-000000000317',
   'the person is an invited identity, linked to the login, with no client and no state', JSON.stringify(row));
const tasks = (await svc.get('onboarding_tasks', `employee_id=eq.${jid}&select=code,owner,statutory`)).data ?? [];
ok(tasks.length === 8 && tasks.filter((t) => t.statutory).length === 1, 'the standard checklist is stamped: eight tasks, one statutory', JSON.stringify(tasks.length));
const lines = (await svc.get('audit_log', `target=eq.${jid}&select=action,actor&order=id`)).data ?? [];
ok(lines.map((l) => l.action).join(',') === 'identity_created,invite_sent', 'two audit lines: identity created, invite sent', JSON.stringify(lines));

r = await call(hr, joiner());
ok(r.status === 409, 'the same email again → 409', JSON.stringify(r));
r = await call(hr, joiner({ full_name: 'Intern', personal_email: `intern${suffix}@example.test`, employment_type: 'intern' }));
const internTasks = (await svc.get('onboarding_tasks', `employee_id=eq.${r.data?.app_user_id}&select=statutory`)).data ?? [];
ok(r.status === 201 && internTasks.length === 7 && internTasks.every((t) => !t.statutory), 'an intern gets the checklist without the statutory task', JSON.stringify({ status: r.status, n: internTasks.length }));
r = await call(hr, joiner({ full_name: 'Another HR', personal_email: `hr${suffix}@example.test`, system_role: 'hr_resource' }));
const flagged = (await svc.get('audit_log', `target=eq.${r.data?.app_user_id}&action=eq.hr_resource_created&select=flagged`)).data ?? [];
ok(r.status === 201 && flagged.length === 1 && flagged[0].flagged === true, 'an HR resource may create another HR resource; that line is flagged', JSON.stringify({ status: r.status, flagged }));
const left = await svc.get('app_users', `display_name=in.("Old app","Joiner ${suffix}")&select=id`);
ok(left.ok && left.data.length === 1, 'refused calls left no person behind', JSON.stringify(left.data));

// ---------------------------------------------------------------------------------------------------------------
// 2 · the joiner signs in: own password first, a checklist, and no scope until HR marks them joined and a manager assigns
// ---------------------------------------------------------------------------------------------------------------
let tok = await tryIn({ email: `joiner${suffix}@example.test`, password: temp1 });
ok(tok && claims(tok).user_metadata?.must_change_password === true, 'a new login is marked: must set an own password at first sign-in');
ok(tok && claims(tok).app_metadata?.grainveda_login === true, 'a new login carries the service-role mark that login linking requires');
const own = `Own-${suffix}-pw`;
let u = await fetch(`${cfg.url}/auth/v1/user`, { method: 'PUT',
  headers: { apikey: cfg.anon, authorization: `Bearer ${tok}`, 'content-type': 'application/json' },
  body: JSON.stringify({ password: own, data: { must_change_password: false } }) });
ok(u.ok, 'the joiner sets an own password', `${u.status}`);
ok((await tryIn({ email: `joiner${suffix}@example.test`, password: temp1 })) === null, 'the temporary password no longer works');
tok = await tryIn({ email: `joiner${suffix}@example.test`, password: own });
ok(tok && claims(tok).user_metadata?.must_change_password === false, 'the own password works and the mark is cleared');
let me = as(tok);
ok((await me.rpc('mark_first_login')).data === 'onboarding', 'first sign-in: invited → onboarding');
let ctx = (await me.rpc('my_context')).data;
ok(ctx?.user?.status === 'onboarding' && ctx.scopes.length === 0 && ctx.slots.length === 0 && ctx.onboarding?.total === 8, 'the joiner sees a checklist and no scope', JSON.stringify(ctx?.user));
const mine = (await me.rpc('my_onboarding')).data;
ok(mine?.tasks?.length === 8 && mine.reports_to?.name === 'Prasaadam Client Manager', 'my_onboarding lists the eight tasks and who they report to', JSON.stringify(mine?.reports_to));

// a document goes to the private store; the joiner cannot open it again, HR can
const blob = new Blob([`pan card ${suffix}`], { type: 'image/jpeg' });
const path = `${jid}/pan-${suffix}.jpg`;
const up = async (t, p) => (await fetch(`${cfg.url}/storage/v1/object/hr-docs/${p}`, { method: 'POST', headers: { apikey: cfg.anon, authorization: `Bearer ${t}`, 'content-type': 'image/jpeg' }, body: blob }));
ok((await up(tok, path)).ok, 'the joiner uploads a document into their own folder of the private store');
const wrongFolder = await up(tok, `00000000-0000-4000-8000-000000000306/pan-${suffix}.jpg`);
ok(!wrongFolder.ok, 'and into nobody else\'s', `${wrongFolder.status}`);
const dl = (t) => fetch(`${cfg.url}/storage/v1/object/authenticated/hr-docs/${path}`, { headers: { apikey: cfg.anon, authorization: `Bearer ${t}` } });
ok(!(await dl(tok)).ok, 'the joiner cannot open the document again (only HR and the admin can)');
ok(!(await dl(cm)).ok, 'a manager cannot open it');
const hrGot = await dl(hr);
ok(hrGot.ok && (await hrGot.text()) === `pan card ${suffix}`, 'HR opens it', `${hrGot.status}`);
const sha = [...new Uint8Array(await crypto.subtle.digest('SHA-256', await blob.arrayBuffer()))].map((b) => b.toString(16).padStart(2, '0')).join('');
const idTask = mine.tasks.find((t) => t.code === 'identity')?.id;
r = await me.rpc('register_hr_file', { p_employee: jid, p_kind: 'pan', p_path: path, p_sha256: sha, p_file_name: 'pan.jpg', p_task: idTask });
ok(r.ok, 'the document is registered with its fingerprint', JSON.stringify(r.data));
r = await me.rpc('complete_task', { p_task: idTask, p_data: { pan_last4: 'ABCDE1234F' } });
ok(!r.ok && /last four/.test(r.data?.message ?? ''), 'a full PAN typed into the box is refused, not stored', JSON.stringify(r.data));
r = await me.rpc('complete_task', { p_task: idTask, p_data: { pan_last4: '234F', aadhaar_last4: '9012' } });
ok(r.ok && r.data?.open === 7, 'the identity task is done with the last four characters', JSON.stringify(r.data));

// access: none until marked joined; then exactly what a manager assigns
r = await as(cm).rpc('assign', { p_employee: jid, p_lens: 'scope', p_target: '00000000-0000-4000-8000-000000000402', p_op_role: 'operator', p_stages: ['sorting'] });
ok(r.ok && r.data?.warnings?.some((w) => w.code === 'not_active_yet'), 'the Client Manager assigns the joiner ahead of time; the answer warns: not active yet', JSON.stringify(r.data?.warnings ?? r.data));
ctx = (await me.rpc('my_context')).data;
ok(ctx.scopes.length === 0 && ctx.slots.length === 0, 'before joining the assignment opens nothing');
r = await as(hr).rpc('assign', { p_employee: jid, p_lens: 'scope', p_target: '00000000-0000-4000-8000-000000000401', p_op_role: 'operator', p_stages: ['qc'] });
ok(!r.ok && /outside what you manage/.test(r.data?.message ?? ''), 'HR cannot assign: HR never grants access', JSON.stringify(r.data));
r = await as(cm).rpc('activate_joiner', { p_employee: jid });
ok(!r.ok, 'a manager cannot mark a joiner as joined', JSON.stringify(r.data));
r = await as(hr).rpc('activate_joiner', { p_employee: jid });
ok(r.ok && r.data === 'active', 'HR marks the joiner as joined', JSON.stringify(r.data));
ctx = (await me.rpc('my_context')).data;
ok(ctx.user.status === 'active' && ctx.scopes.length === 1 && ctx.slots.length === 1 && ctx.slots[0].stage_type === 'sorting' && ctx.scopes[0].manage === false,
   'now the joiner works at exactly the stage assigned', JSON.stringify({ scopes: ctx.scopes.length, slots: ctx.slots }));

// ---------------------------------------------------------------------------------------------------------------
// 3 · a client's own login: made by whoever manages the client, outside HR
// ---------------------------------------------------------------------------------------------------------------
r = await call(hr, { kind: 'viewer', client_id: prasaadam, display_name: `Buyer ${suffix}`, email: `buyer${suffix}@example.test` });
ok(r.status === 403, 'HR cannot create a client login → 403', JSON.stringify(r));
r = await call(cm, { kind: 'viewer', client_id: other, display_name: `Buyer ${suffix}`, email: `buyer${suffix}@example.test` });
ok(r.status === 403, 'a Client Manager cannot create one for another client → 403', JSON.stringify(r));
r = await call(cm, { kind: 'viewer', client_id: prasaadam, display_name: `Buyer ${suffix}`, email: `buyer${suffix}@example.test` });
ok(r.status === 201, 'the Client Manager creates the client\'s own login → 201', JSON.stringify({ status: r.status, error: r.data?.error }));
const vid = r.data?.app_user_id;
const vtok = await tryIn({ email: `buyer${suffix}@example.test`, password: r.data?.temporary_password });
const vctx = vtok ? (await as(vtok).rpc('my_context')).data : null;
ok(vctx?.user?.external === true && vctx.user.role === 'client_view' && vctx.scopes.length >= 7 && vctx.scopes.every((s) => !s.manage && s.whole),
   'it signs in at once and reads every scope of that client, managing none', JSON.stringify(vctx?.user));
ok(((await svc.get('onboarding_tasks', `employee_id=eq.${vid}&select=id`)).data ?? []).length === 0, 'it has no checklist: it is not an employee');

// ---------------------------------------------------------------------------------------------------------------
// 4 · reset-password: credentials belong to HR
// ---------------------------------------------------------------------------------------------------------------
const reset = (t, id) => fn('reset-password', t, { app_user_id: id });
r = await reset(cfg.anon, jid);
ok(r.status === 401, 'reset without a login → 401', JSON.stringify(r));
r = await reset(qc, jid);
ok(r.status === 403, 'an operator cannot reset a password → 403', JSON.stringify(r));
r = await reset(cm, jid);
ok(r.status === 403, 'a Client Manager can no longer reset the people assigned to him → 403', JSON.stringify(r));
r = await reset(sm, jid);
ok(r.status === 403, 'nor a State Manager → 403', JSON.stringify(r));
r = await reset(hr, '00000000-0000-4000-8000-000000000301');
ok(r.status === 403, 'an HR resource cannot reset the admin → 403', JSON.stringify(r));
r = await reset(hr, '00000000-0000-4000-8000-000000000316');
ok(r.status === 403, 'nor the HR Admin → 403', JSON.stringify(r));
r = await reset(hr, '00000000-0000-4000-8000-000000000317');
ok(r.status === 403, 'nobody resets their own password this way → 403', JSON.stringify(r));
r = await reset(hr, vid);
ok(r.status === 403, 'HR does not reset a client\'s login → 403', JSON.stringify(r));
r = await reset(cm, vid);
ok(r.status === 200 && r.data?.temporary_password, 'the Client Manager resets the client\'s own login → 200', JSON.stringify({ status: r.status }));
// a session open on the person's phone before the reset (the "lost phone" case)
const openSession = await (await fetch(`${cfg.url}/auth/v1/token?grant_type=password`, { method: 'POST',
  headers: { apikey: cfg.anon, 'content-type': 'application/json' }, body: JSON.stringify({ email: `joiner${suffix}@example.test`, password: own }) })).json();
const refresh = async (rt) => (await fetch(`${cfg.url}/auth/v1/token?grant_type=refresh_token`, { method: 'POST',
  headers: { apikey: cfg.anon, 'content-type': 'application/json' }, body: JSON.stringify({ refresh_token: rt }) })).status;
r = await reset(hr, jid);
ok(r.status === 200 && r.data?.temporary_password && r.data.temporary_password !== temp1, 'HR resets the joiner → 200 with a new temporary password', JSON.stringify({ status: r.status }));
ok((await tryIn({ email: `joiner${suffix}@example.test`, password: own })) === null, 'after the reset the old own password no longer works');
const refreshed = openSession?.refresh_token ? await refresh(openSession.refresh_token) : 0;
ok(refreshed >= 400, 'a session that was open before the reset cannot be renewed (it ends when its token expires, within the hour)', `refresh answered ${refreshed}`);
tok = await tryIn({ email: `joiner${suffix}@example.test`, password: r.data?.temporary_password });
ok(tok && claims(tok).user_metadata?.must_change_password === true, 'the new temporary password works and must be changed again');
ok((await as(tok).rpc('my_context')).data?.user?.id === jid, 'it is still the same person');
const resetLine = (await svc.get('audit_log', `target=eq.${jid}&action=eq.login_reset&select=actor`)).data ?? [];
ok(resetLine.length === 1 && resetLine[0].actor === '00000000-0000-4000-8000-000000000317', 'the reset is one audit line naming who did it', JSON.stringify(resetLine));

// ---------------------------------------------------------------------------------------------------------------
// 5 · offboarding ends everything; the login then opens nothing
// ---------------------------------------------------------------------------------------------------------------
r = await as(cm).rpc('offboard_person', { p_employee: jid, p_exit_date: today });
ok(!r.ok, 'a manager cannot offboard', JSON.stringify(r.data));
r = await as(hr).rpc('offboard_person', { p_employee: jid, p_exit_date: today, p_reason: 'test', p_final_settlement: 'none due', p_form16_ref: 'n/a' });
ok(r.ok && r.data?.assignments_ended === 1, 'HR offboards: the one assignment ends', JSON.stringify(r.data));
ctx = (await as(tok).rpc('my_context')).data;
ok(ctx?.user === null, 'the offboarded person\'s login is recognised by nothing', JSON.stringify(ctx));
r = await reset(hr, jid);
ok(r.status === 403, 'and its password cannot be reset → 403', JSON.stringify(r));

// ---------------------------------------------------------------------------------------------------------------
// 6 · a public sign-up with the e-mail of a person who has no login must not become that person
// ---------------------------------------------------------------------------------------------------------------
const ghostMail = `ghost${suffix}@example.test`;
const ghost = await svc.insert('app_users', { display_name: `Ghost ${suffix}`, email: ghostMail });
const su = await fetch(`${cfg.url}/auth/v1/signup`, { method: 'POST', headers: { apikey: cfg.anon, 'content-type': 'application/json' },
  body: JSON.stringify({ email: ghostMail, password: `Pub-${suffix}-signup` }) });
const suData = await su.json().catch(() => ({}));
if (!su.ok) {
  ok(true, `public sign-up is switched off on this project (${su.status})`);
} else {
  const st = suData.access_token ?? await tryIn({ email: ghostMail, password: `Pub-${suffix}-signup` });
  const role = st ? await as(st).rpc('current_role') : { data: null };
  ok(role.data === null, 'public sign-up is open here, yet a sign-up with a person\'s e-mail gets NO role', JSON.stringify(role.data));
  const linked = await svc.get('app_users', `id=eq.${ghost.data?.[0]?.id}&select=auth_uid`);
  ok(linked.data?.[0]?.auth_uid === null, 'the person\'s row stays unlinked', JSON.stringify(linked.data));
  const signedUpId = suData.user?.id ?? suData.id;
  if (signedUpId) await fetch(`${cfg.url}/auth/v1/admin/users/${signedUpId}`, { method: 'DELETE', headers: { apikey: cfg.service, authorization: `Bearer ${cfg.service}` } });
}
await svc.raw('DELETE', `/rest/v1/app_users?id=eq.${ghost.data?.[0]?.id}`);

// ---------------------------------------------------------------------------------------------------------------
// 7 · the once-a-day sign-in code. Built and tested; OFF on every project until a sender exists.
// ---------------------------------------------------------------------------------------------------------------
const state = async (t) => (await as(t).rpc('daily_code_state')).data;
r = await fn('daily-code', cfg.anon, undefined, 'GET');
ok(r.status === 200 && r.data?.function === 'daily-code' && typeof r.data.sender === 'boolean', `daily-code says which build it is and whether a sender is set up (here: ${r.data?.sender})`, JSON.stringify(r));
ok((await state(cm))?.on === false && (await state(cm))?.needed === false, 'the code is off: nobody is asked for one');
r = await as(cm).rpc('set_daily_code', { p_on: true });
ok(!r.ok, 'a manager cannot switch it on', JSON.stringify(r.data));
r = await as(admin).rpc('set_daily_code', { p_on: true });
ok(r.ok && r.data?.ok === false && r.data.without_email >= 11, 'the admin is refused while people who sign in have no email, and told how many', JSON.stringify(r.data));

if (!cfg.env.MAIL_OUTBOX_URL) {
  r = await fn('daily-code', cm, {});
  ok(r.status === 503, 'with no sender set up, asking for a code answers 503 and sends nothing', JSON.stringify(r));
  console.log('skip  the rest of the sign-in code checks need the local mail stand-in (STACK_NO_MAIL is set)');
} else {
  // Switched on the way a database owner would for a trial: the eleven demo operators have no email, so the admin's
  // own switch refuses (above). Everything below runs with the code ON for the whole stack, and puts it back OFF.
  const flip = (v) => svc.raw('POST', '/rest/v1/app_meta', { key: 'daily_code', value: v }, { Prefer: 'resolution=merge-duplicates' });
  await fetch(cfg.env.MAIL_OUTBOX_URL, { method: 'DELETE' });
  try {
    ok((await flip('on')).ok, 'the code is switched ON for the test');
    const t3 = await token('303');
    ctx = (await as(t3).rpc('my_context')).data;
    ok(ctx?.needs_daily_code === true && ctx.user?.display_name === 'Prasaadam Client Manager' && ctx.scopes.length === 0,
       'on: after the password the app is told a code is owed, and nothing is open', JSON.stringify({ needs: ctx?.needs_daily_code, scopes: ctx?.scopes?.length }));
    const none = await as(t3, 'public').get('scopes', 'select=id');
    ok(none.ok && none.data.length === 0, 'on: the tables answer with nothing', JSON.stringify(none.data?.length));
    r = await fn('daily-code', cfg.anon, {});
    ok(r.status === 401, 'a code is not sent without a login → 401', JSON.stringify(r));
    r = await fn('daily-code', t3, {});
    ok(r.status === 200 && r.data?.sent === true && /^g•••@/.test(r.data.to) && !JSON.stringify(r.data).match(/\d{6}/), 'the code is sent to the address on record; the answer does not carry it', JSON.stringify(r));
    const box = await (await fetch(`${cfg.env.MAIL_OUTBOX_URL}?to=grainvedas%2Bclientmanager@gmail.com`)).json();
    const code = /(\d{6}) is your GrainVeda sign-in code/.exec(box.at(-1)?.subject ?? '')?.[1];
    ok(box.length === 1 && code, 'one message arrived with a six-digit code', JSON.stringify(box.map((m) => m.subject)));
    r = await fn('daily-code', t3, {});
    ok(r.status === 429, 'asking again within a minute → 429', JSON.stringify(r));
    r = await as(t3).rpc('verify_daily_code', { p_code: code === '000000' ? '111111' : '000000' });
    ok(r.ok && r.data === false, 'a wrong code is refused');
    r = await as(qc).rpc('verify_daily_code', { p_code: code });
    ok(!r.ok || r.data === false, 'somebody else cannot use that code');
    r = await as(t3).rpc('verify_daily_code', { p_code: code });
    ok(r.ok && r.data === true, 'the right code passes');
    ctx = (await as(t3).rpc('my_context')).data;
    ok(ctx?.needs_daily_code === false && ctx.scopes.length >= 7, 'passed: everything is open again for today', JSON.stringify({ needs: ctx?.needs_daily_code, scopes: ctx?.scopes?.length }));
    const t3b = await token('303');
    ok((await as(t3b).rpc('my_context')).data?.needs_daily_code === false, 'a second sign-in the same day is not asked again (once per calendar day)');
    const drawn = await svcApp.rpc('issue_daily_code', { p_auth_uid: claims(qc).sub });
    ok(!drawn.ok && /no email/.test(drawn.data?.message ?? ''), 'a person with no email cannot be sent a code (which is why the switch refuses while such people exist)', JSON.stringify(drawn.data));
  } finally {
    await flip('off');
    await svc.raw('DELETE', '/rest/v1/daily_code_passes?day=gte.2000-01-01');
    await svc.raw('DELETE', '/rest/v1/daily_codes?issued_at=gte.2000-01-01');
  }
  ok((await state(cm))?.needed === false && (await as(cm).rpc('my_context')).data?.scopes?.length >= 7, 'the code is OFF again: everything as before');
}

console.log(`\n${passes} passed, ${failures} failed`);
if (failures) process.exit(1);
console.log('CREATE-USER PASSED');
