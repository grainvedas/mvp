@echo off
rem SHOWCASE AND LIFETIME: Phase 3 release 5 (migration 72 and the app) on the practice system.
rem Run it only when Veda has said so. It changes the staging database and PUSHES TO THE MAIN BRANCH. It asks first.
rem What it does: scripts\staging_showcase_lifetime.ps1 and docs\RUNSHEET_showcase_lifetime.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_showcase_lifetime.ps1" %*
echo.
pause
