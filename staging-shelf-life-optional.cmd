@echo off
rem THE SHELF LIFE OPTIONAL: Phase 1 release 3c (migration 61c and the app) on the practice system.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_shelf_life_optional.ps1" %*
echo.
pause
