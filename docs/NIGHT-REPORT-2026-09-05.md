# Furphy Addon Manager - overnight report, 2026-09-04 evening to 2026-09-05 midday

Eric asked for: multi-version support, a full adversarial bug review, a full design/UX review, tests for everything, and a performance pass with zero impact on gameplay - then "iterate overnight". Everything below shipped to the live install on GIZMO and to github.com/krenz444/furphy-addon-manager (main). GitHub Releases were not published (they are only ever created on Eric's word); zips for every version are built under `dist\`.

## Versions shipped tonight

| Version | Round | What | Repo |
|---|---|---|---|
| 1.6.0 | 19 | Multi-version: Retail / Classic / Classic Era detected from the installed folders; per-version state with a copy-first migration (rehearsed on a copy of the live state before it ran live); version-aware file, `.toc` and Wago selection; install-link targeting; a switcher that renders nothing when only one version is installed; per-version launchers; the tray syncs every installed version | ca275f8 |
| 1.6.1 | 20 | Adversarial bug pass: 20 confirmed findings fixed (5 high) plus two hand-fixes to callers the CSRF guard broke | 5de20ac |
| 1.7.0 | 21 | Design/UX pass: 17 confirmed findings fixed (5 high) | e88c837 |
| 1.8.0 | 22-24 | Tests for everything: one runner, ~450 assertions, deploy gate | 222aa78 |
| 1.9.0 | 25 | Performance pass: game mode, low priority + efficiency mode, launch budget, perf test layer | 54c9b5a |
| 1.9.1 | 26 | Hardening: test-server readiness, lazy catalogue load, provable launch budget, launcher check-time proof | (this deploy) |

## What changed for Eric, visibly

- Nothing on the Retail-only machine from multi-version support - by design. The switcher does not exist in the page until a second client folder appears. The addon list moved one folder deeper (`flavours\retail\`) with an identical copy kept beside it in `flavours\_migration-backup-20260904-234328\`; hashes matched before and after.
- "Update all" no longer touches addons marked "Ignoring updates", and the pill says so when an update exists.
- The headline reads "Checking..." while a check or update runs.
- Pasting a CurseForge page link into Add addon now says what to do instead.
- Dark and Light themes' faint text passes contrast; the Lofi cat no longer truncates the wordmark; long sidebar labels wrap.
- Nothing polls, syncs, refreshes or talks to the network while any WoW client is running; a single muted line says so. The window drops to below-normal priority and suspends the CurseForge pane when it is not in front.

## Bug pass (round 20) - the five highs

1. The local API was reachable from the LAN by spoofing `Host: localhost`. Now bound to `127.0.0.1` and `[::1]` only.
2. No CSRF protection: any web page could drive the API. Non-GET requests now require a same-origin `Origin`/`Referer`. Two of our own callers (the `curseforge://` handler and `deploy.ps1`) were fixed by hand afterwards.
3. Addon IDs containing a space smuggled extra flags into the updater's command line. Every argument is now quoted per CommandLineToArgvW rules.
4. The server's idle shutdown killed in-flight jobs. It waits now.
5. `/api/open` let a space in a URL smuggle Edge flags past the allow-list. Structural URL parsing with an exact host match.

Also: per-version staging (two versions installing at once corrupted each other), uninstall no longer deletes the real Desktop shortcuts when run against a test root (the cause of the shortcuts vanishing twice on 09-04), int/bool settings validation (500 -> 400; "false"/"0"/"no" parse correctly), job history never evicts a running job, DPI-only monitor moves resync the pane, Wago search ignores out-of-order responses, ad-filter CSS honours a live toggle-off.

## Design/UX pass (round 21) - what the reviewers caught

Five lenses (first-time player, brief compliance, copy, visual/themes, flows), every finding independently confirmed before fixing. Highs: "Update all" updating ignored addons; the frozen headline; Dark/Light faint-text contrast (now 6.07/4.57 and 5.82/4.61 against bg-1/bg-3); the installer and README.txt still advertising the removed API key and the old "Browse" name; tray wording that said updates were "ready" after installing them. Mediums: a third update-count badge (removed: one fact, one place), Save/Load wording in toasts and dialogs, the CurseForge-link guidance, the Lofi wordmark, the overflowing sidebar button, installer console still saying "adopt".

## Tests (rounds 22-24)

`tests\run-all.ps1` runs static -> unit -> integration -> host -> spa -> fixture-acceptance -> perf, prints a summary, writes `tests\last-report.{json,md}`, exits non-zero on failure. `-Quick` skips network, tray and perf layers.

| Layer | Count (full run) | What |
|---|---|---|
| static | 7 | parse every script, node --check, ASCII, JSON, banned terms, package allow-list, .gitignore coverage |
| unit | 162 | Pester 3.4 over the CLI/server helpers (dot-source guard added) |
| integration | 76 | real server + CLI: state, settings, CSRF, loopback bind, open allow-list, jobs, freshness, tray, startup, fan-out, install/rollback/launcher |
| host | 3 | window and tray self-test markers |
| spa | 2 | headless-Edge harness (42 checks) + 14-theme contrast audit (438 pairs) |
| fixture-acceptance | 9 | FLAVORS-SPEC section 8 checklist |
| perf | 3 | the zero-gameplay-impact rule, recovery, launch budget |

`deploy.ps1` runs `-Quick` before touching the live folder and aborts on failure (`-SkipTests` overrides loudly). Mutation check: forcing the CSRF guard open, gutting the status pill and making the Classic resolver fall back to Retail each turned the suite red. The suite itself found nine real contrast failures across five older themes and a race in the window self-test, both fixed.

Timings: quick 91-199 s depending on machine load (target under 4 min - flagged as near the budget); full 470-585 s.

## Performance pass (round 25) - measured

Bench: `tests\perf\Measure-Furphy.ps1` samples every Furphy process (server, window, tray, WebView2 children) for CPU, working set, IO and new outbound TCP connections. A fake `Wow.exe` (a renamed `timeout.exe`) stands in for the game; the real client was never launched.

| State | Before | After |
|---|---|---|
| Window open on My Addons, game running, 60 s | 1.548 CPU-s, 12 requests | 0.516 CPU-s, 1 request |
| Window minimized, game running, 60 s | (not measured before) | 0.063 CPU-s, 0 requests, priority BelowNormal |
| Server + tray + minimized window + 7 WebView2 children, game running, 90 s | - | 0.047-0.078 CPU-s total, 0 requests, 0 new TCP, 0 IO, logs unchanged |
| Tray alone, game running, 180 s | 0.000 CPU-s (already skipping) | 0.016-0.031 CPU-s |
| Pre-launch update, checked recently | 1.38 s | 0.57-0.67 s |
| Pre-launch update, CurseForge unreachable (two addons) | unbounded (no cap existed) | 41.8 s, launch proceeds (cap 45 s) |
| Server cold start to listening | 0.77 s | 0.40 s (catalogue now loads after the listener is up) |

Mechanisms: a 30-second-cached game probe shared by server and host over the seven client exe names; no catalogue refresh, enrichment or auto-check in game mode; idle exit 5 min in game mode; BelowNormal + EcoQoS for the server, tray and any background window; the CurseForge pane hidden and suspended when the window is not in front for 10 s; SPA polling backed off to 60 s; 2 MB log rotation; the launcher's 45 s wall-clock budget and a skip when checked within 10 minutes. Manual actions (Update & Play, Check now, an install) still run during game mode - the user asked for them.

Reviews caught before shipping: the pane going permanently blank after an alt-tab cycle; a page message resuming a suspended pane mid-game; the tray taking five minutes to notice being switched off.

## Open items and recommendations

- **Publish the releases** when ready: zips for 1.2.0 through 1.9.1 are built and unpublished; the last published release is 1.1.0.
- **Revoke the old CurseForge API key** at console.curseforge.com. The feature is gone and the stored key was erased from settings, but the key itself still exists there and inside pre-14:36 (09-04) deploy backup zips in `_retail_`.
- **The separate session** Eric started for "Fix shared staging-dir race" was working on a bug already fixed in 1.6.1; its edits, if any, were not in the repo when checked - close it.
- **Quick test gate** is near its 4-minute budget under load; if deploys feel slow, the perf-sensitive integration tests can move to full-only.
- **Non-Retail Battle.net launch codes** are flagged as unreliable in the UI on purpose; verify against a real Classic install when one exists.
- **PTR/Beta** clients are detected but hidden behind Settings > Advanced > "Show test realms".
- **Harness gap closed**: a duplicated headline inside one container is now detected.
- The tray's "Start with Windows" registry value string is byte-identical between host and server; both remain off by default.
