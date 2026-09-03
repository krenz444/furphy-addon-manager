Furphy Addon Manager (AddonSync)
=================================
Keeps your retail addons updated from CurseForge and Wago Addons, and gives you a CurseForge-style app to manage
them. No API key required for any of this - see NO API KEY NEEDED below.

NEW INSTALL
  Run "Install Furphy.cmd" (or "install.ps1" from PowerShell) from the folder this file is in. It finds your WoW
  folder, copies the app into <WoW>\_retail_\AddonSync, writes the launcher pair, creates both desktop shortcuts,
  registers curseforge:// install links, and adopts any addons already in your AddOns folder. Safe to re-run any
  time (upgrades the app, adopts anything new, never touches your addon list or settings). "install.ps1 -Uninstall"
  removes the app cleanly and tells you where your addon list/settings/logs were left.

TWO WAYS IN
  Desktop shortcut "WoW (auto-update addons)"  -> silently updates everything, then launches WoW via Battle.net.
  Desktop shortcut "Furphy Addon Manager"      -> opens the app (installed list, updates, versions, browse, settings).
  Both are safe to use any time; the app refuses to run two operations at once.

NO API KEY NEEDED
  Installing, updating, browsing and searching both CurseForge and Wago Addons all work with no sign-up. An
  optional free CurseForge API key (Settings -> API key) additionally gets you CurseForge's own official search/
  sort/categories plus descriptions, changelogs and screenshots sourced directly from CurseForge.

THE APP
  My Addons  installed addons with version, update badges, status (up to date / update available / pinned / ignored),
             per-addon menu: Update, Versions (install any specific version), Pin/Unpin, Ignore updates, Roll back,
             Uninstall, Open on CurseForge/Wago. "Check for updates" and "Update all" in the toolbar.
             "Update & Play" in the sidebar.
  Browse     search CurseForge and Wago Addons (source switch at the top), categories/sorting, descriptions,
             screenshots, changelogs and one-click install - all keyless. Install by Project ID or wago:<slug> also
             works without a key (the Project ID is shown in the right-hand "About Project" box on any CurseForge
             addon page).
  Settings   release channel (release / beta / alpha), auto-update on launch, optional API key, scan for untracked
             folders (with one-click adopt), diagnostics, open logs, force reinstall.

FILES (this folder)
  install.ps1 / Install Furphy.cmd   the installer (see NEW INSTALL above); -Uninstall removes the app cleanly
  addon-sync.ps1      the updater (command line; the app and the launcher both use it)
  addon-server.ps1    the local server behind the app (http://localhost:47831, only reachable from this PC)
  Addon Manager.vbs   starts the server hidden and opens the app window (Edge app mode)
  ui\                 the app's HTML/JS/CSS (no internet resources, works offline except the addon sources)
  addons.json         your addon list and installed state (project id, file id, version, folders, pin/ignore flags)
  settings.json       release channel, auto-update flag, API key, port
  VERSION             the installed version (also reported by the app's Settings -> About)
  last-run.txt        result table of the most recent update run
  sync.log            everything the updater did          server.log   everything the server did
  README.md           full docs (what it does, privacy, troubleshooting)   CHANGELOG.md   what changed each round

COMMAND LINE (open PowerShell in this folder)
  .\addon-sync.ps1                 update everything now
  .\addon-sync.ps1 -Status         what is installed (no network)
  .\addon-sync.ps1 -DryRun         what would update, without changing anything
  .\addon-sync.ps1 -Add 12345      install by CurseForge Project ID      -Add 12345 -FileId 999  install a specific file
  .\addon-sync.ps1 -Remove Name    uninstall (name or project id)
  .\addon-sync.ps1 -Ignore 12345 / -Unignore 12345 / -Unpin 12345
  .\addon-sync.ps1 -Files 12345    list available versions              -Scan   list folders not managed by the tool

SAFETY
  - A failed download never touches the installed copy; the addon is skipped for that run and logged.
  - Only folders that came from a CurseForge package are ever deleted; hand-installed folders are left alone.
  - Backups in _retail_: AddOns-backup-pre-addonsync-2026-09-01.zip (before this tool took over),
    AddOns-backup-pre-cursebreaker-2026-09-01.zip (original Wago-app state), AddOns-removed-*.zip (purged addons),
    AddonSync-backup-*.zip (this folder before each app deployment).
  - The retired CurseBreaker.exe in _retail_ is a dormant fallback; do not run it alongside this tool.
