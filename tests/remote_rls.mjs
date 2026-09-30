#!/usr/bin/env node
// Permissions with REAL logins on the live development project (execution plan, workstream E).
// Signs in as each demo user with the PUBLIC key only, then checks what each can see and what each is refused.
// Expected visibility is computed from the data with the service key, so the check stays right as data grows.
//
//   node tests/remote_rls.mjs          read checks + refused writes (writes nothing)
//   node tests/remote_rls.mjs --t1     also runs T1 through the API as three different people:
//                                      procure -> QC verifies -> QC records -> QR verifies -> QR seals -> public journey.
//                                      This leaves ONE sealed demo lot in the development project, on purpose.
import { supabaseConfig, client, signIn, readDemoLogins } from '../scripts/lib/env.mjs';
import { DEMO_USERS, appUserId, demoUser } from '../scripts/lib/demo-users.mjs';

const cfg = supabaseConfig({ needService: true });
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
  svc.get('scopes', 'select=id,client_id'),
  svc.get('clients', 'select=id,state_id'),
  svc.get('slot_assignments', 'select=user_id,scope_id,stage_type'),
  svc.get('farmers', 'select=id,client_id'),
]);
for (const r of [users, scopes, clients, slots, farmers]) if (!r.ok) throw new Error(`service read failed: ${r.status} ${d(r)}`);
const clientState = Object.fromEntries(clients.data.map((c) => [c.id, c.state_id]));

function expectedScopes(u) {
  if (u.role === 'admin') return scopes.data.length;
  if (u.role === 'state_manager') return scopes.data.filter((s) => u.state_ids.includes(clientState[s.client_id])).length;
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
  ok(role.ok && role.data === u.role, `${u.key} current_role() = ${u.role}`, d(role));
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
    const a = await R.pub.insert('footprints', { scope_id: scope, client_id: clientId, stage_type: 'qr_activation',
      prev_footprint_id: qc?.id, created_by: appUserId('307'), payload: {} });
    const qr = a.data?.[0];
    ok(a.ok, 'T1 QR activation record created by 307', d(a));
    const wrongSeal = await Q.app.rpc('seal_lot', { p_qr_fp: qr?.id });
    ok(!wrongSeal.ok, 'T1 QC technician cannot seal', d(wrongSeal));
    const seal = await R.app.rpc('seal_lot', { p_qr_fp: qr?.id });
    ok(seal.ok && /^GV-/.test(seal.data?.qr_code ?? ''), `T1 sealed by 307: ${seal.data?.qr_code ?? '?'}`, d(seal));
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
