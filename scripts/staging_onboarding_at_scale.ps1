# ONBOARDING AT SCALE, on the practice system (staging): migration 38, the six server functions (invite is new) and
# the app built with them. Brief "GrainVeda MVP - Onboarding at scale (10 -> 100 -> 200+ hires)" (Veda, 11 October
# 2026; decisions "as recommended"; docs/FIX_LIST.md item 32; docs/RUNSHEET_onboarding_at_scale.md).
# RUN IT ONLY WHEN VEDA HAS SAID SO: it deploys functions on the staging project, changes the staging database and
# PUSHES TO THE MAIN BRANCH (Vercel builds the staging app from that push). It asks once, in words, before any of it.
#
# What it does:
#   S0 checks (tools, the tested files, the staging project, exactly migration 38 waiting, the key of id-numbers set)
#      and records how things stand (read only: people joining, open steps whose due date H7 will move); asks.
#   S1 deploys the six server functions (build 2026-10-13; invite is new and public: --no-verify-jwt, like ledger-check)
#      and checks them: all current.
#   S2 pushes migration 38. S3 reads the project back (smoke check, 34 rows; the earlier checks; ledger audit; logins;
#      functions; what migration 38 did: role checklists, due dates moved once, the reminder round).
#   S4 commits and pushes the app.
# Nothing is deleted or rewritten. No test data is added: the 205-person test ran on the local stack only (the brief).
# It refuses: any project but the staging one named below; a project that says it is production; files that are not
# the tested ones; any migration waiting other than migration 38.
#
# Usage (PowerShell, repository root), or double-click staging-onboarding-at-scale.cmd:
#   powershell -ExecutionPolicy Bypass -File scripts\staging_onboarding_at_scale.ps1
# Options:  -NoGit   stop after S3 (the database is then on migration 38 and the staging app is still the old one:
#                    it keeps working, without the new screens. Push soon after)
# It can be run again after a stop: the functions and the migration are not done twice.
# The record of the run: release-evidence\staging-onboarding-at-scale-<time>.log (git-ignored). It reads no .env file
# and prints no key or password.
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
$phrase = 'ONBOARDING AT SCALE'
$migration = '20261013000100_onboarding_at_scale.sql'
$functions = @('create-user', 'reset-password', 'ledger-check', 'daily-code', 'id-numbers', 'invite')

$evidence = Join-Path $root 'release-evidence'
if (-not (Test-Path $evidence)) { New-Item -ItemType Directory -Path $evidence | Out-Null }
$log = Join-Path $evidence ("staging-onboarding-at-scale-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
  if ($script:DbPushed) { Say 'The database is on migration 38. The staging app is the old one until S4 has run: run this again (it does not push the database twice). The old app keeps working meanwhile, without the new screens; Mark as joined there now refuses while a statutory step is open (the new app offers "received on paper").' }
  elseif ($script:Changed) { Say 'The database was not changed. The server functions were deployed: the old app keeps working with them.' }
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

Say "GrainVeda - onboarding at scale, on the practice system - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

# ---------------------------------------------------------------------------------------------------------------
# S0  pre-flight: the tools, the files, the project, what is waiting, how things stand, and the question
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

# The database files and the server functions must be the ones tested on 11 October 2026 (local stack: 32 test files,
# the upgrade path, the screens with the 205-person test, the load runs); the app must be the tested app, file for file.
$tested = [ordered]@{
  "supabase/migrations/$migration" = '12750c98145d54d0af68e0c0a292974e52242cd0b317db542f3f80e7d76eb76c'
  'tests/remote_smoke.sql' = 'f45c7f7e7251b046a8fc3f90ed8a1e091f5f3e8b6242d9a71c53f4c061538e1a'
  'tests/remote_ledger_audit.sql' = '7f51601f01166f33145cefdd13ef92009c0390edf337c1c5167646e5d820f8d5'
}
$appListHash = '58a4efd512300354da76a11d538c8a93d9621b92f77bbd2a8cb73ce2bb0b96b1'
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
Say "  ok  migration 38, the smoke check and the ledger audit are the tested files; the app's and functions' $($script:AppCount) files are the tested ones"

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
  Say '  no migration is waiting: migration 38 was pushed before (S2 is skipped; S3 shows whether it is in place)'
} elseif ($waiting.Count -eq 1 -and $waiting[0] -eq $migration) {
  Say "  ok  exactly one migration is waiting: $migration"
} else {
  Stop-Run 'S0' ("waiting to be pushed: " + ($waiting -join ', ') + ". Only $migration was expected.")
}

# How things stand (read only; no names): people joining, and their open steps due within three days (H7 moves those
# once, to three days from the push, each move logged).
Query 'q_before' "select 'before: joining=' || (select count(*) from public.app_users where status in ('invited', 'onboarding')) || ' open_steps=' || (select count(*) from public.onboarding_tasks t join public.app_users u on u.id = t.employee_id where t.status = 'pending' and u.status in ('invited', 'onboarding')) || ' due_within_3_days=' || (select count(*) from public.onboarding_tasks t join public.app_users u on u.id = t.employee_id where t.status = 'pending' and u.status in ('invited', 'onboarding') and t.due_on < app.today() + 3) || ' templates=' || (select count(*) from public.onboarding_templates where active) || ' end' as result;"
$before = [regex]::Match($script:Out, 'before: (.*?) end').Groups[1].Value
Say "  how things stand: $before"
Run "$sb secrets list"
if ($script:Code -ne 0) { Stop-Run 'S0' 'the project secrets could not be listed' }
if ($script:Out -notmatch '\bID_HMAC_KEY\b') { Stop-Run 'S0' 'the key ID_HMAC_KEY of id-numbers is not set: run staging-joiner-hr-data.cmd first (migration 37)' }
Say '  ok  the key of id-numbers is set (kept as it is)'
$mailSet = ($script:Out -match '\bMAIL_API_KEY\b')
if ($mailSet) { Say '  a mail sender key is set: invites and reminders will be emailed' }
else { Say '  no mail sender is set: invite links are copied by HR; reminders wait in the queue (decisions 1 and 2)' }
Say ''
Say '  This will:'
Say '   - deploy the six server functions (build 2026-10-13; invite is new: one-time links, 72 hours)'
if (-not $dbDone) { Say '   - push migration 38 to the practice database: openings, import, invites, HR owner, paged lists, bulk acts,' }
if (-not $dbDone) { Say '     the gate on Mark as joined, a checklist per role, the Deputy seat. Open steps due within three days move' }
if (-not $dbDone) { Say '     once to three days from now (each logged). Nothing is deleted.' }
if (-not $NoGit) { Say '   - commit and PUSH TO THE MAIN BRANCH: Vercel then builds the staging app.' }
Say ''
$answer = Read-Host "  Only if Veda has said so: type  $phrase  and press Enter (anything else stops)"
[System.IO.File]::AppendAllText($log, "  typed: $answer`r`n", $utf8)
if ($answer -cne $phrase) { Stop-Run 'S0' 'not confirmed' }
Mark 'S0' 'OK' "practice project $stagingRef, environment staging, tested files, $($script:AppCount) app and function files; waiting: $(if ($dbDone) { 'nothing' } else { $migration }); $before; confirmed in words"

# ---------------------------------------------------------------------------------------------------------------
# S1  the six server functions
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S1  deploy the server functions'
foreach ($f in $functions) {
  $extra = ''
  if ($f -eq 'ledger-check' -or $f -eq 'invite') { $extra = ' --no-verify-jwt' }
  Run "$sb functions deploy $f$extra"
  if ($script:Code -ne 0) { Stop-Run 'S1' "deploying $f failed" }
  $script:Changed = $true
}
Run 'node scripts/check_functions.mjs'
if ($script:Out -notmatch 'FUNCTIONS DEPLOYED AND CURRENT') { Stop-Run 'S1' 'the functions are not all current or not configured (read the lines above). The database was not changed.' }
Say '  ok  six functions, build 2026-10-13'
Mark 'S1' 'OK' 'six functions deployed; FUNCTIONS DEPLOYED AND CURRENT'

# ---------------------------------------------------------------------------------------------------------------
# S2  push migration 38
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S2  push migration 38'
if ($dbDone) {
  Say '  NOT RUN: nothing waiting'
  Mark 'S2' 'NOT RUN' 'migration 38 was already pushed'
} else {
  Run "$sb db push --linked --yes"
  if ($script:Code -ne 0) { Stop-Run 'S2' 'db push failed (one transaction per migration: read the error above)' }
  $script:DbPushed = $true
  Run "$sb db push --linked --dry-run"
  if (@([regex]::Matches($script:Out, '\b\d{14}_[A-Za-z0-9_]+\.sql')).Count -gt 0) { Stop-Run 'S2' 'a migration is still waiting after the push' }
  Say '  ok  pushed; nothing is waiting'
  Mark 'S2' 'OK' "$migration pushed"
}

# ---------------------------------------------------------------------------------------------------------------
# S3  read the project back (read only)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S3  checks'
$checks = @('extensions', 'schema app', 'tables (15)', 'RLS on every table', 'stage_definitions (16)', 'ledger guard trigger',
  'footprint triggers', 'ledger chain intact', 'seed: Kalanamak crop', 'environment', 'demo data', 'api surface closed',
  'auth.uid mapping', 'public journey rpc', 'phase 3 objects', 'phase 4 objects', 'phase 4 triggers', 'ledger read by stage',
  'direct writes closed', 'evidence in the ledger', 'public page data', 'capture time, verdict preview',
  'a new client can be read back', 'identity layer objects', 'people moved to assignments', 'the two seats',
  'manager rules ask about the scope', 'people written only by their actions', 'once-a-day sign-in code', 'the admin oversees',
  'joiner HR data', 'onboarding at scale', 'reminder round', 'nightly ledger check')
Run "$sb db query --linked -f tests/remote_smoke.sql"
if ($script:Code -ne 0) { Stop-Run 'S3' 'the smoke check could not be run' }
$text = $script:Out
$at = @{}
foreach ($x in $checks) { $at[$x] = $text.IndexOf($x, [System.StringComparison]::Ordinal) }
$missing = @($checks | Where-Object { $at[$_] -lt 0 })
# Two rows say how the project is set up, not what this run did: whether pg_cron schedules the nightly check and the reminders.
$standing = @('reminder round', 'nightly ledger check')
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
Say "  smoke rows read: $($present.Count) of 34, OK: $okCount"
foreach ($w in $warn) { Say "  NOT OK (standing, does not stop): $w" }
foreach ($b in $bad) { Say "  NOT OK: $b" }
if ($missing.Count -gt 0) { Stop-Run 'S3' ("smoke rows not found in the output: " + ($missing -join ', ')) }
if ($bad.Count -gt 0) { Stop-Run 'S3' ("smoke rows not OK: " + ($bad -join ' ; ')) }

Run "$sb db query --linked -f tests/remote_ledger_audit.sql"
if ($script:Code -ne 0 -or $script:Out -notmatch 'NO FINDINGS \(') { Stop-Run 'S3' "the ledger audit did not answer 'NO FINDINGS ('" }
$auditLine = [regex]::Match($script:Out, 'NO FINDINGS \([^)]*\)').Value
Run 'node scripts/check_logins.mjs'
if ($script:Out -notmatch 'NO LOGIN WITHOUT A PERSON') { Stop-Run 'S3' "'NO LOGIN WITHOUT A PERSON' was not printed" }
Run 'node scripts/check_functions.mjs'
if ($script:Out -notmatch 'FUNCTIONS DEPLOYED AND CURRENT') { Stop-Run 'S3' 'the functions are no longer all current' }
Query 'q_two_jobs' "select 'twojobs=' || case when to_regprocedure('app.acts_as_hr()') is null or to_regprocedure('app.admin_trends(integer)') is null then 'MISSING' when position('is_hr_admin' in pg_get_functiondef(to_regprocedure('app.may_assign(assignment_lens, op_role, uuid)'))) = 0 then 'OLD' else 'OK' end || ' hrjoined=' || case when position('hr_admin_activated_by_admin' in pg_get_functiondef(to_regprocedure('app.activate_joiner(uuid, text)'))) = 0 then 'OLD' else 'OK' end || ' end' as result;"
$prev = [regex]::Match($script:Out, 'twojobs=(\w+) hrjoined=(\w+) end')
if ($prev.Groups[1].Value -ne 'OK' -or $prev.Groups[2].Value -ne 'OK') { Stop-Run 'S3' "the checks of migrations 35 and 36 answered '$($prev.Value)' (expected OK OK)" }
# What migration 38 did (read only): checklists per role, due dates moved once (H7), openings and invites so far.
Query 'q_after' "select 'after: role_templates=' || (select count(*) from public.onboarding_templates where active and role is not null) || ' due_dates_moved_for=' || (select count(*) from public.audit_log where action = 'due_dates_recalculated') || ' openings=' || (select count(*) from public.openings) || ' invites=' || (select count(*) from public.invites) || ' personal_steps=' || (select count(*) from public.onboarding_tasks where kind = 'personal') || ' end' as result;"
$after = [regex]::Match($script:Out, 'after: (.*?) end').Groups[1].Value
Say "  after: $after"
$smokeNote = "smoke $okCount of 34 OK"
if ($warn.Count -gt 0) { $smokeNote += '; NOT OK (standing): ' + ($warn -join ' ; ') }
Say '  ok  smoke, the earlier checks, ledger audit, logins, functions'
Mark 'S3' 'OK' "$smokeNote; 35 and 36 OK; $auditLine; NO LOGIN WITHOUT A PERSON; FUNCTIONS DEPLOYED AND CURRENT; $after"

# ---------------------------------------------------------------------------------------------------------------
# S4  the app: commit and push (Vercel builds the push)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S4  commit and push the app'
if ($NoGit) {
  Say '  NOT RUN: -NoGit. The staging app is still the old one (no new screens). Push soon.'
  Mark 'S4' 'NOT RUN' 'switched off with -NoGit: the staging app is still the old build'
} else {
  $envPath = '(?m)(^|[\\/\s"])\.env($|[.\s"-])'
  Run 'git status --short'
  if ($script:Code -ne 0) { Stop-Run 'S4' 'git status failed' }
  if ($script:Out -match $envPath) { Stop-Run 'S4' 'git status shows a .env file. Nothing was committed. It must be git-ignored first.' }
  Run 'git add -A'
  if ($script:Code -ne 0) { Stop-Run 'S4' 'git add failed' }
  Run 'git diff --cached --name-only'
  $staged = @($script:Out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^warning:' -and $_ -notmatch '^The file will have' })
  if (@($staged | Where-Object { $_ -match $envPath -or $_ -match '^release-evidence/' -or $_ -match '(^|/)backups/' -or $_ -match 'id-hmac-key' -or $_ -match '\.xlsx$' }).Count -gt 0) {
    Run 'git reset'
    Stop-Run 'S4' 'a .env file, a key, a backup, a spreadsheet or the run record was about to be committed. The staging was undone; nothing was committed.'
  }
  if ($staged.Count -eq 0) { Say '  nothing new to commit' }
  else {
    $msg = Join-Path $evidence 'commit-message.txt'
    [System.IO.File]::WriteAllText($msg, "Onboarding at scale (migration 38): openings, spreadsheet import, invite links, HR owner and paged lists, bulk acts, gate on Mark as joined, a checklist per role, ready to assign, the Deputy seat`n`nBrief 'Onboarding at scale (10 -> 100 -> 200+ hires)', Veda 11 Oct 2026; decisions as recommended.`n`nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`nClaude-Session: https://claude.ai/code/session_01VSgZRQeaqm6gr2gjyiknfF`n", $utf8)
    Run 'git commit -F release-evidence/commit-message.txt'
    if ($script:Code -ne 0) { Stop-Run 'S4' 'git commit failed' }
  }
  Run 'git push'
  if ($script:Code -ne 0) { Stop-Run 'S4' 'git push failed (run "git push" by hand)' }
  Run 'git rev-parse --short HEAD'
  $head = $script:Out.Trim()
  Say "  ok  pushed (head $head, $($staged.Count) files in this commit)"
  Mark 'S4' 'OK' "pushed, head $head ($($staged.Count) files); Vercel builds the staging app from it"
}

Summary
Say ''
if ($NoGit) {
  Say 'The database is on migration 38; the staging app is still the old one (-NoGit). Run this again without -NoGit soon.'
  Say 'RESULT: DATABASE DONE, APP NOT PUSHED'
  exit 0
}
Say 'In a few minutes (Vercel): docs/RUNSHEET_onboarding_at_scale.md, "Afterwards".'
Say 'RESULT: ONBOARDING AT SCALE ON STAGING'
exit 0
