@echo off
rem THE EXPORTS: Phase 1 release 2 (migration 60 and the app) on the practice system.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_exports.ps1 and docs\RUNSHEET_exports.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_exports.ps1" %*
echo.
pause
