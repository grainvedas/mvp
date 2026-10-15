@echo off
rem MILLING, QUALITY CONTROL AND PACKING, release 6 (migration 53 and the app) on the practice system. Run it only when Veda has said so.
rem It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_milling_qc_packing.ps1 and docs\RUNSHEET_milling_qc_packing.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_milling_qc_packing.ps1" %*
echo.
pause
