@echo off
rem CLIENT ORDERS: Phase 3 release 3 (migration 70 and the app) on the practice system.
rem Run it only when Veda has said so. It changes the staging database and PUSHES TO THE MAIN BRANCH. It asks first.
rem What it does: scripts\staging_client_orders.ps1 and docs\RUNSHEET_client_orders.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_client_orders.ps1" %*
echo.
pause
