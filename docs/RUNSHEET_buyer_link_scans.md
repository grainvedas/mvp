# Share with the buyer, scans and copies, release 9: migrations 56 and 56b, the app and buyer-file, onto the practice system

Veda, 16 October 2026, "proceed with 56" (decision G19). Release 9 of the operator-stages plan, the last. Item 51 in
`docs/FIX_LIST.md`. Releases 1 to 8 (migrations 48 to 55) are on staging since 16 Oct 2026, 07:22 (9cfe6c9); this
script expects **migrations 56 and 56b** waiting, or **56b alone**.

**The first run (16 Oct, 09:59) stopped at S2**, as it should: the isolation check found another client's **openings**
readable by every Client Manager (`leaks=2 … what=table:openings`). Migration 56 and `buyer-file` were in; the app was
not pushed. **Migration 56b** closes it (a manager reads only the openings of his own clients). Run the same
double-click again: it pushes 56b alone, deploys `buyer-file` again (harmless), and runs the check again.

- **Share with the buyer (Part F).** On a sale or a shipment, the Client Manager (or a manager of the scope) makes a
  **link that lasts 7, 30 or 90 days**. It is shown once (only its fingerprint is kept), to copy or send by WhatsApp or
  email. The buyer opens it **without signing in**: the order (its number, the packs, the kilograms), the shipments'
  papers, the lab results per market with the readings, the export documents and their state, the chain, the villages'
  shares and how many farmers. **Never a price, a farmer's name or another buyer's order.** He opens the lab report and
  the documents (through the new server function `buyer-file`: a download that lasts two minutes) and downloads the
  **evidence pack** (the page as a file, with each file's SHA-256). **Every view is listed** for the Client Manager
  (page opened, a file, the evidence pack); a link is **revoked** with a reason, and then opens nothing. The page is
  built apart from the way in: a buyer's own sign-in can replace the link later.
- **Scans and copies (D5–D6).** Every scan of a pack's or a lot's QR is counted with the time and its **approximate
  place**: the city, region and country the host saw, and a point rounded to about 10 km. Nothing about the person (no
  address, no device). More than 60 scans of one code in a minute are answered, not counted. A pack's code scanned
  **more than 300 km apart within 30 days**, or **more than 50 times in a day** (the crop can say other numbers), is a
  **scan flag** for the scope's managers ("Needs my action", the Flags page), and the pack's public page **warns**
  ("it may be a copy; the seller is checking it") until a manager **clears** it (genuine scans) or **confirms** it (a
  copy: the warning stays), with a reason.
- **One client's data is never another's** (Veda: "check that one client data should not be visible to another
  client"). A check, `app.isolation_probe()`, looks as every person bound to a client at every table the app reads and
  calls every app function with the other clients' ids. It found three leaks on the local data, and a fourth on staging (another client's openings, migration 56b), all closed: **a client's own lab** was
  readable by everyone; **a scope's activation list** answered for another client's scope; the **roster pool** named the
  client and the scope where a person works for another client (now: "Milling for another client (active)"). S2 runs
  the check on staging, read only, and stops before the app is pushed if anything is seen.
- **The Collection Batch's lots** (Veda: "there will be many lots per farmer per village"): a **village** filter, a
  search by **farmer, farmer code or lot code**, "**Choose the N shown**", and a line when chosen lots are hidden by
  the filter. Works offline (it filters what the phone has).
- **Three fixes of release 8's checks**: "every day" (not "every 1 days"); the farm-gate farmer list says "Loading the
  farmers…" until it has come (not "No active farmer of this client yet"); an export sale's market profile and
  destination are marked required (`*`; the save asked them already).

**Only when Veda has said so.** This pushes migrations 56 and 56b to the practice database, **deploys one new server function
(`buyer-file`)** and **pushes to the main branch**. Production is not touched. Nothing is changed or deleted. The six
server functions of before are unchanged (build 2026-10-14); `buyer-file` has its own build (2026-10-16). Between S1
and S3 (a few minutes) the old app works as before; it offers no buyer link and counts scans without a place.

**The scan's place comes from Vercel** (`web/api/scan.js` reads its `x-vercel-ip-*` headers). On another host (G4:
Cloudflare recommended for production) scans are counted without a place until that host has the same small
function: an owner decision in `docs/FIX_LIST.md` item 51.

## One double-click (about 4 minutes, then Vercel)

Double-click **`staging-buyer-link-scans.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migrations 56 and 56b waiting (now: 56b alone); the six functions current (`buyer-file`: "not deployed" the first time). **Asks you to type `BUYER`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: the waiting migrations, in order | a push fails (nothing of that migration is applied) |
| S1c | `supabase functions deploy buyer-file --no-verify-jwt`, then `check_functions`: seven functions current | the deploy fails, or a function is not current |
| S1b | Reads back (read only): `commercial_form=new stages=17 links=0 link_views=0 scan_flags=0 scans=… scans_with_place=0` | the read fails, the form is the old one, or a link, a flag or a scan with a place exists already |
| S2 | Smoke check **54** rows (new: `buyer link scans`, `client isolation`), the new rules in place, the change log intact (**54** tables), **one client and another** (`leaks=0 people=… tables=… calls=…`), the ledger audit, logins, functions | a row or a check is not `OK` (the three set-up rows are listed but do not stop it); **any leak** stops it before the app is pushed |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: BUYER LINK AND SCANS ON STAGING` or `RESULT: STOPPED`.

## Afterwards (about 30 minutes, phone width; practice data, clearly fake)

Each person signs in themselves; Claude can then drive the steps in the browser. Lucky holds every stage of Test Client
UP's scopes.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Lucky (Client Manager) | A sale or shipment of Test Client UP (one of release 7's checks) → its record → Share with the buyer → Make a buyer link: 7 days, note `practice (test)` → Make the link | the link once (`…/b#…`), Copy, WhatsApp, Email; the list: Active, opened 0 times |
| 2 | Nobody signed in (a private window) | Open the link | the buyer's page: the order, the papers, the lab result, the villages' shares; no price, no farmer's name |
| 3 | Same | Open a file (if the page lists one); Download the evidence pack | the file opens; a file `evidence-<code>.json` |
| 4 | Lucky | Reload the record | the link: opened 2 or 3 times; "Every view" lists them |
| 5 | Lucky | Revoke, reason `practice done (test)` | Revoked; the buyer's page now says "This link does not open" |
| 6 | Nobody signed in | A pack's page `/p/<code>` (one of release 6's packs) | the page; in the browser's network list `/api/scan` answers `{"counted":true,…}` (the place was recorded) |
| 7 | Lucky | Home; Flags | no scan flag (a copy needs two places 300 km apart or 50 scans a day: the tests cover it) |
| 8 | Lucky | Season Scopes → a scope's People: the pool | a person working for another client, if any: "… for another client", no client or scope named |
| 9 | Collection Batch (Lucky) | A practice scope with a Collection Batch → New Collection Batch | the lots with "Village", the search box, "Choose the N shown"; a village and a search narrow the list |
| 10 | Lucky | Record Commercial Clearance, Market Export (then Cancel) | Export market and Destination country marked `*` |

Clean-up: the link stays revoked (its views are the record); the practice records stay (named "(test)").

Not checked on staging (the tests cover them): a scan flag and its public warning (`tests/51_buyer_link_scans.sql` §4–5;
`e2e/phase28.spec.ts`), the fair-use limit, a link that expires, another client's person refused
(`tests/50_client_isolation.sql`; S2 runs the probe on staging).

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 56b changes one read rule (openings) and the check itself; migration 56 adds three tables (`buyer_links`, `buyer_link_views`, `scan_flags`, each
with its change log and read rule), five columns of `scans` (the place; earlier scans keep none), functions, the
labs' read rule (a client's lab for its client; the state's labs for everyone, as before), and two patched functions
(the activation list, the roster pool's work elsewhere); it marks two fields of the Commercial form required. A link
that should not have been made is revoked; a scan flag raised wrongly is cleared with a reason. `buyer-file` can be
left deployed: without a live link it answers nothing.
