@echo off
rem THE ADMIN MARKS THE HR ADMIN AS JOINED on the practice system: migration 36 and the app. Run it only when Veda has said so: it pushes
rem the database AND pushes to the main branch (Vercel builds the staging app). It asks before either.
rem What it does: scripts\staging_hr_admin_joined.ps1 and docs\RUNSHEET_hr_admin_joined.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_hr_admin_joined.ps1" %*
echo.
pause
