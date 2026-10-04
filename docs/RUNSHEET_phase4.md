# Run-sheet for Antigravity — Phase 4 (deploy, acceptance, restore drill, go-live)

Prerequisite: the run-sheets of Phases 0 to 3 done on the staging project (step A2 shows whether they were), and the
security run-sheet `docs/RUNSHEET_2026-10-01_security_and_phase0.md` read again: the secrets of the development phase
are still in use and are rotated in step C1, before production.

**Changed on 4 October 2026: migrations 28 and 29 added, and the web app changed.**
28 `20261004000100_public_page_data`: the public page's function no longer sends the buyer's name.
29 `20261004000200_capture_time_verdict_preview`: a record saved without network keeps the time it was captured; the
lab form shows pass / fail before saving. The app carries the fixes of FIX_LIST faults 22 to 31.

**Changed again the same day (decision G8 = B): the app has the prototype's look and frame** (`docs/FIX_LIST.md`,
"The prototype's look and frame", B1 to B7): dark side menu and top bar on a laptop, first screens with number cards,
stage forms in sections. No new migration. **Seed 01 changed** (each field now names its form section): run step A5
again even if part A was done before. Until then the app works, with each form as one block without headings.

**Found on staging the same evening (FIX_LIST open item 17): step A6 was skipped.** The migrations were pushed, the
functions were not: `create-user` was still the build of 1 October, `reset-password` was not deployed, `ledger-check`
had no token. Every **New user** ended in "Login created but not linked; both removed" and **Reset password** failed.
**The functions go with the database: after any `supabase db push`, do A6 and its two checks.** If `ledger-check` is
reported as "secrets are not set": `docs/RUNSHEET_phase3.md` steps 7 and 8, then A6 again.

**Changed on 5 October 2026: migration 30 added.** 30 `20261005000100_clients_read_by_row`: an admin or a State
Manager can add a client from the screen (before: "Not allowed for your role or stage", FIX_LIST open item 18,
fault 33). On a project that already has migrations 22 to 29: A1, then A2 lists exactly this one, A3, then **A6 with
its two checks** (the functions go with every push), A8 (24 rows now). The app of the same day adds a client also on
a database without migration 30, so a push to GitHub alone makes the Clients page work.

- Part A not yet done on staging: the steps below already include both migrations.
- Part A already done: repeat A1, A2 (it then lists exactly the two new migrations), A3, **A5** and A8.
- The app and the database can go in either order. The new app on a database without migration 29 still saves
  (it sends the capture time only if the server knows the column) and says "the lab result is worked out when the
  record is saved"; an older app on the new database is unaffected. Push the database first all the same: until
  migration 28 is on staging, the buyer's name is readable there.
- After the push, the app: commit, push to GitHub `main`, wait for Vercel, then B-steps as written, and **B11**
  (new): the fixes and the new look of 4 October looked at on the deployed app, on a laptop and on a phone.

Three parts. A and B are on **staging** (the existing project) and can be done today. C is go-live day.
Stop at the first step that does not match "Expect" and paste the raw output back to Claude.
Never paste keys, tokens or passwords into chat. PowerShell, from the repository root unless a step says `cd web`.

**Never run against a hosted project:** `tests/00_local_auth_shim.sql`, `tests/run_local.*` (they rebuild a database),
`tests/remote_create_user.mjs`, `tests/remote_ledger_check.mjs --tamper-local`, `scripts/collect_release_evidence.sh`,
and anything with `ENV_FILE=.env.stack`. Seeds 02–05 never go to production (they refuse; do not test it).

## Part A — staging database (about 30 minutes)

| # | Command | Expect |
|---|---|---|
| A1 | `tests/run_local.ps1` | `ALL TESTS PASSED`. Files 01–21, the T1 self-test, the production build, concurrency |
| A2 | `supabase db push --linked --dry-run` | Would push exactly eight: `20261002000100_integrity_guards`, `…000200_phase4_ops`, `…000300_atomic_saves`, `…000400_access_rules`, `…000500_ledger_event_evidence`, `…000600_evidence_ledger`, `20261004000100_public_page_data`, `20261004000200_capture_time_verdict_preview`, and since 5 October a ninth, `20261005000100_clients_read_by_row`. **If the list also has `20261001…` files, the run-sheets of Phases 1 to 3 were not finished on this project: do them first, in order, then come back here.** Any other name: stop |
| A3 | `supabase db push --linked --yes` | `Finished supabase db push.` A NOTICE `catch-up not run in this transaction` is expected: step A4 |
| A4 | SQL Editor: `select app.record_missing_evidence_blocks();` | One number: the evidence files registered before today that now get their ledger block (0 if none) |
| A5 | `supabase db query --linked -f supabase/seeds/01_stage_definitions.sql` | No errors (Commercial "market" is gated on the lab verdict; Shipment takes a document; every field names its form section). Check: `supabase db query --linked "select count(*) from public.stage_definitions d, jsonb_array_elements(d.form_schema) f where f ? 'section'"` says **64** |
| A6 | `supabase functions deploy create-user` · `supabase functions deploy reset-password` · `supabase functions deploy ledger-check --no-verify-jwt` · then `node scripts/check_functions.mjs` · then `node scripts/check_logins.mjs` | `Deployed Function` three times. Then three lines `ok` and `FUNCTIONS DEPLOYED AND CURRENT` (a line `FAIL … not deployed` or `… an older build`: deploy that one again; `… secrets are not set`: Phase 3 run-sheet steps 7 and 8). Then `NO LOGIN WITHOUT A PERSON` (if it lists any: the same command with `--remove`; a listed "person without a login": FIX_LIST K22) |
| A7 | Dashboard → Authentication → Sign In / Providers: **Allow new users to sign up OFF**, anonymous sign-ins OFF. **Leave the Phone provider as it is** (operators sign in with phone + password through it). Sessions: **time-box user sessions 720 hours**. Then `node tests/remote_auth_settings.mjs` | First line `ok    public sign-up is off`; no line starts with `WARN`; a line starting `note` (addresses auto-confirmed, no effect while sign-up is off) is fine. Last line `AUTH SETTINGS CHECKED` |
| A8 | `supabase db query --linked -f tests/remote_smoke.sql` | 24 rows, all `OK`. `environment` says staging; `phase 4 objects`, `phase 4 triggers`, `ledger read by stage`, `direct writes closed`, `evidence in the ledger`, `public page data`, `capture time, verdict preview`, `a new client can be read back` are the new rows |
| A9 | Create the folder `release-evidence`, then `node tests/remote_rls.mjs --t1 \| Tee-Object release-evidence\rls.log` | First line `project: <ref>.supabase.co (staging)`; last lines `… passed, 0 failed` and `REMOTE RLS PASSED` |
| A10 | `supabase db query --linked -f tests/remote_ledger_audit.sql \| Tee-Object release-evidence\audit.log` | `NO FINDINGS (… blocks, … records, … seals, … evidence files checked)` |
| A11 | `node tests/remote_ledger_check.mjs` | `LEDGER CHECK TEST PASSED` |
| A12 | Replace `.github/workflows/database-tests.yml` with `docs/ci/database-tests.yml`, commit, push | Both CI jobs green (the second now takes about 25 minutes). Download its artifact **release-evidence** and copy `sql.log`, `unit.json`, `e2e.json` and `prod.log` from it into `release-evidence\` (not its `rehearsal` folder: that is the acceptance run against CI's own database, not staging) |

## Part B — staging app and acceptance (about 2 hours, most of it people)

| # | Who | Do | Expect |
|---|---|---|---|
| B1 | Antigravity | `cd web; npm ci; npm run build` | `dist\` with `_headers` in it; the build names the staging project |
| B2 | Antigravity | `npx wrangler login` (Veda's Cloudflare account, in the browser), then `npx wrangler deploy` | An address like `https://grainveda-staging.<account>.workers.dev`: "the staging address" below |
| B3 | Antigravity | `curl.exe -sI https://<staging address>/work/x/y` | `HTTP/… 200`, `content-security-policy:` containing `connect-src 'self' https://<ref>.supabase.co`, `x-frame-options: DENY`, `strict-transport-security:`. **If the policy line is missing on this deep address, stop**: Cloudflare is not applying `_headers` to the app's fallback pages (checked here only against a stand-in) |
| B4 | Veda, on a phone | Open the staging address. Sign in as the Client Manager → **Users & Roles** → create a test person → sign out → sign in as that person with the temporary password | Gold strip **PRACTICE SYSTEM** on every screen. **No yellow warning above the list of people** (a warning "Creating people and resetting passwords will not work on this system yet" means A6 is not done). The temporary password is shown once; the new person is asked to choose an own password. (This is also the check that logins can be made with public sign-up off.) Then **Deactivate** the test person |
| B5 | A person who did not build it | `docs/ACCEPTANCE.md` part A: the automated run, twice | `5 passed`, twice; `release-evidence\acceptance-1.json` and `acceptance-2.json` |
| B6 | Veda, on a phone | `docs/ACCEPTANCE.md` part B: T1–T4 by hand; fill in `docs/ACCEPTANCE_SIGNOFF.md` | Four lines `pass`, name, date. Anything that did not match: `docs/FIX_LIST.md` |
| B7 | Veda or an operator, on a real phone | **A day without network.** Sign in as `…05`, open Procurement · Gorakhpur once. Airplane mode ON. Leave it **more than one hour** (overnight is better). Open the app, record two lots, **Save on this phone**. Airplane mode OFF | The app opens straight into the form, not the sign-in screen. After the network is back both lots show under **Saved on phone → Sent** with consecutive codes, none "needs attention". Write the result in the sign-off |
| B8 | Antigravity | `npx --yes lighthouse@12 "https://<staging address>/verify/<a sealed code from B5>" --only-categories=accessibility --output=json --output-path=release-evidence/lighthouse.json --chrome-flags="--headless=new"` | Accessibility 90 or more (100 on the local build) |
| B9 | Antigravity | Restore drill from the staging project. Needs: `SUPABASE_DB_URL` in `.env.local` (Dashboard → Connect → Session pooler, port 5432); PostgreSQL **17** tools (`& "$env:PGBIN\pg_dump.exe" --version` says 17; if it says 16, unzip the PostgreSQL 17 Windows binaries and point `PGBIN` there); a throwaway local cluster made with those tools (header of `tests/run_local.ps1`), `PGHOST`/`PGPORT`/`PGUSER` pointing at it. Then `node scripts/restore_drill.mjs \| Tee-Object release-evidence\restore-drill.log` | A line `source: … supabase …`, every check `ok`, last line `RESTORE DRILL PASSED`. Copy the last lines into the drill log of `docs/RESTORE.md`. Move the `backups\<time>` folder to an encrypted drive |
| B10 | Antigravity | `node scripts/release_gate.mjs` | Ten rows. **Every row PASS and `Gate: OPEN`**. A row that says REHEARSAL means its file still comes from the local stack; NOT RUN names the missing file |

### B11 — the fixes and the new look of 4 October, looked at on the deployed app (30 minutes)

By Veda or anyone who did not build them, any time after B4. Steps 1 to 9 on a phone, steps 10 to 15 on a laptop
(browser window 1200 px wide or more). All of it was tested on the local stack only (`docs/FIX_LIST.md` lines 22 to 31
and B1 to B7). Anything that does not match goes into `docs/FIX_LIST.md` as a new open item.

| # | Sign in as | Do | Expect |
|---|---|---|---|
| 1 | nobody | Open the app | A white sign-in card on a dark green page, with a language box; **हिन्दी** turns the screen to Hindi |
| 2 | any operator | Look at the top of the screen; open two or three screens | Gold strip on one line: `PRACTICE SYSTEM · not real lots`. Your name beside the language box. The menu is one row that slides sideways. No screen has to be pushed sideways to be read |
| 3 | QC technician | Quality Control → a waiting lot → verify → type the readings with Moisture **12.6** | Before saving: `Lab result if saved now: domestic passed · export not met` and `Not met: Moisture (export)`. Save: the record says Pass and Fail, the same |
| 4 | during T4 of B6 (steps 18, 19) | Packing: the review step; Commercial: the arrival check of the packed lot, then the review step | `Batch code` shows the code as typed, at both stages; `Buyer` and `Market` are words. Nowhere the word `NaN`, no text in `{ }` or `[ ]` |
| 5 | during T2 of B6 (steps 6, 8) | Sorting: the review step; Grading: the review step | `Reject reasons` reads `discoloured 6 kg`; `Grades` reads `A 100 kg · B 50 kg · C 15 kg` |
| 6 | admin | **Crop Registry** → **Edit** on a crop → type `12.5` into a limit box, then leave the page without saving | The box shows `12.5` (before: 125) |
| 7 | after B7 (a day without network) | Open one of the two lots that were sent | `Recorded` shows the time it was saved on the phone, then `kept on the phone, sent …` with the later time |
| 8 | Client View | **Season Scopes** → a scope → People. Then **Dashboard** → a scope → in **Season flow**, the first stage | People: names only, no `Remove`, no `Assign existing…`, no `+ new person`. The stage opens on **Records at this stage** |
| 9 | Client Manager | **Dashboard** → a scope → **Full dashboard and exports** | Each stage box says `… records · … kg available`; the last column of the activity table is `Manager actions and stage assignments` |
| 10 | Client Manager, **laptop** | Sign in; look at the frame | Dark green top bar and a dark menu on the left with the headings **Overview, Registry, Operations, System, Support**. Top bar: where you are, a **Scope** box, your name over your role, your initials in a circle. Nothing has to be pushed sideways |
| 11 | the same | First screen with **⭐ Overall** in the Scope box | Four number cards (active scopes, total volume, needs action, QR issued) and one card per scope |
| 12 | the same | Choose a scope in the **Scope** box | Number cards (procured, action queue, yield, completed), **Your action queue**, **Season flow — stage by stage**, **Team & pipeline overview**. The menu's **Operations** now lists that scope's stages. Reload the page: the same scope is still chosen |
| 13 | the same | Compare **Procured** with the first stage's verified kg in **Full dashboard and exports** | The same number |
| 14 | Procurement operator, **laptop** | **Operations → Procurement** | The form is in two columns under headings (Farmer, Weighing, Moisture readings, Evidence); the farmer picker, the three moisture boxes and the photo take the whole width. A status chip reads **Pending verification**; after the next stage verified it: **Approved** |
| 15 | the same person, **phone** | The same form | One column, the same headings, the three header lines of step 2 |

## Part C — production (go-live day, about 2 hours). Only after B10 says OPEN

Decisions G1 to G5 of `docs/FIX_LIST.md` are taken first. Explanations of each step: `docs/DEPLOY.md`.

| # | Do | Expect |
|---|---|---|
| C1 | Security run-sheet: rotate the database password, the service key and the access token of the development phase; update `.env.local`; repeat A8 | 24 rows `OK` with the new keys |
| C2 | Dashboard: new project, **Pro**, **Mumbai (ap-south-1)**; database password generated and kept in the password manager. Then Database → Extensions → enable **pg_cron**. Project Settings → API → exposed schemas: add **app** | Project ref noted |
| C3 | `.env.production` in the repository root, six lines: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_DB_URL`, `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` | `git status` does not show the file |
| C4 | `supabase link --project-ref <production ref>` then `supabase db push --linked --dry-run` | **30** migrations listed, first `20260927000100_extensions_enums`, last `20261005000100_clients_read_by_row` |
| C5 | `supabase db push --linked --yes` · `supabase db query --linked -f supabase/seeds/01_stage_definitions.sql` · `supabase db query --linked -f supabase/seeds/production/10_reference.sql` | `production reference seed applied`, environment `production`. **Never seeds 02–05** |
| C6 | `$env:ENV_FILE='.env.production'; node scripts/make_ledger_token.mjs` · `supabase secrets set --env-file .env.functions.production` · the three `supabase functions deploy …` of A6 · `$env:ENV_FILE='.env.production'; node scripts/check_functions.mjs` | Token "not shown"; `Finished supabase secrets set.`; three functions deployed; `FUNCTIONS DEPLOYED AND CURRENT` |
| C7 | Dashboard → Authentication: as A7, plus password minimum 8; keep "Secure password change" OFF | — |
| C8 | `supabase db query --linked -f tests/remote_smoke.sql` · `node tests/remote_auth_settings.mjs` · `node tests/remote_ledger_check.mjs` (`ENV_FILE` still `.env.production`) | 23 rows `OK`; `environment` = `OK production`, `demo data` = `OK production: no demo people or scopes`; `AUTH SETTINGS PASSED`; `LEDGER CHECK TEST PASSED` |
| C9 | **`supabase link --project-ref <staging ref>`** · `Remove-Item Env:ENV_FILE` | From here every `--linked` command is staging again. Check: `supabase projects list` marks the staging project |
| C10 | `$env:ENV_FILE='.env.production'; node scripts/bootstrap_admin.mjs --email <Veda's address> --name "Veda"; Remove-Item Env:ENV_FILE` | Temporary password written to `.env.admin-login`, not shown |
| C11 | `cd web; npm run build:production; npx wrangler deploy --env production`. Cloudflare dashboard: add the own domain to the Worker `grainveda`. `curl.exe -sI https://<own domain>/work/x/y` | The build stops if `.env.production` is missing. Headers as in B3, naming the production project |
| C12 | Veda: open the own domain, sign in with the temporary password, choose an own password, delete `.env.admin-login` | No practice strip. **My account** shows the build |
| C13 | Veda, in the app: State Manager → Client Manager → scope (chain, people) → farmers → **Activate** | `docs/OPERATIONS.md` "Start of a season" |
| C14 | `$env:ENV_FILE='.env.production'; node scripts/restore_drill.mjs; Remove-Item Env:ENV_FILE` | `RESTORE DRILL PASSED` on the production project before its first real lot; the folder goes to the encrypted drive |
| C15 | Uptime monitor (UptimeRobot or Better Stack): `GET https://<production ref>.supabase.co/functions/v1/ledger-check?evidence=1`, header `x-check-token: <token from .env.functions.production>`, every 6 hours, alert to Veda's phone | First check green |
| C16 | Health page → **Check the ledger now** | intact |
| C17 | Each operator, with a manager, where there is a network: sign in, choose an own password, **open the own stage once**, switch on the phone's screen lock. Hand out `docs/OPERATOR_GUIDE.md` (one sheet, both sides) | The stage then opens without a network, all day |

Go-live checklist with the proof for each line: `docs/DEPLOY.md`.

## What Phase 4 added

- **Migrations 22 to 27.** 22 `integrity_guards`: eleven ways to rewrite quantities, status, dates, codes or verdicts
  by a direct API call are closed; a wrong record is withdrawn with a reason and replaced. 23 `phase4_ops`: practice /
  production marker, problems reported by phones, password reset rules, ledger check on demand. 24 `atomic_saves`:
  recording and sealing in one transaction; grade lots made by the save. 25 `access_rules`: the ledger follows the
  thumb rule; stage assignments removable; people and assignments in the ledger. 26 and 27: evidence fingerprints in
  the ledger. 28 `public_page_data` (added 4 October): the function behind the public page sent every record's
  worked-out values, which for a sale include the buyer's name; it now sends a fixed list of keys. 29
  `capture_time_verdict_preview` (added 4 October): `footprints.captured_at` (the time a record was saved on the phone,
  accepted within 31 days back and 5 minutes ahead, in the ledger block, shown on the record, the lot journey and the
  public page); `app.preview_verdict` (the lab verdict the save would derive, for the review step).
- **Edge Function** `reset-password` (new); `create-user` and `ledger-check` accept Supabase's new key names.
- **Web.** Works without a network for as long as the day lasts (before: one hour), never sends a save without the
  operator's own token, never stores a save twice, keeps an unsent photo, copes with a link that is connected but dead,
  erases its offline copy from a lost or deactivated phone. Own password at first sign-in; reset by the manager; **My
  account**; **Health** page; withdraw and replace; evidence added later; activity per day; practice strip; security
  headers written by the build; sessions of 12 hours for managers and 30 days for operators; the record page, status
  words and the app's own messages in Hindi.
- **Acceptance and release gate.** T1 to T5 through the screens against a deployed address (`docs/ACCEPTANCE.md`);
  `scripts/release_gate.mjs` reads result files and says PASS, REHEARSAL, PENDING, NOT RUN or FAIL per PRD criterion.
- **Backup and restore.** `scripts/backup.mjs`, `restore_drill.mjs`, `restore_evidence.mjs`; `docs/RESTORE.md`.
- **Handover.** `docs/DEPLOY.md`, `OPERATIONS.md`, `OPERATOR_GUIDE.md` (Hindi and English), `FIX_LIST.md`.

## What only people can close (PRD §12, §13)

| Task | Owner | Where it is recorded |
|---|---|---|
| Acceptance suite run twice by someone who did not build it | Tarun or QA | B5, sign-off |
| Veda's own run of T1–T4 on a phone | Veda | B6, sign-off |
| A day without network on a real phone | Veda or an operator | B7, sign-off |
| Hindi read by two field operators | Veda arranges | `docs/FIX_LIST.md` K9 |
| Device lab: three low-end Android phones | Tarun or QA | `docs/FIX_LIST.md` K16 |
| Penetration test | external | `docs/FIX_LIST.md` K16 |
| Decisions G1 to G7 | Veda | `docs/FIX_LIST.md` |
