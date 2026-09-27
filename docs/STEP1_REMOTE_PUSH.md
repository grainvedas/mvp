# Step 1 — apply Phase 0 to the Supabase project `zogkrhgzatplarimbmxk`

Instructions for Antigravity IDE (or whoever runs it). Do these in order; stop at the first failure and report it verbatim.

## 0. Preconditions
- `.env` / `.env.local` hold the URL, publishable key and service-role key. **They are git-ignored; never commit them, never put the service-role key in front-end code.**
- The Supabase CLI needs two things `.env` does not have: a **personal access token** (`supabase login`) and the
  **database password / direct connection string** (Dashboard → Connect → Session pooler URI). Ask Veda for both; do not guess.

## 1. Expose the `app` schema (Dashboard)
Project Settings → API → *Exposed schemas* → add `app`. Without this, `supabase-js` cannot call
`app.verify_footprint`, `app.seal_lot`, `app.incoming_records`, `app.public_lot_journey`, `app.pipeline_summary`.

## 2. Link and push migrations
```bash
npx supabase login                                   # personal access token
npx supabase link --project-ref zogkrhgzatplarimbmxk # asks for the DB password
npx supabase db push                                 # applies supabase/migrations/* in order
```
Expected: six migrations applied, no errors. If `db push` reports the project already has migrations, list them with
`npx supabase migration list` and report before doing anything else.

## 3. Seeds (db push does not seed a remote project)
```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/seeds/01_stage_definitions.sql
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/seeds/02_kalanamak_demo.sql
```
(`SUPABASE_DB_URL` = the session-pooler URI. Newer CLIs also accept `npx supabase db push --include-seed` with
`[db.seed] sql_paths = ["./seeds/*.sql"]` in `supabase/config.toml`.)

## 4. Smoke check (read-only)
```bash
psql "$SUPABASE_DB_URL" -f tests/remote_smoke.sql
```
Every row must read `OK`, except `auth.uid mapping`, which stays non-OK until step 5.
**Never run `tests/run_local.sh` or `tests/00_local_auth_shim.sql` against the remote project** — the shim overwrites `auth.uid()`.

## 5. Auth users and mapping
Create the 12 demo users in Dashboard → Authentication (phone OTP for operators, email for managers), then map each one:
```sql
update public.app_users set auth_uid = '<auth.users.id>' where id = '<app_users.id>';
```
Re-run the smoke check; `auth.uid mapping` must now be `OK`.

## 6. Report back
Paste the `db push` output and the full smoke-check table. Do not summarise them as "done".
