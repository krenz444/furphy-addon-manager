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
 eyeballed - plus the -Launcher fresh-check budget.

 FULL-RUN-ONLY BY DESIGN (like fixture-acceptance/the theme audit): the
 tray's own WorkerLoop always waits ~90s before its first cycle (by
 design, unrelated to this test - see host\FurphyHost.cs's own comment on
 that constant), so this file waits for that first skip to complete
 (steady state) BEFORE measuring a clean 90-second window - the whole
 Describe costs a bit over three real wall-clock minutes even before the
 "game stops" half runs. That is well over tests\run-all.ps1 -Quick's
 <4-minute budget for the WHOLE suite, so this layer is never part of
 Quick (tests\run-all.ps1's own Quick layer list omits 'perf', same as
 'fixture-acceptance').

 WHY STEADY STATE FIRST: WorkerLoop's first RunCycle fires at t=~90s
 after the tray starts - if this file's own 90-second measurement window
 started at the same moment as the tray, the one-time first-skip
 transition (which DOES write tray-state.json and DOES log
 "[tray] cycle start" - see CompleteCycleSkippedWow's own comment: only
 the SECOND-and-later skip in the same WoW session is silent) would land
 inside the measured window, which would fail "tray-state.json unchanged"
 for a reason that has nothing to do with steady-state overhead. Waiting
 for that one transition to finish first (~100s, with margin) means the
 tray's own nextRunAtUtc is already ~10 minutes out by the time the real
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
$Script:LauncherFreshCheckMaxSec = 3     # task brief

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
'@ -ErrorAction SilentlyContinue

$Script:SW_MINIMIZE = 6
$Script:SW_RESTORE = 9

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

    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination (Join-Path $Root 'addon-sync.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1') -Destination (Join-Path $Root 'addon-server.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'ui') -Destination (Join-Path $Root 'ui') -Recurse -Force
    $binDst = Join-Path $Root 'host\bin'
    New-Item -ItemType Directory -Path $binDst -Force | Out-Null
    Get-ChildItem -LiteralPath $Script:HostBinDir -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $binDst -Recurse -Force }
    New-Item -ItemType Directory -Path (Join-Path $Root 'flavours\retail') -Force | Out-Null
    '[]' | Set-Content -LiteralPath (Join-Path $Root 'flavours\retail\addons.json') -Encoding UTF8

    $settings = [ordered]@{
        releaseType = 1; autoUpdateOnLaunch = $true; port = $Port; adFilter = $true; cfFocus = $true
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

Describe 'Perf: zero impact on gameplay (P3 automated layer)' {

    It 'steady state (WoW running, minimized window, tray past its first skip): CPU/network/log growth all stay within tolerance' {
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

            # Wait for the tray's one-time first-skip transition (~90s) to
            # finish, plus margin, BEFORE measuring - see header comment.
            Start-Sleep -Seconds $Script:SettleWaitSec

            $trayStateBefore = if (Test-Path -LiteralPath $trayStatePath) { Get-Content -LiteralPath $trayStatePath -Raw } else { $null }
            $hostLogLinesBefore = if (Test-Path -LiteralPath $hostLogPath) { @(Get-Content -LiteralPath $hostLogPath).Count } else { 0 }
            $serverLogLenBefore = if (Test-Path -LiteralPath $serverLogPath) { (Get-Item -LiteralPath $serverLogPath).Length } else { 0 }

            $result = & (Join-Path $PSScriptRoot 'Measure-Furphy.ps1') -Label 'p3-steadystate' -DurationSec $Script:MeasureWindowSec `
                -ServerLogPath $serverLogPath -Quiet `
                -Notes 'P3 perf test: fake Wow.exe running, tray past its first skip, host window minimized (background mode engaged). Steady-state zero-impact assertion window.'

            $trayStateAfter = if (Test-Path -LiteralPath $trayStatePath) { Get-Content -LiteralPath $trayStatePath -Raw } else { $null }
            $serverLogLenAfter = if (Test-Path -LiteralPath $serverLogPath) { (Get-Item -LiteralPath $serverLogPath).Length } else { 0 }
            $newCycleStarts = Get-NewLineCountMatching -Path $hostLogPath -Pattern '\[tray\] cycle start' -SkipLines $hostLogLinesBefore

            $serverCpu = ($result.Processes | Where-Object { $_.Role -eq 'server' } | Measure-Object -Property CpuSeconds -Sum).Sum
            if (-not $serverCpu) { $serverCpu = 0 }
            $trayCpu = ($result.Processes | Where-Object { $_.Role -eq 'host-tray' } | Measure-Object -Property CpuSeconds -Sum).Sum
            if (-not $trayCpu) { $trayCpu = 0 }

            ($serverCpu -lt $Script:ServerCpuMaxSec) | Should Be $true
            ($trayCpu -lt $Script:TrayCpuMaxSec) | Should Be $true
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

    It 'game stops: normal behaviour resumes within 60s (a poll reaches the server; a fresh tray cycle is not skipped)' {
        if (-not (Ensure-PerfHostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $root = New-TempRoot -Name 'perf-resume'
        New-PerfAppRoot -Root $root -Port 47899
        $wowRoot = Copy-Fixture -Destination (New-TempRoot -Name 'perf-resume-wowroot')

        $fakeProcName = 'WowFakePerf' + (Get-Random -Maximum 99999)
        $fakeExePath = Join-Path $root ($fakeProcName + '.exe')
        Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\timeout.exe') -Destination $fakeExePath -Force

        $serverLogPath = Join-Path $root 'server.log'
        $hostExe = Join-Path $root 'host\bin\FurphyHost.exe'

        $fakeWow = $null
        $server = $null
        $trayProc = $null
        $hostProc = $null

        try {
            $fakeWow = Start-Process -FilePath $fakeExePath -ArgumentList @('/t', '900', '/nobreak') -WindowStyle Hidden -PassThru
            Start-Sleep -Milliseconds 500
            $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -IdleMinutes 60 -ExtraArgs @('-WowFakeProcessName', $fakeProcName)
            $hostProc = Start-Process -FilePath $hostExe -ArgumentList @('--port', '47899', '--wow-fake', $fakeProcName) -PassThru

            Start-Sleep -Seconds 3
            $hostProc.Refresh()
            [FurphyPerfTest.User32]::ShowWindow($hostProc.MainWindowHandle, $Script:SW_MINIMIZE) | Out-Null
            Start-Sleep -Seconds 15

            # Stop WoW, then restore the window (a realistic "the player
            # alt-tabbed back to check" trigger for ExitBackgroundMode) -
            # this is the moment normal behaviour should start resuming.
            Stop-PerfProcessQuiet -Process $fakeWow
            $fakeWow = $null
            $serverLogLenAtStop = if (Test-Path -LiteralPath $serverLogPath) { (Get-Item -LiteralPath $serverLogPath).Length } else { 0 }
            $hostProc.Refresh()
            [FurphyPerfTest.User32]::ShowWindow($hostProc.MainWindowHandle, $Script:SW_RESTORE) | Out-Null

            $deadline = (Get-Date).AddSeconds($Script:ResumeTimeoutSec)
            $pollArrived = $false
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 2
                if (Test-Path -LiteralPath $serverLogPath) {
                    $lenNow = (Get-Item -LiteralPath $serverLogPath).Length
                    if ($lenNow -gt $serverLogLenAtStop) { $pollArrived = $true; break }
                }
            }
            $pollArrived | Should Be $true

            # Tray: this scenario never started a LIVE --tray (the steady-
            # state It above already covers that combination at length) -
            # rather than waiting out WorkerLoop's real 10-minute
            # nextRunAtUtc on a fresh live tray just to prove this, run one
            # --tray-selftest (RunCycle fires immediately, no 90s wait) now
            # that WoW has stopped - proves a genuinely due cycle is NOT
            # skipped once the game is gone, deterministically and fast.
            # $trayProc is still $null here (nothing to stop) - the
            # Stop-PerfProcessQuiet call in `finally` below is a no-op
            # until this line assigns the selftest process to it.
            $needle = 'perfresume-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
            $markerPath = Join-Path $root ($needle + '.json')
            $selfPsi = New-Object System.Diagnostics.ProcessStartInfo
            $selfPsi.FileName = $hostExe
            $selfPsi.Arguments = '--port 47899 --tray-selftest "' + $markerPath + '"'
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
            ($marker.lastResult -ne 'skipped_wow_running') | Should Be $true
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

    It '-Launcher with a fresh updatesCheckedAt finishes in under 3 seconds (launch-chain budget, P1 skip-if-recently-checked)' {
        # Same shape as tests\integration\Cli.InstallRollbackLauncher.Tests.ps1's
        # own "-Launcher skip-if-recently-checked" Describe (real otherwise-
        # checkable addon record on file, so the skip has to fire BEFORE any
        # per-addon path, not just "there was nothing to check anyway") -
        # this copy asserts the tighter <3s perf budget specifically,
        # instead of that Describe's own more forgiving <8s correctness bound.
        $wowRoot = Copy-Fixture
        $tempRoot = New-TempRoot -Name 'perf-launcher-budget'
        $cliPath = Join-Path $tempRoot 'addon-sync.ps1'
        Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force

        $settings = @{ releaseType = 1; autoUpdateOnLaunch = $true; port = 47831; schemaVersion = 2 }
        ConvertTo-Json -InputObject $settings -Depth 4 | Set-Content -LiteralPath (Join-Path $tempRoot 'settings.json') -Encoding UTF8

        $flavourDir = Join-Path $tempRoot 'flavours\retail'
        New-Item -ItemType Directory -Path $flavourDir -Force | Out-Null
        $record = [PSCustomObject]@{
            name = 'PerfBudgetAddon'; projectId = 424243; fileId = 1000; version = '1.0.0'
            fileName = 'PerfBudgetAddon-1.0.0.zip'
            installedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            folders = @('PerfBudgetAddon'); author = $null; ignoreUpdates = $false
            pinnedFileId = $null; releaseType = $null; previousFileId = $null; previousVersion = $null
        }
        ConvertTo-Json -InputObject @($record) -Depth 6 | Set-Content -LiteralPath (Join-Path $flavourDir 'addons.json') -Encoding UTF8

        $state = @{ updatesCheckedAt = @{ retail = (Get-Date).ToUniversalTime().AddSeconds(-30).ToString('yyyy-MM-ddTHH:mm:ssZ') } }
        ConvertTo-Json -InputObject $state -Depth 4 | Set-Content -LiteralPath (Join-Path $tempRoot 'state.json') -Encoding UTF8

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 15 -ArgumentList @(
            '-Launcher', '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot,
            '-AddonsPath', (Join-Path $wowRoot '_retail_\Interface\AddOns'))
        $sw.Stop()

        $r.ExitCode | Should Be 0
        @($r.Json.results).Count | Should Be 0
        ($sw.Elapsed.TotalSeconds -lt $Script:LauncherFreshCheckMaxSec) | Should Be $true
    }
}
