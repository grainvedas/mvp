@echo off
rem THE WAREHOUSE, release 8 (migrations 55a and 55 and the app) on the practice system. Run it only when Veda has said so.
rem It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_warehouse.ps1 and docs\RUNSHEET_warehouse.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_warehouse.ps1" %*
echo.
pause
