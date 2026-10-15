# SET-UP LISTS, release 4 of the operator-stages plan (migration 51 and the app with it), on the practice system
# (staging). Veda, 15 October 2026, "ok complete everything" (decision G19); releases 1 to 3 are on staging since
# 15 Oct 2026, 17:01.
#   - THE LISTS THE STAGES PICK FROM (Part B): the places of a state (Uttar Pradesh's 75 districts loaded; blocks and
#     villages added by whoever registers farmers there); the Client Manager's collection points, mills, packing units,
#     buyers and pack list; the State Manager's labs and market profiles (versioned, each activated only with the
#     document its limits come from); the parameter library (11 tests, loaded once, read-only).
#   - THE CROP: GI crop = has a GI number (no GI area otherwise), GI blocks, shelf life per packing material, a
#     reference photo. Its Domestic and Export limits become its first two market profiles.
#   - THE FARMER: district from the list, block and village (new ones added), the farm's GPS needed before the Client
#     Manager verifies a farmer registered from now on (those already there are asked, never refused), land record and
#     GI authorised-user numbers; "Outside the GI area" marked; the State Manager sees a GPS check at step 2.
#   - A14 the ledger banner counts the blocks added since the last full check. A15 the roster pool lists free people
#     first, then those already on other scopes with their work; the State Manager's overview counts them.
# docs/FIX_LIST.md item 46; docs/RUNSHEET_setup_lists.md.
# RUN IT ONLY WHEN VEDA HAS SAID SO: it changes the staging database and PUSHES TO THE MAIN BRANCH (Vercel builds the
# staging app from that push). It asks once, in words, first. The server functions are unchanged (build 2026-10-14).
#
# What it does:
#   S0 checks (tools, the tested files, the staging project, migration 51 waiting,
#      the functions current) and asks.
#   S1 pushes it.
#   S1b reads back what the migration filled: the places, the library, each crop's carried profiles (read only).
#   S2 reads the project back: smoke check (48 rows; "statement logging" is a go-live step and does not stop it), the
#      new rules in place, the change log intact, the ledger audit, logins, functions.
#   S3 commits and pushes the app (Vercel builds it), and says how to see that Vercel built that commit.
# Nothing is deleted or rewritten. It refuses: any project but the staging one named below; a project that says it is
# production; files that are not the tested ones; any migration waiting other than 51.
#
# Usage (PowerShell, repository root), or double-click staging-setup-lists.cmd:
#   powershell -ExecutionPolicy Bypass -File scripts\staging_setup_lists.ps1
# It can be run again after a stop: a migration is not pushed twice.
# The record of the run: release-evidence\staging-setup-lists-<time>.log (git-ignored). It reads no .env file and
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
$phrase = 'LISTS'
$migration = '20261026000100_setup_lists.sql'

$evidence = Join-Path $root 'release-evidence'
if (-not (Test-Path $evidence)) { New-Item -ItemType Directory -Path $evidence | Out-Null }
$log = Join-Path $evidence ("staging-setup-lists-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
  if ($script:DbPushed) { Say 'The database is on migration 51; the staging app is the old one until S3 has run: run this again (it does not push the database twice). Meanwhile the old app works as before; its farmer form types the district and asks no GPS, so a farmer it registers is verified by the Client Manager only once the new app is there to add the GPS.' }
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

Say "GrainVeda - set-up lists, release 4 (migration 51 and the app), on the practice system - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

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
  "supabase/migrations/$migration" = '477846fcdc23b6d052901397dd06be340ad9b614bd52973f68b90bd79a86febc'
  'tests/remote_smoke.sql' = '34c5d10164e21e045b1092da8215a6f6468b4b63c49403aa6eda2cec6b223b6e'
  'scripts/anchor_ledger.mjs' = '3d3cdfd71459f64df71c8166abeb1c1b28017c1dcf3db9527d07fc3b87f139ed'
  'scripts/templates/ledger-anchor.yml' = '9759bd65771371bebba38e4317a345852913a0c491647e57eed9b3095c284f80'
  'tests/remote_ledger_audit.sql' = 'b64cff8bc3df0fb67260e340198293bc21394e492ff0c156a123538a1e96472d'
}
$appListHash = 'd6e75b2bc982f317918a423c1d7102879f6d5a017b0c4065bed93f496dfd6951'
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
Say "  ok  migration 51, the smoke check and the ledger audit are the tested files; the app's and functions' $($script:AppCount) files are the tested ones"
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
  Say '  no migration is waiting: migration 51 was pushed before (S1 is skipped; S2 shows whether it is in place)'
} elseif ($waiting.Count -eq 1 -and $waiting[0] -eq $migration) {
  Say "  ok  exactly one migration is waiting: $migration"
} else {
  Stop-Run 'S0' ("waiting to be pushed: " + ($waiting -join ', ') + ". Only $migration was expected.")
}
Run 'node scripts/check_functions.mjs'
if ($script:Out -notmatch 'FUNCTIONS DEPLOYED AND CURRENT') { Stop-Run 'S0' 'the server functions are not all current (read the lines above). This release does not deploy them.' }
Say '  ok  the six functions are current (build 2026-10-14; unchanged)'
Say ''
Say '  This will:'
if (-not $dbDone) { Say '   - push migration 51 to the practice database: the places (UP''s 75 districts), the Client Manager''s lists, labs,' }
if (-not $dbDone) { Say '     market profiles (each crop''s limits become its Domestic and Export profiles), the parameter library, farm GPS.' }
if (-not $dbDone) { Say '     The farmers already there are marked "GPS asked, not required". No record is changed or deleted.' }
Say '   - commit and PUSH TO THE MAIN BRANCH: Vercel builds the app with the Set-up lists page, the farmer form with the'
Say '     district list and the farm GPS, the crop''s GI area, shelf life per material and photo, the ledger banner and'
Say '     the roster pool with people already on other scopes.'
Say ''
$answer = Read-Host "  Only if Veda has said so: type  $phrase  and press Enter (anything else stops)"
[System.IO.File]::AppendAllText($log, "  typed: $answer`r`n", $utf8)
if ($answer -cne $phrase) { Stop-Run 'S0' 'not confirmed' }
Mark 'S0' 'OK' "practice project $stagingRef, environment staging, tested files, $($script:AppCount) app and function files; waiting: $(if ($dbDone) { 'nothing' } else { $waiting -join ' + ' }); functions current; confirmed in words"

# ---------------------------------------------------------------------------------------------------------------
# S1  push migration 51
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S1  push migration 51'
if ($dbDone) {
  Say '  NOT RUN: nothing waiting'
  Mark 'S1' 'NOT RUN' 'migration 51 was already pushed'
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
# S1b  what the migration filled: places, the library, each crop's carried profiles, farmers (read only)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S1b  places, library, profiles, farmers (read only)'
Query 'q_read51' "select 'fix: states=' || (select count(*) from public.states) || ' districts=' || (select count(*) from public.places where block is null) || ' up_districts=' || (select count(*) from public.places p join public.states st on st.id = p.state_id where p.block is null and lower(st.name) = 'uttar pradesh') || ' library=' || (select count(*) from public.quality_param_library) || ' crops=' || (select count(*) from public.crops) || ' crops_without_profiles=' || (select count(*) from public.crops c where (select count(*) from public.market_profiles m where m.crop_id = c.id and m.status = 'active' and m.code in ('domestic', 'export')) < 2) || ' farmers=' || (select count(*) from public.farmers) || ' farmers_gps_asked=' || (select count(*) from public.farmers where not location_required) || ' farmers_gps_required=' || (select count(*) from public.farmers where location_required) || ' gi_crops=' || (select count(*) from public.crops where gi_crop) || ' end' as result;"
if ($script:Code -ne 0 -or $script:Out -notmatch 'fix: .* end') { Stop-Run 'S1b' 'what the migration filled could not be read (read the error above)' }
$fix = [regex]::Match($script:Out, 'fix: (.*?) end').Groups[1].Value
Say "  $fix"
if ($fix -notmatch 'crops_without_profiles=0 ') { Stop-Run 'S1b' 'a crop has not got its two carried market profiles (read the line above)' }
if ($fix -notmatch 'library=1[1-9] ') { Stop-Run 'S1b' 'the parameter library was not loaded (read the line above)' }
if ($fix -notmatch 'farmers_gps_required=0 ') { Say '  note: farmers_gps_required counts farmers registered after the push (none expected before S3)' }
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
  'joiner HR data', 'onboarding at scale', 'hr by geography', 'HR holds no seat', 'state manager rules', 'crop registry', 'farmer register', 'rules and farmer ids', 'production safeguards', 'requirements', 'farmer corrections', 'operator template', 'trust numbers', 'packs and release', 'setup lists', 'statement logging', 'reminder round', 'nightly ledger check')
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
Say "  smoke rows read: $($present.Count) of 48, OK: $okCount"
foreach ($w in $warn) { Say "  NOT OK (standing, does not stop): $w" }
foreach ($b in $bad) { Say "  NOT OK: $b" }
if ($missing.Count -gt 0) { Stop-Run 'S2' ("smoke rows not found in the output: " + ($missing -join ', ')) }
if ($bad.Count -gt 0) { Stop-Run 'S2' ("smoke rows not OK: " + ($bad -join ' ; ')) }

Query 'q_rule51' "select 'rule51=' || case when to_regclass('public.places') is not null and to_regclass('public.collection_points') is not null and to_regclass('public.mills') is not null and to_regclass('public.packing_units') is not null and to_regclass('public.buyers') is not null and to_regclass('public.pack_skus') is not null and to_regclass('public.labs') is not null and to_regclass('public.market_profiles') is not null and to_regclass('public.reference_files') is not null and to_regprocedure('app.add_place(uuid, text, text, text)') is not null and to_regprocedure('app.activate_market_profile(uuid)') is not null and to_regprocedure('app.ledger_status()') is not null and to_regprocedure('app.multi_scope_people(uuid)') is not null and exists (select 1 from storage.buckets where id = 'reference') and to_regclass('public.packs') is not null and to_regclass('public.footprint_links') is not null and (select count(*) from pg_trigger where tgname = 'zz_change_log') = 41 and not exists (select 1 from app.verify_change_log()) then 'OK' else 'OLD' end || ' end' as result;"
if ($script:Out -notmatch 'rule51=OK end') { Stop-Run 'S2' 'the new rules are not in place, or the change log does not verify' }
Query 'q_after51' "select 'after: places=' || (select count(*) from public.places) || ' profiles=' || (select count(*) from public.market_profiles) || ' packs=' || (select count(*) from public.packs) || ' change_log_lines=' || (select count(*) from public.change_log) || ' ledger_head=' || coalesce((select max(l.seq) from public.ledger l)::text, '-') || ' end' as result;"
$after = [regex]::Match($script:Out, 'after: (.*?) end').Groups[1].Value
Say "  after: $after"
Run "$sb db query --linked -f tests/remote_ledger_audit.sql"
if ($script:Code -ne 0 -or $script:Out -notmatch 'NO FINDINGS \(') { Stop-Run 'S2' "the ledger audit did not answer 'NO FINDINGS ('" }
$auditLine = [regex]::Match($script:Out, 'NO FINDINGS \([^)]*\)').Value
Run 'node scripts/check_logins.mjs'
if ($script:Out -notmatch 'NO LOGIN WITHOUT A PERSON') { Stop-Run 'S2' "'NO LOGIN WITHOUT A PERSON' was not printed" }
Run 'node scripts/check_functions.mjs'
if ($script:Out -notmatch 'FUNCTIONS DEPLOYED AND CURRENT') { Stop-Run 'S2' 'the functions are no longer all current' }
$smokeNote = "smoke $okCount of 48 OK"
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
  [System.IO.File]::WriteAllText($msg, "Set-up lists, release 4 (migration 51): places, the Client Manager's lists, labs, market profiles with their sources, the parameter library; farm GPS and the district list; GI crop, shelf life per material, reference photo; the ledger banner; the roster pool`n`nVeda, 15 Oct 2026 (the operator-stages brief, G19).`n`nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`nClaude-Session: https://claude.ai/code/session_01VSgZRQeaqm6gr2gjyiknfF`n", $utf8)
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
Say "the push of 13 Oct): Deployments, the ... menu, Create Deployment, branch main. Then docs/RUNSHEET_setup_lists.md, Afterwards."
Say 'RESULT: SET-UP LISTS ON STAGING'
exit 0
