# Backups and restore (PRD §9 "Backup and recovery", §12 "restore drill completed from backup")

## What is kept where

| What | First copy | Second copy (off the platform) | Without it |
|---|---|---|---|
| Records, farmers, ledger, rules (schemas `public`, `app`) | Supabase daily backup, 7 days kept. **Pro plan only: the Free plan has no backups** | `backups/<time>/db.dump` from `scripts/backup.mjs` | the season's records are gone |
| Logins (phone / e-mail, password hashes) | inside the same Supabase backup | `backups/<time>/auth.dump` | everyone needs a new temporary password |
| Evidence files (photos, documents) | Supabase Storage. **Not part of any database backup** | `backups/<time>/evidence/…`, each file re-hashed as it is copied | records keep their fingerprints, the files are gone |
| The rules themselves (migrations), the app, the functions | this repository | GitHub | — |
| Keys and passwords | Supabase dashboard | the password manager | — |

The second copy holds farmers' phone numbers and password hashes: keep the `backups` folder on an encrypted drive, never
on a shared drive or in git (`backups/` is git-ignored).

Loss in the worst case: with daily backups, up to one day of records. The ledger makes the loss visible, not smaller:
a restored copy that is behind the paper slips of the last day is completed by recording those lots again.

## Routine

| When | Command | Result |
|---|---|---|
| Weekly (and before every migration push to production) | `$env:ENV_FILE='.env.production'; node scripts/backup.mjs` | `BACKUP TAKEN backups/<time>`; a line per part; `evidence: n/n file(s) stored and matching their fingerprint` |
| Quarterly, and once before go-live | `node scripts/restore_drill.mjs` (same `ENV_FILE`) | last line `RESTORE DRILL PASSED`; log in `backups/<time>/RESTORE_DRILL.log` |

Needs on the computer that runs them: Node 22; the PostgreSQL client tools of the server's version or newer
(the project runs Postgres 17: `pg_dump --version` must say 17 or more; set `PGBIN` to their folder if they are not on
the PATH); `SUPABASE_DB_URL` in the env file (Dashboard → Connect → Session pooler, port 5432, with the database
password). For the drill also a local Postgres 17 to restore into; the throwaway cluster from the header of
`tests/run_local.ps1` is enough (`PGHOST`, `PGPORT`, `PGUSER` point at it).

## The restore drill

A backup is only a backup once it has been restored and compared. The drill restores into a scratch database **on the
computer it runs on**; it refuses any other target, so it cannot overwrite a real project.

What it does, in the order a lost project would be rebuilt:

1. takes a backup (or uses `--backup backups/<time>`), checks the dump against the SHA-256 in its manifest;
2. builds the schema from the repository's migrations, as a new project gets it;
3. loads the backup's data with triggers off, so nothing is re-derived and no ledger block is written twice;
4. compares with the source as it was when the backup was taken: rows per table, number of functions, policies,
   triggers and API grants (a difference here means the live project has drifted from the migrations), the ledger's
   last block and a digest of the whole chain, digests of records, farmers and evidence fingerprints, and the public
   page of the newest sealed lot, byte for byte;
5. runs the chain check and the ledger audit on the restored copy;
6. alters one block in the restored copy by hand and expects the chain check to catch it (a check that cannot fail
   proves nothing);
7. confirms every evidence file in the backup matched its fingerprint.

Proven on the local stack (2 Oct 2026): 20 tables, 1139 rows, 705 ledger blocks, 37 seals, 6 evidence files, identical;
the altered block was caught; with a manifest that disagreed the drill failed, naming the table and the block; with one
stored file altered the backup reported that file. **Not yet run against the hosted project**: that is step B9 of
`docs/RUNSHEET_phase4.md`, and the release gate shows REHEARSAL until it is.

The second kind of drill tests Supabase's own backup: Dashboard → Database → Backups → *Restore to a new project*
(paid plans), then compare the new project with the source:

```powershell
node scripts/restore_drill.mjs --compare .env.restored      # .env.restored holds the new project's SUPABASE_DB_URL
```

It passes when the restored project's ledger is a true prefix of the source's (same hash at its last block), verifies,
and the audit finds nothing. Supabase states that this kind of restore does not bring Storage files, Edge Functions or
Auth settings; the evidence files then come from the off-platform copy (`scripts/restore_evidence.mjs`). Delete the
drill project afterwards.

## If it happens

| Situation | Do | Then check |
|---|---|---|
| The nightly ledger check fails (red banner, monitor alert) | Nothing is restored yet. Health page → which block; `tests/remote_ledger_audit.sql`; freeze sealing (tell the QR operators); call the admin. A failed check means a row was changed outside the app | `docs/OPERATIONS.md` § "Ledger check failed" |
| Records were damaged by a mistake in the last days (a bad migration, a wrong bulk change) | First, in the app, each scope → **Dashboard → Download season summary (CSV)**: one row per record with its `created_at`. Then Supabase Dashboard → Database → Backups → restore the last good day. Every row of the CSV made after that backup is gone from the database and is recorded again from the CSV and the paper slips | smoke check, ledger audit, `restore_evidence.mjs --backup <the newest off-platform backup>` (a database restore does not touch stored files; this re-hashes every registered file and puts back any that is missing) |
| The project is gone or unreachable for good | New project (Pro, Mumbai) → `supabase db push` → data from `db.dump` → logins from `auth.dump` → evidence with `restore_evidence.mjs` → dashboard settings, functions and secrets as in `docs/DEPLOY.md` steps 4–6 → new `.env.production`, build, deploy | `restore_drill.mjs --compare`, smoke check 21/21, a sign-in, a sealed lot's public page |

Loading the data and the logins into a new hosted project (third row):

```powershell
$env:PGBIN = 'C:\path\to\pgsql17\bin'
& "$env:PGBIN\pg_restore.exe" --data-only --no-owner --no-privileges -f data.sql backups\<time>\db.dump
& "$env:PGBIN\psql.exe" "<new project's session-pooler URL>" -1 -v ON_ERROR_STOP=1 -c "set session_replication_role = replica" -f data.sql
& "$env:PGBIN\pg_restore.exe" --data-only --no-owner --no-privileges -f auth.sql backups\<time>\auth.dump
& "$env:PGBIN\psql.exe" "<new project's session-pooler URL>" -1 -v ON_ERROR_STOP=1 -c "set session_replication_role = replica" -f auth.sql
Remove-Item data.sql, auth.sql
$env:ENV_FILE = '.env.production'; node scripts/restore_evidence.mjs --backup backups\<time>
```

The first two lines are exactly what the drill does into the scratch database. The two `auth` lines and the upload of
evidence into a hosted bucket have been written but **not rehearsed on a hosted project** (none was available from the
build environment; the evidence upload was rehearsed against the local stand-in: one file removed, restored
byte-identical). Rehearse them once on a throwaway project in the first quarterly drill, and correct this page with
what was learned. People sign in with their old passwords after such a restore; every session open at the time ends.

## Drill log

Each drill writes `backups/<time>/RESTORE_DRILL.log`. Copy its last lines here (never the files themselves).

| Date | Run by | Source | Result | Restore time | Notes |
|---|---|---|---|---|---|
| 2026-10-02 | Claude (build environment) | local stack, logical dump | PASSED | 1.9 s (1139 rows, 705 blocks) | rehearsal only; not a hosted project |
| | | | | | |
