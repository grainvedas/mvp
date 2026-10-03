# Fix list (PRD §13 Phase 4: "fix list")

One list for everything that is wrong, missing or undecided, from the first staging run to the end of the first season.
A problem that is not on this list does not exist for planning purposes; a fix that has no test is not closed.

## How an item moves

| Class | It means | What happens |
|---|---|---|
| **Blocker** | wrong data can be stored, data can reach the wrong person, or a stage cannot work at all | sealing stops in the affected scope; fixed and tested before the next lot |
| **Before next lot** | the step works only with a manager's workaround | fixed before the next lot reaches that stage |
| **This week** | annoying, a workaround exists, nothing wrong is stored | fixed within 7 days |
| **Later** | a wish, or a limit that was accepted | reviewed on the first Monday of each month |

1. Anyone writes the item under "Open items" (step number of `docs/ACCEPTANCE.md` or the screen, what happened, what
   was expected, a screenshot or the line from **Health → Problems reported by phones**).
2. Veda sets the class and the owner the same day.
3. The fix is a migration and/or app change **with a test that failed before the fix**; staging first, acceptance run
   twice, then production (`docs/DEPLOY.md` "After go-live").
4. Closed by someone other than the person who fixed it, with the test named in the last column.

## Decisions only Veda can take

Numbered G1 to G7 (go-live), so they are not mistaken for the PRD's own decisions D1 to D13.

| # | Decision | Needed by | Recommendation | Detail |
|---|---|---|---|---|
| G1 | May a lot that fails the **domestic** limit be sold on the domestic market? | first sale | Block it (a small database rule and one test) | The PRD gates only the export sale. Today such a lot can be sold "domestic"; the failed verdict is shown on the public page |
| G2 | Supabase plan for production | creating the project | Pro | The Free plan has no backups and pauses an idle project. Point-in-time recovery: not yet (`docs/DEPLOY.md`, second G2 row) |
| G3 | Region | creating the project | Mumbai (ap-south-1) | Cannot be changed afterwards |
| G4 | Host and address of the app | before QR labels are printed | Cloudflare; own domain (e.g. `app.grainveda.in`) | A label printed with a temporary address works only as long as that address is kept |
| G5 | Custom domain for the Supabase project | before the season, if the budget allows | Yes | India blocked `supabase.co` for a week in Feb–Mar 2026; with a custom domain the app keeps reaching its database. A paid add-on |
| G6 | Who runs the acceptance suite, and who are the two operators for the Hindi review | staging run | Tarun or QA; two field operators | PRD §12: not the developer who built it |
| G7 | Printed label text: English only, or English and Hindi | first label print | Decide with the first client | The pack label says "Scan to see who grew it and how it was tested" in English; the page behind the QR is in both languages |

## Open items

| # | Date | Reported by | Where | What happened / what was expected | Class | Owner | Status | Closed by (test) |
|---|---|---|---|---|---|---|---|---|
| 1 | 2026-10-03 | Claude | `web/vite.config.ts`, `web/src/lib/supabase.ts` | Since commits 5d05103 and b1f9b6f a build with no project configured no longer stops. `npm run build:production` without `.env.production` builds against the project written in the source (`zogkrhgzatplarimbmxk`, the one `.env.local` names: staging), and the app can no longer say "not connected to a database". Expected: the build stops, as `docs/DEPLOY.md` "What the build guarantees" still says. The Vercel deploy does not need it: it builds `--mode staging` | | | Open | |
| 2 | 2026-10-03 | Claude | `vercel.json` at the repo root, `scripts/build.mjs` | Not read by Vercel (Root Directory is `web`). Its build command, run by hand from the root, adds `"grainveda-mvp": "file:.."` to `web/package.json` and its lockfile (seen in a fresh clone). Expected: one Vercel config, `web/vercel.json` | | | Open | |
| 3 | 2026-10-03 | Claude | `.github/workflows/database-tests.yml` | CI has not passed since 5d05103. Its last step looks for `NO ORPHAN BLOCKS`; the ledger audit now prints `NO FINDINGS`. `docs/ci/database-tests.yml` was updated, the workflow that runs was not | | | Open | |
| 4 | 2026-10-03 | Claude | staging project, https://mvp-beta-one.vercel.app | The deployed app is the Phase 4 build; its database is at Phase 3 and has no logins. Supabase Auth holds 0 logins (nobody can sign in), migrations 22 to 27 are not applied, `reset-password` is not deployed. Expected: part A of `docs/RUNSHEET_phase4.md`, then `node scripts/create_demo_logins.mjs` | | | Open | |

## Known at hand-over: limits that were accepted, and what to do about each

| # | Limit | What it means in the field | Until it is fixed | Class |
|---|---|---|---|---|
| K1 | Nothing has run on the hosted project or on a real phone yet | Every measurement in this repository is from the local stack and a desktop Chromium with a phone profile. The release gate says REHEARSAL for those rows | `docs/RUNSHEET_phase4.md` parts A and B | Blocker for go-live |
| K2 | Operators sign in with phone + password, not a one-time code by SMS | A password can be shared or forgotten | Managers reset passwords (**Users → Reset password**); SMS needs DLT registration | Later |
| K3 | A lost phone keeps its offline copy until it next reaches the server | For a Procurement operator that copy is the client's farmer list with phone numbers. Deactivating the person stops the phone getting anything more and erases the copy at the next contact; it cannot reach a phone that stays offline | Screen lock on every operator phone; Deactivate at once | Later |
| K4 | After **Reset password**, a phone that is still signed in keeps working for up to one hour | The token lasts one hour and cannot be renewed after a reset | To cut a phone off at once: **Deactivate** | Later |
| K5 | A stage must be opened once, with a network, on a phone before it works there without one | A new operator, or a new phone, that goes to the field without doing this sees "No connection" | In the operator guide; managers check it on the first day | This week (training) |
| K6 | Verifying an arrival, correcting a record and sealing need a connection | On a link that is connected but dead these wait for the browser to give up | Do them where there is a signal | Later |
| K7 | After a long spell on a dead link, waiting saves start going out up to about a minute after the link is back | Measured: 48 s. The sign-in library pauses for a minute after a failed renewal | None needed; **Send now** does not shorten it | Later |
| K8 | The database's refusals are in English on Hindi screens | A rule message such as "milling: input (194) must equal rice + bran + loss (184)" is shown as the database wrote it. Everything else on operator screens is translated | Managers explain; the numbers are readable | Later |
| K9 | The Hindi has not been read by field operators | Words may be bookish or not what people say | Review with two operators (G6); corrections go into `web/src/lib/i18n.hi.ts` and `docs/OPERATOR_GUIDE.md` | Before the season |
| K10 | Manager and admin screens are English only | PRD §9 asks for Hindi on operator screens | — | Later |
| K11 | Closing a scope has no screen and is not written to the ledger | The admin closes it with one SQL statement (`docs/OPERATIONS.md` "End of the season"); a closed scope cannot seal and cannot be reopened | Check the dashboard before closing | Before end of season |
| K12 | An operator can read the stage totals of the own scope through the API | `app.pipeline_summary` returns records / kg per stage (no codes, no names, no prices) to anyone in the scope; the screens show it to managers only | Decide whether to close it to operators | Later |
| K13 | First load of the public page is about 169 KB of a 200 KB budget | Little room: react-dom 65, supabase 62, router 14, translations 14 KB (gzip) | The production test fails above 200 KB; check it after adding any library | Later |
| K14 | A save that is found again by its save id keeps the numbers first stored | If a save looked failed (a server error after it was stored), the operator changed a number and saved again, the first numbers stand; the "saved" screen shows them | Correct the record the usual way | Later |
| K15 | Restoring logins and evidence files into a new hosted project was written but not rehearsed | The database restore itself was rehearsed locally with a comparison of every table | First quarterly drill on a throwaway project (`docs/RESTORE.md`) | Before the season |
| K16 | No external penetration test, no device lab | Permissions are tested with real logins through the API (121 checks) and the security policy is enforced in the tests; nobody outside the build has attacked it, and no low-end Android phone has run it | PRD §13 human tasks | Before the season |
| K17 | The CI workflow could not be delivered into `.github/` from the build environment | CI still runs the previous workflow | Copy `docs/ci/database-tests.yml` over `.github/workflows/database-tests.yml` (run-sheet step A12) | This week |

Checked only against the vendors' documentation, not by a test from here; each has a run-sheet step that checks it on
the real system: phone + password sign-in with the hosted Phone provider settings (A7, B4), the nightly schedule
(`pg_cron`, A8), the security headers on Cloudflare's single-page fallback (B3). Making and resetting logins with
public sign-up switched off was tested on the local Auth server (same software as the hosted one) and is checked on
staging in B4.

## Found and fixed in Phase 4, before any real lot

Each fault was reproduced first (a test that failed, or a probe of the app as it was), then fixed, and the test is now
part of the suite. Lines 13 to 15 are things the app could not do at all. Numbers and commands are in
`docs/VERIFICATION_LOG.md`.

| # | What was wrong | Since | Now | Test |
|---|---|---|---|---|
| 1 | **Working without a network ended after one hour.** The sign-in token lasts an hour. With no network after that, opening the app showed the sign-in screen (which needs a network) | Phase 3 | The app opens from the login kept on the phone (0.5 s) and renews the token when the network is back | `e2e-prod/field_day.spec.ts` 1 |
| 2 | **A waiting save could be sent with nobody's name on it.** In the same situation, when the network came back the save went out with the project's public key, the database refused it ("permission denied for table footprints") and it was marked "needs attention" | Phase 3 | A signed-in phone never sends a request without its own token; the save waits and then goes out | `field_day` 1, 2; `tests/field_day.test.ts` |
| 3 | **A save whose answer was lost was stored twice** (the request arrived, the reply did not: two records, the farmer's grain counted twice) | Phase 3 | Every save carries one id from the first tap; the database refuses the id twice and the app picks up the record already made | `field_day` 7 |
| 4 | A photo that could not be sent after its record was stored was dropped; the operator had to attach it again by hand | Phase 3 | The photo waits on the phone with the save and is attached when the network is back | `field_day` 8 |
| 5 | On a link that takes requests and never answers, a form did not open (waited 40 s and more) and a save waited for the browser | always | The form opens from the phone's copy after 9 s; a save is stopped after 30 s and kept on the phone | `field_day` 3 |
| 6 | After a lost phone was deactivated, or a login was ended by the server, the farmer list and forms stayed on the phone | Phase 3 | Erased on every sign-out and at the first contact after deactivation | `field_day` 4, 6 |
| 7 | With no network and the hour over, **Sign out** did nothing, and it had already erased the forms kept for offline work | Phase 3 | Signs out on the phone, after a warning that signing in again needs a network | `field_day` 5 |
| 8 | Switching to another app and back (a phone call, the camera) wiped a half-filled form | Phase 1 | The form stays | `e2e/phase4.spec.ts` "Switching to another app…" |
| 9 | A seal refused at the gate (an open flag) left the lot closed and unsealable | Phase 1 | Recording and sealing are one transaction (`app.seal_source`); a refusal leaves nothing behind | `tests/16_seal_atomic.sql`, `e2e/phase4.spec.ts` |
| 10 | A grading run marked "split" could be saved without its grade lots (two requests), and a run corrected to "split" never got them | Phase 2 | The save itself makes the lots (trigger) | `tests/16_seal_atomic.sql`, `e2e/phase4.spec.ts` |
| 11 | An operator could read the whole scope's ledger through the API (a Procurement operator saw the buyer and the sale) | Phase 0 | The ledger follows the thumb rule: own stage and the one behind | `tests/17_access_rules.sql`, `tests/remote_rls.mjs` |
| 12 | Quantities, status, dates, codes and lab verdicts could be rewritten by a direct API call from a signed-in person at the right stage (eleven such openings, listed at the top of migration 22) | Phase 0 | Each is refused by the database | `tests/14_integrity_guards.sql`, `remote_rls.mjs --t1` |
| 13 | A wrong lab record, batch or grade lot could not be put right at all | Phase 1 | Withdraw with a reason, record the replacement; nothing is deleted | `tests/14`, `e2e/phase4.spec.ts` |
| 14 | Stage assignments could not be taken away; changes to people and evidence files were not in the ledger | Phase 1 | Removable; every such change is a ledger block | `tests/17`, `tests/18` |
| 15 | A person made by a manager kept the password the manager had seen; nobody could reset a forgotten one | Phase 1 | Own password at first sign-in; **Reset password** | `e2e/phase4.spec.ts`, `remote_create_user.mjs` |
| 16 | "Correct this record" at any stage but the first showed the waiting list instead of the form | Phase 1 | Shows the form | `e2e/phase4.spec.ts` |
| 17 | On Hindi screens the record page, the status words (pending, verified, pass…) and the app's own messages ("No connection…") were English | Phase 3 | Translated; a test scans the operator screens for text that bypasses the dictionary | `tests/phase4.test.tsx`, `e2e/phase3.spec.ts` Hindi |
| 18 | Grey text and the GI badge were below the contrast needed (Lighthouse accessibility 96) | Phase 1 | 100 on the verify page and the sign-in page | `release-evidence/lighthouse.json` |
| 19 | **No deploy to Vercel got as far as the build** (five in a row). `web/vercel.json` carried a `$comment`; Vercel refuses any property outside its schema | 2026-10-03, the first Vercel deploy | The note is in `docs/DEPLOY.md`; the file holds accepted properties only | `tests/phase4.test.tsx` "hosting config" |
| 20 | `npm ci` in `web/` failed on Linux ("Cannot find module @rollup/rollup-linux-x64-gnu"; the same install runs on Vercel). A `package.json` added at the repo root named `web` as a workspace, so npm ignored `web/package-lock.json` and used a root lockfile written on Windows | 2026-10-03, commit 5ffc656 | `web` installs from its own lockfile; the root lockfile is gone | same, and the CI step "web — install, typecheck, component tests" |

Hardening in the same phase that was **not** a demonstrated fault: the service worker's plain copy of the app shell for
hosts that redirect `/index.html` (the old worker passed the same test); sign-out with no network while the token is
still fresh (it worked before too); the production build stops without `.env.production` (a build made without it
would have carried the staging keys) and the monitor token script keeps separate files for production.
