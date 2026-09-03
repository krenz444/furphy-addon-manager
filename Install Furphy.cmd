@echo off
rem Runs install.ps1 in a visible console so you can see what it finds and does.
rem No CurseForge API key is needed - this installs everything working keylessly.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
