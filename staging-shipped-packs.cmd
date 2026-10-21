@echo off
rem THE SHIPPED PACKS: Phase 1 release 4 (migration 62 and the app) on the practice system.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_shipped_packs.ps1" %*
echo.
pause
