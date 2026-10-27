@echo off
rem EVIDENCE PACK: Phase 3 release 4 (migration 71 and the app) on the practice system.
rem Run it only when Veda has said so. It changes the staging database and PUSHES TO THE MAIN BRANCH. It asks first.
rem What it does: scripts\staging_evidence_pack.ps1 and docs\RUNSHEET_evidence_pack.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_evidence_pack.ps1" %*
echo.
pause
