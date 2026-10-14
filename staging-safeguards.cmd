@echo off
rem SAFEGUARDS (migration 45 and the app) on the practice system: the change log, one door for corrections, the daily ledger copy.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_safeguards.ps1 and docs\RUNSHEET_safeguards.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_safeguards.ps1" %*
echo.
pause
