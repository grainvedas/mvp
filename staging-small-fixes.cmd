@echo off
rem SMALL FIXES (open item 34) on the practice system: the app only (no migration, no server function).
rem Run it only when Veda has said so. It PUSHES TO THE MAIN BRANCH (Vercel builds the staging app). It asks first.
rem What it does: scripts\staging_small_fixes.ps1 and docs\FIX_LIST.md item 34.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_small_fixes.ps1" %*
echo.
pause
