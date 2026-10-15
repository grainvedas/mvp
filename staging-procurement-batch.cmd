@echo off
rem PROCUREMENT AND COLLECTION BATCH, release 5 (migration 52 and the app) on the practice system. Run it only when Veda has said so.
rem It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_procurement_batch.ps1 and docs\RUNSHEET_procurement_batch.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_procurement_batch.ps1" %*
echo.
pause
