#!/usr/bin/env node
// RELEASE GATE (PRD §12): every release criterion, the evidence found for it, and a verdict.
// It reads result files only; it runs nothing and talks to no server.
//
//   node scripts/release_gate.mjs                 reads ./release-evidence, prints the table, writes release-evidence/GATE.md
//   node scripts/release_gate.mjs --dir <folder>
//   exit 0 only when every criterion is PASS.
//
// The files are produced by scripts/collect_release_evidence.sh (what can be run on the local stack) and by the
// staging steps of docs/RUNSHEET_phase4.md. A criterion without its file is NOT RUN, never assumed.
//   sql.log            tests/run_local.sh                       edge checks, RLS suite (database level)
//   unit.json          vitest --reporter=json                   Hindi completeness
//   e2e.json           playwright (whole suite, JSON reporter)  offline edge check, Hindi on the screens
//   prod.log           playwright -c playwright.prod.config.ts  public page time and size on throttled 3G
//   acceptance-1.json, acceptance-2.json   playwright -c playwright.acceptance.config.ts, two consecutive runs
//   rls.log            node tests/remote_rls.mjs --t1           permissions with real logins through the API
//   audit.log          tests/remote_ledger_audit.sql            every block has a real counterpart
//   lighthouse.json    lighthouse <verify page> --only-categories=accessibility --output=json
//   restore-drill.log  scripts/restore_drill.sh
//   ../docs/ACCEPTANCE_SIGNOFF.md                               Veda's own run of T1–T4, and who ran the acceptance suite
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { ROOT } from './lib/env.mjs';

const arg = (name, fallback) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : fallback; };
const dir = resolve(arg('--dir', join(ROOT, 'release-evidence')));
const signoffFile = resolve(arg('--signoff', join(ROOT, 'docs', 'ACCEPTANCE_SIGNOFF.md')));
// Result files written from Windows PowerShell may be UTF-16 or carry a byte-order mark: read them all the same.
const text = (name) => {
  const p = join(dir, name);
  if (!existsSync(p)) return null;
  const b = readFileSync(p);
  const s = b[0] === 0xff && b[1] === 0xfe ? b.toString('utf16le') : b.toString('utf8');
  return s.replace(/^\uFEFF/, '').replace(/\r\n/g, '\n');
};
const json = (name) => { const t = text(name); if (t === null) return null; try { return JSON.parse(t); } catch { return undefined; } };
const local = (u) => /127\.0\.0\.1|localhost/.test(String(u ?? ''));

/** Every test of a Playwright JSON report: { title, file, status } with status passed | failed | flaky | skipped. */
function playwrightTests(report) {
  const out = [];
  const walk = (suite, file) => {
    for (const spec of suite.specs ?? []) {
      const t = spec.tests?.[0];
      const status = t?.status === 'expected' ? 'passed' : t?.status === 'flaky' ? 'flaky' : t?.status === 'skipped' ? 'skipped' : 'failed';
      out.push({ title: spec.title, file: file ?? suite.file ?? suite.title, status });
    }
    for (const s of suite.suites ?? []) walk(s, file ?? suite.file ?? suite.title);
  };
  for (const s of report?.suites ?? []) walk(s, s.file ?? s.title);
  return out;
}

const rows = [];
const add = (criterion, verdict, evidence) => rows.push({ criterion, verdict, evidence });

// ---- 1. T1–T5 green in staging on two consecutive runs ---------------------------------------------------------------
{
  const runs = ['acceptance-1.json', 'acceptance-2.json'].map((f) => ({ f, r: json(f) }));
  const detail = [];
  let verdict = 'PASS';
  for (const { f, r } of runs) {
    if (r === null) { verdict = 'NOT RUN'; detail.push(`${f}: missing`); continue; }
    if (r === undefined) { verdict = 'FAIL'; detail.push(`${f}: not a JSON report`); continue; }
    const tests = playwrightTests(r).filter((t) => /\bT[1-5]: /.test(t.title));
    const got = Object.fromEntries(tests.map((t) => [t.title.match(/T[1-5]/)[0], t.status]));
    const line = ['T1', 'T2', 'T3', 'T4', 'T5'].map((t) => `${t} ${got[t] ?? 'missing'}`).join(', ');
    const target = r.config?.metadata?.target ?? 'unknown target';
    detail.push(`${f}: ${line} · ${target} · ${r.stats?.startTime ?? ''}`);
    if (!['T1', 'T2', 'T3', 'T4', 'T5'].every((t) => got[t] === 'passed')) { if (verdict !== 'NOT RUN') verdict = 'FAIL'; }
    else if (local(target) && verdict === 'PASS') verdict = 'REHEARSAL';
  }
  const [a, b] = runs.map((x) => x.r);
  if (a && b) {
    if ((a.config?.metadata?.target ?? '') !== (b.config?.metadata?.target ?? '')) { verdict = 'FAIL'; detail.push('the two runs were against different systems'); }
    if (new Date(b.stats?.startTime ?? 0) <= new Date(a.stats?.startTime ?? 0)) { verdict = 'FAIL'; detail.push('run 2 did not start after run 1'); }
  }
  add('T1–T5 green in staging on two consecutive runs', verdict,
    detail.join(' | ') + (verdict === 'REHEARSAL' ? ' | green on the LOCAL stack only: the staging run is still to be done' : ''));
}

// ---- 2. All edge checks green ------------------------------------------------------------------------------------------
{
  const sql = text('sql.log'), e2e = json('e2e.json');
  const sqlOk = (re) => (sql === null ? null : re.test(sql));
  const e2eTest = (re) => { if (!e2e) return e2e; const t = playwrightTests(e2e).find((x) => re.test(x.title)); return t ? t.status === 'passed' : false; };
  const checks = [
    ['chain without QC rejected; same stage twice rejected', sqlOk(/ok {3}rule 5: chain without QC rejected/) && sqlOk(/ok {3}rule 5: same stage type twice rejected/)],
    ['save exceeding input rejected, except Blanching', sqlOk(/ok {3}rule 3: non-blanching stage cannot exceed input/) && sqlOk(/ok {3}blanching: output > input allowed/) && sqlOk(/ok {3}availability: qty_in 200 > 178 available rejected/)],
    ['drying: moisture explains the drop → no flag; beyond → flag', sqlOk(/ok {3}drying: 9 kg drop explained by moisture → no loss flag/) && sqlOk(/ok {3}drying: 85 kg out .* flags grain loss/)],
    ['popping: 50 % yield at 85 % pop rate no flag; 75 % flagged', sqlOk(/ok {3}popping: 50% weight yield at 85% pop rate → no flag/) && sqlOk(/ok {3}popping: 75% pop rate flagged/)],
    ['QC qty_out = qty − sample; next stage sees it', sqlOk(/ok {3}rule 7: QC qty_out = 147\.5 - 0\.5 sample/)],
    ['run leaving < 2 kg closes the source', sqlOk(/ok {3}auto-close: source with < 2 kg left is closed/)],
    ['verified footprint UPDATE rejected; ledger DELETE rejected for every role', sqlOk(/ok {3}rule 4: verified payload immutable/) && sqlOk(/ok {3}ledger: DELETE refused \(superuser included\)/)],
    ['offline: 10 lots in airplane mode sync in order', e2eTest(/^Airplane mode: 10 farm-gate lots captured offline sync in capture order/)],
    ['nightly ledger check detects an altered payload_hash', sqlOk(/ok {3}ledger check: a hand-altered payload_hash is caught/)],
  ];
  const suitePassed = sql !== null && /ALL TESTS PASSED/.test(sql) && !/FAILED {3}|ASSERTION FAILED/.test(sql);
  const missing = checks.filter(([, v]) => v === null || v === undefined);
  const failed = checks.filter(([, v]) => v === false);
  const verdict = sql === null || e2e === null ? 'NOT RUN' : failed.length || !suitePassed || e2e === undefined ? 'FAIL' : missing.length ? 'NOT RUN' : 'PASS';
  add('All edge checks green', verdict,
    `${checks.filter(([, v]) => v === true).length}/9 edge checks found green` +
    (sql !== null ? ` · database suite: ${(sql.match(/ok {3}/g) ?? []).length} assertions, ${suitePassed ? 'ALL TESTS PASSED' : 'NOT all passed'}` : ' · sql.log missing') +
    (failed.length ? ` · not green: ${failed.map(([n]) => n).join('; ')}` : '') + (e2e === null ? ' · e2e.json missing' : ''));
}

// ---- 3. RLS test suite: 0 cross-tenant rows for any role ---------------------------------------------------------------
{
  const sql = text('sql.log'), rls = text('rls.log');
  const need = [/ok {3}tenant isolation: other client's operator sees 0 footprints/, /ok {3}tenant isolation: other client's operator sees 0 farmers/,
    /ok {3}tenant isolation: other client's operator sees 0 scopes/, /ok {3}tenant isolation: other client's operator sees 0 ledger blocks/,
    /ok {3}ledger: he cannot read the lab, mill or sale blocks of the same scope/, /ok {3}ledger: another client's operator reads nothing/];
  const db = sql === null ? null : need.every((re) => re.test(sql));
  const api = rls === null ? null : /REMOTE RLS PASSED/.test(rls) && !/^FAIL /m.test(rls);
  const n = rls?.match(/(\d+) passed, (\d+) failed/);
  const where = rls?.match(/^project: (.+)$/m)?.[1] ?? 'project not named in the log';
  const verdict = db === null || api === null ? 'NOT RUN' : db && api ? (local(where) ? 'REHEARSAL' : 'PASS') : 'FAIL';
  add('RLS test suite: 0 cross-tenant rows for any role', verdict,
    `database: ${db === null ? 'sql.log missing' : db ? 'isolation assertions green' : 'isolation assertions NOT all green'} · ` +
    `real logins through the API: ${rls === null ? 'rls.log missing' : `${n ? `${n[1]} passed, ${n[2]} failed` : 'no summary'} on ${where}`}` +
    (verdict === 'REHEARSAL' ? ' · LOCAL stack only: run tests/remote_rls.mjs against staging' : ''));
}

// ---- 4. Verify page < 3 s on throttled 3G; Lighthouse accessibility ≥ 90 ---------------------------------------------
{
  // the acceptance runs measure it on the deployed build (T1 prints it); prod.log is the same measurement on the local build
  const fromRuns = ['acceptance-1.json', 'acceptance-2.json'].map((f) => text(f)).filter(Boolean)
    .flatMap((t) => [...t.matchAll(/public page: (\d+) ms, (\d+) KB/g)]);
  const prod = fromRuns.length ? '' : text('prod.log'), lh = json('lighthouse.json');
  const all = fromRuns.length ? fromRuns : [...(prod ?? '').matchAll(/public page: (\d+) ms, (\d+) KB/g)];
  const m = all.length ? ['', Math.max(...all.map((x) => Number(x[1]))), Math.max(...all.map((x) => Number(x[2])))] : null;
  const speed = prod === null ? null : !!m && Number(m[1]) < 3000 && Number(m[2]) < 200;
  const score = lh ? Math.round((lh.categories?.accessibility?.score ?? 0) * 100) : null;
  const a11y = lh === null ? null : lh === undefined ? false : score >= 90;
  const targets = ['acceptance-1.json', 'acceptance-2.json'].map((f) => json(f)?.config?.metadata?.target).filter(Boolean);
  const measuredLocally = !fromRuns.length || targets.some(local) || local(lh?.finalDisplayedUrl ?? lh?.finalUrl ?? lh?.requestedUrl);
  const verdict = speed === null || a11y === null ? 'NOT RUN' : !(speed && a11y) ? 'FAIL' : measuredLocally ? 'REHEARSAL' : 'PASS';
  add('Verify page < 3 s on throttled 3G (and < 200 KB); Lighthouse accessibility ≥ 90', verdict,
    `${m ? `${m[1]} ms, ${m[2]} KB first load (${fromRuns.length ? `worst of ${fromRuns.length} measurement(s) in the acceptance runs` : 'local build, prod.log'})` : prod === null ? 'prod.log missing' : 'no measurement found'} · ` +
    `${lh === null ? 'lighthouse.json missing' : lh === undefined ? 'lighthouse.json unreadable' : `Lighthouse accessibility ${score} on ${lh.finalDisplayedUrl ?? lh.finalUrl ?? lh.requestedUrl ?? '?'}`}` +
    (verdict === 'REHEARSAL' ? ' · measured on a local build: repeat both on the deployed staging app' : ''));
}

// ---- 5. Restore drill completed from backup ----------------------------------------------------------------------------
{
  const log = text('restore-drill.log');
  const ok = log === null ? null : /RESTORE DRILL PASSED/.test(log);
  const src = log?.match(/^source: (.+)$/m)?.[1] ?? '';
  const verdict = ok === null ? 'NOT RUN' : !ok ? 'FAIL' : /supabase|production|staging backup/i.test(src) ? 'PASS' : 'REHEARSAL';
  add('Restore drill completed from backup', verdict,
    log === null ? 'restore-drill.log missing' : `${ok ? 'drill passed' : 'drill did NOT pass'} · source: ${src || 'not named'}` +
    (verdict === 'REHEARSAL' ? ' · a dump of the local stack: the drill from a real project backup is still to be done' : ''));
}

// ---- 6. Hindi strings complete for F4–F8 -------------------------------------------------------------------------------
{
  const unit = json('unit.json'), e2e = json('e2e.json');
  const names = ['has every English key, with the same {placeholders}', 'translates every stage name, form field, option and handoff check of all 16 stages',
    'every key the screens ask for exists in English (so no screen can show a raw key)',
    'no plain English text or label outside the translation table'];
  const results = unit ? (unit.testResults ?? []).flatMap((f) => f.assertionResults ?? []) : null;
  const found = results ? names.map((n) => results.find((r) => r.title === n)?.status === 'passed') : null;
  const screen = e2e ? playwrightTests(e2e).find((t) => /^Hindi: operator screens switch language/.test(t.title))?.status === 'passed' : null;
  const verdict = found === null || screen === null ? 'NOT RUN' : found.every(Boolean) && screen ? 'PASS' : 'FAIL';
  add('Hindi strings complete for F4–F8', verdict,
    `${found === null ? 'unit.json missing' : `${found.filter(Boolean).length}/${names.length} dictionary and screen-text checks green`} · ` +
    `${screen === null ? 'e2e.json missing' : screen ? 'operator screen switches to Hindi' : 'Hindi screen test not green'} · native-speaker review with operators: see sign-off`);
}

// ---- 7. Veda's own browser run of T1–T4, signed off; acceptance run by someone other than the builder ------------------
{
  const s = existsSync(signoffFile) ? readFileSync(signoffFile, 'utf8') : null;
  // the value after the label; the template's own hints in (brackets) do not count as an answer
  const field = (label) => (s?.match(new RegExp(`^\\s*[-*]?\\s*${label}:[ \\t]*([^\\n]*)$`, 'mi'))?.[1] ?? '').replace(/\(.*?\)/g, '').replace(/[_`*]/g, '').trim();
  const by = field('Signed off by'), on = field('Date'), ran = field('Acceptance suite run by');
  const t = ['T1', 'T2', 'T3', 'T4'].map((x) => [x, field(`${x} result`).toLowerCase()]);
  const done = !!by && /\d{4}-\d{2}-\d{2}/.test(on) && t.every(([, v]) => v.startsWith('pass'));
  add("Veda's own browser end-to-end run of T1–T4 completed and signed off", s === null ? 'NOT RUN' : done ? 'PASS' : 'PENDING',
    s === null ? 'docs/ACCEPTANCE_SIGNOFF.md missing' : `${t.map(([x, v]) => `${x} ${v || '—'}`).join(', ')} · signed off by: ${by || '—'} · date: ${on || '—'}`);
  add('Acceptance run by someone other than the developer who built the feature', s === null ? 'NOT RUN' : ran ? 'PASS' : 'PENDING',
    s === null ? 'docs/ACCEPTANCE_SIGNOFF.md missing' : `acceptance suite run by: ${ran || '—'}`);
}

// ---- supporting evidence (not PRD criteria on their own, but either one failing stops a release) ----------------------
{
  // PRD §9 "offline field capture" beyond the airplane-mode edge check: a whole day without network, dead links, lost
  // answers, a lost phone. Eight tests against the built app (they need a stand-in server to cut the link), and one
  // thing only a real phone can show: the app opening more than an hour after its last contact with the server.
  const prod = text('prod.log'), s = existsSync(signoffFile) ? readFileSync(signoffFile, 'utf8') : '';
  if (prod !== null) {
    const clean = prod.replace(/\x1b\[[0-9;]*m/g, '');
    const passed = (clean.match(/✓\s+\d+\s+e2e-prod[\\/]field_day\.spec\.ts/g) ?? []).length;
    const failed = (clean.match(/✘\s+\d+\s+e2e-prod[\\/]field_day\.spec\.ts/g) ?? []).length;
    const phone = (s.match(/^\s*[-*]?\s*Day without network on a real phone:[ \t]*([^\n]*)$/mi)?.[1] ?? '').replace(/\(.*?\)/g, '').trim().toLowerCase();
    const verdict = failed || passed < 8 ? 'FAIL' : phone.startsWith('pass') ? 'PASS' : phone.startsWith('fail') ? 'FAIL' : 'PENDING';
    add('Work without network: a day in the field, dead links, lost answers, lost phone', verdict,
      `built app: ${passed}/8 tests green${failed ? `, ${failed} failed` : ''} · on a real phone, more than an hour offline: ${phone || '—'}`);
  }
}
{
  const audit = text('audit.log');
  if (audit !== null) add('Ledger audit: every block has a real counterpart, every record its block', /NO FINDINGS/.test(audit) ? 'PASS' : 'FAIL',
    (audit.match(/NO FINDINGS[^\n|]*/)?.[0] ?? audit.trim().split('\n').slice(0, 3).join(' / ')).trim());
}

const order = { FAIL: 0, 'NOT RUN': 1, PENDING: 2, REHEARSAL: 3, PASS: 4 };
const worst = rows.reduce((w, r) => (order[r.verdict] < order[w] ? r.verdict : w), 'PASS');
const cell = (x) => String(x).replace(/\|/g, '\\|');
const md = [
  '# GrainVeda MVP · release gate (PRD §12)', '',
  `Generated ${new Date().toISOString()} from \`${dir.replace(ROOT, '.')}\`.`, '',
  '| # | Release criterion | Verdict | Evidence |', '|---|---|---|---|',
  ...rows.map((r, i) => `| ${i + 1} | ${cell(r.criterion)} | **${r.verdict}** | ${cell(r.evidence)} |`), '',
  `**Gate: ${worst === 'PASS' ? 'OPEN — every criterion has passed' : `CLOSED — ${rows.filter((r) => r.verdict !== 'PASS').length} of ${rows.length} not passed`}**`, '',
  'PASS = met, with the evidence named. REHEARSAL = green on the local stack only; the criterion asks for staging or a real backup.',
  'PENDING = waiting for a person. NOT RUN = no result file. FAIL = a result file says no.', '',
].join('\n');
console.log(md);
try { writeFileSync(join(dir, 'GATE.md'), md); } catch { /* evidence folder missing: the table above is the output */ }
process.exit(worst === 'PASS' ? 0 : 1);
