# The showcase page and the lifetime rule, Phase 3 release 5: migration 72 and the app, onto the practice system

Veda, 27 October 2026: the combined brief ("GrainVeda MVP: combined brief"), Phase 3 Parts E3, F and A4, with item 71;
"proceed" (the defaults sent that day). Item 72 in `docs/FIX_LIST.md`. Phase 3 release 4 (migration 71, the evidence
pack) is on staging since 27 Oct 2026 (head de1ff2b); this script expects **only migration 72** waiting.

- **The showcase page, Basic (E3)**, at `/verified/<client code>`, public:
  - the client's name; each verified state (Active, Suspended or Ended) with its crops and seasons and their figures;
  - the headline figures: tonnes traced (the verified kilograms bought from farmers), villages, the share from the GI
    area and farm-verified, the lab pass rate (QC records passed for at least one market);
  - **"Verify any pack"** (the code on a pack or a lot's QR opens its own page); the active **recall notices**;
  - a sourcing partner only where it agreed to be named.
  - Never a price, a farmer's name or phone, or a buyer's name (the server sends none).
- **Approval.** Nothing is public until the **client's owner** approves it ("Approve and publish", after a preview); the
  owner unpublishes it with a reason, also while the client is suspended. Prasaadam and any own-brand client, which have
  no owner of their own, are approved by the **admin**; their page and badge say "Operated by GrainVeda (own brand)".
  While the client is suspended in every state the owner cannot approve. Both acts are in the Audit log.
- **Never active when it is not.** Each state says "Verification paused" or "Verification ended on …"; the page's banner
  says so when no state is Active. After the lifetime period (below) the page says only that verification ended.
- **The badge**: an image from the host (`/api/badge?c=<code>`) that always shows the client's status ("Verified by
  GrainVeda", "Verification paused", "Verification ended on …", "No showcase page"), and the snippet the owner copies onto
  its own site, linking to the page.
- **How long things stay live (F, A4).** An ended client's accounts read and export until the longer of best-before +
  12 months and 24 months after the contract ended; then they open nothing (the rules enforce it; a daily round marks
  them removed, in the Audit log, and tells the owners 30 days before). The verify pages of its evidence packs and season
  reports likewise say only that verification ended. A practice system may shorten the periods for a test; production
  never.
- **Item 71.** (1) The admin's card is "Reports and evidence packs issued". (2) The Audit log's lines of a report or a
  pack name its reference and open its verify page; a showcase's lines name the client. (3) A client order's pack has its
  files stored the first time its Client or State Manager opens it, so its verify page lists them.

**Only when Veda has said so.** This pushes migration 72 to the practice database and **pushes to the main branch**.
Production is not touched. Nothing is deleted or rewritten: one new table (`client_showcases`, a showcase's approval),
new functions, a daily round (pg_cron, `grainveda-client-lifetime`), a wider list of notification kinds; replaced from
their own text, each change named in the migration: `app.my_client_account`, `app.account_reaches`,
`app.account_states`, `app.account_sees_farmer`, `app.client_operator_for` (an ended client's accounts after the lifetime
period), `app.public_document` (an output's verify page after it).

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-showcase-lifetime.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migration 72 waiting; the seven functions current. **Asks you to type `SHOWCASE`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 72 | the push fails (a migration is one transaction) |
| S1b | Reads back (read only): `table=new functions=new lifetime=yes round=scheduled published=0 ended_states=… closed_clients=0` | anything is not as migration 72 leaves it |
| S2 | Smoke check **70** rows (new: `showcase and lifetime`, `client lifetime round`), the rules in place (70's, 71's, 72's), the change log intact (**73** tables), **one client and another** in 8 parts, the ledger audit, logins, functions | a row or a check is not `OK` (statement logging stands); any leak stops it before the app is pushed |
| S3 | Commits and pushes the app (with the host's `/api/badge`) | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: SHOWCASE AND LIFETIME ON STAGING` or `RESULT: STOPPED`. Between S1 and S3 (if a run stops there) the
old app works as before; it has no showcase page and nothing is published. Run the script again.

## Afterwards (about 25 minutes, phone width; practice data only)

Each person signs in themselves; Claude can then drive the steps in the browser. Test Client UP (`TCUP`) and its
practice owner; the lot sealed in release 4's checks (`GV-7FA853226C45`).

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | anyone, not signed in | open `/verified/TCUP` | "No showcase page" (nothing is public yet) |
| 2 | tcup (a viewer) | Portfolio → **Showcase page** | "Not published"; Preview opens the page as it would be; no "Approve" |
| 3 | Practice Owner TCUP | Portfolio → Showcase page → Preview, then **Approve and publish** → Publish | "Published on … by …"; the badge "Verified by GrainVeda · Test Client UP"; the snippet to copy |
| 4 | anyone, not signed in | `/verified/TCUP` | the name, Uttar Pradesh "Verified by GrainVeda", Kalanamak Rice · KH26 with its figures; no price, no farmer's or buyer's name; "Verify any pack" with `GV-7FA853226C45` opens the lot's page |
| 5 | Claude | `/api/badge?c=TCUP` | the badge, "Verified by GrainVeda" |
| 6 | the admin | Clients → Test Client UP → suspend in Uttar Pradesh (a reason) | the page: Uttar Pradesh "Verification paused" and the banner "Verification paused"; the badge "Verification paused"; then **resume** (a reason): active again |
| 7 | Practice Owner TCUP | Showcase page → **Unpublish** (a reason) | "Unpublished on … by …: …"; `/verified/TCUP` says "No showcase page"; then Approve and publish again (optional) |
| 8 | the admin | the Audit log | "published the showcase page of TCUP", "unpublished …" with the reason; the evidence packs' lines name `GV-EP-…` and open their verify page |
| 9 | Lucky | Client orders → `ORD-TCUP-0001` | the order's pack's files stored on opening; `/d/GV-EP-000002` lists six files |
| 10 | the admin | Home | the card "Reports and evidence packs issued" |

Not checked on staging (the tests cover them): an own-brand client's page approved by the admin (staging's own-brand
client, if any, can be tried the same way), a recall and a named partner on the page, a client's owner refused while
suspended, the ended client's accounts closing after the lifetime period, the owner told 30 days before, the outputs'
verify pages after it, production never shortening the periods (`tests/67_showcase_lifetime.sql`, 38 checks, 18
controls; `web/tests/release72.test.tsx`; `e2e/phase43.spec.ts`, at 527 px).

## If something is wrong afterwards

Nothing was deleted or rewritten. A page published by mistake is unpublished by its owner (or, for an own-brand client,
the admin) with a reason. An account closed by the lifetime round is in the Audit log with the date and the reason.
Send Claude the page's address and its words.
