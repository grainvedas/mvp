# THE EXPORT CORRECTIONS: Phase 1, release 3 (migration 61 and the app), on the practice system (staging).
# Veda's combined brief of 19 October 2026: Part C checked word by word, and the shown parts of the season corrections
# E2.2 to E2.5 (found live on build index-Cv0Uu-5v); "do what is left as per best". Release 60 (Phase 1 release 2) is on
# staging since 19 Oct 2026, 21:10 IST.
#   - Both exports: a column per field, names not ids, empty columns left out, raw_values only in the internal copy;
#     prices only where the scope records them; packs by size; staff and buyers named in the shareable copy (the brief's
#     words), never a farmer, a price or an id; the brief's footer.
#   - By-products are not floor loss (milling: head rice, broken, husk, bran in kg and %); a lot closed as floor loss is
#     its own line; the Summary and the dashboard show each stage's mass balance, a difference in red.
#   - The public page: "Collection Batch", "2 farmers from 2 villages", one line for all of a batch's purchases.
#   - Best-before on every pack page; PACKING IS REFUSED while the crop has no shelf life for the pack's material: S1b
#     lists the crops and materials without one (the State Manager sets them).
# docs/FIX_LIST.md item 57; docs/RUNSHEET_export_corrections.md.
# RUN IT ONLY WHEN VEDA HAS SAID SO: it changes the staging database and PUSHES TO THE MAIN BRANCH (Vercel builds the
# staging app from that push). The seven server functions are unchanged. It asks once, in words, first.
#
# What it does:
#   S0 checks (tools, the tested files, the staging project, migration 61 waiting, the seven functions current) and asks.
#   S1 pushes it.
#   S1b reads back what the migration set and lists the crops and pack materials without a shelf life (read only).
#   S2 reads the project back: smoke check (59 rows; "statement logging" is a go-live step and does not stop it), the
#      new rules in place, the change log intact, ONE CLIENT'S DATA NOT VISIBLE TO ANOTHER (app.isolation_probe, read
#      only), the ledger audit, logins, functions.
#   S3 commits and pushes the app (Vercel builds it), and says how to see that Vercel built that commit.
# Nothing is deleted or rewritten. It refuses: any project but the staging one named below; a project that says it is
# production; files that are not the tested ones; any migration waiting other than 61.
#
# Usage (PowerShell, repository root), or double-click staging-export-corrections.cmd:
#   powershell -ExecutionPolicy Bypass -File scripts\staging_export_corrections.ps1
# It can be run again after a stop: a migration is not pushed twice.
# The record of the run: release-evidence\staging-export-corrections-<time>.log (git-ignored). It reads no .env file and
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
$phrase = 'CORRECTIONS'
$migration = '20261105000100_export_corrections.sql'

$evidence = Join-Path $root 'release-evidence'
if (-not (Test-Path $evidence)) { New-Item -ItemType Directory -Path $evidence | Out-Null }
$log = Join-Path $evidence ("staging-export-corrections-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
  if ($script:DbPushed) { Say 'The database has migration 61; the staging app is the old one until S3 has run: run this again (it does not push a migration twice). Meanwhile the old app works (its exports come from the new functions; the old screens show the old column names): wait for S3.' }
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

Say "GrainVeda - The export corrections, Phase 1 release 3 (migration 61, the app), on the practice system - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

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
  "supabase/migrations/$migration" = 'c9ee2a4b6b11d2766f9b10d262e69a030e2b63a061975173d023a78614106331'
  'scripts/check_functions.mjs' = '7d86813aee68319d0f1506aaf447a56fd7be4ebb88d07eda0746943521ce9e3d'
  'tests/remote_smoke.sql' = '7ee55ca2b756ed3b83b7ef22b0f7c0c09e57adad2140e22e5c8546ceab50f044'
  'scripts/anchor_ledger.mjs' = '3d3cdfd71459f64df71c8166abeb1c1b28017c1dcf3db9527d07fc3b87f139ed'
  'scripts/templates/ledger-anchor.yml' = '9759bd65771371bebba38e4317a345852913a0c491647e57eed9b3095c284f80'
  'tests/remote_ledger_audit.sql' = 'f45f90d2e2f6c2a424ba56a7bbbd15bb68da4cb6a7015fbd22472ce531a3cdbf'
}
$appListHash = '7ac00e1082a7bf4d1152d327c752d6c7d713682699811cc0701ca4489940883e'
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
Say "  ok  migration 61, the smoke check and the ledger audit are the tested files; the app's and functions' $($script:AppCount) files are the tested ones"
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
  Say '  no migration is waiting: migration 61 was pushed before (S1 is skipped; S2 shows whether it is in place)'
} elseif ($waiting.Count -eq 1 -and $waiting[0] -eq $migration) {
  Say "  ok  exactly one migration is waiting: $migration"
} else {
  Stop-Run 'S0' ("waiting to be pushed: " + ($waiting -join ', ') + ". Only $migration was expected.")
}
# The seven server functions are unchanged by this release and must be current
Run 'node scripts/check_functions.mjs'
if ($script:Out -notmatch 'FUNCTIONS DEPLOYED AND CURRENT') { Stop-Run 'S0' 'the server functions are not all current (read the lines above); this release does not deploy them' }
Say '  ok  the seven server functions are current (this release does not change them)'
Say ''
Say '  This will:'
if (-not $dbDone) { Say '   - push migration 61: the exports'' columns per field and names, prices only where recorded, floor loss' }
if (-not $dbDone) { Say '     without by-products, closures as their own line, the mass balance per stage, one line for a batch''s' }
if (-not $dbDone) { Say '     purchases on the public page, best-before on every pack page. New and replaced functions; no record changed.' }
if (-not $dbDone) { Say '     PACKING IS REFUSED for a crop and pack material without a shelf life (S1b lists them).' }
Say '   - commit and PUSH TO THE MAIN BRANCH: Vercel builds the app with the new export words, the dashboard''s mass'
Say '     balance, the journey''s closure line and printed heading, the public page''s purchases line.'
Say ''
$answer = Read-Host "  Only if Veda has said so: type  $phrase  and press Enter (anything else stops)"
[System.IO.File]::AppendAllText($log, "  typed: $answer`r`n", $utf8)
if ($answer -cne $phrase) { Stop-Run 'S0' 'not confirmed' }
Mark 'S0' 'OK' "practice project $stagingRef, environment staging, tested files, $($script:AppCount) app and function files; waiting: $(if ($dbDone) { 'nothing' } else { $waiting -join ' + ' }); functions current; confirmed in words"

# ---------------------------------------------------------------------------------------------------------------
# S1  push migration 61
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S1  push migration 61'
if ($dbDone) {
  Say '  NOT RUN: nothing waiting'
  Mark 'S1' 'NOT RUN' 'migration 61 was already pushed'
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
# S1b  what the migration set, and the crops and pack materials without a shelf life (read only)
# ---------------------------------------------------------------------------------------------------------------
Say ''
Say '== S1b  the export corrections (read only)'
Query 'q_read61' "select 'fix: functions=' || case when to_regprocedure('app.stage_balance(uuid)') is not null and to_regprocedure('app.record_parts(footprints)') is not null and to_regprocedure('app.stage_balance_of(uuid)') is not null then 'new' else 'old' end || ' granted=' || case when has_function_privilege('authenticated', 'app.stage_balance(uuid)', 'execute') and not has_function_privilege('anon', 'app.stage_balance(uuid)', 'execute') and not has_function_privilege('authenticated', 'app.stage_balance_of(uuid)', 'execute') and not has_function_privilege('authenticated', 'app.record_parts(footprints)', 'execute') then 'yes' else 'no' end || ' closure_line=' || case when position('floor_loss_closure' in pg_get_functiondef('app.export_table(uuid[], boolean, jsonb, text)'::regprocedure)) > 0 then 'yes' else 'no' end || ' prices_rule=' || case when position('v_price' in pg_get_functiondef('app.export_record(uuid, boolean, numeric)'::regprocedure)) > 0 then 'yes' else 'no' end || ' purchases=' || case when position('''purchases''' in pg_get_functiondef('app.public_lot_journey(text)'::regprocedure)) > 0 then 'yes' else 'no' end || ' shelf_rule=' || case when position('set the shelf life for this crop' in pg_get_functiondef('app.reconcile(footprints, scopes)'::regprocedure)) > 0 then 'yes' else 'no' end || ' closures=' || (select count(*) from public.lot_closures) || ' no_shelf_life=' || coalesce((select string_agg(y.m, '; ' order by y.m) from (select cr.name || ' (' || c.code || '): ' || string_agg(distinct coalesce(k.material, 'packs not from a list'), ',') as m from public.scopes s join public.crops cr on cr.id = s.crop_id join public.clients c on c.id = s.client_id left join public.pack_skus k on k.client_id = s.client_id and k.active where s.status <> 'closed' and app.shelf_life_for(cr.id, k.material) is null group by cr.name, c.code) y), 'none') || ' end' as result;"
if ($script:Code -ne 0 -or $script:Out -notmatch 'fix: .* end') { Stop-Run 'S1b' 'what the migration set could not be read (read the error above)' }
$fix = [regex]::Match($script:Out, 'fix: (.*?) end').Groups[1].Value
Say "  $fix"
if ($fix -notmatch '^functions=new granted=yes closure_line=yes prices_rule=yes purchases=yes shelf_rule=yes closures=\d+ no_shelf_life=') { Stop-Run 'S1b' 'the mass balance, who may read it, the closure line, the prices rule, the purchases line or the shelf-life rule are not as migration 61 leaves them (read the line above)' }
$noShelf = [regex]::Match($fix, 'no_shelf_life=(.*)$').Groups[1].Value
if ($noShelf -ne 'none') {
  Say '  NOTE  Packing is refused for these crops (client) and pack materials until the State Manager sets their shelf life'
  Say "        (Crops, the crop, Shelf life): $noShelf"
}
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
  'joiner HR data', 'onboarding at scale', 'hr by geography', 'HR holds no seat', 'state manager rules', 'crop registry', 'farmer register', 'rules and farmer ids', 'production safeguards', 'requirements', 'farmer corrections', 'operator template', 'trust numbers', 'packs and release', 'setup lists', 'procurement batch', 'milling qc packing', 'commercial shipment', 'warehouse', 'buyer link scans', 'client isolation', 'people public page packs', 'cartons people choices', 'fixes and client reads only', 'exports', 'export corrections', 'statement logging', 'reminder round', 'nightly ledger check')
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
Say "  smoke rows read: $($present.Count) of 59, OK: $okCount"
foreach ($w in $warn) { Say "  NOT OK (standing, does not stop): $w" }
foreach ($b in $bad) { Say "  NOT OK: $b" }
if ($missing.Count -gt 0) { Stop-Run 'S2' ("smoke rows not found in the output: " + ($missing -join ', ')) }
if ($bad.Count -gt 0) { Stop-Run 'S2' ("smoke rows not OK: " + ($bad -join ' ; ')) }

Query 'q_rule61' "select 'rule61=' || case when to_regprocedure('app.stage_balance(uuid)') is not null and to_regprocedure('app.record_parts(footprints)') is not null and has_function_privilege('authenticated', 'app.stage_balance(uuid)', 'execute') and not has_function_privilege('authenticated', 'app.stage_balance_of(uuid)', 'execute') and not has_function_privilege('anon', 'app.stage_balance(uuid)', 'execute') and to_regprocedure('app.export_journey(uuid, text)') is not null and to_regprocedure('app.export_season(uuid, text)') is not null and has_function_privilege('authenticated', 'app.may_internal_copy(uuid)', 'execute') and not has_function_privilege('authenticated', 'app.export_table(uuid[], boolean, jsonb, text)', 'execute') and not has_function_privilege('anon', 'app.export_season(uuid, text)', 'execute') and to_regprocedure('app.is_client_login()') is not null and to_regprocedure('app.client_waiting(uuid)') is not null and to_regprocedure('app.client_farmers(text, uuid[], integer)') is not null and to_regprocedure('app.cm_phone_ok(uuid)') is not null and has_function_privilege('authenticated', 'app.client_farmers(text, uuid[], integer)', 'execute') and not has_function_privilege('anon', 'app.client_waiting(uuid)', 'execute') and not has_function_privilege('authenticated', 'app.param_units(uuid)', 'execute') and to_regprocedure('app.may_offer_assign_seen(uuid)') is not null and not has_function_privilege('authenticated', 'app.may_offer_assign_seen(uuid)', 'execute') and to_regprocedure('app.register_attachment(uuid, attachment_kind, text, text, text, text)') is not null and position('data_note' in pg_get_functiondef('app.lot_trace(uuid)'::regprocedure)) > 0 and to_regprocedure('app.allocate_units(uuid, uuid, jsonb, jsonb)') is not null and to_regprocedure('app.org_choices(uuid)') is not null and not has_function_privilege('authenticated', 'app.allocate_units(uuid, uuid, jsonb, jsonb)', 'execute') and not has_function_privilege('anon', 'app.available_cartons(uuid, uuid)', 'execute') and position('make_cartons' in pg_get_functiondef('app.make_packs(uuid, text)'::regprocedure)) > 0 and exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'cartons' and policyname = 'cartons_read') and to_regprocedure('app.busy_for_other_client(uuid)') is not null and to_regprocedure('app.order_pack_codes(uuid, uuid)') is not null and not has_function_privilege('anon', 'app.order_pack_codes(uuid, uuid)', 'execute') and not has_function_privilege('authenticated', 'app.busy_for_other_client(uuid)', 'execute') and position('busy_for_other_client' in pg_get_functiondef('app.cm_seen_ids()'::regprocedure)) > 0 and to_regclass('public.buyer_links') is not null and to_regclass('public.buyer_link_views') is not null and to_regclass('public.scan_flags') is not null and to_regprocedure('app.create_buyer_link(uuid, integer, text)') is not null and to_regprocedure('app.revoke_buyer_link(uuid, text)') is not null and to_regprocedure('app.buyer_view(text)') is not null and to_regprocedure('app.buyer_file(text, uuid)') is not null and to_regprocedure('app.record_scan_at(text, text, text, text, numeric, numeric)') is not null and to_regprocedure('app.decide_scan_flag(uuid, text, text)') is not null and to_regprocedure('app.isolation_probe(boolean, boolean)') is not null and not has_function_privilege('anon', 'app.buyer_file(text, uuid)', 'execute') and not has_column_privilege('authenticated', 'public.buyer_links', 'token_hash', 'select') and exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'openings' and policyname = 'openings_read' and qual like '%can_access_client%') and to_regclass('public.warehouse_inspections') is not null and (select count(*) from pg_trigger where tgname = 'zz_change_log') = 56 and not exists (select 1 from app.verify_change_log()) then 'OK' else 'OLD' end || ' end' as result;"
if ($script:Out -notmatch 'rule61=OK end') { Stop-Run 'S2' 'the new rules are not in place, or the change log does not verify' }
# Veda, 16 Oct 2026: "check that one client data should not be visible to another client". As every person bound to a
# client, the probe reads every table and calls every function with another client's ids; one statement, read only.
Query 'q_iso61' "select 'iso: leaks=' || jsonb_array_length(j->'leaks') || ' people=' || (j->>'people') || ' tables=' || (j->>'tables') || ' calls=' || (j->>'calls') || ' own_rows=' || (j->>'own_rows_seen') || ' clients=' || (j->>'clients') || ' what=' || coalesce((select string_agg(distinct (x->>'kind') || ':' || (x->>'what'), ',') from jsonb_array_elements(j->'leaks') x), '-') || ' end' as result from (select app.isolation_probe() as j) p;"
if ($script:Code -ne 0 -or $script:Out -notmatch 'iso: .* end') { Stop-Run 'S2' 'the check that one client sees nothing of another could not be run (read the error above). The app was not pushed.' }
$iso = [regex]::Match($script:Out, 'iso: (.*?) end').Groups[1].Value
Say "  one client's data, another client: $iso"
if ($iso -notmatch '^leaks=0 ') { Stop-Run 'S2' "A CLIENT CAN SEE ANOTHER CLIENT'S DATA: $iso. The app was not pushed; send this line to Claude." }
Query 'q_after61' "select 'after: closures=' || (select count(*) from public.lot_closures) || ' packs_without_best_before=' || (select count(*) from public.packs where best_before is null and status <> 'void') || ' exports_logged=' || (select count(*) from public.audit_log where action = 'export_downloaded') || ' same_file_reasons=' || (select count(*) from public.attachments where dup_reason is not null) || ' old_data_scopes=' || (select count(*) from public.scopes where data_note is not null) || ' cartons=' || (select count(*) from public.cartons) || ' departments=' || (select count(*) from public.departments) || ' links=' || (select count(*) from public.buyer_links) || ' scan_flags=' || (select count(*) from public.scan_flags) || ' inspections=' || (select count(*) from public.warehouse_inspections) || ' sale_terms=' || (select count(*) from public.sale_terms) || ' samples=' || (select count(*) from public.qc_samples) || ' payments=' || (select count(*) from public.lot_payments) || ' packs=' || (select count(*) from public.packs) || ' change_log_lines=' || (select count(*) from public.change_log) || ' ledger_head=' || coalesce((select max(l.seq) from public.ledger l)::text, '-') || ' end' as result;"
$after = [regex]::Match($script:Out, 'after: (.*?) end').Groups[1].Value
Say "  after: $after"
Run "$sb db query --linked -f tests/remote_ledger_audit.sql"
if ($script:Code -ne 0 -or $script:Out -notmatch 'NO FINDINGS \(') { Stop-Run 'S2' "the ledger audit did not answer 'NO FINDINGS ('" }
$auditLine = [regex]::Match($script:Out, 'NO FINDINGS \([^)]*\)').Value
Run 'node scripts/check_logins.mjs'
if ($script:Out -notmatch 'NO LOGIN WITHOUT A PERSON') { Stop-Run 'S2' "'NO LOGIN WITHOUT A PERSON' was not printed" }
Run 'node scripts/check_functions.mjs'
if ($script:Out -notmatch 'FUNCTIONS DEPLOYED AND CURRENT') { Stop-Run 'S2' 'the functions are no longer all current' }
$smokeNote = "smoke $okCount of 59 OK"
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
  [System.IO.File]::WriteAllText($msg, "Phase 1 release 3 (migration 61): release 2's corrections and the shown parts of E2.2-E2.5. Both exports: a column per field, names not ids, empty columns left out, raw_values only in the internal copy, prices only where the scope records them, packs by size, staff and buyers named in the shareable copy (never a farmer, a price or an id), the brief's footer; floor loss without the milling by-products; a lot closed as floor loss as its own line; the mass balance per stage in the Summary and on the dashboard; the public page's Collection Batch, real village counts and one line for a batch's purchases; best-before on every pack page; Packing refused without the crop's shelf life`n`nVeda, 19 Oct 2026, the combined brief, Part C and E2: ""do what is left as per best"".`n`nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`nClaude-Session: https://claude.ai/code/session_01VSgZRQeaqm6gr2gjyiknfF`n", $utf8)
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
Say "the push of 13 Oct): Deployments, the ... menu, Create Deployment, branch main. Then docs/RUNSHEET_export_corrections.md, Afterwards."
Say 'RESULT: EXPORT CORRECTIONS ON STAGING'
exit 0
