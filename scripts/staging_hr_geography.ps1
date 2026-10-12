# HR BY GEOGRAPHY, on the practice system (staging): migration 39, the six server functions (build 2026-10-14) and the
# app built with them. Veda, 12 October 2026: an HR resource works only on the people based in her states; HR holds no
# seat ("HR should never be the State Manager"); a base location (state, district) for everyone. docs/FIX_LIST.md item
# 33; docs/RUNSHEET_hr_geography.md. Also the fault found on the way: the Add joiner form's opening, role and HR owner
# did not reach the database (create-user passed only the older fields).
# RUN IT ONLY WHEN VEDA HAS SAID SO: it deploys functions on the staging project, changes the staging database and
# PUSHES TO THE MAIN BRANCH (Vercel builds the staging app from that push). It asks once, in words, before any of it.
#
# What it does:
#   S0 checks (tools, the tested files, the staging project, exactly migration 39 waiting) and how things stand (read
#      only). It STOPS while anyone in HR holds a seat (Veda: the HR Admin ends it in the app first) and names them.
#   S1 deploys the six server functions (build 2026-10-14) and checks them.
#   S2 pushes migration 39. S3 reads the project back (smoke check, 36 rows; the earlier checks; ledger audit; logins;
#      functions; what migration 39 filled in) and names the HR resources who have no state yet and the people with
#      no base state: the HR Admin gives those on HR - Team and on each profile.
#   S4 commits and pushes the app.
# Nothing is deleted or rewritten. It refuses: any project but the staging one named below; a project that says it is
# production; files that are not the tested ones; any migration waiting other than migration 39.
#
# Usage (PowerShell, repository root), or double-click staging-hr-geography.cmd:
#   powershell -ExecutionPolicy Bypass -File scripts\staging_hr_geography.ps1
# Options:  -NoGit   stop after S3 (the database is then on migration 39 and the staging app is still the old one. Push
#                    soon after: the old app does not ask where a joiner is based)
# It can be run again after a stop: the functions and the migration are not done twice.
# The record of the run: release-evidence\staging-hr-geography-<time>.log (git-ignored). It reads no .env file and
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
$phrase = 'HR GEOGRAPHY'
$migration = '20261014000100_hr_geography.sql'
$functions = @('create-user', 'reset-password', 'ledger-check', 'daily-code', 'id-numbers', 'invite')

$evidence = Join-Path $root 'release-evidence'
if (-not (Test-Path $evidence)) { New-Item -ItemType Directory -Path $evidence | Out-Null }
$log = Join-Path $evidence ("staging-hr-geography-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
  if ($script:DbPushed) { Say 'The database is on migration 39. The staging app is the old one until S4 has run: run this again (it does not push the database twice). Meanwhile an HR resource sees only the people of her states, and the old Add joiner form does not ask where a person is based.' }
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

Say "GrainVeda - HR by geography, on the practice system - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

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

# The database files and the server functions must be the ones tested on 13 October 2026 (local stack: 33 test files,
# the upgrade path, the screens); the app must be the tested app, file for file.
$tested = [ordered]@{
  "supabase/migrations/$migration" = '88f9aa4f885c93e17e73e595273f4f470419fadb1606dfee1bad143f90709e6a'
  'tests/remote_smoke.sql' = 'c2ec8f1f84535d814d29bf4906e119f09da210dc0c2a92cbdc835478808b517a'
  'tests/remote_ledger_audit.sql' = '7f51601f01166f33145cefdd13ef92009c0390edf337c1c5167646e5d820f8d5'
}
$appListHash = 'dbd1b90bec28e57d12164c75302624a195147d48024e901f211ed6937ab5f3ef'
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
Say "  ok  migration 39, the smoke check and the ledger audit are the tested files; the app's and functions' $($script:AppCount) files are the tested ones"

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
  Say '  no migration is waiting: migration 39 was pushed before (S2 is skipped; S3 shows whether it is in place)'
} elseif ($waiting.Count -eq 1 -and $waiting[0] -eq $migration) {
  Say "  ok  exactly one migration is waiting: $migration"
} else {
  Stop-Run 'S0' ("waiting to be pushed: " + ($waiting -join ', ') + ". Only $migration was expected.")
}

# How things stand (read only). HR holds no seat: anyone in HR who still holds one is named, and the run stops until
# the HR Admin ends it (Veda, 12 Oct: she ends Neha's State Manager seat in the app).
Query 'q_before' "select 'before: hr_admins=' || (select count(*) from public.app_users where system_role = 'hr_admin' and status <> 'offboarded') || ' hr_resources=' || (select count(*) from public.app_users where system_role = 'hr_resource' and status <> 'offboarded') || ' people=' || (select count(*) from public.app_users where not external and system_role <> 'admin' and status <> 'offboarded') || ' end' as result;"
$before = [regex]::Match($script:Out, 'before: (.*?) end').Groups[1].Value
Say "  how things stand: $before"
Run "$sb secrets list"
if ($script:Code -ne 0) { Stop-Run 'S0' 'the project secrets could not be listed' }
if ($script:Out -notmatch '\bID_HMAC_KEY\b') { Stop-Run 'S0' 'the key ID_HMAC_KEY of id-numbers is not set: run staging-joiner-hr-data.cmd first (migration 37)' }
Say '  ok  the key of id-numbers is set (kept as it is)'
Query 'q_hr_seats' "select 'hrseat: ' || u.display_name || ' | ' || u.system_role || ' | ' || a.lens || ' ' || a.op_role || ' end' as result from public.assignments a join public.app_users u on u.id = a.employee_id where a.active and u.system_role in ('hr_admin', 'hr_resource') order by u.display_name;"
$hrSeats = @([regex]::Matches($script:Out, 'hrseat: (.*?) end') | ForEach-Object { $_.Groups[1].Value })
if ($hrSeats.Count -gt 0) {
  foreach ($h in $hrSeats) { Say "  HR person with a seat: $h" }
  Stop-Run 'S0' ("HR holds no seat: the HR Admin first ends these seats (People & access, the person, End on the assignment): " + ($hrSeats -join ' ; ') + '. Nothing was changed.')
}
Say '  ok  nobody in HR holds a seat'
$mailSet = ($script:Out -match '\bMAIL_API_KEY\b')
if ($mailSet) { Say '  a mail sender key is set: invites and reminders will be emailed' }
else { Say '  no mail sender is set: invite links are copied by HR; reminders wait in the queue (decisions 1 and 2)' }
Say ''
Say '  This will:'
Say '   - deploy the six server functions (build 2026-10-14; create-user now passes the opening, role, HR owner and base location)'
if (-not $dbDone) { Say '   - push migration 39 to the practice database: an HR resource works only on the people of her states;' }
if (-not $dbDone) { Say '     HR holds no seat; a base state and district for everyone, filled in where the data leaves no doubt.' }
if (-not $dbDone) { Say '     HR resources see NOBODY until the HR Admin gives them their states (HR - Team). Nothing is deleted.' }
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
Say '  ok  six functions, build 2026-10-14'
Mark 'S1' 'OK' 'six functions deployed; FUNCTIONS DEPLOYED AND CURRENT'

# ---------------------------------------------------------------------------------------------------------------
# S2  push migration 39
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S2  push migration 39'
if ($dbDone) {
  Say '  NOT RUN: nothing waiting'
  Mark 'S2' 'NOT RUN' 'migration 39 was already pushed'
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
  'joiner HR data', 'onboarding at scale', 'hr by geography', 'HR holds no seat', 'reminder round', 'nightly ledger check')
Run "$sb db query --linked -f tests/remote_smoke.sql"
if ($script:Code -ne 0) { Stop-Run 'S3' 'the smoke check could not be run' }
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
Say "  smoke rows read: $($present.Count) of 36, OK: $okCount"
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
# What migration 39 did (read only) and what the HR Admin does next: states for each HR resource, a base state for
# each person the data could not place.
Query 'q_after' "select 'after: based_from_openings=' || coalesce((select (detail->>'from_openings') from public.audit_log where action = 'base_locations_filled' order by id desc limit 1), '0') || ' based_from_seats=' || coalesce((select (detail->>'from_seats') from public.audit_log where action = 'base_locations_filled' order by id desc limit 1), '0') || ' not_based=' || (select count(*) from public.app_users u left join public.employee_org e on e.employee_id = u.id where not u.external and u.system_role <> 'admin' and u.status <> 'offboarded' and e.base_state_id is null) || ' hr_states=' || (select count(*) from public.hr_states where ended_at is null) || ' end' as result;"
$after = [regex]::Match($script:Out, 'after: (.*?) end').Groups[1].Value
Say "  after: $after"
Query 'q_todo' "select 'todo: ' || x || ' end' as result from (select 'HR resource with no state yet: ' || u.display_name as x from public.app_users u where u.system_role = 'hr_resource' and u.status <> 'offboarded' and not exists (select 1 from public.hr_states h where h.employee_id = u.id and h.ended_at is null) union all select 'no base state: ' || u.display_name from public.app_users u left join public.employee_org e on e.employee_id = u.id where not u.external and u.system_role <> 'admin' and u.status <> 'offboarded' and e.base_state_id is null) t order by 1;"
$todo = @([regex]::Matches($script:Out, 'todo: (.*?) end') | ForEach-Object { $_.Groups[1].Value })
Say "  for the HR Admin to do in the app: $($todo.Count)"
foreach ($x in $todo) { Say "    $x" }
$smokeNote = "smoke $okCount of 36 OK"
if ($warn.Count -gt 0) { $smokeNote += '; NOT OK (standing): ' + ($warn -join ' ; ') }
Say '  ok  smoke, the earlier checks, ledger audit, logins, functions'
Mark 'S3' 'OK' "$smokeNote; 35 and 36 OK; $auditLine; NO LOGIN WITHOUT A PERSON; FUNCTIONS DEPLOYED AND CURRENT; $after; for the HR Admin: $($todo.Count)"

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
    [System.IO.File]::WriteAllText($msg, "HR by geography (migration 39): an HR resource works for her states, HR holds no seat, a base location for everyone; create-user passes the opening, role, HR owner and base location`n`nVeda, 12 Oct 2026.`n`nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`nClaude-Session: https://claude.ai/code/session_01VSgZRQeaqm6gr2gjyiknfF`n", $utf8)
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
  Say 'The database is on migration 39; the staging app is still the old one (-NoGit). Run this again without -NoGit soon.'
  Say 'RESULT: DATABASE DONE, APP NOT PUSHED'
  exit 0
}
Say 'In a few minutes (Vercel): docs/RUNSHEET_hr_geography.md, "Afterwards" (the HR Admin gives the states first).'
Say 'RESULT: HR GEOGRAPHY ON STAGING'
exit 0
