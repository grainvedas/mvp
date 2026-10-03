// Runs once before the acceptance suite: is this a system the suite may write practice lots to, and is the deployed
// build really the app of that database?
import { supabaseConfig, environmentOf } from '../../scripts/lib/env.mjs';

export default async function acceptanceSetup() {
  const target = process.env.ACCEPTANCE_URL!.replace(/\/+$/, '');
  const cfg = supabaseConfig();
  const dbHost = new URL(cfg.url).host;
  const env = await environmentOf(cfg);
  if (env === 'production') {
    throw new Error(`REFUSED: ${dbHost} is the PRODUCTION project. The acceptance run records practice lots: run it against staging.`);
  }
  const page = await fetch(`${target}/`);
  if (!page.ok) throw new Error(`${target} answered ${page.status}: is the build deployed?`);
  const scripts = [...(await page.text()).matchAll(/(?:src|href)="(\/assets\/[^"]+\.js)"/g)].map((m) => m[1]);
  let found = false;
  for (const s of scripts) if ((await (await fetch(`${target}${s}`)).text()).includes(dbHost)) { found = true; break; }
  if (!found) {
    throw new Error(`The build at ${target} does not talk to ${dbHost} (the database in ${process.env.ENV_FILE}). ` +
      'Point ENV_FILE at the env file of the project this build was made for, or deploy the build for this project.');
  }
  console.log(`\nACCEPTANCE RUN\n  app       ${target}\n  database  ${dbHost} (${env})\n  logins    ${process.env.GV_LOGINS_FILE}\n  started   ${new Date().toISOString()}\n`);
}
