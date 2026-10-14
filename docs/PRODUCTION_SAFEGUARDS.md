# Production safeguards: what the system does, and the go-live checklist

Veda, 14 October 2026: *"when in production and in real time can such thing happen and not recorded? … this is
practice data but i want to be sure when in production how can we solve this issue?"* Open item 40 in
`docs/FIX_LIST.md`; built in migration 45 (`20261020000100_production_safeguards`).

## The answer in one paragraph

People who use the app cannot change anything without it being recorded under their own name: the database takes the
signer from the sign-in, never from the screen, and every act is a ledger block that cannot be edited or removed. The
one way round it is **the database owner's keys** (the Supabase dashboard login, the database password, the service
key). No system can stop its own owner completely. What we do instead: (1) almost nobody holds those keys; (2) the
only proper way to correct live data is one door that records who asked, who approved and why; (3) anything done with
the keys outside that door leaves evidence the owner cannot quietly erase: the change log, the database's own
statement log, and a daily copy of the ledger's fingerprint kept outside the database.

## What migration 45 built

| Layer | What it does | Where you see it |
|---|---|---|
| **Change log** | Every insert, update and delete on 21 tables (farmers, people, HR records, assignments, rosters, openings, scopes, clients, crops, states, lots, verdicts, seals, withdrawals, the system settings): who, when, how it came (in the app · a server function · a correction · declared · direct), which columns, fingerprints of the row. **No values** (no phone, no ID number). Append-only and chained like the ledger: a line changed or removed breaks the chain | Safeguards page (admin): "Change log intact", the counts by way, the list of changes behind the app |
| **One door for corrections** | The admin asks in the app, with the reason. A second person (the HR Admin or another admin) approves or refuses, with a reason. A database owner then runs it inside `app.open_correction` / `app.close_correction`: a ledger block in the name of the admin who asked, and every change marked with it. While two-person approval is off (one admin today), an owner may run a request as it is | Safeguards page: Corrections; the ledger: "correction opened / closed" |
| **Outside copy of the fingerprint** | Every day a GitHub job copies the newest ledger block's and change-log line's fingerprints to the branch `ledger-anchors`, and checks every earlier copy still matches. A ledger or change log rewritten since, even with every hash recomputed, no longer matches: the run fails and GitHub emails | GitHub → Actions → "ledger anchor"; branch `ledger-anchors` |
| **The ledger cannot be emptied** | It refused update and delete; now also truncate | — |

Release scripts that change data on the practice system refuse production (`practice_fix_14oct`,
`practice_note_15oct`). Any future correction on production goes through the door.

Emptying the practice system (`scripts/fresh_start/empty_staging.sql`, refused on production) sets the ledger's and
the change log's guards aside for that one statement, as it already did for the audit log. Its daily outside copy then
no longer matches, by design: after such a reset, rename `staging.csv` on the branch `ledger-anchors` (for example to
`staging-before-<date>.csv`) so the copy starts again.

## Go-live checklist (before the first real lot)

Each step names who does it. Claude prepares scripts and reads results; it holds no production key.

| # | Step | Who | How to check |
|---|---|---|---|
| 1 | **The production project in its own Supabase organization, with exactly two members, both Owner**: Veda and one person she trusts. Nobody else, not as Developer (Developer works with the project's data) and not as Read-only (Read-only can see the server functions' secrets). Developers (Tarun, Claude) work on staging only | Veda | Organization → Team: two names |
| 2 | **Two-factor sign-in** for both owners, and the organization set to *Require MFA to access organization* (Pro plan or above; only an owner who has MFA on can switch it on) | Veda | Organization → Security |
| 3 | **Keys stay in two places**: the Supabase project, and the owners' password manager. The service key never on a developer's laptop or in chat; the database password changed at go-live (the staging ones were shared in chat) | Veda | — |
| 4 | **The database's own statement log**: Database → Extensions → enable `pgaudit`; then in the SQL editor `alter role "postgres" set pgaudit.log to 'write, ddl';` (or, without the extension, `alter role postgres set log_statement = 'mod';`). Every write and schema change made with the owner's account then lands in Logs → Postgres (filter `AUDIT`); a query run from the dashboard also carries the member's id (`-- user:`) | Veda | the smoke check's row `statement logging` says OK |
| 5 | **Plan and backups** (decision G2): Pro gives daily backups kept 7 days and the MFA rule; point-in-time recovery is an add-on. *Platform audit logs* (who did what in the dashboard) are on the Team plan and above: decide whether you want them | Veda | Project → Database → Backups |
| 6 | **The daily outside copy**: GitHub → the repository → Settings → Secrets and variables → Actions → **Variables**: `GV_PROD_URL` and `GV_PROD_ANON_KEY` (the production project's URL and its public key; for staging `GV_STAGING_URL`, `GV_STAGING_ANON_KEY`). Then Actions → "ledger anchor" → Run workflow once; it must end green and the branch `ledger-anchors` must hold `production.csv`. GitHub emails a failed run to the person who last changed the schedule (the one whose push installed it): check that address is read | Veda | Actions: a green run every day |
| 7 | **The nightly ledger check is scheduled** (pg_cron) | Veda (with the go-live run sheet) | the smoke check's row `nightly ledger check` says OK |
| 8 | **Two-person approval on**, once a second approver exists: in the SQL editor `insert into public.app_meta (key, value) values ('two_person_corrections', 'on') on conflict (key) do update set value = 'on';` (this change itself shows as "direct" in the change log: expected) | an owner | Safeguards page: "Two-person approval is on" |
| 9 | **Every week**: the admin opens Safeguards. Anything **direct** needs an explanation from the owners; the outside copy's runs are green | the admin | — |

## Running an approved correction (an owner, in the SQL editor)

All in **one run** (the dashboard does not keep a session between runs):

```sql
select app.open_correction('<the correction id from the Safeguards page>');
-- the change itself, as small as possible, e.g.:
update public.farmers set village = 'Bansi Khurd' where id = '<farmer id>';
select app.close_correction();
```

The ledger then shows *correction opened* (in the name of the admin who asked, with the reason and who approved) and
*correction closed* (how many rows changed); the change log marks the update as that correction. A change made any
other way shows as **direct**.

## How Claude and other helpers work once production is live (Veda, 14 Oct 2026: "after production we have to be careful")

On staging (practice data) Claude has worked directly in GitHub and Vercel with Veda's word. On production it does not.
The same rules hold for any other helper (Tarun, another AI tool, a contractor).

| On production | The rule |
|---|---|
| Data | Never changed by Claude. A correction goes through the door: the admin asks, a second person approves, an owner runs it |
| Releases | Claude prepares a script; Veda runs it and types the words; Claude reads the record |
| Keys and accounts | Claude holds no production key, password or seat in the production Supabase organization |
| Settings (Supabase, GitHub, Vercel) | Changed by Veda, or by Claude only after her yes for that one step, said in the chat |
| Veda's browser | Claude reads (dashboards, logs, deployments); it clicks only what she has approved, one step at a time |
| Every act | Leaves a trace (change log, ledger, GitHub history, the release record), so she can see what was done and by whom |

*Draft of 14 Oct, to be changed by Veda before go-live.*

## What this does not do (said plainly)

- An owner can still switch the guards off and change data. That is detected (the chains break, the outside copy stops
  matching, the statement log records it), not prevented.
- The change log keeps fingerprints, not values: it proves *that* a row changed and when, not what it said before.
  The daily backups hold the earlier values.
- Platform audit logs (dashboard actions such as changing settings or members) need the Team plan.
- The outside copy proves the ledger's history from the day it starts; it cannot vouch for anything before its first
  run.
