# Windows twin of tests/run_local.sh: rebuilds a scratch database from the migrations + seeds and runs every test file.
# Same steps, same order, same output lines. Exit code 1 on any failure.
# Usage (PowerShell, repo root):
#   $env:PGBIN = 'C:\path\to\pgsql\bin'; $env:PGHOST = 'localhost'; $env:PGPORT = '5433'; $env:PGUSER = 'postgres'
#   powershell -ExecutionPolicy Bypass -File tests/run_local.ps1
# A throwaway cluster for it (no install, no admin):
#   & "$env:PGBIN\initdb.exe" -D <dir> -U postgres -A trust -E UTF8
#   & "$env:PGBIN\pg_ctl.exe" -D <dir> -o "-p 5433" -l <dir>\log.txt start
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$db = if ($env:DB) { $env:DB } else { 'grainveda_test' }
$bin = if ($env:PGBIN) { $env:PGBIN } else { Split-Path (Get-Command psql.exe).Source }
$env:PGCLIENTENCODING = 'UTF8'

function Invoke-Psql($file) {
  & "$bin\psql.exe" -v ON_ERROR_STOP=1 -q -d $db -f $file
  return $LASTEXITCODE -eq 0
}

& "$bin\dropdb.exe" --if-exists $db; if ($LASTEXITCODE -ne 0) { exit 1 }
& "$bin\createdb.exe" $db;          if ($LASTEXITCODE -ne 0) { exit 1 }
if (-not (Invoke-Psql 'tests/00_local_auth_shim.sql')) { exit 1 }
foreach ($f in Get-ChildItem supabase/migrations/*.sql | Sort-Object Name) {
  Write-Output "migrate  supabase/migrations/$($f.Name)"; if (-not (Invoke-Psql $f.FullName)) { exit 1 }
}
foreach ($f in Get-ChildItem supabase/seeds/*.sql | Sort-Object Name) {
  Write-Output "seed     supabase/seeds/$($f.Name)"; if (-not (Invoke-Psql $f.FullName)) { exit 1 }
}
$fail = $false
foreach ($f in Get-ChildItem tests/*.sql | Where-Object { $_.Name -match '^[0-9]' -and $_.Name -notmatch '^00' } | Sort-Object Name) {
  Write-Output "test     tests/$($f.Name)"
  if (-not (Invoke-Psql $f.FullName)) { $fail = $true; Write-Output "FAILED   tests/$($f.Name)" }
}
# Self-test of the live-project T1 check on this fresh build, so it is proven here before it runs remotely.
Write-Output 'test     tests/remote_t1_rollback.sql (local self-test)'
if (-not (Invoke-Psql 'tests/remote_t1_rollback.sql')) { $fail = $true; Write-Output 'FAILED   tests/remote_t1_rollback.sql' }
# Four sessions at once: ledger appends and Farmer IDs under concurrency. Last, because it commits into the scratch DB.
Write-Output 'test     tests/concurrency (4 parallel sessions)'
if (-not (Invoke-Psql 'tests/concurrency/setup.sql')) { $fail = $true }
$workers = foreach ($w in 1..4) {
  $proc = Start-Process -FilePath "$bin\psql.exe" -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\gv_worker_$w.txt" `
    -ArgumentList '-v', 'ON_ERROR_STOP=1', '-q', '-d', $db, '-v', "worker=$w", '-f', 'tests/concurrency/worker.sql'
  $null = $proc.Handle   # PowerShell 5.1: keep the handle, or ExitCode reads as null after exit
  $proc
}
foreach ($p in $workers) { $p.WaitForExit(); if ($p.ExitCode -ne 0) { $fail = $true; Write-Output 'FAILED   tests/concurrency/worker.sql' } }
if (-not (Invoke-Psql 'tests/concurrency/check.sql')) { $fail = $true; Write-Output 'FAILED   tests/concurrency/check.sql' }
if ($fail) { Write-Output 'SOME TESTS FAILED'; exit 1 }
Write-Output 'ALL TESTS PASSED'
