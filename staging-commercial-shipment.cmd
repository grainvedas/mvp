@echo off
rem COMMERCIAL AND SHIPMENT, release 7 (migration 54 and the app) on the practice system. Run it only when Veda has said so.
rem It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_commercial_shipment.ps1 and docs\RUNSHEET_commercial_shipment.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_commercial_shipment.ps1" %*
echo.
pause
