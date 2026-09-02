# Furphy Addon Manager

A self-contained World of Warcraft (retail) addon manager for Windows: silent CurseForge updates when you launch the game, plus a CurseForge-style desktop app to browse, install, pin, roll back and manage addons. No Electron, no accounts, no ads - one PowerShell CLI, one local server, one static web UI opened as an Edge app window.

Built for a single machine (Windows 11, Windows PowerShell 5.1) and used daily; not a general-purpose product yet.

## What it does

- **Update on launch** - the "WoW (auto-update addons)" shortcut runs the updater hidden (~15-20 s for 37 addons), then starts WoW through Battle.net. No console flash.
- **The app** ("WoW Addon Manager" shortcut) - installed list with authors, versions, update badges, status/filter chips, sorting and keyboard shortcuts; per addon: update, install any specific version, pin/unpin, ignore updates, **roll back** to the previous version, uninstall, open on CurseForge; dependency warnings; automatic update checks (persisted); update digest; light/dark theme; Settings for release channel, auto-update on launch, API key, untracked-folder scan/adopt/delete, logs and backups; "Update & Play".
- **Browse/search, descriptions, changelogs, screenshots, logos** - via the official CurseForge API, which needs a free key from <https://console.curseforge.com> (paste it under Settings). Everything else works without a key.
- **Safety** - a failed download never touches the installed copy; only folders that came from a package are ever deleted; every update keeps the previous zip for rollback.

## How it works

| File | Role |
|---|---|
| `addon-sync.ps1` | The updater/CLI. Talks to CurseForge's public website file-list and download endpoints (the ones the site itself uses; search and mod pages are Cloudflare-gated for scripts, hence the API key for Browse). State in `addons.json`, settings in `settings.json`. |
| `addon-server.ps1` | Local HTTP server (`System.Net.HttpListener`, `http://localhost:47831/`, localhost only). Serves `ui/`, exposes a JSON API, runs the CLI as hidden child processes for jobs, proxies the official CurseForge API when a key is configured, persists check results and job history in `state.json`. Exits after idle. |
| `ui/` | Vanilla HTML/CSS/JS single-page app. No frameworks, no CDN, works offline except CurseForge itself. |
| `Addon Manager.vbs` | Starts the server hidden if it is not running and opens the UI as an Edge `--app` window. |
| `launcher/` | The update-then-launch pieces used by the game shortcut (hidden VBS wrapper + cmd). |
| `deploy.ps1` | Copies a build into the live `_retail_\AddonSync` folder with a backup and end-to-end verification; never overwrites state files. |
| `iterate.workflow.js` | The Claude Code workflow used to develop this: audit -> fix -> implement roadmap items -> review -> test (CLI, server API, browser-driven UI). |
| `docs/` | `SPEC.md` (authoritative spec and API contract), `ROADMAP.md` (backlog), `OVERNIGHT-REPORT.md` (build log). |

## Install (manual)

1. Copy `addon-sync.ps1`, `addon-server.ps1`, `Addon Manager.vbs`, `README.txt`, `CHANGELOG.md` and `ui/` into `<WoW>\_retail_\AddonSync\`.
2. Copy `settings.example.json` to `settings.json` there (edit the port or release channel if you like).
3. Add addons by CurseForge Project ID: `.\addon-sync.ps1 -Add 12345 -Add 67890` (the ID is in the "About Project" box on any CurseForge addon page), or let the app do it.
4. Create shortcuts: `wscript.exe "<WoW>\_retail_\AddonSync\Addon Manager.vbs"` for the app, and the `launcher/` pair for update-then-play (edit the paths inside if WoW is not in `C:\Program Files (x86)\World of Warcraft`).

`deploy.ps1` automates steps 1-2 for repeated deployments from a checkout.

## CLI

```
.\addon-sync.ps1                    update everything
.\addon-sync.ps1 -Status            what is installed (no network)      -Json for machine output
.\addon-sync.ps1 -DryRun            what would update
.\addon-sync.ps1 -Add <id> [-FileId <fileId>]      install (optionally a specific file = pinned)
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

## Status

Actively iterated; see `CHANGELOG.md` and `docs/ROADMAP.md`. Timeline Reminders and AuraUpdater are not on CurseForge (Patreon-only) and cannot be managed by this tool.
