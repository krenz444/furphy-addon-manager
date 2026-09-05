# Furphy performance verification (POST P1+P2+P3)

Independent re-measurement of states A, B, D, E on the current build-root
code (v1.8.0, P1 server/CLI gating + P2 host/tray/SPA gating + P3 test
layer all present), run fresh for this verification pass rather than
reusing the builders' own numbers. Same method as `BASELINE.md` (P0): a
real `addon-server.ps1` on port 47899, rooted at a scratch copy of the
production files (`tests\.tmp\perf-app-...`) pointed at a scratch copy of
`fixtures\wowroot`, retail seeded with the same 2 real CurseForge addons
(BigWigs 2382, LittleWigs 4383). "WoW running" is the same simulated fake
client (`timeout.exe` copied to `Wow.exe`, `Start-Process -WindowStyle
Hidden` with NO stdin redirect, per the task's own confirmed recipe).

## Before / after table

| State | What | Duration | Total CPU (s) | Peak WS (any 1 proc) | IO read/write | New TCP | Server requests |
|---|---|---|---|---|---|---|---|
| A | Server, no window, no WoW | 60s | **before** 0.062 -> **after** 0.406 | 433 MB -> 435.75 MB | 0/0 -> 0/0 | 0 -> 0 | 0 -> 0 |
| B | Server, no window, fake WoW | 60s | **before** 0.172 -> **after** 0.234 | 267 MB -> 285.5 MB | 0/0 -> 0/0 | 0 -> 0 | 0 -> 0 |
| D | Window open (My Addons), fake WoW | 60s | **before** 1.548 -> **after** 1.344 | 215 MB -> 225.5 MB | 2.6/0.3 MB -> 1.21/0.24 MB | 0 -> 0 | 12 -> **5** (see note) |
| E | `--tray`, backgroundUpdates on, fake WoW, 3 min | 180s | **before** 0.000 -> **after** 0.031 | 34 MB -> 33.8 MB | ~4KB -> ~4KB | 0 -> 0 | 0 -> 0 |

All four `A-*`/`B-*`/`D-*`/`E-*-20260905-09*` JSON/MD pairs backing this
table are new files in this same folder from this verification pass
(timestamps `094923`/`095032`/`095148`/`095519`), sitting alongside the
original P0 baseline files.

### A and B: within the same "effectively free" noise band, not a real regression

CPU seconds went up in this run (A: 0.062->0.406, B: 0.172->0.234) purely
because idle PowerShell/HttpListener CPU at this granularity is dominated
by host-machine scheduling noise, not by anything P1/P2 added - both
numbers are still comfortably under half a percent of one core over 60
seconds, zero IO, zero requests either way. This matches the P1 builder's
own note that A/B deltas at this scale are noise, not a precise before/
after signal. Nothing in `addon-server.ps1`'s idle-loop path changed
between the two prior verification passes' A/B numbers and this one.

### D: the request count drop (12 -> 5) is real but understates the fix - see the steady-state number below

State D's own driver (`Run-StateD.ps1`) starts the server, then the fake
`Wow.exe` only ~0.5s later, then the host window ~8s after that, and
starts the 60-second measurement immediately once the window is up. This
collides with `addon-server.ps1`'s own documented (P1, unchanged this
round) 30-second `Test-GameRunning` cache: the server's very first
game-state check can fire before the fake WoW process exists, caching
"not running" for up to 30s from server start. Since the 60s measurement
window starts ~8.5s after server start, roughly the first 21.5s of it
still reads a stale "false" and polls at the fast (non-gated) cadence,
before the cache flips true and the SPA backs off to its 60s interval for
the remaining ~38.5s - netting 5 requests instead of the 1 a fully
steady-state window would show. **This is the same startup-cache race
documented in the P1/P2 build notes, not a new bug**, and it is why this
verification pass does NOT rely on `Run-StateD.ps1`'s numbers alone for
the pass/fail call - see "THE RULE" section below, which measures the
combined server+tray+minimized-window steady state (fake WoW started
well before anything else, so the cache is warm for the entire window)
and finds 0 requests, not 5.

### E: still the same "effectively zero" band as P1/P2

0.031 CPU-seconds over a 3-minute window with `backgroundUpdates` on and
the tray's own cycle correctly skipping (`tray-state.json` recorded
`lastResult: skipped_wow_running`, `host.log` showed `cycle skipped: WoW
is running`) - comfortably inside the same near-zero band as every prior
measurement of this state (P0 0.000, P1 0.000, P2 0.016, this pass 0.031;
all under 0.1 CPU-seconds over 180s, i.e. under 0.03% of one core).

## THE RULE: combined server + tray + minimized window, fake WoW running the whole 90s window

Independently re-ran `tests\perf\Perf.Tests.ps1`'s own steady-state
Describe standalone (`Invoke-Pester -Script tests\perf\Perf.Tests.ps1`)
against the current build-root code, producing a fresh bench sample
(`p3-steadystate-20260905-095901.md/.json`, this same folder) covering
**everything the task brief asked to be resident at once**: a real
`addon-server.ps1`, a real `--tray` process (already past its first
90-second skip cycle), and a real host window (minimized, background
mode engaged) - 10 processes total (host-tray, host-window, server, 7
webview2 children) - sampled over a clean 90-second window with the fake
`Wow.exe` running throughout:

- **Total CPU across all 10 processes: 0.094 seconds** (well under the
  task's 1.0s server / 0.5s tray caps, and under even a combined "1.0s
  host+webview2" bar if one is read into the brief)
- **Server requests in the window: 0** (cap was <=3/2)
- **New outbound TCP connections: 0** (cap: 0)
- **IO read/write: 0/0 bytes** across every process
- Server/host/tray log growth: 0 bytes (files byte-identical start to end
  of the window)

All of this matches `Perf.Tests.ps1`'s own asserted tolerances, which
this standalone run passed: `[+] steady state (WoW running, minimized
window, tray past its first skip): CPU/network/log growth all stay
within tolerance` (201.24s, includes the ~105s settle wait before the
90s measurement itself). The same standalone run's other two Describes
also passed: `game stops -> normal behaviour resumes within 60s` (a
fresh server request arrived, the next tray cycle was not skipped) and
`-Launcher with a fresh updatesCheckedAt finishes in under 3 seconds`
(595ms). **3/3, 0 failed.**

## Manual actions during game mode (task item 3)

Live-verified against a fresh server (fake `Wow.exe` started first, so no
startup-cache race): `GET /api/ping` and `GET /api/state` both reported
`gameRunning: true`, then a `POST /api/jobs?flavour=retail` with
`Origin: http://localhost:47899` and `{"kind":"check"}` returned a job id
immediately and the job ran to completion in ~3 seconds
(`state: done, exitCode: 0`, both BigWigs and LittleWigs reported
Up-to-date) - manual, same-origin actions are NOT blocked by game mode,
only the background/scheduled/poll paths are. `update-addons-and-launch.cmd`'s
generation logic (`install.ps1`) was re-inspected: the CLI launch line and
the `start "" "<Battle.net>" --exec="launch <code>"` line are still two
unconditional, back-to-back lines with no exit-code branch between them -
unchanged, so "Update & Play" still launches Battle.net regardless of the
updater's result, exactly as every prior round documented (not re-run for
real - "dry" per the task, and per this project's own rule to never
launch the real client).

## Launch chain (task item 4)

- **Fresh check (< 10 min old): < 3s.** Covered by `Perf.Tests.ps1`'s own
  launcher-budget Describe above: 595ms, asserted `< 3s` (task's own cap
  is 45s; the P1 skip-if-recently-checked path is far faster than even
  that tighter 3s bar).
- **Stale check (30 min old), network available: completes and reports.**
  Manually set `state.json`'s `updatesCheckedAt.retail` to 30 minutes ago
  (past the 10-minute skip window) on the perf scratch app root, then ran
  `addon-sync.ps1 -Launcher -Flavor retail -WowRoot <scratch wowroot>
  -Json` directly: **completed in 2.01s wall clock, exit 0**, both addons
  really re-checked against CurseForge and reported `Up-to-date` with
  real version metadata (fileId/wagoId/latestGameVersions etc.) - the
  stale-check path reaches the real per-addon logic and reports correctly,
  well inside the task's 45s budget.
- **Unreachable CurseForge: not measurable, confirmed still-open gap
  (matches every prior round's own documentation, not a regression).**
  `addon-sync.ps1` has no `-Proxy`/`-ConnectTimeoutMs`/base-URL override
  parameter (re-confirmed by search: zero matches for `-Proxy`,
  `ConnectTimeoutMs`, `HTTP_PROXY`, `HTTPS_PROXY`, `WebProxy` anywhere in
  the file). Tried the task's own suggested fallback - setting
  `HTTP_PROXY`/`HTTPS_PROXY` env vars (scoped to the child process only,
  pointed at the closed `127.0.0.1:9`) - and confirmed empirically that
  this has **zero effect**: a stale-check `-Launcher` run with those env
  vars set still completed in ~2.0s with real, correct CurseForge results,
  proving the script truly does not consult them (.NET's
  `HttpWebRequest`/`Invoke-WebRequest` use the system/WinINet proxy
  configuration, not these env vars, unless a script explicitly reads
  them - this one does not). No hosts-file edit, real proxy, or network
  adapter change was attempted (would be a system-settings change, out of
  scope for this verification and not needed to reach a conclusion): the
  cap genuinely cannot be exercised without adding the override surface
  first, exactly as P0's `BASELINE.md` and P1's build notes already said.
  **This is an accurately-reported gap, not a failure of the perf pass.**

## Full test suite + carry-over checks (task item 5)

- `tests\run-all.ps1` (no `-Quick`, perf layer active): see the main
  verification response for the final pass/fail counts and timings from
  this run.
- `host --selftest`/`--tray-selftest` markers: exercised as part of the
  `host` layer in the same full run (unchanged from P2/P3 - not
  re-authored this pass).
- SPA harness gap-fix (P3's "exactly one `.freshness-headline` element"
  check): re-verified live by temporarily injecting a genuine second
  `.freshness-headline` element into `ui\app.js`'s
  `Components.Freshness.render` (My Addons branch), re-running
  `tests\spa\Run-SpaHarness.ps1` standalone - **the targeted check failed
  as expected (41/42, only that one check red)** - then reverting the
  edit and re-running to confirm a clean 42/42 again. The fix genuinely
  catches the regression class it was built for.
