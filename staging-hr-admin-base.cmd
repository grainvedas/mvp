@echo off
rem HR ADMIN BASE (migration 40) on the practice system: the admin sets where the HR Admin is based.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_hr_admin_base.ps1 and docs\FIX_LIST.md item 35.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_hr_admin_base.ps1" %*
echo.
pause
