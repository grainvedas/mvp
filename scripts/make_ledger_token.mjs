#!/usr/bin/env node
// Makes the ledger-check monitor token once per project and writes it to two git-ignored files. Never printed.
//   node scripts/make_ledger_token.mjs                               staging:    .env.functions            + .env.local
//   ENV_FILE=.env.production node scripts/make_ledger_token.mjs     production: .env.functions.production + .env.production
// The first file is what `supabase secrets set --env-file <file>` uploads (it holds nothing else); the second is where
// tests/remote_ledger_check.mjs and the uptime monitor's setup read it from. Staging and production get different tokens.
import { randomBytes } from 'node:crypto';
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT } from './lib/env.mjs';

const production = process.env.ENV_FILE === '.env.production';
const fnName = production ? '.env.functions.production' : '.env.functions';
const envName = production ? '.env.production' : '.env.local';
const fn = join(ROOT, fnName), envFile = join(ROOT, envName);
const has = (p) => existsSync(p) && /^LEDGER_CHECK_TOKEN=/m.test(readFileSync(p, 'utf8'));
let line;
if (has(fn)) line = readFileSync(fn, 'utf8').match(/^LEDGER_CHECK_TOKEN=.*$/m)[0];
else { line = `LEDGER_CHECK_TOKEN=${randomBytes(24).toString('hex')}`; writeFileSync(fn, line + '\n'); }
if (!has(envFile)) appendFileSync(envFile, `\n${line}\n`);
console.log(`LEDGER_CHECK_TOKEN is in ${fnName} and ${envName} (not shown). Next: supabase secrets set --env-file ${fnName}`);
