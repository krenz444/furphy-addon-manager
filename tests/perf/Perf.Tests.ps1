<#
=====================================================================
 tests\perf\Perf.Tests.ps1 (P3)

 Eric's rule, verbatim: "do a full performance tuning / pass, absolutely
 nothing / everything must have zero impact on gameplay." P0 measured the
 baseline (tests\perf\bench\BASELINE.md), P1 added server/CLI game-state
 gating + process priority + a launch-chain budget (SPEC.md Expansion
 E28), P2 added the host window's background mode / tray priority / SPA
 poll gating. This file is the automated regression layer over all of
 that: a real fake-Wow.exe + real addon-server.ps1 + real --tray + a real
 (minimized) host window, sampled with the same tests\perf\Measure-Furphy.ps1
 bench P0-P2 used by hand, now asserted against fixed tolerances instead of
 eyeballed. (Round 34, 2026-09-07: the -Launcher fresh-check budget test
 that used to live here was removed along with -Launcher itself - see
 CHANGELOG.md.)

 FULL-RUN-ONLY BY DESIGN (like fixture-acceptance/the theme audit): the
 tray's own WorkerLoop always waits ~90s before its first cycle (by
 design, unrelated to this test - see host\FurphyHost.cs's own comment on
 that constant), so this file waits for that first cycle to complete
 (steady state) BEFORE measuring a clean 90-second window - the whole
 Describe costs a bit over three real wall-clock minutes even before the
 "cycle while WoW keeps running" half runs. That is well over
 tests\run-all.ps1 -Quick's <4-minute budget for the WHOLE suite, so this
 layer is never part of Quick (tests\run-all.ps1's own Quick layer list
 omits 'perf', same as 'fixture-acceptance').

 WHY STEADY STATE FIRST: WorkerLoop's first RunCycle fires at t=~90s
 after the tray starts - if this file's own 90-second measurement window
 started at the same moment as the tray, that first REAL cycle (GAME-
 MODE-SPEC.md 2026-09-08 removed RunCycle's WowDetector.IsRunning gate
 entirely, so this first cycle always runs in full now, WoW running or
 not - it posts a sync job per flavour, DOES write tray-state.json, and
 DOES log "[tray] cycle start"/"[tray] cycle done...") would land inside
 the measured window, which would fail "tray-state.json unchanged" for a
 reason that has nothing to do with steady-state overhead. Waiting for
 that one cycle to finish first (~100s, with margin) means the tray's own
 nextRunAtUtc is already ~30 minutes out (this file's own
 backgroundIntervalMinutes, New-PerfAppRoot below) by the time the real
 90-second measurement starts, comfortably inside a "nothing scheduled"
 window.

 WHY --wow-fake / -WowFakeProcessName (not a literal renamed Wow.exe):
 both hooks are real, designed, already-tested testability surfaces (see
 TESTING.md's own "--selftest / --tray-selftest" section and
 tests\host\Host.Tests.ps1's existing --wow-fake Describe) - using them
 keeps this file's fake client from ever being confused with a real game
 process in Task Manager during a run, and is the same mechanism
 addon-server.ps1's own -WowFakeProcessName test hook already documents
 itself as mirroring.

 TOLERANCES are deliberately generous relative to the actual measured
 numbers this round (see CHANGELOG.md's Round 25 before/after table) -
 comfortable margin for a slower/busier CI machine, while still being
 tight enough that the ungated pre-P1/P2 behavior (the P0 baseline's
 state D/E numbers) would fail every single one of them.
=====================================================================
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

# ---------------------------------------------------------------------
# Tolerances (explicit constants - see header comment on how these were
# chosen). Compare against CHANGELOG.md's Round 25 before/after table.
# ---------------------------------------------------------------------
$Script:MeasureWindowSec = 90            # task brief's own window length
$Script:SettleWaitSec = 105              # >90s (first-cycle delay) + margin
$Script:ServerCpuMaxSec = 1.0            # task brief
$Script:TrayCpuMaxSec = 0.5              # task brief
$Script:MaxNewTcpConnections = 0         # task brief: "zero NEW outbound"
$Script:MaxServerRequestsInWindow = 2    # task brief: "at most 2 SPA polls" (POLL_GAME_MS=60000 in ui\app.js -> 1-2 polls/90s)
$Script:MaxServerLogGrowthBytes = 2048   # task brief: "< 2 KB"
$Script:ResumeTimeoutSec = 60            # task brief

# Round 40 (QA-FINDINGS-LENSES-3.md, tests:perf-suite-no-webview-cpu-assertion,
# HIGH): the checks above only ever summed CPU for Role 'server'/'host-tray' -
# host-window and every webview2-child row (renderer/gpu-process/etc.) were
# never asserted on anywhere in this file, and the window was never measured
# in any state other than minimized. That gap is exactly how the companion
# finding webview2-gpu-cpu-open-foreground (an unthrottled decorative theme
# animation costing ~5.766 CPU-s/60s in the open+foreground state, ~11x the
# round-25 baseline of 0.516 CPU-s/60s) shipped undetected. Two guards below:
# $TotalCpuMaxSec closes the gap for the EXISTING minimized/tray It (added to
# its assertion block, not a new It); $ForegroundTotalCpuMaxSec backs a new,
# separate It that actually reproduces the state the regression landed in
# (window open, focused, WoW running, no minimize).
$Script:TotalCpuMaxSec = 1.0             # minimized steady-state It: total across EVERY Furphy-scoped process (server+tray+host-window+webview2 children), not just server/tray
$Script:ForegroundTotalCpuMaxSec = 1.5   # foreground It, 60s window: fixNote's own verified after-fix number is 0.312 CPU-s and the historical pre-regression P0-P2 baseline is 0.516 CPU-s/60s - 1.5 leaves ~3-5x headroom over both for a slower/busier CI machine while still failing hard (by ~4x) against the confirmed 5.766 CPU-s regression
$Script:ForegroundSettleWaitSec = 8      # matches tests\perf\Run-StateD.ps1's own settle - no tray/first-cycle wait needed here (no --tray process is started for this It)

$Script:HostBinDir = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'host\bin'
$Script:HostCsPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'host\FurphyHost.cs'
$Script:HostExePath = Join-Path -Path $Script:HostBinDir -ChildPath 'FurphyHost.exe'

function Ensure-PerfHostBuilt {
    <# Same pattern as tests\host\Host.Tests.ps1's Ensure-HostBuilt (kept as its own local copy - Pester dot-sources each *.Tests.ps1 into its own scope, nothing here is shared automatically). #>
    $needsBuild = $false
    if (-not (Test-Path -LiteralPath $Script:HostExePath -PathType Leaf)) {
        $needsBuild = $true
    } elseif ((Get-Item -LiteralPath $Script:HostCsPath).LastWriteTimeUtc -gt (Get-Item -LiteralPath $Script:HostExePath).LastWriteTimeUtc) {
        $needsBuild = $true
    }
    if ($needsBuild) {
        Write-Host '  (building host\bin\FurphyHost.exe - missing or stale)'
        & (Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'host\build-host.ps1')
    }
    return (Test-Path -LiteralPath $Script:HostExePath -PathType Leaf)
}

Add-Type -Namespace FurphyPerfTest -Name User32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
'@ -ErrorAction SilentlyContinue

$Script:SW_MINIMIZE = 6
$Script:SW_RESTORE = 9

function Test-RealWowClientRunning {
    <#
      HARD RULE for this build round: never launch a native FurphyHost.exe
      window while a real WoW client may be running on this machine - only
      --wow-fake/-WowFakeProcessName's fake client should ever be involved.
      Own local copy (kept dependency-free, matches
      tests\host\Host.Tests.ps1's Test-RealWowClientRunning and
      addon-server.ps1's Test-GameRunning / host\FurphyHost.cs's
      WowDetector.IsRunning name list byte-for-byte) - each *.Tests.ps1 is
      dot-sourced into its own scope, nothing here is shared automatically.
    #>
    $names = @('Wow', 'Wow-64', 'WowClassic', 'WowClassicT', 'WowClassicB', 'WowT', 'WowB')
    foreach ($n in $names) {
        try {
            $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
            if ($procs -and @($procs).Count -gt 0) { return $true }
        } catch { }
    }
    return $false
}

function New-PerfAppRoot {
    <#
      Builds a scratch app root (addon-sync.ps1/addon-server.ps1/ui\/
      host\bin\/settings.json, one empty flavour "retail") - same shape
      tests\perf\Setup-Baseline.ps1 used for P0, minus the real CurseForge
      seed (this layer's window/tray/server steady-state assertions don't
      need a real installed addon, and staying addon-free keeps every
      measured request/CPU number this file asserts on fully offline).
    #>
    param([Parameter(Mandatory = $true)][string]$Root, [int]$Port = 47899)

    Copy-FurphyAppFiles -Destination $Root | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'flavours\retail') -Force | Out-Null
    '[]' | Set-Content -LiteralPath (Join-Path $Root 'flavours\retail\addons.json') -Encoding UTF8

    $settings = [ordered]@{
        releaseType = 1; port = $Port; adFilter = $true; cfFocus = $true
        hostWindow = $null; hostTheme = $null; backgroundUpdates = $true; backgroundIntervalMinutes = 30
        runAtStartup = $false; schemaVersion = 2; activeFlavour = 'retail'; showTestRealms = $false
    }
    ($settings | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $Root 'settings.json') -Encoding UTF8
}

function Stop-PerfProcessQuiet {
    param($Process)
    if ($Process -and -not $Process.HasExited) {
        try { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Get-NewLineCountMatching {
    <# Counts lines in -Path matching -Pattern, restricted to lines at index >= -SkipLines (i.e. lines added since a prior snapshot of that same file). #>
    param([string]$Path, [string]$Pattern, [int]$SkipLines = 0)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ($lines.Count -le $SkipLines) { return 0 }
    $newLines = $lines[$SkipLines..($lines.Count - 1)]
    return @($newLines | Where-Object { $_ -match $Pattern }).Count
}

Describe 'Perf: light touch while you play (P3 automated layer)' {

    It 'steady state (WoW running, minimized window, tray past its first completed cycle): CPU/network/log growth all stay within tolerance' {
        if (-not (Ensure-PerfHostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $root = New-TempRoot -Name 'perf-steadystate'
        New-PerfAppRoot -Root $root -Port 47899
        $wowRoot = Copy-Fixture -Destination (New-TempRoot -Name 'perf-steadystate-wowroot')

        $fakeProcName = 'WowFakePerf' + (Get-Random -Maximum 99999)
        $fakeExePath = Join-Path $root ($fakeProcName + '.exe')
        Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\timeout.exe') -Destination $fakeExePath -Force

        $serverLogPath = Join-Path $root 'server.log'
        $hostLogPath = Join-Path $root 'host.log'
        $trayStatePath = Join-Path $root 'tray-state.json'
        $hostExe = Join-Path $root 'host\bin\FurphyHost.exe'

        $fakeWow = $null
        $server = $null
        $trayProc = $null
        $hostProc = $null

        try {
            # Order matters: fake WoW BEFORE the server, so Test-GameRunning's
            # own 30s startup cache (addon-server.ps1) is warm from the
            # server's very first read - see SPEC.md Expansion E28's own
            # "known, deliberate characteristic" paragraph. -WindowStyle
            # Hidden with NO stdin redirection (redirecting stdin makes
            # timeout.exe exit almost immediately - a confirmed gotcha from
            # the P0 baseline round).
            $fakeWow = Start-Process -FilePath $fakeExePath -ArgumentList @('/t', '900', '/nobreak') -WindowStyle Hidden -PassThru
            Start-Sleep -Milliseconds 500

            $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -IdleMinutes 60 -ExtraArgs @('-WowFakeProcessName', $fakeProcName)

            $trayProc = Start-Process -FilePath $hostExe -ArgumentList @('--port', '47899', '--tray', '--wow-fake', $fakeProcName) -PassThru
            $hostProc = Start-Process -FilePath $hostExe -ArgumentList @('--port', '47899', '--wow-fake', $fakeProcName) -PassThru

            # Minimize the window deterministically (ShowWindow, not a real
            # user alt-tab) - a headless/automated session cannot reliably
            # simulate stealing foreground away from an unrelated window
            # (P2's own verification notes document Windows' foreground-lock
            # -timeout silently downgrading exactly that attempt), but a
            # process minimizing its OWN just-created window is a normal,
            # always-allowed operation. This engages the full P2 background-
            # mode stack (BelowNormal+EcoQoS, CF pane suspended) - MainForm's
            # own 10-second foreground grace period, then some margin.
            Start-Sleep -Seconds 3
            $hostProc.Refresh()
            [FurphyPerfTest.User32]::ShowWindow($hostProc.MainWindowHandle, $Script:SW_MINIMIZE) | Out-Null

            # Wait for the tray's first real cycle (~90s) to finish, plus
            # margin, BEFORE measuring - see header comment.
            Start-Sleep -Seconds $Script:SettleWaitSec

            $trayStateBefore = if (Test-Path -LiteralPath $trayStatePath) { Get-Content -LiteralPath $trayStatePath -Raw } else { $null }
            $hostLogLinesBefore = if (Test-Path -LiteralPath $hostLogPath) { @(Get-Content -LiteralPath $hostLogPath).Count } else { 0 }
            $serverLogLenBefore = if (Test-Path -LiteralPath $serverLogPath) { (Get-Item -LiteralPath $serverLogPath).Length } else { 0 }

            # -ScopeRoot $root: every process this It legitimately measures
            # (fake WoW exe, server, tray, host window, its webview2
            # children) was copied/started under this It's own scratch
            # root (New-PerfAppRoot -Root $root above) - never the whole
            # shared build root, which a parallel fixer's/the verifier's
            # own concurrent scratch root elsewhere under tests\.tmp\
            # could otherwise leak into this measurement.
            $result = & (Join-Path $PSScriptRoot 'Measure-Furphy.ps1') -Label 'p3-steadystate' -DurationSec $Script:MeasureWindowSec `
                -ServerLogPath $serverLogPath -ScopeRoot $root -Quiet `
                -Notes 'P3 perf test: fake Wow.exe running, tray past its first completed cycle, host window minimized (background mode engaged). Steady-state light-touch assertion window.'

            $trayStateAfter = if (Test-Path -LiteralPath $trayStatePath) { Get-Content -LiteralPath $trayStatePath -Raw } else { $null }
            $serverLogLenAfter = if (Test-Path -LiteralPath $serverLogPath) { (Get-Item -LiteralPath $serverLogPath).Length } else { 0 }
            $newCycleStarts = Get-NewLineCountMatching -Path $hostLogPath -Pattern '\[tray\] cycle start' -SkipLines $hostLogLinesBefore

            $serverCpu = ($result.Processes | Where-Object { $_.Role -eq 'server' } | Measure-Object -Property CpuSeconds -Sum).Sum
            if (-not $serverCpu) { $serverCpu = 0 }
            $trayCpu = ($result.Processes | Where-Object { $_.Role -eq 'host-tray' } | Measure-Object -Property CpuSeconds -Sum).Sum
            if (-not $trayCpu) { $trayCpu = 0 }
            # Round 40: $result.TotalCpuSeconds already sums EVERY Furphy-
            # scoped process in the window (server+tray+host-window+every
            # webview2-child role) - the two per-role checks above never
            # covered host-window/webview2-child at all, which is exactly
            # where QA round 3's webview2-gpu-cpu-open-foreground regression
            # lived. This window is minimized (background mode engaged), so
            # webview2/CF panes are expected to be suspended - see the
            # separate 'foreground state' It below for the un-minimized case
            # that actually caught the regression.
            $totalCpu = $result.TotalCpuSeconds
            if (-not $totalCpu) { $totalCpu = 0 }

            # GAME-MODE-SPEC.md (2026-09-08): these five checks used to read
            # as "no network while WoW runs" - that gate is gone, addon
            # browsing/updates/self-update checks all run fully while WoW is
            # up now. What they actually prove, and still correctly prove,
            # is narrower and unchanged by the policy: THIS PARTICULAR
            # 90-second window sits between the tray's first completed
            # cycle (already finished, during the settle wait above) and
            # its next one (~30 minutes out, New-PerfAppRoot's
            # backgroundIntervalMinutes) - nothing is scheduled to run in
            # it, so the server/tray/SPA correctly stay quiet: zero new TCP
            # connections, zero new "[tray] cycle start" lines, tray-state.
            # json byte-identical, and only the (at most 2, POLL_GAME_MS=
            # 60000-backed) idle SPA polls' worth of log growth. A stray
            # cycle firing early, or a maintenance/catalogue/growth-crawl
            # tick landing inside this specific window, would fail these -
            # that is the real regression these guard against now, not
            # "did WoW-running block a network call."
            ($serverCpu -lt $Script:ServerCpuMaxSec) | Should Be $true
            ($trayCpu -lt $Script:TrayCpuMaxSec) | Should Be $true
            ($totalCpu -lt $Script:TotalCpuMaxSec) | Should Be $true
            ($result.TotalNewTcpConnections -le $Script:MaxNewTcpConnections) | Should Be $true
            if ($null -ne $result.RequestCountInWindow) {
                ($result.RequestCountInWindow -le $Script:MaxServerRequestsInWindow) | Should Be $true
            }
            $newCycleStarts | Should Be 0
            $trayStateAfter | Should Be $trayStateBefore
            (($serverLogLenAfter - $serverLogLenBefore) -lt $Script:MaxServerLogGrowthBytes) | Should Be $true
        } finally {
            Stop-PerfProcessQuiet -Process $hostProc
            Stop-PerfProcessQuiet -Process $trayProc
            Stop-PerfProcessQuiet -Process $fakeWow
            Start-Sleep -Milliseconds 500
            Get-Process -Name 'msedgewebview2' -ErrorAction SilentlyContinue | Where-Object {
                (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like "*$root*"
            } | Stop-Process -Force -ErrorAction SilentlyContinue
            Stop-TestServer -Server $server
        }
    }

    It 'foreground state (WoW running, host window open + focused on My Addons, no minimize): total CPU stays within tolerance' {
        <#
          Round 40 regression guard for QA-FINDINGS-LENSES-3.md's
          webview2-gpu-cpu-open-foreground (HIGH): the steady-state It above
          only ever measures the window MINIMIZED, where the existing P2
          background-mode gate already suspends the webview2/CF panes - the
          real regression (an unthrottled decorative theme animation forcing
          the compositor to keep doing full-frame-rate composite passes)
          only shows up with the window open and NOT minimized, which no
          test in this file exercised before. Deliberately mirrors this QA
          round's own repro as closely as possible: no --tray process (the
          finding's own repro didn't use one either), a short settle instead
          of the 90s+ first-cycle wait (nothing here depends on tray
          timing), --view my-addons (same view tests\perf\Run-StateD.ps1 used
          to capture the original round-25 P0-P2 baseline this compares
          against).
        #>
        if (-not (Ensure-PerfHostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }
        if (Test-RealWowClientRunning) {
            Write-Host '  (skipped: a real WoW client process is running on this machine - not launching a native FurphyHost.exe window)'
            return
        }

        $root = New-TempRoot -Name 'perf-foreground'
        New-PerfAppRoot -Root $root -Port 47899
        $wowRoot = Copy-Fixture -Destination (New-TempRoot -Name 'perf-foreground-wowroot')

        $fakeProcName = 'WowFakePerf' + (Get-Random -Maximum 99999)
        $fakeExePath = Join-Path $root ($fakeProcName + '.exe')
        Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\timeout.exe') -Destination $fakeExePath -Force

        $serverLogPath = Join-Path $root 'server.log'
        $hostExe = Join-Path $root 'host\bin\FurphyHost.exe'

        $fakeWow = $null
        $server = $null
        $hostProc = $null

        try {
            $fakeWow = Start-Process -FilePath $fakeExePath -ArgumentList @('/t', '900', '/nobreak') -WindowStyle Hidden -PassThru
            Start-Sleep -Milliseconds 500

            $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -IdleMinutes 60 -ExtraArgs @('-WowFakeProcessName', $fakeProcName)

            $hostProc = Start-Process -FilePath $hostExe -ArgumentList @('--port', '47899', '--view', 'my-addons', '--wow-fake', $fakeProcName) -PassThru

            # Wait for a real window handle rather than assuming one appears
            # - "no window can be shown" (no interactive desktop session, a
            # locked workstation, etc.) is a real possibility on some runner
            # machines and should skip cleanly, not fail/hang.
            $hwnd = [IntPtr]::Zero
            $tries = 0
            while ($hwnd -eq [IntPtr]::Zero -and $tries -lt 20) {
                Start-Sleep -Milliseconds 500
                $hostProc.Refresh()
                $hwnd = $hostProc.MainWindowHandle
                $tries++
            }
            if ($hwnd -eq [IntPtr]::Zero) {
                Write-Host '  (skipped: no window could be shown on this machine - MainWindowHandle stayed zero)'
                return
            }

            # Deliberately NOT minimized, and explicitly brought to the
            # foreground/focused - this is the exact state the finding's
            # own repro measured (state D: "Window open, My Addons, fake
            # WoW running") and the one no existing It covered.
            [FurphyPerfTest.User32]::SetForegroundWindow($hwnd) | Out-Null
            Start-Sleep -Seconds $Script:ForegroundSettleWaitSec

            # -ScopeRoot $root: same rationale as the steady-state It above
            # - fake WoW exe, server, and host window (plus its webview2
            # children) all live under this It's own scratch root.
            $result = & (Join-Path $PSScriptRoot 'Measure-Furphy.ps1') -Label 'p3-foreground' -DurationSec 60 `
                -ServerLogPath $serverLogPath -ScopeRoot $root -Quiet `
                -Notes 'P3 perf test: fake Wow.exe running, host window OPEN and FOCUSED on My Addons (no minimize, no tray). Regression guard for QA round 3 webview2-gpu-cpu-open-foreground.'

            $totalCpu = $result.TotalCpuSeconds
            if (-not $totalCpu) { $totalCpu = 0 }

            ($totalCpu -lt $Script:ForegroundTotalCpuMaxSec) | Should Be $true
        } finally {
            Stop-PerfProcessQuiet -Process $hostProc
            Stop-PerfProcessQuiet -Process $fakeWow
            Start-Sleep -Milliseconds 500
            Get-Process -Name 'msedgewebview2' -ErrorAction SilentlyContinue | Where-Object {
                (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like "*$root*"
            } | Stop-Process -Force -ErrorAction SilentlyContinue
            Stop-TestServer -Server $server
        }
    }

    It 'cycle while WoW keeps running: a --tray-selftest cycle completes normally (never skipped_wow_running) with the fake WoW process alive the whole time' {
        <#
          GAME-MODE-SPEC.md (2026-09-08), section 8: retires the old "game
          stops: normal behaviour resumes within 60s" It. That test's whole
          premise - that a fresh tray cycle needed WoW to STOP before it
          would stop being skipped - is moot now that RunCycle
          (host\FurphyHost.cs) never gates on WowDetector.IsRunning at all;
          skipped_wow_running can no longer occur regardless of WoW state,
          so "resumes once WoW stops" proves nothing a regression could
          still trip. Replaced with the policy-relevant direction instead:
          a --tray-selftest cycle completes normally WHILE the fake WoW
          process is still running for the entire run, not just started
          then stopped. Merges naturally with the inverted assertion in
          tests\host\Host.Tests.ps1's "runs the cycle normally (never
          skipped_wow_running)..." It - this one exercises the same
          contract through Perf.Tests.ps1's own New-PerfAppRoot/-wow-fake
          scaffolding (single "retail" flavour, no live install fixture)
          rather than duplicating Host.Tests.ps1's 3-flavour setup.
        #>
        if (-not (Ensure-PerfHostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $root = New-TempRoot -Name 'perf-cycle-while-running'
        New-PerfAppRoot -Root $root -Port 47899
        $wowRoot = Copy-Fixture -Destination (New-TempRoot -Name 'perf-cycle-while-running-wowroot')

        $fakeProcName = 'WowFakePerf' + (Get-Random -Maximum 99999)
        $fakeExePath = Join-Path $root ($fakeProcName + '.exe')
        Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\timeout.exe') -Destination $fakeExePath -Force

        $hostExe = Join-Path $root 'host\bin\FurphyHost.exe'

        $fakeWow = $null
        $server = $null
        $trayProc = $null

        try {
            # Long enough wait ('/t' 120) to comfortably outlast the whole
            # It, unlike the steady-state It's 900s (this one never
            # measures CPU over a wall-clock window, so no need to match
            # that budget) - kept alive for the ENTIRE cycle below, proving
            # there is no gate left to trip, not just that one happened not
            # to fire.
            $fakeWow = Start-Process -FilePath $fakeExePath -ArgumentList @('/t', '120', '/nobreak') -WindowStyle Hidden -PassThru
            Start-Sleep -Milliseconds 500
            $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -IdleMinutes 60 -ExtraArgs @('-WowFakeProcessName', $fakeProcName)

            # --tray-selftest fires RunCycle immediately (no 90s WorkerLoop
            # wait) - deterministic and fast, fake WoW process still alive
            # throughout.
            $needle = 'perfwhilerunning-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
            $markerPath = Join-Path $root ($needle + '.json')
            $selfPsi = New-Object System.Diagnostics.ProcessStartInfo
            $selfPsi.FileName = $hostExe
            $selfPsi.Arguments = '--port 47899 --tray-selftest "' + $markerPath + '" --wow-fake ' + $fakeProcName
            $selfPsi.UseShellExecute = $false
            $selfPsi.WorkingDirectory = Split-Path -Path $hostExe -Parent
            $trayProc = [System.Diagnostics.Process]::Start($selfPsi)

            $deadline = (Get-Date).AddSeconds(40)
            $marker = $null
            while ((Get-Date) -lt $deadline) {
                if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
                    try { $marker = (Get-Content -LiteralPath $markerPath -Raw) | ConvertFrom-Json; break } catch { }
                }
                Start-Sleep -Milliseconds 250
            }
            $marker | Should Not Be $null
            $marker.mutexHeld | Should Be $true
            $marker.lastResult | Should Not Be 'skipped_wow_running'
            $marker.serverStarted | Should Be $true
            @($marker.flavourJobs).Count | Should BeGreaterThan 0
        } finally {
            Stop-PerfProcessQuiet -Process $trayProc
            Stop-PerfProcessQuiet -Process $fakeWow
            Start-Sleep -Milliseconds 500
            Get-Process -Name 'msedgewebview2' -ErrorAction SilentlyContinue | Where-Object {
                (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like "*$root*"
            } | Stop-Process -Force -ErrorAction SilentlyContinue
            Stop-TestServer -Server $server
        }
    }
}
