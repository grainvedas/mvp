@echo off
rem FIXES AND THE CLIENT LOGIN READS ONLY: Phase 1 release 1 (migration 59 and the app) on the practice system.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_fixes_client_reads_only.ps1 and docs\RUNSHEET_fixes_client_reads_only.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_fixes_client_reads_only.ps1" %*
echo.
pause
