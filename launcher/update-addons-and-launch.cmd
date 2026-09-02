@echo off
rem Updates all addons from CurseForge via AddonSync\addon-sync.ps1, then launches WoW retail via Battle.net.
rem Run hidden via "Launch WoW (Updated).vbs" - do not run this directly unless you want a console window.
rem Results: AddonSync\last-run.txt  History: AddonSync\sync.log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files (x86)\World of Warcraft\_retail_\AddonSync\addon-sync.ps1" -Launcher -Quiet
start "" "C:\Program Files (x86)\Battle.net\Battle.net.exe" --exec="launch WoW"
