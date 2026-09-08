Furphy Addon Manager (AddonSync)
=================================
Keeps your retail addons updated from CurseForge and Wago Addons, and gives you a CurseForge-style app to manage
them. No API key required for any of this - see NO API KEY NEEDED below.

NEW INSTALL
  Download the zip, right-click it and choose Extract All, open the extracted folder, then double-click
  "Install Furphy.cmd" (or run "install.ps1" from PowerShell). Windows may show a small "Open File - Security
  Warning" box the first time you run Install Furphy.cmd, since it isn't signed with a paid certificate yet -
  click Run. Furphy only writes inside your WoW folder and never asks for admin access. On most machines one
  small window then opens with a single Install button (or a folder picker if it can't find WoW); on some
  machines you may see plain console text instead - that's fine, it does the same thing. Either way it finds
  your WoW folder, copies the app into <WoW>\_retail_\AddonSync, creates the desktop shortcut, registers
  curseforge:// install links, registers Furphy in Windows' own Settings > Apps list, and adopts any addons
  already in your AddOns folder. Safe to re-run any time (upgrades the app, adopts anything new, never touches
  your addon list or settings - and cleans up any leftover launcher files from an older install, if you're
  upgrading from before 2026-09-07).

  Advanced: "irm <url>/install.ps1 | iex" also works from PowerShell if you'd rather skip the downloaded file -
  not the recommended path for most people, since it skips the readable console log a normal install shows you.

UNINSTALL (three equivalent ways)
  - Right-click the tray icon -> Uninstall Furphy Addon Manager...
  - Inside the app: Settings -> Backup & troubleshooting -> Uninstall Furphy Addon Manager
  - Windows' own Settings -> Apps -> Furphy Addon Manager -> Uninstall
  All three remove the app files, the Start with Windows setting, and the curseforge:// registration, and tell
  you where your addon list/settings/logs were left. Or run "install.ps1 -Uninstall" directly from an unzipped
  copy of the app - the same mechanism the three paths above use.

ONE WAY IN
  Desktop shortcut "Furphy Addon Manager" opens the app (installed list, updates, versions, browse, settings).
  The tray icon's own background service keeps your addons updated on its own schedule (its "Update addons in
  the background" checkbox), so there's nothing else to click just to stay current - it pauses automatically
  while WoW is actually running. The app refuses to run two operations at once. The tray icon's right-click
  menu also has its own Start with Windows checkbox and an Uninstall option - see UNINSTALL above.

NO API KEY NEEDED
  Installing, updating, browsing and searching both CurseForge and Wago Addons all work with no sign-up, no
  account, and no key of any kind - there's nothing to configure.

THE APP
  My Addons       installed addons with version, update badges, status (up to date / update available / pinned /
                  ignored), per-addon menu: Update, Versions (install any specific version), Pin/Unpin, Ignore
                  updates, Roll back, Uninstall, Open on CurseForge/Wago. "Check now" and "Update all" in the
                  toolbar.
  Get new addons  switch between an in-app Wago search and the real CurseForge.com (open right inside the app
                  window) - both fully keyless. Paste a CurseForge link/ID or a wago.io link to install directly.
                  The Wago side has a category strip (all 29 of Wago's own categories, plus All) and a sort
                  control with four options: Popular (Wago's own default order), Recently updated (each addon's
                  own last-updated date), Name (A-Z), and Gaining this week. "Gaining this week" is Furphy's own
                  measurement, not something Wago publishes - it's built from daily snapshots Furphy takes of
                  Wago's popular list, comparing this week's download count to about a week ago, so it takes a
                  little while to have anything to show after a fresh install. It only covers Wago's own top
                  ~150 popular addons and isn't split by category or search. Wago doesn't expose an addon's
                  creation date or any "installs this season" figure at all, so neither is shown anywhere -
                  Recently updated and Gaining this week are the honest stand-ins for "new" and "rising."
  Settings        one page, two tiers - a few Essentials always on screen (release channel, spacing, theme) and
                  an Advanced section for everything else (CurseForge options, game folders, folders Furphy
                  doesn't manage yet with one-click take over, backups, diagnostics, open logs, force reinstall).
                  Every row that needs more explaining has a small info icon - hover or tab to it for details.

FILES (this folder)
  install.ps1 / Install Furphy.cmd   the installer (see NEW INSTALL above); -Uninstall removes the app cleanly
  addon-sync.ps1      the updater (command line; the app and the background service both use it)
  addon-server.ps1    the local server behind the app (http://localhost:47831, only reachable from this PC)
  Addon Manager.vbs   starts the server hidden and opens the app window (Edge app mode)
  ui\                 the app's HTML/JS/CSS (no internet resources, works offline except the addon sources)
  addons.json         your addon list and installed state (project id, file id, version, folders, pin/ignore flags)
  settings.json       release channel, background-update flag, port
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
