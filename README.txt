Furphy Addon Manager (AddonSync)
=================================
Keeps your retail addons updated from CurseForge, Wago Addons, and GitHub, and gives you a CurseForge-style app to
manage them. No API key required for CurseForge or Wago - see NO API KEY NEEDED below. Some guilds ship their own
addons as GitHub releases instead, sometimes gated behind a token the guild hands out - see ADDONS FROM GITHUB below.

NEW INSTALL
  Download FurphyAddonManager-Setup.exe from the Releases page (or the
  download button on the landing page). Your browser may show a mild
  download-safety notice first - choose Keep/Keep anyway, then open the
  file. Windows may show a blue "Windows protected your PC" screen since
  it isn't signed with a paid certificate - click More info, then Run
  anyway. Furphy only writes inside your WoW folder and never asks for
  admin access, and Setup never shows a Windows admin (UAC) prompt either.
  A small window then opens with a single Install button (or a folder
  picker if it can't find WoW). It finds your WoW folder, copies the app
  into <WoW>\_retail_\AddonSync, creates the desktop shortcut, registers
  curseforge:// install links, registers Furphy in Windows' own Settings >
  Apps list, and starts keeping track of any addons already in your AddOns
  folder - nothing is downloaded or changed. Safe to re-run any time.

  Scripted/silent install: FurphyAddonManager-Setup.exe /S (optionally
  followed by any install.ps1 flag, e.g. -WowPath "<path>").

  Prefer the old zip (Install Furphy.cmd / install.ps1)? Still published
  on every release for power users and the auto-updater - see the
  Releases page. Advanced: "irm <url>/install.ps1 | iex" also works from
  PowerShell with that zip's install.ps1 if you'd rather skip the
  downloaded file.

UNINSTALL (three equivalent ways)
  - Right-click the tray icon -> Uninstall Furphy Addon Manager...
  - Inside the app: Settings -> Backup & troubleshooting -> Uninstall Furphy Addon Manager
  - Windows' own Settings -> Apps -> Furphy Addon Manager -> Uninstall
  All three remove the app files, the Start with Windows setting, and the curseforge:// registration, and tell
  you where your addon list/settings/logs were left. Or run "install.ps1 -Uninstall" directly from an unzipped
  copy of the app - the same mechanism the three paths above use.

UPDATES ITSELF (starting with version 1.22.0)
  Furphy checks for a newer version of ITSELF and installs it on its own, the next time doing so is safe - never
  mid-addon-update, and (for the fully automatic path) never while a Furphy window is open. If a window is open
  when an update is ready, you'll see a small banner with an Install now button instead;
  either way it takes only a few seconds and your addon list/settings/logs are never touched. A tray balloon lets
  you know once, after a silent update finishes.
  Settings has its own "App updates" section (separate from "Update addons in the background" above - that one
  updates your ADDONS, this one updates FURPHY ITSELF) with a toggle, Install app updates automatically (on by
  default), plus Check now / Install now buttons. Turning the toggle off only stops it from installing on its own
  - checking still happens, and you can always click Install now yourself. Every update is verified before it
  touches your installed copy, and a failed update automatically restores the version you had.
  Coming from a version older than 1.22.0? This feature doesn't run for you yet - update to 1.22.0 by hand, once
  (same NEW INSTALL steps above), and every version after that updates itself.

ONE WAY IN
  Desktop shortcut "Furphy Addon Manager" opens the app (installed list, updates, versions, browse, settings).
  The tray icon's own background service keeps your addons updated on its own schedule (its "Update addons in
  the background" checkbox), so there's nothing else to click just to stay current. The app refuses to run two
  operations at once. The tray icon's right-click menu also has its own Start with Windows checkbox and an
  Uninstall option - see UNINSTALL above.

NO API KEY NEEDED
  Installing, updating, browsing and searching both CurseForge and Wago Addons all work with no sign-up, no
  account, and no key of any kind - there's nothing to configure.

ADDONS FROM GITHUB (guild addons)
  Some guilds ship their own addons as GitHub releases instead of CurseForge or Wago - sometimes as PRIVATE
  releases, gated behind a token the guild hands out (often a Patreon perk). Furphy manages those too, exactly
  like any CurseForge or Wago addon: checked, updated, pinned, rolled back.
  - Public addon: paste its github.com/owner/repo link (Settings > GitHub addons, or "From a GitHub link" under
    Get new addons) - no token needed.
  - Private addon: paste the token your guild gave you into Settings > GitHub addons and hit Save, once. The
    token stays on your own PC (it lives in your local settings.json, same as every other setting) and is only
    ever sent to GitHub itself when Furphy checks that one addon - never to CurseForge, Wago, or anywhere else,
    and Furphy never shows it back to you or writes it to any log file. If a token stops working (guilds rotate
    these), Furphy just tells you to paste a fresh one.
  - Already have the addon installed from an old script? Paste its GitHub link anyway - Furphy recognizes the
    folder that's already there and starts managing it in place, no re-download.
  - Once your GitHub addons show up in Furphy, any separate updater script or scheduled task you were using
    before is no longer needed - you can delete it.

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
                  an Advanced section for everything else (CurseForge options, game folders, addons Furphy
                  isn't managing yet with one-click Manage - no download, nothing changes until a real update
                  is found - backups, diagnostics, open logs, force reinstall all).
                  Every row that needs more explaining has a small info icon - hover or tab to it for details.

FILES (this folder)
  install.ps1 / Install Furphy.cmd   the installer (see NEW INSTALL above); -Uninstall removes the app cleanly
  addon-sync.ps1      the updater (command line; the app and the background service both use it)
  addon-server.ps1    the local server behind the app (http://localhost:47831, only reachable from this PC)
  Addon Manager.vbs   starts the server hidden if needed and opens the app window right away (native, or Edge as a fallback)
  ui\                 the app's HTML/JS/CSS (no internet resources, works offline except the addon sources)
  addons.json         your addon list and installed state (project id, file id, version, folders, pin/ignore flags)
  settings.json       release channel, background-update flag, port, GitHub token (if you pasted one)
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
  - Running an installer OLDER than what's already installed (an old downloaded zip, a stale link) now warns
    instead of silently replacing the newer app with the older one - your addon list is never touched either way.

TROUBLESHOOTING
  - If double-clicking the desktop shortcut does nothing at all and no window ever appears, the most likely
    cause is a missing or broken Microsoft Edge WebView2 Runtime - Furphy now tells you this in an on-screen
    message when it can detect it; if you ever see total silence instead, install the WebView2 Runtime from
    Microsoft (search "WebView2 Runtime download") and try again.
  - Minimizing the app and coming back to it later reconnects on its own; if "Server not reachable" ever sticks
    around after clicking back into the window, use the desktop shortcut once to restart it fully.
