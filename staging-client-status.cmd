@echo off
rem A CLIENT IN SEVERAL STATES, ITS STATUS: Phase 2 release 2 (migration 65, and the app) on the practice system.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_client_status.ps1" %*
echo.
pause
