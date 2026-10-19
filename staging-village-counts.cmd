@echo off
rem THE VILLAGE COUNTS: Phase 1 release 3b (migration 61b) on the practice system.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_village_counts.ps1.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_village_counts.ps1" %*
echo.
pause
