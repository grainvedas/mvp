#!/usr/bin/env node
// Makes the ledger-check monitor token once and writes it to .env.functions (for `supabase secrets set --env-file`)
// and .env.local (for tests/remote_ledger_check.mjs). Both files are git-ignored. The token is never printed.
import { randomBytes } from 'node:crypto';
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT } from './lib/env.mjs';

const fn = join(ROOT, '.env.functions'), local = join(ROOT, '.env.local');
const has = (p) => existsSync(p) && /^LEDGER_CHECK_TOKEN=/m.test(readFileSync(p, 'utf8'));
let line;
if (has(fn)) line = readFileSync(fn, 'utf8').match(/^LEDGER_CHECK_TOKEN=.*$/m)[0];
else { line = `LEDGER_CHECK_TOKEN=${randomBytes(24).toString('hex')}`; writeFileSync(fn, line + '\n'); }
if (!has(local)) appendFileSync(local, `\n${line}\n`);
console.log('LEDGER_CHECK_TOKEN is in .env.functions and .env.local (not shown). Next: supabase secrets set --env-file .env.functions');
