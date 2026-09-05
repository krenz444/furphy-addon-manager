# Furphy performance baseline (P0)

Eric's rule, verbatim: "do a full performance tuning / pass, absolutely
nothing / everything must have zero impact on gameplay". This is the
**measurement step only** - the bench (`tests\perf\Measure-Furphy.ps1`) and
one baseline run of the current (v1.8.0) code in every state a future
optimization pass needs a "before" number for. No production file changed.

All runs against a real `addon-server.ps1` on port 47899 (never 47831),
rooted at a scratch app folder (`tests\.tmp\perf-app-...`, a copy of
addon-sync.ps1/addon-server.ps1/ui/host\bin) pointed at a scratch copy of
`fixtures\wowroot` via `-WowRoot`. Retail's `addons.json` was seeded with
two real, known-good CurseForge addons (BigWigs 2382, LittleWigs 4383 -
both confirmed installable in earlier real runs) so states F/G have real
network/disk work to do, not an empty addon list. The real game was never
launched - "WoW running" is simulated per the task brief: `timeout.exe`
copied to `Wow.exe` and run hidden (`Wow.exe /t 600 /nobreak`, no stdin
redirection - see "Gotcha" below), which `WowDetector.IsRunning` matches by
process name exactly like the real client.

## Results

| State | What | Duration | Processes resident | Total CPU (s) | Peak WS (any one process) | IO read / write | New TCP conns | Server requests |
|---|---|---|---|---|---|---|---|---|
| A | Server running, no window, no WoW | 60s | 1 (server) | 0.062 | 433 MB | 0 / 0 | 0 | 0 |
| B | Server running, no window, **fake WoW running** | 60s | 1 (server) | 0.172 | 267 MB | 0 / 0 | 0 | 0 |
| C | Window open on Get new addons \> CurseForge, no WoW | 60s | 13 (host + server + 11 webview2) | 3.548 | 241 MB | 6.4 / 8.6 MB | 0 | 12 |
| D | Window open on My Addons, **fake WoW running** | 60s | 9 (host + server + 7 webview2) | 1.548 | 215 MB | 2.6 / 0.3 MB | 0 | 12 |
| E | `--tray` (backgroundUpdates on, interval 30), **fake WoW running**, 3 min | 180s | 1 (host-tray only) | 0.000 | 34 MB | 0.004 / 0.0003 MB | 0 | 0 |
| F | Real sync job running (force reinstall, 2 addons), no WoW | 45s | 2 (server + sync CLI child) | 0.797 | 320 MB (server) / 147 MB (CLI) | 8.6 / 14.7 MB | 0 | 2 |
| G | Launch chain: `addon-sync.ps1 -Launcher -Flavor retail`, no WoW | 1.38s wall clock | 1 (CLI, one sample only - see note) | ~0 (see note) | 14 MB | 0 / 0 (see note) | 0 | n/a |

Full per-process breakdown for every state is in the sibling
`<label>-<stamp>.json`/`.md` files this same folder holds - this table is
the roll-up.

### State G's numbers are not meaningful (measurement artifact, not a finding)

The whole launch-chain CLI call (both addons already installed, so a real
network version check with no download) completed in **1.38 seconds wall
clock** - faster than even the bench's fastest 2-second sample slice, so
`Measure-Furphy.ps1` only ever caught it once. A CPU/IO **delta** needs at
least two samples; with one, every delta reads as zero even though the
process plainly did real work (two real CurseForge API calls, exit 0, both
"Up-to-date"). The 1.38s wall-clock figure is the only trustworthy number
from this state. **This is a gap in the bench itself, not a claim that the
launcher is free** - see "For the builders" below.

### The network-blocked cap does not exist yet

`addon-sync.ps1` has no `-Proxy`/timeout-override parameter and does not
read `HTTP_PROXY`/`HTTPS_PROXY` - every `Invoke-WebRequest`/
`HttpWebRequest` call (`Invoke-HttpDownloadWithProgress`, the two inline
`Invoke-WebRequest -Uri` call sites) hardcodes `-TimeoutSec 30` with no
override surface. There is no hosts-file-free way to make this script's
own CurseForge calls time out on demand. Per the task brief, this is
reported rather than worked around: **only the happy-path launch chain
(state G above) was measured.** If a fast, deterministic "network
unreachable" cap becomes something the perf pass wants to guarantee (e.g.
"the launcher must never delay WoW's start by more than N seconds even
with no internet"), a `-ConnectTimeoutMs`-style override needs to be added
to `addon-sync.ps1` before that state can be measured at all.

## A genuine gotcha, fixed in the harness (worth recording so it isn't
relearned)

The task brief's own suggested recipe - `Wow.exe /t 600 /nobreak` **with
stdin redirected** - does not keep the fake process alive. `timeout.exe`
detects a non-console stdin (a redirected file, `\\.\NUL`, or a pipe) and
exits immediately (no error surfaced through `$LASTEXITCODE`/`.ExitCode`
in the reproduction here, it just quits within under a second). Confirmed
live: with `-RedirectStandardInput <file>`, `Get-Process -Name Wow`
already returns nothing 3 seconds later; **without** any stdin redirection
(`Start-Process -WindowStyle Hidden`, no `-RedirectStandardInput` at all),
the same `Wow.exe /t 600 /nobreak` stays alive and answers to
`Get-Process -Name Wow` indefinitely. `-WindowStyle Hidden` alone is
sufficient to keep it off-screen - a hidden console still counts as a real
console handle, so `/nobreak`'s stdin check passes. Every `Run-State*.ps1`
driver in this folder uses the no-redirection form. **The first B/D/E
measurements taken with the redirected form were silently measuring "no
WoW at all"** (the fake process had already exited before the tray's first
cycle or before the 60s window even started) - those runs were discarded
and redone; only the corrected files are in this folder.

## For the builders (P1+): what's resident during gameplay, and what it's
still doing

Answering the task's actual question - **which of these must go to zero,
and by how much** - state by state, using the corrected numbers above:

- **State A/B (server alive, no UI) - already effectively free.** ~0.06-
  0.17 CPU-seconds over 60s (~0.1-0.3% of one core) either way, zero IO,
  zero new connections, identical whether the fake WoW is running or not
  - because nothing in `addon-server.ps1`'s own request loop consults
    `WowDetector`/a "WoW running" signal at all; its only per-tick cost is
    the existing 2-second `WaitOne`/idle-timer check (`Write-ServerLog`
    only on state transitions, not every tick). The ~270-430MB working set
    is pure PowerShell-hosting-HttpListener overhead (JSON/enrichment
    caches held in memory) - notably higher than the sub-100MB a
    minimal HttpListener host would need; worth a memory profile in a
    later round if "server left running with the window closed" is meant
    to be cheap to leave resident all the time, not just idle-CPU-cheap.
  - **Nothing to fix here for CPU/network/disk** - the real cost during
    gameplay is state C/D below, i.e. **whether the window/tray are
    allowed to stay open/active while WoW runs at all.**

- **State C/D (native host window open) - the big one.** A WebView2
  window costs **7-12 msedgewebview2.exe child processes** (renderer, GPU,
  network service, storage service, crashpad handler, plus one per
  extra frame) on top of `FurphyHost.exe` itself and the server -
  **1.5-3.5 CPU-seconds over 60s (2.5-6% of a core) and 200-320MB peak
  working set on the busiest single process alone** (likely 700MB-1GB+
  summed across all of them - the per-process JSON in this folder has the
  exact per-PID numbers to add up). Critically: **state D proves the SPA
  keeps polling `/api/state` every ~5 seconds (12 requests in 60s, same
  count as state C with no WoW at all) with WoW already running** -
  neither the SPA's poll loop nor the host window's own presence currently
  check `WowDetector` at all. **This is the actual "zero impact" gap** -
  today, if a player leaves the Furphy window open (minimized or not) and
  starts WoW, none of this stops. A builder's fix needs to either (a) make
  the host itself detect WoW-running and pause the SPA's poll interval /
  suspend the webview, or (b) close/hide the window automatically when WoW
  is detected, or (c) both. Either way, the fix belongs in
  `ui\app.js`'s poll loop and/or `host\FurphyHost.cs`'s `MainForm`, not in
  `addon-server.ps1` (the server itself does no polling of its own; it
  only answers what it's asked - see A/B above).

- **State E (`--tray`, WoW running) - already correctly zero.** Confirmed
  live: `WowDetector.IsRunning` catches the fake WoW process, the cycle
  logs `"[tray] cycle skipped: WoW is running"` and writes
  `tray-state.json`/updates the tooltip - **0.000 measured CPU-seconds,
  no server ever started, no CLI ever spawned, no network** across the
  full 3-minute window (one ~90-second-scheduled check, then a fixed
  10-minute cooldown before the next attempt - not `backgroundIntervalMinutes`
  on the skip path specifically, see `FurphyHost.cs`'s
  `CompleteCycle("skipped_wow_running", ..., DateTime.UtcNow.AddMinutes(10), false)`).
  The only cost is the pre-existing `FurphyHost.exe --tray` process itself
  sitting resident (~34MB working set, effectively 0% CPU between its
  <=60-second settings.json re-read ticks) - **this is the "whatever
  remains resident must be idle at low priority" case**; nothing to fix in
  the skip path itself, but see the priority note below.
  - **No test yet proves the *reverse* transition** - WoW starting up
    exactly while the tray is mid-sync (a real update in flight) - which
    is the actual risk case for "gameplay" (a sync starting a few seconds
    before the player alt-tabs into the loading screen). That race is out
    of this bench's scope but worth a dedicated test in a future round.

- **State F (a real sync job, no WoW) - the actual work, for reference.**
  A real forced re-download+reinstall of 2 addons: **0.797 total
  CPU-seconds, ~23MB read + ~14MB write, done in well under the 45-second
  measurement window** (the CLI child was only resident for ~4 seconds of
  it). This is the baseline "a sync is actually happening" cost a builder
  can compare a real player's larger addon list against - useful as a
  per-addon extrapolation (`~0.4 CPU-s / ~11MB IO per addon`, this
  particular pair), not as a hard number (BigWigs/LittleWigs are
  small/no-media addons; a texture-heavy UI addon set will cost more per
  addon).

- **Process priority - not measured here, worth flagging.** Nothing in
  `addon-sync.ps1`/`addon-server.ps1`/`FurphyHost.cs` currently sets
  `Process.PriorityClass`/`BELOW_NORMAL_PRIORITY_CLASS` on itself or its
  children (confirmed by inspection - no `PriorityClass`/`SetPriority`
  hits in any of the three files). Whatever must stay resident during
  gameplay (today: nothing computed above needs to, once C/D's window/poll
  gap is closed) should still drop to a below-normal/idle priority class
  as a defense in depth measure, per Eric's "low priority" wording -
  a P1+ item, not something this bench measures (CPU-seconds consumed is
  the same whether at normal or idle priority; only *scheduling
  preference under contention* differs, which needs a contention test,
  not an idle one).

## Known limitations of this bench (fix before trusting a very-short
sub-2s process's numbers)

1. **Sub-sample-interval processes read as zero-CPU** (state G, above) -
   a delta needs 2+ samples; anything faster than one `-SampleIntervalSec`
   slice is under-counted. A future round should either drop the interval
   for known-short invocations or capture one extra snapshot at process
   exit (`Process.Exited` event / `WaitForExit` then one final
   `Win32_Process` read) so the LAST sample is the true final cumulative
   value even if the loop's own tick missed it.
2. **New-TCP-connection counting reads 0 everywhere in this baseline**,
   including states (C/D) that plainly did real network work (12 real
   HTTP requests to the local server alone, plus whatever the CurseForge
   pane/API calls made). Two plausible causes, not yet isolated: (a) this
   bench's 8-second warm-up sleep before sampling starts in states C/D
   means most of the pane's own connections were already open before the
   window began: a state that starts sampling from the moment the window
   first opens (no warm-up) would be a better test of "does opening the
   window open new connections"; (b) `Get-NetTCPConnection`'s
   `OwningProcess` may not attribute a WebView2 renderer's sockets the way
   this bench assumes (Chromium's actual socket ownership can live in the
   browser/network-service process, not the renderer, regardless of which
   PID "looks like" the active tab) - worth a manual
   `netstat -ano`/`Get-NetTCPConnection` cross-check against a live pane
   in a future round before trusting this column for anything but the
   plain PowerShell/CLI processes (server/sync-cli), where it should be
   reliable.
3. **Working-set peaks are per-process, not summed** - the table above
   quotes the single busiest process per state; the JSON files have every
   PID's own number if a future round wants a true summed-memory figure
   per state.

## Files

- `tests\perf\Measure-Furphy.ps1` - the bench itself (reusable for every
  future round's before/after).
- `tests\perf\Setup-Baseline.ps1`, `Run-StateA.ps1` .. `Run-StateG.ps1` -
  the scratch drivers that built this specific baseline. Not part of
  `tests\run-all.ps1` (the perf layer stays a placeholder per
  TESTING.md/run-all.ps1 - these are one-off scripts for this round, kept
  here for the next round to reuse or delete).
- `tests\perf\bench\<label>-<stamp>.json`/`.md` - one pair per state, full
  per-process detail.
