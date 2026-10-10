# THE ADMIN OVERSEES, on the practice system (staging): migration 34 and the app built with it.
# Decision: Veda, 10 October 2026 (docs/FIX_LIST.md G15; brief "GrainVeda MVP - Admin role changes", override removed).
# RUN IT ONLY WHEN VEDA HAS SAID SO: it changes the staging database and PUSHES TO THE MAIN BRANCH (Vercel builds the
# staging app from that push). It asks once, in words, before either.
#
# What it does: S0 checks (tools, the tested files, the staging project, exactly migration 34 waiting) and the
# question; S1 pushes migration 34; S2 reads the project back (smoke check, 31 rows; ledger audit; logins; functions);
# S3 commits and pushes the app. Nothing is deleted or rewritten: migration 34 is additive (new columns, functions,
# changed rules). The records already there (clients, scopes, a sealed lot) stay readable.
# It refuses: any project but the staging one named below; a project that says it is production; files that are not
# the tested ones; any migration waiting other than migration 34.
#
# Usage (PowerShell, repository root), or double-click staging-admin-oversight.cmd:
#   powershell -ExecutionPolicy Bypass -File scripts\staging_admin_oversight.ps1
# Options:  -NoGit   stop after S2 (the database is then on the new rules and the staging app is still the old one:
#                    its admin screens offer acts the database refuses, with the database's words. Push soon after)
# It can be run again after a stop: a database already on migration 34 is not pushed again.
# The record of the run: release-evidence\staging-admin-oversight-<time>.log (git-ignored). It reads no .env file and
# prints no key or password.
#
# Plain ASCII on purpose (Windows PowerShell 5.1 reads a script without a byte-order mark as ANSI). No function hands
# back a result: results go to $script: names (docs/FIX_LIST.md fault 36).
param(
  [switch]$NoGit
)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$utf8 = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = $utf8 } catch { }
$env:GIT_TERMINAL_PROMPT = '0'
$stagingRef = 'zogkrhgzatplarimbmxk'          # the practice project; the only one this script will touch
$phrase = 'ADMIN OVERSIGHT'
$migration = '20261010000100_admin_oversight.sql'

$evidence = Join-Path $root 'release-evidence'
if (-not (Test-Path $evidence)) { New-Item -ItemType Directory -Path $evidence | Out-Null }
$log = Join-Path $evidence ("staging-admin-oversight-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:Out = ''
$script:Code = 0
$script:Results = New-Object System.Collections.Generic.List[string]
$script:DbPushed = $false

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
  if ($script:DbPushed) { Say 'The database is on migration 34. The staging app is the old one until S3 has run: run this again (it does not push the database twice).' }
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
  foreach ($dir in @('web/src', 'web/tests', 'web/public')) {
    $base = (Join-Path $root $dir)
    foreach ($f in @(Get-ChildItem -Path $base -Recurse -File)) {
      $rel = $dir + '/' + ($f.FullName.Substring($base.Length + 1) -replace '\\', '/')
      if (-not $known.ContainsKey($rel)) { $script:AppDiff.Add("$rel (new)") }
    }
  }
}

Say "GrainVeda - the admin oversees, on the practice system - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

# ---------------------------------------------------------------------------------------------------------------
# S0  pre-flight: the tools, the files, the project, what is waiting, and the question
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
Run "$sb --version"
if ($script:Code -ne 0) { Stop-Run 'S0' 'supabase --version failed' }

# The database files must be the ones tested on 10 October 2026 (local stack: 28 test files, the upgrade path, the
# screens); the app must be the tested app, file for file.
$tested = [ordered]@{
  "supabase/migrations/$migration" = '741729916e4afdd47644edc7f6193e3680bb43bc4a87039c6ca1e0d8d78a39f7'
  'tests/remote_smoke.sql' = '66e069c427f83c7666a042280e565a9c9744744fd866423222cb6acd242d7dad'
  'tests/remote_ledger_audit.sql' = '7f51601f01166f33145cefdd13ef92009c0390edf337c1c5167646e5d820f8d5'
}
$appListHash = '825584481a607ee1e76ee36ed9a91482fe55c4c020584898c74630e7f6306b93'
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
  Stop-Run 'S0' ("the app's files are not the tested ones: " + ($shown -join ', ') + " ($($script:AppDiff.Count) in all)")
}
Say "  ok  migration 34, the smoke check and the ledger audit are the tested files; the app's $($script:AppCount) files are the tested ones"

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
  Say '  no migration is waiting: migration 34 was pushed before (S1 is skipped; S2 shows whether it is in place)'
} elseif ($waiting.Count -eq 1 -and $waiting[0] -eq $migration) {
  Say "  ok  exactly one migration is waiting: $migration"
} else {
  Stop-Run 'S0' ("waiting to be pushed: " + ($waiting -join ', ') + ". Only $migration was expected.")
}

Say ''
Say '  This will:'
if (-not $dbDone) { Say '   - push migration 34 to the practice database: from then on the admin oversees and runs nothing;' }
Say '     crops and clients are the State Manager''s; a farmer is verified by the Client Manager and then by the'
Say '     State Manager of its state. Nothing already there is deleted or rewritten.'
if (-not $NoGit) { Say '   - commit and PUSH TO THE MAIN BRANCH: Vercel then builds the staging app with the admin''s overview.' }
Say ''
$answer = Read-Host "  Only if Veda has said so: type  $phrase  and press Enter (anything else stops)"
[System.IO.File]::AppendAllText($log, "  typed: $answer`r`n", $utf8)
if ($answer -cne $phrase) { Stop-Run 'S0' 'not confirmed' }
Mark 'S0' 'OK' "practice project $stagingRef, environment staging, tested files, app $($script:AppCount) files; waiting: $(if ($dbDone) { 'nothing' } else { $migration }); confirmed in words"

# ---------------------------------------------------------------------------------------------------------------
# S1  push migration 34
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S1  push migration 34'
if ($dbDone) {
  Say '  NOT RUN: nothing waiting'
  Mark 'S1' 'NOT RUN' 'migration 34 was already pushed'
} else {
  Run "$sb db push --linked --yes"
  if ($script:Code -ne 0) { Stop-Run 'S1' 'db push failed (one transaction per migration: read the error above)' }
  $script:DbPushed = $true
  Run "$sb db push --linked --dry-run"
  if (@([regex]::Matches($script:Out, '\b\d{14}_[A-Za-z0-9_]+\.sql')).Count -gt 0) { Stop-Run 'S1' 'a migration is still waiting after the push' }
  Say '  ok  pushed; nothing is waiting'
  Mark 'S1' 'OK' "$migration pushed"
}

# ---------------------------------------------------------------------------------------------------------------
# S2  read the project back
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S2  checks'
$checks = @('extensions', 'schema app', 'tables (15)', 'RLS on every table', 'stage_definitions (16)', 'ledger guard trigger',
  'footprint triggers', 'ledger chain intact', 'seed: Kalanamak crop', 'environment', 'demo data', 'api surface closed',
  'auth.uid mapping', 'public journey rpc', 'phase 3 objects', 'phase 4 objects', 'phase 4 triggers', 'ledger read by stage',
  'direct writes closed', 'evidence in the ledger', 'public page data', 'capture time, verdict preview',
  'a new client can be read back', 'identity layer objects', 'people moved to assignments', 'the two seats',
  'manager rules ask about the scope', 'people written only by their actions', 'once-a-day sign-in code', 'the admin oversees',
  'nightly ledger check')
Run "$sb db query --linked -f tests/remote_smoke.sql"
if ($script:Code -ne 0) { Stop-Run 'S2' 'the smoke check could not be run' }
$text = $script:Out
$at = @{}
foreach ($x in $checks) { $at[$x] = $text.IndexOf($x, [System.StringComparison]::Ordinal) }
$missing = @($checks | Where-Object { $at[$_] -lt 0 })
# One row says how the project is set up, not what this run did: whether the nightly check is scheduled (pg_cron).
# Shown and listed; it does not stop the run.
$standing = @('nightly ledger check')
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
Say "  smoke rows read: $($present.Count) of 31, OK: $okCount"
foreach ($w in $warn) { Say "  NOT OK (standing, does not stop): $w" }
foreach ($b in $bad) { Say "  NOT OK: $b" }
if ($missing.Count -gt 0) { Stop-Run 'S2' ("smoke rows not found in the output: " + ($missing -join ', ')) }
if ($bad.Count -gt 0) { Stop-Run 'S2' ("smoke rows not OK: " + ($bad -join ' ; ')) }

Run "$sb db query --linked -f tests/remote_ledger_audit.sql"
if ($script:Code -ne 0 -or $script:Out -notmatch 'NO FINDINGS \(') { Stop-Run 'S2' "the ledger audit did not answer 'NO FINDINGS ('" }
$auditLine = [regex]::Match($script:Out, 'NO FINDINGS \([^)]*\)').Value
Run 'node scripts/check_logins.mjs'
if ($script:Out -notmatch 'NO LOGIN WITHOUT A PERSON') { Stop-Run 'S2' "'NO LOGIN WITHOUT A PERSON' was not printed" }
# The server functions did not change with migration 34 (build 2026-10-06 is still the one the app needs).
Run 'node scripts/check_functions.mjs'
$fn = 'FUNCTIONS DEPLOYED AND CURRENT'
if ($script:Out -notmatch $fn) { $fn = 'NOT all current (read the lines above; not caused by this run)' ; Say "  NOT OK (does not stop): the server functions are $fn" }
# What is in the practice system, read the new way: the admin's overview counts (as the database owner).
Query 'q_overview' "select 'now: states=' || (select count(*) from public.states) || ' clients=' || (select count(*) from public.clients) || ' scopes=' || (select count(*) from public.scopes) || ' farmers=' || (select count(*) from public.farmers) || ' farmers_without_state=' || (select count(*) from public.farmers where state_id is null) || ' records=' || (select count(*) from public.footprints) || ' seals=' || (select count(*) from public.qr_seals) || ' ledger=' || (select count(*) from public.ledger) || ' hr_seat=' || (select case when app.hr_seat_filled() then 'filled' else 'vacant' end) || ' end' as result;"
$now = [regex]::Match($script:Out, 'now: (.*?) end').Groups[1].Value
$smokeNote = "smoke $okCount of 31 OK"
if ($warn.Count -gt 0) { $smokeNote += '; NOT OK (standing): ' + ($warn -join ' ; ') }
Say '  ok  smoke, ledger audit, logins'
Mark 'S2' 'OK' "$smokeNote; $auditLine; NO LOGIN WITHOUT A PERSON; functions: $fn; $now"

# ---------------------------------------------------------------------------------------------------------------
# S3  the app: commit and push (Vercel builds the push)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S3  commit and push the app'
if ($NoGit) {
  Say '  NOT RUN: -NoGit. The staging app is still the old one: push soon.'
  Mark 'S3' 'NOT RUN' 'switched off with -NoGit: the staging app is still the old build'
} else {
  $envPath = '(?m)(^|[\\/\s"])\.env($|[.\s"])'
  Run 'git status --short'
  if ($script:Code -ne 0) { Stop-Run 'S3' 'git status failed' }
  if ($script:Out -match $envPath) { Stop-Run 'S3' 'git status shows a .env file. Nothing was committed. It must be git-ignored first.' }
  Run 'git add -A'
  if ($script:Code -ne 0) { Stop-Run 'S3' 'git add failed' }
  Run 'git diff --cached --name-only'
  $staged = @($script:Out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^warning:' -and $_ -notmatch '^The file will have' })
  if (@($staged | Where-Object { $_ -match $envPath -or $_ -match '^release-evidence/' -or $_ -match '(^|/)backups/' }).Count -gt 0) {
    Run 'git reset'
    Stop-Run 'S3' 'a .env file, a backup or the run record was about to be committed. The staging was undone; nothing was committed.'
  }
  if ($staged.Count -eq 0) { Say '  nothing new to commit' }
  else {
    $msg = Join-Path $evidence 'commit-message.txt'
    [System.IO.File]::WriteAllText($msg, "The admin oversees (migration 34): overview, ledger page, two farmer verifications; no override`n`nDecision G15, Veda 10 Oct 2026.`n`nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`nClaude-Session: https://claude.ai/code/session_01VSgZRQeaqm6gr2gjyiknfF`n", $utf8)
    Run 'git commit -F release-evidence/commit-message.txt'
    if ($script:Code -ne 0) { Stop-Run 'S3' 'git commit failed' }
  }
  Run 'git push'
  if ($script:Code -ne 0) { Stop-Run 'S3' 'git push failed (run "git push" by hand)' }
  Run 'git rev-parse --short HEAD'
  $head = $script:Out.Trim()
  Say "  ok  pushed (head $head, $($staged.Count) files in this commit)"
  Mark 'S3' 'OK' "pushed, head $head ($($staged.Count) files); Vercel builds the staging app from it"
}

Summary
Say ''
if ($NoGit) {
  Say 'The database is on migration 34; the staging app is still the old one (-NoGit). Run this again without -NoGit soon.'
  Say 'RESULT: DATABASE DONE, APP NOT PUSHED'
  exit 0
}
Say 'In a few minutes (Vercel), sign in as the admin: the first screen is the Platform overview. Then the first day in'
Say "Veda's order: docs/RUNSHEET_fresh_start.md part 2."
Say 'RESULT: ADMIN OVERSIGHT ON STAGING'
exit 0
