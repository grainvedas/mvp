@echo off
rem SHARE WITH THE BUYER, SCANS AND COPIES, release 9 (migrations 56 and 56b, the app, buyer-file) on the practice system.
rem Run it only when Veda has said so. It changes the practice database, deploys one server function AND pushes to
rem the main branch. It asks first. What it does: scripts\staging_buyer_link_scans.ps1 and docs\RUNSHEET_buyer_link_scans.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_buyer_link_scans.ps1" %*
echo.
pause
