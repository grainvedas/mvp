# Showcase fixes, Phase 3 close-out (FIX_LIST item 73, the app only), onto the practice system

Veda, 27 October 2026: "proceed with phase 3" (close Phase 3 out: item 73, then the report back). Phase 3 release 5
(migration 72) is on staging since 27 Oct 2026 (head 0fa86e0); this script expects **no migration waiting**.

- **(1) "Verified" only while active.** The line above the client's name on `/verified/<code>` says "Showcase ·
  verified by GrainVeda" only while the client is active; paused or ended it says "Showcase · GrainVeda". The badge's
  last line likewise ("Traceability verified under GrainVeda's protocol" only while active, else "GrainVeda
  traceability").
- **(2) Never a wrong status on the badge.** When the host cannot read a client's status (a cold start, the database not
  answering), `/api/badge` says "Status unavailable" and is not cached; before, it said "No showcase page" for a minute.
- **(3) A client's lines in the Audit log** (status, gates, documents, renewals, activation) name the client's code and
  open its page; before, they showed "—" and opened a person page that does not exist.
- **(4)** The unpublish reason box has a name for a screen reader.

**Only when Veda has said so.** This **pushes to the main branch**. No migration, no data changed, production not touched.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-showcase-fixes.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files (212 app and function files); the practice project, answering `staging`, with **no** migration waiting; the seven functions current. **Asks you to type `FIXES`** | any check fails, a migration is waiting, or anything else is typed. Nothing is changed |
| S1 | Not run: no migration | |
| S1b | Reads back (read only) that migration 72 is still in place: `table=new functions=new lifetime=yes round=scheduled published=1 …` (TCUP's page is published) | anything of migration 72 is not in place |
| S2 | Smoke check **70** rows, the rules in place (70's, 71's, 72's), the change log intact (73 tables), **one client and another** in 8 parts, the ledger audit, logins, functions | a row or a check is not `OK` (statement logging stands); any leak stops it before the app is pushed |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: SHOWCASE FIXES ON STAGING` or `RESULT: STOPPED`. A stop changes nothing; run it again.

## Afterwards (about 10 minutes, phone width; practice data only)

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | anyone | `/verified/TCUP` | above the name: "Showcase · verified by GrainVeda" (TCUP is active) |
| 2 | the admin | suspend Test Client UP in Uttar Pradesh (a reason), open `/verified/TCUP`, then resume (a reason) | while suspended: "Showcase · GrainVeda" above the name, nowhere "verified by GrainVeda"; the badge (`/api/badge?c=TCUP&t=<anything>`) "Verification paused" and its last line "GrainVeda traceability"; resumed: as row 1 |
| 3 | the admin | the Audit log | the suspend and resume lines name `TCUP` and open Test Client UP's page |
| 4 | Claude | `/api/badge?c=TCUP` twenty times with a new address each | "Verified by GrainVeda" every time (a "Status unavailable" would be the host not reading the status, never a wrong one) |

Not checked on staging (the tests cover it): the badge when the database does not answer
(`web/tests/release73.test.tsx`, 6 tests; `e2e/phase43.spec.ts` at 527 px).
