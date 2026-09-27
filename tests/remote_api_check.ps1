# REST check for the live project (execution plan, workstream C). Read-only.
# Proves the `app` schema is exposed to the Data API: app.public_lot_journey('GV-NONE') called with the PUBLIC key must
# return HTTP 200 and null. tests/remote_smoke.sql cannot see this: hosted Supabase keeps the exposed-schemas setting
# in PostgREST's config, not in the database.
#
# Run from the repo root (Windows PowerShell 5.1 or pwsh 7):  powershell -File tests/remote_api_check.ps1
# Reads NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY (or ..._ANON_KEY) from the environment, else
# from .env.local. Never prints the key. Exit code 0 = OK, 1 = FAIL.

$ErrorActionPreference = 'Stop'
$vars = @{}
if (Test-Path .env.local) {
  Get-Content .env.local | Where-Object { $_ -match '^\s*[A-Za-z_][A-Za-z0-9_]*\s*=' } |
    ForEach-Object { $k, $v = $_ -split '=', 2; $vars[$k.Trim()] = $v.Trim().Trim('"').Trim("'") }
}
function Get-Setting($name) {
  $fromEnv = [Environment]::GetEnvironmentVariable($name)
  if ($fromEnv) { return $fromEnv } else { return $vars[$name] }
}

$base = Get-Setting 'NEXT_PUBLIC_SUPABASE_URL'
$key = Get-Setting 'NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY'; $keyName = 'publishable'
if (-not $key) { $key = Get-Setting 'NEXT_PUBLIC_SUPABASE_ANON_KEY'; $keyName = 'anon' }
if (-not $base -or -not $key) { Write-Output 'FAIL  missing NEXT_PUBLIC_SUPABASE_URL or a public key'; exit 1 }

$headers = @{ apikey = $key; 'Content-Profile' = 'app' }
if ($keyName -eq 'anon') { $headers['Authorization'] = "Bearer $key" }   # legacy JWT key; a publishable key is not a JWT
$uri = $base.TrimEnd('/') + '/rest/v1/rpc/public_lot_journey'

try {
  $r = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -ContentType 'application/json' `
                         -Body '{"p_qr_code":"GV-NONE"}' -UseBasicParsing
  $status = [int]$r.StatusCode; $body = "$($r.Content)".Trim()
} catch {
  $status = [int]$_.Exception.Response.StatusCode; $body = "$($_.ErrorDetails.Message)".Trim()
}

if ($status -eq 200 -and $body -eq 'null') {
  Write-Output "OK    app schema exposed: public_lot_journey('GV-NONE') over REST with the $keyName key -> HTTP 200, null"
  exit 0
}
Write-Output "FAIL  public_lot_journey('GV-NONE') over REST with the $keyName key -> HTTP $status $body"
exit 1
