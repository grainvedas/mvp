@echo off
rem ONBOARDING AT SCALE on the practice system: the six server functions (invite is new), migration 38 and the app.
rem Run it only when Veda has said so: it changes the practice project AND pushes to the main branch (Vercel builds
rem the staging app). It asks before any of it. No test data is added.
rem What it does: scripts\staging_onboarding_at_scale.ps1 and docs\RUNSHEET_onboarding_at_scale.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_onboarding_at_scale.ps1" %*
echo.
pause
