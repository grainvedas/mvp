@echo off
rem SET-UP LISTS, release 4 (migration 51 and the app) on the practice system. Run it only when Veda has said so.
rem It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_setup_lists.ps1 and docs\RUNSHEET_setup_lists.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_setup_lists.ps1" %*
echo.
pause
