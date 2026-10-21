# Shared sourcing, own brand and the hooks, Phase 2 release 3: migration 66 (with 65) and the app, onto the practice system

Veda, 21 October 2026: the combined brief ("GrainVeda MVP: combined brief"), Phase 2 Parts E, F and G; "yes, I'll check
everything after completion". Item 62 in `docs/FIX_LIST.md`. Release 2 (migration 65, `docs/RUNSHEET_client_status.md`)
was built just before and not yet run: **this one script pushes 65 and then 66** (or 66 alone if 65 is there already).

- **Shared sourcing, split at the farmer (E).** Each client's scope buys directly from its own farmers: a farmer is in
  the state register once (by phone) and has a record with each client he consented to. A scope's procurement form
  offers only that client's farmers, and the server refuses a lot of a farmer registered only with another client.
- **"Member of" (E2).** On a farmer's page the Client Manager sets his FPO or aggregator (a registered sourcing partner).
  The procurement form then offers a filter "… members".
- **Sourcing partners (E3).** On a scope's page (Season Scopes → the scope) the Client Manager adds an FPO or aggregator
  from the registry, or registers one by its PAN (a business already known — even a client — gets the role on its own
  record, and nothing of its other roles is shown). The tick **"Partner agrees to be named publicly"**. At the farm gate
  "Procured through" is pre-filled with the scope's partner. The public page says **"Sourced through …"** only for a
  partner that agreed.
- **The season across clients (E4).** When a farmer's sales through GrainVeda this season, every client together, pass
  what his GI land plausibly gives, the person recording sees "This farmer has sold 1,150 kg through GrainVeda this
  season; his GI land (1 acre) plausibly gives about 1,000 kg." — a warning, never a refusal, never which client bought.
- **No cross-client visibility (E5).** ABFPO's login does not see ITC's procurement from its members, nor ITC's login
  ABFPO's own-brand scope; the partners, memberships and buyers' links are closed tables.
- **Prasaadam (F).** GrainVeda Private Limited goes through the same gates (the first-day test does it). Its public page
  says **"Operated by GrainVeda (own brand)"**.
- **Kept open (G).** Every scope has an entry point ("Farmer procurement", the only one selectable); every record is
  "farm-verified" (set by the server, all lots today) and the GI badge needs it; a domestic buyer with a GSTIN is linked
  silently to the registry by its PAN, a foreign one by country and importer ID — never shown to anyone in the app.

**Only when Veda has said so.** This pushes migrations 65 and 66 to the practice database and **pushes to the main
branch**. Production is not touched. Nothing is deleted or rewritten: migration 66 adds `scopes.entry_point`,
`footprints.farm_verified`, `entities.foreign_hash` (each with its default for the rows already there), the tables
`scope_partners`, `farmer_memberships`, `buyer_entities` (the buyers already there linked: new rows only), the procurement
form's field "Procured through"; replaced from their own text: the public lot page, `app.lot_gi_status`,
`app.procurement_crop_checks`.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-sourcing-hooks.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with 65 and 66 waiting (or 66 alone); the seven functions current. **Asks you to type `SOURCING`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migrations 65 then 66 | the push fails (each migration is one transaction) |
| S1b | Reads back (read only), two lines: `tables=new columns=new functions=new closed=yes status_rule=19 public_pages=yes clients: …` and `tables=new closed=yes farm_verified=yes entry_points=farmer_procurement procured_through_field=yes buyers=… linked=…` | anything is not as the migrations leave it |
| S2 | Smoke check **64** rows (new: `client status`, `sourcing and hooks`), the rules in place, the change log intact (68 tables), **one client and another** (`leaks=0 …`), the ledger audit, logins, functions | a row or a check is not `OK` (statement logging stands); any leak stops it before the app is pushed |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: CLIENT STATUS AND SOURCING ON STAGING` or `RESULT: STOPPED`. Then release 2's checks
(`docs/RUNSHEET_client_status.md`, Afterwards) and these.

## Afterwards (about 25 minutes, phone width; practice data, fake numbers only)

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Lucky (Client Manager) | Season Scopes → a Test Client UP scope → **Sourcing partners** → "Not in the list: register by PAN": Cooperative, a fake PAN with A as its 4th letter (`ZZZAB1234C`), "Practice FPO (test)" → Register → tick "Partner agrees to be named publicly" → Add | the partner listed, "named on the public page" |
| 2 | Lucky | Farmers → one of the scope's farmers → **Member of** → Practice FPO (test) → Save | saved |
| 3 | the procurement operator of that scope | My stages → Procurement | "Procured through: Practice FPO (test)" already chosen; "Show the members of" → "Practice FPO (test) members": that farmer only |
| 4 | the operators | record the lot, its QC and seal it as usual | — |
| 5 | anyone, signed out | the lot's public page | "Sourced through Practice FPO (test)"; no farmer's name |
| 6 | Lucky | the scope → Sourcing partners → "Do not name it" | the public page no longer names it |
| 7 | the admin | Overview, Clients (read only) | nothing new to do; the partners are the Client Manager's |

Not checked on staging (the tests cover them): a second client sharing a farmer (staging has one client with
people on its scopes), the season warning across clients, a client's login not seeing the other's procurement, the GI
badge refused to a lot not farm-verified (only a forced value can make one), the buyers' link to the registry
(`tests/61_sourcing_partners_hooks.sql`, 52 checks and 15 controls; `web/tests/release66.test.tsx`;
`e2e/phase38.spec.ts`).

## If something is wrong afterwards

Nothing was deleted or rewritten. A partner added by mistake is removed with a reason (kept, marked removed); a
membership is set to "None". A partner named by mistake: "Do not name it" (the page stops naming it at once).
