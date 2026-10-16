# SHARE WITH THE BUYER, SCANS AND COPIES, release 9 of the operator-stages plan, the last (migrations 56 and 56b, the
# app and the new server function buyer-file), on the practice system (staging). Veda, 16 October 2026, "proceed with 56"
# (decision G19); releases 1 to 8 are on staging since 16 Oct 2026, 07:22.
#   - PART F, THE BUYER'S LINK: the Client Manager (or a manager of the scope) shares a sale or a shipment with its
#     buyer: a link that lasts 7, 30 or 90 days, shown once, sent by WhatsApp or email. The buyer opens it without
#     signing in: the order, the shipments' papers, the lab results per market, the export documents, the chain, the
#     villages' shares; never a price, a farmer's name or another buyer's order. He opens the lab report and the
#     documents (through buyer-file, a two-minute download) and downloads the evidence pack. Every view is listed for
#     the Client Manager; a link is revoked with a reason.
#   - D5-D6, SCANS: every scan of a pack's or a lot's QR is counted with its approximate place (city, region, country,
#     a point rounded to about 10 km; nothing of the person) and a fair-use limit. A pack's code scanned far apart or
#     very often is flagged for the scope's managers ("Needs my action", the Flags page) and its public page warns
#     until it is cleared.
#   - Veda's points: one client's data is never another's (four leaks found and closed; the full check runs in S2,
#     read only); the Collection Batch filters its lots by village, by a farmer or a lot code. Three fixes of release 8.
#   - 56b: the first run (16 Oct 09:59) stopped at S2: the isolation check found another client's OPENINGS readable by
#     every Client Manager. 56b closes it; this run pushes 56b (and 56, where it is not in yet) and checks again.
#   - The app again (16 Oct, after 10:23): on staging the scan's place was not recorded (the Vercel project has no
#     settings of its own, so web/api/scan.js answered not configured); it now uses the project the page talks to.
#     With nothing waiting, this run deploys buyer-file again, checks, and pushes the app.
# docs/FIX_LIST.md item 51; docs/RUNSHEET_buyer_link_scans.md.
# RUN IT ONLY WHEN VEDA HAS SAID SO: it changes the staging database and PUSHES TO THE MAIN BRANCH (Vercel builds the
# staging app from that push), and it deploys one new server function (buyer-file). It asks once, in words, first.
#
# What it does:
#   S0 checks (tools, the tested files, the staging project, migrations 56 and 56b waiting (or 56b alone),
#      the six functions current) and asks.
#   S1 pushes them. S1c deploys the server function buyer-file (after the migration: it calls app.buyer_file).
#   S1b reads back what the migration set: the Commercial form, no link, scan flag or scan place yet (read only).
#   S2 reads the project back: smoke check (54 rows; "statement logging" is a go-live step and does not stop it), the
#      new rules in place, the change log intact, ONE CLIENT'S DATA NOT VISIBLE TO ANOTHER (app.isolation_probe, read
#      only), the ledger audit, logins, functions.
#   S3 commits and pushes the app (Vercel builds it), and says how to see that Vercel built that commit.
# Nothing is deleted or rewritten. It refuses: any project but the staging one named below; a project that says it is
# production; files that are not the tested ones; any migration waiting other than 56 and 56b.
#
# Usage (PowerShell, repository root), or double-click staging-buyer-link-scans.cmd:
#   powershell -ExecutionPolicy Bypass -File scripts\staging_buyer_link_scans.ps1
# It can be run again after a stop: a migration is not pushed twice; the function may be deployed again.
# The record of the run: release-evidence\staging-buyer-link-scans-<time>.log (git-ignored). It reads no .env file and
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
$phrase = 'BUYER'
$migration = '20261031000100_buyer_link_scans.sql'
$second = '20261031000200_openings_isolation.sql'
$order = @($migration, $second)
$six = @('create-user', 'reset-password', 'ledger-check', 'daily-code', 'id-numbers', 'invite')
$sixBuild = '2026-10-14'
$newBuild = '2026-10-16'

$evidence = Join-Path $root 'release-evidence'
if (-not (Test-Path $evidence)) { New-Item -ItemType Directory -Path $evidence | Out-Null }
$log = Join-Path $evidence ("staging-buyer-link-scans-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
  if ($script:DbPushed) { Say 'The database has the new migrations; the staging app is the old one until S3 has run: run this again (it does not push a migration twice). Meanwhile the old app works as before (it offers no buyer link and counts scans without a place): wait for S3.' }
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
  foreach ($dir in @('web/src', 'web/tests', 'web/public', 'web/api', 'supabase/functions')) {
    $base = (Join-Path $root $dir)
    foreach ($f in @(Get-ChildItem -Path $base -Recurse -File)) {
      $rel = $dir + '/' + ($f.FullName.Substring($base.Length + 1) -replace '\\', '/')
      if (-not $known.ContainsKey($rel)) { $script:AppDiff.Add("$rel (new)") }
    }
  }
}

Say "GrainVeda - Share with the buyer, scans and copies, release 9 (migrations 56 and 56b, the app, buyer-file), on the practice system - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

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
  "supabase/migrations/$second" = 'e8d69ba6ce2b0e0e829cf60d9dc86f1020467424661383a207656956b53e8976'
  "supabase/migrations/$migration" = '8c9d22bf7c24f71afbe7e47c97abcee940d7c83d8a07e937e0565940cc25b187'
  'scripts/check_functions.mjs' = '7d86813aee68319d0f1506aaf447a56fd7be4ebb88d07eda0746943521ce9e3d'
  'tests/remote_smoke.sql' = '74149244124ab0d54e82c7aeaa80ae7b9c907bf1ba658a8c4e7916ff6b4cb89f'
  'scripts/anchor_ledger.mjs' = '3d3cdfd71459f64df71c8166abeb1c1b28017c1dcf3db9527d07fc3b87f139ed'
  'scripts/templates/ledger-anchor.yml' = '9759bd65771371bebba38e4317a345852913a0c491647e57eed9b3095c284f80'
  'tests/remote_ledger_audit.sql' = 'f45f90d2e2f6c2a424ba56a7bbbd15bb68da4cb6a7015fbd22472ce531a3cdbf'
}
$appListHash = 'bee3f5a1115bf4a3fb166cc8d2351eeb02c50cc8a097f7f6b8088795b8a0ae7d'
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
Say "  ok  migrations 56 and 56b, the smoke check and the ledger audit are the tested files; the app's and functions' $($script:AppCount) files are the tested ones"
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
  Say '  no migration is waiting: 56 and 56b were pushed before (S1 is skipped; S2 shows whether they are in place)'
} elseif ($waiting.Count -le 2 -and (($waiting -join ',') -eq (($order | Select-Object -Last $waiting.Count) -join ','))) {
  Say ("  ok  waiting: " + ($waiting -join ', then ') + " (pushed in order)")
} else {
  Stop-Run 'S0' ("waiting to be pushed: " + ($waiting -join ', ') + ". Only $second (with $migration before it, if it is not in yet) was expected.")
}
# The six functions of before must be current; buyer-file is new (S1c deploys it): "not deployed" before the first run
Run 'node scripts/check_functions.mjs'
$sixOk = @($six | Where-Object { $script:Out -match ('(?m)^ok\s+' + [regex]::Escape($_) + ': build ' + [regex]::Escape($sixBuild)) })
if ($sixOk.Count -ne $six.Count) { Stop-Run 'S0' ('the six server functions of before are not all current (read the lines above): ' + (($six | Where-Object { $sixOk -notcontains $_ }) -join ', ')) }
if ($script:Out -match ('(?m)^ok\s+buyer-file: build ' + [regex]::Escape($newBuild))) { Say '  ok  the six functions are current (build 2026-10-14); buyer-file is deployed already (S1c deploys it again)' }
elseif ($script:Out -match '(?m)^FAIL\s+buyer-file: ') { Say '  ok  the six functions are current (build 2026-10-14); buyer-file is not deployed yet (S1c deploys it)' }
else { Stop-Run 'S0' 'check_functions did not say anything about buyer-file (is scripts/check_functions.mjs the tested one?)' }
Say ''
Say '  This will:'
if (-not $dbDone) { Say '   - push migration 56b (another client''s openings no longer readable by every Client Manager) and, if it' }
if (-not $dbDone) { Say '     is not in yet, migration 56 first: buyer links (made, viewed, revoked), scans with their' }
if (-not $dbDone) { Say '     approximate place, scan flags (far apart, very often) and the public warning, three leaks between' }
if (-not $dbDone) { Say '     clients closed (a lab, a scope''s activation list, the roster pool), an export sale''s market and' }
if (-not $dbDone) { Say '     destination marked required. Earlier scans keep what they have. No record is changed or deleted.' }
Say '   - deploy the server function buyer-file (a buyer opens a file of his page; no sign-in, a two-minute download).'
Say '   - commit and PUSH TO THE MAIN BRANCH: Vercel builds the app with "Share with the buyer" on a sale and a'
Say '     shipment, the buyer''s page, scans with their place (web/api/scan.js), the scan flags on the Flags page and in'
Say '     "Needs my action", the copy warning on a pack''s page, the Collection Batch''s lot filters and three fixes.'
Say ''
$answer = Read-Host "  Only if Veda has said so: type  $phrase  and press Enter (anything else stops)"
[System.IO.File]::AppendAllText($log, "  typed: $answer`r`n", $utf8)
if ($answer -cne $phrase) { Stop-Run 'S0' 'not confirmed' }
Mark 'S0' 'OK' "practice project $stagingRef, environment staging, tested files, $($script:AppCount) app and function files; waiting: $(if ($dbDone) { 'nothing' } else { $waiting -join ' + ' }); functions current; confirmed in words"

# ---------------------------------------------------------------------------------------------------------------
# S1  push migrations 56 and 56b (or 56b alone)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S1  push the waiting migrations'
if ($dbDone) {
  Say '  NOT RUN: nothing waiting'
  Mark 'S1' 'NOT RUN' 'migrations 56 and 56b were already pushed'
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
# S1c  deploy the server function buyer-file (it calls app.buyer_file, which migration 56 made)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S1c  deploy the server function buyer-file'
Run "$sb functions deploy buyer-file --no-verify-jwt"
if ($script:Code -ne 0) { Stop-Run 'S1c' 'deploying buyer-file failed (read the error above); the six functions of before are unchanged' }
$script:Changed = $true
Run 'node scripts/check_functions.mjs'
if ($script:Out -notmatch 'FUNCTIONS DEPLOYED AND CURRENT') { Stop-Run 'S1c' 'the functions are not all current after the deploy (read the lines above)' }
Say "  ok  buyer-file build $newBuild; the six of before build $sixBuild"
Mark 'S1c' 'OK' "buyer-file deployed (build $newBuild); FUNCTIONS DEPLOYED AND CURRENT"

# ---------------------------------------------------------------------------------------------------------------
# S1b  what the migration set: the Commercial form, no link, scan flag or scan place yet (read only)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S1b  the Commercial form, nothing shared or flagged yet (read only)'
Query 'q_read56' "select 'fix: commercial_form=' || (select case when exists (select 1 from jsonb_array_elements(form_schema) f where f->>'key' = 'market_code' and f->>'required' = 'true' and f->'shown_if'->>'market' = 'export') and exists (select 1 from jsonb_array_elements(form_schema) f where f->>'key' = 'destination_country' and f->>'required' = 'true') then 'new' else 'old' end from public.stage_definitions where stage_type = 'commercial') || ' stages=' || (select count(*) from public.stage_definitions) || ' links=' || (select count(*) from public.buyer_links) || ' link_views=' || (select count(*) from public.buyer_link_views) || ' scan_flags=' || (select count(*) from public.scan_flags) || ' scans=' || (select count(*) from public.scans) || ' scans_with_place=' || (select count(*) from public.scans where country is not null or lat is not null) || ' end' as result;"
if ($script:Code -ne 0 -or $script:Out -notmatch 'fix: .* end') { Stop-Run 'S1b' 'what the migration set could not be read (read the error above)' }
$fix = [regex]::Match($script:Out, 'fix: (.*?) end').Groups[1].Value
Say "  $fix"
if ($fix -notmatch '^commercial_form=new stages=17 ') { Stop-Run 'S1b' 'the Commercial form is not the new one (read the line above)' }
# (only while the migrations are new: once they are in and the app is live, people make links and scans have places)
if (-not $dbDone -and $fix -notmatch 'links=0 link_views=0 scan_flags=0 scans=\d+ scans_with_place=0$') { Stop-Run 'S1b' 'a link, a view, a scan flag or a scan with a place is there before anyone made one (read the line above)' }
Mark 'S1b' 'OK' $fix

# ---------------------------------------------------------------------------------------------------------------
# S2  read the project back (read only)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S2  checks'
$checks = @('extensions', 'schema app', 'tables (15)', 'RLS on every table', 'stage_definitions (17)', 'ledger guard trigger',
  'footprint triggers', 'ledger chain intact', 'seed: Kalanamak crop', 'environment', 'demo data', 'api surface closed',
  'auth.uid mapping', 'public journey rpc', 'phase 3 objects', 'phase 4 objects', 'phase 4 triggers', 'ledger read by stage',
  'direct writes closed', 'evidence in the ledger', 'public page data', 'capture time, verdict preview',
  'a new client can be read back', 'identity layer objects', 'people moved to assignments', 'the two seats',
  'manager rules ask about the scope', 'people written only by their actions', 'once-a-day sign-in code', 'the admin oversees',
  'joiner HR data', 'onboarding at scale', 'hr by geography', 'HR holds no seat', 'state manager rules', 'crop registry', 'farmer register', 'rules and farmer ids', 'production safeguards', 'requirements', 'farmer corrections', 'operator template', 'trust numbers', 'packs and release', 'setup lists', 'procurement batch', 'milling qc packing', 'commercial shipment', 'warehouse', 'buyer link scans', 'client isolation', 'statement logging', 'reminder round', 'nightly ledger check')
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
Say "  smoke rows read: $($present.Count) of 54, OK: $okCount"
foreach ($w in $warn) { Say "  NOT OK (standing, does not stop): $w" }
foreach ($b in $bad) { Say "  NOT OK: $b" }
if ($missing.Count -gt 0) { Stop-Run 'S2' ("smoke rows not found in the output: " + ($missing -join ', ')) }
if ($bad.Count -gt 0) { Stop-Run 'S2' ("smoke rows not OK: " + ($bad -join ' ; ')) }

Query 'q_rule56' "select 'rule56=' || case when to_regclass('public.buyer_links') is not null and to_regclass('public.buyer_link_views') is not null and to_regclass('public.scan_flags') is not null and to_regprocedure('app.create_buyer_link(uuid, integer, text)') is not null and to_regprocedure('app.revoke_buyer_link(uuid, text)') is not null and to_regprocedure('app.buyer_view(text)') is not null and to_regprocedure('app.buyer_file(text, uuid)') is not null and to_regprocedure('app.record_scan_at(text, text, text, text, numeric, numeric)') is not null and to_regprocedure('app.decide_scan_flag(uuid, text, text)') is not null and to_regprocedure('app.isolation_probe(boolean, boolean)') is not null and not has_function_privilege('anon', 'app.buyer_file(text, uuid)', 'execute') and not has_column_privilege('authenticated', 'public.buyer_links', 'token_hash', 'select') and exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'openings' and policyname = 'openings_read' and qual like '%can_access_client%') and to_regclass('public.warehouse_inspections') is not null and (select count(*) from pg_trigger where tgname = 'zz_change_log') = 54 and not exists (select 1 from app.verify_change_log()) then 'OK' else 'OLD' end || ' end' as result;"
if ($script:Out -notmatch 'rule56=OK end') { Stop-Run 'S2' 'the new rules are not in place, or the change log does not verify' }
# Veda, 16 Oct 2026: "check that one client data should not be visible to another client". As every person bound to a
# client, the probe reads every table and calls every function with another client's ids; one statement, read only.
Query 'q_iso56' "select 'iso: leaks=' || jsonb_array_length(j->'leaks') || ' people=' || (j->>'people') || ' tables=' || (j->>'tables') || ' calls=' || (j->>'calls') || ' own_rows=' || (j->>'own_rows_seen') || ' clients=' || (j->>'clients') || ' what=' || coalesce((select string_agg(distinct (x->>'kind') || ':' || (x->>'what'), ',') from jsonb_array_elements(j->'leaks') x), '-') || ' end' as result from (select app.isolation_probe() as j) p;"
if ($script:Code -ne 0 -or $script:Out -notmatch 'iso: .* end') { Stop-Run 'S2' 'the check that one client sees nothing of another could not be run (read the error above). The app was not pushed.' }
$iso = [regex]::Match($script:Out, 'iso: (.*?) end').Groups[1].Value
Say "  one client's data, another client: $iso"
if ($iso -notmatch '^leaks=0 ') { Stop-Run 'S2' "A CLIENT CAN SEE ANOTHER CLIENT'S DATA: $iso. The app was not pushed; send this line to Claude." }
Query 'q_after56' "select 'after: links=' || (select count(*) from public.buyer_links) || ' scan_flags=' || (select count(*) from public.scan_flags) || ' inspections=' || (select count(*) from public.warehouse_inspections) || ' sale_terms=' || (select count(*) from public.sale_terms) || ' samples=' || (select count(*) from public.qc_samples) || ' payments=' || (select count(*) from public.lot_payments) || ' packs=' || (select count(*) from public.packs) || ' change_log_lines=' || (select count(*) from public.change_log) || ' ledger_head=' || coalesce((select max(l.seq) from public.ledger l)::text, '-') || ' end' as result;"
$after = [regex]::Match($script:Out, 'after: (.*?) end').Groups[1].Value
Say "  after: $after"
Run "$sb db query --linked -f tests/remote_ledger_audit.sql"
if ($script:Code -ne 0 -or $script:Out -notmatch 'NO FINDINGS \(') { Stop-Run 'S2' "the ledger audit did not answer 'NO FINDINGS ('" }
$auditLine = [regex]::Match($script:Out, 'NO FINDINGS \([^)]*\)').Value
Run 'node scripts/check_logins.mjs'
if ($script:Out -notmatch 'NO LOGIN WITHOUT A PERSON') { Stop-Run 'S2' "'NO LOGIN WITHOUT A PERSON' was not printed" }
Run 'node scripts/check_functions.mjs'
if ($script:Out -notmatch 'FUNCTIONS DEPLOYED AND CURRENT') { Stop-Run 'S2' 'the functions are no longer all current' }
$smokeNote = "smoke $okCount of 54 OK"
if ($warn.Count -gt 0) { $smokeNote += '; NOT OK (standing): ' + ($warn -join ' ; ') }
Say '  ok  smoke, the new rules, one client and another, ledger audit, logins, functions'
Mark 'S2' 'OK' "$smokeNote; the new rules: in place, the change log intact; one client and another: $iso; $after; $auditLine; NO LOGIN WITHOUT A PERSON; FUNCTIONS DEPLOYED AND CURRENT"

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
  [System.IO.File]::WriteAllText($msg, "Share with the buyer, scans and copies, release 9 (migrations 56 and 56b, buyer-file): a link per sale or shipment (expires, revoked, every view logged; no price, no farmer's name); scans with their approximate place, copies flagged and warned; one client's data never another's (four leaks closed, a probe); the Collection Batch's lot filters; three fixes of release 8`n`nVeda, 16 Oct 2026 (the operator-stages brief, G19).`n`nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`nClaude-Session: https://claude.ai/code/session_01VSgZRQeaqm6gr2gjyiknfF`n", $utf8)
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
Say "the push of 13 Oct): Deployments, the ... menu, Create Deployment, branch main. Then docs/RUNSHEET_buyer_link_scans.md, Afterwards."
Say 'RESULT: BUYER LINK AND SCANS ON STAGING'
exit 0
