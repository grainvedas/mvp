@echo off
rem THE SEASON SUMMARY FIX: Phase 1 release 3c (the app only) on the practice system.
rem Run it only when Veda has said so. It pushes to the main branch. It asks first.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_season_summary_fix.ps1" %*
echo.
pause
