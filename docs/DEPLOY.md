# Going live (PRD §13 Phase 4)

Two systems, never mixed:

| | Staging (practice) | Production (real lots) |
|---|---|---|
| Supabase project | the existing development project (`zogkrhgzatplarimbmxk`) | a NEW project, created at go-live |
| Data | demo seed (5 farmers, 6 scopes, 15 demo logins) | no demo data: the production seed + what people enter |
| What the app shows | gold strip "PRACTICE SYSTEM" on every screen and on the public page | no strip |
| Env file (git-ignored) | `.env.local` | `.env.production` |
| App build | `npm run build` (`vite build --mode staging`) | `npm run build:production` |
| Demo scripts, test scripts, acceptance run | allowed | refuse to run (they ask the database: `app.environment()`) |

A project becomes production when `supabase/seeds/production/10_reference.sql` writes the marker row. From that moment
the demo seeds raise an error there, `create_demo_logins`, `remote_rls` and `remote_create_user` exit with REFUSED, and
the acceptance suite will not start against it. Nobody can write that marker through the API (tested).

## Decisions only Veda can take

The same decisions, with the same numbers, are tracked in `docs/FIX_LIST.md`.

| # | Decision | Recommendation | Why | Cost |
|---|---|---|---|---|
| G1 | Domestic sale of a lot that fails the DOMESTIC limit | Block it; decide before the first sale | The PRD gates only the export sale. Today a lot above 13 % moisture can still be sold "domestic" (with the failed verdict on the public page). Blocking it is a small database rule | — |
| G2 | Supabase plan for production | **Pro** | The Free plan has no backups at all, and pauses a project after a week without traffic | about USD 25 / month |
| G2 | Point-in-time recovery | Not yet | A paid add-on (about USD 100 / month and a larger database size). Daily backups + the weekly off-platform backup of `docs/RESTORE.md` lose at most one day; revisit when a client contract demands less | — |
| G3 | Region | **Mumbai (ap-south-1)** | Closest to the field; the region of a project cannot be changed later | none |
| G4 | Where the app is hosted | **Cloudflare** (config in `web/wrangler.jsonc`) | Static files are free and unmetered, with edge locations in India. Vercel's free plan is for non-commercial use only; Netlify's free plan stops every site when the monthly credits run out | free |
| G4 | Own domain for the app (e.g. `app.grainveda.in`) | Yes, before QR labels are printed | The QR code on a bag carries the address. A label printed with a `workers.dev` address works only as long as that address is kept | domain fee |
| G5 | Custom domain for the Supabase project | Yes, if the budget allows | See "Known outside risk" below | a paid add-on |

Known outside risk: India blocked `supabase.co` for a week in February–March 2026. If that happens again the app
cannot reach its database, whatever the host. Mitigation that keeps working: a custom domain for the Supabase project
(a paid add-on), set as `VITE_SUPABASE_URL`; the build's security policy follows that value automatically. Not set up
now; it is one build and one deploy when needed.

Also dated: Supabase is retiring the old `anon` / `service_role` keys (announced for late 2026). The app and scripts
already accept the new publishable / secret keys under the same variable names; the three Edge Functions read
`SB_PUBLISHABLE_KEY` / `SB_SECRET_KEY` if set (`supabase secrets set`). Nothing to do until Supabase gives a date for
this project.

## What the build guarantees

- `npm run build:production` stops with an error unless `.env.production` names the production project. Without that
  check a production build would silently use the staging values in `.env.local`.
- `dist/_headers` is written by the build: a Content-Security-Policy that allows scripts from the app itself only and
  network calls to the one Supabase project of that build, plus `nosniff`, `frame-ancestors 'none'`, HSTS, and cache
  rules (hashed files a year, the page and the service worker revalidated). Tested locally behind a server that sends
  the same file (`npx playwright test -c playwright.prod.config.ts`): a whole journey with a photo runs with zero
  policy violations.
- The service key is in no build: only variables starting `VITE_` or `NEXT_PUBLIC_` are read by the build.

Not verified from here (no Cloudflare account): that Cloudflare applies `_headers` to the single-page fallback
responses exactly as the local stand-in does. Step B3 of the run-sheet checks it with one command on the real address.

On Vercel the project's Root Directory is `web` and the config is `web/vercel.json`; a `vercel.json` at the repo root
is not read. Vercel does not read `dist/_headers`, so the same headers are repeated in that file; its `connect-src`
allows any Supabase project because the file cannot read the build's environment. The file may hold only properties of
Vercel's schema and no comment: any other property fails the deploy before the build starts (`tests/phase4.test.tsx`
"hosting config"). `web` installs from `web/package-lock.json`: no `package.json` above it may name it as a workspace.

## Production, step by step

Do staging first (`docs/RUNSHEET_phase4.md` parts A and B). Production is part C of the same run-sheet; this is the
explanation of each step.

1. **Create the project** (Dashboard): organisation on the Pro plan, region Mumbai, a generated database password kept
   in the password manager, not in a file.
2. **`.env.production`** in the repository root (git-ignored by `.env.*`), six lines: `SUPABASE_URL`,
   `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_DB_URL` (Connect → Session pooler),
   `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`. The last two repeat the first two: they are the only ones the app
   build reads.
3. **Database**: link the CLI to the production project, `supabase db push` (29 migrations), then
   `supabase/seeds/01_stage_definitions.sql` and `supabase/seeds/production/10_reference.sql`. Never seeds 02–05.
   Then link the CLI back to staging.
4. **Dashboard settings**: API → exposed schemas: add `app`. Authentication → Sign In / Providers: "Allow new users
   to sign up" OFF, anonymous sign-ins OFF, e-mail confirmation ON, phone provider set up exactly as on staging
   (operators sign in with phone + password until SMS is registered). Sessions: time-box 720 hours (30 days). Password
   minimum 8. Keep "Secure password change" OFF: operators have no e-mail to receive a re-authentication code.
   With sign-up off, nobody can make a login for themselves; the settings check then reports an "auto-confirm"
   setting as a note, not a failure.
5. **Functions and secrets**: `supabase functions deploy create-user`, `reset-password`, and
   `ledger-check --no-verify-jwt`; a new `LEDGER_CHECK_TOKEN` for production (`scripts/make_ledger_token.mjs` with
   `ENV_FILE=.env.production`), uploaded with `supabase secrets set --env-file .env.functions.production`.
6. **Checks, read-only**: `tests/remote_smoke.sql` (23 rows; "environment" must say `OK production`, "demo data" must
   say `OK production: no demo people or scopes`), `ENV_FILE=.env.production node tests/remote_auth_settings.mjs`
   (must end `AUTH SETTINGS PASSED`; on production an open setting is a failure, not a warning).
7. **First admin**: `ENV_FILE=.env.production node scripts/bootstrap_admin.mjs --email <Veda's address> --name "Veda"`.
   The temporary password is written to `.env.admin-login`, not shown. Sign in, choose an own password when the app
   asks, delete the file.
8. **App**: `cd web; npm run build:production; npx wrangler deploy --env production`. Add the custom domain in the
   Cloudflare dashboard. Check the headers on the real address.
9. **In the app, as admin**: State Manager(s) → Client Manager → the scope (chain, people) → farmers (form or Excel) →
   activate. Every person gets a temporary password in person and chooses an own one at first sign-in.
10. **Before the first real lot**: one off-platform backup and one restore drill (`docs/RESTORE.md`); the uptime
    monitor on `…/functions/v1/ledger-check?evidence=1` with the production token; Health page → "Check the ledger now".

## Go-live checklist

| Done | Item | Proof |
|---|---|---|
| ☐ | Release gate open on staging | `release-evidence/GATE.md`: every row PASS |
| ☐ | Decisions G1 to G5 taken | `docs/FIX_LIST.md` |
| ☐ | Secrets of the development phase rotated (database password, service key, access token) | `docs/RUNSHEET_2026-10-01_security_and_phase0.md` |
| ☐ | Production project: Pro, Mumbai | Dashboard |
| ☐ | 29 migrations, seed 01, production seed; no demo data | smoke check 23/23 |
| ☐ | Sign-up off, anonymous off | `remote_auth_settings.mjs`: PASSED |
| ☐ | Functions deployed, token set, monitor green | monitor's first check |
| ☐ | First admin signed in with an own password; `.env.admin-login` deleted | — |
| ☐ | App on its own domain, no practice strip, headers present | `curl -sI` |
| ☐ | Off-platform backup taken and restored once | `backups/<time>/RESTORE_DRILL.log`: PASSED |
| ☐ | Managers have read `docs/OPERATIONS.md`; operators have the one-page guide | — |
| ☐ | Every operator has signed in, chosen an own password and **opened the own stage once with a network**; screen lock on the phone | run-sheet C17 |
| ☐ | A day without network on a real phone | `docs/ACCEPTANCE_SIGNOFF.md` |

## After go-live

| When | Who | What |
|---|---|---|
| Daily | admin | Health page: ledger check green, no new problems from phones, nothing waiting more than 2 days |
| Weekly | admin | `node scripts/backup.mjs` with `ENV_FILE=.env.production`; move the folder to the encrypted drive |
| Quarterly | admin | Restore drill; log kept |
| On staff change | Client Manager | Users → Deactivate; Scope → People → Remove / assign |
| On a new app version | Antigravity | staging first: migrations, build, acceptance run twice; then production |
