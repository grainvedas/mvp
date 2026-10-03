#!/usr/bin/env node
// RESTORE DRILL (PRD §9 "quarterly restore drill", §12 release criterion "restore drill completed from backup").
// A backup is only a backup once it has been restored and found identical. Two ways to run it:
//
// A. From an off-platform backup (scripts/backup.mjs), into a SCRATCH database on this machine, the same way a lost
//    project is rebuilt: schema from supabase/migrations, then the backup's data with triggers off:
//      node scripts/restore_drill.mjs                    takes a fresh backup of the project in .env.local, then restores it
//      node scripts/restore_drill.mjs --backup backups/<UTC time>
//      ENV_FILE=.env.stack node scripts/restore_drill.mjs       rehearsal on the local stack
//    The scratch database is created on the local Postgres named by PGHOST / PGPORT / PGUSER (default 127.0.0.1:5432,
//    postgres); it must be the same major version as the source or newer. It is dropped afterwards (--keep keeps it).
//    The script refuses any target that is not on this machine: it can never restore over a real project.
//
// B. After restoring one of Supabase's own backups into a NEW project (Dashboard → Database → Backups → Restore to a
//    new project), compare that project with the source:
//      node scripts/restore_drill.mjs --compare .env.restored       (.env.restored holds the new project's SUPABASE_DB_URL)
//
// Checks, both ways: every table has the same number of rows; the ledger has the same last block and the same chain
// digest and verifies; records, farmers and evidence fingerprints are identical; the newest sealed lot's public page
// is byte-identical; the ledger audit finds nothing. Way A also alters one block in the restored copy and expects the
// chain check to notice (a check that cannot fail proves nothing).
// Output: the log on screen and in <backup>/RESTORE_DRILL.log; last line RESTORE DRILL PASSED or FAILED; exit code.
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { ROOT } from './lib/env.mjs';
import { describeUrl, diffFingerprints, envFromUrl, fingerprint, run, serverVersion, sourceUrl, sql, toolVersion } from './lib/pg.mjs';
import { takeBackup } from './backup.mjs';

const has = (flag) => process.argv.includes(flag);
const opt = (name) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : undefined; };
const lines = [];
const log = (s = '') => { lines.push(s); console.log(s); };
const SCRATCH = 'grainveda_restore_drill';
let failures = 0;
const check = (ok, name, detail = '') => { if (!ok) failures++; log(`${ok ? 'ok  ' : 'FAIL'}  ${name}${detail ? `  ${ok ? '' : '-> '}${detail}` : ''}`); };

function auditOf(env) {
  const out = run('psql', ['-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', join(ROOT, 'tests', 'remote_ledger_audit.sql')], env).stdout.trim();
  return { clean: /NO FINDINGS/.test(out), text: out.split('\n').slice(0, 5).join(' / ') };
}

async function compareProjects(otherEnvFile) {
  const src = sourceUrl();
  const srcEnv = envFromUrl(src);
  const mainEnvFile = process.env.ENV_FILE;
  const dst = sourceUrl(otherEnvFile);
  process.env.ENV_FILE = mainEnvFile;
  if (describeUrl(src) === describeUrl(dst)) throw new Error('the restored project is the same database as the source: nothing to compare');
  const dstEnv = envFromUrl(dst);
  log(`source: Supabase backup restored to project ${describeUrl(dst)}, compared with ${describeUrl(src)}`);
  log(`started: ${new Date().toISOString()}`);
  const a = fingerprint(srcEnv), b = fingerprint(dstEnv);
  // the source keeps working while the backup is restored: the restored copy may be OLDER, never different in what it has
  const older = (b.ledger_last_seq ?? 0) <= (a.ledger_last_seq ?? 0);
  check(older, `the restored project is at ledger block ${b.ledger_last_seq}, the source at ${a.ledger_last_seq}`);
  const sameBlock = b.ledger_last_seq ? sql(srcEnv, `select hash from public.ledger where seq = ${Number(b.ledger_last_seq)}`) : '';
  check(!b.ledger_last_seq || sameBlock === b.ledger_last_hash, 'that block has the same hash in both: the restored chain is a true prefix of the source chain');
  check(b.ledger_bad_blocks === 0, 'the restored ledger verifies', `${b.ledger_bad_blocks} bad block(s)`);
  const audit = auditOf(dstEnv);
  check(audit.clean, 'ledger audit on the restored project', audit.text);
  if (a.ledger_last_seq === b.ledger_last_seq) {
    const d = diffFingerprints(a, b);
    check(d.length === 0, 'nothing was written since the backup: the two databases are identical', d.slice(0, 8).join('; '));
  } else {
    log(`note  ${a.ledger_last_seq - b.ledger_last_seq} block(s) were written to the source after the backup was taken: row counts are not compared`);
  }
  return null;
}

async function restoreBackup() {
  let dir = opt('--backup') ? resolve(opt('--backup')) : null;
  if (!dir) { log('No --backup given: taking a fresh one first.'); dir = (await takeBackup({ log })).dir; }
  const manifestPath = join(dir, 'MANIFEST.json');
  if (!existsSync(manifestPath)) throw new Error(`${dir} is not a backup folder (no MANIFEST.json)`);
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  if (opt('--backup')) log(`source: ${manifest.source}`);
  log(`backup: ${dir.replace(ROOT, '.')}  taken ${manifest.taken_at}`);
  log(`started: ${new Date().toISOString()}`);

  const dump = join(dir, 'db.dump');
  const sum = createHash('sha256').update(readFileSync(dump)).digest('hex');
  check(sum === manifest.files['db.dump'].sha256, 'the dump file is the one the manifest describes (SHA-256)');

  // the scratch target: this machine only
  const host = process.env.PGHOST ?? '127.0.0.1';
  if (!(/^(127\.0\.0\.1|localhost|::1)$/.test(host) || host.startsWith('/'))) {
    throw new Error(`REFUSED: the scratch database must be on this machine, PGHOST is ${host}. The drill never restores over a real project.`);
  }
  const base = { PGHOST: host, PGPORT: process.env.PGPORT ?? '5432', PGUSER: process.env.PGUSER ?? 'postgres', PGDATABASE: 'postgres' };
  const target = { ...base, PGDATABASE: SCRATCH };
  const targetMajor = Math.floor(serverVersion(base) / 10000), sourceMajor = Math.floor(manifest.server_version_num / 10000);
  check(targetMajor >= sourceMajor && toolVersion('pg_restore') >= manifest.pg_dump_major,
    `scratch server PostgreSQL ${targetMajor}, pg_restore ${toolVersion('pg_restore')}; the backup is from PostgreSQL ${sourceMajor}, taken with pg_dump ${manifest.pg_dump_major}`);

  // The restore, the way a lost project is rebuilt (docs/RESTORE.md): the schema from the repository's migrations,
  // then the data from the backup with triggers off, so nothing is re-derived and no ledger block is written again.
  const t0 = Date.now();
  run('dropdb', ['--if-exists', SCRATCH], base);
  run('createdb', [SCRATCH], base);
  // what a Supabase project already has: the three API roles, auth.uid(), storage tables, pgcrypto in schema extensions
  run('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1', '-f', join(ROOT, 'tests', '00_local_auth_shim.sql')], target);
  run('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1', '-c',
    'create schema if not exists extensions; create extension if not exists pgcrypto with schema extensions; create extension if not exists "uuid-ossp" with schema extensions;'], target);
  const migrations = manifest.migrations ?? readdirSync(join(ROOT, 'supabase', 'migrations')).filter((f) => f.endsWith('.sql')).sort();
  const missing = migrations.filter((f) => !existsSync(join(ROOT, 'supabase', 'migrations', f)));
  check(missing.length === 0, `the ${migrations.length} migrations the backup was taken under are in this repository`, missing.length ? `missing: ${missing.join(', ')}` : '');
  for (const f of migrations) if (!missing.includes(f)) run('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1', '-f', join(ROOT, 'supabase', 'migrations', f)], { ...target, PGOPTIONS: '-c client_min_messages=warning' });
  const dataSql = join(dir, 'data.restore.sql');
  run('pg_restore', ['--data-only', '--no-owner', '--no-privileges', '--file', dataSql, dump], base);
  const load = run('psql', ['-X', '-q', '-1', '-v', 'ON_ERROR_STOP=1', '-c', 'set session_replication_role = replica', '-f', dataSql], target, { allowFail: true });
  rmSync(dataSql, { force: true });                                     // plain-text farmer data: not left lying around
  const seconds = (Date.now() - t0) / 1000;
  check(load.status === 0, `schema rebuilt from the migrations and the backup's data loaded, in ${seconds.toFixed(1)} s`, (load.stderr ?? '').trim().split('\n').slice(-3).join(' | '));

  const after = fingerprint(target);
  const diff = diffFingerprints(manifest.fingerprint, after);
  const rows = Object.values(after.tables ?? {}).reduce((a, b) => a + b, 0);
  check(diff.length === 0, `identical to the source: ${Object.keys(after.tables ?? {}).length} tables, ${rows} rows; ${after.functions_app} functions, ${after.policies_public} policies, ` +
    `${after.triggers_public} triggers, ${after.api_table_grants} API table grants, ${after.api_functions} API functions (so the source has not drifted from the migrations)`,
    diff.slice(0, 10).join('; '));
  check(after.ledger_bad_blocks === 0 && after.ledger_last_hash === manifest.fingerprint.ledger_last_hash,
    `ledger: ${after.ledger_blocks} blocks verify; last block ${String(after.ledger_last_hash).slice(0, 12)}… is the source's last block`);
  check(after.newest_seal_public_page_md5 === manifest.fingerprint.newest_seal_public_page_md5,
    after.newest_seal ? `the public page of the newest sealed lot (${after.newest_seal}) is byte-identical` : 'no sealed lot yet: nothing to compare on the public page');
  const audit = auditOf(target);
  check(audit.clean, 'ledger audit on the restored copy', audit.text);

  // a check that cannot fail proves nothing: alter one block in the restored copy and expect the chain check to notice
  if (after.ledger_blocks > 2) {
    run('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1', '-c',
      `alter table public.ledger disable trigger all;
       update public.ledger set payload = payload || '{"altered_by_drill": true}'::jsonb where seq = (select seq from public.ledger order by seq offset ${Math.floor(after.ledger_blocks / 2)} limit 1);
       alter table public.ledger enable trigger all;`], target);
    const bad = sql(target, "select coalesce(min(seq)::text, '') from app.verify_ledger()");
    check(bad !== '', `one block altered by hand in the restored copy is caught by the chain check${bad ? ` (block ${bad})` : ''}`);
  }
  if (manifest.evidence && manifest.evidence !== 'skipped') {
    check(manifest.evidence.stored === manifest.evidence.expected && manifest.evidence.problems.length === 0,
      `evidence in the backup: ${manifest.evidence.stored}/${manifest.evidence.expected} file(s), each re-hashed against the record`);
  } else log('note  evidence files were not part of this backup');
  if (manifest.logins !== null && manifest.logins !== undefined) log(`note  logins in the backup: ${manifest.logins} (auth.dump; restored into a NEW project only, see docs/RESTORE.md)`);
  if (!has('--keep')) run('dropdb', ['--if-exists', SCRATCH], base); else log(`note  scratch database kept: ${SCRATCH}`);
  return dir;
}

let dir = null;
try {
  dir = opt('--compare') ? await compareProjects(opt('--compare')) : await restoreBackup();
} catch (e) { failures++; log(`FAIL  ${e.message}`); }
log(`finished: ${new Date().toISOString()}`);
log(failures === 0 ? 'RESTORE DRILL PASSED' : `RESTORE DRILL FAILED (${failures})`);
const out = dir ? join(dir, 'RESTORE_DRILL.log') : join(ROOT, 'backups', `RESTORE_DRILL_compare_${Date.now()}.log`);
try { writeFileSync(out, lines.join('\n') + '\n'); console.log(`log: ${out.replace(ROOT, '.')}`); } catch { /* the screen has it */ }
process.exit(failures === 0 ? 0 : 1);
