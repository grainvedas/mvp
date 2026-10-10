@echo off
rem THE ADMIN'S TWO JOBS on the practice system: migration 35 and the app. Run it only when Veda has said so: it pushes
rem the database AND pushes to the main branch (Vercel builds the staging app). It asks before either.
rem What it does: scripts\staging_admin_two_jobs.ps1 and docs\RUNSHEET_admin_two_jobs.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_admin_two_jobs.ps1" %*
echo.
pause
