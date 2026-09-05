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
        [Parameter(Mandatory = $true)][int]$Port,
        # Round 28: the tray's "Checking addons (N of M)"/"Updating <Name>
        # (k of m)" per-addon tooltip wording (SPEC.md section B) only ever
        # renders when exactly one flavour job exists for the cycle - a
        # genuine multi-flavour cycle keeps the simpler counts-free
        # "Checking..." text, by design (out of scope this round). Passing
        # e.g. @('_retail_') strips every OTHER fixture flavour folder
        # right after the copy, before Get-InstalledFlavours ever sees this
        # root, so a test needing the per-addon wording gets a real
        # single-flavour install instead of the default 3-flavour fixture.
        # $null (the default) keeps every flavour, unchanged from before
        # this parameter existed.
        [string[]]$OnlyFlavours = $null
    )

    if (-not (Test-Path -LiteralPath (Join-Path $WowRoot '_retail_'))) {
        Copy-Fixture -Destination $WowRoot | Out-Null
        if ($OnlyFlavours) {
            foreach ($folder in @('_retail_', '_classic_', '_classic_era_', '_ptr_')) {
                if ($OnlyFlavours -notcontains $folder) {
                    $stripPath = Join-Path $WowRoot $folder
                    if (Test-Path -LiteralPath $stripPath) {
                        Remove-Item -LiteralPath $stripPath -Recurse -Force
                    }
                }
            }
        }
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

function Get-OlderCurseForgeFileId {
    <#
      Round 28: real network lookup (never hardcoded - BigWigs releases
      often enough that a hand-typed file id would go stale within days)
      of a file id for $ProjectId that is genuinely older than whatever
      the CLI's own normal (unpinned) sync would pick as "latest" right
      now - mirrors addon-sync.ps1's own Invoke-CfRequest file-list call
      (same endpoint/query, newest-first) but stops at $BackIndex entries
      back from the newest rather than index 0, so the forced-update test
      below has a real gap for the subsequent unpinned check to close.
    #>
    param(
        [Parameter(Mandatory = $true)][int64]$ProjectId,
        [int]$BackIndex = 15
    )

    $uri = "https://www.curseforge.com/api/v1/mods/$ProjectId/files?pageIndex=0&pageSize=50&sort=dateCreated&sortDescending=true"
    $resp = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ 'Referer' = 'https://www.curseforge.com/'; 'Accept' = 'application/json' } -TimeoutSec 30
    $files = @($resp.data)
    if ($files.Count -lt 2) { throw "Get-OlderCurseForgeFileId: project $ProjectId returned fewer than 2 files" }
    $idx = [Math]::Min($BackIndex, $files.Count - 1)
    return [int64]$files[$idx].id
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
        # Round 28 (SPEC.md section K, HARD RULE): --tray-selftest never
        # touches the real "FurphyAddonManager" Run value any more (a live
        # tray/install may own it) - it always registers/unregisters a
        # test-scoped "FurphyAddonManager.Test" value instead, so this is
        # the value name FurphyHost.exe itself actually writes now.
        $valueName = 'FurphyAddonManager.Test'
        $preExisting = Get-ItemProperty -LiteralPath $keyPath -Name $valueName -ErrorAction SilentlyContinue

        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exePath
            # --wow-fake with a name that cannot match a real process:
            # this test's own WoW-running check must never depend on
            # whether the machine running it happens to have a real WoW.exe
            # open (round 28 investigation: a real WoW.exe running on the
            # dev machine reproduces the exact "flavourJobs.Count is 0
            # instead of 3" symptom a prior build step flagged as an
            # unexplained pre-existing failure - RunCycle correctly takes
            # the skipped_wow_running branch and never posts any jobs at
            # all, which is not a product bug, just this test previously
            # having no --wow-fake guard against real game state).
            $psi.Arguments = '--port 47899 --tray-selftest "' + $markerPath + '" --wow-fake NoSuchFurphyHostTestProcess'
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

            # Round 28 (SPEC.md section F/J): --tray-selftest's own
            # ActivateOrLaunch(true) call never actually starts a process
            # (dryRun) - with no real "Furphy Addon Manager"-titled window
            # anywhere on this machine, the only possible outcome is
            # "launch" (an "activate:foreground"/"activate:flashed" value
            # would mean this run somehow found and clicked a REAL live
            # window, which must never happen from a test).
            $marker.clickOutcome | Should Be 'launch'

            # Round 28: a genuine 3-flavour cycle has no single-job n-of-N
            # counts to show (SPEC.md section B's own multi-flavour carve-
            # out) - the tooltip history for THIS shape stays the simple,
            # counts-free "Starting the updater..." -> a done_* state, and
            # must never show the old incident's "Updating 34 of 34"-style
            # text for a plain check.
            $tooltipHistory = @($marker.tooltipHistory)
            $tooltipHistory.Count | Should BeGreaterThan 0
            (@($tooltipHistory | Where-Object { $_ -match 'Updating \d+ of \d+' }).Count) | Should Be 0

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

Describe 'Host --tray-selftest (tray) - single-flavour tooltip/icon/balloon history (Round 28)' -Tags 'Host', 'Network' {
    # Round 28 (SPEC.md section B/J): the per-addon "Checking addons
    # (N of M)"/"Updating <Name> (k of m)" tooltip wording only ever
    # renders for a SINGLE-flavour cycle (a genuine multi-flavour cycle
    # keeps the simpler counts-free text, by design - see the Describe
    # above's own "runs a real cycle" It) - so both Its here build a
    # retail-ONLY root (New-TrayTestLayout -OnlyFlavours '_retail_')
    # rather than reusing the default 3-flavour fixture.
    #
    # DEVIATION FROM SPEC.md's OWN WORDING, found while implementing this:
    # SPEC.md section J describes the "nothing to update" case as
    # "today's existing scratch fixture, zero tracked addons" - but with
    # truly zero addons.json records, addon-sync.ps1's main loop's own
    # Write-ProgressStep('queued', Total=$toSync.Count) writes {total:0}
    # ONCE and the per-addon loop body never runs at all (see addon-
    # sync.ps1 ~line 5064) - so "Checking addons (" (which needs total>0)
    # can NEVER appear for a zero-addon cycle; ComputeCore's own
    # total<=0 branch ("Starting the updater...") is what actually shows
    # instead, the whole time. Confirmed against B2's own manual
    # verification notes (STATE TABLE), which used 2 REAL tracked addons
    # for exactly this reason, not zero. Both Its below follow that same,
    # actually-correct shape (one real tracked addon) rather than the
    # zero-addon text in SPEC.md section J, which does not match the
    # implemented behaviour.
    $projectId = 2382 # BigWigs - retail-compatible, already used by
                       # tests\perf\Setup-Baseline.ps1/Perf.Tests.ps1.

    It 'a real single-flavour check with nothing to update: tooltipHistory shows "Checking addons (" then ends "Everything''s up to date", never "Updating"' {
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $wowRoot = New-TempRoot -Name 'host-tray-single-clean'
        $addonSyncDir = New-TrayTestLayout -WowRoot $wowRoot -Port 47899 -OnlyFlavours @('_retail_')
        $cliPath = Join-Path $addonSyncDir 'addon-sync.ps1'
        $exePath = Join-Path $addonSyncDir 'host\bin\FurphyHost.exe'
        $needle = 'trayclean-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $markerPath = Join-Path $addonSyncDir ($needle + '.json')
        $hostProc = $null

        try {
            # Real network install (latest compatible file) - this addon
            # is then genuinely up to date the moment the cycle checks it
            # again a few seconds later.
            $addResult = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 90 -ArgumentList @(
                '-Add', $projectId, '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot)
            $addResult.ExitCode | Should Be 0
            $addedRow = @($addResult.Json.results) | Where-Object { [string]$_.projectId -eq [string]$projectId }
            @($addedRow).Count | Should Be 1
            $addedRow[0].status | Should Be 'Installed'

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exePath
            $psi.Arguments = '--port 47899 --tray-selftest "' + $markerPath + '" --wow-fake NoSuchFurphyHostTestProcess'
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path -Path $exePath -Parent
            $hostProc = [System.Diagnostics.Process]::Start($psi)

            $marker = Wait-MarkerFile -Path $markerPath -TimeoutSec 60
            $marker | Should Not Be $null
            [int]$marker.exitCode | Should Be 0

            $flavourJobs = @($marker.flavourJobs)
            $flavourJobs.Count | Should Be 1
            $flavourJobs[0].flavour | Should Be 'retail'

            $tooltipHistory = @($marker.tooltipHistory)
            (@($tooltipHistory | Where-Object { $_ -match 'Checking addons \(' }).Count) | Should BeGreaterThan 0
            $tooltipHistory[$tooltipHistory.Count - 1] | Should Match 'Everything.s up to date'
            (@($tooltipHistory | Where-Object { $_ -match 'Updating' }).Count) | Should Be 0

            $marker.balloonShown | Should Be $false
            $marker.clickOutcome | Should Be 'launch'

            Wait-ProcessExit -Process $hostProc -TimeoutSec 15 | Should Be $true
        } finally {
            if ($hostProc -and -not $hostProc.HasExited) { try { $hostProc.Kill() } catch { } }
            Stop-Straggler-FurphyHost -Needle $needle
            try {
                Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -like ('*' + $addonSyncDir + '*addon-server.ps1*') } |
                    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
            } catch { }
        }
    }

    It 'a real single-flavour forced-update cycle: tooltipHistory shows "Updating <Name> (1 of 1" then ends "Updated 1 at", balloon names it' {
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $wowRoot = New-TempRoot -Name 'host-tray-single-update'
        $addonSyncDir = New-TrayTestLayout -WowRoot $wowRoot -Port 47899 -OnlyFlavours @('_retail_')
        $cliPath = Join-Path $addonSyncDir 'addon-sync.ps1'
        $exePath = Join-Path $addonSyncDir 'host\bin\FurphyHost.exe'
        $needle = 'trayupdate-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $markerPath = Join-Path $addonSyncDir ($needle + '.json')
        $hostProc = $null

        try {
            # Install an OLDER real file explicitly (-FileId pins the
            # record to it), then -Unpin so the next, unforced check is
            # free to find and install whatever is actually newest.
            $olderFileId = Get-OlderCurseForgeFileId -ProjectId $projectId -BackIndex 15
            $addResult = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 90 -ArgumentList @(
                '-Add', $projectId, '-FileId', $olderFileId, '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot)
            $addResult.ExitCode | Should Be 0
            $addedRow = @($addResult.Json.results) | Where-Object { [string]$_.projectId -eq [string]$projectId }
            @($addedRow).Count | Should Be 1
            $addedRow[0].status | Should Be 'Installed'
            [int64]$addedRow[0].fileId | Should Be $olderFileId
            $addonName = [string]$addedRow[0].name

            $unpinResult = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 30 -ArgumentList @(
                '-Unpin', $projectId, '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot)
            $unpinResult.ExitCode | Should Be 0
            $unpinRow = @($unpinResult.Json.results) | Where-Object { [string]$_.projectId -eq [string]$projectId }
            @($unpinRow).Count | Should Be 1
            $unpinRow[0].status | Should Be 'Unpinned'

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exePath
            $psi.Arguments = '--port 47899 --tray-selftest "' + $markerPath + '" --wow-fake NoSuchFurphyHostTestProcess'
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path -Path $exePath -Parent
            $hostProc = [System.Diagnostics.Process]::Start($psi)

            $marker = Wait-MarkerFile -Path $markerPath -TimeoutSec 60
            $marker | Should Not Be $null
            [int]$marker.exitCode | Should Be 0

            $flavourJobs = @($marker.flavourJobs)
            $flavourJobs.Count | Should Be 1
            $flavourJobs[0].flavour | Should Be 'retail'
            @($flavourJobs[0].updatedNames) -contains $addonName | Should Be $true

            $tooltipHistory = @($marker.tooltipHistory)
            $updatingPattern = 'Updating ' + [regex]::Escape($addonName) + ' \(1 of 1'
            (@($tooltipHistory | Where-Object { $_ -match $updatingPattern }).Count) | Should BeGreaterThan 0
            $tooltipHistory[$tooltipHistory.Count - 1] | Should Match 'Updated 1 at'

            $marker.balloonShown | Should Be $true
            [string]$marker.balloonText | Should Match ([regex]::Escape($addonName))
            $marker.clickOutcome | Should Be 'launch'

            Wait-ProcessExit -Process $hostProc -TimeoutSec 15 | Should Be $true
        } finally {
            if ($hostProc -and -not $hostProc.HasExited) { try { $hostProc.Kill() } catch { } }
            Stop-Straggler-FurphyHost -Needle $needle
            try {
                Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -like ('*' + $addonSyncDir + '*addon-server.ps1*') } |
                    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
            } catch { }
        }
    }
}

Remove-TempRoots
