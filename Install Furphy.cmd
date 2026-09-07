@echo off
rem Runs install.ps1. It opens a small window with a single Install button
rem (falling back to a visible console automatically if that window can't
rem be shown on this machine - either way you can see what it finds and does).
rem No CurseForge API key is needed - this installs everything working keylessly.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
