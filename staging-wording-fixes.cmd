@echo off
rem WORDING FIXES (FIX_LIST item 63) on the practice system: the app only (no migration, no server function).
rem Run it only when Veda has said so. It PUSHES TO THE MAIN BRANCH (Vercel builds the staging app). It asks first.
rem What it does: scripts\staging_wording_fixes.ps1 and docs\FIX_LIST.md item 63.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\staging_wording_fixes.ps1" %*
echo.
pause
