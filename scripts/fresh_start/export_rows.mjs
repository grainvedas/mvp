#!/usr/bin/env node
// A COPY OF EVERY ROW, taken before the practice system is emptied (scripts/staging_fresh_start.ps1). Read-only.
// It is a keepsake, not a backup: plain JSON, one file per table, so that "what was in there?" can still be answered.
// It cannot be loaded back as it is (scripts/backup.mjs makes the copy that can; that one needs pg_dump).
//
//   node scripts/fresh_start/export_rows.mjs                  the project in .env.local  → backups/fresh-start-<time>/
//   ENV_FILE=.env.stack node scripts/fresh_start/export_rows.mjs
//
// Not copied: the logins themselves (Supabase Auth; a login is useless without its person) and the stored files.
// THE FOLDER HOLDS NAMES, PHONE NUMBERS AND E-MAIL ADDRESSES. backups/ is git-ignored; keep it off shared drives.
// Nothing of the rows is printed: only table names and counts.
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT, supabaseConfig, client } from '../lib/env.mjs';

const KNOWN = ['app_meta', 'app_users', 'assignments', 'attachments', 'audit_log', 'client_errors', 'clients', 'crops',
  'daily_code_passes', 'daily_codes', 'employee_docs', 'employee_exits', 'employee_files', 'employee_goals',
  'employee_notes', 'employee_org', 'farmer_id_counters', 'farmers', 'flags', 'footprint_counters', 'footprints', 'ledger',
  'ledger_checks', 'onboarding_tasks', 'onboarding_templates', 'qc_verdicts', 'qr_seals', 'scopes', 'slot_assignments',
  'stage_definitions', 'states', 'template_tasks', 'withdrawals'];
const PAGE = 1000;

const cfg = supabaseConfig({ needService: true });
const svc = client(cfg, { key: cfg.service });

// The tables the API knows of, so that one added by a later migration is copied too. If the list cannot be read
// (some projects close it), the tables named above are copied.
const names = new Set(KNOWN);
const spec = await svc.raw('GET', '/rest/v1/');
if (spec.ok && spec.data?.definitions) for (const n of Object.keys(spec.data.definitions)) names.add(n);

const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..*$/, 'Z');
const dir = join(ROOT, 'backups', `fresh-start-${stamp}`);
mkdirSync(dir, { recursive: true });

console.log(`project: ${new URL(cfg.url).host}`);
const counts = {};
let failed = 0, total = 0;
for (const table of [...names].sort()) {
  const rows = [];
  let bad = null;
  for (let offset = 0; ; offset += PAGE) {
    // a stable order where there is an id; tables without one are small
    let r = await svc.get(table, `select=*&order=id&limit=${PAGE}&offset=${offset}`);
    if (!r.ok && r.status === 400) r = await svc.get(table, `select=*&limit=${PAGE}&offset=${offset}`);
    if (!r.ok || !Array.isArray(r.data)) { bad = r.status; break; }
    rows.push(...r.data);
    if (r.data.length < PAGE) break;
  }
  if (bad !== null) {
    if (KNOWN.includes(table)) { failed++; console.log(`FAIL  ${table}: could not be read (HTTP ${bad})`); }
    continue;                                    // something the list names that is not a readable table
  }
  writeFileSync(join(dir, `${table}.json`), JSON.stringify(rows, null, 1));
  counts[table] = rows.length; total += rows.length;
  console.log(`${String(rows.length).padStart(6)}  ${table}`);
}
writeFileSync(join(dir, 'MANIFEST.json'), JSON.stringify({ project: new URL(cfg.url).host, taken_at: new Date().toISOString(),
  what: 'rows of every table before the fresh start; a keepsake, not a restorable backup', counts }, null, 1));
if (failed) { console.log(`\n${failed} table(s) could not be read. NOT COMPLETE.`); process.exit(1); }
console.log(`\nfolder: ${dir}`);
console.log(`ROWS COPIED: ${total} rows of ${Object.keys(counts).length} tables`);
