@echo off
rem JOINER CHECKLIST AND HR DATA on the practice system: the key of the id-numbers function, the five server functions,
rem migration 37 and the app. Run it only when Veda has said so: it changes the practice project AND pushes to the main
rem branch (Vercel builds the staging app). It asks before any of it.
rem What it does: scripts\staging_joiner_hr_data.ps1 and docs\RUNSHEET_joiner_hr_data.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_joiner_hr_data.ps1" %*
echo.
pause
