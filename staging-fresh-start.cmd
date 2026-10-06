@echo off
rem THE FRESH START of the practice system: empties it and leaves one admin. NOT REVERSIBLE. It asks before removing.
rem What it does: scripts\staging_fresh_start.ps1 and docs\RUNSHEET_fresh_start.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_fresh_start.ps1" %*
echo.
pause
