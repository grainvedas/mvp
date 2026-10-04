# Running a season on GrainVeda: handbook for the admin and managers

What to do when something ordinary happens, in the app's own words. The database enforces every rule named here; a
screen that lets you tap something the rule forbids will show the database's refusal, in plain words, and nothing is
saved. If a step here does not match what you see, write it into `docs/FIX_LIST.md`.

## Who does what

| Role | Signs in with | Sees | Does |
|---|---|---|---|
| Admin (Veda) | e-mail | everything | states, crops and their limits, clients, State Managers; Health page; backups |
| State Manager | e-mail | clients of the state | verifies farmers and issues Farmer IDs; changes or deactivates a verified farmer; Health page |
| Client Manager | e-mail | the client's scopes | opens scopes, assigns people to stages, resets passwords, overrides an export verdict, withdraws wrong records, resolves flags |
| Client View | e-mail | the client's scopes, read-only | dashboards, journey export, can raise a flag |
| Operator | phone | own stage and the stage directly behind it | records at the own stage, verifies what arrives |

Managers are signed out 12 hours after signing in; operators stay signed in for 30 days on their phone.
A manager may act at any stage when needed. The ledger marks such an act as supervisory, with the manager's name.

## Start of a season

1. Admin: **Crop Registry** → check the quality limits (domestic and export). Limits are copied into a scope when it is
   activated; changing them later does not change running scopes.
2. Admin: **Users & Roles** → State Manager. State Manager or admin: **Users & Roles** → Client Manager for the client.
3. Client Manager: **Season Scopes → New scope** → season and place → crop → chain → **People**: one person per stage, a
   different person at neighbouring stages (nobody verifies a lot they recorded). **+ new person** makes the login and
   shows a temporary password once: give it in person.
4. **Activate scope**. From here the chain, the place and the limits are frozen; people can still be assigned and
   removed, and each such change is written to the ledger.
5. Farmers: operators or managers add them (**Farmers → New farmer**, or **Import from Excel**), then
   **Submit for verification**. The State Manager verifies; only then does the farmer get a Farmer ID and appear at
   Procurement.

Every new person: first sign-in with the temporary password → the app asks for an own password (8 characters or
more) before anything else.

## Every day

| Look at | Healthy | If not |
|---|---|---|
| **Health** (admin, State Manager) → Ledger check | green, checked last night | § Ledger check failed |
| Health → Waiting longest to be verified | nothing older than 2 days | call the operator of the next stage: a lot nobody verifies cannot move |
| Health → Problems reported by phones | empty | "Sync refused": the operator's phone has a save the database refused; they see the reason under **Saved on phone**. Anything else: copy the line into the fix list |
| **Flags & Disputes** | none open | § Flags |
| **Dashboard** → choose the scope (selector in the top bar; on a phone, on the first screen) | action queue empty, no bottleneck line under the season flow | the queue says what waits: records nobody verified, stages with nobody assigned, open flags |
| the same screen → **Full dashboard and exports** | activity every working day | no activity where there should be: phone the operator |

## People

| Situation | Who | Do |
|---|---|---|
| Forgot the password | Client Manager (State Manager for a Client Manager, admin for a State Manager) | **Users & Roles** → the person → **Reset password** → tap again to confirm → a new temporary password is shown once. The old password stops working at once; a phone that is still signed in with it is signed out within the hour (to cut a phone off at once: Deactivate) |
| Phone lost or stolen | the same | **Users & Roles → Deactivate** first: from that moment the lost phone gets nothing more from the database and can save nothing, and the copy it keeps for offline work is erased the next time that phone reaches the server. Until then that copy can still be read on the phone itself (for a Procurement operator: the client's farmer list with phone numbers), so **every operator phone needs a screen lock**. When the person has a phone again: **Activate**, then **Reset password**. Saves that were still waiting on the lost phone are lost; the person records those lots again from the paper slip |
| Left the job | Client Manager | **Users & Roles → Deactivate**. Their records stay, with their name |
| Works at another stage now | Client Manager | **Season Scopes** → the scope → People → **Remove** at the old stage, **Assign existing…** at the new one. Both acts are in the ledger |
| A stage has nobody for a day | Client Manager | assign a second person to that stage, or do the step yourself (it is recorded as supervisory) |

Nobody can reset their own password this way, and nobody can reset someone ranked above them. To change your own:
**My account → Change password**.

## A record is wrong

| The record is… | Who | Do |
|---|---|---|
| pending (not yet verified by the next stage), and is a Procurement, Lot Inward or processing record | the operator who recorded it, or a manager | open the record → **Correct this record** → fix → review → save. The correction is the same record; the ledger keeps both versions |
| a lab record (QC), a Village Batch, a grading run that was split, or a grade lot | Client Manager | these are not corrected in place, because a verdict, a batch or grade lots were derived from them. Open the record → **Withdraw…** → reason → **Withdraw this record**. Then the operator opens the withdrawn record → **Record the replacement** (the form opens with the old values) |
| already verified | Client Manager | **Withdraw…** with a reason, then the operator records it again. Verified records are never edited |
| already built on (the next stage has recorded from it) | Client Manager | withdraw the later records first, newest first; the app names them |
| sealed | nobody | a sealed lot is never withdrawn. Raise a flag on it and call the admin |

Withdrawing deletes nothing: the record stays, marked withdrawn, with your reason and name; the lot behind it opens
again; the replacement shows "Replaces …" to whoever verifies it, and in the journey export.

## Flags

Anyone who can see a record can raise a flag on it (record page → **Raise a flag**). **This is also how an arrival
is refused**: the arrival check can verify a lot, it has no "Reject". The receiver does not verify, opens the full
record from the arrival check, raises a flag saying what is wrong and tells the manager; the sender corrects the
record while it is pending, or the manager withdraws it ("A record is wrong", above). A flag cannot be edited or
deleted. A manager closes it with **Resolve** (the matter was dealt with) or **Dismiss** (it was not a problem); both
are written to the ledger. **A lot cannot be sealed while any record in its history has an open flag**: the QR operator
sees which record; when the flag is closed the lot is still in the operator's list and seals.

## Lab verdict and export

The lab's verdict is derived from the readings against the crop's limits; nobody types it. The technician sees it
before saving ("Lab result if saved now", with the reading that is over a limit named), and the saved record says the
same. At Commercial Clearance a
lot that did not pass the export limits is offered for domestic sale only. A Client Manager can open export for that
lot: QC record → **Override the export verdict** with a reason. The failed verdict stays visible, the override is in
the ledger with the manager's name, and the public page says "export approved with a recorded reason".

## Photos and documents

Procurement takes a photo in the form; Shipment takes one document in the form. More can be added at any time on the
record page: **Add a photo or document → Attach** (a photo or a PDF, up to 15 MB). Each file's fingerprint (SHA-256)
goes into the ledger; the record page re-checks the stored file against it every time it is opened
("file matches its fingerprint"). A stored file is never replaced.

## The seal is refused

| The app says | Means | Do |
|---|---|---|
| open flag on … | a record in the lot's history has an open flag | a manager resolves or dismisses it; then seal |
| … is not verified | a stage behind was never verified | the operator of the stage after it verifies |
| no QC record behind this lot / QC verdict is pending | the lot was not tested | the lab records QC |
| may not create at stage qr_activation | you are not the QR operator of this scope | the assigned QR operator, or a manager |

A refused seal saves nothing; the lot stays in the list.

## Working without a network

Procurement and the processing stages can be saved with no connection, for as long as the day lasts: the phone keeps
the save (**Saved on phone**) and sends it when the network is back, in the order the lots were captured. One
condition: the operator has opened that stage once, with a network, on that phone. That is when the form, the farmer
list and the lots waiting are put on the phone. Verifying an arrival, correcting a record and sealing need a
connection.

A record saved on the phone keeps **the time it was saved there**; that is the time shown as "Recorded" on the record,
in the lists, in the journey, on the public page and in the exports (`recorded_at`). When it waited more than two
minutes the record also says "kept on the phone, sent …", and the exports carry the server's time in
`received_by_server_at`. The time is the phone's own clock: keep operator phones on automatic network time. A time
more than 31 days old or more than 5 minutes ahead of the server is not believed: the server uses its own time and
puts a warning on the record ("phone clock not plausible").

| Situation | What the app does |
|---|---|
| No network at all | Opens from the phone at once, also hours after the last contact. The button says **Save on this phone** |
| A signal that connects but carries nothing | A screen opens from the phone's copy after about 8 seconds; a save with no answer after 30 seconds is kept on the phone instead |
| The answer to a save got lost on the way back | The phone keeps the save and sends it again; the database recognises it by its save id and does not store it twice |
| The network is back | Waiting saves go out by themselves: usually at once, about a minute later at the latest |
| The record went through, its photo did not | The photo waits on the phone with the save and is attached when the network is back |
| The database refuses a save at sync | It stays on the phone marked "needs attention", with the reason; the operator taps **Fix and save again** |
| Sign out with no network | Allowed, after a warning: nobody can sign in again until the network is back. Waiting saves stay on that phone and go out when the same person signs in there again |
| The manager reset the password, or deactivated the person, while the phone was out of reach | When the phone is back in coverage it shows the sign-in screen (reset) or "no GrainVeda user is linked" (deactivated). Nothing it captured meanwhile is sent without a valid login; after a reset the saves go out once the person signs in with the new password |

## Farmers

Drafts can be edited by whoever works with farmers. After submission only a State Manager (or the admin) changes a
farmer; every change to a verified farmer is in the ledger with the old and new values (a changed phone number is noted
as "changed", the number itself is not kept there). **Deactivate** removes the farmer from Procurement's list; lots
already bought keep their farmer.

## Ledger check failed

The ledger check recomputes every block every night and whenever the admin taps **Check the ledger now**. A failure
means a row of the ledger was changed outside the app; the app itself cannot do that.

1. Do not restore anything yet. Tell the QR operators to stop sealing.
2. Health page: note the block number and the problem. Run `tests/remote_ledger_audit.sql` (read-only) and keep its
   output.
3. Call Veda and whoever has database access. Find out who touched the database (Supabase dashboard → logs).
4. Decide with the evidence in hand: if a block was altered, the last backup before the change is the reference
   (`docs/RESTORE.md`).

## End of the season

When every lot of a scope is sealed or accounted for (Dashboard: nothing left "available" that should move), the scope
is closed so nothing more can be recorded in it. There is no button for this in the MVP: the admin runs, in the
Supabase SQL editor, `update public.scopes set status = 'closed' where id = '<scope id>';`. **A closed scope cannot be
reopened and nothing in it can be sealed afterwards**, so check the dashboard first.

## What nobody can do, by design

Delete a record, a flag, a seal or a ledger block. Edit a verified record. Change a quantity, a code or a date after
saving. Verify one's own record. Seal a lot with an open flag or an unverified stage. Sell for export a lot the lab
failed, without a manager's recorded override. Read another client's data. Read, as an operator, any stage but one's
own and the one behind it, including through the ledger. Turn a practice system into production from the app.
