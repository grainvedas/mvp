# JOINER CHECKLIST AND HR DATA, on the practice system (staging): migration 37, the five server functions with the
# key of the new one, and the app built with them. Brief "GrainVeda MVP - Joiner checklist and HR data improvements"
# (Veda, 11 October 2026; docs/FIX_LIST.md item 31; docs/RUNSHEET_joiner_hr_data.md).
# RUN IT ONLY WHEN VEDA HAS SAID SO: it sets a secret and deploys functions on the staging project, changes the
# staging database and PUSHES TO THE MAIN BRANCH (Vercel builds the staging app from that push). It asks once, in
# words, before any of it.
#
# What it does:
#   S0 checks (tools, the tested files, the staging project, exactly migration 37 waiting) and records how things stand
#      (read only: people joining, documents, stored files by kind, whether the key is set); asks.
#   S1 the key of the id-numbers function: made here (32 random bytes), NEVER PRINTED, written to the git-ignored file
#      .env.id-hmac-key.staging (Veda moves it to her password manager, then deletes the file) and set as the project's
#      secret ID_HMAC_KEY (with ID_HMAC_KEY_ID=k1). If the project already has the key, it is left alone: a new key
#      would make every fingerprint already saved useless for finding duplicates.
#   S2 deploys the five server functions (build 2026-10-12) and checks them: all current, the key set.
#   S3 pushes migration 37. S4 reads the project back (smoke check, 32 rows; the earlier checks; ledger audit; logins;
#      functions) and LISTS the files already in the HR documents store (read only: none is deleted or changed).
#   S5 commits and pushes the app.
# Nothing is deleted or rewritten. It refuses: any project but the staging one named below; a project that says it is
# production; files that are not the tested ones; any migration waiting other than migration 37.
#
# Usage (PowerShell, repository root), or double-click staging-joiner-hr-data.cmd:
#   powershell -ExecutionPolicy Bypass -File scripts\staging_joiner_hr_data.ps1
# Options:  -NoGit   stop after S4 (the database is then on migration 37 and the staging app is still the old one:
#                    joiners cannot save the identity, bank or PF step until the app is pushed. Push soon after)
# It can be run again after a stop: the key, the functions and the migration are not done twice.
# The record of the run: release-evidence\staging-joiner-hr-data-<time>.log (git-ignored). It reads no .env file except
# the key file it writes, and prints no key or password.
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
$phrase = 'JOINER HR DATA'
$migration = '20261012000100_joiner_checklist_hr_data.sql'
$keyFile = '.env.id-hmac-key.staging'
$functions = @('create-user', 'reset-password', 'ledger-check', 'daily-code', 'id-numbers')

$evidence = Join-Path $root 'release-evidence'
if (-not (Test-Path $evidence)) { New-Item -ItemType Directory -Path $evidence | Out-Null }
$log = Join-Path $evidence ("staging-joiner-hr-data-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
  if ($script:DbPushed) { Say 'The database is on migration 37. The staging app is the old one until S5 has run: run this again (it does not push the database or the key twice). Until then a joiner cannot save an identity step (the old app sends the last four, which migration 37 refuses).' }
  elseif ($script:Changed) { Say 'The database was not changed. The key and/or the server functions were set: the old app keeps working (Add joiner now needs a phone).' }
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

Say "GrainVeda - joiner checklist and HR data, on the practice system - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

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

# The database files and the server functions must be the ones tested on 11 October 2026 (local stack: 31 test files,
# the upgrade path, the screens, the search for typed numbers); the app must be the tested app, file for file.
$tested = [ordered]@{
  "supabase/migrations/$migration" = '80148d8112ff7c1bd1f4244c73a399ac1db4f0ce3f8a6e2d1ce3c3045a0acec5'
  'tests/remote_smoke.sql' = '6a03e4c0d16736262c583d690da6e333d5ddb78aa973d2edbd615230eee0b23b'
  'tests/remote_ledger_audit.sql' = '7f51601f01166f33145cefdd13ef92009c0390edf337c1c5167646e5d820f8d5'
}
$appListHash = '2ddb13a9b604e674a13723305fa045a73025aeefb70de4e5a8de484177739d93'
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
Say "  ok  migration 37, the smoke check and the ledger audit are the tested files; the app's and functions' $($script:AppCount) files are the tested ones"

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
  Say '  no migration is waiting: migration 37 was pushed before (S3 is skipped; S4 shows whether it is in place)'
} elseif ($waiting.Count -eq 1 -and $waiting[0] -eq $migration) {
  Say "  ok  exactly one migration is waiting: $migration"
} else {
  Stop-Run 'S0' ("waiting to be pushed: " + ($waiting -join ', ') + ". Only $migration was expected.")
}

# How things stand (read only; no names, no numbers): people joining, identity records, stored HR files by kind.
Query 'q_before' "select 'before: joining=' || (select count(*) from public.app_users where status in ('invited', 'onboarding')) || ' docs=' || (select count(*) from public.employee_docs) || ' docs_with_last4=' || (select count(*) from public.employee_docs where coalesce(pan_last4, aadhaar_last4, bank_last4, pf_uan_last4) is not null) || ' hr_files=' || coalesce((select string_agg(kind || ':' || n, ',' order by kind) from (select kind, count(*) as n from public.employee_files group by kind) x), 'none') || ' stored_objects=' || (select count(*) from storage.objects where bucket_id = 'hr-docs') || ' end' as result;"
$before = [regex]::Match($script:Out, 'before: (.*?) end').Groups[1].Value
Say "  how things stand: $before"
Run "$sb secrets list"
if ($script:Code -ne 0) { Stop-Run 'S0' 'the project secrets could not be listed' }
$keySet = ($script:Out -match '\bID_HMAC_KEY\b')
if ($keySet) { Say '  the key ID_HMAC_KEY is already set on the project: it is kept' }
else { Say '  the key ID_HMAC_KEY is not set yet' }
Say ''
Say '  This will:'
if (-not $keySet) {
  if (Test-Path (Join-Path $root $keyFile)) { Say "   - set the key from $keyFile (made by an earlier run) as the project's secret. Not shown." }
  else { Say "   - make the key of the id-numbers function and set it as the project's secret. Not shown; a copy goes to $keyFile" }
}
Say '   - deploy the five server functions (build 2026-10-12; id-numbers is new; Add joiner needs a phone)'
if (-not $dbDone) { Say '   - push migration 37 to the practice database: duplicates refused, masked Aadhaar only, Personal details step,' }
if (-not $dbDone) { Say '     no step overdue on the day added, steps in any order unless the template says. Nothing is deleted.' }
if (-not $NoGit) { Say '   - commit and PUSH TO THE MAIN BRANCH: Vercel then builds the staging app.' }
Say ''
$answer = Read-Host "  Only if Veda has said so: type  $phrase  and press Enter (anything else stops)"
[System.IO.File]::AppendAllText($log, "  typed: $answer`r`n", $utf8)
if ($answer -cne $phrase) { Stop-Run 'S0' 'not confirmed' }
Mark 'S0' 'OK' "practice project $stagingRef, environment staging, tested files, $($script:AppCount) app and function files; waiting: $(if ($dbDone) { 'nothing' } else { $migration }); $before; confirmed in words"

# ---------------------------------------------------------------------------------------------------------------
# S1  the key of the id-numbers function (never printed)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S1  the key of the id-numbers function'
if ($keySet) {
  Say '  NOT RUN: the project has the key already (a new one would make the saved fingerprints useless)'
  Mark 'S1' 'NOT RUN' 'the key was already set; kept'
} else {
  $kf = Join-Path $root $keyFile
  if (-not (Test-Path $kf)) {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $key = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $body = "# The key of the id-numbers function on the PRACTICE project $stagingRef, made $(Get-Date -Format 'yyyy-MM-dd HH:mm').`n" +
            "# Move it to your password manager, then delete this file. Never send it to anybody, never commit it.`n" +
            "# Lost: nothing saved is lost or exposed; new numbers cannot be compared with old ones (docs/OPERATIONS.md).`n" +
            "ID_HMAC_KEY=$key`nID_HMAC_KEY_ID=k1`n"
    [System.IO.File]::WriteAllText($kf, $body, $utf8)
    $key = $null; $body = $null
    Say "  made; written to $keyFile (not shown)"
  } else { Say "  using $keyFile from an earlier run (not shown)" }
  Run "git check-ignore -q $keyFile"
  if ($script:Code -ne 0) { Stop-Run 'S1' "$keyFile is not git-ignored. Nothing was set." }
  Run "$sb secrets set --env-file $keyFile"
  if ($script:Code -ne 0) { Stop-Run 'S1' 'supabase secrets set failed' }
  $script:Changed = $true
  Run "$sb secrets list"
  if ($script:Out -notmatch '\bID_HMAC_KEY\b' -or $script:Out -notmatch '\bID_HMAC_KEY_ID\b') { Stop-Run 'S1' 'the key is not listed after setting it' }
  Say "  ok  set. Move $keyFile to your password manager, then delete the file."
  Mark 'S1' 'OK' "key set (not shown); copy in $keyFile until Veda moves it"
}

# ---------------------------------------------------------------------------------------------------------------
# S2  the five server functions
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S2  deploy the server functions'
foreach ($f in $functions) {
  $extra = ''
  if ($f -eq 'ledger-check') { $extra = ' --no-verify-jwt' }
  Run "$sb functions deploy $f$extra"
  if ($script:Code -ne 0) { Stop-Run 'S2' "deploying $f failed" }
  $script:Changed = $true
}
Run 'node scripts/check_functions.mjs'
if ($script:Out -notmatch 'FUNCTIONS DEPLOYED AND CURRENT') { Stop-Run 'S2' 'the functions are not all current or the key is not set (read the lines above). The database was not changed.' }
Say '  ok  five functions, build 2026-10-12, id-numbers configured'
Mark 'S2' 'OK' 'five functions deployed; FUNCTIONS DEPLOYED AND CURRENT'

# ---------------------------------------------------------------------------------------------------------------
# S3  push migration 37
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S3  push migration 37'
if ($dbDone) {
  Say '  NOT RUN: nothing waiting'
  Mark 'S3' 'NOT RUN' 'migration 37 was already pushed'
} else {
  Run "$sb db push --linked --yes"
  if ($script:Code -ne 0) { Stop-Run 'S3' 'db push failed (one transaction per migration: read the error above)' }
  $script:DbPushed = $true
  Run "$sb db push --linked --dry-run"
  if (@([regex]::Matches($script:Out, '\b\d{14}_[A-Za-z0-9_]+\.sql')).Count -gt 0) { Stop-Run 'S3' 'a migration is still waiting after the push' }
  Say '  ok  pushed; nothing is waiting'
  Mark 'S3' 'OK' "$migration pushed"
}

# ---------------------------------------------------------------------------------------------------------------
# S4  read the project back; list the stored HR files (read only)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S4  checks'
$checks = @('extensions', 'schema app', 'tables (15)', 'RLS on every table', 'stage_definitions (16)', 'ledger guard trigger',
  'footprint triggers', 'ledger chain intact', 'seed: Kalanamak crop', 'environment', 'demo data', 'api surface closed',
  'auth.uid mapping', 'public journey rpc', 'phase 3 objects', 'phase 4 objects', 'phase 4 triggers', 'ledger read by stage',
  'direct writes closed', 'evidence in the ledger', 'public page data', 'capture time, verdict preview',
  'a new client can be read back', 'identity layer objects', 'people moved to assignments', 'the two seats',
  'manager rules ask about the scope', 'people written only by their actions', 'once-a-day sign-in code', 'the admin oversees',
  'joiner HR data', 'nightly ledger check')
Run "$sb db query --linked -f tests/remote_smoke.sql"
if ($script:Code -ne 0) { Stop-Run 'S4' 'the smoke check could not be run' }
$text = $script:Out
$at = @{}
foreach ($x in $checks) { $at[$x] = $text.IndexOf($x, [System.StringComparison]::Ordinal) }
$missing = @($checks | Where-Object { $at[$_] -lt 0 })
# One row says how the project is set up, not what this run did: whether the nightly check is scheduled (pg_cron).
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
Say "  smoke rows read: $($present.Count) of 32, OK: $okCount"
foreach ($w in $warn) { Say "  NOT OK (standing, does not stop): $w" }
foreach ($b in $bad) { Say "  NOT OK: $b" }
if ($missing.Count -gt 0) { Stop-Run 'S4' ("smoke rows not found in the output: " + ($missing -join ', ')) }
if ($bad.Count -gt 0) { Stop-Run 'S4' ("smoke rows not OK: " + ($bad -join ' ; ')) }

Run "$sb db query --linked -f tests/remote_ledger_audit.sql"
if ($script:Code -ne 0 -or $script:Out -notmatch 'NO FINDINGS \(') { Stop-Run 'S4' "the ledger audit did not answer 'NO FINDINGS ('" }
$auditLine = [regex]::Match($script:Out, 'NO FINDINGS \([^)]*\)').Value
Run 'node scripts/check_logins.mjs'
if ($script:Out -notmatch 'NO LOGIN WITHOUT A PERSON') { Stop-Run 'S4' "'NO LOGIN WITHOUT A PERSON' was not printed" }
Run 'node scripts/check_functions.mjs'
if ($script:Out -notmatch 'FUNCTIONS DEPLOYED AND CURRENT') { Stop-Run 'S4' 'the functions are no longer all current' }
Query 'q_two_jobs' "select 'twojobs=' || case when to_regprocedure('app.acts_as_hr()') is null or to_regprocedure('app.admin_trends(integer)') is null then 'MISSING' when position('is_hr_admin' in pg_get_functiondef(to_regprocedure('app.may_assign(assignment_lens, op_role, uuid)'))) = 0 then 'OLD' else 'OK' end || ' hrjoined=' || case when position('hr_admin_activated_by_admin' in pg_get_functiondef(to_regprocedure('app.activate_joiner(uuid)'))) = 0 then 'OLD' else 'OK' end || ' end' as result;"
$prev = [regex]::Match($script:Out, 'twojobs=(\w+) hrjoined=(\w+) end')
if ($prev.Groups[1].Value -ne 'OK' -or $prev.Groups[2].Value -ne 'OK') { Stop-Run 'S4' "the checks of migrations 35 and 36 answered '$($prev.Value)' (expected OK OK)" }
# What migration 37 did to open checklists, and the HR files already stored (read only). File names pass through
# app.scrub_numbers: a name that holds a number is shown as [number removed].
Query 'q_after' "select 'after: personal_steps_added=' || (select count(*) from public.onboarding_tasks where kind = 'personal') || ' not_checked=' || (select count(*) from public.employee_docs where coalesce(pan_last4, aadhaar_last4) is not null and pan_hmac is null and aadhaar_hmac is null) || ' end' as result;"
$after = [regex]::Match($script:Out, 'after: (.*?) end').Groups[1].Value
Say "  after: $after"
Query 'q_hr_files' "select 'hrfile: ' || f.kind || ' | ' || to_char(f.created_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD') || ' | person ' || u.status || ' | ' || app.scrub_numbers(coalesce(f.file_name, '-')) || ' | ' || case when f.removed_at is not null then 'image deleted' when exists (select 1 from storage.objects o where o.bucket_id = 'hr-docs' and o.name = f.storage_path) then 'stored' else 'NOT IN STORE' end || ' end' as result from public.employee_files f join public.app_users u on u.id = f.employee_id order by f.created_at;"
$files = @([regex]::Matches($script:Out, 'hrfile: (.*?) end') | ForEach-Object { $_.Groups[1].Value })
Say "  HR files already stored: $($files.Count) (none deleted or changed by this run)"
foreach ($f in $files) { Say "    $f" }
$smokeNote = "smoke $okCount of 32 OK"
if ($warn.Count -gt 0) { $smokeNote += '; NOT OK (standing): ' + ($warn -join ' ; ') }
Say '  ok  smoke, the earlier checks, ledger audit, logins, functions'
Mark 'S4' 'OK' "$smokeNote; 35 and 36 OK; $auditLine; NO LOGIN WITHOUT A PERSON; FUNCTIONS DEPLOYED AND CURRENT; $after; HR files listed: $($files.Count)"

# ---------------------------------------------------------------------------------------------------------------
# S5  the app: commit and push (Vercel builds the push)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S5  commit and push the app'
if ($NoGit) {
  Say '  NOT RUN: -NoGit. The staging app is still the old one: joiners cannot save identity, bank or PF steps. Push soon.'
  Mark 'S5' 'NOT RUN' 'switched off with -NoGit: the staging app is still the old build'
} else {
  $envPath = '(?m)(^|[\\/\s"])\.env($|[.\s"-])'
  Run 'git status --short'
  if ($script:Code -ne 0) { Stop-Run 'S5' 'git status failed' }
  if ($script:Out -match $envPath) { Stop-Run 'S5' 'git status shows a .env file. Nothing was committed. It must be git-ignored first.' }
  Run 'git add -A'
  if ($script:Code -ne 0) { Stop-Run 'S5' 'git add failed' }
  Run 'git diff --cached --name-only'
  $staged = @($script:Out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^warning:' -and $_ -notmatch '^The file will have' })
  if (@($staged | Where-Object { $_ -match $envPath -or $_ -match '^release-evidence/' -or $_ -match '(^|/)backups/' -or $_ -match 'id-hmac-key' }).Count -gt 0) {
    Run 'git reset'
    Stop-Run 'S5' 'a .env file, the key, a backup or the run record was about to be committed. The staging was undone; nothing was committed.'
  }
  if ($staged.Count -eq 0) { Say '  nothing new to commit' }
  else {
    $msg = Join-Path $evidence 'commit-message.txt'
    [System.IO.File]::WriteAllText($msg, "Joiner checklist and HR data (migration 37): duplicate numbers refused by fingerprint, masked Aadhaar only, Personal details, phone required, no day-one overdue, steps in any order, joiner help and first-day details`n`nBrief 'Joiner checklist and HR data improvements', Veda 11 Oct 2026.`n`nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`nClaude-Session: https://claude.ai/code/session_01VSgZRQeaqm6gr2gjyiknfF`n", $utf8)
    Run 'git commit -F release-evidence/commit-message.txt'
    if ($script:Code -ne 0) { Stop-Run 'S5' 'git commit failed' }
  }
  Run 'git push'
  if ($script:Code -ne 0) { Stop-Run 'S5' 'git push failed (run "git push" by hand)' }
  Run 'git rev-parse --short HEAD'
  $head = $script:Out.Trim()
  Say "  ok  pushed (head $head, $($staged.Count) files in this commit)"
  Mark 'S5' 'OK' "pushed, head $head ($($staged.Count) files); Vercel builds the staging app from it"
}

Summary
Say ''
if (Test-Path (Join-Path $root $keyFile)) { Say "REMEMBER: move $keyFile to your password manager, then delete the file." }
if ($NoGit) {
  Say 'The database is on migration 37; the staging app is still the old one (-NoGit). Run this again without -NoGit soon.'
  Say 'RESULT: DATABASE DONE, APP NOT PUSHED'
  exit 0
}
Say 'In a few minutes (Vercel): docs/RUNSHEET_joiner_hr_data.md, "Afterwards" (and the log search, step 7).'
Say 'RESULT: JOINER HR DATA ON STAGING'
exit 0
