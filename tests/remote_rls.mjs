#!/usr/bin/env node
// Permissions with REAL logins on the live development project (execution plan, workstream E).
// Signs in as each demo user with the PUBLIC key only, then checks what each can see and what each is refused.
// Expected visibility is computed from the data with the service key, so the check stays right as data grows.
//
//   node tests/remote_rls.mjs          read checks + refused writes (writes nothing)
//   node tests/remote_rls.mjs --t1     also runs T1 through the API as three different people:
//                                      procure -> QC verifies -> QC records -> QR verifies -> QR seals -> public journey.
//                                      This leaves ONE sealed demo lot in the development project, on purpose.
import { supabaseConfig, client, signIn, readDemoLogins, assertNotProduction, environmentOf } from '../scripts/lib/env.mjs';
import { DEMO_USERS, appUserId, demoUser } from '../scripts/lib/demo-users.mjs';

const cfg = supabaseConfig({ needService: true });
await assertNotProduction(cfg, 'the permission test with demo logins');
console.log(`project: ${new URL(cfg.url).host} (${await environmentOf(cfg)})`);          // read by scripts/release_gate.mjs
const passwords = readDemoLogins();
const svc = client(cfg, { key: cfg.service });
const svcApp = client(cfg, { key: cfg.service, profile: 'app' });
let failures = 0, passes = 0;
const ok = (cond, name, detail = '') => {
  if (cond) { passes++; console.log(`ok    ${name}`); }
  else { failures++; console.log(`FAIL  ${name}${detail ? `  -> ${detail}` : ''}`); }
};
const refused = (r) => !r.ok || (Array.isArray(r.data) && r.data.length === 0);
const d = (r) => JSON.stringify(r.data)?.slice(0, 160);

// ---- ground truth from the service key -------------------------------------------------------------------
const [users, scopes, clients, slots, farmers] = await Promise.all([
  svc.get('app_users', 'select=id,role,client_id,state_ids,active'),
  svc.get('scopes', 'select=id,client_id,state_id'),
  svc.get('clients', 'select=id,state_id'),
  svc.get('slot_assignments', 'select=user_id,scope_id,stage_type'),
  svc.get('farmers', 'select=id,client_id'),
]);
for (const r of [users, scopes, clients, slots, farmers]) if (!r.ok) throw new Error(`service read failed: ${r.status} ${d(r)}`);
const clientState = Object.fromEntries(clients.data.map((c) => [c.id, c.state_id]));

function expectedScopes(u) {
  if (u.role === 'admin') return scopes.data.length;
  // migration 31: the state is a fact of the scope (a client may work in several states), not of the client
  if (u.role === 'state_manager') return scopes.data.filter((s) => u.state_ids.includes(s.state_id)).length;
  if (u.role === 'client_manager' || u.role === 'client_view') return scopes.data.filter((s) => s.client_id === u.client_id).length;
  return new Set(slots.data.filter((x) => x.user_id === u.id).map((x) => x.scope_id)).size;
}
function expectedFarmers(u) {
  const accessibleClient = (cid) => u.role === 'admin' || (u.role === 'state_manager' && u.state_ids.includes(clientState[cid]))
    || (['client_manager', 'client_view'].includes(u.role) && u.client_id === cid);
  if (u.role !== 'operator') return farmers.data.filter((f) => accessibleClient(f.client_id)).length;
  const farmerSlot = slots.data.some((x) => x.user_id === u.id && ['procurement', 'village_batch'].includes(x.stage_type));
  return farmerSlot ? farmers.data.filter((f) => f.client_id === u.client_id).length : 0;
}

// ---- sign in everyone ------------------------------------------------------------------------------------
const sessions = {};
for (const u of DEMO_USERS) {
  const pw = passwords[u.key];
  if (!pw) { ok(false, `${u.key} has a password in .env.demo-logins`, 'run scripts/create_demo_logins.mjs first'); continue; }
  try {
    const token = await signIn(cfg, { email: u.email, phone: u.phone?.replace(/[^0-9]/g, ''), password: pw });
    sessions[u.key] = { pub: client(cfg, { key: cfg.anon, token }), app: client(cfg, { key: cfg.anon, token, profile: 'app' }) };
    ok(true, `${u.key} ${u.name} signs in`);
  } catch (e) { ok(false, `${u.key} ${u.name} signs in`, e.message); }
}

// ---- read visibility -------------------------------------------------------------------------------------
for (const u of DEMO_USERS) {
  const s = sessions[u.key]; if (!s) continue;
  const row = users.data.find((x) => x.id === appUserId(u.key));
  const role = await s.app.rpc('current_role');
  // The summary role. HR people, a person with no assignment and a joiner all read 'operator': what they may do
  // comes from their system role and their assignments (checked further down), not from this word.
  const summary = ['hr_admin', 'hr_resource', 'unassigned', 'joiner'].includes(u.role) ? 'operator' : u.role;
  ok(role.ok && role.data === summary, `${u.key} current_role() = ${summary}`, d(role));
  const sc = await s.pub.count('scopes');
  ok(sc === expectedScopes(row), `${u.key} sees ${expectedScopes(row)} scope(s)`, `got ${typeof sc === 'number' ? sc : d(sc)}`);
  const fm = await s.pub.count('farmers');
  ok(fm === expectedFarmers(row), `${u.key} sees ${expectedFarmers(row)} farmer(s)`, `got ${typeof fm === 'number' ? fm : d(fm)}`);
  if (u.role === 'operator') {
    const us = await s.pub.count('app_users');
    ok(us === 1, `${u.key} operator sees only its own user row`, `got ${us}`);
  }
}
if (sessions['312']) {
  const o = sessions['312'];
  ok((await o.pub.count('footprints')) === 0, '312 other-client operator sees 0 footprints');
  ok((await o.pub.count('ledger', '', 'seq')) === 0, '312 other-client operator sees 0 ledger blocks');
  const inc = await o.app.rpc('incoming_records', { p_scope: '00000000-0000-4000-8000-000000000401', p_stage: 'qc' });
  ok(inc.ok && inc.data.length === 0, '312 other-client operator gets 0 incoming records for a Prasaadam scope', d(inc));
}
// ---- Phase 4 (migration 25): the ledger follows the thumb rule; blocks without a scope stay with the admin --------
for (const u of DEMO_USERS.filter((x) => x.role === 'operator')) {
  const s = sessions[u.key]; if (!s) continue;
  const [led, fps] = await Promise.all([s.pub.get('ledger', 'select=seq,footprint_id'), s.pub.get('footprints', 'select=id')]);
  const mine = new Set((fps.data ?? []).map((f) => f.id));
  const stray = (led.data ?? []).filter((b) => !b.footprint_id || !mine.has(b.footprint_id));
  ok(led.ok && fps.ok && stray.length === 0, `${u.key} operator reads only ledger blocks of records it can see (${(led.data ?? []).length} blocks)`,
     `${stray.length} block(s) of records it cannot see, e.g. seq ${stray[0]?.seq}`);
}
if (sessions['303']) {
  const n = await sessions['303'].pub.count('ledger', 'scope_id=is.null', 'seq');
  ok(n === 0, '303 client manager reads no ledger block without a scope (farmers, users)', `got ${typeof n === 'number' ? n : d(n)}`);
}
if (sessions['301']) {
  const n = await sessions['301'].pub.count('ledger', 'limit=1', 'seq');
  ok(n === 1, '301 admin reads the ledger', `got ${typeof n === 'number' ? n : d(n)}`);
}

// ---- Phase 4: things only a manager, or nobody, may do (nothing is changed by these calls) -------------------
if (sessions['306']) {
  const q = sessions['306'];
  const nowhere = '00000000-0000-4000-8000-00000000ffff';
  const w = await q.app.rpc('withdraw_footprint', { p_fp: nowhere, p_reason: 'x' });
  ok(!w.ok, 'an operator cannot call withdraw_footprint', d(w));
  const c = await q.app.rpc('check_ledger_now');
  ok(!c.ok, 'an operator cannot run the ledger check', d(c));
  const e = await q.pub.get('client_errors', 'select=id&limit=1');
  ok(refused(e), 'an operator cannot read the field error log', d(e));
  const r = await q.app.rpc('reset_login_allowed', { p_target: appUserId('305') });
  ok(r.ok && r.data === false, 'an operator may reset nobody\'s password', d(r));
  const m = await q.pub.insert('app_meta', { key: 'environment', value: 'production' });
  ok(!m.ok, 'nobody can mark the project as production through the API', d(m));
}
if (sessions['303']) {
  const cm = sessions['303'];
  const slot = await cm.pub.get('slot_assignments', 'select=id,stage_type&limit=1');
  if (slot.ok && slot.data.length) {
    const upd = await cm.pub.update('slot_assignments', `id=eq.${slot.data[0].id}`, { stage_type: slot.data[0].stage_type });
    ok(!upd.ok, 'a stage assignment cannot be rewritten, only given or removed', d(upd));
  }
  const rs = await cm.app.rpc('reset_login_allowed', { p_target: appUserId('302') });
  ok(rs.ok && rs.data === false, 'a Client Manager may not reset the State Manager\'s password', d(rs));
  const er = await cm.pub.get('client_errors', 'select=id&limit=1');
  ok(refused(er), 'a Client Manager cannot read the field error log', d(er));
}

// ---- identity layer (migrations 31–33): HR makes people and sees no operation; managers assign and make nobody ------
{
  const employees = (await svc.get('app_users', 'select=id&external=is.false')).data.length;
  const nobody = '00000000-0000-4000-8000-00000000ffff';
  const joiner = { p: { full_name: 'Not Created', personal_email: 'not.created@example.test', join_date: '2027-01-01' } };
  for (const key of ['316', '317']) {
    const s = sessions[key]; if (!s) continue;
    ok((await s.pub.count('app_users')) === employees, `${key} HR reads every employee (${employees}) and no client login`);
    ok((await s.pub.count('footprints')) === 0 && (await s.pub.count('clients')) === 0 && (await s.pub.count('ledger', '', 'seq')) === 0,
       `${key} HR reads no record, no client, no ledger`);
    const a = await s.app.rpc('assign', { p_employee: appUserId('318'), p_lens: 'scope', p_target: '00000000-0000-4000-8000-000000000401', p_op_role: 'operator', p_stages: ['qc'] });
    ok(!a.ok, `${key} HR cannot give an assignment`, d(a));
    const p = await s.app.rpc('hr_pipeline');
    ok(p.ok && p.data.some((x) => x.id === appUserId('319')), `${key} HR reads the joiner pipeline`, d(p));
  }
  for (const key of ['302', '303', '305', '304']) {
    const s = sessions[key]; if (!s) continue;
    const a = await s.app.rpc('add_joiner', joiner);
    ok(!a.ok, `${key} cannot add a person (only HR does)`, d(a));
    const h = await s.app.rpc('hr_pipeline');
    ok(!h.ok, `${key} cannot open the HR pipeline`, d(h));
    const docs = await s.pub.get('employee_docs', 'select=employee_id');
    ok(refused(docs) || docs.data.every((x) => x.employee_id === appUserId(key)), `${key} reads nobody else's identity details`, d(docs));
    const off = await s.app.rpc('offboard_person', { p_employee: appUserId('318'), p_exit_date: '2027-01-01' });
    ok(!off.ok, `${key} cannot offboard anyone`, d(off));
  }
  for (const key of ['301', '302', '303', '305', '316']) {
    const s = sessions[key]; if (!s) continue;
    const ins = await s.pub.insert('app_users', { display_name: 'Planted', email: 'planted@example.test' });
    ok(!ins.ok, `${key} cannot insert a person directly`, d(ins));
    const asg = await s.pub.insert('assignments', { employee_id: appUserId('318'), lens: 'state', op_role: 'state_supervisor', state_id: '00000000-0000-4000-8000-000000000001' });
    ok(!asg.ok, `${key} cannot write an assignment directly`, d(asg));
    const aud = await s.pub.insert('audit_log', { action: 'forged' });
    ok(!aud.ok, `${key} cannot write the audit log`, d(aud));
    const upd = await s.pub.update('app_users', `id=eq.${appUserId('318')}`, { system_role: 'admin' });
    ok(refused(upd), `${key} cannot set a system role by hand`, d(upd));
  }
  if (sessions['318']) {
    const z = sessions['318'];
    const c = await z.app.rpc('my_context');
    ok(c.ok && c.data.user.status === 'active' && c.data.assignments.length === 0 && c.data.scopes.length === 0 && (await z.pub.count('clients')) === 0,
       '318 an active person with no assignment sees nothing (the holding screen)', d(c));
  }
  if (sessions['319']) {
    const j = sessions['319'];
    const c = await j.app.rpc('my_context');
    const t = await j.pub.get('onboarding_tasks', 'select=employee_id');
    ok(c.ok && c.data.user.status === 'onboarding' && c.data.scopes.length === 0 && t.ok && t.data.length === 8 && t.data.every((x) => x.employee_id === appUserId('319')),
       '319 a joiner sees her own eight tasks and no scope', d(c));
    const done = await j.app.rpc('complete_task', { p_task: nobody });
    ok(!done.ok, '319 a task that is not hers cannot be ticked', d(done));
  }
  if (sessions['303']) {
    const cm = sessions['303'];
    const dir = await cm.app.rpc('people_directory');
    ok(dir.ok && dir.data.some((x) => x.id === appUserId('318') && x.unassigned) && !dir.data.some((x) => x.status === 'offboarded'),
       '303 a Client Manager opens the people directory and finds the unassigned person', d(dir));
    const far = await cm.app.rpc('assign', { p_employee: appUserId('318'), p_lens: 'state', p_target: '00000000-0000-4000-8000-000000000001', p_op_role: 'state_supervisor' });
    ok(!far.ok, '303 a Client Manager cannot appoint a state supervisor', d(far));
    const aud = await cm.app.rpc('audit_feed');
    ok(!aud.ok && (await cm.pub.count('audit_log')) === 0, '303 a Client Manager reads no audit log', d(aud));
    const seats = await cm.app.rpc('bootstrap_seats');
    ok(!seats.ok, '303 a Client Manager cannot open the seats', d(seats));
  }
  if (sessions['305']) {
    const dir = await sessions['305'].app.rpc('people_directory');
    ok(!dir.ok, '305 an operator cannot open the people directory', d(dir));
  }
  if (sessions['301'] && sessions['316']) {
    const a = await sessions['301'].app.rpc('audit_feed', { p_limit: 5 });
    const h = await sessions['316'].app.rpc('audit_feed', { p_limit: 5 });
    ok(a.ok && a.data.length > 0 && h.ok && h.data.length > 0, 'the admin and the HR Admin read the audit feed', d(a));
    const seats = await sessions['301'].app.rpc('bootstrap_seats');
    ok(seats.ok && seats.data.admins.length >= 1 && seats.data.hr_admin?.name === 'Asha (HR Admin)' && seats.data.daily_code.on === false,
       'the admin reads the two seats; the once-a-day sign-in code is off', d(seats));
  }
  const drawn = await client(cfg, { key: cfg.anon, token: undefined, profile: 'app' }).rpc('issue_daily_code', { p_auth_uid: nobody });
  ok(!drawn.ok, 'a visitor cannot draw a sign-in code', d(drawn));
}

const anonPub = client(cfg, { key: cfg.anon });
const anonFarmers = await anonPub.get('farmers', 'select=id');
ok(refused(anonFarmers), 'anonymous visitor cannot list farmers', d(anonFarmers));

// ---- closed API surface (migration 14): internal functions are not callable over REST ------------------------
{
  const forged = { p_footprint: null, p_scope: null, p_event: 'seal', p_actor: null, p_payload: { forged: true } };
  const anonApp = client(cfg, { key: cfg.anon, profile: 'app' });
  const a1 = await anonApp.rpc('ledger_append', forged);
  ok(!a1.ok, 'anonymous visitor cannot write a ledger block', `${a1.status} ${d(a1)}`);
  if (sessions['303']) {
    const a2 = await sessions['303'].app.rpc('ledger_append', forged);
    ok(!a2.ok, 'signed-in manager cannot write a ledger block directly', `${a2.status} ${d(a2)}`);
    const a3 = await sessions['303'].app.rpc('next_farmer_code', { p_client: '00000000-0000-4000-8000-000000000201' });
    ok(!a3.ok, 'signed-in manager cannot burn a Farmer ID', `${a3.status} ${d(a3)}`);
  }
}

// ---- refused writes --------------------------------------------------------------------------------------
if (sessions['306']) {
  const r = await sessions['306'].pub.insert('farmers', { client_id: '00000000-0000-4000-8000-000000000201', name: 'X',
    guardian_name: 'Y', village: 'Z', district: 'W', phone: '+919999999999', land_area_acres: 1 });
  ok(!r.ok, 'QC technician cannot create a farmer', d(r));
}
if (sessions['305']) {
  const r = await sessions['305'].pub.insert('footprints', { scope_id: '00000000-0000-4000-8000-000000000401', client_id: '00000000-0000-4000-8000-000000000201',
    stage_type: 'qc', created_by: appUserId('305'), payload: { qty_kg: 1, sample_qty_kg: 0.1, readings: {} } });
  ok(!r.ok, 'procurement operator cannot create a QC record', d(r));
}
if (sessions['303']) {
  const r = await sessions['303'].pub.update('app_users', `id=eq.${appUserId('303')}`, { role: 'admin' });
  ok(refused(r), 'client manager cannot make themselves admin', d(r));
}
if (sessions['304']) {
  const r = await sessions['304'].pub.update('farmers', 'village=eq.Itwa', { village: 'Changed' });
  ok(refused(r), 'client view cannot edit a farmer', d(r));
}

// ---- T1 through the API, as three different people --------------------------------------------------------
if (process.argv.includes('--t1')) {
  const P = sessions['305'], Q = sessions['306'], R = sessions['307'];
  if (!P || !Q || !R) { ok(false, 'T1 needs logins 305, 306, 307'); }
  else {
    const scope = '00000000-0000-4000-8000-000000000401', clientId = '00000000-0000-4000-8000-000000000201';
    const p = await P.pub.insert('footprints', { scope_id: scope, client_id: clientId, stage_type: 'procurement',
      farmer_id: '00000000-0000-4000-8000-000000000502', created_by: appUserId('305'),
      payload: { gross_kg: 150, bags: 1, tare_kg_per_bag: 2.5, moisture_pct: [11.9, 11.8, 12.0] } });
    const proc = p.data?.[0];
    ok(p.ok && Number(proc.qty_out) === 147.5, 'T1 procurement by 305: net 147.5 kg', d(p));
    const inc = await Q.app.rpc('incoming_records', { p_scope: scope, p_stage: 'qc' });
    ok(inc.ok && inc.data.some((x) => x.id === proc?.id), 'T1 the lot is incoming for the QC technician', d(inc));
    const selfVerify = await P.app.rpc('verify_footprint', { p_fp: proc?.id });
    ok(!selfVerify.ok, 'T1 procurement operator cannot verify own lot', d(selfVerify));
    const v1 = await Q.app.rpc('verify_footprint', { p_fp: proc?.id });
    ok(v1.ok && v1.data?.status === 'verified', 'T1 QC technician (306) verifies the procurement lot', d(v1));
    const q = await Q.pub.insert('footprints', { scope_id: scope, client_id: clientId, stage_type: 'qc', prev_footprint_id: proc?.id,
      created_by: appUserId('306'), payload: { qty_kg: 147.5, sample_qty_kg: 0.5, readings: { moisture_pct: 11.9, broken_pct: 2, foreign_matter_pct: 0.2 } } });
    const qc = q.data?.[0];
    ok(q.ok && Number(qc.qty_out) === 147, 'T1 QC by 306: 147 kg forwarded after 0.5 kg sample', d(q));
    const verdict = await Q.pub.get('qc_verdicts', `footprint_id=eq.${qc?.id}&select=domestic_verdict,export_verdict`);
    ok(verdict.ok && verdict.data[0]?.export_verdict === 'pass', 'T1 QC export verdict PASS derived', d(verdict));
    const v2 = await R.app.rpc('verify_footprint', { p_fp: qc?.id });
    ok(v2.ok, 'T1 QR operator (307) verifies the QC record', d(v2));
    // Phase 4: what the API refuses on a real lot (migrations 22 and 24)
    const forged = await P.pub.update('footprints', `id=eq.${proc?.id}`, { qty_out: 999 });
    ok(!forged.ok, 'T1 the procurement operator cannot rewrite his lot\'s quantity through the API', d(forged));
    const voided = await P.pub.update('footprints', `id=eq.${proc?.id}`, { status: 'superseded' });
    ok(!voided.ok, 'T1 nor withdraw it himself', d(voided));
    const backdated = await Q.pub.update('footprints', `id=eq.${qc?.id}`, { created_at: '2020-01-01T00:00:00Z' });
    ok(!backdated.ok, 'T1 the QC technician cannot back-date his record', d(backdated));
    const verdictRewrite = await Q.pub.update('qc_verdicts', `footprint_id=eq.${qc?.id}`, { export_verdict: 'fail' });
    ok(refused(verdictRewrite), 'T1 nor rewrite the derived verdict', d(verdictRewrite));
    const wrongSeal = await Q.app.rpc('seal_source', { p_source: qc?.id });
    ok(!wrongSeal.ok, 'T1 QC technician cannot seal', d(wrongSeal));
    const leftBehind = await svc.get('footprints', `prev_footprint_id=eq.${qc?.id}&select=id`);
    ok(leftBehind.ok && leftBehind.data.length === 0, 'T1 the refused seal left no QR record behind', d(leftBehind));
    const seal = await R.app.rpc('seal_source', { p_source: qc?.id });
    ok(seal.ok && /^GV-/.test(seal.data?.qr_code ?? ''), `T1 sealed by 307 in one call: ${seal.data?.qr_code ?? '?'}`, d(seal));
    const pLedger = await P.pub.get('ledger', `footprint_id=in.(${qc?.id},${seal.data?.footprint_id})&select=seq`);
    ok(pLedger.ok && pLedger.data.length === 0, 'T1 the procurement operator cannot read the lab or seal blocks of his own lot', d(pLedger));
    const anonApp = client(cfg, { key: cfg.anon, profile: 'app' });
    const j = await anonApp.rpc('public_lot_journey', { p_qr_code: seal.data?.qr_code });
    ok(j.ok && j.data?.journey?.length === 3 && j.data.journey[0].farmer?.name === 'Sita Devi',
      'T1 public journey (no login): 3 steps, farmer Sita Devi', d(j));
    ok(j.ok && !JSON.stringify(j.data).includes('919000000002'), 'T1 public journey never shows the farmer phone');
    const chain = await svcApp.rpc('verify_ledger');
    ok(chain.ok && chain.data.length === 0, 'ledger chain intact after T1', d(chain));
  }
}

console.log(`\n${passes} passed, ${failures} failed`);
if (failures) process.exit(1);
console.log('REMOTE RLS PASSED');
