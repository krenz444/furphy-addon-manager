<#
=====================================================================
 tests\host\Host.Tests.ps1

 T3 (host layer): host\FurphyHost.exe's --selftest (main window) and
 --tray-selftest (tray) self-test markers. Both are existing, designed
 features of the exe itself (see FurphyHost.cs's own header comments on
 RunSelftestSequence/WriteSelftestMarker) - this file drives them for
 real against a REAL FurphyHost.exe process and asserts on the JSON
 marker each one writes, never a fake/mocked host.

 Never touches port 47831, the real WoW folder, the real Desktop, or a
 real HKCU Run value outside its own copied test root (the tray test
 registers/unregisters against the REAL HKCU Run key by design - this
 mirrors what the exe itself does with -Enable/-Disable elsewhere - but
 always removes it in a finally block and asserts it is gone afterward,
 same contract as tests\integration\Server.Tray.Tests.ps1's own
 server-side tray test).

 Builds host\bin\FurphyHost.exe first if missing or stale relative to
 host\FurphyHost.cs (build-host.ps1), so this file works on a clean
 checkout with no manual build step.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:HostExePath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'host\bin\FurphyHost.exe'
$Script:HostCsPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'host\FurphyHost.cs'
$Script:HostBinDir = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'host\bin'

function Ensure-HostBuilt {
    <# Compiles host\bin\FurphyHost.exe if missing, or older than FurphyHost.cs. #>
    $needsBuild = $false
    if (-not (Test-Path -LiteralPath $Script:HostExePath -PathType Leaf)) {
        $needsBuild = $true
    } elseif ((Get-Item -LiteralPath $Script:HostCsPath).LastWriteTimeUtc -gt (Get-Item -LiteralPath $Script:HostExePath).LastWriteTimeUtc) {
        $needsBuild = $true
    }
    if ($needsBuild) {
        Write-Host '  (building host\bin\FurphyHost.exe - missing or stale)'
        $buildScript = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'host\build-host.ps1'
        & $buildScript
    }
    return (Test-Path -LiteralPath $Script:HostExePath -PathType Leaf)
}

function Wait-MarkerFile {
    param([string]$Path, [int]$TimeoutSec = 40)

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            # Written via temp-file + File.Move (atomic rename) by the host
            # itself - existence implies a complete write, but give one
            # extra short pause + retry-on-parse-failure belt-and-suspenders
            # in case a reader catches it mid-rename on a slow disk.
            for ($attempt = 0; $attempt -lt 5; $attempt++) {
                try {
                    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
                    return ($raw | ConvertFrom-Json)
                } catch {
                    Start-Sleep -Milliseconds 200
                }
            }
        }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

function Wait-ProcessExit {
    param([System.Diagnostics.Process]$Process, [int]$TimeoutSec = 15)

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { if ($Process.HasExited) { return $true } } catch { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function New-TrayTestLayout {
    <#
      Builds (idempotently - safe to call more than once against the same
      -WowRoot) the production-shaped layout --tray-selftest's own
      auto-start/WoW-root-detection code needs:

        <WowRoot>\_retail_\..._ptr_\      the FLAVORS-SPEC.md section 8
                                          fixture (retail/classic/
                                          classic_era/ptr), copied once
        <WowRoot>\_retail_\AddonSync\     addon-server.ps1/addon-sync.ps1/
                                          ui\/settings.json/host\bin\ -
                                          "AddonSync" is a literal,
                                          case-sensitive-by-convention leaf
                                          name Resolve-EffectiveAddonsPath's
                                          own walk-up looks for (see
                                          addon-server.ps1's
                                          Get-InstalledFlavours doc
                                          comment) - its own parent
                                          (_retail_) must be a known
                                          flavour folder for the walk-up to
                                          fire, which is why the fixture
                                          copy happens at -WowRoot's own
                                          root, one level up.

      settings.json is pre-seeded with port 47899 (never 47831 -
      Get-DefaultSettings' own default) BEFORE addon-server.ps1 ever runs
      (self-started by --tray-selftest's own TryStartServer, which never
      forwards -Port) and showTestRealms explicitly false, so ptr is
      excluded from the update-all-flavours fan-out exactly like a fresh
      real install.

      Returns the AddonSync directory path.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$WowRoot,
        [Parameter(Mandatory = $true)][int]$Port
    )

    if (-not (Test-Path -LiteralPath (Join-Path $WowRoot '_retail_'))) {
        Copy-Fixture -Destination $WowRoot | Out-Null
    }

    $addonSyncDir = Join-Path -Path $WowRoot -ChildPath '_retail_\AddonSync'
    if (-not (Test-Path -LiteralPath $addonSyncDir)) {
        New-Item -ItemType Directory -Path $addonSyncDir -Force | Out-Null
    }

    foreach ($pair in @(
        @{ Src = 'addon-server.ps1'; Dst = 'addon-server.ps1' }
        @{ Src = 'addon-sync.ps1'; Dst = 'addon-sync.ps1' }
    )) {
        $dstPath = Join-Path $addonSyncDir $pair.Dst
        if (-not (Test-Path -LiteralPath $dstPath)) {
            Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot $pair.Src) -Destination $dstPath -Force
        }
    }
    $uiDst = Join-Path $addonSyncDir 'ui'
    if (-not (Test-Path -LiteralPath $uiDst)) {
        Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'ui') -Destination $uiDst -Recurse -Force
    }
    $binDst = Join-Path $addonSyncDir 'host\bin'
    if (-not (Test-Path -LiteralPath $binDst)) {
        Copy-Item -LiteralPath $Script:HostBinDir -Destination $binDst -Recurse -Force
    }

    $settingsPath = Join-Path $addonSyncDir 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        $settings = [ordered]@{
            releaseType               = 1
            autoUpdateOnLaunch        = $true
            port                      = $Port
            adFilter                  = $true
            cfFocus                   = $true
            hostWindow                = $null
            hostTheme                 = $null
            backgroundUpdates         = $false
            backgroundIntervalMinutes = 120
            runAtStartup              = $false
            schemaVersion             = 2
            activeFlavour             = 'retail'
            showTestRealms            = $false
        }
        ($settings | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    }

    return $addonSyncDir
}

function Stop-Straggler-FurphyHost {
    <# Hard-kills any FurphyHost.exe whose command line names $MarkerNeedle (a marker path fragment unique to this test run), belt-and-suspenders cleanup. #>
    param([string]$Needle)

    try {
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'FurphyHost.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like ('*' + $Needle + '*') }
        foreach ($p in @($procs)) {
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
    } catch { }
}

Describe 'Host --selftest (main window)' -Tags 'Host', 'Network' {
    # T4: tagged 'Network' in addition to 'Host' (T3 left it untagged and
    # flagged this exact choice as open) so tests\run-all.ps1 -NoNetwork /
    # -Quick can skip it - the CF pane genuinely navigates to
    # www.curseforge.com. Every other Host.Tests.ps1 Describe (the two
    # --tray-selftest Its) stays 'Host'-only: fully offline/deterministic.
    It 'writes a marker with init/dpiAware/cf-pane/deep-link fields, real screenshot' {
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $root = New-TempRoot -Name 'host-window-selftest'
        $server = $null
        $hostProc = $null
        $needle = 'winmarker-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $markerPath = Join-Path -Path $root -ChildPath ($needle + '.json')

        try {
            # Start-TestServer copies ui\ + addon-sync.ps1 in and creates a
            # default settings.json (port 47899, never 47831) - see
            # tests\lib\common.ps1. host\selftest.html is copied alongside
            # ui\ so addon-server.ps1's own static-file route serves it at
            # /selftest.html, same origin as the API it will POST /api/jobs
            # against (the exe's own Referer check needs same-origin).
            $server = Start-TestServer -Root $root -Port 47899
            Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'host\selftest.html') -Destination (Join-Path $root 'ui\selftest.html') -Force

            # Run the exe from a COPY of host\bin (never the real build-root
            # copy) so HostFiles.FindUpward's settings.json/VERSION reads
            # land on this test's own throwaway settings.json, never the
            # real one - the host never writes settings.json during
            # --selftest (persist is explicitly suppressed - see
            # FurphyHost.cs's own comment on that), but this keeps every
            # read isolated too, and keeps host.log/capture output inside
            # tests\.tmp\ instead of the real build root.
            Copy-Item -LiteralPath $Script:HostBinDir -Destination (Join-Path $root 'host\bin') -Recurse -Force
            Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'VERSION') -Destination (Join-Path $root 'VERSION') -Force -ErrorAction SilentlyContinue
            $exeCopyPath = Join-Path $root 'host\bin\FurphyHost.exe'

            # Wipe any stale WebView2 user-data folder next to the exe
            # copy before running - defensive, per the task brief (a
            # previous crashed run could leave a locked profile behind).
            $webview2Dir = $exeCopyPath + '.WebView2'
            if (Test-Path -LiteralPath $webview2Dir) {
                Remove-Item -LiteralPath $webview2Dir -Recurse -Force -ErrorAction SilentlyContinue
            }

            $selftestUrl = 'http://localhost:47899/selftest.html'
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exeCopyPath
            $psi.Arguments = '--port 47899 --selftest "' + $markerPath + '" "' + $selftestUrl + '"'
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path -Path $exeCopyPath -Parent
            $hostProc = [System.Diagnostics.Process]::Start($psi)

            # The exe's own selftest timeline writes the marker at ~8s
            # (SelftestTimer, 8000ms interval) - see FurphyHost.cs.
            $marker = Wait-MarkerFile -Path $markerPath -TimeoutSec 40
            $marker | Should Not Be $null

            $marker.init | Should Be $true
            ($marker.dpiAware -is [bool]) | Should Be $true
            $marker.dpiAware | Should Be $true
            $marker.hostReadySent | Should Be $true
            [int]$marker.cfShowCount | Should BeGreaterThan 1
            [int]$marker.cfHideCount | Should BeGreaterThan 0
            $marker.cfPaneVisible | Should Be $true
            [int]$marker.cfStateMessages | Should BeGreaterThan 0
            $marker.cfFocusEnabled | Should Be $true

            # KNOWN FINDING (reproduced 3/3 runs on this machine, real
            # network to www.curseforge.com, not a flaky/environment
            # fluke): EnsureSelftestDeepLinkInjection fires its fake
            # curseforge://install link exactly 2000ms after the CF pane's
            # document is created (host\FurphyHost.cs), which lands almost
            # exactly on top of selftest.html's own cf-hide at t=3000ms
            # (itself ~2000ms after the same cf-show that creates that
            # document) - hiding the pane (_cfWebView.Visible = false)
            # appears to suspend/throttle the pending WebView2 page timer
            # badly enough that it never fires again before the marker is
            # written at t=8000ms, even though the pane is shown again at
            # t=4000ms (host.log shows the second cf-show, but
            # intercepted/jobPostStatus stay empty/null every time). This
            # is pre-existing production code, not something this
            # tests-only step is scoped to fix (same convention as T1's
            # cache/ .gitignore gap and T2's Update-JobStatus gap) - kept
            # as a hard assertion, not softened, so this stays visibly RED
            # until it is either fixed (give the fake link more slack
            # before selftest.html's own hide, or run
            # AddScriptToExecuteOnDocumentCreatedAsync's callback while
            # hidden) or someone deliberately re-scopes this assertion.
            $intercepted = @($marker.intercepted)
            $sawDeepLink = @($intercepted | Where-Object { $_ -match 'curseforge://install' -and $_ -match 'addonId=999999001' }).Count -gt 0
            $sawDeepLink | Should Be $true

            $marker.jobPostStatus | Should Be 202

            $marker.capturePath | Should Not Be $null
            (Test-Path -LiteralPath $marker.capturePath -PathType Leaf) | Should Be $true
            # A real PNG, not an empty/placeholder file.
            (Get-Item -LiteralPath $marker.capturePath).Length | Should BeGreaterThan 100

            Wait-ProcessExit -Process $hostProc -TimeoutSec 15 | Should Be $true
        } finally {
            if ($hostProc -and -not $hostProc.HasExited) {
                try { $hostProc.Kill() } catch { }
            }
            Stop-Straggler-FurphyHost -Needle $needle
            Stop-TestServer -Server $server
        }
    }
}

Describe 'Host --tray-selftest (tray)' -Tags 'Host' {
    $root = New-TempRoot -Name 'host-tray-selftest'
    $wowFakeProc = $null

    It 'skips the cycle with skipped_wow_running when --wow-fake matches a real running process' {
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $addonSyncDir = New-TrayTestLayout -WowRoot $root -Port 47899
        $exePath = Join-Path $addonSyncDir 'host\bin\FurphyHost.exe'
        $needle = 'traywow-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $markerPath = Join-Path $addonSyncDir ($needle + '.json')
        $fakeProcessName = 'WowFakeSelftest'
        $fakeExePath = Join-Path $addonSyncDir ($fakeProcessName + '.exe')
        $hostProc = $null

        try {
            # A real, harmless, long-running process under a fake WoW
            # client name - a renamed copy of the in-box timeout.exe,
            # given a long wait so it is still alive for the whole test.
            Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\timeout.exe') -Destination $fakeExePath -Force
            $wowFakeProc = Start-Process -FilePath $fakeExePath -ArgumentList @('/t', '120', '/nobreak') -WindowStyle Hidden -PassThru

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exePath
            $psi.Arguments = '--port 47899 --tray-selftest "' + $markerPath + '" --wow-fake ' + $fakeProcessName
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path -Path $exePath -Parent
            $hostProc = [System.Diagnostics.Process]::Start($psi)

            $marker = Wait-MarkerFile -Path $markerPath -TimeoutSec 40
            $marker | Should Not Be $null

            $marker.lastResult | Should Be 'skipped_wow_running'
            $marker.serverStarted | Should Be $false
            @($marker.flavourJobs).Count | Should Be 0
            [int]$marker.exitCode | Should Be 0
            $marker.mutexHeld | Should Be $true

            Wait-ProcessExit -Process $hostProc -TimeoutSec 15 | Should Be $true
        } finally {
            if ($hostProc -and -not $hostProc.HasExited) { try { $hostProc.Kill() } catch { } }
            if ($wowFakeProc -and -not $wowFakeProc.HasExited) { try { Stop-Process -Id $wowFakeProc.Id -Force -ErrorAction SilentlyContinue } catch { } }
            Stop-Straggler-FurphyHost -Needle $needle
        }
    }

    It 'runs a real cycle: one flavourJobs entry per installed first-class flavour, icon shown, Run value written then removed and absent afterward' {
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $addonSyncDir = New-TrayTestLayout -WowRoot $root -Port 47899
        $exePath = Join-Path $addonSyncDir 'host\bin\FurphyHost.exe'
        $needle = 'traynorm-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $markerPath = Join-Path $addonSyncDir ($needle + '.json')
        $hostProc = $null
        $keyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $valueName = 'FurphyAddonManager'
        $preExisting = Get-ItemProperty -LiteralPath $keyPath -Name $valueName -ErrorAction SilentlyContinue

        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exePath
            $psi.Arguments = '--port 47899 --tray-selftest "' + $markerPath + '"'
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path -Path $exePath -Parent
            $hostProc = [System.Diagnostics.Process]::Start($psi)

            # A real cycle: self-starts addon-server.ps1, fans out one sync
            # job per non-hidden installed flavour against the fixture (zero
            # tracked addons -> fast, fully offline), polls to completion,
            # then the register/unregister startup sequence. Generous
            # timeout - covers server cold-start + 3 sync jobs.
            $marker = Wait-MarkerFile -Path $markerPath -TimeoutSec 60
            $marker | Should Not Be $null

            $marker.iconShown | Should Be $true
            [int]$marker.exitCode | Should Be 0
            $marker.mutexHeld | Should Be $true

            # FLAVORS-SPEC.md section 2.1: retail/classic/classic_era are
            # first-class (ptr is detected but hidden by default -
            # showTestRealms is false in this test's own settings.json).
            $flavourJobs = @($marker.flavourJobs)
            $flavourJobs.Count | Should Be 3
            $flavourIds = @($flavourJobs | ForEach-Object { $_.flavour }) | Sort-Object
            (@($flavourIds) -join ',') | Should Be 'classic,classic_era,retail'

            $expectedRunValue = '"' + $exePath + '" --tray'
            $marker.runValueWritten | Should Be $expectedRunValue
            $marker.runValueRemoved | Should Be $true

            Wait-ProcessExit -Process $hostProc -TimeoutSec 15 | Should Be $true

            # Real registry check, independent of the marker's own claim.
            $prop = Get-ItemProperty -LiteralPath $keyPath -Name $valueName -ErrorAction SilentlyContinue
            $prop | Should Be $null
        } finally {
            if ($hostProc -and -not $hostProc.HasExited) { try { $hostProc.Kill() } catch { } }
            Stop-Straggler-FurphyHost -Needle $needle
            # Belt-and-suspenders: never leave a Run value behind, and never
            # remove one that predates this test (shouldn't exist on a dev
            # machine, but this test must not be the reason it's gone).
            try {
                $leftover = Get-ItemProperty -LiteralPath $keyPath -Name $valueName -ErrorAction SilentlyContinue
                if ($leftover -and -not $preExisting) {
                    Remove-ItemProperty -LiteralPath $keyPath -Name $valueName -ErrorAction SilentlyContinue
                }
            } catch { }
            # Any orphaned self-started addon-server.ps1 for this cycle.
            try {
                Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -like ('*' + $addonSyncDir + '*addon-server.ps1*') } |
                    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
            } catch { }
        }
    }
}

Remove-TempRoots
