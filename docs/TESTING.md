# Testing hooks

Eric's test suite (`tests\`) needs a small number of testability hooks in
production files. Every one is listed here, per file, with exactly what it
does and why it is safe.

## addon-sync.ps1 / addon-server.ps1 - dot-source guard

Both scripts have this block near the top of their "main"/"startup" section:

```powershell
$script:FurphyDotSourced = ($MyInvocation.InvocationName -eq '.') -or ($MyInvocation.Line -match '^\s*\.\s')
if ($script:FurphyDotSourced) {
    return
}
```

**What it does:** when the script is dot-sourced (`. .\addon-sync.ps1`)
instead of run normally (`.\addon-sync.ps1 ...` or `powershell -File
addon-sync.ps1 ...`), every function/table above this line is still defined
in the caller's scope, but the script returns immediately instead of running
its normal main body (parsing `-Flavor`/`-Scan`/etc., binding a listener,
starting a sync, exiting).

**Why it's safe:** a normal invocation (`-File`, or the file run directly)
is completely unaffected - `$MyInvocation.InvocationName` is the script's own
path, not `.`, so the guard is false and every existing behavior is
byte-identical to before this line existed. It only changes behavior for the
one call shape (`. path\to\script.ps1`) that nothing in the real app ever
uses.

**Who uses it:** `tests\unit\*.Tests.ps1` and `tests\static\*.ps1`
dot-source one or both scripts to call their internal functions
(`Get-InstalledFlavours`, `Test-SameOriginRequest`, `ConvertTo-SafeProcessArg`,
etc.) directly, without running a real HTTP listener or a real CLI pass.

## ui\app.js - `window.__furphyTest`

At the very end of the file:

```javascript
document.addEventListener("DOMContentLoaded", function () {
  const initPromise = App.init();
  if (new URLSearchParams(location.search).get("test") === "1") {
    window.__furphyTest = window.__furphyTest || {};
    window.__furphyTest.ready = false;
    window.__furphyTest.App = App;
    window.__furphyTest.Store = Store;
    initPromise.then(function () { window.__furphyTest.ready = true; });
  }
});
```

**What it does:** when the page is opened with `?test=1` present anywhere in
the query string (normally alongside `?mock=1`), it exposes `window.App` and
`window.Store` as `window.__furphyTest.App`/`.Store`, and flips
`window.__furphyTest.ready` from `false` to `true` once `App.init()`'s whole
async startup chain (fetch ping info, load state, wire everything up) has
actually finished.

**Why it's safe:** the entire block is gated on the literal query param
`test=1`. Any real load - the native host, a plain browser tab pointed at
the real server, or even `?mock=1` on its own with no `test=1` - never
touches `window.__furphyTest` at all; the object is never created and
nothing about `App.init()`'s own behavior changes (the hook only *reads*
the promise it already returns, never intercepts or delays it).

**Who uses it:** `tests\spa\harness.js` loads `/?mock=1&test=1` (and
variants: `&flavours=3`, `&host=webview2`, `&theme=<slug>`, `&view=`/`&tab=`)
in an iframe and polls `window.__furphyTest.ready` before running any DOM
assertion, so it never races the app's own startup sequence. It does not
currently use the exposed `App`/`Store` objects for assertions (every check
in that file reads rendered DOM instead, which is what a real user/host
would see) - they are exposed for a future harness author who needs to
inspect internal state directly rather than infer it from the DOM.

## host\FurphyHost.exe - `--selftest` / `--tray-selftest`

Not new for this test suite - both flags, and the JSON marker file each one
writes, are existing, designed features of the shipped exe (see
`host\FurphyHost.cs`'s own header comments on `RunSelftestSequence`/
`WriteSelftestMarker`/`--tray-selftest`). Documented here only because
`tests\host\Host.Tests.ps1` is the first place anything in this repo
actually drives them as a real, asserted-against test:

- `FurphyHost.exe --port <n> --selftest <markerPath> <url>` loads `<url>`
  as the main window's page (in place of the real server-hosted SPA),
  drives a fixed ~8-second scripted sequence (`host\selftest.html`'s own
  hello/theme/cf-show/cf-hide/cf-show timeline plus a host-side injected
  fake `curseforge://install` deep link), and writes a JSON marker to
  `<markerPath>` before exiting on its own.
- `FurphyHost.exe --port <n> --tray-selftest <markerPath> [--wow-fake <name>]`
  runs one full tray background-sync cycle (real WoW-running check, real
  self-started `addon-server.ps1` if not already running, a real
  `update-all-flavours` job fan-out, a real Start-with-Windows
  register/unregister round-trip against the real HKCU `Run` key) and
  writes its own JSON marker, then exits. `--wow-fake <processName>` swaps
  the real "is WoW running" process-name check for a caller-supplied one,
  so the skip path can be proven without the real game installed.

Neither flag can be reached by a normal launch (both require an explicit
command-line switch nothing else in the app ever passes), and
`--tray-selftest` always writes its marker and exits even if it crashes
partway through (`RunSelftestSequenceSafe`'s own try/catch), so a harness
waiting on the marker file never hangs.

**Fixed finding (Round 24/T5), documented here for history:** `Host.Tests.ps1`'s
own `--selftest` test used to find that the fake `curseforge://install`
deep-link's 2-second-after-document-created timer and `selftest.html`'s
own cf-hide (also ~2 seconds after the same cf-show) landed close enough
together that the pending timer did not reliably survive being hidden and
re-shown within the remaining ~4 seconds before the marker is written -
reproduced 3/3 (and later 4/4) times on a real machine with real network
to curseforge.com. Fixed by shortening the injected script's own delay
from 2000ms to 500ms (`EnsureSelftestDeepLinkInjection`, `host\FurphyHost.cs`)
and pushing `selftest.html`'s cf-hide/final cf-show out from t=3s/4s to
t=5s/5.5s, giving several seconds of margin on both sides instead of a
near-exact coincidence. Verified clean 2/2 real runs after the fix
(`sawDeepLink`/`intercepted`/`jobPostStatus` all populated).

## addon-sync.ps1 - FURPHY_TEST_CF_BASEURL / FURPHY_TEST_WAGO_BASEURL (Round 26)

Two environment variables, read once near the top of `addon-sync.ps1`
(`$script:CfBaseUrl`/`$script:WagoBaseUrl`), before the dot-source guard:
when either is set to a non-empty, non-whitespace value, it REPLACES the
real `https://www.curseforge.com` / `https://addons.wago.io` base for
every real HTTP call site in this file (file listing, file-detail lookup,
download, the CurseForge Referer header, and the Wago Inertia page fetch)
for the life of that one process. An empty or whitespace-only value is
treated exactly like an unset one - falls back to the real host.

**TEST-ONLY.** Nothing in the real app - `install.ps1`, the generated
launcher `.cmd`, `addon-server.ps1`'s own CLI child-process spawns, the
tray, the host - ever sets either variable, so a real user's launch always
resolves to the real hosts, byte-identical to before this existed. It
exists purely so a test can point both hosts at a local, test-owned HTTP
endpoint - most usefully `tests\lib\common.ps1`'s `Start-BlackHoleListener`
(a TCP listener that accepts a connection and never responds), which is
how `tests\integration\Cli.LauncherBudgetOverride.Tests.ps1` proves the
`-Launcher` wall-clock budget cap (`Test-LauncherBudgetExceeded`) actually
bounds a real launch chain end to end, rather than only unit-testing the
budget math in isolation.

**Who uses it:** `Invoke-CliProcess`/`Invoke-CliJson` (`tests\lib\
common.ps1`) take an `-EnvironmentOverrides` hashtable that sets extra
environment variables on that ONE spawned child process only - never on
the test-runner's own process, so a value set for one test can never leak
into another. `tests\unit\Cli.BaseUrlOverride.Tests.ps1` re-dot-sources
`addon-sync.ps1` with the variable set/unset/blank and asserts
`$script:CfBaseUrl`/`$script:WagoBaseUrl` directly (no real process, no
real HTTP call); `tests\integration\Cli.LauncherBudgetOverride.Tests.ps1`
drives a real child process end to end, both against the black-hole
listener and (one `Network`-tagged It) confirming a blank override still
reaches the real host.

## Round 28: tray tooltip/icon/menu/balloon history (`host\FurphyHost.cs`, `tests\host\Host.Tests.ps1`)

`--tray-selftest`'s JSON marker (see the `--selftest`/`--tray-selftest`
section above) gained five new fields so a test can prove the exact
sequence of user-visible text/state a cycle produced, not just its final
outcome: `tooltipHistory`/`iconStateHistory` (every DISTINCT tooltip text /
icon variant name set during the run, in order - consecutive duplicates
collapse to one entry, a later repeat of an earlier value does not merge
with it), `menuStatusText` (the context menu's disabled status line at the
moment the marker is written), `balloonShown`/`balloonText` (whether
`ShowBalloon` fired at all this run, and its text if so), and `clickOutcome`
(the same value as the pre-existing `clickAction` field, kept for back-
compat, now colon-qualified: `"activate:foreground"` / `"activate:flashed"`
/ `"launch"`).

**Single- vs multi-flavour matters for these fields.** The per-addon
"Checking addons (N of M)"/"Updating \<Name\> (k of m)" tooltip wording
(SPEC.md section B) only ever renders for a cycle with exactly ONE flavour
job - a genuine multi-flavour cycle keeps the simpler, counts-free
"Checking..." text throughout, by design (combining N independent jobs'
progress into one n-of-N line is out of scope). `tests\host\Host.Tests.ps1`
therefore now has TWO different tray-cycle shapes:

- The pre-existing "runs a real cycle" It still uses the default 3-flavour
  fixture root (retail/classic/classic_era) with zero tracked addons - it
  now additionally asserts `clickOutcome` is exactly `"launch"` (the only
  possible value here - `--tray-selftest`'s own `ActivateOrLaunch(true)`
  call is a dry run that never actually starts a process, and no real
  `"Furphy Addon Manager"`-titled window exists on a test machine) and that
  `tooltipHistory` never contains the old incident's `"Updating N of N"`
  shape for this genuine multi-flavour, nothing-tracked cycle.
- A new Describe, `New-TrayTestLayout -OnlyFlavours @('_retail_')`, builds
  a retail-ONLY root (every other fixture flavour folder is deleted right
  after the copy, before `Get-InstalledFlavours` ever sees it) so the
  cycle is single-flavour and the per-addon wording actually renders. Two
  `Network`-tagged Its against this root, both real CurseForge installs of
  project 2382 (BigWigs - already used by `tests\perf\Setup-Baseline.ps1`/
  `Perf.Tests.ps1`, retail-compatible):
  - **Nothing to update**: a plain `-Add 2382` (latest file) followed
    immediately by a real cycle - `tooltipHistory` contains an entry
    matching `"Checking addons ("` and its LAST entry matches
    `"Everything's up to date"`; never contains `"Updating"`;
    `balloonShown` is `false`.
  - **Forced update**: `-Add 2382 -FileId <older>` (an OLDER real file,
    looked up live via `Get-OlderCurseForgeFileId` - never hardcoded,
    since BigWigs releases often enough that a fixed file id would go
    stale within days) pins the record to it, then `-Unpin 2382` frees it,
    then a real cycle finds and installs whatever is actually newest -
    `tooltipHistory` contains an entry matching `"Updating <Name> (1 of
    1"` and its LAST entry matches `"Updated 1 at"`; `balloonShown` is
    `true` and `balloonText` contains the addon's real name.

**Deliberate deviation from SPEC.md section J's own wording, found while
implementing this**: that section describes the "nothing to update" case
as "today's existing scratch fixture, zero tracked addons" - but with
truly zero `addons.json` records, `addon-sync.ps1`'s main loop writes
`Write-ProgressStep('queued', Total=$toSync.Count)` exactly ONCE (the
per-addon loop body never runs at all) - so `"Checking addons ("` (which
needs `total > 0`) can never appear for a zero-addon cycle; the tray
correctly shows `"Starting the updater..."` the whole time instead (see
`ComputeCore`'s own `total <= 0` branch). This matches round 28's own B2
build-step manual verification notes, which used 2 REAL tracked addons for
exactly this reason, not zero. `Host.Tests.ps1`'s new Its follow that
actually-correct shape (one real tracked addon) rather than SPEC.md
section J's zero-addon text.

`ui\app.js`'s Job Panel (`Components.JobPanel.update`) and Settings status
line (`Views.settings.backgroundStatusText`) gained the same phase-aware/
status-driven wording client-side - `tests\spa\harness.js`'s default phase
now samples the running progress label across a whole mock "Update all"
job (`labelSamples`, collecting every DISTINCT text seen) and asserts both
the `"Checking addons (N of M)"` / `"Checking addons (N of M) - K updates
found so far"` and `"Updating <Name> (K of K)"` shapes appear, and that the
old `"Updating i of N addons"` text never does; a second small block
toggles `#toggle-background-updates` on and asserts the Settings status
line reads the tray's exact `"Everything's up to date - checked HH:MM -
next ..."` core sentence (from `ui\app.js`'s Mock, whose fabricated
`/api/tray/start` cycle now carries the full `status`/tallies shape, not
just the pre-round-28 `lastResult`/`message` fields).

## Running the suite

One entry point, `tests\run-all.ps1`, runs every layer below in order,
prints a plain summary table and one-line verdict, writes
`tests\last-report.json`/`tests\last-report.md`, and exits 0 (all green)
or 1 (anything failed).

```
tests\run-all.ps1                          # full run: every layer
tests\run-all.ps1 -Quick                   # static/unit/integration/host/spa only, no network, target <4 min
tests\run-all.ps1 -NoNetwork               # skip anything tagged 'Network' (works on a full run too)
tests\run-all.ps1 -NoTray                  # skip anything tagged 'Tray' (a real HKCU Run round-trip)
tests\run-all.ps1 -Only unit,integration   # just these layers (still honors -NoNetwork/-NoTray/-Quick's tag effect)
tests\run-all.ps1 -Json                    # print the final report as JSON instead of the table (files are always written)
```

**Layers, in order** (`static -> unit -> integration -> host -> spa ->
fixture-acceptance -> perf`):

| Layer | What | Quick? |
|---|---|---|
| `static` | `tests\static\*.ps1` - parse/ASCII/JSON/banned-terms/package-allowlist/gitignore-coverage/node --check checks. Each script is its own process (they `exit N`, so `run-all.ps1` drives them as real child processes, never `&`-invokes them in-process). | yes |
| `unit` | `tests\unit\*.Tests.ps1` (Pester 3) - CLI/server functions called directly via the dot-source guard, no real socket/process. | yes |
| `integration` | `tests\integration\*.Tests.ps1` (Pester 3) - real HTTP against a real `addon-server.ps1` test instance and real CLI child processes. Two Describes tagged `Network` (a real CurseForge install, a mid-flight freshness check); one tagged `Tray` (a real tray process + HKCU round-trip). | yes (network/tray-tagged pieces skip only if you also pass `-NoNetwork`/`-NoTray`) |
| `host` | `tests\host\Host.Tests.ps1` (Pester 3, `-Tag Host`) - builds/uses the real `host\bin\FurphyHost.exe`, drives `--selftest`/`--tray-selftest`. The `--selftest` Describe is tagged `Network` (the CF pane really navigates to curseforge.com); the first two `--tray-selftest` Its (multi-flavour, zero tracked addons) are fully offline. Round 28 added a second `--tray-selftest` Describe, both Its tagged `Network` (real CurseForge installs against a single-flavour retail-only root) - see "Round 28: tray tooltip/icon/menu/balloon history" below. | yes (the two new Network-tagged Its skip under `-Quick`/`-NoNetwork`, same as every other Network-tagged piece) |
| `spa` | `tests\spa\Run-SpaHarness.ps1` (always) - a same-origin copy of `ui\` driven headlessly, 47 DOM/behavior checks (this count drifts release to release - see Round 28 below for the latest addition; do not treat any specific number here as load-bearing). `tests\spa\Run-ThemeAudit.ps1` (full-run only) - live-computed WCAG contrast for all 16 themes plus one screenshot per theme into `tests\theme-screenshots\`. | harness only; theme audit is full-only |
| `fixture-acceptance` | `tests\fixture-acceptance\FlavorsSpec.Section8.Tests.ps1` (Pester 3) - a traceability pass over FLAVORS-SPEC.md section 8's own checklist: install.ps1's home-flavour fallback ordering (including the fixture install into `_classic_era_`) and the CurseForge auto-target flavour-resolution cases (S5.5). Real `install.ps1` runs (incl. a real `host\` rebuild) make this full-run-only. | no |
| `perf` | `tests\perf\Perf.Tests.ps1` (Pester 3) - Eric's "zero impact on gameplay" pass, asserted: a real fake-Wow.exe + real `addon-server.ps1` + real `--tray` + a real (minimized) host window, sampled over a 90-second steady-state window (server CPU, tray CPU, new TCP connections, server requests, `server.log` growth, `tray-state.json`/host.log all asserted against fixed tolerances); a second Describe stops the fake WoW and asserts normal behaviour resumes within 60s; a third asserts the `-Launcher` fresh-check launch-chain budget (< 3s). The tray's own ~90-second first-cycle delay alone puts this well over the Quick budget - full-run-only. | no |

**Hygiene, unconditional:** the same port/process/HKCU/`tests\.tmp` sweep
(`Invoke-HygieneSweep` in `run-all.ps1`) runs BOTH once at the very start
of a run AND in a trailing `finally` around the whole run, so a run never
inherits a stale server/process/HKCU value left by whatever ran on this
machine before it (a crash or Ctrl+C that skipped its own cleanup),
regardless of how the run itself exits. Every port this suite might use
(47899, 47890-47897) is checked and any owning process force-stopped;
`tests\.tmp` is swept to empty; a straggler `FurphyHost.exe` process or a
leftover HKCU `FurphyAddonManager` Run value is detected and
force-cleaned as a last-resort safety net (logged loudly - it means some
test's own `finally` did not run to completion, which is itself worth
investigating). The trailing sweep runs even if a layer throws an
unexpected error instead of a normal test failure. `Start-TestServer`
(`tests\lib\common.ps1`) also independently refuses to even try starting
against a port that is already answering, for the same reason (Round 23
review fix) - a stale server answering `/api/ping` could otherwise be
silently mistaken for the one this call just started.

**Known, non-blocking findings:** `run-all.ps1` has a small, explicit
`$Script:KnownNonBlockingChecks` allowlist (keyed by exact check
`DisplayName`). A check named there can still fail - it still counts in
`Total`/`FailedCount`, still prints to the console, and gets its own
"known, non-blocking findings" section in `tests\last-report.md` (never
silently hidden) - but does NOT flip that layer's `Passed` or the run's
overall pass/fail. This exists so a checked-in, already-documented issue
(tracked in CHANGELOG.md/ROADMAP.md, owned by something outside this
tests-only suite) does not permanently red the `deploy.ps1` gate. Add an
entry here ONLY for a finding that is already written up elsewhere as
flagged-not-fixed - never to quiet a new or unexplained failure; that
would defeat the entire point of the gate. **Currently empty** - the one
long-standing entry (Round 22's repo-mirror `.gitignore` missing a
`cache\` pattern) is resolved: Eric added the pattern by hand and
`tests\static\Test-GitignoreCoverage.ps1` was fixed (Round 25/P3) to read
the mirror path from `deploy.ps1`'s own `-RepoPath` default instead of a
second hand-typed copy - the check passes clean (17/17) on its own again.

**deploy.ps1's gate:** `deploy.ps1` runs `tests\run-all.ps1 -Quick` as its
own step 0, before touching the live install folder, and aborts (pointing
at `tests\last-report.md`) on any failure. Pass `deploy.ps1 -SkipTests` to
bypass this deliberately - it prints a loud, impossible-to-miss warning
banner in the console every time, so a skipped gate is never silent in the
transcript.

## Adding a test

- **static** (`tests\static\`): a new plain `.ps1` using
  `tests\lib\common.ps1`'s `New-ResultsCollector`/`Add-Result`/
  `Write-ResultsSummary` (see any existing file in that folder for the
  exact three-line pattern). Must `exit 0`/`exit 1` - `run-all.ps1` drives
  it as a real child process specifically because of that `exit` call.
- **unit/integration/host/fixture-acceptance** (Pester 3 syntax -
  `Describe`/`Context`/`It`/`Should Be`, no `-Because`, no `Should -Be`
  dash form): dot-source `tests\lib\common.ps1` then, if you need the
  CLI/server's own functions, dot-source `addon-sync.ps1`/
  `addon-server.ps1` directly (the dot-source guard makes this a no-op
  main-body run). Use `New-TempRoot`/`Copy-Fixture` for anything you
  mutate - never touch `fixtures\wowroot` directly. Tag a Describe
  `-Tags 'Network'` if it makes a real internet call, `-Tags 'Tray'` if it
  starts a real tray process/touches HKCU Run - both need an unconditional
  cleanup in a `finally`/`try`/`finally` shape, not "cleanup at the end of
  the It" (a failed assertion must not skip it).
  **Pester's `Mock` cmdlet does not reach a function that was defined by
  dot-sourcing a script at file scope** (confirmed live while writing
  `FlavorsSpec.Section8.Tests.ps1` - see that file's own header comment
  on `Resolve-CfInstallFlavour` for the full explanation and the working
  alternative: redefine the real command as a plain function at the same
  file scope, driven by a couple of script-scope variables each `It` sets
  before calling in, the same technique `Server.Handlers.Tests.ps1`
  already uses for `Open-InBrowser`). Reach for that pattern instead of
  `Mock` in this suite.
- **spa** (`tests\spa\`): extend `harness.js`'s phase list (or add a new
  `Run-*.ps1` + `.html`/`.js` trio following `Run-ThemeAudit.ps1`'s
  pattern) if the SPA needs a new same-origin, headless-msedge check.
  Register it in `tests\run-all.ps1`'s `spa` layer section, and decide
  Quick-vs-full-only by real wall-clock cost (target: Quick's whole run
  stays under 4 minutes).
- **perf** (`tests\perf\`): extend `Perf.Tests.ps1` (Pester 3, same
  conventions as `host`/`integration`) if a new "zero impact on gameplay"
  scenario needs asserting. Reuse `tests\perf\Measure-Furphy.ps1` (a real
  fake-Wow.exe + real processes, sampled and rolled up into CPU/IO/TCP/
  request-count numbers) rather than re-deriving sampling logic - it
  self-discovers every Furphy-scoped process under a given build root. Any
  scenario involving the tray should account for its own ~90-second
  first-cycle delay when deciding how long the Describe needs to run.
- Always add the new file's directory to `tests\run-all.ps1`'s layer list
  if it's a genuinely new layer (rare) - the seven layers above are meant
  to be the complete set for the foreseeable future.

## Scratch roots

Building a scratch app root by hand (a copy of `addon-sync.ps1`/
`addon-server.ps1`/`ui\`/`host\bin\`) always goes `New-TempRoot` +
`Copy-FurphyAppFiles -Destination <root>`, never a hand-written
`Copy-Item`. **Never copy `tests\` itself into a root under
`tests\.tmp`** - a 2026-09-08 incident did exactly that (destination
lived inside `tests\.tmp`, itself under `tests\`, so the recursive copy
of `tests\` copied itself into itself until Windows' path limits
stopped it) and `Copy-FurphyAppFiles` exists specifically so that
mistake cannot happen again.

## Hygiene rules (apply to every test you write)

- Never touch `C:\Program Files (x86)\World of Warcraft\_retail_\AddonSync`,
  the real WoW folder, the real Desktop, the HKCU Run value (except a
  `Tray`-tagged test, which must remove it and assert it is gone), or port
  47831. Use port 47899 (integration/host/fixture-acceptance servers) and
  the 47890-47897 pool (static file servers), and a copy of
  `fixtures\wowroot` (`Copy-Fixture`), never the checked-in original.
- **Never call `install.ps1 -Uninstall` without `-NoShortcuts`** unless
  you have independently confirmed `-WowPath` is a scratch/test root
  `Test-LooksLikeScratchRun` would recognize (under `%TEMP%`, `\scratch\`,
  or `fixtures\wowroot`) - `-Uninstall`'s desktop-shortcut removal targets
  the REAL Windows Desktop, not anything scoped to `-WowPath`. This
  suite's own `fixture-acceptance` layer only ever calls plain
  `install.ps1` (never `-Uninstall`) for exactly this reason - see its own
  file header if a future test genuinely needs to exercise `-Uninstall`.
- Every test that starts a process (a server, the CLI, `FurphyHost.exe`,
  a static file server) must stop it in a `finally` block, unconditionally
  - a failed assertion must never leak a process, a bound port, or a
  registry value.
- Tests must be deterministic and self-contained. A test that makes a
  real network call must be tagged `Network`; a test that starts a real
  tray/HKCU cycle must be tagged `Tray`.
