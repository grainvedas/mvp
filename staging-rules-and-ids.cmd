@echo off
rem RULES AND IDS (migration 44 and the app) on the practice system: who holds a stage, staffed activation, two farmer IDs.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_rules_and_ids.ps1 and docs\RUNSHEET_rules_and_ids.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_rules_and_ids.ps1" %*
echo.
pause
