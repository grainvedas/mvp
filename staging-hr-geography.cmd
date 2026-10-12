@echo off
rem HR BY GEOGRAPHY on the practice system: the six server functions, migration 39 and the app.
rem Run it only when Veda has said so, and after the HR Admin has ended any seat an HR person holds (it stops otherwise).
rem It changes the practice project AND pushes to the main branch (Vercel builds the staging app). It asks first.
rem What it does: scripts\staging_hr_geography.ps1 and docs\RUNSHEET_hr_geography.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_hr_geography.ps1" %*
echo.
pause
