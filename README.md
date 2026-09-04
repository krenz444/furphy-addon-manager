# Furphy Addon Manager

A self-contained World of Warcraft (retail) addon manager for Windows: silent updates when you launch the game, plus a CurseForge-style desktop app to browse, install, pin, roll back and manage addons - from both CurseForge and Wago Addons. No Electron, **no accounts, no API keys, no sign-up of any kind**, no ads. One PowerShell CLI, one local server, one static web UI opened as an Edge app window.

## No accounts, no API keys

Everything works out of the box, with nothing to sign up for and nothing to configure: installing and updating addons from CurseForge and Wago Addons, searching Wago and browsing the real CurseForge.com from inside the app, versions, pin/ignore/rollback, dependency and compatibility checks, descriptions/changelogs/screenshots. There used to be an optional CurseForge API key that added a little extra official metadata - it was removed entirely (2026-09-04), since every one of those flows already worked just as well without it.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built into Windows - nothing to install)
- Microsoft Edge (used for the app window; the installer falls back to your default browser if Edge is missing)
- World of Warcraft retail, installed anywhere the installer can find or you can point it at

## Install

1. Download the latest zip from the project's Releases page (or clone this repo).
2. Unzip it anywhere, then run **`Install Furphy.cmd`**. A console window shows what it's doing.
3. That's it. The installer:
   - finds your WoW retail folder (registry, then common install paths - or pass `-WowPath "<your WoW folder>"` if it can't)
   - copies the app into `<WoW>\_retail_\AddonSync\`
   - writes the "update addons, then launch WoW" launcher into `<WoW>\_retail_\`
   - creates two desktop shortcuts: **Furphy Addon Manager** (the app) and **WoW (auto-update addons)** (silent update + launch)
   - registers `curseforge://` install links (from CurseForge.com's own Install buttons) to open here instead of the CurseForge desktop app, unless you pass `-NoProtocol`
   - scans your existing `AddOns` folder and adopts anything it recognizes (CurseForge or Wago), so addons you already had become managed - reinstalling each from its source, so give it a minute; skip with `-SkipAdopt`

Re-running the installer is safe: it upgrades the app in place and adopts anything new, without touching your addon list, settings, or an addon it already manages.

Command-line options: `-WowPath <path>`, `-NoShortcuts`, `-NoProtocol`, `-SkipAdopt`, `-Uninstall`.

## Uninstall

Run `install.ps1 -Uninstall` (or `Install Furphy.cmd -Uninstall` from a console) from the unzipped folder. It removes the app files, both desktop shortcuts, and the `curseforge://` registration. Your `AddOns` folder and this tool's own addon list/settings/logs (`addons.json`, `settings.json`, `state.json`, `sync.log`, `server.log`) are left in place, in case you reinstall later; the console output tells you exactly where they are.

## Privacy

The app only listens on `http://localhost:<port>/` (default 47831) - nothing outside this PC can reach it. It talks to the internet only to do what you asked: `curseforge.com`'s public file-list/download/browsing endpoints, `addons.wago.io` and its `cdn.wago.io` downloads, `addon-radar.com` (a community CurseForge metadata mirror), and `raw.githubusercontent.com` (the offline CurseForge id catalogue, refreshed at most once a day). Nothing else - never `api.curseforge.com`, since the app never had, and no longer even has a way to hold, a CurseForge API key. No accounts, no telemetry, no ads.

## Troubleshooting

- `server.log` (in the app folder) - every request the local server handled, and any errors.
- `sync.log` (in the app folder) - everything the updater did on each run.
- `last-run.txt` - a quick table of the most recent update.
- The app shows a banner if it can't reach the server; restart it from the **Furphy Addon Manager** desktop shortcut.

## What it does

- **Update on launch** - the "WoW (auto-update addons)" shortcut runs the updater hidden, then starts WoW through Battle.net. No console flash.
- **The app** ("Furphy Addon Manager" shortcut) - one headline tells you if anything needs updating; each addon shows a single status pill (Update, Pinned, Ignoring updates, Needs a dependency, Old patch, or Up to date) that doubles as its own one-click fix; any update shows a live progress bar with the raw log one click away, and a plain-language reason plus Retry if one fails; **Get new addons** switches between an in-app Wago search and the real CurseForge.com, browsed right inside the app window (installing from a CurseForge page there just works, no key required), trimmed by default to just its search results - no CurseForge header, filter sidebar, cookie banner, or footer clutter (toggle it off in Settings > Advanced if you want the page as-is) - with ads and trackers on that page also filtered by default (same Settings > Advanced toggle to turn off); per addon: install any specific version, pin/unpin, ignore updates, **roll back** to the previous version, uninstall, open on CurseForge/Wago; automatic update checks; **update addons in the background** on a timer, plus **start with Windows**, both optional and off by default; 14 themes, picked from a swatch grid (Vaporwave default, Lofi Night, Dark, Light, and ten more - Terminal Green, Arctic Ice, Art Deco, Alpine Dawn, Matcha, Desert Night, Tokyo Rain, Brushed Steel, Aurora Sky, Strawberry Cream); Settings keeps the everyday toggles up front and tucks everything else (release channel extras, folders, logs, diagnostics) one click away; "Update & Play".
- **Two sources** - CurseForge and Wago Addons, side by side: install, pin, ignore, roll back and check dependencies/compatibility on either, no key needed for either. Wago is searched in-app; CurseForge is the real website, embedded in the app window itself (or a side window on an older install).
- **Safety** - a failed download never touches the installed copy; only folders that came from a package are ever deleted; every update keeps the previous zip for rollback.

## How it works

| File | Role |
|---|---|
| `install.ps1` / `Install Furphy.cmd` | The installer described above. |
| `package.ps1` | Builds `dist\FurphyAddonManager-<version>.zip` for a Release, from the `VERSION` file. |
| `addon-sync.ps1` | The updater/CLI. Talks to CurseForge's and Wago's public website endpoints directly - no key, no account, ever. State in `addons.json`, settings in `settings.json`. |
| `addon-server.ps1` | Local HTTP server (`System.Net.HttpListener`, localhost only). Serves `ui/`, exposes a JSON API, runs the CLI as hidden child processes for jobs, proxies Wago and CurseForge's keyless metadata sources, persists check results and job history in `state.json`. Exits after idle. |
| `ui/` | Vanilla HTML/CSS/JS single-page app. No frameworks, no CDN, works offline except the addon sources themselves. |
| `Addon Manager.vbs` | Starts the server hidden if it is not running and opens the UI as an Edge `--app` window. |
| `curseforge-handler.vbs` / `register-protocol.ps1` | The `curseforge://` install-link handler and its (per-user, reversible) registration. |
| `deploy.ps1` | Dev tool: copies a build into a live `_retail_\AddonSync` folder with a backup and end-to-end verification; never overwrites state files. Not needed for a normal install - use `install.ps1`. |
| `iterate.workflow.js` | The Claude Code workflow used to develop this: audit -> fix -> implement roadmap items -> review -> test (CLI, server API, browser-driven UI). |
| `SPEC.md` / `ROADMAP.md` / `OVERNIGHT-REPORT.md` | Authoritative spec and API contract, backlog, and build log - developer-facing, not needed to use the app. |

## CLI

```
.\addon-sync.ps1                    update everything
.\addon-sync.ps1 -Status            what is installed (no network)      -Json for machine output
.\addon-sync.ps1 -DryRun            what would update
.\addon-sync.ps1 -Add <id> [-FileId <fileId>]      install (CurseForge project id, or wago:<slug>) - optionally a specific file = pinned
.\addon-sync.ps1 -Remove <name|id>  uninstall
.\addon-sync.ps1 -Only <id> [-Force]               update/reinstall specific addons
.\addon-sync.ps1 -Ignore/-Unignore/-Unpin/-Rollback <id>
.\addon-sync.ps1 -Files <id>        list available versions
.\addon-sync.ps1 -Scan              folders not managed by the tool
```

## PowerShell 5.1 lessons learned (see CHANGELOG)

- `Get-Content` returns strings decorated with provider note properties; feeding one to `ConvertTo-Json` walks the whole provider graph and hangs. Use `[IO.File]::ReadAllText`.
- `Start-Process -ArgumentList` does not quote array elements; quote paths with spaces (`C:\Program Files (x86)\...`) yourself.
- `@()` around a `List[object]` throws on some builds; use `.ToArray()` / `foreach` / `Write-Output -NoEnumerate`.
- A single comma-joined token (`-Add 111,222`) survives `powershell.exe -File` argument binding intact; separate space-separated tokens do not collect into an array parameter the way an in-process call does.

## Status

Actively iterated; see `CHANGELOG.md`, `SPEC.md` and `ROADMAP.md`.
