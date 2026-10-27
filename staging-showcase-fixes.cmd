@echo off
rem SHOWCASE FIXES: Phase 3 close-out (FIX_LIST item 73, the app only) on the practice system.
rem Run it only when Veda has said so. It PUSHES TO THE MAIN BRANCH; no migration, no data changed. It asks first.
rem What it does: scripts\staging_showcase_fixes.ps1 and docs\RUNSHEET_showcase_fixes.md.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_showcase_fixes.ps1" %*
echo.
pause
