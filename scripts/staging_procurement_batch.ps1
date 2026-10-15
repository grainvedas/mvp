# PROCUREMENT AND COLLECTION BATCH, release 5 of the operator-stages plan (migration 52 and the app with it), on the
# practice system (staging). Veda, 15 October 2026, "ok great proceed" (decision G19); releases 1 to 4 are on staging
# since 15 Oct 2026, 19:54.
#   - C1 PROCUREMENT: where the lot was weighed (a collection point of the client, or at the farm), its GPS (taken from
#     the phone), who delivered it (the farmer, his family, a named agent); harvest date, condition and the scale slip
#     if known. The scope's Client Manager says whether where/GPS/who are asked (on for every scope, also those already
#     there; he can turn it off). The farmer card: GI land, sold this season against what it should give, practice, GI
#     area. Warnings above the crop's moisture limit and when the three readings are far apart.
#   - PRICE AND PAYMENT (where the Client Manager turns it on): price per quintal, paid or pending, how, and the
#     transaction ID only (never an account number), kept apart from the record and its ledger block: read only by the
#     person who recorded the lot and the client's Client Manager. The farmer's receipt.
#   - C2 COLLECTION BATCH (was "Village Batch"): the lots of one collection point; the villages, their shares and the
#     farmers from the lots (none typed); single origin; re-weighed total and its loss; weighted moisture. Works with
#     no network (the phone works it out as the save does).
#   - A13 the journey forward: from a lot to the records built on it, the packs and the seal.
#   - Found on staging (15 Oct): GPS typed key by key split too early; Places opened on Bihar for the Client Manager;
#     the parameter library listed "Moisture (%)" twice.
#   - Migration 52b: the first run (15 Oct, 22:43 IST) pushed 52 and stopped at S2: the smoke check's "public page data"
#     rule (the public page reads nothing of what a record worked out) caught 52's public page reading the batch's
#     villages there. 52b gives the villages through a helper. This run pushes 52b only (52, if still waiting, first).
# docs/FIX_LIST.md item 47; docs/RUNSHEET_procurement_batch.md.
# RUN IT ONLY WHEN VEDA HAS SAID SO: it changes the staging database and PUSHES TO THE MAIN BRANCH (Vercel builds the
# staging app from that push). It asks once, in words, first. The server functions are unchanged (build 2026-10-14).
#
# What it does:
#   S0 checks (tools, the tested files, the staging project, migration 52b waiting (with 52 before it, if still waiting),
#      the functions current) and asks.
#   S1 pushes it.
#   S1b reads back what the migration set: the scopes' two settings, the library's second names, no payment yet (read only).
#   S2 reads the project back: smoke check (49 rows; "statement logging" is a go-live step and does not stop it), the
#      new rules in place, the change log intact, the ledger audit, logins, functions.
#   S3 commits and pushes the app (Vercel builds it), and says how to see that Vercel built that commit.
# Nothing is deleted or rewritten. It refuses: any project but the staging one named below; a project that says it is
# production; files that are not the tested ones; any migration waiting other than 52b (and 52 before it).
#
# Usage (PowerShell, repository root), or double-click staging-procurement-batch.cmd:
#   powershell -ExecutionPolicy Bypass -File scripts\staging_procurement_batch.ps1
# It can be run again after a stop: a migration is not pushed twice.
# The record of the run: release-evidence\staging-procurement-batch-<time>.log (git-ignored). It reads no .env file and
# prints no key or password.
#
# Plain ASCII on purpose (Windows PowerShell 5.1 reads a script without a byte-order mark as ANSI). No function hands
# back a result: results go to $script: names (docs/FIX_LIST.md fault 36).
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$utf8 = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = $utf8 } catch { }
$env:GIT_TERMINAL_PROMPT = '0'
$stagingRef = 'zogkrhgzatplarimbmxk'          # the practice project; the only one this script will touch
$phrase = 'BATCH'
$migration = '20261027000100_procurement_batch.sql'   # on staging since 15 Oct 22:43 (the first run)
$fix = '20261027000200_public_batch_villages.sql'
$chain = @($migration, $fix)

$evidence = Join-Path $root 'release-evidence'
if (-not (Test-Path $evidence)) { New-Item -ItemType Directory -Path $evidence | Out-Null }
$log = Join-Path $evidence ("staging-procurement-batch-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:Out = ''
$script:Code = 0
$script:Results = New-Object System.Collections.Generic.List[string]
$script:DbPushed = $false
$script:Changed = $false

function Say([string]$text) {
  Write-Host $text
  [System.IO.File]::AppendAllText($log, $text + "`r`n", $utf8)
}
function Mark([string]$step, [string]$status, [string]$note) {
  $script:Results.Add(('{0,-4} {1,-8} {2}' -f $step, $status, $note))
}
function Summary() {
  Say ''
  Say '---- summary ----'
  foreach ($r in $script:Results) { Say $r }
  Say "record: $log"
}
function Stop-Run([string]$step, [string]$why) {
  Mark $step 'STOPPED' $why
  Say ''
  Say "STOPPED AT ${step}: $why"
  if ($script:DbPushed) { Say 'The database is on migration 52 (and 52b, once pushed); the staging app is the old one until S3 has run: run this again (it does not push the database twice). Meanwhile the old app cannot record Procurement in a scope that asks where the lot was weighed (every scope, until its Client Manager turns it off), nor a Collection Batch (it asks a village): wait for S3.' }
  else { Say 'Nothing was changed on the project.' }
  Summary
  Say 'RESULT: STOPPED'
  exit 1
}
# Runs one command line through cmd with no keyboard attached, shows and records every line, and leaves the text in
# $script:Out and the exit code in $script:Code.
function Run([string]$cmdline) {
  Say "> $cmdline"
  $buf = New-Object System.Collections.Generic.List[string]
  & cmd /c "$cmdline < NUL 2>&1" | ForEach-Object { $l = "$_"; Write-Host "  $l"; $buf.Add($l) }
  $script:Code = $LASTEXITCODE
  $text = ($buf -join "`n")
  $script:Out = [regex]::Replace($text, "\x1b\[[0-9;?]*[A-Za-z]", '')
  if ($buf.Count -gt 0) { [System.IO.File]::AppendAllText($log, (($buf | ForEach-Object { "  $_" }) -join "`r`n") + "`r`n", $utf8) }
  Say "  (exit code $($script:Code))"
}
function Query([string]$name, [string]$sql) {
  $file = Join-Path $evidence "$name.sql"
  [System.IO.File]::WriteAllText($file, $sql + "`n", $utf8)
  Run "$sb db query --linked -f release-evidence/$name.sql"
}
function Hash-Text([string]$path) {
  $t = [System.IO.File]::ReadAllText((Join-Path $root $path), [System.Text.Encoding]::UTF8)
  $t = $t.Replace("`r`n", "`n")
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $script:Hash = (($sha.ComputeHash($utf8.GetBytes($t)) | ForEach-Object { $_.ToString('x2') }) -join '')
}
# The app's files against scripts/tested_app_files.txt (the app as it was tested). $script:AppDiff lists every file
# that is missing, changed or new; empty means the app here is the tested one.
function Read-App() {
  $script:AppDiff = New-Object System.Collections.Generic.List[string]
  $script:AppCount = 0
  $list = 'scripts/tested_app_files.txt'
  if (-not (Test-Path (Join-Path $root $list))) { $script:AppDiff.Add("$list (missing)"); return }
  Hash-Text $list
  if ($script:Hash -ne $appListHash) { $script:AppDiff.Add("$list (changed)"); return }
  $known = @{}
  foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $root $list), [System.Text.Encoding]::UTF8)) {
    if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { continue }
    $path = $Matches[2]; $want = $Matches[1]
    $known[$path] = $true
    $script:AppCount++
    if (-not (Test-Path (Join-Path $root $path))) { $script:AppDiff.Add("$path (missing)"); continue }
    Hash-Text $path
    if ($script:Hash -ne $want) { $script:AppDiff.Add("$path (changed)") }
  }
  foreach ($dir in @('web/src', 'web/tests', 'web/public', 'supabase/functions')) {
    $base = (Join-Path $root $dir)
    foreach ($f in @(Get-ChildItem -Path $base -Recurse -File)) {
      $rel = $dir + '/' + ($f.FullName.Substring($base.Length + 1) -replace '\\', '/')
      if (-not $known.ContainsKey($rel)) { $script:AppDiff.Add("$rel (new)") }
    }
  }
}

Say "GrainVeda - Procurement and Collection Batch, release 5 (migration 52 and the app), on the practice system - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

# ---------------------------------------------------------------------------------------------------------------
# S0  pre-flight
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S0  pre-flight'
$sb = ''
if (Get-Command supabase -ErrorAction SilentlyContinue) { $sb = 'supabase' }
elseif (Test-Path (Join-Path $root 'web/node_modules/.bin/supabase.cmd')) { $sb = 'web\node_modules\.bin\supabase.cmd' }
elseif (Test-Path (Join-Path $root 'node_modules/.bin/supabase.cmd')) { $sb = 'node_modules\.bin\supabase.cmd' }
if (-not $sb) { Stop-Run 'S0' 'the supabase command was not found' }
foreach ($tool in @('node', 'git')) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Stop-Run 'S0' "the $tool command was not found on PATH" }
}
$tested = [ordered]@{
  "supabase/migrations/$fix" = '62cf7bdd20db44b655ab44ce1cd0c7afbb1c10104ebeccb29ee129ed2ea8ce18'
  "supabase/migrations/$migration" = 'f5183b77869ae7993761515b32d54d8066cace3eff367616218cdeb67ef9be3c'
  'tests/remote_smoke.sql' = 'b2ae8b26bb8584f4ff9fe0aeeaaa24239018f6334820356d8aabbcebf2888da5'
  'scripts/anchor_ledger.mjs' = '3d3cdfd71459f64df71c8166abeb1c1b28017c1dcf3db9527d07fc3b87f139ed'
  'scripts/templates/ledger-anchor.yml' = '9759bd65771371bebba38e4317a345852913a0c491647e57eed9b3095c284f80'
  'tests/remote_ledger_audit.sql' = 'b64cff8bc3df0fb67260e340198293bc21394e492ff0c156a123538a1e96472d'
}
$appListHash = '5ebacc06908d2a368e306e984fc810f01d4e5e643aacec14b7da90166d525bc1'
$changed = @()
foreach ($path in $tested.Keys) {
  if (-not (Test-Path (Join-Path $root $path))) { $changed += "$path (missing)"; continue }
  Hash-Text $path
  if ($script:Hash -ne $tested[$path]) { $changed += $path }
}
if ($changed.Count -gt 0) { Stop-Run 'S0' ("these files are not the tested ones: " + ($changed -join ', ')) }
Read-App
if ($script:AppDiff.Count -gt 0) {
  $shown = @($script:AppDiff | Select-Object -First 8)
  Stop-Run 'S0' ("the app's or the functions' files are not the tested ones: " + ($shown -join ', ') + " ($($script:AppDiff.Count) in all)")
}
Say "  ok  migrations 52 and 52b, the smoke check and the ledger audit are the tested files; the app's and functions' $($script:AppCount) files are the tested ones"
$refFile = Join-Path $root 'supabase/.temp/project-ref'
if (-not (Test-Path $refFile)) { Stop-Run 'S0' 'this folder is not linked to a Supabase project (supabase/.temp/project-ref is missing)' }
$ref = ([System.IO.File]::ReadAllText($refFile)).Trim()
if ($ref -cne $stagingRef) { Stop-Run 'S0' "this folder is linked to project '$ref', not to the practice project '$stagingRef'. This script is for the practice project only." }
Say "  ok  linked to the practice project $stagingRef"
Query 'q_environment' "select 'environment=' || app.environment() as e;"
if ($script:Code -ne 0) { Stop-Run 'S0' 'the linked project could not be asked which system it is' }
if ($script:Out -match 'environment=production') { Stop-Run 'S0' 'THE LINKED PROJECT SAYS IT IS PRODUCTION. This script is for the practice system only.' }
if ($script:Out -notmatch 'environment=staging') { Stop-Run 'S0' 'the linked project did not answer environment=staging' }
Say '  ok  the project says it is the practice system'
Run "$sb db push --linked --dry-run"
if ($script:Code -ne 0) { Stop-Run 'S0' 'the dry run failed' }
$waiting = @([regex]::Matches($script:Out, '\b\d{14}_[A-Za-z0-9_]+\.sql') | ForEach-Object { $_.Value } | Select-Object -Unique)
$dbDone = $false
if ($waiting.Count -eq 0) {
  $dbDone = $true
  $script:DbPushed = $true
  Say '  no migration is waiting: 52 and 52b were pushed before (S1 is skipped; S2 shows whether they are in place)'
} elseif ($waiting.Count -le 2 -and (($waiting -join ',') -eq (($chain | Select-Object -Last $waiting.Count) -join ','))) {
  Say ("  ok  waiting: " + ($waiting -join ', then ') + " (pushed in order)")
} else {
  Stop-Run 'S0' ("waiting to be pushed: " + ($waiting -join ', ') + ". Only $fix (with $migration before it) was expected.")
}
Run 'node scripts/check_functions.mjs'
if ($script:Out -notmatch 'FUNCTIONS DEPLOYED AND CURRENT') { Stop-Run 'S0' 'the server functions are not all current (read the lines above). This release does not deploy them.' }
Say '  ok  the six functions are current (build 2026-10-14; unchanged)'
Say ''
Say '  This will:'
if (-not $dbDone -and $waiting.Count -eq 2) { Say '   - push migration 52 to the practice database: where/GPS/who delivered (asked in every scope, the Client' }
if (-not $dbDone -and $waiting.Count -eq 2) { Say '     Manager can turn it off), price and payment kept apart (off until he turns it on), the farmer card, the' }
if (-not $dbDone -and $waiting.Count -eq 2) { Say '     Collection Batch of one place, the journey forward, the library''s second names, then:' }
if (-not $dbDone) { Say '   - push migration 52b: the public page names a Collection Batch''s villages through a helper (it reads nothing' }
if (-not $dbDone) { Say '     of what a record worked out). No record is changed or deleted.' }
Say '   - commit and PUSH TO THE MAIN BRANCH: Vercel builds the app with the new farm-gate form, the receipt, the payment'
Say '     panel, the Collection Batch by place (also offline), the journey forward, the scope''s two settings, and the'
Say '     three fixes found on staging (GPS typing, Places on the right state, one "Moisture" in the library).'
Say ''
$answer = Read-Host "  Only if Veda has said so: type  $phrase  and press Enter (anything else stops)"
[System.IO.File]::AppendAllText($log, "  typed: $answer`r`n", $utf8)
if ($answer -cne $phrase) { Stop-Run 'S0' 'not confirmed' }
Mark 'S0' 'OK' "practice project $stagingRef, environment staging, tested files, $($script:AppCount) app and function files; waiting: $(if ($dbDone) { 'nothing' } else { $waiting -join ' + ' }); functions current; confirmed in words"

# ---------------------------------------------------------------------------------------------------------------
# S1  push what is waiting (52b; 52 first if it is still waiting)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S1  push migration 52b (and 52 first, if waiting)'
if ($dbDone) {
  Say '  NOT RUN: nothing waiting'
  Mark 'S1' 'NOT RUN' 'migrations 52 and 52b were already pushed'
} else {
  Run "$sb db push --linked --yes"
  if ($script:Code -ne 0) { Stop-Run 'S1' 'db push failed (one transaction per migration: read the error above)' }
  $script:DbPushed = $true
  Run "$sb db push --linked --dry-run"
  if (@([regex]::Matches($script:Out, '\b\d{14}_[A-Za-z0-9_]+\.sql')).Count -gt 0) { Stop-Run 'S1' 'a migration is still waiting after the push' }
  Say '  ok  pushed; nothing is waiting'
  Mark 'S1' 'OK' (($waiting -join ' and ') + ' pushed')
}

# ---------------------------------------------------------------------------------------------------------------
# S1b  what the migration set: the scopes' two settings, the library's second names, payments (read only)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S1b  scopes, library, payments (read only)'
Query 'q_read52' "select 'fix: scopes=' || (select count(*) from public.scopes) || ' asking_where=' || (select count(*) from public.scopes where procurement_details_required) || ' recording_price=' || (select count(*) from public.scopes where record_price) || ' library=' || (select count(*) from public.quality_param_library) || ' library_second_names=' || (select count(*) from public.quality_param_library where alias_of is not null) || ' payments=' || (select count(*) from public.lot_payments) || ' batch_form=' || (select case when label like 'Collection Batch%' and not exists (select 1 from jsonb_array_elements(form_schema) f where f->>'key' = 'village') then 'new' else 'old' end from public.stage_definitions where stage_type = 'village_batch') || ' end' as result;"
if ($script:Code -ne 0 -or $script:Out -notmatch 'fix: .* end') { Stop-Run 'S1b' 'what the migration set could not be read (read the error above)' }
$fix = [regex]::Match($script:Out, 'fix: (.*?) end').Groups[1].Value
Say "  $fix"
if ($fix -notmatch 'recording_price=0 ') { Stop-Run 'S1b' 'a scope records the price before its Client Manager turned it on (read the line above)' }
if ($fix -notmatch 'payments=0 ') { Stop-Run 'S1b' 'payments are there before anyone recorded one (read the line above)' }
if ($fix -notmatch 'batch_form=new') { Stop-Run 'S1b' 'the Collection Batch form is not the new one (read the line above)' }
Mark 'S1b' 'OK' $fix

# ---------------------------------------------------------------------------------------------------------------
# S2  read the project back (read only)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S2  checks'
$checks = @('extensions', 'schema app', 'tables (15)', 'RLS on every table', 'stage_definitions (16)', 'ledger guard trigger',
  'footprint triggers', 'ledger chain intact', 'seed: Kalanamak crop', 'environment', 'demo data', 'api surface closed',
  'auth.uid mapping', 'public journey rpc', 'phase 3 objects', 'phase 4 objects', 'phase 4 triggers', 'ledger read by stage',
  'direct writes closed', 'evidence in the ledger', 'public page data', 'capture time, verdict preview',
  'a new client can be read back', 'identity layer objects', 'people moved to assignments', 'the two seats',
  'manager rules ask about the scope', 'people written only by their actions', 'once-a-day sign-in code', 'the admin oversees',
  'joiner HR data', 'onboarding at scale', 'hr by geography', 'HR holds no seat', 'state manager rules', 'crop registry', 'farmer register', 'rules and farmer ids', 'production safeguards', 'requirements', 'farmer corrections', 'operator template', 'trust numbers', 'packs and release', 'setup lists', 'procurement batch', 'statement logging', 'reminder round', 'nightly ledger check')
Run "$sb db query --linked -f tests/remote_smoke.sql"
if ($script:Code -ne 0) { Stop-Run 'S2' 'the smoke check could not be run' }
$text = $script:Out
$at = @{}
# A check's name is found only in the first column of the table (the start of a cell, then the cell's end), never inside
# another row's result: "hr by geography" says "... HR holds no seat" (13 Oct 2026: the first run stopped on that).
foreach ($x in $checks) {
  $m = [regex]::Match($text, '(?m)(?<=^[ \t]*[\u2502|][ \t]*)' + [regex]::Escape($x) + '(?=[ \t]*[\u2502|])')
  if ($m.Success) { $at[$x] = $m.Index } else { $at[$x] = -1 }
}
$missing = @($checks | Where-Object { $at[$_] -lt 0 })
# Two rows say how the project is set up, not what this run did: whether pg_cron schedules the nightly check and the reminders.
$standing = @('statement logging', 'reminder round', 'nightly ledger check')
$bad = @(); $warn = @(); $okCount = 0
$present = @($checks | Where-Object { $at[$_] -ge 0 } | Sort-Object { $at[$_] })
for ($i = 0; $i -lt $present.Count; $i++) {
  $x = $present[$i]
  $start = $at[$x] + $x.Length
  $end = $text.Length
  if ($i + 1 -lt $present.Count) { $end = $at[$present[$i + 1]] }
  $seg = $text.Substring($start, $end - $start)
  $seg = $seg -replace '^[^A-Za-z0-9]+', ''
  $seg = $seg -replace '^result[^A-Za-z0-9]+', ''
  $first = (($seg -split "`n")[0]).Trim()
  if ($first.Length -gt 90) { $first = $first.Substring(0, 90) }
  $first = ($first -replace '[^A-Za-z0-9).]+$', '')
  if ($seg -cmatch '^OK\b') { $okCount++ } elseif ($standing -contains $x) { $warn += "$x = $first" } else { $bad += "$x = $first" }
}
Say "  smoke rows read: $($present.Count) of 49, OK: $okCount"
foreach ($w in $warn) { Say "  NOT OK (standing, does not stop): $w" }
foreach ($b in $bad) { Say "  NOT OK: $b" }
if ($missing.Count -gt 0) { Stop-Run 'S2' ("smoke rows not found in the output: " + ($missing -join ', ')) }
if ($bad.Count -gt 0) { Stop-Run 'S2' ("smoke rows not OK: " + ($bad -join ' ; ')) }

Query 'q_rule52' "select 'rule52=' || case when to_regclass('public.lot_payments') is not null and to_regprocedure('app.save_lot_payment(uuid, jsonb)') is not null and to_regprocedure('app.farmer_card(uuid, uuid)') is not null and to_regprocedure('app.lot_forward(uuid)') is not null and to_regprocedure('app.reads_lot_payment(uuid, uuid)') is not null and to_regprocedure('app.batch_villages(uuid)') is not null and exists (select 1 from pg_trigger where tgname = 'footprints_a00_payment') and exists (select 1 from pg_trigger where tgname = 'footprints_z6_payment') and to_regclass('public.places') is not null and to_regclass('public.market_profiles') is not null and (select count(*) from pg_trigger where tgname = 'zz_change_log') = 42 and not exists (select 1 from app.verify_change_log()) then 'OK' else 'OLD' end || ' end' as result;"
if ($script:Out -notmatch 'rule52=OK end') { Stop-Run 'S2' 'the new rules are not in place, or the change log does not verify' }
Query 'q_after52' "select 'after: payments=' || (select count(*) from public.lot_payments) || ' places=' || (select count(*) from public.places) || ' packs=' || (select count(*) from public.packs) || ' change_log_lines=' || (select count(*) from public.change_log) || ' ledger_head=' || coalesce((select max(l.seq) from public.ledger l)::text, '-') || ' end' as result;"
$after = [regex]::Match($script:Out, 'after: (.*?) end').Groups[1].Value
Say "  after: $after"
Run "$sb db query --linked -f tests/remote_ledger_audit.sql"
if ($script:Code -ne 0 -or $script:Out -notmatch 'NO FINDINGS \(') { Stop-Run 'S2' "the ledger audit did not answer 'NO FINDINGS ('" }
$auditLine = [regex]::Match($script:Out, 'NO FINDINGS \([^)]*\)').Value
Run 'node scripts/check_logins.mjs'
if ($script:Out -notmatch 'NO LOGIN WITHOUT A PERSON') { Stop-Run 'S2' "'NO LOGIN WITHOUT A PERSON' was not printed" }
Run 'node scripts/check_functions.mjs'
if ($script:Out -notmatch 'FUNCTIONS DEPLOYED AND CURRENT') { Stop-Run 'S2' 'the functions are no longer all current' }
$smokeNote = "smoke $okCount of 49 OK"
if ($warn.Count -gt 0) { $smokeNote += '; NOT OK (standing): ' + ($warn -join ' ; ') }
Say '  ok  smoke, the new rule, ledger audit, logins, functions'
Mark 'S2' 'OK' "$smokeNote; the new rules: in place, the change log intact; $after; $auditLine; NO LOGIN WITHOUT A PERSON; FUNCTIONS DEPLOYED AND CURRENT"

# ---------------------------------------------------------------------------------------------------------------
# S3  commit and push
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S3  commit and push'
$envPath = '(?m)(^|[\\/\s"])\.env($|[.\s"-])'
Run 'git status --short'
if ($script:Code -ne 0) { Stop-Run 'S3' 'git status failed' }
if ($script:Out -match $envPath) { Stop-Run 'S3' 'git status shows a .env file. Nothing was committed. It must be git-ignored first.' }
Run 'git add -A'
if ($script:Code -ne 0) { Stop-Run 'S3' 'git add failed' }
Run 'git diff --cached --name-only'
$staged = @($script:Out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^warning:' -and $_ -notmatch '^The file will have' })
if (@($staged | Where-Object { $_ -match $envPath -or $_ -match '^release-evidence/' -or $_ -match '(^|/)backups/' -or $_ -match 'id-hmac-key' -or $_ -match '\.xlsx$' }).Count -gt 0) {
  Run 'git reset'
  Stop-Run 'S3' 'a .env file, a key, a backup, a spreadsheet or the run record was about to be committed. The staging was undone; nothing was committed.'
}
if ($staged.Count -eq 0) { Say '  nothing new to commit' }
else {
  $msg = Join-Path $evidence 'commit-message.txt'
  [System.IO.File]::WriteAllText($msg, "Procurement and Collection Batch, release 5 (migration 52): where, GPS and who delivered; price and payment kept apart, the receipt; the farmer card; the Collection Batch of one place, also offline; the journey forward; fixes found on staging (GPS typing, Places state, library duplicate)`n`nVeda, 15 Oct 2026 (the operator-stages brief, G19).`n`nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`nClaude-Session: https://claude.ai/code/session_01VSgZRQeaqm6gr2gjyiknfF`n", $utf8)
  Run 'git commit -F release-evidence/commit-message.txt'
  if ($script:Code -ne 0) { Stop-Run 'S3' 'git commit failed' }
}
Run 'git push'
if ($script:Code -ne 0) { Stop-Run 'S3' 'git push failed (run "git push" by hand)' }
Run 'git rev-parse --short HEAD'
$head = $script:Out.Trim()
Say "  ok  pushed (head $head, $($staged.Count) files in this commit)"
Mark 'S3' 'OK' "pushed, head $head ($($staged.Count) files)"

Summary
Say ''
Say "Vercel: in a few minutes its Deployments page must show commit $head as Ready. If it does not after 5 minutes (it missed"
Say "the push of 13 Oct): Deployments, the ... menu, Create Deployment, branch main. Then docs/RUNSHEET_procurement_batch.md, Afterwards."
Say 'RESULT: PROCUREMENT AND BATCH ON STAGING'
exit 0
