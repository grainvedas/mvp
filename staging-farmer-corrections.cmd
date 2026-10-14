@echo off
rem FARMER CORRECTIONS (migration 47 and the app) on the practice system: Procurement fills in good farming practice and proposes corrections.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_farmer_corrections.ps1 and docs\RUNSHEET_farmer_corrections.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_farmer_corrections.ps1" %*
echo.
pause
