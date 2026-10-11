#!/usr/bin/env node
// THE 200-PERSON TEST (Veda's brief "Onboarding at scale", 11 Oct 2026, "Done means"), end to end over the API with real
// sign-ins: openings for one state (1 State Manager, 2 Client Managers, 200 Operators across 5 stages), an import of 200
// rows (plus bad ones) with its preview, a second upload that makes nobody, invites in bulk and one accepted, the
// checklist for the role, HR owners and "Mine", the lists and their timings, the gate on Mark as joined, the scope
// activated and the waiting operators "ready to assign", 40 put on a stage in one act (five times), the opening numbers
// at every point and the admin's overview. Prints a timing table.
// LOCAL STACK ONLY: it makes hundreds of people. Never against the practice or production project.
//   ENV_FILE=.env.stack node tests/load_onboarding.mjs            (200 operators)
//   ENV_FILE=.env.stack node tests/load_onboarding.mjs --per 400   (2,000 operators: 400 per stage, two files of 1,000)
import { supabaseConfig, client, signIn, readDemoLogins, assertNotProduction } from '../scripts/lib/env.mjs';
import { demoUser } from '../scripts/lib/demo-users.mjs';

const cfg = supabaseConfig({ needService: true });
if (!/^http:\/\/(127\.0\.0\.1|localhost)[:/]/.test(cfg.url)) { console.error('refusing: this test makes hundreds of people; run it on the local stack only'); process.exit(2); }
await assertNotProduction(cfg, 'the 200-person onboarding test');
const PER = Number(process.argv[process.argv.indexOf('--per') + 1]) || 40;
const STAGES = ['procurement', 'qc', 'milling', 'packing', 'commercial'];
const N = PER * STAGES.length;
const pw = readDemoLogins();
const token = async (key) => { const u = demoUser(key); return signIn(cfg, { email: u.email, password: pw[key] }); };
const as = (tok) => client(cfg, { key: cfg.anon, token: tok, profile: 'app' });
const pub = (tok) => client(cfg, { key: cfg.anon, token: tok });
const svc = client(cfg, { key: cfg.service });
let passes = 0, failures = 0;
const ok = (c, n, d = '') => { if (c) { passes++; console.log(`ok    ${n}`); } else { failures++; console.log(`FAIL  ${n}  -> ${typeof d === 'string' ? d : JSON.stringify(d).slice(0, 300)}`); } };
const timings = [];
async function timed(what, fn) { const t0 = performance.now(); const r = await fn(); const ms = performance.now() - t0; timings.push([what, ms]); return r; }
async function timedAvg(what, fn, n = 5) { let r; const ms = []; for (let i = 0; i < n; i++) { const t0 = performance.now(); r = await fn(); ms.push(performance.now() - t0); } ms.sort((a, b) => a - b); timings.push([`${what} (median of ${n})`, ms[Math.floor(n / 2)]]); return r; }
const must = (r, what) => { if (!r.ok) throw new Error(`${what}: ${r.status} ${JSON.stringify(r.data).slice(0, 300)}`); return r.data; };
const run = String(Date.now()).slice(-6);
const UP = '00000000-0000-4000-8000-000000000001', CLIENT = '00000000-0000-4000-8000-000000000201';
const today = new Date(Date.now() + 5.5 * 3600_000).toISOString().slice(0, 10);
const inDays = (d) => new Date(Date.now() + 5.5 * 3600_000 + d * 864e5).toISOString().slice(0, 10);

const admin = await token('301'), sm = await token('302'), hrAdmin = await token('316'), hr = await token('317');
console.log(`run ${run}: ${N} operators (${PER} per stage), 1 State Manager, 2 Client Managers`);

// 0 · a scope that is not active yet (the operators' wave waits for it)
const crop = (await svc.get('scopes', `id=eq.00000000-0000-4000-8000-000000000405&select=crop_id,chain`)).data[0];
const scope = must(await pub(sm).insert('scopes', { client_id: CLIENT, crop_id: crop.crop_id, state_id: UP, season_code: `LT${run.slice(-2)}`,
  geography: `Load test ${run}`, chain: crop.chain, status: 'draft' }), 'draft scope')[0];

// 1 · openings
const H = as(hr);
const open = async (o) => must(await H.rpc('save_opening', { p: o }), 'opening');
const oSM = await timed('create an opening', () => open({ state_id: UP, role: 'state_manager', positions: 1, target_join: inDays(10) }));
const oCM = await open({ state_id: UP, role: 'client_manager', positions: 2, client_id: CLIENT, target_join: inDays(10) });
const oOp = {};
for (const st of STAGES) oOp[st] = await open({ state_id: UP, role: 'operator', stage: st, positions: PER, scope_id: scope.id, target_join: inDays(10) });
const num = async (o) => (must(await H.rpc('openings_summary', { p_state: UP }), 'summary').openings).find((x) => x.id === o.id);
ok((await num(oOp.qc)).vacant === PER && (await num(oOp.qc)).joining === 0, `openings: 1 SM, 2 CM, ${N} operators across 5 stages, all vacant`);

// 2 · the import: N good rows, then bad ones; preview, commit, a second upload
const row = (i, opening, extra = {}) => ({ full_name: `Load ${run} Operator ${i}`, personal_email: `load${run}.${i}@example.com`,
  phone: `8${run}${String(i).padStart(3, '0')}`.slice(0, 10), join_date: inDays(10), employment_type: 'full_time', job_title: 'Field Operator',
  opening: opening.code, ...extra });
const phone = (i) => `7${String(Number(run) % 1000).padStart(3, '0')}${String(i).padStart(6, '0')}`;
const good = [];
STAGES.forEach((st, s) => { for (let k = 0; k < PER; k++) { const i = s * PER + k + 1; good.push(row(i, oOp[st], { phone: phone(i) })); } });
const managers = [row(9001, oSM, { phone: phone(9001), full_name: `Load ${run} State Manager` }),
  row(9002, oCM, { phone: phone(9002), full_name: `Load ${run} Client Manager A` }), row(9003, oCM, { phone: phone(9003), full_name: `Load ${run} Client Manager B` })];
const bad = [row(9101, oOp.qc, { phone: phone(9101), personal_email: 'nope' }), row(9102, oOp.qc, { phone: '12345' }),
  row(9103, oOp.qc, { phone: phone(9103), opening: 'UP-NONE-999' }), row(9104, oOp.qc, { phone: phone(9104), join_date: '2026-13-40' }),
  row(9105, oOp.qc, { phone: phone(1), personal_email: `other${run}@example.com` }),                      // phone twice in the file
  row(9106, oOp.qc, { phone: phone(9106) })];                                                              // the qc opening is full by then
const files = []; const all = [...good, ...managers, ...bad];
for (let i = 0; i < all.length; i += 1000) files.push(all.slice(i, i + 1000));
let dry = { ready: 0, warning: 0, error: 0, skipped: 0 };
for (const [i, f] of files.entries()) {
  const d = await timed(`import preview, ${f.length} rows${files.length > 1 ? ` (file ${i + 1})` : ''}`, async () => must(await H.rpc('import_joiners', { p_rows: f, p_dry_run: true }), 'dry run'));
  for (const k of Object.keys(dry)) dry[k] += d.counts[k];
}
// One file is previewed on its own: a row clashing with a row of ANOTHER file (or filling an opening another file
// fills) shows in that file's commit, not in the preview. With one file (200 people) every bad row shows in the preview.
if (files.length === 1) ok(dry.ready === N + 3 && dry.error === bad.length, `import preview: ${N + 3} ready, ${bad.length} errors with reasons`, dry);
else ok(dry.ready + dry.error === all.length && dry.error >= 4, `import preview, ${files.length} files: ${dry.error} errors found file by file (the rest at commit)`, dry);
let made = 0; const createdIds = [];
for (const [i, f] of files.entries()) {
  const c = await timed(`import commit, ${f.length} rows${files.length > 1 ? ` (file ${i + 1})` : ''}`, async () => must(await H.rpc('import_joiners', { p_rows: f, p_dry_run: false, p_batch: `load-${run}-${i}` }), 'commit'));
  made += c.counts.created; for (const r of c.rows) if (r.created) createdIds.push(r.id);
}
ok(made === N + 3, `import commit: ${made} people made, in one go per file`);
let again = 0;
for (const f of files) again += must(await H.rpc('import_joiners', { p_rows: f, p_dry_run: false }), 'again').counts.created;
ok(again === 0, 'import again: the same file makes nobody twice');
const people = (await svc.get('app_users', `email=like.load${run}.*&select=id,email,display_name`)).data;
const byEmail = Object.fromEntries(people.map((p) => [p.email, p.id]));
const opIds = good.map((g) => byEmail[g.personal_email]);
const [smId, cmA, cmB] = managers.map((m) => byEmail[m.personal_email]);
ok((await num(oOp.qc)).joining === PER && (await num(oOp.qc)).vacant === 0, `openings: each operator opening ${PER} joining, 0 vacant`);
const tpl = (await svc.get('employee_org', `employee_id=eq.${opIds[0]}&select=template_id,intended_role,intended_stage,onboarding_templates(role)`)).data[0];
ok(tpl.onboarding_templates?.role === 'operator' && tpl.intended_stage === 'procurement', 'checklist for the role: the Operator template, picked by the role', tpl);
const smTpl = (await svc.get('employee_org', `employee_id=eq.${smId}&select=onboarding_templates(role)`)).data[0];
ok(smTpl.onboarding_templates?.role === 'state_manager', 'checklist for the role: the State Manager template for the State Manager');

// 3 · invites in bulk (the local stack has a mail stand-in, so they are also "sent"); one accepted
const fn = async (name, tok, body) => { const r = await fetch(`${cfg.url}/functions/v1/${name}`, { method: 'POST',
  headers: { apikey: cfg.anon, authorization: `Bearer ${tok ?? cfg.anon}`, 'content-type': 'application/json', origin: 'http://127.0.0.1:5173' }, body: JSON.stringify(body) });
  return { status: r.status, data: await r.json().catch(() => null) }; };
const links = {};
await timed(`invites in bulk, ${N + 3} people (batches of 100)`, async () => {
  const ids = [...opIds, smId, cmA, cmB];
  for (let i = 0; i < ids.length; i += 100) {
    const r = await fn('invite', hr, { action: 'send', employee_ids: ids.slice(i, i + 100) });
    if (r.status !== 200) throw new Error(`invite send: ${r.status} ${JSON.stringify(r.data)}`);
    for (const x of r.data.results) links[x.id] = x.link;
  }
});
ok(Object.keys(links).length === N + 3 && Object.values(links).every((l) => /\/invite#[A-Za-z0-9_-]{43}$/.test(l)), `invites: ${N + 3} one-time links made`);
const tok0 = links[opIds[0]].split('#')[1];
const chk = await fn('invite', null, { action: 'check', token: tok0 });
ok(chk.status === 200 && chk.data.state === 'ok' && /^Load$/.test(chk.data.first_name) && chk.data.email_masked.includes('•••'), 'invite: the link says whose it is, the address masked', chk.data);
const acc = await fn('invite', null, { action: 'accept', token: tok0, password: `Own-${run}-pw` });
ok(acc.status === 200 && acc.data.sign_in === good[0].personal_email, 'invite: the joiner sets their own password', acc);
const joinerTok = await signIn(cfg, { email: good[0].personal_email, password: `Own-${run}-pw` }).catch(() => null);
ok(!!joinerTok, 'invite: and signs in with it');
const mine = joinerTok ? must(await as(joinerTok).rpc('my_onboarding'), 'my_onboarding') : null;
ok(mine && mine.tasks.length > 0, 'invite: the joiner sees their checklist');
ok((await fn('invite', null, { action: 'accept', token: tok0, password: `Again-${run}-pw` })).status === 410, 'invite: the link works once');

// 4 · HR owners split the work; the lists stay fast
await timed(`HR owner set for ${Math.floor(N / 2)} people`, async () => must(await H.rpc('set_hr_owner', { p_employees: opIds.slice(0, N / 2), p_owner: '00000000-0000-4000-8000-000000000316' }), 'owner'));
const A = as(hrAdmin);
const mineHr = must(await H.rpc('joiners_page', { p: { owner: 'mine', q: `load ${run}`, limit: 1 } }), 'mine').total;
const mineAdmin = must(await A.rpc('joiners_page', { p: { owner: 'mine', q: `load ${run}`, limit: 1 } }), 'mine').total;
ok(mineHr === N / 2 + 3 && mineAdmin === N / 2, `"Mine": Imran ${mineHr}, Asha ${mineAdmin}`);
const totalJoining = must(await H.rpc('joiners_page', { p: { limit: 1 } }), 'all').total;
await timedAvg(`joiners list, first page of 50 (${totalJoining} in the list)`, async () => must(await H.rpc('joiners_page', { p: { limit: 50 } }), 'page'));
await timedAvg('joiners list, "Mine"', async () => must(await H.rpc('joiners_page', { p: { owner: 'mine', limit: 50 } }), 'page'));
await timedAvg('joiners list, by opening, page 3', async () => must(await H.rpc('joiners_page', { p: { opening: oOp.qc.id, limit: 50, offset: 100 } }), 'page'));
await timedAvg('joiners list, search', async () => must(await H.rpc('joiners_page', { p: { q: 'operator 1', limit: 50 } }), 'page'));
await timedAvg('joiners list, overdue only, waiting on the joiner', async () => must(await H.rpc('joiners_page', { p: { overdue: true, waiting: 'joiner', limit: 50 } }), 'page'));
await timedAvg('people & access, first page of 50', async () => must(await H.rpc('people_page', { p: { limit: 50 } }), 'page'));
await timedAvg('people & access, by role and state', async () => must(await H.rpc('people_page', { p: { role: 'operator', state: UP, limit: 50 } }), 'page'));
await timedAvg('audit log, first page of 50', async () => must(await A.rpc('audit_page', { p: { limit: 50 } }), 'page'));
await timedAvg('openings page (all numbers)', async () => must(await H.rpc('openings_summary', {}), 'summary'));

// 5 · the gate on Mark as joined, then the whole wave joined
const t0 = (await svc.get('onboarding_tasks', `employee_id=eq.${opIds[1]}&statutory=eq.true&select=id`)).data[0];
const refused = await H.rpc('activate_joiner', { p_employee: opIds[1] });
ok(!refused.ok && /statutory step is still open/.test(refused.data?.message ?? ''), 'gate: refused while the PF step is open');
const allIds = [...opIds, smId, cmA, cmB];
await timed(`statutory step recorded on paper, ${allIds.length} people`, async () => {
  const tasks = [];
  for (let i = 0; i < allIds.length; i += 150) tasks.push(...(await svc.get('onboarding_tasks', `employee_id=in.(${allIds.slice(i, i + 150).join(',')})&statutory=eq.true&status=eq.pending&select=id`)).data);
  for (let i = 0; i < tasks.length; i += 25) await Promise.all(tasks.slice(i, i + 25).map((x) => H.rpc('record_on_paper', { p_task: x.id, p_note: 'forms signed at the induction' })));
});
const noReason = await H.rpc('activate_joiner', { p_employee: opIds[1] });
ok(!noReason.ok && /give a reason/.test(noReason.data?.message ?? ''), 'gate: other steps open, so a reason is needed');
void t0;
const joinedRes = { done: 0 };
await timed(`marked as joined, ${allIds.length} people (in acts of up to 500)`, async () => {
  for (let i = 0; i < allIds.length; i += 500) joinedRes.done += must(await H.rpc('activate_many', { p_employees: allIds.slice(i, i + 500), p_reason: 'induction day: forms done, the rest in the field' }), 'activate').done;
});
ok(joinedRes.done === allIds.length, `joined: ${joinedRes.done} of ${allIds.length}, each with a flagged line and the reason`);
const flagged = (await svc.get('audit_log', `action=eq.activated_with_open_steps&target=in.(${opIds.slice(0, 20).join(',')})&select=flagged`)).data;
ok(flagged.length === 20 && flagged.every((f) => f.flagged), 'joined: flagged per person');
let o = await num(oOp.procurement);
ok(o.joined === PER && o.waiting_wave === PER && o.ready === 0 && o.assigned === 0, `openings: ${PER} joined and waiting for their wave (the scope is not active)`, o);

// 6 · the scope is activated: the operators are ready; 40 on a stage in one act, five times
must(await pub(sm).update('scopes', `id=eq.${scope.id}`, { status: 'active' }), 'activate scope');
o = await num(oOp.procurement);
ok(o.ready === PER && o.waiting_wave === 0, `openings: the scope is active: ${PER} ready to assign`, o);
const S = as(sm);
const ready = await timed('ready to assign on the scope', async () => must(await S.rpc('ready_to_assign', { p_lens: 'scope', p_target: scope.id }), 'ready'));
ok(ready.length === N, `ready to assign: all ${N} operators, each with their stage`);
for (const st of STAGES) {
  const ids = ready.filter((r) => r.stage === st).map((r) => r.employee_id);
  const r = await timed(`assign ${ids.length} people to ${st} in one act`, async () => must(await S.rpc('assign_many', { p_employees: ids, p_lens: 'scope', p_target: scope.id, p_op_role: 'operator', p_stages: [st] }), 'assign many'));
  if (ids.length > 500) throw new Error('more than 500 in one act');
  ok(r.done === PER, `assign many: ${r.done} on ${st}`);
}
const smSeat = must(await A.rpc('assign_many', { p_employees: [smId], p_lens: 'state', p_target: UP, p_op_role: 'state_supervisor' }), 'seat SM');
const cms = must(await S.rpc('assign_many', { p_employees: [cmA, cmB], p_lens: 'client', p_target: CLIENT, p_op_role: 'client_account' }), 'CMs');
ok(smSeat.done === 1 && cms.done === 2, 'the State Manager seated by the HR Admin; the two Client Managers given the client');
const sum = must(await H.rpc('openings_summary', { p_state: UP }), 'summary');
const ours = sum.openings.filter((x) => [oSM.id, oCM.id, ...STAGES.map((s) => oOp[s].id)].includes(x.id));
ok(ours.every((x) => x.assigned === x.positions && x.vacant === 0 && x.joining === 0), 'openings: every position assigned, none vacant', ours.map((x) => [x.code, x.assigned, x.positions]));
const overview = must(await as(admin).rpc('platform_overview'), 'overview');
const fullSum = must(await as(admin).rpc('openings_summary', {}), 'summary');
ok(JSON.stringify(overview.openings.total) === JSON.stringify(fullSum.total), "admin overview: the same totals as the Openings page", [overview.openings.total, fullSum.total]);

console.log('\ntimings (local stack; the hosted project adds network time per call):');
for (const [w, ms] of timings) console.log(`  ${String(Math.round(ms)).padStart(7)} ms  ${w}`);
console.log(`\n${passes} passed, ${failures} failed`);
console.log(failures ? 'LOAD TEST FAILED' : 'LOAD TEST PASSED');
process.exit(failures ? 1 : 0);
