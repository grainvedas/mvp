@echo off
rem ANOTHER CLIENT'S PEOPLE, THE PUBLIC PAGE, THE PACKS LOADED: release 10 (migration 57 and the app) on the practice system.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_people_public_page.ps1 and docs\RUNSHEET_people_public_page.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_people_public_page.ps1" %*
echo.
pause
