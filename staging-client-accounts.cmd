@echo off
rem CLIENT ACCOUNTS: Phase 3 release 1 (migration 67 and the app) on the practice system.
rem Run it only when Veda has said so. It changes the staging database and PUSHES TO THE MAIN BRANCH. It asks first.
rem What it does: scripts\staging_client_accounts.ps1 and docs\RUNSHEET_client_accounts.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_client_accounts.ps1" %*
echo.
pause
