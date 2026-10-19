@echo off
rem THE EXPORT CORRECTIONS: Phase 1 release 3 (migration 61 and the app) on the practice system.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_export_corrections.ps1 and docs\RUNSHEET_export_corrections.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_export_corrections.ps1" %*
echo.
pause
