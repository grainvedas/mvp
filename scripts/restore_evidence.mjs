#!/usr/bin/env node
// Puts the evidence files of a backup (scripts/backup.mjs) back into a project's private `evidence` bucket, and checks
// every file the database knows against its recorded SHA-256. Used after restoring the database into a NEW project
// (Supabase's own backups do not contain Storage files), and safe to run again: a file already there is left alone,
// never overwritten.
//
//   ENV_FILE=.env.restored node scripts/restore_evidence.mjs --backup backups/<UTC time>
//   ENV_FILE=.env.stack    node scripts/restore_evidence.mjs --backup backups/<UTC time>      (local stack)
// Needs SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY of the TARGET project in the env file.
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { extname, join, relative, resolve, sep } from 'node:path';
import { client, supabaseConfig } from './lib/env.mjs';

const i = process.argv.indexOf('--backup');
const dir = i > 0 ? resolve(process.argv[i + 1], 'evidence') : null;
if (!dir || !existsSync(dir)) { console.error('usage: node scripts/restore_evidence.mjs --backup backups/<UTC time>   (the folder must contain evidence/)'); process.exit(2); }
const cfg = supabaseConfig({ needService: true });
const svc = { apikey: cfg.service, authorization: `Bearer ${cfg.service}` };
const TYPES = { '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp', '.heic': 'image/heic', '.pdf': 'application/pdf' };
const walk = (d) => readdirSync(d).flatMap((n) => { const p = join(d, n); return statSync(p).isDirectory() ? walk(p) : [p]; });
const url = (path) => `${cfg.url}/storage/v1/object/evidence/${path.split('/').map(encodeURIComponent).join('/')}`;

let uploaded = 0, present = 0; const problems = [];
for (const file of walk(dir)) {
  const path = relative(dir, file).split(sep).join('/');
  const res = await fetch(url(path), { method: 'POST', headers: { ...svc, 'content-type': TYPES[extname(file).toLowerCase()] ?? 'application/octet-stream', 'x-upsert': 'false' },
    body: readFileSync(file) });
  const body = await res.text();
  if (res.ok) uploaded++;
  else if (/already exists|Duplicate|"409"/i.test(body)) present++;
  else problems.push(`${path}: upload refused (${res.status} ${body.slice(0, 120)})`);
}
console.log(`evidence files: ${uploaded} uploaded, ${present} already in the bucket`);

// every file the database knows must now be in the bucket, with the fingerprint recorded when it was first attached
const rows = await client(cfg, { key: cfg.service }).get('attachments', 'select=storage_path,sha256&order=created_at');
if (!rows.ok) { console.error(`cannot read public.attachments: ${rows.status}`); process.exit(1); }
let good = 0;
for (const a of rows.data) {
  const res = await fetch(url(a.storage_path), { headers: svc });
  if (!res.ok) { problems.push(`${a.storage_path}: in the database, not in the bucket (${res.status})`); continue; }
  if (createHash('sha256').update(Buffer.from(await res.arrayBuffer())).digest('hex') !== a.sha256) { problems.push(`${a.storage_path}: SHA-256 differs from the record`); continue; }
  good++;
}
console.log(`database check: ${good}/${rows.data.length} evidence file(s) in the bucket and matching their fingerprint`);
if (problems.length) { console.log(`PROBLEMS:\n  ${problems.join('\n  ')}\nEVIDENCE RESTORE INCOMPLETE`); process.exit(1); }
console.log('EVIDENCE RESTORED');
