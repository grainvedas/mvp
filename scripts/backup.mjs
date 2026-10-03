#!/usr/bin/env node
// OFF-PLATFORM BACKUP of one GrainVeda project: the database (records, ledger, rules), the logins, and the evidence
// files, each checked as it is taken. This is the second copy; the first is Supabase's own daily backup (Pro plan).
//
//   node scripts/backup.mjs                          the project in .env.local
//   ENV_FILE=.env.production node scripts/backup.mjs
//   ENV_FILE=.env.stack node scripts/backup.mjs      the local stack (rehearsal)
//   options:  --out <folder> (default ./backups)   --no-evidence   --no-logins
//
// Needs in the env file: SUPABASE_DB_URL (Dashboard → Connect → Session pooler, port 5432), SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY (for the evidence files). Needs pg_dump of the server's major version or newer (PGBIN or PATH).
//
// Writes backups/<UTC time>/  db.dump (schemas public + app, custom format)   auth.dump (logins)   evidence/<path>…
//                             MANIFEST.json (what was taken, sizes, SHA-256, and the database's fingerprint)
// THE FOLDER HOLDS FARMERS' PHONE NUMBERS AND PASSWORD HASHES. Keep it encrypted, off shared drives, out of git
// (backups/ is git-ignored). scripts/restore_drill.mjs proves a backup can be restored.
import { createHash } from 'node:crypto';
import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ROOT, supabaseConfig } from './lib/env.mjs';
import { describeUrl, envFromUrl, fingerprint, run, serverVersion, sourceUrl, sql, toolVersion } from './lib/pg.mjs';

const sha256File = (p) => createHash('sha256').update(readFileSync(p)).digest('hex');
const has = (flag) => process.argv.includes(flag);
const opt = (name, fallback) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : fallback; };

export async function takeBackup({ outRoot = join(ROOT, 'backups'), evidence = true, logins = true, log = console.log } = {}) {
  const url = sourceUrl();
  const env = envFromUrl(url);
  const started = new Date();
  const stamp = started.toISOString().replace(/[-:]/g, '').replace(/\..+/, 'Z');
  const dir = resolve(outRoot, stamp);
  mkdirSync(dir, { recursive: true });

  const server = serverVersion(env), dumpTool = toolVersion('pg_dump');
  if (dumpTool < Math.floor(server / 10000)) {
    throw new Error(`pg_dump is version ${dumpTool} but the server runs PostgreSQL ${Math.floor(server / 10000)}: install the newer client tools (or set PGBIN).`);
  }
  const hostIsSupabase = /supabase\.(co|com|in)$/.test(new URL(url).hostname);
  const before = fingerprint(env);
  if (!before.tables || !('ledger' in before.tables)) throw new Error('this database has no GrainVeda tables');
  const label = `${hostIsSupabase ? 'Supabase project' : 'local stack database'} ${describeUrl(url)} (${before.environment}), logical dump ${started.toISOString()}`;
  log(`source: ${label}`);

  // 1. database: everything GrainVeda owns. Supabase's own schemas (auth, storage, extensions) are not GrainVeda's to restore.
  const t0 = Date.now();
  run('pg_dump', ['--format=custom', '--schema=public', '--schema=app', '--no-owner', '--no-privileges', '--file', join(dir, 'db.dump')], env);
  const files = { 'db.dump': { bytes: statSync(join(dir, 'db.dump')).size, sha256: sha256File(join(dir, 'db.dump')), seconds: (Date.now() - t0) / 1000 } };
  log(`database: db.dump ${(files['db.dump'].bytes / 1024).toFixed(0)} KB in ${files['db.dump'].seconds.toFixed(1)} s`);

  // 2. logins (phone / e-mail and the password hash), so people can sign in again after a restore into a new project
  let loginCount = null;
  if (logins) {
    try {
      loginCount = Number(sql(env, 'select count(*) from auth.users'));
      const tables = ['auth.users', ...(sql(env, "select to_regclass('auth.identities') is not null") === 't' ? ['auth.identities'] : [])];
      run('pg_dump', ['--format=custom', '--data-only', ...tables.flatMap((t) => ['--table', t]), '--no-owner', '--no-privileges', '--file', join(dir, 'auth.dump')], env);
      files['auth.dump'] = { bytes: statSync(join(dir, 'auth.dump')).size, sha256: sha256File(join(dir, 'auth.dump')), rows: loginCount };
      log(`logins: auth.dump, ${loginCount} login(s)`);
    } catch (e) { log(`logins: NOT backed up (${String(e.message).split('\n')[0]})`); }
  }

  // 3. evidence files: every file the database knows, downloaded with the service key and re-hashed
  const ev = { expected: 0, stored: 0, bytes: 0, problems: [] };
  if (evidence) {
    const cfg = supabaseConfig({ needService: true });
    const rows = JSON.parse(sql(env, "select coalesce(jsonb_agg(jsonb_build_object('path', storage_path, 'sha256', sha256) order by created_at, id), '[]')::text from public.attachments"));
    ev.expected = rows.length;
    for (const a of rows) {
      const res = await fetch(`${cfg.url}/storage/v1/object/evidence/${a.path.split('/').map(encodeURIComponent).join('/')}`,
        { headers: { apikey: cfg.service, authorization: `Bearer ${cfg.service}` } });
      if (!res.ok) { ev.problems.push(`${a.path}: not downloadable (${res.status})`); continue; }
      const bytes = Buffer.from(await res.arrayBuffer());
      if (createHash('sha256').update(bytes).digest('hex') !== a.sha256) { ev.problems.push(`${a.path}: SHA-256 differs from the record`); continue; }
      const p = join(dir, 'evidence', ...a.path.split('/'));
      if (!resolve(p).startsWith(resolve(dir, 'evidence'))) { ev.problems.push(`${a.path}: unsafe path`); continue; }
      mkdirSync(dirname(p), { recursive: true }); writeFileSync(p, bytes);
      ev.stored++; ev.bytes += bytes.length;
    }
    log(`evidence: ${ev.stored}/${ev.expected} file(s) stored and matching their fingerprint (${(ev.bytes / 1024).toFixed(0)} KB)` +
      (ev.problems.length ? `\n  PROBLEMS:\n  ${ev.problems.join('\n  ')}` : ''));
  }

  // The schema a restore rebuilds first: the migration files of this repository at the time of the backup (and, on a
  // Supabase project, the versions its own migration table says were applied).
  const repoMigrations = readdirSync(join(ROOT, 'supabase', 'migrations')).filter((f) => f.endsWith('.sql')).sort();
  let applied = null;
  try {
    if (sql(env, "select to_regclass('supabase_migrations.schema_migrations') is not null") === 't') {
      applied = sql(env, 'select version from supabase_migrations.schema_migrations order by version').split('\n').filter(Boolean);
    }
  } catch { /* not readable with this login: the repository list stands */ }
  const manifest = { taken_at: started.toISOString(), source: label, server_version_num: server, pg_dump_major: dumpTool,
    files, logins: loginCount, evidence: evidence ? ev : 'skipped', migrations: repoMigrations, migrations_applied_on_source: applied, fingerprint: before };
  writeFileSync(join(dir, 'MANIFEST.json'), JSON.stringify(manifest, null, 2));
  log(`manifest: ${join(dir, 'MANIFEST.json').replace(ROOT, '.')}`);
  return { dir, manifest, ok: ev.problems.length === 0 };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const r = await takeBackup({ outRoot: resolve(opt('--out', join(ROOT, 'backups'))), evidence: !has('--no-evidence'), logins: !has('--no-logins') });
    console.log(r.ok ? `\nBACKUP TAKEN  ${r.dir.replace(ROOT, '.')}\nKeep this folder encrypted and off shared drives: it holds phone numbers and password hashes.`
                     : '\nBACKUP INCOMPLETE: see PROBLEMS above');
    process.exit(r.ok ? 0 : 1);
  } catch (e) { console.error(`BACKUP FAILED: ${e.message}`); process.exit(1); }
}
