# Furphy Addon Manager - night report, 2026-09-06 evening to 2026-09-07 morning

Eric asked for, in order: keep the icon, a snowy theme, Tokyo Rain as the
default, fix the desktop icon; fix the install-links toggle error and reword
that row; a full Settings audit with tooltips; Wago browsing by category,
popular, new, rising and season installs; be the only GitHub contributor;
publish every release; tray-menu uninstall and background/startup controls,
the same in the app, and an easy way to distribute to non-technical players;
match the app icon everywhere; remove everything that launches the game;
uninstall the Wago App; and "iterate overnight". Everything below is live on
GIZMO unless marked otherwise.

## Versions shipped

| Version | Round | What | Notes |
|---|---|---|---|
| 1.12.0 | 31 | Tokyo Rain default; Snow Day theme (light, cocoa accent, falling snow + pines + snowman after a first draft was rejected as invisible); install-links toggle crash fixed | Sept 6 14:01 |
| 1.13.0 | 32 | Settings simplified: plain labels, one tooltip per row, install-links row reworded, Advanced regrouped 9 -> 5, DPI-aware window minimum; exe carries the cat icon; installer scoped per install | Sept 6 16:39 |
| 1.14.0 | 33 | Tray menu: background updates on/off, Start with Windows, Uninstall; Uninstall in Settings and in Windows' Installed apps; one-window installer with console fallback; latest.zip + download page; Game folders buttons fixed (from the other session); checks no longer fail on unflushed CLI output; test-suite lock and de-flaking | Sept 7 02:00 |
| 1.15.0 | 34 | No more game launching: Update & Play, Launch WoW, update-before-WoW setting, launcher files, WoW shortcut, launch endpoints and CLI launcher mode removed; game-mode detection kept; upgrade cleans legacy files | Sept 7 04:28 |
| 1.16.0 | 35 | Wago browsing (see the section below) | PENDING - see status at the end |

Your machine after the night: tray running with Start with Windows
registered; Installed apps lists Furphy 1.15.0 with a working Uninstall;
the old WoW launcher files and the "WoW (auto-update addons)" shortcut are
gone; "Furphy Addon Manager" shortcut untouched; Wago App uninstalled
(program, entry, shortcuts, 202 MB updater cache, 516 MB config/cache).

## Bugs you reported and their causes

- **Install-links toggle** ("Cannot convert PSCustomObject to
  SwitchParameter"): the script's unregister branch stored its result in a
  variable named `$status`, which PowerShell treats as the script's own
  `-Status` switch. Renamed; a unit test now runs a real register/unregister
  round-trip against a throwaway registry key.
- **"Failed - Checked for updates" although every addon was checked**: the
  server read the updater's redirected output the instant the process exited,
  but PowerShell flushes that output a moment later, so a fast run read as
  empty and empty was treated as failure. Fixed at every place a child
  process's output is read; failed jobs now keep their raw output for
  diagnosis; a regression test reproduces the exact shape.
- **App icon not matching**: the exe carried the generic .NET icon because
  the build only copied the icon next to it. The icon file also used a
  container the compiler rejected. Both fixed; pinned taskbar, Task Manager
  and the Apps list now show the cat.

## Incidents during the night (all repaired, all now prevented)

1. **Scratch uninstall removed your real startup entry and stopped your tray**
   (14:45). install.ps1 removed the Run value and set the machine-wide stop
   event regardless of which install it was removing. Fixed with per-install
   scoping (a scratch or test root can only ever touch ".Test" names) and six
   unit assertions.
2. **Windows' Installed apps entry pointed at a test folder** (early build of
   the registration). Removed by hand; the live server now writes the correct
   entry itself at startup, and tests can only write the ".Test" name.
3. **A verifying agent killed your tray with a blanket process kill** (21:50).
   Not product code. Restarted; every future brief forbids blanket kills and
   the live tray pid is re-checked after each round.
4. **Two test suites overlapping** produced the intermittent failures you
   sent. The suite now takes a lock, refuses to start while the test port is
   busy, waits for real process exit in the tray tests, snapshots only
   production processes, and was proven with three consecutive clean runs
   plus a deliberately overlapping run that the lock refused.

## Wago browsing (1.16.0)

What Wago's public site can truthfully provide, verified live: Popular
(its default order is all-time downloads), 29 categories, search, and a
"Recently updated" date per card. It has no creation date, no time-windowed
download numbers and no season concept, and the official API with sorting
needs the paid key you removed. So: Popular, Recently updated, Name, category
chips, richer rows (author, downloads, updated, summary), Load more, and a
"Gaining this week" tab that Furphy measures itself from a small daily
snapshot of the popular list (at most ten pages per version, polite pacing,
never while WoW runs) and that says so wherever it appears. Nothing is
labelled new, rising, trending or "this season".

## Waiting on you

- **GitHub**: your force push. Local history is rewritten so you are the only
  contributor, with tags v1.0.0 through v1.15.0. The deploy script no longer
  adds a co-author line. Release notes and zips are ready for 1.2.0 through
  1.15.0; they publish the moment the push lands.
- **Code signing** (optional): the installer is unsigned, so Windows shows a
  warning the first time. DISTRIBUTION-SPEC.md section 6.4 lists the options
  and costs (Azure Trusted Signing, SignPath for open source, Certum).
- **Revoke the old CurseForge API key** at console.curseforge.com.

## Status at the time of writing

See the last lines of this file for the 1.16.0 outcome and anything else that
finished after this draft.

## Status update, 2026-09-08 01:45

| Version | Round | What | When |
|---|---|---|---|
| 1.16.0 | 35 | Wago browsing shipped as designed | Sept 7 19:41 |
| 1.17.0 | 36 | Adversarial pass: 15 confirmed fixes (dual-launcher start race, CurseForge Install click off the UI thread, catalogue startup guard, docs) plus the critical one-client installer fix found by the other session | Sept 7 23:00 |
| 1.18.1 | 37 | Fast launch: measured on this machine after deploy - server answers its first request 1.5 s after the process starts (was 5-20 s when a refresh was due), addon state 60-66 ms per call after the first (was ~970 ms), install-links status 37 ms (was 413 ms); the window shows "Starting..." immediately and the shortcut no longer waits 15 s | Sept 8 01:39 |
| 1.19.0 | 38 | QA journeys: 21 confirmed findings fixed (9 high) - minimized window recovers after the helper's idle exit, Windows uninstall entry and relaunch handle "Program Files (x86)", downgrade guard, Settings port range check, honest errors for locked folders / CurseForge outages / corrupt files, Classic Wago mapping, PTR adopt gate, WebView2-missing message, log rotation and pruning; upgrade from the public 1.1.0 re-tested end to end | Sept 8 03:45 |
| 1.20.0 | 39 | IN PROGRESS: QA lens round 2 - keyboard/accessibility, installer at other display scalings, 16-theme visual regression on every view, tray text truth, documentation truth, regression-guard audit | running |

The "overnight" ran through the evening of Sept 7 and the night into Sept 8
because the usage-limit pause covered most of Sept 7's daytime. Nothing was
skipped; the order was kept.
