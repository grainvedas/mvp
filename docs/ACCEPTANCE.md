# Acceptance run (PRD §12)

The MVP is accepted when the five chain tests and all edge checks pass **in staging**, run by someone other than the
developer who built the feature, and Veda has done T1–T4 by hand. This page is the procedure. The verdict is produced by
`node scripts/release_gate.mjs`, which reads result files and assumes nothing.

| Part | Who | Time | Result goes to |
|---|---|---|---|
| A. Automated run, twice | a person who did not build it (Tarun or QA), on any computer with Node 22 | 15 min | `release-evidence/acceptance-1.json`, `acceptance-2.json` |
| B. Veda's own run of T1–T4 | Veda, on a phone | 45 min | `docs/ACCEPTANCE_SIGNOFF.md` |
| C. Gate | anyone | 1 min | `release-evidence/GATE.md` |

Staging = the development project with the demo seed. The app shows a gold strip **PRACTICE SYSTEM** on every screen
there, including the public page. Nothing in this procedure is run against production: the automated run refuses to
start if the database says it is production.

## A. Automated run (Playwright, against the deployed staging app)

Needs: the repository, `.env.local` (staging project URL + public key) and `.env.demo-logins` (demo passwords) in the
repository root. Both are git-ignored; ask Antigravity for a copy, never send them by chat or e-mail.

```powershell
cd web
npm ci
npx playwright install chromium
$env:ACCEPTANCE_URL = 'https://<staging address>'
$env:ACCEPTANCE_REPORT = '../release-evidence/acceptance-1.json'; npx playwright test -c playwright.acceptance.config.ts
$env:ACCEPTANCE_REPORT = '../release-evidence/acceptance-2.json'; npx playwright test -c playwright.acceptance.config.ts
```

Expect, both times: `5 passed`. The first lines name the app address and the database it checked. No retries are
allowed: a chain that passes only on a second attempt is a failure to report, with the HTML report
(`npx playwright show-report playwright-report/acceptance`).

What each test proves, in the PRD's words:

| Test | PRD "passes when" | How the test checks it |
|---|---|---|
| T1 | Lot seals; verify page shows farmer, moisture, QC result; ledger has ≥ 5 blocks | Three people record, verify, seal; the public page shows "Grown by Sita Devi, Itwa", moisture 11.9 %, both verdicts, never the phone number; the Client Manager's journey has ≥ 5 ledger blocks incl. the seal. Also measures the public page as a first visit on throttled 3G (< 3 s, < 200 KB) |
| T2 | Three grade lots appear downstream, parent hidden; each seals independently; A+B+C+reject+loss = input enforced | A wrong sum is refused before review; the three lots are in the lab's list and the run is not; grade A and grade B are tested and sealed separately, two different codes |
| T3 | Domestic-only lot is hidden from export sale; export-passed lot visible; override makes a failed lot visible with audit entry | At Commercial the 12.1 % lot offers only "domestic" (and an export sale sent straight to the API is refused); the 11.9 % lot offers export; after the Client Manager's override with a reason the first lot offers export, the ledger row names him, and the public page says "export approved with a recorded reason" |
| T4 | Batch code mandatory; transit loss carried to qty_out; verify page shows full journey | Packing cannot be reviewed without a batch code; shipment forwards 78.5 kg of 79; the public page shows milling, batch, destination, seal; 12 labels carry the batch code |
| T5 | Grading operator cannot create at Sorting; operator in scope A sees nothing from scope B; Farmers hidden from non-procurement operators; QR gated to assigned sealer | Each "cannot" is checked on the screen **and** by calling the API with that person's own login: the insert, the verify, the seal are refused; other scopes, other clients, farmers and the ledger return zero rows |

## B. Veda's own run of T1–T4 (by hand, on a phone)

Open the staging address in Chrome on an Android phone. Passwords are in `.env.demo-logins` on Antigravity's computer.
Operators sign in on the **Phone** tab with `+91 00000 000NN` (or on the **Email** tab, if they were given an email); managers on the **Email** tab.
The demo operators hold stages in several places, so after signing in they are asked **Where are you working now?**
Tap the place; the first screen then shows a card per stage held there, "My stage: Procurement" with the scope's name
under it. "Procurement · Siddharthnagar" below means: choose Siddharthnagar, then tap that card. For the next place:
**Change where I am working**. The phone remembers the last choice. (On a laptop the same stage is also in the menu on the left
under **Operations**, once the scope is chosen in the **Scope** box of the top bar.) A record's status chip reads
**Pending verification** until the next stage has verified it, then **Approved**.

| Step | Sign in as | Do | You should see |
|---|---|---|---|
| **T1** scope Siddharthnagar | | | |
| 1 | …05 Procurement | Procurement · Siddharthnagar → Sita Devi, gross 150, 1 bag, tare 2.5, moisture 11.9 / 11.8 / 12.0, a photo → Review → Save | "147.5 kg" at review and after saving; a code `PRSDM-KNM-KH26-P-…` |
| 2 | …06 QC | Quality Control · Siddharthnagar → tap the lot → tick every check → Verify → Record QC: sample 0.5, moisture 11.9, broken 2, foreign 0.2 | Lot quantity is already 147.5; saved with 147 kg |
| 3 | …07 QR | QR Activation · Siddharthnagar → tap the lot → tick → Verify → **Activate and seal** | A QR code `GV-…` |
| 4 | nobody (sign out) | Scan the QR with the phone camera, or open the public page link | Sita Devi, Itwa; Lab tested with moisture 11.9 %; domestic passed, export passed; no phone number |
| **T2** scope Gorakhpur | | | |
| 5 | …05 | Procurement · Gorakhpur → Mohan Lal, gross 180, 1 bag, tare 2 | 178 kg |
| 6 | …09 Sorting | verify → Record Sorting: reject 6 (reason "discoloured" 6), loss 2 | 170 kg |
| 7 | …10 Grading | verify → Grade A 100, B 50, C **25**, reject 3, loss 2 | Refused in red: the parts do not add up to 170 |
| 8 | …10 | change C to 15, tick **Split into grade lots** → Save | Three lots listed: …-A (100 kg), …-B (50 kg), …-C (15 kg) |
| 9 | …06 | Quality Control · Gorakhpur | The three grade lots are waiting; the grading run itself is not in the list |
| 10 | …06, …07 | QC then seal grade A; QC then seal grade B | Two different QR codes; each public page shows only its own grade |
| **T3** scope Basti | | | |
| 11 | …05, …06, …08 | Ram Achal 124/2/2 → QC moisture **12.1** → Milling 80 rice / 30 bran / 9 loss | QC record: Domestic Pass, Export Fail |
| 12 | …11 Commercial | verify the milled lot → Record Commercial Clearance | "Lab result: domestic passed · export not met"; Market offers **only domestic** |
| 13 | Client Manager | open the QC record → Override the export verdict → reason → confirm | "Override: export · …"; Export still shows Fail; ledger row "Override" with your name |
| 14 | …11 | the same milled lot again | Market now offers export; "export approved with a recorded reason" |
| 15 | …07 | seal the export sale; open the public page | "export not met" **and** "export approved with a recorded reason" |
| **T4** scope Basti mill | | | |
| 16 | …05 → …06 → …08 | Suresh Yadav 199/2/2 → QC 11.8 → Milling 130 / 54 / 10 | Milling warns "yield below threshold" and still saves |
| 17 | …09 Packing | 100 × 1 kg, 58 × 0.5 kg, wastage 1, **no batch code** | Review stays disabled; "Batch code" is listed as missing |
| 18 | …09 | add a batch code → Save | 129 kg |
| 19 | …11 | 50 kg domestic to one buyer, then **Another … from this lot**: 79 kg export | "79 kg still available" after the first sale |
| 20 | …14 Shipment | verify the export sale → transit loss 0.5, vehicle, date, destination; then on the record page **Add a photo or document** | 78.5 kg forwarded; the document shows "file matches its fingerprint" |
| 21 | …07 | seal → Print labels | 12 labels with the batch code; public page: Milled, Batch, Shipped to …, Sealed |

Then one more thing only a real phone can show (run-sheet step B7): sign in as `…05`, open Procurement · Gorakhpur once,
switch on airplane mode, leave the phone for more than an hour, open the app, record two lots, switch airplane mode
off. The app must open into the form (not the sign-in screen) and both lots must go out by themselves with consecutive
codes.

Fill in `docs/ACCEPTANCE_SIGNOFF.md` (one line per test, and the line for the day without network) and commit it.
Anything that did not match goes into `docs/FIX_LIST.md` with the step number and a screenshot.

## C. Gate

```powershell
node scripts/release_gate.mjs
```

Prints one row per release criterion, and two rows of supporting evidence (work without network; the ledger audit),
with PASS, REHEARSAL (green on the local stack only), PENDING (waiting for a person), NOT RUN (no result file) or FAIL,
and writes `release-evidence/GATE.md`. Go-live needs every row at PASS.
`docs/RUNSHEET_phase4.md` lists the command that produces each result file.
