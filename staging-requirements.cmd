@echo off
rem REQUIREMENTS (migration 46 and the app) on the practice system: HR's requirements list, staffing a scope, openings' provenance.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_requirements.ps1 and docs\RUNSHEET_requirements.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_requirements.ps1" %*
echo.
pause
