@echo off
rem FARMER REGISTER (migration 43 and the app) on the practice system: GI land, possible duplicates, the yield check.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_farmer_register.ps1 and docs\RUNSHEET_farmer_register.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_farmer_register.ps1" %*
echo.
pause
