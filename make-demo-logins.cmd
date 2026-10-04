@echo off
rem Double-click to create the demo logins on the staging project (refuses production).
rem Runs the project's own script; the passwords go to .env.demo-logins, which then opens in Notepad.
rem What the script prints (names and results, never a password) is also kept in make-demo-logins.log.
cd /d "%~dp0"
node scripts\create_demo_logins.mjs > make-demo-logins.log 2>&1
type make-demo-logins.log
echo.
if exist .env.demo-logins (start notepad .env.demo-logins) else (echo NO PASSWORD FILE WAS WRITTEN - see the lines above)
pause
