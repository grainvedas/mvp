@echo off
rem A CLIENT IN SEVERAL STATES, ITS STATUS, ITS SOURCING: Phase 2 releases 2 and 3 (migrations 65 and 66, the app) on the practice system.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_sourcing_hooks.ps1" %*
echo.
pause
