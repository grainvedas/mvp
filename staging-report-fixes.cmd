@echo off
rem THE SEASON REPORT FIXES: Phase 1 release 5b (the app only) on the practice system.
rem Run it only when Veda has said so. It pushes to the main branch. It asks first.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_report_fixes.ps1" %*
echo.
pause
