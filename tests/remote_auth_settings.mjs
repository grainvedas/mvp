#!/usr/bin/env node
// READ-ONLY check of the Auth settings that decide who can get a login. Safe on any project.
//   node tests/remote_auth_settings.mjs                 (project from .env.local)
//   ENV_FILE=.env.production node tests/remote_auth_settings.mjs
// On the PRODUCTION project every line must be OK (exit 1 otherwise). On staging and the local stack an open setting
// is reported as a WARNING: login linking (migration 23) still stops a public sign-up from becoming a user.
import { supabaseConfig, environmentOf } from '../scripts/lib/env.mjs';

const cfg = supabaseConfig();
const env = await environmentOf(cfg);
const r = await fetch(`${cfg.url}/auth/v1/settings`, { headers: { apikey: cfg.anon } });
if (!r.ok) { console.error(`cannot read auth settings: ${r.status}`); process.exit(1); }
const s = await r.json();
const strict = env === 'production';
let bad = 0;
const line = (good, what, fix) => {
  if (good) { console.log(`ok    ${what}`); return; }
  if (strict) bad++;
  console.log(`${strict ? 'FAIL ' : 'WARN '} ${what}  -> ${fix}`);
};
console.log(`project: ${cfg.url}  (environment: ${env})`);
line(s.disable_signup === true, 'public sign-up is off (logins are made only by create-user, reset-password and bootstrap_admin)',
     'Dashboard → Authentication → Sign In / Providers → turn OFF "Allow new users to sign up"');
// Auto-confirmation lets a login that someone made for themselves work without proving the address or number. With
// public sign-up off nobody can make a login for themselves (create-user, reset-password and bootstrap_admin confirm
// the ones they make), so it has nothing to act on: it is reported, and counts only when sign-up is open.
const signupOff = s.disable_signup === true;
const autoconfirm = (on, what, fix) => {
  if (!on) { console.log(`ok    ${what} are not auto-confirmed`); return; }
  if (signupOff) { console.log(`note  ${what} are auto-confirmed: no effect while public sign-up is off. Keep sign-up off.`); return; }
  line(false, `${what} are not auto-confirmed`, fix);
};
autoconfirm(s.mailer_autoconfirm !== false, 'e-mail addresses',
     'Dashboard → Authentication → Sign In / Providers → Email → turn ON "Confirm email"');
autoconfirm(s.phone_autoconfirm !== false, 'phone numbers',
     'Dashboard → Authentication → Sign In / Providers → Phone → turn ON "Confirm phone" (operators sign in with phone + password; do not switch the phone provider itself off)');
line(s.external?.anonymous_users !== true, 'anonymous sign-ins are off',
     'Dashboard → Authentication → Sign In / Providers → turn OFF "Allow anonymous sign-ins"');
const social = Object.entries(s.external ?? {}).filter(([k, v]) => v === true && !['email', 'phone'].includes(k)).map(([k]) => k);
line(social.length === 0, 'no social sign-in provider is on', `turn off: ${social.join(', ')}`);
console.log(bad ? `\nAUTH SETTINGS: ${bad} to fix before go-live` : `\nAUTH SETTINGS ${strict ? 'PASSED' : 'CHECKED (warnings are allowed outside production)'}`);
process.exit(bad ? 1 : 0);
