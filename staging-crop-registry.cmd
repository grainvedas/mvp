@echo off
rem CROP REGISTRY (migration 42 and the app) on the practice system: ready crops, typed limits, good farming practice.
rem Run it only when Veda has said so. It changes the practice database AND pushes to the main branch. It asks first.
rem What it does: scripts\staging_crop_registry.ps1 and docs\RUNSHEET_crop_registry.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_crop_registry.ps1" %*
echo.
pause
