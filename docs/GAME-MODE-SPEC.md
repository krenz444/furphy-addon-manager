# GAME-MODE-SPEC.md

Contract for the "addon browsing, updates and stuff need to happen while wow
is running" round. Written 2026-09-08 as the synthesis of three read-only
finder passes (addon-server.ps1/addon-sync.ps1; host/FurphyHost.cs + ui/;
tests/ + docs). Every file:line anchor below was re-verified by this
document's author directly against the build root immediately before this
file was written (a concurrent self-update round is editing
addon-server.ps1, install.ps1, host/FurphyHost.cs, ui/, and tests/ at the
same time - re-check a line against HEAD before touching it if more than a
few minutes have passed since this spec was generated). ASCII only
throughout this file and in everything the implementing round writes.

---

## 1. Policy

**Eric's rule, verbatim (2026-09-08 evening):** "addon browsing, updates and
stuff need to happen while wow is running."

This replaces the OLD rule this codebase was built around (also verbatim,
still quoted in several places below because it is the thing being
overturned): "do a full performance tuning / pass, absolutely nothing /
everything must have zero impact on gameplay."

### 1.1 Works while a WoW client is running (no gate on Test-GameRunning /
WowDetector.IsRunning left anywhere in the path)

- Addon update checks, updates, installs, removals, rollbacks (`sync`,
  `check`, `add`, `remove`, `install`, `rollback`, `update-all-flavours`,
  `import`, `switch-source` job kinds - all of them, not a subset).
- Wago browsing/search (Popular, Recently updated, Name A-Z, live search).
- CurseForge browsing (the embedded CurseForge.com pane) and catalogue
  refresh (`Initialize-CfCatalogueIndex`'s 24h freshness cadence).
- Wago's own daily "growth snapshot" background crawl
  (`Initialize-WagoGrowthSnapshots`, feeds `sort=gaining`).
- Per-addon enrichment (`GET /api/cf/enrich/{id}` - Wago-match lookup, then
  the addon-radar.com detail fetch).
- Background tray cycles (`RunCycle` in host\FurphyHost.cs) - the whole
  addon check+update fan-out across flavours.
- The hourly maintenance child (`Invoke-MaintenanceTick`'s
  `-MaintenanceOnly` spawn) - which is also what folds in the self-update
  check, so removing ITS gate is most of what makes self-update
  policy-compliant too.
- The app's own self-update CHECK and DOWNLOAD (`POST /api/app-update/check`
  manual trigger, the hourly maintenance-child check, and
  `Invoke-AppUpdateMaintenanceCore`'s check/download/verify/stage pipeline,
  which already has zero `Test-GameRunning` calls anywhere in it and needs
  no change).

### 1.2 Stays - CPU-only measures kept because they cost no function

None of these refuse or delay any addon/browse/update/self-update work;
they only make the app cheaper to have open/resident while you play.

- Decorative theme animations paused while `data-game-active` or
  `data-window-inactive` is set on `<html>` (the entire "Decorative
  animation gating" CSS section, ui\style.css:3931-4057, and the
  `Store.applyGameActiveAttr`/`WindowActivity` plumbing that stamps those
  attributes, ui\app.js:2160-2301 and ui\app.js:120-200ish). Unchanged.
- `BelowNormal` priority + EcoQoS for background/resident processes:
  `Set-FurphyLowPriority` (addon-server.ps1:10416-10424, unchanged),
  `TrayForm`'s constructor `ApplyLowPriority` (host\FurphyHost.cs:5219-5224,
  unchanged), and `MainForm`'s own foreground/background priority drop
  (host\FurphyHost.cs:2214-2260, `EnterBackgroundMode`/`ExitBackgroundMode`,
  keyed on window focus/minimize, never on WoW - unchanged). These are
  defense-in-depth CPU savings for a resident process, not a network gate.
- CurseForge WebView2 pane suspended when the app window is not foreground
  (`EnterBackgroundMode`'s `TrySuspendAsync` call, host\FurphyHost.cs, and
  `scheduleRectUpdate`'s deliberately-NOT-gameRunning-gated logic,
  ui\app.js:6528-6544, which already has its own comment confirming this
  was fixed correctly before this policy even existed). Unchanged.
- The request loop's `WaitOne` timeout widening from 2000ms to 15000ms
  while `Test-GameRunning` is true (addon-server.ps1:10574-10576 in the
  current code, kept in the new code too) - only reduces how often an
  idle loop wakes with nothing to do; a real request signals the wait
  handle and returns instantly regardless, so request latency is
  unaffected. Kept exactly as the task brief calls for.
- The SPA's own idle `/api/state` poll backing off from 5s to 60s while
  `Store.state.gameRunning` is true (`POLL_GAME_MS`, ui\app.js:8443-8460).
  This only throttles a passive UI-freshness refresh; an in-flight job is
  tracked by its own independent 500ms `pollJob` loop regardless, and
  `startJob`/`autoCheckForUpdates` are unaffected. Kept.
- The 30s `Test-GameRunning` cache interval (addon-server.ps1:280-303,
  `$Script:GameProbeIntervalSeconds`) and the 30s `WowDetector` poll that
  pushes `{type:"game", running}` to the SPA (host\FurphyHost.cs:2487-2520).
  Both are cheap detection-signal plumbing the surviving CSS gating and the
  new reload/relog messaging both depend on. Kept verbatim.

### 1.3 Dropped - no CPU reason survives the new policy

- **The shortened idle-exit window in game mode**
  (`$Script:IdleMinutesGameRunning = 5`, addon-server.ps1:10030). Its own
  stated rationale ("nothing should be polling this server during
  gameplay... exiting sooner is the safer default") is exactly the
  assumption 1.1 above overturns - legitimate work (browsing, checks,
  updates, the hourly maintenance tick) now happens throughout a play
  session, so a quiet gap of a few minutes between requests no longer
  means "this server is stuck, tear it down." Worse: once
  `Invoke-MaintenanceTick`'s own gate is removed (section 4), the hourly
  maintenance child (catalogue refresh + Wago growth crawl + self-update
  check) only keeps firing for as long as this resident request loop stays
  alive - a 5-minute idle-exit during exactly the long WoW sessions this
  maintenance is now supposed to keep running through would tear the
  server down long before the next hourly tick is due, defeating the fix.
  This has no independent CPU justification (a stopped process uses zero
  CPU either way; the question is only how soon it stops, and "soon" is
  now wrong). DROPPED - see section 4.4 for the exact edit.

Every OTHER `Test-GameRunning`/`WowDetector.IsRunning` call site that
currently refuses or defers FUNCTIONAL work (network I/O, a job, an
install, a UI action) is dropped in sections 4 and 5 below. Every call site
that only feeds the CSS gate, the priority mechanism, or the new
reload/relog signal is kept per 1.2.

---

## 2. Inventory

Format: `file:line` | current behavior | new behavior | action. Verified
directly against the build root at write time. Grouped by file; findings
that are pure detection/CPU plumbing and need **no change** are listed too,
so nothing is silently skipped.

### addon-server.ps1

| Site | Current | New | Action |
|---|---|---|---|
| 228-241 (doc comment above `$Script:KnownWowProcessNames`) | Quotes the OLD rule verbatim ("zero impact on gameplay... refuse to do network I/O while the game is up") | Rewrite to say Test-GameRunning now exists ONLY to (a) drive the SPA/tray decorative-gating + reload/relog signal, and (b) gate the surviving CPU-only measures (15s idle wait, BelowNormal/EcoQoS, decorative animations). Explicitly state it no longer gates any network/functional work. | Change (comment only) |
| 280-303 (`function Test-GameRunning`) | Cached probe, `-WowFakeProcessName` seam, 30s cache | Unchanged | Keep |
| 1405-1406 (default-settings object literal, doc comment above `appUpdateAutoInstall`) | A second, independent copy of the OLD "Safe" rule: `# safe (never while WoW is running or a job is running, and - for` / `# this automatic path only - never while any Furphy window is`. This is the exact sentence APP-UPDATE-SPEC.md:22-25 mirrors (fixed by section 6's table) - but this in-code copy is a separate site the SPA/host tables never touch. | Drop `never while WoW is running or a job is running` down to `never while a job is running` (matches the section 6 rewrite of APP-UPDATE-SPEC.md:22-25 exactly - keep both copies textually identical, same "must agree" spirit as ComputeCore/computeCoreText). | Change (comment only) |
| 4747-4890 (`Handle-WagoBrowse`), specifically 4871/4873/4890 | `$gameIsRunning = Test-GameRunning` (4871); `Get-WagoCached -PageUri $uri -AllowLiveFetch:(-not $gameIsRunning)` (4873); cold-miss-while-running returns `gameActive=$true` + empty items (4890) | Always `-AllowLiveFetch:$true` (or omit the switch). Remove the `gameActive` branch and the `$gameIsRunning` variable entirely - the field is dropped from the response (see SPA-side removal below), not kept as always-false. | Remove gate + remove field |
| 5349-5490 (`Initialize-WagoGrowthSnapshots`), gates at ~5421-5423, ~5451-5454, ~5484-5487 | Three `Test-GameRunning` checks: skip the whole crawl at top; re-check before each flavour; re-check before every page (TOCTOU abort, sets `$abortAll`) | Remove all three checks and the `$abortAll` machinery. Keep the per-`game_version` 20h freshness gate, the `FURPHY_TEST_SKIP_WAGO_GROWTH` test escape hatch, and the `-Root`/`$Script:AcceptingRequests` ordering guard - none of those are WoW-state gates. | Remove |
| 5597-5636 (`Invoke-MaintenanceTick`) | `param([bool]$GameRunning)` then `if ($GameRunning) { return }` as the first line - single master gate disabling catalogue refresh + Wago growth crawl + hourly self-update check together whenever WoW runs | Drop the `$GameRunning` param and the `if` line entirely - function starts straight at the `$Script:LastMaintenanceAttemptAt` interval check. See section 4.2/4.4 for the exact diff and the caller-site update. | Remove (highest-impact single site) |
| 5876-5947 (`Initialize-CfCatalogueIndex`), line ~5923 | `if ($stale -and (Test-GameRunning)) { ...skip, log "skipped at startup: WoW is running"... }` | Drop the `-and (Test-GameRunning)` clause so a stale (>=24h) catalogue refreshes on its normal cadence regardless of game state. Keep `FURPHY_TEST_SKIP_CF_CATALOGUE` and `$Script:AcceptingRequests` guards. | Remove |
| 6463-6564 (`Get-CfEnrichmentNoKey`), lines ~6494/6498/6500/6531 | `$gameIsRunning = Test-GameRunning` (6494); Wago-match lookup gated `(-not $gameIsRunning)` (6498, 6500); addon-radar fetch gated the same way (6531) | Remove the `(-not $gameIsRunning)` condition from all three sites and delete the now-unused `$gameIsRunning` variable. Enrichment always attempts a live/cached lookup. | Remove |
| 6957-6968 (`Handle-Ping`), 7037-7220 (`Handle-State`) | `gameRunning = (Test-GameRunning)` in both response bodies - informational only | Unchanged. Still drives the SPA's decorative gating and now additionally the reload/relog awareness (via the job/lastRun fields below, not this field itself). | Keep |
| 9528-9538 (`Handle-AppUpdateCheck`) | `if (Test-GameRunning) { Send-Json 200 @{ok=$true; skipped='game running'}; return }` as the first check | Remove entirely. `Invoke-AppUpdateMaintenanceCore` (called by both this handler and the hourly maintenance child) already has zero `Test-GameRunning` calls in its check/download/verify/stage pipeline - removing this one HTTP-level gate is the whole fix. | Remove |
| 9593-9691 (`Handle-AppUpdateInstall`), lines 9619-9628 (job-running 409) and 9631-9636 (game-running 409) | Two 409 gates before staging: job-running, then `if (Test-GameRunning) { deferredReason='game-running'; Send-Json 409 'WoW is running' }` | Remove the game-running gate (lines 9631-9636) only. KEEP the job-running gate (9619-9628) unchanged - it is one of the two surviving install preconditions. install.ps1 -Upgrade never touches WoW or Interface\AddOns, so there is no technical tie to game state left. | Remove game-running gate; keep job-running gate |
| 10018-10032 (idle-exit window setup) | `$Script:IdleMinutesNormal = $IdleMinutes` (10029); `$Script:IdleMinutesGameRunning = 5` (10030); doc comment above justifies the shortening | Drop `$Script:IdleMinutesGameRunning` entirely; rewrite the doc comment to say the idle-exit window no longer shortens in game mode and why (section 1.3). | Remove (paired with next row) |
| 10568-10598 (request-loop body) | `$idleLimit = $Script:IdleMinutesNormal; if ($gameRunningNow) { $waitMs = 15000; $idleLimit = $Script:IdleMinutesGameRunning }` (10574-10578); `Invoke-MaintenanceTick -GameRunning $gameRunningNow` (10594) | Keep `$waitMs = 15000` widening when `$gameRunningNow` is true; drop the `$idleLimit` reassignment inside that `if` (idleLimit is always `$Script:IdleMinutesNormal`). Change the call site to plain `Invoke-MaintenanceTick` (no args). | Change (see 4.4 for exact before/after) |
| 2898-2919 (`Start-Job`, single-phase job object literal) | No notion of whether WoW was running at job start | Add `gameRunningAtStart = (Test-GameRunning)` to the literal (captured once, at spawn time). | Add field |
| 3106-3163 (`Start-ImportJob` job object literal, ~3141-3159) | Same gap | Add `gameRunningAtStart = (Test-GameRunning)` to this literal too (captured before checking whether there is anything to import - correct even on the zero-phases immediate-finish branch just below it). | Add field |
| 3719-3775 (`Start-SwitchSourceJob` job object literal, ~3756-3773) | Same gap | Add `gameRunningAtStart = (Test-GameRunning)` to this literal too. | Add field |
| 4103-4131 (`Get-JobStatusView`) | Returns id/kind/params/state/startedAt/finishedAt/exitCode/log/results/error/flavour/progress/choices - the single shape behind `GET /api/jobs*`, `/api/state.job`, and the persisted `state.json` job-history array | Add `reloadNeeded` (bool) to the returned object, computed from `$Job.gameRunningAtStart` and `$Job.results` (exact predicate in section 4.1). One change here reaches every consumer. | Add field |
| 3457-3580 (`Apply-JobCompletionSideEffects`), the `$Script:LastRunByFlavour[$flavor] = ...` literal at 3576-3580 | `[PSCustomObject]@{ timestamp; summary; rows }` - the persistent "Last run" slot that outlives the 20-job history | Add `reloadNeeded` (bool) to this literal too, same predicate, sourced from the completing job. This is what lets the SPA's "Last run" line keep the reload reminder after later unrelated jobs pushed the original job out of `state.json`'s 20-entry history. | Add field |
| 3254+ (`Load-CheckState`, the `foreach ($jv in @($obj.jobs))` reconstruction loop and its `$job = [PSCustomObject]@{...}` literal) | Reconstructs id/kind/params/state/startedAt/finishedAt/exitCode/log/results/error/flavour/Process/OutFile/ErrFile/SyncLogOffset/Phases/PhaseIndex from a persisted job - no `gameRunningAtStart`. Confirmed BUG once 4.1's field ships: `Get-JobStatusView`'s `reloadNeeded` reads `$Job.gameRunningAtStart`, a silent `$null`-is-falsy property access on a reconstructed job that never had it set, so EVERY job that survives a server restart reports `reloadNeeded: false` from then on via `GET /api/jobs*`, `/api/state.job`, and every later `Save-CheckState` re-derivation - even one that genuinely updated an addon while WoW was running. (`$Script:LastRunByFlavour`'s own `reloadNeeded`, section 4.2, is unaffected - `Load-CheckState` copies that object verbatim rather than rebuilding it field-by-field, so only the job-history/API surface breaks.) | Add one line to the reconstructed literal: `gameRunningAtStart = [bool]$jv.gameRunningAtStart` (safe against an old, pre-this-round state.json with no such key - `$jv.gameRunningAtStart` reads as `$null` there and `[bool]$null` is `$false`, the same "no signal, no reload note" behavior a brand-new job with the field would show if it legitimately started with WoW closed). | Add field (bug fix - see section 8 for the missing restart round-trip test) |

### addon-sync.ps1

| Site | Current | New | Action |
|---|---|---|---|
| Whole file (confirmed via grep for `gameRunning`/`GameRunning`/`WowFake`/`IsRunning`/`is running`) | Zero game-state awareness anywhere - it always writes addon folders the same way regardless of caller/game state | No change required for policy compliance - it never refused anything based on WoW to begin with. | No change (policy) |
| `Install-AddonPackage`, the per-folder swap loop (~1257-1276): `Remove-Item -Recurse -Force` then `Move-Item` per top-level folder, staging on the same volume as the destination, any single-folder failure recorded in `$failedFolders` and the whole package THROWS at the end (~1288) | Correct today; becomes more load-bearing once installs legitimately happen more often mid-session (raising, slightly, the odds of hitting a file another process happens to be touching - Windows Search, an AV real-time scanner, a sync client - not WoW itself, see section 7.1) | RECOMMENDED (not policy-required) addition: wrap the `Remove-Item`+`Move-Item` pair per folder in a small retry - 3 attempts, ~150ms apart, only around that swap - so a transient external lock does not fail an otherwise-good install. After 3 failures, the existing throw-and-record-in-`$failedFolders` behavior is unchanged (never silently swallow the final failure). | Add (recommended resilience, not a policy requirement - see section 7.4) |

### host\FurphyHost.cs

| Site | Current | New | Action |
|---|---|---|---|
| 5814-5828 (`RunCycle`, WoW check) | `if (WowDetector.IsRunning(_options.WowFakeProcessName)) { CompleteCycleSkippedWow(); return outcome; }` before any work | Remove the whole `if` block. `RunCycle` always proceeds to `SetCheckingStarting()`/the ping/job-post flow. | Remove |
| 6422-6437 (`CompleteCycleSkippedWow`) plus its 2 call/state refs | Sets status `waiting_game`/lastResult `skipped_wow_running`, writes tray-state.json (first skip only), schedules next recheck 10 minutes out instead of the normal interval | Remove the whole method (dead once the RunCycle gate is gone). This also removes the shortened 10-minute recheck cadence - no CPU justification once cycles simply run during WoW. | Remove |
| 6638-6639 (`ComputeCore`'s `"waiting_game"` case) | `case "waiting_game": return "Waiting for WoW to close - next check after";` | Remove this case - status `waiting_game` can no longer occur. | Remove |
| 6042-6045 (`RunAppUpdateStep`, WoW check) | `if (WowDetector.IsRunning(_options.WowFakeProcessName)) return;` blocks the status GET, `AnnounceInstalledIfNew`, and the silent install POST together | Remove these 4 lines. Every other check in the function (`state=="ready"`, `WindowOpen`, `AppUpdateAutoInstall`) is untouched. | Remove |
| 6006-6021 (`RunCycle`'s tail, the doc comment right before the `RunAppUpdateStep(settings)` call) and 6025-6032 (the doc comment on `RunAppUpdateStep` itself) | Two more stale-rationale comments, not caught by the `RunCycle`/`RunAppUpdateStep` code rows above (which only cover the executable lines, not these doc comments): the first says "every OTHER return in this function above (WoW running at (a); ...) already exits RunCycle before this line - which is exactly 'never while WoW is running' ... for free" and "RunAppUpdateStep still re-checks WoW itself, purely as defense-in-depth ... matching this file's own 'enforced twice' idiom"; the second says "... AND (defense-in-depth) WoW is not running right now, POST /api/app-update/install ...". Both go false the instant `RunCycle`'s `(a)` check and `RunAppUpdateStep`'s own check are removed. | Rewrite both. First: drop the "(WoW running at (a); ...)" parenthetical and the "never while WoW is running" / "enforced twice" claims - this step's only remaining "for free" guarantee is "never while a job is running" (from (c)); state plainly that `RunAppUpdateStep` no longer re-checks WoW at all. Second: drop "AND (defense-in-depth) WoW is not running right now" from the precondition list - it is now `state=="ready"` AND no window open AND `AppUpdateAutoInstall` true, full stop. | Change (comment only) |
| 6966-6979 (`ShowBalloon`) | Fires only for `done_updated`/`done_failed`, joined addon-name list, title "Furphy", 8000ms, never mentions WoW | For `status=="done_updated"` ONLY, check `WowDetector.IsRunning(_options.WowFakeProcessName)` fresh (not the RunCycle-start check - minutes can pass during a sync) at the moment the balloon is about to show. If true, append `" - WoW will use it once you type /reload in your chat window, or log out and back in."` to the name-list text before calling `ShowBalloonText`. Never append for `done_failed`. Keep 8000ms and title "Furphy". Per 3.6, this same fresh check's result is also what feeds `_reloadNeeded` for the tooltip/Settings status line - compute it once, reuse for both, do not check `WowDetector` twice for the same cycle completion. | Change (add the reload note) |
| 2165, 6420 (code comments quoting "zero impact") | Comment wording only | Reword to "light touch while you play"; keep the surrounding technical explanation for measures that survive (BelowNormal/EcoQoS at 2165). Line 6420's instance disappears with `CompleteCycleSkippedWow`. | Change (cosmetic) |
| 2214-2260 (foreground/background tracking, `EnterBackgroundMode`/`ExitBackgroundMode`), 5219-5224 (`TrayForm` `ApplyLowPriority`) | Keyed on window focus/minimize or on simply being the tray process, never on `WowDetector.IsRunning` | Unchanged - explicitly preserved CPU measures (1.2). | Keep |
| 2487-2520 (`StartGameCheckTimer`/`CheckAndReportGameState`, 30s cadence) | Pushes `{type:"game", running}` to the SPA on change | Unchanged - feeds the surviving CSS gate and is cheap. | Keep |

### ui\app.js

| Site | Current | New | Action |
|---|---|---|---|
| 2160-2301 (`Store.state.gameRunning`, `applyGameActiveAttr`/`set()`) | Drives `data-game-active` (CSS gate) and feeds the idle-poll backoff/Freshness note | Keep the field and the CSS-attribute plumbing unchanged. Only the DOWNSTREAM behaviors below change. | Keep (plumbing) |
| 3106-3145 (`Components.Freshness.render`, the `if (Store.state.gameRunning) {...}` block at ~3139-3143) | Appends `"WoW is running - background checks paused"` (`freshness-game-note`) whenever gameRunning is true - now false, since checks no longer pause | Replace with the reload-reminder note: `if (Store.state.gameRunning && Store.state.lastRun && Store.state.lastRun.reloadNeeded) { ...append "WoW will use it once you type /reload in your chat window, or log out and back in." under a renamed class `freshness-reload-note`... }`. Exact copy/placement in section 3.2. | Change (repurpose, not just remove) |
| 5498-5513 (`Actions.checkAppUpdate`) | Shows `"Can't check for updates right now - WoW is running."` when `res.skipped` is set | `res.skipped` for that reason can no longer occur once the server drops the gate. Remove the WoW-specific toast copy/branch entirely (or repoint it at whatever else, if anything, legitimately reports `skipped` - nothing does today). | Remove |
| 6140-6360 (Wago browse render), specifically `w.gameActive = !!res.gameActive` (6153), `gameActiveBox` (6306, 6313), the gate at 6351-6356 | Hides the grid and shows `#browse-gameactive` whenever `gameActive:true` comes back for a live-fetch sort | Remove the whole gate block and the `w.gameActive` assignment - the server no longer sends this field at all (see server-side removal above), so there is nothing to read. | Remove |
| 7058-7082 (`renderAppUpdates`) | `checkBtn.disabled = gameRunning` (title "WoW is running"); `installBtn.disabled = gameRunning \|\| jobRunning` (title "WoW is running" when that's the reason) | Remove `gameRunning` from both conditions and drop the "WoW is running" title branch on each. `installBtn.disabled = jobRunning;` only, title "An addon job is running" only. | Remove |
| 8547-8558 (`Actions.scheduleAutoCheck`) | Both the page-load kick and every repeat tick skip while `Store.state.gameRunning` is true | Remove `Store.state.gameRunning` from both conditions, leaving only the `Store.isBusy()` guard. | Remove |
| 8258-8296 (`pollJob` completion) | Shows one toast from `Components.JobPanel.summarize(job.results)`, no WoW mention ever | Once `job.reloadNeeded` (new server field) is true, append `" - WoW will use it once you type /reload in your chat window, or log out and back in."` to the summary and pass `{duration: 7000}` to `Components.Toast.show`. Exact wiring in section 3.1. | Add |
| 1047-1065 (mock `/api/state` gameRunning), 1365-1370 (mock Wago game-active), 1472-1473 (mock app-update check skip), 1486-1487 (mock app-update install 409) | `?mock=1&game=1` simulates every one of the removed gates | Remove the 3 obsolete branches (1365-1370, 1472-1473, 1486-1487). Keep the base `gameRunning` mock flag (1050/1057/1064) - still needed to preview the CSS gate and (surviving) `POLL_GAME_MS` backoff. Add a mock `reloadNeeded: true` on a completed job under `?game=1` so the new toast/note are previewable too. | Remove 3, add 1 |
| 8443-8460 (`POLL_GAME_MS`) | 5s -> 60s idle-poll backoff while gameRunning | Unchanged (1.2). | Keep |
| 6528-6544 (`scheduleRectUpdate`, CF-pane) | Deliberately NOT gated on `gameRunning` (comment explains this was already fixed) | Unchanged. | Keep |
| 6299-6356 (`renderWagoResults`, non-gate parts) | Normal grid/skeleton/empty/error rendering | Unchanged apart from the gate removal above. | Keep |
| 126-127, 8445 (comments quoting "zero impact") | Comment wording only | Reword to "light touch while you play"; the technical explanation underneath (data-game-active gating, POLL_GAME_MS) is unchanged and stays. | Change (cosmetic) |
| host\FurphyHost.cs `ComputeCore` <-> ui\app.js `computeCoreText`/`backgroundStatusText` mirror (ui\app.js ~7152-7220) | Both sides carry matching `"waiting_game"`/`"skipped_wow_running"` cases (the two functions are maintained as byte-identical mirrors, by their own doc comments) | Remove the matching `case "waiting_game": return "Waiting for WoW to close - next check after";` and `case "skipped_wow_running": return "Waiting - WoW is running";` from ui\app.js in the SAME change as the host-side removal, or the "must agree" mirror contract breaks. | Remove (paired with host-side) |
| `computeCoreText`'s `"done_updated"` case (ui\app.js ~7176-7183) <-> `ComputeCore`'s `"done_updated"` case (host\FurphyHost.cs, section 2 table above) | Neither side knows about the reload/relog signal at all - the toast (3.1), Freshness note (3.2), and balloon (3.3) all get it from elsewhere (`job.reloadNeeded`, `lastRun.reloadNeeded`, a fresh `WowDetector` check), but the tray's own persistent tooltip/menu text and the SPA's `#updates-background-status` Settings line (both driven by this exact mirrored pair, per its own "must agree" comment) never do. RECOMMENDED EXTENSION, not required by Eric's literal ask (toast + persistent note + balloon) - see section 3.6 for the full design and section 10 for who owns it. | Add `reloadNeeded` param to both functions' `"done_updated"` branch, sourced from a new `reloadNeeded` field on the persisted tray state (section 3.6) | Add (recommended, section 3.6) |

### ui\index.html

| Site | Current | New | Action |
|---|---|---|---|
| 998-1007 (`#browse-gameactive` empty-state) | `<div class="empty-state" id="browse-gameactive" hidden>...Wago browsing pauses while a WoW client is running...</div>` | Remove this element and its explanatory comment - unreachable once the JS gate (ui\app.js:6351-6356) is gone. | Remove |
| 1116 | Tooltip: "...using a separate process that keeps running even after you close Furphy. It pauses while WoW is running. Off by default." | "Checks for updates on a schedule and installs them automatically - using a separate process that keeps running even after you close Furphy. Off by default." | Change |
| 1124 | Tooltip: "How often Furphy checks for updates in the background. If WoW is already running, it skips that check and tries again once you close the game." | "How often Furphy checks for updates in the background." | Change |
| 1156 | Tooltip: "...it installs on its own the next time no Furphy window is open - and never while WoW is running. Turn this off..." | "When a new version of Furphy is ready, it installs on its own the next time no Furphy window is open and no addon job is running. Turn this off to only be asked before installing. On by default." | Change |

### ui\style.css

| Site | Current | New | Action |
|---|---|---|---|
| 1122 | `.freshness-game-note { margin-top: 2px; }` | Rename selector to `.freshness-reload-note` to match the repurposed note in ui\app.js (same rule body, unchanged). | Change (rename, paired with app.js) |
| 3931-4057 ("Decorative animation gating" section, every `data-game-active`/`data-window-inactive` selector) | Pauses decorative CSS animations while the game runs or the window is inactive | Unchanged - explicitly kept (1.2). | Keep |

---

## 3. User experience

Two new surfaces (SPA toast/note, tray balloon) and three settings-copy
fixes (already in the inventory above). Exact copy, chosen once and reused
verbatim everywhere so the "must agree" mirrored-text convention this
codebase already uses (ComputeCore/computeCoreText) extends naturally to
this new text too:

> **Canonical clause: `" - WoW will use it once you type /reload in your
> chat window, or log out and back in."`**

Built on Eric's own wording ("a /reload or a relog"), spelled out rather
than left as jargon: this project is explicitly for below-average-
tech-savvy players, and nothing in the shorter "/reload or a relog"
phrasing tells a reader who has never used a slash command that `/reload`
is typed into WoW's own chat box, not clicked anywhere in Furphy. The
longer clause says the same thing Eric asked for, just spelled out so it
reads the same - and is actually actionable - whether a below-average-
tech-savvy player sees it in the app, in a toast, or in a tray balloon.

### 3.1 SPA toast (immediate, foreground job completion)

- **Where:** the existing toast stack (`#toast-container`, top of the app
  window), via the existing `pollJob` completion path (ui\app.js:8258-8296)
  - this is the one choke point every foreground job (check/sync/add/
  install/remove/rollback/import/switch-source, and each per-flavour job
  from an `update-all-flavours` fan-out) already passes through.
- **When:** the job finished (`job.state !== "failed"`) AND the new server
  field `job.reloadNeeded` (section 4.1) is `true`. Do NOT re-derive this
  client-side from `job.results` - trust the server's computation, which
  already knows whether the game was running when the job STARTED (a race
  a client-side re-check against the CURRENT `Store.state.gameRunning`
  would get wrong if the player quit WoW mid-job).
- **Exact copy:** take the existing summary text
  (`Components.JobPanel.summarize(job.results)`, e.g. `"2 updated, 1 up to
  date"`) and append the canonical clause, producing e.g. `"2 updated, 1
  up to date - WoW will use it once you type /reload in your chat window,
  or log out and back in."`
- **How long:** pass `{duration: 7000}` to `Components.Toast.show` (longer
  than the 4500ms success default, matching the existing error-toast
  precedent, so the extra sentence is readable).
- **Dismissal:** unchanged toast mechanism - auto-removes after the
  duration, or the existing dismiss (X) button. No new UI needed.
- **Do NOT** add the clause for a check-only job (no Installed/Updated/
  Rolled-back rows), or for a job whose only rows are Removed/Pinned/
  Unpinned/Ignored/Unignored/Failed/Skipped/Up-to-date - only when
  something was actually written to disk while the game was running.

### 3.2 SPA persistent note ("Last run" line, survives past the toast)

A toast disappears in a few seconds; a player who tabs back to Furphy
5 minutes later with WoW still running and an unactioned update should
still see the reminder. This is what the persisted `lastRun.reloadNeeded`
field (section 4.1) is for.

- **Where:** `Components.Freshness.render` (ui\app.js:3106-3145), the same
  slot that used to hold the removed `"WoW is running - background checks
  paused"` line - reuse the position (a muted row under the main
  headline/clause), rename the CSS hook from `freshness-game-note` to
  `freshness-reload-note` (ui\style.css:1122) so it does not read as a
  leftover of the old "paused" behavior.
- **When:** `Store.state.gameRunning` is true (the game is STILL running
  right now - if the player already closed WoW, the note is moot, since
  the addon will simply load fresh at their next login with no reload
  needed) AND `Store.state.lastRun && Store.state.lastRun.reloadNeeded`
  is true for the active flavour.
- **Exact copy:** `"WoW will use it once you type /reload in your chat
  window, or log out and back in."` (same canonical clause, standalone
  this time since there is no summary line to append to here).
- **How long / dismissal:** not time-based - it is a status line, not a
  toast. It disappears automatically the moment either condition above
  stops holding: the game closes (next `/api/state` poll flips
  `gameRunning` false), or a newer job completes for this flavour and
  overwrites `lastRun` with a fresh (possibly `reloadNeeded:false`) one.
  No manual dismiss control.

### 3.3 Tray balloon (background cycle completion)

- **Where:** the existing Windows tray balloon
  (`ShowBalloonText`/`_icon.ShowBalloonTip`, host\FurphyHost.cs:6966-6997).
- **When:** `status == "done_updated"` from a just-completed background
  cycle (never `"done_failed"` - nothing was actually installed) AND a
  FRESH `WowDetector.IsRunning(_options.WowFakeProcessName)` check at the
  moment the balloon is about to show returns true (not the check `RunCycle`
  made at the very start - a sync can take minutes, during which WoW could
  have been launched or closed).
- **Exact copy:** append the canonical clause to the existing joined
  addon-name text, e.g. `"AddonA, AddonB - WoW will use it once you type
  /reload in your chat window, or log out and back in."`
- **How long / dismissal:** unchanged 8000ms `ShowBalloonTip` duration and
  "Furphy" title. Windows' own balloon dismiss (click or timeout) - no new
  UI.

### 3.4 Removal of the game banner and disabled states

"The game banner" in this codebase IS the Freshness "background checks
paused" note (repurposed above, not just deleted) and the Wago
`#browse-gameactive` blocked state (deleted, section 2). "Disabled
controls" are the Wago grid being hidden during a live-fetch sort while
`gameActive:true`, and the self-update Check now/Install now buttons'
`gameRunning`-driven `disabled`/title. All three are covered by the
removals in section 2 - nothing else in the SPA disables itself based on
`Store.state.gameRunning` (confirmed: every other `isBusy()`-based disable
in the app is keyed on an in-flight JOB, never on game state).

### 3.5 Settings copy

The three index.html tooltip rewrites (1116, 1124, 1156) are in the
inventory table above - reproduced here as the literal strings a docs/SPA
fixer should ship, unchanged from that table.

### 3.6 RECOMMENDED EXTENSION: tray tooltip and Settings status line

Sections 3.1-3.3 cover the toast, the SPA's persistent Freshness note, and
the tray balloon - the three surfaces Eric's brief literally asks for
("the app tells the user plainly"). They do NOT cover two more surfaces
that already show the exact same "Updated N addon(s) at HH:MM: ..." text
and, unlike the 8-second balloon, stay showing it for the rest of the
session:

- The tray icon's own hover tooltip (`SetTooltip("Furphy - " + core)`,
  host\FurphyHost.cs) and its right-click menu status text
  (`menuStatusText = _coreText`).
- The SPA's Settings page "Background updates" status line
  (`#updates-background-status`, fed by `backgroundStatusText` ->
  `computeCoreText`, ui\app.js).

Both are generated by the SAME `"done_updated"` switch case - one in C#
(`ComputeCore`), one in JS (`computeCoreText`) - that the code's own
comments describe as a byte-identical mirror pair, and neither function
takes any WoW-state input today. This is real, if optional, scope: closing
it means threading a new signal through both languages, not just editing a
string. Flagged here as a recommended follow-up rather than folded into
3.1-3.3's requirements, because Eric's literal ask (toast + persistent note
+ balloon-if-shown) is already satisfied without it, and because the tray
tooltip/menu is a much lower-visibility surface than the three above (a
player has to hover the tray icon or open its menu to see it, versus the
toast/note/balloon which all surface unprompted).

**If taken up, the minimal design that fits the existing plumbing:**

- Add `private bool _reloadNeeded = false;` alongside `TrayForm`'s other
  `_status`/`_coreText`/etc. fields (host\FurphyHost.cs, near line 5174).
- `ComputeCore`'s `"done_updated"` case only fires from ONE call site
  today (the `CompleteMultiFlavourCycle`-adjacent status update around
  line 6470 - the other four `ComputeCore` calls pass `"idle"`,
  `"checking"`, or `"updating"`/`"finishing"`, never `"done_updated"`), so
  only that one site needs to compute the value: reuse the SAME fresh
  `WowDetector.IsRunning(...)` check section 3.3 already specifies for
  `ShowBalloon` (compute it once, right before both the `ComputeCore` call
  and the `ShowBalloon` call that follow it a few lines later - do not
  check `WowDetector` twice for one cycle completion).
- Add a `reloadNeeded` bool parameter to `ComputeCore`, used only in the
  `"done_updated"` case to append the canonical clause (section 3) to the
  returned string, exactly like the balloon append in 3.3.
- Add `snapshot["reloadNeeded"] = _reloadNeeded;` to `WriteStateFile`'s
  `Dictionary<string, object> snapshot` (host\FurphyHost.cs, ~line 7050),
  alongside `status`/`updated`/`updatedNames`/etc., so it round-trips
  through tray-state.json the same way every other `_coreText` input does.
- Mirror the same parameter/append into ui\app.js's `computeCoreText`,
  reading it from `state.reloadNeeded` (the `trayStatus.state` object
  `backgroundStatusText` already passes in) - same "must agree" pairing
  the code's own comments already require for this function.
- This is a THIRD, independent read of "was WoW running," alongside
  `job.gameRunningAtStart` (section 4.1, per-job) and the ShowBalloon
  fresh-check (section 3.3, per-balloon). That is intentional, not
  duplication to clean up: the job-level flag answers "should THIS job's
  own toast/note say it," while this one answers "should the tray's
  ambient status text say it right now" - they can legitimately disagree
  (e.g. a background cycle updates one flavour while WoW is running, the
  player alt-tabs to Furphy and reads the tooltip immediately after) and
  neither should be rederived from the other.

If this extension is NOT taken up this round, section 9's "light touch
while you play" doc rewrites should not claim the tray tooltip or the
Settings status line carries a reload reminder - only that the toast
(3.1), the Freshness "Last run" note (3.2), and the balloon (3.3) do.

---

## 4. Server and CLI changes

### 4.1 The `reloadNeeded` job flag - exact fields, exact predicate

Two new fields, both booleans, both additive (no existing field renamed or
removed):

- **`gameRunningAtStart`** - captured ONCE, at the moment a job is created
  (before its CLI child is spawned, or before a multi-phase job's first
  phase starts). Added to the job object literal in all three job
  constructors:
  - `Start-Job` (addon-server.ps1:2898-2919, single-phase: sync/check/add/
    remove/install/rollback/each `update-all-flavours` fan-out job)
  - `Start-ImportJob` (addon-server.ps1:3106-3163)
  - `Start-SwitchSourceJob` (addon-server.ps1:3719-3775)

  In each literal, add one line: `gameRunningAtStart = (Test-GameRunning)`.
  addon-sync.ps1 itself has zero game-state awareness (confirmed, section
  2) and no way to know WoW's process state - this flag can ONLY be
  captured server-side, at job-creation time, never inside the CLI's own
  JSON output.

- **`reloadNeeded`** - computed, not stored on the job object directly;
  derived in `Get-JobStatusView` (addon-server.ps1:4103-4131) so every
  consumer that already routes through that one function picks it up for
  free: `GET /api/jobs`, `GET /api/jobs/{id}`, `/api/state.job` (via
  `Get-CurrentOrLastJobSummary`), and the persisted `state.json` jobs
  history array (`Save-CheckState` serializes jobs "via Get-JobStatusView").

  **Exact predicate** (add as a new line inside the returned
  `[PSCustomObject]@{...}` in `Get-JobStatusView`):

  ```
  reloadNeeded = [bool]($Job.gameRunningAtStart -and (
      $Job.results | Where-Object {
          $_.Status -eq 'Installed' -or $_.Status -eq 'Updated' -or $_.Status -eq 'Rolled-back'
      } | Select-Object -First 1
  ))
  ```

  Notes for whoever implements this:
  - PowerShell property access is case-insensitive, so `$_.Status` and
    `$_.status` are the same access regardless of which case the CLI's
    -Json output actually used for the key (verified: addon-sync.ps1's
    `resultsRows` entries use PascalCase `Status`; this predicate is safe
    either way since it runs in PowerShell, not JavaScript).
  - The three-value set `{Installed, Updated, Rolled-back}` is
    DELIBERATE and narrower than the four-value set
    `{Updated, Installed, Pinned, Rolled-back}` used elsewhere in this same
    file (Apply-JobCompletionSideEffects's `updateAvailable` cleanup,
    addon-server.ps1:3556) - that other list answers a different question
    ("should this stop showing an update-available badge"), where `Pinned`
    legitimately belongs because pinning an already-installed version
    clears the badge. This predicate answers "did a file on disk actually
    change," where `Pinned`/`Unpinned`/`Ignored`/`Unignored` do NOT belong
    - none of those four touch the AddOns folder at all, so they must
    never trigger the reload notice. Do not copy the other list by
    mistake.
  - `Removed` is likewise deliberately excluded per Eric's literal wording
    ("updated or installed") - see section 7.5 for the one-line honesty
    note this implies.
  - This predicate needs no per-`kind` allowlist (no need to special-case
    `sync`/`add`/`install`/`update-all-flavours`/`import`/`switch-source`):
    a `check`-only job's rows are always `Would-update`/`Up-to-date`/
    `Failed`/`Skipped`, never `Installed`/`Updated`/`Rolled-back`, so it
    naturally evaluates to `false` without being named. Confirmed by
    reading every `Status = ...` literal in addon-sync.ps1 (full set:
    `Installed, Updated, Rolled-back, Removed, Failed, Ignored, Pinned,
    Skipped, Unignored, Unpinned, Up-to-date, Would-update`).

### 4.2 State fold-in (surviving the 20-job history window)

`Apply-JobCompletionSideEffects`'s `$Script:LastRunByFlavour[$flavor] = ...`
literal (addon-server.ps1:3576-3580) gets the same field, sourced from the
job that just completed:

```
$Script:LastRunByFlavour[$flavor] = [PSCustomObject]@{
    timestamp    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    summary      = ($summaryParts -join '  ')
    rows         = $rows.ToArray()
    reloadNeeded = [bool]($Job.gameRunningAtStart -and (
        $rows | Where-Object { $_.Status -eq 'Installed' -or $_.Status -eq 'Updated' -or $_.Status -eq 'Rolled-back' } | Select-Object -First 1
    ))
}
```

This is what `/api/state.lastRun` (`Handle-State`, `lastRun = (Get-
FlavourLastRun -Flavor $flavor)`, addon-server.ps1:~7193) reports, and what
the SPA's `Store.state.lastRun.reloadNeeded` (section 3.2) reads - a single
slot that outlives the rolling 20-entry job history in `state.json`, so the
reminder does not vanish just because a few more (unrelated) jobs ran
later in the same session.

### 4.3 `gameRunning` field on ping/state - stays, informational only

No change to `Handle-Ping` (addon-server.ps1:6957-6968) or `Handle-State`'s
own `gameRunning = (Test-GameRunning)` line. It still drives the SPA's
`data-game-active` CSS attribute and is the source `Store.state.gameRunning`
reads on every poll - both of which sections 3.1-3.2's gating logic depend
on. It does not, itself, refuse anything server-side any more.

### 4.4 Maintenance tick and idle-exit - exact before/after

**`Invoke-MaintenanceTick`** (addon-server.ps1:5597-5636):

Before:
```
function Invoke-MaintenanceTick {
    param([bool]$GameRunning)
    try {
        if ($GameRunning) { return }
        if (((Get-Date) - $Script:LastMaintenanceAttemptAt).TotalMinutes -lt $Script:MaintenanceIntervalMinutes) { return }
        if (Test-MaintenanceChildRunning) { return }
        ...
```

After:
```
function Invoke-MaintenanceTick {
    try {
        if (((Get-Date) - $Script:LastMaintenanceAttemptAt).TotalMinutes -lt $Script:MaintenanceIntervalMinutes) { return }
        if (Test-MaintenanceChildRunning) { return }
        ...
```

Also rewrite the function's own doc comment (currently says "-GameRunning
is $false (never while WoW is running...)" as one of the three spawn
conditions) to drop that bullet - only the interval and
`Test-MaintenanceChildRunning` gate the spawn now.

Caller site (addon-server.ps1:~10594): change
`Invoke-MaintenanceTick -GameRunning $gameRunningNow` to plain
`Invoke-MaintenanceTick` (no arguments). `$gameRunningNow` itself is NOT
removed - it is still used two lines above for the `$waitMs = 15000`
widening (section 1.2), so the variable stays; only this one call site
drops the now-nonexistent parameter.

**Idle-exit window** (addon-server.ps1:10018-10032 and 10568-10598):

Before (setup):
```
$Script:IdleMinutesNormal = $IdleMinutes
$Script:IdleMinutesGameRunning = 5
```
After:
```
$Script:IdleMinutesNormal = $IdleMinutes
```
(plus the doc-comment rewrite from section 1.3/2).

Before (loop body):
```
$gameRunningNow = Test-GameRunning
$waitMs = 5000
$idleLimit = $Script:IdleMinutesNormal
if ($gameRunningNow) {
    $waitMs = 15000
    $idleLimit = $Script:IdleMinutesGameRunning
}
```
After:
```
$gameRunningNow = Test-GameRunning
$waitMs = 5000
$idleLimit = $Script:IdleMinutesNormal
if ($gameRunningNow) {
    $waitMs = 15000
}
```

`$idleLimit` is now always `$Script:IdleMinutesNormal` (the caller's real
`-IdleMinutes`, default 20) regardless of game state.

### 4.5 addon-sync.ps1

No change required for policy compliance (section 2). The one RECOMMENDED
addition (a 3-attempt, ~150ms-apart retry around the per-folder
`Remove-Item`+`Move-Item` swap in `Install-AddonPackage`) is a resilience
improvement, not a policy requirement - see section 7.4 for the reasoning
and section 10 for which work package owns it.

---

## 5. Host changes

- **`RunCycle`** (host\FurphyHost.cs:5814-5828): remove the
  `WowDetector.IsRunning(...)` check and its `CompleteCycleSkippedWow()`
  call entirely. The cycle always proceeds to `SetCheckingStarting()` and
  the ping/job-post flow, exactly as it already does when WoW is not
  running today.
- **Result/status values removed:** `waiting_game` (status) and
  `skipped_wow_running` (lastResult) can no longer occur anywhere. Remove
  `CompleteCycleSkippedWow` (host\FurphyHost.cs:6422-6437) and its
  `ComputeCore` case (6638-6639) together, in the same change as the
  matching ui\app.js removals (section 2) - these three copies are
  maintained as a "must agree" mirror by the code's own comments.
- **`RunAppUpdateStep`** (host\FurphyHost.cs:6042-6045): remove the
  `WowDetector.IsRunning(...)` early return. The status GET, the
  `AnnounceInstalledIfNew` balloon, and the silent-install POST all run
  regardless of WoW state now; the install POST's own two remaining
  preconditions (`state=="ready"`, `WindowOpen`) are untouched, and the
  server's own job-running 409 (which this caller already tolerates,
  logging and returning on non-200) is the other surviving gate.
- **Balloon copy:** `ShowBalloon` (host\FurphyHost.cs:6966-6979) gets the
  reload-notice append for `done_updated` + a fresh `WowDetector.IsRunning`
  check, per section 3.3. This is the ONLY place `WowDetector.IsRunning`
  is called with any bearing on functional behavior after this round - and
  even here it only decides whether to append a sentence to a balloon that
  is showing regardless, never whether the balloon (or the cycle) happens.
- **What `WowDetector` is still used for** after this round:
  1. `MainForm`'s 30s poll pushing `{type:"game", running}` to the SPA
     (host\FurphyHost.cs:2487-2520) - feeds the surviving CSS decorative
     gate (`data-game-active`) and `Store.state.gameRunning`.
  2. The fresh check inside `ShowBalloon` for the reload-notice sentence
     (above) - text only, never a gate on whether anything runs.
  3. Nothing else. It no longer gates `RunCycle`, `RunAppUpdateStep`, or
     any HTTP call the host makes.
- **Unchanged (1.2):** `EnterBackgroundMode`/`ExitBackgroundMode`
  (2214-2260), `TrayForm`'s `ApplyLowPriority` (5219-5224) - both keyed on
  window focus/minimize or on being the tray process, never on
  `WowDetector`.

---

## 6. Self-update interaction

Exact edits to APP-UPDATE-SPEC.md's fixed decisions and scheduling
language, so check/download run while the game runs and only the silent
install keeps its (now WoW-independent) preconditions:

| APP-UPDATE-SPEC.md line(s) | Current | New |
|---|---|---|
| 22-25 | `"Safe" means: never while WoW is running, never while an addon job is running, and (for the automatic/silent path only) never while any Furphy window is open.` | `"Safe" means: never while an addon job is running, and (for the automatic/silent path only) never while any Furphy window is open.` |
| 56-57 | Fixed decision: "No network activity while a WoW client is running (existing rule, reused verbatim via Test-GameRunning)." | Remove this fixed decision entirely. |
| 120 | Settings tooltip: "...it installs on its own the next time no Furphy window is open - and never while WoW is running. Turn this off..." | "...it installs on its own the next time no Furphy window is open. Turn this off..." (matches the ui\index.html:1156 rewrite in section 2) |
| 165-166 | `#btn-app-update-check`: "Disabled with title=\"WoW is running\" when Store.state.gameRunning is true" | Remove this disable condition. Check now is never disabled for game state. |
| 171-172 | `#btn-app-update-install`: "Disabled with title=... or title=\"WoW is running\" when gameRunning is true." | Drop the gameRunning clause; keep only the job-running disable/title. |
| 438 | `deferredReason is null \| "game-running" \| "job-running"` | `deferredReason is null \| "job-running"` |
| 456-458 | `If Test-GameRunning: 200 { ok: true, skipped: "game running" } - NEVER a hard error...` | Remove this branch entirely - the check actually spawns/runs even while GameRunning is true. |
| 492 | `409 { error: "WoW is running" } if Test-GameRunning - a check neither Handle-Uninstall nor Handle-Shutdown currently makes...` | Remove this bullet entirely - install no longer gates on GameRunning. |
| 520-522 | `Error codes summary: 200 (ok, or a soft-skip like "game running" on check)... 409 (job running / WoW running)...` | Drop the "game running" soft-skip mention; 409 becomes just "(job running)". |
| 566 | `Hourly maintenance child: ... gated on !GameRunning and Test-MaintenanceChildRunning.` | `Hourly maintenance child: ... gated on Test-MaintenanceChildRunning and the interval.` (drop `!GameRunning`) |
| 599-604 | Whole "Game mode: enforced twice..." section (client button-disable + server-side Test-GameRunning on both routes + the hourly check never running while GameRunning) | Remove this whole section - neither client nor server gates check/install/maintenance on GameRunning any more. |
| 1051 | Failure-modes row: "Install requested while WoW is running \| 409; state stays \"ready\" \| ...title \"WoW is running\"..." | Remove this table row entirely - this failure mode no longer exists. |

**Scheduling, restated plainly:** the hourly `-MaintenanceOnly` child
(which folds in `Invoke-AppUpdateMaintenance`) now spawns on its normal
`$Script:MaintenanceIntervalMinutes` cadence regardless of game state
(section 4.4); a manual "Check now" click (`POST /api/app-update/check`)
always spawns/runs (section 2, `Handle-AppUpdateCheck`); download/verify/
stage (`Invoke-AppUpdateMaintenanceCore`) already had no gate. Only
`POST /api/app-update/install`'s actual binary-replacement step keeps
preconditions, and those preconditions are now exactly two: no addon job
running (server-enforced 409, unchanged) and, for the fully-automatic/
silent path only, no Furphy window open (host-enforced via
`status.WindowOpen`, unchanged, out of this lens). An explicit user click
on "Install now" has a window open by definition and was never meant to be
blocked by that second rule.

---

## 7. Risks and honesty

### 7.1 What WoW actually holds open

WoW reads addon `.toc`/Lua/XML files ONCE, at login or on `/reload`, then
keeps everything in its own in-memory Lua VM - it does not hold a live file
handle open on addon files during normal play, and it never hot-reloads a
mid-session on-disk change. Swapping files on disk while WoW is running is
therefore very unlikely to hit an OS-level file lock from WoW itself
(unlike a running `.exe`); the existing per-folder try/catch and
throw-on-any-failed-swap safety net in `Install-AddonPackage`
(addon-sync.ps1, ~1183-1304) was already the right defense-in-depth before
this policy change - no new WoW-specific locking logic is needed.

### 7.2 What a half-written .toc means until /reload

`Install-AddonPackage` extracts into a STAGING directory first
(~1207-1224), then swaps each top-level folder into place with a single
`Move-Item` (~1266) - staging lives on the same volume/flavour tree as the
AddOns destination, so the swap is an effectively-atomic same-volume
rename. There is no window where a `.toc` is literally half-written by
Furphy's own process. The real "half-written" state a player can observe
is semantic, not physical: the FILES change the instant the swap
completes, but WoW's IN-MEMORY code/UI stays on the OLD version until
`/reload` or a relog - disk and memory can legitimately disagree for an
arbitrary length of time mid-session. That gap is exactly why sections 3.1-
3.3's reload/relog messaging exists - it is a "the update hasn't taken
effect in-game yet" awareness fix, not a data-safety fix.

### 7.3 SavedVariables in WTF - untouched

Confirmed by grep: addon-sync.ps1, addon-server.ps1, and install.ps1
contain zero references to `WTF` or `SavedVariables` anywhere. Furphy only
ever touches the AddOns folder tree; a player's saved settings/data
(`WTF\Account\<name>\SavedVariables\*.lua`, written by WoW itself only at
logout/reload) are completely untouched by an addon update, whether it
happens mid-play or not.

### 7.4 Multi-folder addons and the retry-on-lock recommendation

An addon package spanning multiple top-level folders swaps them one at a
time (`foreach ($folderName in $candidateFolders)`, ~1258-1276), not as one
atomic unit. Since WoW never re-reads these files mid-session anyway (7.1),
this is only a real risk if a `/reload` races the exact instant of a
multi-folder swap - astronomically unlikely, noted here for completeness/
honesty rather than as something to fix.

The more relevant new risk under this policy is NOT WoW itself, but OTHER
background processes that legitimately touch files under AddOns
occasionally (Windows Search's indexer, a real-time antivirus scanner, a
cloud-sync client if a player keeps their WoW folder inside one) - these
become marginally more likely to collide with a swap now that installs
happen throughout a play session instead of being concentrated in gaps
between sessions. RECOMMENDATION (section 2/4.5): wrap the per-folder
`Remove-Item`+`Move-Item` pair in a small retry - 3 attempts total, ~150ms
between attempts, scoped to exactly that swap. After 3 failed attempts,
the existing behavior is unchanged: record the folder in `$failedFolders`
and let the whole-package throw stand. This is a cheap, low-risk
resilience addition, not a requirement of Eric's policy - flag it to the
CLI work package as a nice-to-have, not a blocker.

### 7.5 Honesty note: "Removed" is deliberately excluded from the reload notice

Section 4.1's `reloadNeeded` predicate does not fire for a job that only
removed addons, per Eric's literal wording ("updated or installed"). This
is a real, if narrow, honesty gap worth stating outright rather than
silently deciding: removing an addon while it is loaded also leaves WoW's
in-memory state stale until `/reload`/relog (the removed addon keeps
running until then, same mechanism as 7.2). If a later round wants full
coverage, adding `'Removed'` to the predicate's status set is a one-line
change in exactly the two places section 4.1/4.2 name - flagged here, not
done, since it goes beyond what was actually asked for.

---

## 8. Tests

Per-file changes, from the fully re-verified test-inventory pass. "Invert"
means: same setup, flip the assertion from "was blocked/skipped" to "runs
normally."

- **tests\host\Host.Tests.ps1:622-665** - `It 'skips the cycle with
  skipped_wow_running when --wow-fake matches a real running process'`.
  INVERT: same fake-WoW-running setup, assert the cycle runs fully
  (`serverStarted==$true`, `flavourJobs.Count` > 0, `lastResult` never
  `skipped_wow_running`). Worth keeping as its own regression guard
  (distinct from the existing 667+ "runs a real cycle" It) because this one
  deliberately keeps WoW "running" for the whole cycle.
- **tests\perf\Perf.Tests.ps1:178** - Describe title `'Perf: zero impact on
  gameplay (P3 automated layer)'`. RENAME to `'Perf: light touch while you
  play (P3 automated layer)'`.
- **tests\perf\Perf.Tests.ps1:180-292** - `It 'steady state (WoW running,
  minimized window, tray past its first skip)...'`. Re-anchor the wait to
  "past the first COMPLETED cycle" (cycles now run, nothing is skipped).
  Keep the CPU/log-growth tolerances (ServerCpuMaxSec/TrayCpuMaxSec/
  TotalCpuMaxSec/MaxServerLogGrowthBytes) unchanged. Re-word the zero-new-
  TCP and tray-state-byte-identical assertions as "nothing scheduled in
  this particular quiet window between cycles," not "no network while WoW
  runs" - re-verify they still hold once cycles run unconditionally. This
  re-anchoring is a wording/timing change, not just an assertion flip, so
  rename the strings that still describe the removed "skip" concept too:
  the `It` title itself (line ~180, "...tray past its first skip)..." ->
  "...tray past its first completed cycle)..."), the file's own "WHY
  STEADY STATE FIRST" header comment (~lines 28-40, which explains waiting
  out "the one-time first-skip transition" - rewrite to explain waiting
  out the tray's first real (now unconditionally-running) cycle instead),
  and the inline comment right above `Start-Sleep -Seconds
  $Script:SettleWaitSec` (~lines 233-234, "Wait for the tray's one-time
  first-skip transition (~90s) to finish" -> "Wait for the tray's first
  real cycle (~90s) to finish"). `$Script:SettleWaitSec`'s own comment
  (line 66, "first-cycle delay") is already generic enough - no change
  needed there.
- **tests\perf\Perf.Tests.ps1:294-387** - `It 'foreground state...'`. NO
  CHANGE - webview2 GPU/CPU regression guard, unrelated to the skip policy.
- **tests\perf\Perf.Tests.ps1:389-496** - `It 'game stops: normal behaviour
  resumes within 60s...'`. RETIRE/REPURPOSE: `skipped_wow_running` can
  never occur any more, so "resumes once WoW stops" is moot. Replace with
  a test proving a `--tray-selftest` cycle completes normally WHILE the
  fake WoW process is still running (merges naturally with the inverted
  Host.Tests.ps1 assertion above).
- **tests\integration\Server.AppUpdate.Tests.ps1:349-410** - Describe
  `'App-update: install refused while WoW is running'`, asserts 409 +
  `error=='WoW is running'`. INVERT: install succeeds (200) while the fake
  WoW process is running, as long as no addon job is running.
- **tests\integration\Server.WagoBrowse.Tests.ps1:648-693** - `'with a
  fake WoW process running and no prior cache entry, browse returns
  gameActive:true, items:[], and the stub sees zero requests'`. INVERT:
  browse reaches the stub and returns real items; `gameActive` absent/
  false; stub request count > 0.
- **tests\unit\Server.WagoParser.Tests.ps1:241-256** - `'while the game is
  running... returns 200 with an empty result and gameActive:true...'`,
  asserts `CapturedAllowLiveFetch==$false`. INVERT:
  `CapturedAllowLiveFetch` should be `$true` regardless of game state; drop
  the forced-empty/gameActive response.
- **tests\unit\Server.WagoSnapshotCrawl.Tests.ps1:124-139** - `'Test-
  GameRunning at the very top skips the entire crawl...'`. INVERT: crawl
  proceeds normally while GameRunning is true (`WagoCachedCallCount` > 0,
  snapshot file written), matching the unrelated 20h-freshness It just
  above it (stays unchanged).
- **tests\spa\harness.js:912-922** - checks `#browse-gameactive` visible +
  exact "pauses while a WoW client is running" text. INVERT: with
  `?game=1`, the Wago grid renders normally (real/mocked items visible);
  remove or repurpose this assertion.
- **tests\spa\harness.js:2182-2190** - `checkTry("Install now is disabled
  with title \"WoW is running\" while a game is active", ...)`. INVERT:
  Install now stays enabled while `?game=1` is set (no job running); the
  job-running case a few lines below (2192-2203) stays unchanged.
- **tests\unit\Server.GameState.Tests.ps1:27-83** - Test-GameRunning probe/
  cache, `gameRunning` on `/api/ping`. NO CHANGE - detection signal still
  required for decorative gating, priority, and the new reload/relog
  messaging.
- **tests\spa\harness.js:1682-1797** - decorative theme-animation gating +
  `data-game-active` tracking. NO CHANGE - explicitly kept measure.
- **New coverage needed (no existing test to invert - gaps, not
  regressions):**
  1. `Invoke-MaintenanceTick` still spawns/runs while `Test-GameRunning`
     is true (no test exists today at all for this gate either way -
     grepped for MaintenanceTick/MaintenanceOnly/LastMaintenanceAttemptAt).
  2. `POST /api/app-update/check` actually spawns (not a `skipped:"game
     running"` soft-skip) while GameRunning is true.
  3. `Initialize-CfCatalogueIndex`'s startup refresh and
     `Get-CfEnrichmentNoKey`'s live-fetch both proceed while GameRunning is
     true (neither has a GameRunning test today, in either direction).
  4. The new `job.reloadNeeded` field: true after an Installed/Updated/
     Rolled-back job started while GameRunning was true; false for a
     check-only job, a Removed/Pinned-only job, or any job started while
     GameRunning was false.
  5. The SPA toast/note copy (section 3.1-3.2) and the tray balloon append
     (section 3.3) - net-new feature surface, zero existing coverage
     (grepped every test file and every *.md for "/reload"/"relog" -
     nothing found beyond unrelated browser-reload hits).
  6. `addon-sync.ps1`'s existing locked-folder throw path still exercised
     under the new retry-on-lock addition (7.4) IF Package A takes it -
     see section 10 for the exact coordination rule that makes this
     conditional testable rather than an orphan/missed item. A test
     forcing 1-2 transient failures then a success should pass; a test
     forcing failures past the retry budget should still throw and
     populate `$failedFolders` exactly as today.
  7. A server-restart round-trip for `gameRunningAtStart`/`reloadNeeded`
     (closes the `Load-CheckState` gap added to section 2/4.1): start a
     job with `-WowFakeProcessName` set so it completes with an
     Installed/Updated row while GameRunning is true (`reloadNeeded` true
     via `Get-JobStatusView`), restart the server process against the same
     `state.json`, and assert `GET /api/jobs/{id}` still reports
     `reloadNeeded: true` after the reload - not just before it. Pair with
     a second case: a job persisted by CODE FROM BEFORE THIS ROUND SHIPPED
     (a `state.json` fixture with no `gameRunningAtStart` key at all on
     that job) reloads with `reloadNeeded: false`, not an error.
  8. IF section 3.6's tray-tooltip/Settings-status-line extension is taken
     up: the tray tooltip/menu text and `#updates-background-status`
     both carry the reload clause after a `done_updated` cycle completes
     while GameRunning is true, and neither does when it completes while
     GameRunning is false - mirrors item 5 above but for the two surfaces
     3.1-3.3 do not cover. Conditional on 3.6 being implemented, same as
     item 6 above is conditional on 7.4.

---

## 9. Docs

Per-file replacement sentences. All of these were re-verified against the
live file content at write time.

**README.md**
- Line 56: drop `"never while WoW is running,"` from the safe-install
  criteria sentence; keep "never in the middle of an addon update" and
  "for the fully automatic path - never while a Furphy window is open."
- Line 64 (Performance section): replace the whole paragraph. New text:
  "Furphy takes a light touch while you play: it doesn't pretend WoW isn't
  running, it just keeps the overhead down. While a supported WoW client
  is running, decorative theme animations pause, the app (and the
  background updater) run at a lower OS scheduling priority, and the
  CurseForge browsing pane suspends itself whenever the window isn't in
  the foreground. Everything else - checking for updates, updating or
  installing addons, browsing Wago and CurseForge - keeps working exactly
  like it does when WoW is closed. `tests\perf\Perf.Tests.ps1` (part of a
  full `tests\run-all.ps1` run) asserts the CPU/priority side of this
  automatically against a real game-running simulation on every test
  pass, not just by hand."
- Line 79: drop `"- it never touches anything while WoW is running."` -
  background updates now run while WoW is running.

**README.txt**
- Lines 31-32: same fix as README.md:56 - drop the WoW-running clause.
- Lines 46-48: drop the sentence "...it pauses automatically while WoW is
  actually running." entirely - the background service now keeps working
  while WoW runs.

**APP-UPDATE-SPEC.md** - see the full table in section 6.

**SPEC.md**
- Line 589: drop "skipping while WoW is running" from the tray-cycle
  description - the tray cycle now runs regardless of WoW state.
- Line 597, 731: remove `skipped_wow_running` from the documented
  `lastResult` enum (both occurrences).
- Line 608: remove the `"Waiting - WoW is running"` status-line mapping
  for `skipped_wow_running` entirely.
- Line 664: add a 2026-09-08 addendum: process-priority/decorative gating
  stays required; the network-skip-while-playing gating does not - the
  background service now updates addons while WoW runs.
- Lines 672-675: remove the whole "Server-side network gates while
  gameRunning" subsection - none of these gates exist any more.
- Line 677: drop the shortened-idle-exit special case from the prose;
  keep the 15s `WaitOne` widening description.
- Line 683: invert the closing sentence - addons DO update while WoW is
  running now, with the reload/relog notice (section 3) covering the
  awareness gap the old sentence used to paper over with a hard block.
- Lines 687-689: remove `CompleteCycleSkippedWow`'s "first skip
  transition" dedup description and the SPA's 30-min auto-check-timer
  no-op description; keep the 30s `WowDetector` push and the foreground-
  based background-mode machinery (unrelated, stays).
- Line 691: rewrite the P3 test-layer narrative to match the reworked
  Perf.Tests.ps1 (section 8) - no more "skip" framing.
- Line 707: remove the "Game-mode gate, a real fix, not new behavior"
  paragraph - Wago browsing/search works fully while WoW runs, matching
  `Handle-WagoSearch`'s original (pre-"fix") ungated behavior.
- Line 709: drop the `Test-GameRunning` gate description from the
  growth-snapshot crawl paragraph; keep the per-`game_version` 20-hour
  freshness gate description.
- Line 711: remove the "new game-running state... replaces the results
  area" sentence - results render normally instead.
- Line 727: remove `waiting_game` from the status enum list.
- Line 752: remove the `waiting_game` per-status table row entirely.
- Line 760: remove `waiting_game` from the "Normal" icon-variant list.

**UX-SPEC.md**
- Line 253 ("Game state" paragraph): rewrite - Wago browsing now works
  fully while a WoW client is running (real results, real network calls,
  same as when WoW is closed); remove the quoted blocked-state banner
  copy entirely.
- Line 284: drop "and it pauses while WoW is running" and the
  "skip-while-WoW-runs" tooltip-explanation clause - background updates
  continue while WoW runs.
- Line 533 (Round 35 acceptance checklist item): invert - a user who
  opens Get New Addons > Wago while a WoW client is running sees real,
  live Wago results, never a blocked-state message.

**SETTINGS-SPEC.md**
- Lines 86-88: drop the sentence "It pauses while WoW is running." from
  the background-updates tooltip.
- Lines 473-476: drop "and never while WoW is running" from the
  appUpdateAutoInstall tooltip.

**TESTING.md**
- Lines 92-98: reword "so the skip path can be proven without the real
  game installed" - there is no more skip path; reword to "so cycle
  behavior can be exercised deterministically without a real game
  installed."
- Line 309: replace "install-refused-while-WoW-running" with
  "install-succeeds-while-WoW-running" in the coverage list (or drop the
  phrase once the Describe is inverted, per section 8).
- Lines 320-323: drop "game-running"/"WoW-running" references - only the
  job-running gate remains for `Handle-AppUpdateInstall`'s precondition
  ordering note.
- Line 399: update the quoted "zero impact on gameplay" description to
  "light touch while you play," matching the reworked steady-state test.

**WAGO-BROWSE-SPEC.md**
- Lines 72-76 and 237-243: remove the "Game-running blocked state" design
  decision and its banner copy entirely - Wago browsing works fully while
  WoW runs.
- Lines 499-560 (section 3.5, "CORRECTION to the original data design"):
  invert the whole section. `Handle-WagoSearch`'s original ungated
  behavior was the correct one; `Handle-WagoBrowse` should match IT by
  dropping its gate, not the other way around.
- Lines 658-693: remove the `Test-GameRunning` skip-the-crawl gate
  (including the per-page re-check and the "aborted mid-run: WoW started"
  log line) from the Gates list; keep the per-`game_version` 20-hour
  freshness gate (gate 2), unrelated to WoW.
- Line 713: drop the "or the game-running abort fired" clause from the
  PARTIAL-results rule.
- Lines 1063-1066, 1100: update the SPA-4 spec pointer and the
  response-shape list once `gameActive` is dropped from the response.
- Lines 1178-1186, 1188-1195: rewrite the "GAME-MODE GATE" and "SNAPSHOT
  GAME-MODE GATE" test-plan descriptions to describe the new, un-gated
  behavior (matches the section 8 test inversions).
- Lines 1240-1241, 1286-1288, 1339: remove the "game-running blocked
  state" mentions from the theme-screenshot/acceptance-checklist lists.

**REMOVAL-SPEC.md** (a still-standing rationale doc, not a changelog entry
- its "KEEP" reasoning is a currently-asserted architectural invariant
that the new policy now contradicts, so it needs correcting, not just
leaving as history)
- Lines 56-58: annotate "superseded 2026-09-08" on the sentence "the
  background service must never update addons while the game is running."
- Lines 60-67: split the KEEP list. KEEP (detection/signal infra):
  `Test-GameRunning`, the known-process-name list, `--wow-fake`/
  `-WowFakeProcessName` hooks, `gameRunning` on ping/state, `WowDetector`'s
  30s push, `Store.state.gameRunning`. NO LONGER KEEP (must be removed per
  this spec): the server-side network gates (catalogue-refresh skip,
  enrichment skip), the tray's skip-while-playing dedup
  (`CompleteCycleSkippedWow`), and the "WoW is running - background checks
  paused" line.
- Line 682: correct the instruction "SPEC.md 670-696 (keep verbatim)" to
  "keep the CPU/priority/decorative-gating parts of SPEC.md 670-696;
  remove the network-skip-while-playing and tray-cycle-skip content per
  the 2026-09-08 policy (this spec)."
- Line 777: correct "game-mode detection (never updating while WoW is
  running) is unchanged" - detection stays; addons now DO update while
  WoW is running.
- Lines 904-906: correct the trailing clause "the background service must
  never update while WoW runs" - it now does; only the detection signal
  itself (`Test-GameRunning`/`WowDetector`/`gameRunning`) is kept verbatim.

**Not flagged (left as history, per the standing CHANGELOG-entries-are-
history rule):** NIGHT-REPORT-2026-09-05.md, OVERNIGHT-REPORT.md, and
ROADMAP.md's "DONE" milestone entries are timestamped records of what a
specific past round measured/shipped, same category as CHANGELOG.md - they
keep their old "zero impact"/"pauses while WoW is running" language as a
historical record, not a living claim. THEMES-SPEC.md:2247 and
SPEC.md:1027 (the AGENT/TEST safety rule "never launch a native
FurphyHost.exe window while a real WoW client may be running on the dev
machine") are unrelated to this app's functional policy - they protect the
build/test process, not the shipped product - and do not need to change.

---

## 10. Work packages

Five packages, disjoint file lists, safe to run in parallel, WITH ONE
NAMED EXCEPTION (the section 7.4 retry, below - Package D's coverage for
it depends on a Package A decision, so treat that one item, and only that
one item, as sequenced rather than parallel).

### Package A - Server + CLI
**Files:** `addon-server.ps1`, `addon-sync.ps1`
**Work:** section 2's addon-server.ps1/addon-sync.ps1 rows (including the
1405-1406 stale-comment fix and the `Load-CheckState` `gameRunningAtStart`
bug fix); section 4 in full (the `reloadNeeded`/`gameRunningAtStart`
fields, the maintenance-tick and idle-exit exact diffs, the
AppUpdateCheck/AppUpdateInstall gate removals, the
WagoBrowse/WagoGrowthSnapshots/CfCatalogueIndex/CfEnrichmentNoKey gate
removals); the RECOMMENDED retry-on-lock addition in addon-sync.ps1
(section 7.4) if time allows - flagged optional, not blocking. **Decide
this one explicitly, one way or the other, before Package D reaches its
own item 6 (section 8):** either implement the retry and say so (e.g. a
one-line comment tag like `# RETRY-ON-LOCK: added` above the swap loop),
or explicitly skip it and say so (`# RETRY-ON-LOCK: skipped, time`) -
either comment is cheap and gives Package D a single grep to check rather
than a guess about whether the optional path landed.

### Package B - Host
**Files:** `host\FurphyHost.cs`
**Work:** section 2's FurphyHost.cs rows (including the two stale
doc-comments at 6006-6021/6025-6032); section 5 in full (RunCycle,
CompleteCycleSkippedWow removal, ComputeCore case removal, RunAppUpdateStep
gate removal, ShowBalloon reload-notice append per section 3.3). IF section
3.6's tooltip/status-line extension is taken up this round (optional - see
3.6), its host-side half (`_reloadNeeded` field, the one `ComputeCore`
call-site change, `WriteStateFile`'s new `snapshot` key) is this package's
work too, coordinated with Package C exactly as the existing ComputeCore
mirror is (next line).

### Package C - SPA
**Files:** `ui\app.js`, `ui\index.html`, `ui\style.css`
**Work:** section 2's ui\* rows; section 3.1-3.5 in full (the toast, the
repurposed Freshness note, the button-disable removals, the auto-check-
timer fix, the mock-branch cleanup, the settings-tooltip copy, the CSS
class rename); the matching `computeCoreText`/`backgroundStatusText` case
removal that must land in the SAME change as Package B's ComputeCore
removal (coordinate on this one - see the mirror-contract note in section
2's app.js table). IF section 3.6 is taken up, its JS-side half
(`computeCoreText` reading `state.reloadNeeded`) is this package's work,
in the SAME change as Package B's `ComputeCore` half - same mirror-contract
coordination as the `waiting_game` case removal just above it.

### Package D - Tests
**Files:** everything under `tests\`
**Work:** section 8 in full - every inversion, the Perf.Tests.ps1 rename/
re-anchor/retirement (including the title and header-comment string
renames, not just the assertion flips), and the eight new-coverage items
listed as gaps. Item 6 (the retry-on-lock test) is the one item in this
package that is NOT independent of another package's work: before writing
it, check for Package A's `# RETRY-ON-LOCK:` comment tag (above) - `added`
means write the test, `skipped` (or the tag never lands - re-check
addon-sync.ps1's actual `Install-AddonPackage` swap loop directly if the
tag itself is missing) means skip item 6 outright rather than guessing.
Items 7 and 8 are new (this synthesis pass) - item 7 is a firm requirement
(it closes a real bug, section 2/4.1), item 8 is conditional on 3.6 the
same way item 6 is conditional on 7.4.

### Package E - Docs
**Files:** `README.md`, `README.txt`, `SPEC.md`, `UX-SPEC.md`,
`SETTINGS-SPEC.md`, `TESTING.md`, `WAGO-BROWSE-SPEC.md`,
`REMOVAL-SPEC.md`, `APP-UPDATE-SPEC.md`
**Work:** section 9 in full, including the section 6 table for
APP-UPDATE-SPEC.md specifically.

### Live-safety and no-window rules (every package)

- **Eric may be playing WoW right now.** Nothing in any package may
  require stopping a real game to test - that is the entire point of this
  round. Use `-WowFakeProcessName`/`--wow-fake` (a renamed `timeout.exe` or
  similar, matched by name, never a literal `Wow.exe` rename) for every
  test that needs a "WoW is running" condition, exactly as the existing
  test suite already does throughout.
- **Never launch `FurphyHost.exe` as a visible window** from any fixer or
  test process. Host-side verification is headless only:
  `FurphyHost.exe --port <n> --tray-selftest <markerPath> [--wow-fake
  <name>]` (one full cycle, writes a JSON marker, exits - no window) or
  `--tray` run fully backgrounded under test harness control. This applies
  to manual spot-checks during implementation too, not just the automated
  test layer - do not open the real app window to "just check" something
  while this round is in flight.
- **Never run `tests\run-all.ps1`** during this round (per the task's own
  scope note) - it is reserved for whoever owns the full-gate pass
  afterward; per `gates-are-manual-now`, Eric runs full gates himself and
  none has run automatically since 2026-09-06.
- **Never touch the live install under Program Files.** All work happens
  in this build root only.
- **Scratch ports: 47950-47969.** Every test server / fake process this
  round's fixers start must bind inside this range - it is reserved
  specifically for this round's concurrent work so it cannot collide with
  the other self-update round's own scratch ports or with a real resident
  `addon-server.ps1`/tray already running on the machine's normal port.
- **This document (GAME-MODE-SPEC.md) is the contract.** If an
  implementing package finds a line number has drifted (the concurrent
  self-update round edits these same files), re-locate the site by the
  function/variable name given here, apply the change, and note the
  drift - do not skip a finding because its cited line number no longer
  matches exactly.

---

## 11. Critic disposition (second-pass synthesis note)

A second, independent read-only pass re-verified this document against the
build root and raised seven items. All seven were re-checked directly
against the code by this synthesis pass and confirmed accurate - none
rejected. Folded in as follows:

1. **addon-server.ps1:1405-1406 stale "Safe" comment, missing from section
   2's inventory** - confirmed verbatim at those exact lines. Added as a
   new row in section 2's addon-server.ps1 table.
2. **host\FurphyHost.cs:~6006-6032 stale rationale comments near
   RunCycle/RunAppUpdateStep, missing from section 2** - confirmed
   verbatim (and a second stale clause at line 6032 adjacent to the one
   the critic cited, folded into the same fix). Added as a new row in
   section 2's FurphyHost.cs table.
3. **`Load-CheckState` never reconstructs `gameRunningAtStart`, defeating
   `reloadNeeded` for any job that survives a server restart** - confirmed
   by reading the reconstruction loop directly; the field list matches the
   critic's citation exactly and `gameRunningAtStart` is absent. This is a
   real bug in a field this same document introduces (section 4.1), not a
   pre-existing one. Added as a new row in section 2's addon-server.ps1
   table plus new-coverage item 7 in section 8.
4. **Tray tooltip/menu and the SPA's Settings status line never get the
   reload signal at all** - confirmed: both are driven by the
   `ComputeCore`/`computeCoreText` mirror pair, neither of which sections
   3.1-3.3 touch, and neither takes a WoW-state parameter today. Accepted
   as valid, but scoped as a RECOMMENDED extension (new section 3.6) rather
   than folded into 3.1-3.3's requirements: Eric's literal ask (toast +
   persistent note + balloon-if-shown) is satisfied without it, and the
   critic's own writeup already frames this as "real design work" beyond
   what was asked. Section 3.6 gives the concrete design if a later round
   wants to close it; section 2 gets two new cross-reference rows; section
   8 gets conditional new-coverage item 8; section 10 gives Packages B/C
   the same mirror-contract coordination note already used for the
   `waiting_game` case removal.
5. **`/reload` is chat-window jargon a below-average-tech-savvy player may
   not know** - accepted outright. The canonical clause (section 3) is
   rewritten from `" - WoW will use it after a /reload or a relog."` to
   `" - WoW will use it once you type /reload in your chat window, or log
   out and back in."`, propagated verbatim to every occurrence (sections
   3.1, 3.2, 3.3, and the matching section 2 table rows for ShowBalloon,
   Components.Freshness.render, and pollJob).
6. **Section 10's "disjoint, safe to run in parallel" claim doesn't hold
   for the section 7.4 retry / section 8 item 6 pair** - confirmed: Package
   A's retry is explicitly optional and Package D's matching test is
   explicitly conditioned on it, with no stated way for D to know which way
   A went. The critic offered two resolutions ("make the retry a firm
   requirement, or drop the contingent test"); this pass took a third,
   less disruptive one that preserves the retry's genuinely-optional status
   (section 7.4's reasoning for that holds up) while closing the
   coordination gap: Package A tags its decision with a one-line grep-able
   comment (`# RETRY-ON-LOCK: added` or `# RETRY-ON-LOCK: skipped, ...`),
   and Package D checks for that tag before writing (or skipping) its
   test. Section 10 rewritten for both packages; this one item is called
   out by name as the exception to "safe to run in parallel."
7. **Perf.Tests.ps1's steady-state `It` title and settle-wait comments
   still describe the removed "skip" concept** - confirmed verbatim at the
   cited lines, plus a third instance the critic's writeup didn't cite (the
   file's own ~28-40 "WHY STEADY STATE FIRST" header comment, which
   explains waiting out a "first-skip transition" that no longer exists).
   All three folded into section 8's existing Perf.Tests.ps1 row alongside
   the already-planned re-anchor, rather than left as a residual naming
   mismatch.
