@echo off
rem CARTONS, REPORTS TO AND DEPARTMENTS: release 11 (migration 58 and the app) on the practice system.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_cartons_people.ps1 and docs\RUNSHEET_cartons_people.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_cartons_people.ps1" %*
echo.
pause
