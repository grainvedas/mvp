#!/usr/bin/env node
// Are the three server functions deployed on this project, and are they the build this repository holds?
//   node scripts/check_functions.mjs                       (the project of .env.local: staging)
//   ENV_FILE=.env.production node scripts/check_functions.mjs
// Reads only: it sends GET to each function (no login, no key beyond the public one) and reads the build from the
// header x-grainveda-function. Run it after every `supabase functions deploy` and after every `supabase db push`:
// the functions, the database and the app are deployed apart, and a function left behind fails in ways that name no
// cause (4 Oct 2026: "login created but not linked; both removed" on every new user; docs/FIX_LIST.md fault 32).
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { supabaseConfig } from './lib/env.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const cfg = supabaseConfig();
const NAMES = ['create-user', 'reset-password', 'ledger-check'];
const versionIn = (name) => /export const VERSION = '([^']+)'/.exec(readFileSync(join(root, 'supabase', 'functions', name, 'handler.ts'), 'utf8'))?.[1] ?? null;
const here = Object.fromEntries(NAMES.map((n) => [n, versionIn(n)]));
if (new Set(Object.values(here)).size !== 1 || !here['create-user']) { console.error('FAIL  the three handler.ts files do not carry one VERSION:', JSON.stringify(here)); process.exit(1); }
const needed = here['create-user'];

console.log(`project: ${new URL(cfg.url).host}   build in this repository: ${needed}`);
let bad = 0;
for (const name of NAMES) {
  let line;
  try {
    const r = await fetch(`${cfg.url}/functions/v1/${name}`, { headers: { apikey: cfg.anon, authorization: `Bearer ${cfg.anon}` }, signal: AbortSignal.timeout(15000) });
    const build = r.headers.get('x-grainveda-function');
    const text = (await r.text().catch(() => '')).slice(0, 200);
    if (r.status === 404) line = `FAIL  ${name}: not deployed`;
    else if (!build) line = `FAIL  ${name}: deployed, but an older build (it does not say which; before 2026-10-04)`;
    else if (build !== needed) line = `FAIL  ${name}: deployed build ${build}, this repository holds ${needed}`;
    else if (/not configured/.test(text)) line = `FAIL  ${name}: build ${build}, but its secrets are not set (${text.replace(/[{}"]/g, '').slice(0, 120)})`;
    else line = `ok    ${name}: build ${build}`;
  } catch (e) { line = `FAIL  ${name}: no answer (${e?.message ?? e})`; }
  if (line.startsWith('FAIL')) bad++;
  console.log(line);
}
if (bad) {
  console.log(`\n${bad} of ${NAMES.length} NOT READY. Deploy: supabase functions deploy create-user · supabase functions deploy reset-password · `
    + 'supabase functions deploy ledger-check --no-verify-jwt   (secrets of ledger-check: docs/RUNSHEET_phase3.md steps 7 and 8)');
  process.exit(1);
}
console.log('\nFUNCTIONS DEPLOYED AND CURRENT');
