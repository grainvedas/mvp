@echo off
rem THE CLOSE AND THE SEASON REPORT: Phase 1 release 5 (migrations 63a and 63, and the app) on the practice system.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_close_scope_report.ps1" %*
echo.
pause
