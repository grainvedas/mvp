# THE FRESH START OF THE PRACTICE SYSTEM (staging): empties it and leaves one admin, the way a pilot starts.
# Decision: Veda, 6 October 2026 ("clean all the data, so that I can start fresh"; only the admin stays); again 27 October
# 2026, after Phase 3 ("after completing phase 3 we can start fresh and diagnose each step"). Rebuilt for 78 migrations.
#
# What goes:  every person, state, crop, client, scope, farmer, record, verdict, seal, flag, ledger block, audit line
#             and counter; every client, account, order, report, evidence pack and showcase; every login; every stored
#             file (evidence photos, HR documents, reference files, reports and packs, clients' documents).
# What stays: the rules (migrations), the 17 stage definitions, the joining checklists the migrations wrote, the 9
#             departments and the quality parameter library, the server functions, the app, the daily rounds, and the
#             mark "practice system". Report and pack reference numbers run on (never given twice).
# Afterwards: the daily outside copy of the ledger is restarted (F7: staging.csv renamed on the branch ledger-anchors).
# NOT REVERSIBLE. A copy of the rows is written to backups\fresh-start-<time>\ first (plain JSON, to look things up
# in; it cannot be loaded back). There is no other backup of this project.
#
# Usage (PowerShell, repository root), or double-click staging-fresh-start.cmd:
#   powershell -ExecutionPolicy Bypass -File scripts\staging_fresh_start.ps1
# It asks once, in words, before anything is removed. It refuses: any project but the staging one named below; a
# project that says it is production; a database with migrations still to push; files that are not the tested ones.
# Options:  -AdminEmail <address>  -AdminName <one word>  (the first admin; default grainvedas+admin@gmail.com, Veda)
#           -NoGit   do not commit and push the new files at the end, and do not restart the outside copy (F7)
# It can be run again after a stop. Once the system holds one admin and nothing else, a further run removes nothing
# and asks nothing: it only repeats the checks and the commit.
# The record of the run: release-evidence\staging-fresh-start-<time>.log (git-ignored). It reads no .env file and
# prints no key or password; the admin's temporary password is written to .env.admin-login by the script it calls.
#
# Plain ASCII on purpose (Windows PowerShell 5.1 reads a script without a byte-order mark as ANSI). No function hands
# back a result: results go to $script: names (docs/FIX_LIST.md fault 36).
param(
  [string]$AdminEmail = 'grainvedas+admin@gmail.com',
  [string]$AdminName = 'Veda',
  [switch]$NoGit
)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$utf8 = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = $utf8 } catch { }
$env:GIT_TERMINAL_PROMPT = '0'
$stagingRef = 'zogkrhgzatplarimbmxk'          # the practice project; the only one this script will touch
$phrase = 'EMPTY STAGING'

if ($AdminEmail -notmatch '^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') { Write-Host 'The admin address does not look like an e-mail address.'; exit 1 }
if ($AdminName -notmatch '^[A-Za-z][A-Za-z0-9.-]{0,40}$') { Write-Host 'The admin name must be one word of letters (it can be changed in the app later).'; exit 1 }

$evidence = Join-Path $root 'release-evidence'
if (-not (Test-Path $evidence)) { New-Item -ItemType Directory -Path $evidence | Out-Null }
$log = Join-Path $evidence ("staging-fresh-start-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:Out = ''
$script:Code = 0
$script:Results = New-Object System.Collections.Generic.List[string]
$script:WipeRan = $false
$script:Emptied = $false
$script:AdminBack = $false

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
  if ($script:WipeRan -and -not $script:Emptied) { Say 'The emptying step ran, and the database is not as expected afterwards: read the line "now: ..." above. Logins and stored files were not touched.' }
  elseif (-not $script:Emptied) { Say 'Nothing was removed.' }
  elseif (-not $script:AdminBack) { Say 'The database is empty and has no admin yet: nobody can sign in until this script has run to the end. Run it again.' }
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
# One line that says what is in the system: read from the database itself, before and after.
$countSql = "select 'now: people=' || (select count(*) from public.app_users) || ' logins=' || (select count(*) from auth.users) || ' states=' || (select count(*) from public.states) || ' crops=' || (select count(*) from public.crops) || ' clients=' || (select count(*) from public.clients) || ' scopes=' || (select count(*) from public.scopes) || ' farmers=' || (select count(*) from public.farmers) || ' records=' || (select count(*) from public.footprints) || ' seals=' || (select count(*) from public.qr_seals) || ' ledger=' || (select count(*) from public.ledger) || ' audit=' || (select count(*) from public.audit_log) || ' admins=' || (select count(*) from public.app_users where system_role = 'admin' and status = 'active') || ' stage_definitions=' || (select count(*) from public.stage_definitions) || ' checklist_tasks=' || (select count(*) from public.template_tasks t join public.onboarding_templates o on o.id = t.template_id where o.is_default) || ' departments=' || (select count(*) from public.departments) || ' param_library=' || (select count(*) from public.quality_param_library) || ' ledger_guards=' || (select case when count(*) filter (where tgenabled <> 'O') = 0 then 'on' else 'OFF' end from pg_trigger where tgname in ('ledger_no_truncate', 'change_log_no_truncate')) || ' audit_guard=' || (select case when tgenabled = 'O' then 'on' else 'OFF' end from pg_trigger where tgname = 'audit_log_no_truncate') || ' end' as result;"
function Read-Counts() {
  $script:Counts = @{}
  $m = [regex]::Match($script:Out, 'now: (.*?) end(?!\w)')
  if (-not $m.Success) { return }
  foreach ($pair in ($m.Groups[1].Value -split '\s+')) {
    $kv = $pair -split '=', 2
    if ($kv.Count -eq 2) { $script:Counts[$kv[0]] = $kv[1] }
  }
}

Say "GrainVeda - fresh start of the practice system - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

# ---------------------------------------------------------------------------------------------------------------
# F0  pre-flight: the tools, the files, the project, and the question
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== F0  pre-flight'
$sb = ''
if (Get-Command supabase -ErrorAction SilentlyContinue) { $sb = 'supabase' }
elseif (Test-Path (Join-Path $root 'web/node_modules/.bin/supabase.cmd')) { $sb = 'web\node_modules\.bin\supabase.cmd' }
elseif (Test-Path (Join-Path $root 'node_modules/.bin/supabase.cmd')) { $sb = 'node_modules\.bin\supabase.cmd' }
if (-not $sb) { Stop-Run 'F0' 'the supabase command was not found' }
foreach ($tool in @('node', 'git')) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Stop-Run 'F0' "the $tool command was not found on PATH" }
}
Run "$sb --version"
if ($script:Code -ne 0) { Stop-Run 'F0' 'supabase --version failed' }

# The files that do the removing and the checking must be the ones rehearsed on the local stack on 27 October 2026
# (emptied, one admin put back, the checks of F5, then the first day of a pilot through the screens up to a sealed lot).
$tested = [ordered]@{
  'scripts/fresh_start/empty_staging.sql' = '5c8958eaaff7f53bec765d2dc714215070bf21c1ce0c0c402a07f345c7fd1225'
  'scripts/fresh_start/export_rows.mjs' = 'df20c44b1df6fa998c0ae56c830f90b3b878c4ef5e8a95d4bf328823d7dab3ce'
  'scripts/fresh_start/clear_logins_and_files.mjs' = '10166911bbb28ba664028fc9fb031ca71fa29c956645d157b466302b8658cd69'
  'scripts/bootstrap_admin.mjs' = 'fa32a16a249955dd9719acde0f5eab732c3da4ec7705e2ae61c7ffea307c4917'
  'scripts/lib/env.mjs' = 'a9c0b9a30647e1443d37da26a7b445313ba4ac78c40e01ec6e436e5e54869ee2'
  'tests/remote_smoke.sql' = '01201d3bd886be00c3c4346e188afc607c8a0cd9d1ac7fdc127d40928cf87d75'
  'tests/remote_ledger_audit.sql' = 'd8428bf2dbd427f352ebeaf4863a34829a3be3e66bd06d3c7a057348e7df56ed'
  'scripts/check_logins.mjs' = '167f25e9358e44f6c8bcf529520d92d16437585cf0b07c6941ca050d2dcc4224'
  'scripts/check_functions.mjs' = '7d86813aee68319d0f1506aaf447a56fd7be4ebb88d07eda0746943521ce9e3d'
}
$changed = @()
foreach ($path in $tested.Keys) {
  if (-not (Test-Path (Join-Path $root $path))) { $changed += "$path (missing)"; continue }
  Hash-Text $path
  if ($script:Hash -ne $tested[$path]) { $changed += $path }
}
if ($changed.Count -gt 0) { Stop-Run 'F0' ("these files are not the ones that were rehearsed: " + ($changed -join ', ')) }
Say "  ok  $($tested.Count) files are the rehearsed ones"

# Which project? Three answers must agree: the folder is linked to the staging project, the project says "staging",
# and nothing is waiting to be pushed to it.
$refFile = Join-Path $root 'supabase/.temp/project-ref'
if (-not (Test-Path $refFile)) { Stop-Run 'F0' 'this folder is not linked to a Supabase project (supabase/.temp/project-ref is missing)' }
$ref = ([System.IO.File]::ReadAllText($refFile)).Trim()
if ($ref -cne $stagingRef) { Stop-Run 'F0' "this folder is linked to project '$ref', not to the practice project '$stagingRef'. This script empties the practice project only." }
Say "  ok  linked to the practice project $stagingRef"
Query 'q_environment' "select 'environment=' || app.environment() as e;"
if ($script:Code -ne 0) { Stop-Run 'F0' 'the linked project could not be asked which system it is' }
if ($script:Out -match 'environment=production') { Stop-Run 'F0' 'THE LINKED PROJECT SAYS IT IS PRODUCTION. This script is for the practice system only.' }
if ($script:Out -notmatch 'environment=staging') { Stop-Run 'F0' 'the linked project did not answer environment=staging' }
Say '  ok  the project says it is the practice system'
Run "$sb db push --linked --dry-run"
if ($script:Code -ne 0) { Stop-Run 'F0' 'the dry run failed' }
if (@([regex]::Matches($script:Out, '\b\d{14}_[A-Za-z0-9_]+')).Count -gt 0) { Stop-Run 'F0' 'there are migrations still to push to this project. Push them first; then run this again.' }
Say '  ok  no migration is waiting'

Query 'q_counts' $countSql
if ($script:Code -ne 0) { Stop-Run 'F0' 'the database could not be read' }
Read-Counts
if (-not $script:Counts.ContainsKey('people')) { Stop-Run 'F0' 'the count of what is in the system could not be read from the output above' }
$before = $script:Counts
# Has this already been done? One person who is the admin, one login, and nothing else: then there is nothing to
# remove, nothing is asked, and only the checks (F5) and the commit (F6) run. A second run never empties again.
$alreadyFresh = $true
foreach ($k in @('people', 'logins', 'admins')) { if ($before[$k] -ne '1') { $alreadyFresh = $false } }
foreach ($k in @('states', 'crops', 'clients', 'scopes', 'farmers', 'records', 'seals')) { if ($before[$k] -ne '0') { $alreadyFresh = $false } }
if ($alreadyFresh) {
  Say '  The practice system is already empty with one admin: nothing is removed in this run.'
  Mark 'F0' 'OK' "practice project $stagingRef; already empty with one admin: nothing to remove"
  $script:Emptied = $true; $script:AdminBack = $true
} else {
Say ''
Say "  In the practice system now: $($before['people']) people, $($before['logins']) logins, $($before['states']) states, $($before['crops']) crops,"
Say "  $($before['clients']) clients, $($before['scopes']) scopes, $($before['farmers']) farmers, $($before['records']) records, $($before['seals']) sealed lots,"
Say "  $($before['ledger']) ledger blocks, $($before['audit']) audit lines."
Say ''
Say '  ALL OF IT WILL BE REMOVED, with every login and every stored file. This cannot be undone.'
Say "  Afterwards one admin exists ($AdminEmail) and nothing else; state, crop, client and people are made in the app."
Say ''
$answer = Read-Host "  To go on, type  $phrase  and press Enter (anything else stops)"
[System.IO.File]::AppendAllText($log, "  typed: $answer`r`n", $utf8)
if ($answer -cne $phrase) { Stop-Run 'F0' 'not confirmed' }
Mark 'F0' 'OK' "practice project $stagingRef, environment staging, no migration waiting, confirmed in words. Before: $($before['people']) people, $($before['logins']) logins, $($before['clients']) clients, $($before['scopes']) scopes, $($before['farmers']) farmers, $($before['records']) records, $($before['ledger']) ledger blocks"
}

# ---------------------------------------------------------------------------------------------------------------
# F1  a copy of the rows, before anything goes
# ---------------------------------------------------------------------------------------------------------------
if (-not $alreadyFresh) {
Say ''
Say '== F1  a copy of every row (backups\fresh-start-<time>\, git-ignored)'
Run 'node scripts/fresh_start/export_rows.mjs'
if ($script:Code -ne 0 -or $script:Out -notmatch 'ROWS COPIED: \d+ rows of \d+ tables') { Stop-Run 'F1' 'the rows could not all be copied out' }
$copied = [regex]::Match($script:Out, 'ROWS COPIED: \d+ rows of \d+ tables').Value
$folder = [regex]::Match($script:Out, '(?m)^folder: (.+)$').Groups[1].Value.Trim()
Say "  ok  $copied"
Mark 'F1' 'OK' "$copied -> $folder"

# ---------------------------------------------------------------------------------------------------------------
# F2  empty the database (one transaction: everything or nothing)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== F2  empty the database'
Run "$sb db query --linked -f scripts/fresh_start/empty_staging.sql"
if ($script:Code -ne 0) { Stop-Run 'F2' 'the database was not emptied (one transaction: nothing was removed). Read the error above.' }
$script:WipeRan = $true
Query 'q_counts' $countSql
if ($script:Code -ne 0) { Stop-Run 'F2' 'the database could not be read after emptying' }
Read-Counts
$c = $script:Counts
$zero = $true
foreach ($k in @('states', 'crops', 'clients', 'scopes', 'farmers', 'records', 'seals')) { if ($c[$k] -ne '0') { $zero = $false } }
foreach ($k in @('people', 'ledger', 'audit', 'admins')) { if ($c[$k] -ne '0') { $zero = $false } }
if (-not $zero) { Stop-Run 'F2' 'the database is not empty after the emptying step (read the line "now: ..." above)' }
# The parameter library: the 11 tests of migration 51, and each test a crop of that day already used (staging has 12:
# Kalanamak's own 'moisture'; 27 Oct 2026, the first run stopped here on an exact 11). Nothing but migrations writes it.
if ($c['stage_definitions'] -ne '17' -or $c['checklist_tasks'] -ne '9' -or $c['departments'] -ne '9' -or [int]('0' + $c['param_library']) -lt 11) { Stop-Run 'F2' "the lists the rules read are not as expected (stage_definitions=$($c['stage_definitions']) of 17, checklist_tasks=$($c['checklist_tasks']) of 9, departments=$($c['departments']) of 9, param_library=$($c['param_library']), at least 11)" }
if ($c['audit_guard'] -ne 'on' -or $c['ledger_guards'] -ne 'on') { Stop-Run 'F2' 'a guard of the audit log, the ledger or the change log was left switched off' }
$script:Emptied = $true
Say '  ok  the database holds no person, state, crop, client, scope, farmer or record; 17 stage definitions, the checklists, 9 departments and the parameter library are there; the guards are on'
Mark 'F2' 'OK' 'database emptied (0 people, 0 records, 0 ledger blocks, 0 audit lines); 17 stage definitions, the checklists, 9 departments, the parameter library kept; guards on'

# ---------------------------------------------------------------------------------------------------------------
# F3  the logins and the stored files
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== F3  logins and stored files'
Run 'node scripts/fresh_start/clear_logins_and_files.mjs --empty-staging'
if ($script:Code -ne 0 -or $script:Out -notmatch 'LOGINS AND FILES REMOVED') { Stop-Run 'F3' 'logins or stored files were not all removed' }
$n = [regex]::Match($script:Out, 'logins removed: (\d+)').Groups[1].Value
Say "  ok  $n logins removed; the five stores are empty"
Mark 'F3' 'OK' "$n logins removed; stores evidence, hr-docs, reference, reports, client-docs empty"

# ---------------------------------------------------------------------------------------------------------------
# F4  the first admin
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== F4  the first admin'
Run "node scripts/bootstrap_admin.mjs --email $AdminEmail --name $AdminName"
if ($script:Code -ne 0 -or $script:Out -notmatch 'ADMIN CREATED AND LINKED') { Stop-Run 'F4' 'the first admin was not made' }
$script:AdminBack = $true
Say "  ok  $AdminName <$AdminEmail>; the temporary password is in .env.admin-login (git-ignored, not shown)"
Mark 'F4' 'OK' "$AdminName <$AdminEmail> made and linked; temporary password in .env.admin-login"
}

# ---------------------------------------------------------------------------------------------------------------
# F5  what is there now, read back four ways
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== F5  checks'
Query 'q_counts' $countSql
Read-Counts
$c = $script:Counts
$oneAdmin = ($c['people'] -eq '1') -and ($c['logins'] -eq '1') -and ($c['admins'] -eq '1') -and ($c['states'] -eq '0') -and ($c['clients'] -eq '0') -and ($c['records'] -eq '0')
if (-not $oneAdmin) { Stop-Run 'F5' 'the system does not hold exactly one person, one login, one admin and nothing else (read the line "now: ..." above)' }
Say '  ok  one person, one login, one active admin, nothing else'

$checks = @('extensions', 'schema app', 'tables (15)', 'RLS on every table', 'stage_definitions (17)', 'ledger guard trigger',
  'footprint triggers', 'ledger chain intact', 'seed: Kalanamak crop', 'environment', 'demo data', 'api surface closed',
  'auth.uid mapping', 'public journey rpc', 'phase 3 objects', 'phase 4 objects', 'phase 4 triggers', 'ledger read by stage',
  'direct writes closed', 'evidence in the ledger', 'public page data', 'capture time, verdict preview',
  'a new client can be read back', 'identity layer objects', 'people moved to assignments', 'the two seats',
  'manager rules ask about the scope', 'people written only by their actions', 'once-a-day sign-in code', 'the admin oversees',
  'joiner HR data', 'onboarding at scale', 'hr by geography', 'HR holds no seat', 'state manager rules', 'crop registry', 'farmer register', 'rules and farmer ids', 'production safeguards', 'requirements', 'farmer corrections', 'operator template', 'trust numbers', 'packs and release', 'setup lists', 'procurement batch', 'milling qc packing', 'commercial shipment', 'warehouse', 'buyer link scans', 'client isolation', 'people public page packs', 'cartons people choices', 'fixes and client reads only', 'exports', 'export corrections', 'shipped packs', 'close scope report', 'client registry', 'client status', 'sourcing and hooks', 'client accounts', 'client views', 'client orders', 'evidence pack', 'showcase and lifetime', 'statement logging', 'reminder round', 'client lifetime round', 'nightly ledger check')
Run "$sb db query --linked -f tests/remote_smoke.sql"
if ($script:Code -ne 0) { Stop-Run 'F5' 'the smoke check could not be run' }
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
$standing = @('statement logging', 'reminder round', 'client lifetime round', 'nightly ledger check')
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
Say "  smoke rows read: $($present.Count) of 70, OK: $okCount"
foreach ($w in $warn) { Say "  NOT OK (standing, does not stop): $w" }
foreach ($b in $bad) { Say "  NOT OK: $b" }
if ($missing.Count -gt 0) { Stop-Run 'F5' ("smoke rows not found in the output: " + ($missing -join ', ')) }
if ($bad.Count -gt 0) { Stop-Run 'F5' ("smoke rows not OK: " + ($bad -join ' ; ')) }
if ($text -notmatch 'fresh start, no demo data') { Stop-Run 'F5' "the smoke check does not say 'fresh start, no demo data'" }

Run "$sb db query --linked -f tests/remote_ledger_audit.sql"
if ($script:Code -ne 0 -or $script:Out -notmatch 'NO FINDINGS \(') { Stop-Run 'F5' "the ledger audit did not answer 'NO FINDINGS ('" }
$auditLine = [regex]::Match($script:Out, 'NO FINDINGS \([^)]*\)').Value
Run 'node scripts/check_logins.mjs'
if ($script:Out -notmatch 'NO LOGIN WITHOUT A PERSON') { Stop-Run 'F5' "'NO LOGIN WITHOUT A PERSON' was not printed" }
Run 'node scripts/check_functions.mjs'
$fn = 'FUNCTIONS DEPLOYED AND CURRENT'
if ($script:Out -notmatch $fn) { $fn = 'NOT all current (read the lines above; not caused by the fresh start)' ; Say "  NOT OK (does not stop): the server functions are $fn" }
$smokeNote = "smoke $okCount of 70 OK (fresh start, no demo data)"
if ($warn.Count -gt 0) { $smokeNote += '; NOT OK (standing): ' + ($warn -join ' ; ') }
Say '  ok  smoke, ledger audit, logins'
Mark 'F5' 'OK' "one person, one login, one admin; $smokeNote; $auditLine; NO LOGIN WITHOUT A PERSON; functions: $fn"

# ---------------------------------------------------------------------------------------------------------------
# F6  the new files into git (the app itself has not changed)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== F6  commit and push the new files'
if ($NoGit) {
  Say '  NOT RUN: -NoGit'
  Mark 'F6' 'NOT RUN' 'switched off with -NoGit'
} else {
  $envPath = '(?m)(^|[\\/\s"])\.env($|[.\s"])'
  Run 'git status --short'
  if ($script:Code -ne 0) { Stop-Run 'F6' 'git status failed (the fresh start itself is complete)' }
  if ($script:Out -match $envPath) { Stop-Run 'F6' 'git status shows a .env file. Nothing was committed (the fresh start itself is complete).' }
  Run 'git add -A'
  if ($script:Code -ne 0) { Stop-Run 'F6' 'git add failed (the fresh start itself is complete)' }
  Run 'git diff --cached --name-only'
  $staged = @($script:Out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^warning:' -and $_ -notmatch '^The file will have' })
  if (@($staged | Where-Object { $_ -match $envPath -or $_ -match '^release-evidence/' -or $_ -match '(^|/)backups/' }).Count -gt 0) {
    Run 'git reset'
    Stop-Run 'F6' 'a .env file, the copy of the rows or the run record was about to be committed. The staging was undone; nothing was committed (the fresh start itself is complete).'
  }
  if ($staged.Count -eq 0) { Say '  nothing new to commit' }
  else {
    $msg = Join-Path $evidence 'commit-message.txt'
    [System.IO.File]::WriteAllText($msg, "Fresh start of the practice system (27 Oct 2026, after Phase 3): empty it, one admin; the fresh-start files rebuilt for 78 migrations`n`nVeda: ""after completing phase 3 we can start fresh and diagnose each step""; ""ok proceed"".`n`nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`nClaude-Session: https://claude.ai/code/session_01VSgZRQeaqm6gr2gjyiknfF`n", $utf8)
    Run 'git commit -F release-evidence/commit-message.txt'
    if ($script:Code -ne 0) { Stop-Run 'F6' 'git commit failed (the fresh start itself is complete)' }
  }
  Run 'git push'
  if ($script:Code -ne 0) { Stop-Run 'F6' 'git push failed (the fresh start itself is complete; run "git push" by hand)' }
  Run 'git rev-parse --short HEAD'
  $head = $script:Out.Trim()
  Say "  ok  pushed (head $head, $($staged.Count) files in this commit)"
  Mark 'F6' 'OK' "pushed, head $head ($($staged.Count) files)"
}

# ---------------------------------------------------------------------------------------------------------------
# F7  the daily outside copy of the ledger starts again (docs/PRODUCTION_SAFEGUARDS.md)
# ---------------------------------------------------------------------------------------------------------------
# The copy on the branch ledger-anchors holds the old ledger's fingerprints; against the emptied ledger it no longer
# matches, by design. Renaming staging.csv there (it is kept, not deleted) lets the next daily run start a new one.
Say ''
Say '== F7  restart the daily outside copy of the ledger'
if ($NoGit) {
  Say '  NOT RUN: -NoGit (rename staging.csv on the branch ledger-anchors by hand)'
  Mark 'F7' 'NOT RUN' 'switched off with -NoGit'
} elseif (-not $script:WipeRan) {
  Say '  NOT RUN: nothing was emptied in this run'
  Mark 'F7' 'NOT RUN' 'nothing emptied in this run'
} else {
  Run 'git remote get-url origin'
  $origin = ($script:Out -split "`n" | Where-Object { $_ -match '^(https://|git@)' } | Select-Object -First 1)
  if (-not $origin) { Stop-Run 'F7' 'the address of the repository could not be read (the fresh start itself is complete; rename staging.csv on ledger-anchors by hand)' }
  $anchorDir = "release-evidence/anchors-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Run "git clone --quiet --depth 5 --branch ledger-anchors $($origin.Trim()) $anchorDir"
  if ($script:Code -ne 0) { Stop-Run 'F7' 'the branch ledger-anchors could not be fetched (the fresh start itself is complete; rename staging.csv there by hand)' }
  if (-not (Test-Path (Join-Path $root "$anchorDir/staging.csv"))) {
    Say '  staging.csv is not on the branch (already renamed): nothing to do'
    Mark 'F7' 'OK' 'no staging.csv on ledger-anchors: the next daily run starts a new copy'
  } else {
    $keptAs = "staging-before-$(Get-Date -Format 'yyyy-MM-dd').csv"
    Run "git -C $anchorDir mv staging.csv $keptAs"
    if ($script:Code -ne 0) { Stop-Run 'F7' 'staging.csv could not be renamed (the fresh start itself is complete)' }
    Run "git -C $anchorDir -c user.name=GrainVeda -c user.email=grainvedas@gmail.com commit --quiet -m ""ledger anchors: staging emptied (fresh start); the earlier copy kept as $keptAs [skip ci]"""
    if ($script:Code -ne 0) { Stop-Run 'F7' 'the rename could not be committed (the fresh start itself is complete)' }
    Run "git -C $anchorDir push --quiet origin ledger-anchors"
    if ($script:Code -ne 0) { Stop-Run 'F7' 'the rename could not be pushed (the fresh start itself is complete; rename staging.csv on ledger-anchors by hand)' }
    Say "  ok  staging.csv kept as $keptAs on ledger-anchors; the next daily run starts a new copy"
    Mark 'F7' 'OK' "staging.csv kept as $keptAs on ledger-anchors; the daily copy starts again"
  }
}

Summary
Say ''
Say "The practice system is empty. Sign in as $AdminEmail with the temporary password in .env.admin-login,"
Say 'set your own password, then delete that file. .env.demo-logins is of no use any more (those logins are gone).'
Say 'Then the first day, step by step, with Claude: docs/RUNSHEET_fresh_start.md, Part 2.'
Say 'RESULT: FRESH START DONE'
exit 0
