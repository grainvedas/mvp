# HISTORICAL: this ran on 6 October 2026 and its job is done (docs/VERIFICATION_LOG.md). It will stop at D0 now, on
# purpose: tests/remote_smoke.sql has changed since (the fresh start), and the practice system no longer holds the
# demo data its steps D9 and D10 expect. Kept as the record of how part D was done and as the pattern for part F.
#
# Phase 5, part D on STAGING in one command: docs/RUNSHEET_phase5.md steps D1 to D12, with each step's "Expect"
# checked by this script. It stops at the first step that does not match and never goes on by itself.
# It reads no .env file and prints no key or password (the scripts it calls write passwords to git-ignored files).
#
# Usage (PowerShell, repository root):
#   powershell -ExecutionPolicy Bypass -File scripts\staging_phase5.ps1
# or double-click staging-phase5.cmd in the repository root (the same thing, and the window stays open at the end).
# Options:
#   -From D5            start at a step (after a stop that has been looked at). D0 always runs.
#   -SkipCheck D5,D8    keep the output of these steps without judging it (only after a person has read it)
#   -SkipLocalTests     do not run D1 (the local test run)
#   -PgBin <folder>     where psql.exe, initdb.exe and pg_ctl.exe are, for D1 (PostgreSQL 16 or 17)
#   -NoGit              stop before the commit and the push (step D11b)
#   -RunT1              also run D12 (needs the Phone provider ON on this project)
# The record of the run: release-evidence\staging-phase5-<time>.log (git-ignored).
#
# This file is plain ASCII on purpose: Windows PowerShell 5.1 reads a script without a byte-order mark as ANSI.
# No function here hands back a result except Wanted (which prints nothing): in PowerShell a function returns
# everything printed inside it, and that made tests/run_local.ps1 report success whatever happened
# (docs/FIX_LIST.md fault 36). Results go to $script: names.
param(
  [string]$From = 'D0',
  [string]$SkipCheck = '',
  [switch]$SkipLocalTests,
  [string]$PgBin = '',
  [switch]$NoGit,
  [switch]$RunT1
)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$utf8 = New-Object System.Text.UTF8Encoding $false
try { [Console]::OutputEncoding = $utf8 } catch { }
$env:GIT_TERMINAL_PROMPT = '0'

$order = @('D0','D1','D2','D3','D4','D5','D6','D6b','D7','D8','D9','D10','D11','D11b','D12')
if ($order -notcontains $From) { Write-Host "Unknown step '$From'. Steps: $($order -join ' ')"; exit 1 }
$skip = @($SkipCheck -split '[,; ]+' | Where-Object { $_ })
foreach ($s in $skip) { if ($order -notcontains $s) { Write-Host "Unknown step '$s' in -SkipCheck. Steps: $($order -join ' ')"; exit 1 } }
if ($skip -contains 'D0') { Write-Host 'D0 is never skipped: it checks that this is the staging project and that the files are the tested ones.'; exit 1 }

$evidence = Join-Path $root 'release-evidence'
if (-not (Test-Path $evidence)) { New-Item -ItemType Directory -Path $evidence | Out-Null }
$log = Join-Path $evidence ("staging-phase5-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:Out = ''
$script:Code = 0
$script:Results = New-Object System.Collections.Generic.List[string]
$script:DbPushed = $false
$script:AppPushed = $false

function Say([string]$text) {
  Write-Host $text
  [System.IO.File]::AppendAllText($log, $text + "`r`n", $utf8)
}
function Mark([string]$step, [string]$status, [string]$note) {
  $script:Results.Add(('{0,-5} {1,-8} {2}' -f $step, $status, $note))
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
  if ($script:DbPushed -and -not $script:AppPushed) {
    Say 'The database is on the new build. If the app has not been pushed yet (step D11b), the Users & Roles page of'
    Say 'the staging app does not work until it is (everything else does). Nothing needs undoing.'
  }
  Summary
  Say 'RESULT: STOPPED'
  exit 1
}
# A step's output did not match its "Expect". Stops, unless the step was named in -SkipCheck.
function Expect([string]$step, [bool]$ok, [string]$why) {
  if ($ok) { return }
  if ($skip -contains $step) { Say "  NOT JUDGED (-SkipCheck $step): $why"; return }
  Stop-Run $step $why
}
function Wanted([string]$step) {
  if ([array]::IndexOf($order, $step) -lt [array]::IndexOf($order, $From)) { return $false }
  return $true
}
# Runs one command line through cmd with no keyboard attached (a tool that asks a question fails instead of
# waiting for ever), shows and records every line, and leaves the text in $script:Out and the exit code in $script:Code.
# -ErrorsToScreen: the tool's error lines are left on the screen and are not in the record (see D1 for why).
function Run([string]$cmdline, [switch]$ErrorsToScreen) {
  Say "> $cmdline"
  $buf = New-Object System.Collections.Generic.List[string]
  $tail = ' < NUL 2>&1'
  if ($ErrorsToScreen) { $tail = ' < NUL' }
  & cmd /c "$cmdline$tail" | ForEach-Object { $l = "$_"; Write-Host "  $l"; $buf.Add($l) }
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

Say "GrainVeda - Phase 5 part D on staging - $(Get-Date -Format 'yyyy-MM-dd HH:mm') - from step $From"
if ($skip.Count -gt 0) { Say "not judged (-SkipCheck): $($skip -join ', ')" }

# ---------------------------------------------------------------------------------------------------------------
# D0  pre-flight: the tools, the files, the project
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== D0  pre-flight'
$sb = ''
if (Get-Command supabase -ErrorAction SilentlyContinue) { $sb = 'supabase' }
elseif (Test-Path (Join-Path $root 'web/node_modules/.bin/supabase.cmd')) { $sb = 'web\node_modules\.bin\supabase.cmd' }
elseif (Test-Path (Join-Path $root 'node_modules/.bin/supabase.cmd')) { $sb = 'node_modules\.bin\supabase.cmd' }
if (-not $sb) { Stop-Run 'D0' 'the supabase command was not found (not on PATH, not in node_modules). Run this from the terminal where supabase db push was run before.' }
foreach ($tool in @('node', 'git')) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Stop-Run 'D0' "the $tool command was not found on PATH" }
}
Run "$sb --version"
if ($script:Code -ne 0) { Stop-Run 'D0' 'supabase --version failed' }
Run 'node --version'
if ($script:Code -ne 0) { Stop-Run 'D0' 'node --version failed' }
$nodeVersion = $script:Out.Trim()

# What goes to staging must be, byte for byte (line ends aside), what was tested on 6 October 2026: 878 database
# checks, the upgrade rehearsal on a database with data, 193 unit tests, 53 screen tests. A changed file stops the run.
$tested = [ordered]@{
  'supabase/migrations/20261006000100_identity_schema.sql' = '84063a58c7c7c498f0fbbaecef335b2dd5c96b8b8ba555ab22277906d576ad75'
  'supabase/migrations/20261006000200_union_access.sql' = '3c375740c9e874428119fb1b6ee2cbeaffd3f51ece819dbd395665a5969ff12d'
  'supabase/migrations/20261006000300_people_lifecycle.sql' = '56e836ce6e73593bfb6358c81777e50e380dfc3423bc7820ec8c2c8f3e64800d'
  'supabase/seeds/06_identity_demo.sql' = 'db1c774bcfb7e0da94216f0acdac6e87cd6c5ac6b29f7ea7c0406c88096ba4b7'
  'supabase/functions/_shared/mail.ts' = '7f94dc78e025ebf0528d2c39e2a5c293779958c55152e1cbb3cc251a32375a5b'
  'supabase/functions/create-user/handler.ts' = '4c748e5d4c4685345ebdefaa4897e1221cc02751692ddac4dfdd30ea3a6d270a'
  'supabase/functions/create-user/index.ts' = 'a67cb3b62c70d97ea3f1b18632646619cca436e402290480dda6c25c2d092a17'
  'supabase/functions/daily-code/handler.ts' = '2188ab6bcc0c574abea0beb77659e57b939d61dadac4a77283d5ce154ca7a702'
  'supabase/functions/daily-code/index.ts' = 'b83495ebe4386b69954f6cd1c08f740a5ff739947f8c99870ea1afb4d11e141d'
  'supabase/functions/ledger-check/handler.ts' = '71578a93dfcb5e3d16f71c69c892cb2745b1a4f3428c04a0eb6f06dd0e15cce7'
  'supabase/functions/ledger-check/index.ts' = 'c3b85c6d170e5d127e03c89baf9ee30e1eaea69f6598b02babc78408f62b33da'
  'supabase/functions/reset-password/handler.ts' = '1716d4e0b69116306f2eeb449c0be2ca6e1e19f6e38dd5cf121eae290232fec5'
  'supabase/functions/reset-password/index.ts' = 'f159f099fc530c723b939137feb02d39792f49c3aa3e6a973e1c82909fa137e0'
  'tests/remote_smoke.sql' = '1c5e97332e64bee8bdce6ade9f255b256fc5d6ba3b729e655cd434954df13389'
  'tests/remote_ledger_audit.sql' = 'a8b970bdf46f6561cc8019dc70598cfe35201671ac4634c5fba284c350033608'
}
$changed = @()
foreach ($path in $tested.Keys) {
  if (-not (Test-Path (Join-Path $root $path))) { $changed += "$path (missing)"; continue }
  Hash-Text $path
  if ($script:Hash -ne $tested[$path]) { $changed += $path }
}
if ($changed.Count -gt 0) {
  Stop-Run 'D0' ("these files are not the ones that were tested (someone changed them after 6 October): " + ($changed -join ', ') + '. Nothing was sent. Tell Claude: the change has to be merged and tested first.')
}
Say "  ok  $($tested.Count) files are the tested ones"
$count = @(Get-ChildItem (Join-Path $root 'supabase/migrations') -Filter '*.sql').Count
if ($count -ne 33) { Stop-Run 'D0' "supabase/migrations holds $count files, 33 expected" }
Say '  ok  33 migration files'

# The linked project must be the practice system. Production is done by docs/RUNSHEET_phase5.md part F, by a person.
Query 'q_environment' "select 'environment=' || app.environment() as e;"
if ($script:Code -ne 0) { Stop-Run 'D0' 'the linked project could not be asked which system it is (is supabase logged in and linked? run: supabase projects list)' }
if ($script:Out -match 'environment=production') { Stop-Run 'D0' 'THE LINKED PROJECT IS PRODUCTION. This script is for staging only. Nothing was sent.' }
if ($script:Out -notmatch 'environment=staging') { Stop-Run 'D0' 'the linked project did not answer environment=staging. Nothing was sent.' }
Say '  ok  the linked project is staging'
Mark 'D0' 'OK' 'tools found, 15 files are the tested ones, linked project is staging'

# ---------------------------------------------------------------------------------------------------------------
# D1  the local test run, on a throwaway PostgreSQL that this step makes and removes
# ---------------------------------------------------------------------------------------------------------------
# Starts a PostgreSQL tool and waits for that one process only (pg_ctl leaves the server running behind it: waiting on
# its output, or on the whole process tree, would wait for ever). Exit code in $script:Code, -1 when it ran out of time.
function Start-Tool([string]$exe, [string[]]$arguments, [int]$seconds) {
  $sp = @{ FilePath = $exe; ArgumentList = $arguments; PassThru = $true }
  if ($env:OS -eq 'Windows_NT') { $sp.WindowStyle = 'Hidden' }
  $p = Start-Process @sp
  $handle = $p.Handle
  if (-not $p.WaitForExit($seconds * 1000)) { try { $p.Kill() } catch { }; $script:Code = -1; return }
  $script:Code = $p.ExitCode
}
function Local-Tests() {
  $script:D1 = 'NOT RUN'
  $script:D1Note = ''
  $cands = @()
  if ($PgBin) { $cands += $PgBin }
  if ($env:PGBIN) { $cands += $env:PGBIN }
  $found = Get-Command psql.exe -ErrorAction SilentlyContinue
  if ($found) { $cands += (Split-Path $found.Source) }
  $places = @("$env:ProgramFiles\PostgreSQL\*\bin", "${env:ProgramFiles(x86)}\PostgreSQL\*\bin", "$env:LOCALAPPDATA\Programs\PostgreSQL\*\bin",
              "$env:USERPROFILE\scoop\apps\postgresql*\current\bin", "$env:USERPROFILE\pgsql\bin", "$env:USERPROFILE\PostgreSQL\*\bin",
              'C:\pgsql\bin', 'D:\pgsql\bin', 'C:\PostgreSQL\*\bin', 'D:\PostgreSQL\*\bin', "$env:USERPROFILE\anaconda3\Library\bin")
  foreach ($g in $places) {
    $cands += @(Resolve-Path -Path $g -ErrorAction SilentlyContinue | Sort-Object Path -Descending | ForEach-Object { $_.Path })
  }
  $bin = ''
  foreach ($d in $cands) {
    if (-not $d) { continue }
    $all = $true
    foreach ($exe in @('psql.exe', 'initdb.exe', 'pg_ctl.exe', 'createdb.exe', 'dropdb.exe')) { if (-not (Test-Path (Join-Path $d $exe))) { $all = $false } }
    if (-not $all) { continue }
    $v = (& (Join-Path $d 'psql.exe') --version 2>$null | Out-String)
    if ($v -match '(\d+)\.\d+' -and [int]$Matches[1] -ge 16) { $bin = $d; Say "  PostgreSQL tools: $d ($($v.Trim()))"; break }
    Say "  passed over $d ($($v.Trim())): PostgreSQL 16 or 17 is needed"
  }
  if (-not $bin) { $script:D1Note = 'no PostgreSQL 16 or 17 tools (psql, initdb, pg_ctl) were found on this computer; give their folder with -PgBin'; return }

  $port = 0
  foreach ($p in 5433..5442) {
    try { $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), $p; $l.Start(); $l.Stop(); $port = $p; break } catch { }
  }
  if ($port -eq 0) { $script:D1Note = 'no free port between 5433 and 5442'; return }
  $data = Join-Path $env:TEMP ('gv_pg_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $old = @{ PGBIN = $env:PGBIN; PGHOST = $env:PGHOST; PGPORT = $env:PGPORT; PGUSER = $env:PGUSER; DB = $env:DB }
  $started = $false
  try {
    Say "  making a throwaway database server in $data on port $port"
    Start-Tool (Join-Path $bin 'initdb.exe') @('-D', "`"$data`"", '-U', 'postgres', '-A', 'trust', '-E', 'UTF8') 180
    if ($script:Code -ne 0) { $script:D1Note = "the scratch database could not be made (initdb exit code $($script:Code))"; return }
    # The server takes its port from PGPORT, so no option with quotes inside has to be passed through.
    $env:PGPORT = "$port"; $env:PGHOST = 'localhost'; $env:PGUSER = 'postgres'; $env:PGBIN = $bin; $env:DB = 'grainveda_test'
    $started = $true
    Start-Tool (Join-Path $bin 'pg_ctl.exe') @('-D', "`"$data`"", '-l', "`"$(Join-Path $data 'server.log')`"", '-w', 'start') 120
    if ($script:Code -ne 0) { $script:D1Note = "the scratch database server did not start (pg_ctl exit code $($script:Code))"; return }
    $shell = 'powershell'
    if ($PSVersionTable.PSEdition -eq 'Core') { $shell = 'pwsh' }
    # The runner's error lines stay on the screen. Sent into a pipe or a file, Windows PowerShell 5.1 turns every
    # notice psql prints into an error of its own, and the runner (which stops on errors) would stop at the first one.
    Run "$shell -NoProfile -ExecutionPolicy Bypass -File tests/run_local.ps1" -ErrorsToScreen
    $lines = @($script:Out -split "`n" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ })
    $last = ''
    if ($lines.Count -gt 0) { $last = $lines[$lines.Count - 1] }
    $failedLines = @($lines | Where-Object { $_ -cmatch '^FAILED' })
    if ($script:Code -eq 0 -and $last -ceq 'ALL TESTS PASSED' -and $failedLines.Count -eq 0 -and ($script:Out -cmatch '(?m)^ok\s+upgrade:')) {
      $script:D1 = 'OK'; $script:D1Note = 'ALL TESTS PASSED, upgrade path ok'
    } else {
      $script:D1 = 'FAILED'
      $script:D1Note = "the local test run did not pass (exit code $($script:Code), last line '$last', $($failedLines.Count) FAILED lines)"
    }
  } finally {
    if ($started) { Start-Tool (Join-Path $bin 'pg_ctl.exe') @('-D', "`"$data`"", '-m', 'fast', '-w', 'stop') 60 }
    foreach ($k in $old.Keys) { if ($null -eq $old[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } else { Set-Item "env:$k" $old[$k] } }
    if (Test-Path $data) { Remove-Item -Recurse -Force $data -ErrorAction SilentlyContinue }
  }
}
if (Wanted 'D1') {
  Say ''
  Say '== D1  local test run (a scratch database on this computer; nothing hosted is touched)'
  if ($SkipLocalTests) {
    Say '  NOT RUN: -SkipLocalTests'
    Mark 'D1' 'NOT RUN' 'switched off with -SkipLocalTests'
  } else {
    Local-Tests
    if ($script:D1 -eq 'FAILED') { Stop-Run 'D1' ($script:D1Note + '. Nothing was sent to staging.') }
    if ($script:D1 -eq 'OK') { Say '  ok  ALL TESTS PASSED and the upgrade path passed'; Mark 'D1' 'OK' $script:D1Note }
    else {
      Say "  NOT RUN: $($script:D1Note)"
      Say '  Going on: D0 has shown the files are the ones that passed the same run on 6 October (Linux, and this runner'
      Say '  under PowerShell 7). What is still unproven is this runner on Windows PowerShell 5.1.'
      Mark 'D1' 'NOT RUN' $script:D1Note
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------
# D2, D3  the database
# ---------------------------------------------------------------------------------------------------------------
$three = @('20261006000100_identity_schema', '20261006000200_union_access', '20261006000300_people_lifecycle')
$toPush = $true
if ((Wanted 'D2') -or (Wanted 'D3')) {
  Say ''
  Say '== D2  what would be pushed'
  Run "$sb db push --linked --dry-run"
  if ($script:Code -ne 0) { Stop-Run 'D2' 'the dry run failed. Nothing was sent.' }
  $names = @([regex]::Matches($script:Out, '\b\d{14}_[A-Za-z0-9_]+') | ForEach-Object { $_.Value -replace '\.sql$', '' } | Sort-Object -Unique)
  if ($names.Count -eq 0) {
    # A dry run that ends well and names no migration: there is nothing left to push. (Whether 31 to 33 are really
    # there is what the smoke check D5 reads from the database itself.)
    Say '  ok  nothing to push: migrations 31 to 33 are already on this project'
    Mark 'D2' 'OK' 'nothing to push (already on this project)'
    $toPush = $false
  } else {
    $same = ($names.Count -eq 3) -and (@($names | Where-Object { $three -notcontains $_ }).Count -eq 0)
    if (-not $same) { Stop-Run 'D2' ("the dry run lists [" + ($names -join ', ') + "], expected exactly the three of 6 October. An older name means Phase 4 part A was not finished here. Nothing was sent.") }
    Say '  ok  exactly the three migrations of 6 October'
    Mark 'D2' 'OK' 'would push exactly migrations 31, 32, 33'
  }
}
if (Wanted 'D3') {
  Say ''
  Say '== D3  push the database'
  if (-not $toPush) {
    Say '  nothing to do'
    Mark 'D3' 'OK' 'already pushed before this run'
  } else {
    Run "$sb db push --linked --yes"
    if ($script:Code -ne 0) { Stop-Run 'D3' 'db push failed. Each migration is one transaction: read the error above; do not edit a migration file.' }
    Expect 'D3' ($script:Out -match 'Finished supabase db push') "the line 'Finished supabase db push.' was not printed"
    Say '  ok  pushed'
    Mark 'D3' 'OK' 'migrations 31, 32, 33 pushed'
  }
}
$script:DbPushed = $true

# ---------------------------------------------------------------------------------------------------------------
# D4  the four server functions
# ---------------------------------------------------------------------------------------------------------------
# What check_functions said: 'current' (all four ready), 'ledger-secrets' (all four on the build of this repository,
# create-user / reset-password / daily-code ready, and the only thing missing is the token of ledger-check: a setting
# of the project from Phase 3, not something a deploy can change), or 'bad' (anything else).
function Read-Functions() {
  $script:FnState = 'bad'
  if ($script:Code -eq 0 -and $script:Out -match 'FUNCTIONS DEPLOYED AND CURRENT') { $script:FnState = 'current'; return }
  $three = $true
  foreach ($f in @('create-user', 'reset-password', 'daily-code')) {
    if ($script:Out -notmatch ('(?m)^\s*ok\s+' + [regex]::Escape($f) + ':?\s+build 2026-10-06\s*$')) { $three = $false }
  }
  if ($three -and $script:Out -match '(?m)^\s*FAIL\s+ledger-check:\s+build 2026-10-06, but its secrets are not set') { $script:FnState = 'ledger-secrets' }
}
if (Wanted 'D4') {
  Say ''
  Say '== D4  server functions'
  foreach ($fn in @('create-user', 'reset-password', 'ledger-check --no-verify-jwt', 'daily-code')) {
    Run "$sb functions deploy $fn"
    if ($script:Code -ne 0) { Stop-Run 'D4' "deploying $fn failed" }
    Expect 'D4' ($script:Out -match 'Deployed Function') "'Deployed Function' was not printed for $fn"
  }
  Run 'node scripts/check_functions.mjs'
  Read-Functions
  if ($script:FnState -eq 'bad') {
    Say '  not current yet: waiting 30 seconds and asking once more'
    Start-Sleep -Seconds 30
    Run 'node scripts/check_functions.mjs'
    Read-Functions
  }
  Expect 'D4' ($script:FnState -ne 'bad') "check_functions did not print 'FUNCTIONS DEPLOYED AND CURRENT'"
  if ($script:FnState -eq 'ledger-secrets') {
    Say '  NOT OK (standing, does not stop): ledger-check is on the current build, but its token was never set on this'
    Say '  project (docs/RUNSHEET_phase3.md steps 7 and 8). Until it is, an outside monitor cannot ask this project for a'
    Say '  ledger check. The three functions the people screens use are current.'
    Mark 'D4' 'OK' 'four functions deployed, all on build 2026-10-06; NOT OK (standing): the ledger-check token is not set on this project (RUNSHEET_phase3 steps 7 and 8)'
  } else {
    $builds = [regex]::Matches($script:Out, 'build 2026-10-06').Count
    Say '  ok  four functions deployed'
    Mark 'D4' 'OK' "four functions deployed; check_functions: FUNCTIONS DEPLOYED AND CURRENT ($builds mentions of build 2026-10-06)"
  }
}

# ---------------------------------------------------------------------------------------------------------------
# D5  smoke check: 30 rows
# ---------------------------------------------------------------------------------------------------------------
$checks = @('extensions', 'schema app', 'tables (15)', 'RLS on every table', 'stage_definitions (16)', 'ledger guard trigger',
  'footprint triggers', 'ledger chain intact', 'seed: Kalanamak crop', 'environment', 'demo data', 'api surface closed',
  'auth.uid mapping', 'public journey rpc', 'phase 3 objects', 'phase 4 objects', 'phase 4 triggers', 'ledger read by stage',
  'direct writes closed', 'evidence in the ledger', 'public page data', 'capture time, verdict preview',
  'a new client can be read back', 'identity layer objects', 'people moved to assignments', 'the two seats',
  'manager rules ask about the scope', 'people written only by their actions', 'once-a-day sign-in code', 'nightly ledger check')
# Rows that say something about how this project is set up, not about today's change. They were not caused by
# the push; a row here that is not OK is shown and listed in the summary, and does not stop the run.
$standing = @('demo data', 'auth.uid mapping', 'nightly ledger check')
if (Wanted 'D5') {
  Say ''
  Say '== D5  smoke check'
  Run "$sb db query --linked -f tests/remote_smoke.sql"
  if ($script:Code -ne 0) { Stop-Run 'D5' 'the smoke check could not be run' }
  $text = $script:Out
  $at = @{}
  foreach ($c in $checks) { $at[$c] = $text.IndexOf($c, [System.StringComparison]::Ordinal) }
  $missing = @($checks | Where-Object { $at[$_] -lt 0 })
  $bad = @(); $warn = @(); $okCount = 0
  $present = @($checks | Where-Object { $at[$_] -ge 0 } | Sort-Object { $at[$_] })
  for ($i = 0; $i -lt $present.Count; $i++) {
    $c = $present[$i]
    $start = $at[$c] + $c.Length
    $end = $text.Length
    if ($i + 1 -lt $present.Count) { $end = $at[$present[$i + 1]] }
    $seg = $text.Substring($start, $end - $start)
    $seg = $seg -replace '^[^A-Za-z0-9]+', ''
    $seg = $seg -replace '^result[^A-Za-z0-9]+', ''
    $first = (($seg -split "`n")[0]).Trim()
    if ($first.Length -gt 90) { $first = $first.Substring(0, 90) }
    if ($seg -cmatch '^OK\b') { $okCount++ }
    elseif ($standing -contains $c) { $warn += "$c = $first" }
    else { $bad += "$c = $first" }
  }
  Say "  rows read: $($present.Count) of 30, OK: $okCount"
  foreach ($w in $warn) { Say "  NOT OK (standing, does not stop): $w" }
  foreach ($b in $bad) { Say "  NOT OK: $b" }
  Expect 'D5' ($missing.Count -eq 0) ("these rows were not found in the output: " + ($missing -join ', '))
  Expect 'D5' ($bad.Count -eq 0) ("rows not OK: " + ($bad -join ' ; '))
  $note = "$okCount of 30 rows OK"
  if ($warn.Count -gt 0) { $note += '; NOT OK (standing): ' + ($warn -join ' ; ') }
  if ($skip -contains 'D5') { Mark 'D5' 'UNJUDGED' $note } else { Mark 'D5' 'OK' $note }
}

if (Wanted 'D6') {
  Say ''
  Say '== D6  the private store for HR documents'
  Query 'q_hr_docs' "select id, public from storage.buckets where id = 'hr-docs';"
  if ($script:Code -ne 0) { Stop-Run 'D6' 'the query failed' }
  if ($script:Out -match 'hr-docs[^A-Za-z0-9]+(public[^A-Za-z0-9]+)?(true|t)\b') { Stop-Run 'D6' 'the store hr-docs is PUBLIC. It must be private.' }
  Expect 'D6' ($script:Out -match 'hr-docs[^A-Za-z0-9]+(public[^A-Za-z0-9]+)?(false|f)\b') 'no row hr-docs / false'
  Say '  ok  hr-docs exists and is private'
  Mark 'D6' 'OK' 'hr-docs exists, private'
}

if (Wanted 'D6b') {
  Say ''
  Say '== D6b ledger audit'
  Run "$sb db query --linked -f tests/remote_ledger_audit.sql"
  if ($script:Code -ne 0) { Stop-Run 'D6b' 'the ledger audit could not be run' }
  Expect 'D6b' ($script:Out -match 'NO FINDINGS \(') "the audit did not answer 'NO FINDINGS ('"
  $m = [regex]::Match($script:Out, 'NO FINDINGS \([^)]*\)')
  Say '  ok  no findings'
  Mark 'D6b' 'OK' $m.Value
}

if (Wanted 'D7') {
  Say ''
  Say '== D7  people who can sign in and have no assignment (for Veda; zero rows is fine)'
  Query 'q_unassigned' "select u.display_name, coalesce(u.email, u.phone) as sign_in from public.app_users u where not u.external and u.system_role = 'operational' and u.status = 'active' and not exists (select 1 from public.assignments a where a.employee_id = u.id and a.active) order by 1;"
  if ($script:Code -ne 0) { Stop-Run 'D7' 'the query failed' }
  Mark 'D7' 'OK' 'list recorded above (read it in the record)'
}

if (Wanted 'D8') {
  Say ''
  Say '== D8  people by system role and status'
  Query 'q_roles' "select system_role, status, count(*) from public.app_users group by 1, 2 order by 1, 2;"
  if ($script:Code -ne 0) { Stop-Run 'D8' 'the query failed' }
  Expect 'D8' ($script:Out -match '(?<![_A-Za-z])admin[^A-Za-z0-9]+(status[^A-Za-z0-9]+)?active[^A-Za-z0-9]+(count[^A-Za-z0-9]+)?[1-9]') 'no row admin / active'
  Say '  ok  at least one active admin'
  Mark 'D8' 'OK' 'at least one active admin'
}

# ---------------------------------------------------------------------------------------------------------------
# D9, D10  demo people of the identity layer and their logins
# ---------------------------------------------------------------------------------------------------------------
if (Wanted 'D9') {
  Say ''
  Say '== D9  demo people (seed 06) and their logins'
  Run "$sb db query --linked -f supabase/seeds/06_identity_demo.sql"
  if ($script:Code -ne 0) { Stop-Run 'D9' 'seed 06 failed' }
  if ($script:Out -cmatch '(?m)^\s*ERROR') { Stop-Run 'D9' 'seed 06 printed an ERROR' }
  Run 'node scripts/create_demo_logins.mjs'
  $rows = @([regex]::Matches($script:Out, '(?m)^\s*(\d{3})\s+\S+\s+(yes|NO)\s+(yes|NO)\s'))
  if ($rows.Count -eq 0) { Stop-Run 'D9' 'create_demo_logins did not print its table (read its error above)' }
  $unlinked = @($rows | Where-Object { $_.Groups[3].Value -ne 'yes' } | ForEach-Object { [int]$_.Groups[1].Value })
  $new = @($rows | Where-Object { @(316, 317, 318, 319) -contains [int]$_.Groups[1].Value -and $_.Groups[3].Value -eq 'yes' })
  $note = ''
  if ($script:Out -match 'ALL DEMO LOGINS CREATED AND LINKED' -and $script:Code -eq 0) {
    $note = "$($rows.Count) demo logins, all linked"
  } else {
    $outside = @($unlinked | Where-Object { $_ -lt 305 -or $_ -gt 315 })
    $phoneOnly = ($rows.Count -gt 0) -and ($unlinked.Count -gt 0) -and ($outside.Count -eq 0)
    Expect 'D9' $phoneOnly ("demo logins not linked: keys [" + ($unlinked -join ', ') + "] (only 305 to 315, the phone sign-ins, may be unlinked while the Phone provider is off)")
    $note = "phone sign-ins not linked (keys " + ($unlinked -join ', ') + "): the Phone provider is off on this project, as before today"
    Say "  $note"
  }
  Expect 'D9' ($new.Count -eq 4) "keys 316 to 319 (the identity-layer demo people) are not all linked: $($new.Count) of 4"
  Say '  ok  the four new demo people have logins (passwords are in .env.demo-logins, git-ignored)'
  Mark 'D9' 'OK' "seed 06 applied; keys 316 to 319 linked; $note"
}

if (Wanted 'D10') {
  Say ''
  Say '== D10 logins without a person'
  Run 'node scripts/check_logins.mjs'
  Expect 'D10' ($script:Out -match 'NO LOGIN WITHOUT A PERSON') "'NO LOGIN WITHOUT A PERSON' was not printed"
  Say '  ok'
  Mark 'D10' 'OK' 'NO LOGIN WITHOUT A PERSON'
}

# ---------------------------------------------------------------------------------------------------------------
# D11  the app: type check, unit tests; D11b: commit and push (Vercel builds the push)
# ---------------------------------------------------------------------------------------------------------------
# Compares the app's files with scripts/tested_app_files.txt (the app as it was tested). $script:AppDiff lists every
# file that is missing, changed or new; empty means the app here is the tested one.
function Read-App() {
  $script:AppDiff = New-Object System.Collections.Generic.List[string]
  $script:AppCount = 0
  $list = 'scripts/tested_app_files.txt'
  if (-not (Test-Path (Join-Path $root $list))) { $script:AppDiff.Add("$list (missing)"); return }
  Hash-Text $list
  if ($script:Hash -ne 'd3c6234f2bad0defa91cdb740d4414c79269f8f9bfb6e6f0dd526575e7d28c8d') { $script:AppDiff.Add("$list (changed)"); return }
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
if (Wanted 'D11') {
  Say ''
  Say '== D11 the app: types and unit tests'
  if (-not (Test-Path (Join-Path $root 'web/node_modules'))) {
    Run 'cd web && npm ci'
    if ($script:Code -ne 0) { Stop-Run 'D11' 'npm ci failed' }
  }
  Run 'cd web && npx tsc -b --noEmit'
  if ($script:Code -ne 0) { Stop-Run 'D11' 'type errors (npx tsc -b --noEmit). The app was not pushed.' }
  Run 'cd web && npx vitest run'
  $vit = $script:Out
  $vcode = $script:Code
  $passed = [regex]::Match($vit, '(?m)^\s*Tests\s+.*?(\d+)\s+passed')
  $anyFailed = $vit -match '(?m)^\s*(Test Files|Tests)\s+.*\bfailed\b'
  if ($vcode -ne 0 -or $anyFailed -or -not $passed.Success) {
    # One case is not a failing test: no test could START on this computer. The test tools in web/package-lock.json
    # need Node 22 (jsdom 30: 22.22 or newer); on an older Node they stop while loading, with ERR_REQUIRE_ESM and
    # "no tests". Then, and only then, the run goes on if the app's files are byte for byte the tested ones.
    $noStart = ($vit -match 'ERR_REQUIRE_ESM') -and ($vit -match '(?m)^\s*Tests\s+no tests') -and (-not $passed.Success) -and (-not $anyFailed)
    $nodeOld = $false
    if ($nodeVersion -match 'v(\d+)\.(\d+)') { $nodeOld = ([int]$Matches[1] -lt 22) -or ([int]$Matches[1] -eq 22 -and [int]$Matches[2] -lt 12) }
    if (-not ($noStart -and $nodeOld)) { Stop-Run 'D11' 'the unit tests did not all pass. The app was not pushed.' }
    Say "  The unit tests could not start: Node $nodeVersion on this computer is older than the test tools need (Node 22)."
    Read-App
    if ($script:AppDiff.Count -gt 0) {
      $shown = @($script:AppDiff | Select-Object -First 8)
      Stop-Run 'D11' ("the unit tests cannot run here (Node $nodeVersion), and the app's files are not the tested ones: " + ($shown -join ', ') + " ($($script:AppDiff.Count) in all). The app was not pushed.")
    }
    Say "  NOT RUN here. Going on: the type check passed on this computer, and the app's $($script:AppCount) files are byte for byte"
    Say '  the ones whose 193 unit tests and 53 screen tests passed on 6 October under Node 22.'
    Mark 'D11' 'NOT RUN' "type check passed; unit tests cannot start on Node $nodeVersion (the test tools need Node 22). The app's $($script:AppCount) files are the tested ones"
  } else {
    Say "  ok  no type errors; $($passed.Groups[1].Value) unit tests passed (193 on 6 October)"
    Mark 'D11' 'OK' "no type errors; $($passed.Groups[1].Value) unit tests passed"
  }
}

if (Wanted 'D11b') {
  Say ''
  Say '== D11b commit and push'
  if ($NoGit) {
    Say '  NOT RUN: -NoGit. The app on staging is still the old one.'
    Mark 'D11b' 'NOT RUN' 'switched off with -NoGit: the staging app is still the old build'
  } else {
    $envPath = '(?m)(^|[\\/\s"])\.env($|[.\s"])'
    Run 'git status --short'
    if ($script:Code -ne 0) { Stop-Run 'D11b' 'git status failed' }
    if ($script:Out -match $envPath) { Stop-Run 'D11b' 'git status shows a .env file. Nothing was committed. It must be git-ignored first.' }
    Run 'git add -A'
    if ($script:Code -ne 0) { Stop-Run 'D11b' 'git add failed' }
    Run 'git diff --cached --name-only'
    if ($script:Code -ne 0) { Stop-Run 'D11b' 'git diff failed' }
    $staged = @($script:Out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^warning:' -and $_ -notmatch '^The file will have' })
    if (@($staged | Where-Object { $_ -match $envPath -or $_ -match '^release-evidence/' -or $_ -match '(^|/)backups/' }).Count -gt 0) {
      Run 'git reset'
      Stop-Run 'D11b' 'a .env file, a backup or the run record was about to be committed. The staging was undone; nothing was committed.'
    }
    if ($staged.Count -eq 0) {
      Say '  nothing new to commit'
    } else {
      $msg = Join-Path $evidence 'commit-message.txt'
      [System.IO.File]::WriteAllText($msg, "Identity and authorization layer: HR onboarding, assignments, lifecycle, seats, audit log (migrations 31-33)`n`nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`nClaude-Session: https://claude.ai/code/session_01VSgZRQeaqm6gr2gjyiknfF`n", $utf8)
      Run 'git commit -F release-evidence/commit-message.txt'
      if ($script:Code -ne 0) { Stop-Run 'D11b' 'git commit failed' }
    }
    Run 'git push'
    if ($script:Code -ne 0) { Stop-Run 'D11b' 'git push failed (the commit is made on this computer; the app on staging is still the old one). If it asked for a sign-in, run "git push" once by hand, then this script again with -From D11b.' }
    Run 'git rev-parse --short HEAD'
    $head = $script:Out.Trim()
    Run 'git status --short --branch'
    $script:AppPushed = $true
    if ($staged.Count -eq 0) {
      Say "  ok  no new commit was needed; the branch is pushed (head $head)"
      Mark 'D11b' 'OK' "nothing new to commit; branch pushed (head $head). If Vercel has not built this head yet, it does now"
    } else {
      Say "  ok  pushed commit $head ($($staged.Count) files in this commit)"
      Mark 'D11b' 'OK' "commit $head pushed ($($staged.Count) files). Vercel builds it: wait for the deployment to be Ready"
    }
  }
}

if (Wanted 'D12') {
  Say ''
  Say '== D12 access rules with real logins (T1)'
  if (-not $RunT1) {
    Say '  NOT RUN: it signs the demo operators in by phone, so it needs the Phone provider ON on this project (-RunT1).'
    Mark 'D12' 'NOT RUN' 'needs the Phone provider ON (run with -RunT1 -From D12 when it is)'
  } else {
    Run 'node tests/remote_rls.mjs --t1'
    Expect 'D12' (($script:Code -eq 0) -and ($script:Out -match 'REMOTE RLS PASSED') -and ($script:Out -match '\b0 failed')) "'REMOTE RLS PASSED' with 0 failed was not printed"
    $m = [regex]::Match($script:Out, '\d+ passed, 0 failed')
    Say '  ok'
    Mark 'D12' 'OK' ("REMOTE RLS PASSED " + $m.Value)
  }
}

Summary
Say 'RESULT: PART D RAN TO THE END'
exit 0
