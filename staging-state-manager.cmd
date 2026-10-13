@echo off
rem STATE MANAGER (migration 41 and the app) on the practice system: a State Manager works only in his own state.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_state_manager.ps1 and docs\RUNSHEET_state_manager.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_state_manager.ps1" %*
echo.
pause
