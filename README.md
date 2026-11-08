# Furphy Addon Manager

Furphy Addon Manager is a Windows desktop app that keeps World of Warcraft addons up to date from CurseForge, Wago Addons and GitHub releases without accounts or API keys. Version 2 is a single native program built with Rust and Tauri 2, a Svelte interface, and SQLite storage. It opens no local web server or port. Each installed WoW version (Retail, Classic Era, WoW Forever) has its own addon list and its own install folder, which can be changed in Settings.

## Requirements

- Windows 10 or 11, 64-bit.
- Microsoft Edge WebView2 Runtime. Setup checks for it and offers Microsoft's download page if it is missing.

## Install

Download `FurphyAddonManager-Setup.exe` from https://github.com/krenz444/furphy-addon-manager/releases/latest or the Download button on https://krenzcreative.org/furphy/ .

Setup installs for the current user into `%LOCALAPPDATA%\Programs\Furphy Addon Manager`, creates Desktop and Start Menu shortcuts, adds Furphy to Windows Settings > Apps, and opens Furphy. Setup writes only to the user profile and the per-user registry. Furphy itself writes addon files inside the WoW folder when it installs or updates addons.

The installer is not code-signed, so Windows may warn or block it. See Troubleshooting below.

### Silent install

- `FurphyAddonManager-Setup.exe /S` installs without opening the window.
- `FurphyAddonManager-Setup.exe /S --relaunch-tray` also restarts Furphy in the tray afterwards.

### Upgrading from Furphy 1.x

On first start Furphy 2 imports the 1.x addon list, settings and backups from `<WoW>\_retail_\AddonSync` and retires 1.x. The 1.x folder is left in place.

## Uninstall

Uninstall through Windows Settings > Apps > Furphy Addon Manager, or run:

`"%LOCALAPPDATA%\Programs\Furphy Addon Manager\Furphy Addon Manager.exe" --uninstall`

It removes the program, shortcuts and the Settings > Apps entry, and keeps the data folder and all installed addons.

The data folder is `%LOCALAPPDATA%\krenzcreative.furphy.addonmanager`. It holds the database and `app.log`. Uninstalling keeps it.

## Updates

Closing the window hides it to the tray. In the tray Furphy checks for addon updates on a schedule (every 2 hours by default; Settings offers every hour up to once a day).

For self-updates, the running app checks https://github.com/krenz444/furphy-addon-manager/releases/latest/download/latest.json every hour, verifies a SHA-256 checksum, and installs a new version automatically when the Furphy window is closed and no addon job is running. With the window open the update waits and can be installed from Settings. If the new installer cannot start, Furphy keeps running and shows the error. After a silent update the tray icon comes back.

## Command line

Run `"%LOCALAPPDATA%\Programs\Furphy Addon Manager\Furphy Addon Manager.exe"` with:

- `--check`
  Look for addon updates, install nothing.
- `--sync`
  Update addons.
- `--status`
  Show status.
- `--json`
  Machine-readable output for the three before (`--check`, `--sync`, `--status`).
- `--flavour <id>`
  Limit to one WoW version.
- `--add <link>`
  Add an addon from a CurseForge, Wago or GitHub link.
- `--export-v1 <folder>`
  Write a Furphy 1.x style copy of the data.
- `--tray`
  Start hidden in the tray.

## Privacy

Furphy contacts only:

- `curseforge.com`
- `addons.wago.io` and `cdn.wago.io`
- `github.com`, `api.github.com`, `objects.githubusercontent.com` and `raw.githubusercontent.com` (app updates, GitHub addons, the addon catalogue)
- `addon-radar.com` (addon details)

It sends no analytics.

## Troubleshooting

### If the installer does not start

- **"The code execution cannot proceed because libunwind.dll was not found."** Installers from 2.0.0 to 2.0.25 needed a file that only existed on the developer's PC. Download the current installer from the [Releases page](https://github.com/krenz444/furphy-addon-manager/releases/latest); 2.0.26 and later no longer need that file.
- **"Windows protected your PC"** (SmartScreen). Furphy isn't signed with a paid certificate. Select **More info**, then **Run anyway**.
- **"Smart App Control blocked an app that may be unsafe"** (Windows 11). Smart App Control blocks unsigned apps and has no Run anyway button. You can turn it off in Windows Security > App & browser control > Smart App Control settings; read what that page says about turning it back on before you decide.
- **Nothing happens for up to a minute.** Microsoft Defender scans a new download before its first run. Wait rather than opening the file again.
- **"Furphy needs the Microsoft Edge WebView2 Runtime."** Setup offers Microsoft's download page. Install the runtime, then start Furphy from its desktop shortcut.
- **Any other problem.** An error message names the log file, `%LOCALAPPDATA%\krenzcreative.furphy.addonmanager\app.log`. Attach it when you report the problem at https://github.com/krenz444/furphy-addon-manager/issues .

## Building from source

- `tools\test-v2.ps1`
  Runs the Rust tests (cargo test, target x86_64-pc-windows-gnullvm, llvm-mingw toolchain).
- `npm --prefix frontend run build`
  Builds the interface.
- `tools\package-v2.ps1`
  Builds the nine release assets and runs `tools\check-release-binary.ps1`, which fails the build if the exe needs any DLL that Windows does not ship and then starts it alone from an empty folder.

See CHANGELOG.md for the changes in each version.

## Documentation

The docs folder holds design documents from the 1.x PowerShell version. Version 2 replaced that architecture, so they describe 1.x, not 2.