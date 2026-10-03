// Postgres client tools (pg_dump, pg_restore, psql, createdb, dropdb) for scripts/backup.mjs and scripts/restore_drill.mjs.
// The tools come from PGBIN (a folder) or the PATH. Connection details are passed to them in the environment
// (PGHOST, PGPASSWORD, …), never on a command line, so a database password does not show up in a process list or a log.
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { loadEnv } from './env.mjs';

const exe = process.platform === 'win32' ? '.exe' : '';
export const tool = (name) => (process.env.PGBIN ? join(process.env.PGBIN, name + exe) : name + exe);

/** Environment for a database given as a URL (postgresql://user:password@host:port/db). */
export function envFromUrl(url) {
  const u = new URL(url);
  const local = /^(127\.0\.0\.1|localhost|::1)$/.test(u.hostname);
  return {
    PGHOST: u.hostname, PGPORT: u.port || '5432', PGUSER: decodeURIComponent(u.username), PGPASSWORD: decodeURIComponent(u.password),
    PGDATABASE: decodeURIComponent(u.pathname.replace(/^\//, '')) || 'postgres', PGSSLMODE: u.searchParams.get('sslmode') ?? (local ? 'prefer' : 'require'),
    PGCONNECT_TIMEOUT: '20', PGAPPNAME: 'grainveda-backup',
  };
}
/** host/database of a URL, for logs. Never the user or the password. */
export function describeUrl(url) {
  const u = new URL(url);
  return `${u.hostname}:${u.port || 5432}/${decodeURIComponent(u.pathname.replace(/^\//, '')) || 'postgres'}`;
}

/** The source database URL: --source-url is not offered on purpose (it would put the password in the shell history). */
export function sourceUrl(envFile) {
  if (envFile) process.env.ENV_FILE = envFile;
  const env = loadEnv();
  const url = env.SUPABASE_DB_URL ?? env.DATABASE_URL ?? env.POSTGRES_URL;
  if (!url) throw new Error(`no database URL: put SUPABASE_DB_URL=postgresql://… in ${process.env.ENV_FILE ?? '.env.local'} (Dashboard → Connect → Session pooler)`);
  return url;
}

export function run(name, args, env, { input, allowFail = false } = {}) {
  const r = spawnSync(tool(name), args, { env: { ...process.env, ...env }, input, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  if (r.error) throw new Error(`${name} could not be started (${r.error.code ?? r.error.message}). Install the PostgreSQL client tools or set PGBIN to their folder.`);
  if (r.status !== 0 && !allowFail) throw new Error(`${name} failed (exit ${r.status}): ${(r.stderr || r.stdout || '').trim().split('\n').slice(-6).join('\n')}`);
  return r;
}
export const sql = (env, statement) => run('psql', ['-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', statement], env).stdout.trim();

export function serverVersion(env) { return Number(sql(env, 'show server_version_num')); }
export function toolVersion(name) {
  const m = run(name, ['--version'], {}).stdout.match(/(\d+)(?:\.(\d+))?/);
  return m ? Number(m[1]) : 0;
}

// What a database looks like, in one JSON object: compared before the dump and after the restore. Uses only built-ins.
export const FINGERPRINT_SQL = `
select jsonb_build_object(
  'tables', (select jsonb_object_agg(c.relname, (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from public.%I', c.relname), false, true, '')))[1]::text::bigint order by c.relname)
               from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r'),
  'functions_app', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app'),
  'policies_public', (select count(*) from pg_policies where schemaname = 'public'),
  'triggers_public', (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
                       where n.nspname = 'public' and not t.tgisinternal),
  'api_table_grants', (select count(*) from information_schema.role_table_grants
                        where table_schema = 'public' and grantee in ('anon', 'authenticated')),
  'api_functions', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'app' and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))),
  'ledger_blocks', (select count(*) from public.ledger),
  'ledger_last_seq', (select max(seq) from public.ledger),
  'ledger_last_hash', (select hash from public.ledger order by seq desc limit 1),
  'ledger_chain_digest', (select encode(sha256(convert_to(coalesce(string_agg(hash, '' order by seq), ''), 'UTF8')), 'hex') from public.ledger),
  'ledger_bad_blocks', (select count(*) from app.verify_ledger()),
  'footprints_digest', (select md5(coalesce(string_agg(id::text || footprint_code || status::text || qty_in::text || qty_out::text || payload::text, '|' order by id), '')) from public.footprints),
  'farmers_digest', (select md5(coalesce(string_agg(id::text || coalesce(farmer_code, '') || status::text || name || phone, '|' order by id), '')) from public.farmers),
  'evidence_digest', (select md5(coalesce(string_agg(storage_path || sha256, '|' order by id), '')) from public.attachments),
  'seals', (select count(*) from public.qr_seals),
  'newest_seal', (select qr_code from public.qr_seals order by sealed_at desc, qr_code limit 1),
  'newest_seal_public_page_md5', (select md5(app.public_lot_journey(qr_code)::text) from public.qr_seals order by sealed_at desc, qr_code limit 1),
  'environment', (select coalesce((select value from public.app_meta where key = 'environment'), 'staging'))
)::text`;
export const fingerprint = (env) => JSON.parse(sql(env, FINGERPRINT_SQL));

/** Differences between two fingerprints as readable lines. Empty = identical. */
export function diffFingerprints(a, b) {
  const out = [];
  for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {
    if (k === 'tables') {
      for (const t of new Set([...Object.keys(a.tables ?? {}), ...Object.keys(b.tables ?? {})])) {
        if (a.tables?.[t] !== b.tables?.[t]) out.push(`table ${t}: ${a.tables?.[t] ?? 'missing'} rows before, ${b.tables?.[t] ?? 'missing'} after`);
      }
    } else if (JSON.stringify(a[k]) !== JSON.stringify(b[k])) out.push(`${k}: ${JSON.stringify(a[k])} before, ${JSON.stringify(b[k])} after`);
  }
  return out;
}
