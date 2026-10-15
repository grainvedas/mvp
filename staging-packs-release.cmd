@echo off
rem PACKS, PROOF AND BLOCKS, release 3 (migration 50 and the app; migrations 48 and 49 first if they are still waiting)
rem on the practice system. Run it only when Veda has said so. It changes the practice database AND pushes to the main
rem branch. It asks first. What it does: scripts\staging_packs_release.ps1 and docs\RUNSHEET_packs_and_release.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_packs_release.ps1" %*
echo.
pause
