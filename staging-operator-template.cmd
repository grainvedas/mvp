@echo off
rem OPERATOR TEMPLATE, release 1 (migration 48 and the app) on the practice system: return to sender, conditions, the date it happened, the Client Manager's day.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_operator_template.ps1 and docs\RUNSHEET_operator_template.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_operator_template.ps1" %*
echo.
pause
