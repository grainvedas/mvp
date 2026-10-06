@echo off
rem Phase 5 part D on STAGING in one go: scripts\staging_phase5.ps1 (what it does: docs\RUNSHEET_phase5.md).
rem Double-click this file, or run it from a terminal. Options are passed on, for example:  staging-phase5.cmd -From D5
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_phase5.ps1" %*
echo.
pause
