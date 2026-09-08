<#
=====================================================================
 tests\integration\Server.Uninstall.Tests.ps1

 DISTRIBUTION-SPEC.md section 3.4/5.3: end-to-end POST /api/uninstall
 against a REAL scratch install and a REAL scratch addon-server.ps1 on
 port 47899 - covers the converging uninstall mechanism's server-driven
 leg (Settings' own button, and the tray's "server reachable" branch, both
 post to this exact route).

 SAFETY, read before touching this file (see the build root's own HARD
 RULES): every install/uninstall this file exercises runs against a
 SCRATCH COPY of fixtures\wowroot under tests\.tmp\ (via Copy-Fixture),
 with -NoShortcuts -NoProtocol always passed (through the request body's
 noShortcuts/noProtocol fields - see Handle-Uninstall's own doc comment
 for why those exist at all), and the scratch settings.json is pre-seeded
 with "port": 47899 BEFORE install.ps1 ever runs, so the scratch server
 this file starts is never anywhere near port 47831. install.ps1 always
 runs with -Console (never -NoConsole's opposite - the WinForms wizard
 would call ShowDialog() and hang forever headless with nothing to
 click). This file snapshots the REAL production Run value, the REAL
 Installed-Apps key, and any REAL live tray pid(s) BEFORE and AFTER every
 test and asserts they are byte-identical - this is the live-safety
 regression test for the exact incident DISTRIBUTION-SPEC.md section 0
 documents (2026-09-06 14:45, a scratch -Uninstall run that hit the real
 Run value and the real tray before fixes 1/3 landed).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Get-ProductionRunValue {
    <# The REAL HKCU Run value's string content, or $null if absent. Never
       writes anything - read-only snapshot for a before/after comparison. #>
    try {
        $prop = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'FurphyAddonManager' -ErrorAction SilentlyContinue
        if ($null -eq $prop) { return $null }
        return [string]$prop.FurphyAddonManager
    } catch {
        return $null
    }
}

function Get-ProductionInstalledAppsSnapshot {
    <# The REAL Installed-Apps key's meaningful fields, or $null if the key
       does not exist. Read-only. #>
    try {
        $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FurphyAddonManager'
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        $p = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
        return [PSCustomObject]@{
            DisplayName          = [string]$p.DisplayName
            DisplayVersion       = [string]$p.DisplayVersion
            Publisher            = [string]$p.Publisher
            InstallLocation      = [string]$p.InstallLocation
            DisplayIcon          = [string]$p.DisplayIcon
            UninstallString      = [string]$p.UninstallString
            QuietUninstallString = [string]$p.QuietUninstallString
        }
    } catch {
        return $null
    }
}

function Get-LiveFurphyTrayPids {
    <#
      Every REAL, LIVE-PRODUCTION FurphyHost.exe --tray process's pid,
      sorted - i.e. its ExecutablePath is under Program Files AND it was
      NOT started with a test port (--port 4789x). Still the live-safety
      check (it must notice a PRODUCTION tray this file might have
      accidentally affected), but a TEST-scoped tray legitimately starts
      and stops on its own schedule across this suite's other files
      (Server.Tray.Tests.ps1, Server.TrayStopScope.Tests.ps1) with no
      relationship to this file's own before/after window - counting one
      here turns unrelated timing into a false live-safety violation.
      Mirrors tests\run-all.ps1's own Invoke-HygieneSweep production/test
      split exactly (same two conditions, same reasoning).
    #>
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'FurphyHost.exe'" -ErrorAction SilentlyContinue
        $found = New-Object 'System.Collections.Generic.List[int]'
        foreach ($p in @($procs)) {
            $cl = [string]$p.CommandLine
            $ep = [string]$p.ExecutablePath
            if (-not ($cl -and ($cl -match '(^|\s)--tray(\s|$)'))) { continue }
            $isTestPort = $cl -match '--port\s+4789\d'
            $isProdPath = $ep -and ($ep -like '*\Program Files*')
            if ($isProdPath -and -not $isTestPort) { $found.Add([int]$p.ProcessId) }
        }
        return @($found | Sort-Object)
    } catch {
        return @()
    }
}

function New-ScratchInstall {
    <#
      Copies fixtures\wowroot into a fresh scratch root, pre-seeds
      _retail_\AddonSync\settings.json with "port": 47899 (so the install
      never defaults to writing the production port - hard rule), then
      runs install.ps1 -WowPath <scratch> -NoShortcuts -NoProtocol
      -Console (forces the console flow - a headless wizard would hang).
      Returns @{ WowRoot; AppDest; ExitCode }.
    #>
    $wowRoot = Copy-Fixture -Destination (New-TempRoot -Name 'uninstall-wowroot')
    $appDest = Join-Path -Path $wowRoot -ChildPath '_retail_\AddonSync'
    New-Item -ItemType Directory -Path $appDest -Force | Out-Null
    '{ "releaseType": 1, "port": 47899 }' |
        Set-Content -LiteralPath (Join-Path $appDest 'settings.json') -Encoding Ascii

    $installScript = Join-Path -Path $Script:FurphyBuildRoot 'install.ps1'
    $r = Invoke-CliProcess -ScriptPath $installScript -ArgumentList @('-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-Console') -TimeoutSec 120

    return [PSCustomObject]@{ WowRoot = $wowRoot; AppDest = $appDest; ExitCode = $r.ExitCode; StdOut = $r.StdOut; StdErr = $r.StdErr }
}

function Wait-ForCondition {
    param([scriptblock]$Condition, [int]$TimeoutSec = 30, [int]$PollMs = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds $PollMs
    }
    return (& $Condition)
}

# ---------------------------------------------------------------------
# Round 33 defect regression - real host WINDOW scenario support.
# Mirrors install.ps1's own Initialize-InstallWin32Type/FindWindow use
# (Get-InstallWindowTitle/Close-InstallMainWindow) so this file can prove
# the window is actually open, then actually gone, independent of the
# fix's own internal claims - a fresh, test-scoped type name so it can
# never collide with anything install.ps1 itself loads into this same
# process (this file never dot-sources install.ps1, so there is no
# actual collision risk today, but the distinct name keeps that true even
# if a future change makes them share a process).
# ---------------------------------------------------------------------
$Script:FurphyUninstallTestWin32Loaded = $false
function Initialize-UninstallTestWin32Type {
    if ($Script:FurphyUninstallTestWin32Loaded) { return }
    if (-not ('FurphyUninstallTest.Win32' -as [type])) {
        Add-Type -Namespace FurphyUninstallTest -Name Win32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);
'@
    }
    $Script:FurphyUninstallTestWin32Loaded = $true
}

function Test-FurphyWindowOpen {
    <# $true if a top-level window with exactly this title exists right now. #>
    param([string]$Title)
    Initialize-UninstallTestWin32Type
    $hwnd = [FurphyUninstallTest.Win32]::FindWindow([NullString]::Value, $Title)
    return ($hwnd -ne [IntPtr]::Zero)
}

function Get-FurphyWebView2ChildrenUnder {
    <# Every live msedgewebview2.exe process whose own command line names
       $AppDestNorm (lowercased, matches install.ps1's own Wait-
       InstallHostAndWebView2Exit matching) - independent proof that the
       fix's own claim ("its WebView2 children are gone too") actually
       holds, not just that FurphyHost.exe itself exited. #>
    param([string]$AppDestNorm)
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue
    } catch {
        return @()
    }
    return @($procs | Where-Object { $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains($AppDestNorm) })
}

Describe 'POST /api/uninstall - end to end against a real scratch install and scratch server (port 47899 only)' {

    It 'uninstalls the scratch app cleanly (keep-list preserved), shuts the scratch server down, removes the scratch Installed-Apps test key, and leaves the REAL production Run value / Installed-Apps key / tray pids byte-identical before and after' {

        # ---- live-safety snapshot BEFORE ----
        $runBefore = Get-ProductionRunValue
        $appsBefore = Get-ProductionInstalledAppsSnapshot
        $trayPidsBefore = Get-LiveFurphyTrayPids
        Write-Host "  [live-safety BEFORE] Run value present: $([bool]$runBefore) | Installed-Apps key present: $([bool]$appsBefore) | live tray pids: $($trayPidsBefore -join ',')"

        $installed = New-ScratchInstall
        $installed.ExitCode | Should Be 0
        (Test-Path -LiteralPath $installed.AppDest) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $installed.AppDest 'addon-server.ps1')) | Should Be $true

        $appsKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FurphyAddonManager.Test'
        (Test-Path -LiteralPath $appsKeyPath) | Should Be $true

        $server = $null
        try {
            $server = Start-TestServer -Root $installed.AppDest -Port 47899 -ScriptPath (Join-Path $installed.AppDest 'addon-server.ps1')

            # Section 5.4/2.2's own semantics: -NoShortcuts/-NoProtocol are
            # never sent by the real UI, but every -Uninstall exercised by
            # this test suite must pass them (hard rule) - Handle-Uninstall
            # accepts them in the JSON body for exactly this reason. quiet
            # (Round 33 defect fix) is the same shape for the new result
            # MessageBox install.ps1 -Uninstall now shows by default - this
            # detached, unattended run must never block forever on
            # MessageBox.Show waiting for a click that will never come.
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/uninstall' -Body @{ noShortcuts = $true; noProtocol = $true; quiet = $true }
            $r.Ok | Should Be $true
            $r.StatusCode | Should Be 200
            $r.Body.ok | Should Be $true

            # The server answers 200 THEN sets $Script:ShuttingDown - the
            # existing main loop polls that and exits, freeing the port.
            $serverDown = Wait-ForCondition -TimeoutSec 20 -Condition { -not (Test-PortOpen -Port 47899 -TimeoutMs 300) }
            $serverDown | Should Be $true

            # The actual file removal happens in a DETACHED temp-copy
            # process Handle-Uninstall launched and does not wait for -
            # poll for it to finish (bounded, since a real scratch
            # uninstall with no locked files completes in well under this).
            $cleaned = Wait-ForCondition -TimeoutSec 30 -Condition {
                -not (Test-Path -LiteralPath (Join-Path $installed.AppDest 'install.ps1'))
            }
            $cleaned | Should Be $true
            # Give the spawned copy a brief moment past that to also finish
            # its own registry-key removal and leftover-note write (both
            # happen a few lines after the file-removal loop it already
            # passed).
            Start-Sleep -Milliseconds 1500

            (Test-Path -LiteralPath $installed.AppDest) | Should Be $true
            $remaining = @(Get-ChildItem -LiteralPath $installed.AppDest -Force | ForEach-Object { $_.Name })
            $allowedRemaining = @('addons.json', 'settings.json', 'state.json', 'sync.log', 'server.log', 'last-run.txt', 'server.pid', 'README-leftover.txt', 'jobs', 'backups', 'cache', 'staging', 'flavours')
            foreach ($name in $remaining) {
                ($allowedRemaining -contains $name) | Should Be $true
            }
            # And the things that SHOULD be gone actually are.
            foreach ($goneName in @('install.ps1', 'addon-server.ps1', 'addon-sync.ps1', 'icon.ico', 'ui', 'host', 'Addon Manager.vbs')) {
                (Test-Path -LiteralPath (Join-Path $installed.AppDest $goneName)) | Should Be $false
            }

            (Test-Path -LiteralPath $appsKeyPath) | Should Be $false
        } finally {
            # Stop-TestServer's own graceful POST /api/shutdown is a
            # harmless no-op if the server already shut itself down; its
            # process-kill fallback only fires if something is still
            # alive, so this is always safe to call.
            Stop-TestServer -Server $server
            if ($installed.WowRoot -and (Test-Path -LiteralPath $installed.WowRoot)) {
                Remove-Item -LiteralPath $installed.WowRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $appsKeyPath) {
                Remove-Item -LiteralPath $appsKeyPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # ---- live-safety snapshot AFTER - must be byte-identical to BEFORE ----
        $runAfter = Get-ProductionRunValue
        $appsAfter = Get-ProductionInstalledAppsSnapshot
        $trayPidsAfter = Get-LiveFurphyTrayPids
        Write-Host "  [live-safety AFTER]  Run value present: $([bool]$runAfter) | Installed-Apps key present: $([bool]$appsAfter) | live tray pids: $($trayPidsAfter -join ',')"

        $runAfter | Should Be $runBefore
        (ConvertTo-Json -InputObject $appsAfter -Compress) | Should Be (ConvertTo-Json -InputObject $appsBefore -Compress)
        (@($trayPidsAfter) -join ',') | Should Be (@($trayPidsBefore) -join ',')
    }
}

Describe 'POST /api/uninstall - real host WINDOW open (Round 33 defect regression: WebView2 children outliving FurphyHost.exe left host\ behind)' -Tags 'Host' {
    # Reproduced 2/2 by the round-33 verifier: with a scratch install's
    # REAL host window open (host\bin\FurphyHost.exe --port 47899 --view
    # settings - the same shape a user gets from "Open Furphy Addon
    # Manager" or the app's own window), POST /api/uninstall used to stop
    # the scratch server and WM_CLOSE/wait-out FurphyHost.exe itself, but
    # never waited for its WebView2 child processes (msedgewebview2.exe
    # renderer/gpu/crashpad/network, spawned under host\bin\
    # FurphyHost.exe.WebView2\EBWebView) - those could still be unwinding
    # and holding a lock when the single Remove-Item -Recurse -Force on
    # the whole host\ folder ran, which threw and left the ENTIRE folder
    # (exe/DLLs/lib/sources, ~1 MB) behind. The existing Describe above
    # only ever exercises -Console mode with no window open, so it never
    # spawned a WebView2 child and never caught this - this Describe opens
    # a REAL window first, proving both the defect's precondition (a live
    # WebView2 child under this appDest) and the fix's own claim (it, and
    # the window, and the whole host\ folder, are all gone afterward).
    It 'closes the real window and its WebView2 children, removes the whole host\ folder with zero leftovers, and writes an uninstall log that says so' {
        if (-not (Test-Path -LiteralPath (Join-Path $Script:FurphyBuildRoot 'host\bin\FurphyHost.exe'))) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe is not built in this build root)'
            return
        }

        # ---- live-safety snapshot BEFORE ----
        $runBefore = Get-ProductionRunValue
        $appsBefore = Get-ProductionInstalledAppsSnapshot
        $trayPidsBefore = Get-LiveFurphyTrayPids
        Write-Host "  [live-safety BEFORE] Run value present: $([bool]$runBefore) | Installed-Apps key present: $([bool]$appsBefore) | live tray pids: $($trayPidsBefore -join ',')"

        $installed = New-ScratchInstall
        $installed.ExitCode | Should Be 0
        $exePath = Join-Path $installed.AppDest 'host\bin\FurphyHost.exe'
        (Test-Path -LiteralPath $exePath -PathType Leaf) | Should Be $true

        $appDestNorm = $installed.AppDest.TrimEnd('\').ToLowerInvariant()
        $windowTitle = 'Furphy Addon Manager [test 47899]'
        $appsKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FurphyAddonManager.Test'

        # Every FurphyUninstall-*.log that exists BEFORE this test's own
        # uninstall call, so the one THIS run writes can be identified by
        # set difference afterward rather than by "most recent" (this
        # file's earlier Describes may also have written one just before).
        $logsBefore = @(Get-ChildItem -Path $env:TEMP -Filter 'FurphyUninstall-*.log' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

        $server = $null
        $hostProc = $null
        try {
            $server = Start-TestServer -Root $installed.AppDest -Port 47899 -ScriptPath (Join-Path $installed.AppDest 'addon-server.ps1')

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exePath
            $psi.Arguments = '--port 47899 --view settings'
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path -Path $exePath -Parent
            $hostProc = [System.Diagnostics.Process]::Start($psi)

            $windowOpen = Wait-ForCondition -TimeoutSec 30 -Condition { Test-FurphyWindowOpen -Title $windowTitle }
            $windowOpen | Should Be $true

            # Precondition proof - at least one WebView2 child is alive
            # under THIS appDest before the uninstall ever runs (the exact
            # thing the old code never waited for).
            $webviewBefore = Wait-ForCondition -TimeoutSec 20 -Condition {
                (Get-FurphyWebView2ChildrenUnder -AppDestNorm $appDestNorm).Count -gt 0
            }
            $webviewBefore | Should Be $true

            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/uninstall' -Body @{ noShortcuts = $true; noProtocol = $true; quiet = $true }
            $r.Ok | Should Be $true
            $r.StatusCode | Should Be 200

            $serverDown = Wait-ForCondition -TimeoutSec 20 -Condition { -not (Test-PortOpen -Port 47899 -TimeoutMs 300) }
            $serverDown | Should Be $true

            # The window itself is gone.
            $windowGone = Wait-ForCondition -TimeoutSec 30 -Condition { -not (Test-FurphyWindowOpen -Title $windowTitle) }
            $windowGone | Should Be $true

            # FurphyHost.exe's own process has exited.
            $hostProcGone = Wait-ForCondition -TimeoutSec 30 -Condition {
                $hostProc.Refresh(); $hostProc.HasExited
            }
            $hostProcGone | Should Be $true

            # And so have every one of its WebView2 children - the actual
            # fix under test.
            $webviewGone = Wait-ForCondition -TimeoutSec 30 -Condition {
                (Get-FurphyWebView2ChildrenUnder -AppDestNorm $appDestNorm).Count -eq 0
            }
            $webviewGone | Should Be $true

            # The whole scratch app folder is gone except the keep-list -
            # host\ specifically, which is what the defect left behind.
            $hostGone = Wait-ForCondition -TimeoutSec 40 -Condition {
                -not (Test-Path -LiteralPath (Join-Path $installed.AppDest 'host'))
            }
            $hostGone | Should Be $true
            Start-Sleep -Milliseconds 1000

            $remaining = @(Get-ChildItem -LiteralPath $installed.AppDest -Force | ForEach-Object { $_.Name })
            $allowedRemaining = @('addons.json', 'settings.json', 'state.json', 'sync.log', 'server.log', 'last-run.txt', 'server.pid', 'README-leftover.txt', 'jobs', 'backups', 'cache', 'staging', 'flavours')
            $unexpected = @($remaining | Where-Object { $allowedRemaining -notcontains $_ })
            if ($unexpected.Count -gt 0) { Write-Host "  Unexpected leftovers: $($unexpected -join ', ')" }
            $unexpected.Count | Should Be 0
            # README-leftover.txt is always written by the pre-existing
            # removal loop (the generic "your addon list is kept here"
            # note) regardless of failures - it is already part of
            # $allowedRemaining above. What this line actually proves is
            # the ZERO-LEFTOVER case: it must NOT additionally carry this
            # fix's own "these items could not be removed" section, which
            # only Remove-InstallFolderWithRetry's failure path appends.
            $leftoverNoteText = Get-Content -LiteralPath (Join-Path $installed.AppDest 'README-leftover.txt') -Raw
            $leftoverNoteText | Should Not Match 'could not be removed'

            (Test-Path -LiteralPath $appsKeyPath) | Should Be $false

            # The uninstall log this run's own copy of install.ps1 wrote -
            # identified by set difference against $logsBefore rather than
            # "newest file", exactly one new log, reporting zero failed
            # removals.
            $newLogFound = Wait-ForCondition -TimeoutSec 15 -Condition {
                @(Get-ChildItem -Path $env:TEMP -Filter 'FurphyUninstall-*.log' -ErrorAction SilentlyContinue |
                    Where-Object { $logsBefore -notcontains $_.FullName }).Count -gt 0
            }
            $newLogFound | Should Be $true
            $newLogs = @(Get-ChildItem -Path $env:TEMP -Filter 'FurphyUninstall-*.log' -ErrorAction SilentlyContinue |
                Where-Object { $logsBefore -notcontains $_.FullName })
            $newLogs.Count | Should Be 1
            $logContent = Get-Content -LiteralPath $newLogs[0].FullName -Raw
            $logContent | Should Match 'Failed removals: 0'
            Remove-Item -LiteralPath $newLogs[0].FullName -Force -ErrorAction SilentlyContinue
        } finally {
            if ($hostProc -and -not $hostProc.HasExited) { try { $hostProc.Kill() } catch { } }
            # Belt-and-suspenders: any straggler WebView2 child under this
            # appDest that somehow survived the fix (would fail the
            # assertions above already, but must never be left running
            # past this test regardless).
            foreach ($wv in @(Get-FurphyWebView2ChildrenUnder -AppDestNorm $appDestNorm)) {
                try { Stop-Process -Id $wv.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
            }
            Stop-TestServer -Server $server
            if ($installed.WowRoot -and (Test-Path -LiteralPath $installed.WowRoot)) {
                Remove-Item -LiteralPath $installed.WowRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $appsKeyPath) {
                Remove-Item -LiteralPath $appsKeyPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # ---- live-safety snapshot AFTER - must be byte-identical to BEFORE ----
        $runAfter = Get-ProductionRunValue
        $appsAfter = Get-ProductionInstalledAppsSnapshot
        $trayPidsAfter = Get-LiveFurphyTrayPids
        Write-Host "  [live-safety AFTER]  Run value present: $([bool]$runAfter) | Installed-Apps key present: $([bool]$appsAfter) | live tray pids: $($trayPidsAfter -join ',')"

        $runAfter | Should Be $runBefore
        (ConvertTo-Json -InputObject $appsAfter -Compress) | Should Be (ConvertTo-Json -InputObject $appsBefore -Compress)
        (@($trayPidsAfter) -join ',') | Should Be (@($trayPidsBefore) -join ',')
    }
}

Describe 'POST /api/uninstall - 409 while a job is genuinely still running (busy branch, addon-server.ps1:7074-7084)' {
    # Round 33 fix (round-32 finding #3): Handle-Uninstall's own busy check
    # reuses the exact same $Script:CurrentJobByFlavour running-state loop
    # as Handle-Shutdown and POST /api/jobs - had zero coverage of its own.
    # Mirrors tests\integration\Server.Jobs.Tests.ps1's "SAME flavour is
    # 409" Describe's own established trick for making a job genuinely
    # still running when the next request lands: seed a handful of
    # nonexistent-but-numeric CurseForge project ids via -Add first (each
    # still subject to addon-sync.ps1's own unconditional 300ms
    # post-request pacing), then start a 'check' job over them so it is
    # reliably still running a moment later - no fabricated sleep/mock, a
    # real slow job through the real CLI.

    It 'refuses with 409 and a plain-language message while busy, and leaves the scratch app fully installed and the scratch server alive' {

        # ---- live-safety snapshot BEFORE ----
        $runBefore = Get-ProductionRunValue
        $appsBefore = Get-ProductionInstalledAppsSnapshot
        $trayPidsBefore = Get-LiveFurphyTrayPids
        Write-Host "  [live-safety BEFORE] Run value present: $([bool]$runBefore) | Installed-Apps key present: $([bool]$appsBefore) | live tray pids: $($trayPidsBefore -join ',')"

        $installed = New-ScratchInstall
        $installed.ExitCode | Should Be 0
        (Test-Path -LiteralPath $installed.AppDest) | Should Be $true

        $appsKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FurphyAddonManager.Test'

        $bogusIds = @(900000021, 900000022, 900000023, 900000024, 900000025)
        Invoke-CliJson -ScriptPath (Join-Path $installed.AppDest 'addon-sync.ps1') `
            -ArgumentList @('-Add', ($bogusIds -join ','), '-Json', '-WowRoot', $installed.WowRoot, '-Flavor', 'retail') | Out-Null

        $server = $null
        try {
            $server = Start-TestServer -Root $installed.AppDest -Port 47899 -ScriptPath (Join-Path $installed.AppDest 'addon-server.ps1')

            $jobStart = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'check' }
            $jobStart.Ok | Should Be $true

            # Confirm the job is actually still running before firing the
            # uninstall - without this a slow-round-trip race could let the
            # check job finish first, silently reintroducing the exact gap
            # this test exists to close (see Server.Jobs.Tests.ps1's own
            # identical guard for the same reason).
            $jobStatus = Invoke-Api -Port 47899 -Method Get -Path "/api/jobs/$($jobStart.Body.jobId)"
            $jobStatus.Body.state | Should Be 'running'

            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/uninstall' -Body @{ noShortcuts = $true; noProtocol = $true }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 409
            $r.Body.error | Should Be 'Furphy is updating an addon right now. Try again in a minute.'

            # Nothing else happened: no Copy-Item, no Start-Process, no
            # $Script:ShuttingDown - the app is still fully there and the
            # scratch server is still answering.
            (Test-Path -LiteralPath (Join-Path $installed.AppDest 'install.ps1')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $installed.AppDest 'addon-server.ps1')) | Should Be $true
            (Test-Path -LiteralPath $appsKeyPath) | Should Be $true
            (Test-PortOpen -Port 47899 -TimeoutMs 500) | Should Be $true

            # Let the job finish before tearing the server down, rather than
            # killing it mid-job.
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline) {
                $g = Invoke-Api -Port 47899 -Method Get -Path "/api/jobs/$($jobStart.Body.jobId)"
                if ($g.Ok -and $g.Body.state -ne 'running') { break }
                Start-Sleep -Milliseconds 200
            }
        } finally {
            Stop-TestServer -Server $server
            if ($installed.WowRoot -and (Test-Path -LiteralPath $installed.WowRoot)) {
                Remove-Item -LiteralPath $installed.WowRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $appsKeyPath) {
                Remove-Item -LiteralPath $appsKeyPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # ---- live-safety snapshot AFTER - must be byte-identical to BEFORE ----
        $runAfter = Get-ProductionRunValue
        $appsAfter = Get-ProductionInstalledAppsSnapshot
        $trayPidsAfter = Get-LiveFurphyTrayPids
        Write-Host "  [live-safety AFTER]  Run value present: $([bool]$runAfter) | Installed-Apps key present: $([bool]$appsAfter) | live tray pids: $($trayPidsAfter -join ',')"

        $runAfter | Should Be $runBefore
        (ConvertTo-Json -InputObject $appsAfter -Compress) | Should Be (ConvertTo-Json -InputObject $appsBefore -Compress)
        (@($trayPidsAfter) -join ',') | Should Be (@($trayPidsBefore) -join ',')
    }
}

Describe 'POST /api/uninstall - a stringified "false" for dryRun is not silently coerced to a no-op dry run (security:security-server-uninstall-bool-coercion-lies)' {
    <#
      Before this round's fix, Handle-Uninstall read its four boolean body
      fields with a bare [bool] cast, which treats ANY non-empty string as
      truthy - a JSON STRING "false" (an easy real-world mistake for any
      client that stringifies booleans, or manual testing) silently became
      $true, so a caller whose literal, expressed intent was a REAL
      uninstall instead got routed into the dry-run branch: 200
      {"ok":true,"dryRun":true}, and the server just kept running with
      nothing actually uninstalled. quiet/noShortcuts/noProtocol are sent
      as real booleans here (not exercised as strings) specifically to
      keep this an automatable, unattended run: quiet:"false" would (once
      correctly coerced) suppress the -Quiet flag and pop a real blocking
      WinForms MessageBox with nothing to click it - the exact scenario
      the finding itself flags as too risky to spawn live, and unnecessary
      here anyway since ConvertTo-SettingsBool's own coercion logic is
      already covered field-agnostically by tests\unit\
      Server.Settings.Tests.ps1's "ConvertTo-SettingsBool" Describe; this
      test's job is only to prove Handle-Uninstall actually calls that
      helper now, for all four fields alike (they were fixed in one
      identical edit) - dryRun is the one field whose coercion is both
      safe to prove end-to-end AND was the finding's own live repro.
    #>

    It 'dryRun:"false" (a string) proceeds with the REAL uninstall - never returns dryRun:true, and the scratch app is actually removed' {

        # ---- live-safety snapshot BEFORE ----
        $runBefore = Get-ProductionRunValue
        $appsBefore = Get-ProductionInstalledAppsSnapshot
        $trayPidsBefore = Get-LiveFurphyTrayPids
        Write-Host "  [live-safety BEFORE] Run value present: $([bool]$runBefore) | Installed-Apps key present: $([bool]$appsBefore) | live tray pids: $($trayPidsBefore -join ',')"

        $installed = New-ScratchInstall
        $installed.ExitCode | Should Be 0
        (Test-Path -LiteralPath $installed.AppDest) | Should Be $true

        $appsKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FurphyAddonManager.Test'
        (Test-Path -LiteralPath $appsKeyPath) | Should Be $true

        $server = $null
        try {
            $server = Start-TestServer -Root $installed.AppDest -Port 47899 -ScriptPath (Join-Path $installed.AppDest 'addon-server.ps1')

            # dryRun sent as the STRING "false" - the exact repro shape.
            # quiet/noShortcuts/noProtocol as real booleans (see the
            # Describe's own header comment for why).
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/uninstall' -Body '{"dryRun":"false","quiet":true,"noShortcuts":true,"noProtocol":true}'
            $r.Ok | Should Be $true
            $r.StatusCode | Should Be 200
            $r.Body.ok | Should Be $true
            # The whole point of this test: a broken coercion here returns
            # 200 {"ok":true,"dryRun":true} and stops there (Handle-
            # Uninstall's dry-run branch, addon-server.ps1's own
            # `if ($dryRun) { Send-Json ... @{ ok = $true; dryRun = $true }; return }`).
            # The REAL-uninstall success response this must take instead
            # never includes a dryRun field at all (`@{ ok = $true }` only)
            # - so "dryRun is present and true" is exactly the failure
            # this test exists to catch; its absence (falsy, not merely
            # equal to $false) is what proves the real path ran.
            ([bool]$r.Body.dryRun) | Should Be $false

            $serverDown = Wait-ForCondition -TimeoutSec 20 -Condition { -not (Test-PortOpen -Port 47899 -TimeoutMs 300) }
            $serverDown | Should Be $true

            $cleaned = Wait-ForCondition -TimeoutSec 30 -Condition {
                -not (Test-Path -LiteralPath (Join-Path $installed.AppDest 'install.ps1'))
            }
            $cleaned | Should Be $true
            Start-Sleep -Milliseconds 1500

            (Test-Path -LiteralPath (Join-Path $installed.AppDest 'addon-server.ps1')) | Should Be $false
            (Test-Path -LiteralPath $appsKeyPath) | Should Be $false
        } finally {
            Stop-TestServer -Server $server
            if ($installed.WowRoot -and (Test-Path -LiteralPath $installed.WowRoot)) {
                Remove-Item -LiteralPath $installed.WowRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $appsKeyPath) {
                Remove-Item -LiteralPath $appsKeyPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # ---- live-safety snapshot AFTER - must be byte-identical to BEFORE ----
        $runAfter = Get-ProductionRunValue
        $appsAfter = Get-ProductionInstalledAppsSnapshot
        $trayPidsAfter = Get-LiveFurphyTrayPids
        Write-Host "  [live-safety AFTER]  Run value present: $([bool]$runAfter) | Installed-Apps key present: $([bool]$appsAfter) | live tray pids: $($trayPidsAfter -join ',')"

        $runAfter | Should Be $runBefore
        (ConvertTo-Json -InputObject $appsAfter -Compress) | Should Be (ConvertTo-Json -InputObject $appsBefore -Compress)
        (@($trayPidsAfter) -join ',') | Should Be (@($trayPidsBefore) -join ',')
    }
}

Describe 'POST /api/uninstall - CSRF: a request with no same-origin Origin/Referer is refused before Handle-Uninstall ever runs' {

    It 'is 403, and the scratch app is left completely untouched' {
        $wowRoot = Copy-Fixture -Destination (New-TempRoot -Name 'uninstall-csrf-wowroot')
        $appDest = Join-Path -Path $wowRoot -ChildPath '_retail_\AddonSync'
        New-Item -ItemType Directory -Path $appDest -Force | Out-Null
        '{ "port": 47899 }' | Set-Content -LiteralPath (Join-Path $appDest 'settings.json') -Encoding Ascii

        $installScript = Join-Path -Path $Script:FurphyBuildRoot 'install.ps1'
        $installResult = Invoke-CliProcess -ScriptPath $installScript -ArgumentList @('-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-Console') -TimeoutSec 120
        $installResult.ExitCode | Should Be 0

        $server = $null
        try {
            $server = Start-TestServer -Root $appDest -Port 47899 -ScriptPath (Join-Path $appDest 'addon-server.ps1')

            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/uninstall' -NoOrigin
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 403

            # Still fully installed - the CSRF guard ran before Handle-Uninstall.
            (Test-Path -LiteralPath (Join-Path $appDest 'install.ps1')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $appDest 'addon-server.ps1')) | Should Be $true
        } finally {
            Stop-TestServer -Server $server
            if (Test-Path -LiteralPath $wowRoot) { Remove-Item -LiteralPath $wowRoot -Recurse -Force -ErrorAction SilentlyContinue }
            $testKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FurphyAddonManager.Test'
            if (Test-Path -LiteralPath $testKey) { Remove-Item -LiteralPath $testKey -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'install.ps1 -Uninstall run DIRECTLY (not via a live server''s own POST /api/uninstall) also stops the background addon-server.ps1 server (fresh-zip:novice-uninstall-orphans-addon-server fix, port 47903)' {
    <#
      QA-FINDINGS-LENSES-3.md MEDIUM finding: uninstalling via README's own
      documented "run install.ps1 -Uninstall directly from an unzipped
      copy of the app" path (the "advanced"/Installed-Apps route) used to
      delete the app's files and report success while the background
      addon-server.ps1 process (spawned by Addon Manager.vbs on first
      open, deliberately left running per README so "minimizing the app
      and coming back to it later reconnects on its own") stayed alive
      indefinitely - a different process image from FurphyHost.exe, which
      Get-InstallLiveAppDestProcesses never used to look for at all. This
      Describe reproduces that exact scenario end-to-end: start the
      server the way Addon Manager.vbs would, THEN run install.ps1
      -Uninstall directly - never through a live server's own POST
      /api/uninstall, which the Describes above already prove worked
      before this fix (Handle-Uninstall sets $Script:ShuttingDown itself)
      - and proves the server PROCESS itself, not just its files, is
      actually gone afterward.

      Uses port 47903 (this fixer's own assigned scratch port, kept
      distinct from the rest of this file's 47899) so this Describe's own
      Start-TestServer/orphan-detection can never collide with anything
      else in this file.
    #>

    function New-OrphanServerScratchInstall {
        $wowRoot = Copy-Fixture -Destination (New-TempRoot -Name 'orphanserver-wowroot')
        $appDest = Join-Path -Path $wowRoot -ChildPath '_retail_\AddonSync'
        New-Item -ItemType Directory -Path $appDest -Force | Out-Null
        '{ "releaseType": 1, "port": 47903 }' | Set-Content -LiteralPath (Join-Path $appDest 'settings.json') -Encoding Ascii

        $installScript = Join-Path -Path $Script:FurphyBuildRoot 'install.ps1'
        $r = Invoke-CliProcess -ScriptPath $installScript -ArgumentList @('-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-Console') -TimeoutSec 120

        return [PSCustomObject]@{ WowRoot = $wowRoot; AppDest = $appDest; ExitCode = $r.ExitCode }
    }

    function Get-OrphanAddonServerProcesses {
        <# Any REAL powershell.exe/pwsh.exe process whose command line
           references THIS scratch install's own addon-server.ps1 -
           independent proof the fix's own claim holds, mirroring how
           Get-FurphyWebView2ChildrenUnder above independently re-checks
           the webview2 case rather than trusting the fix's own internals
           alone. #>
        param([string]$AppDestNorm)
        try {
            $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue
        } catch {
            return @()
        }
        return @($procs | Where-Object {
                $_.CommandLine -and
                $_.CommandLine.ToLowerInvariant().Contains('addon-server.ps1') -and
                $_.CommandLine.ToLowerInvariant().Contains($AppDestNorm)
            })
    }

    It 'stops the orphaned background server (process actually exits, port actually closes) after a direct install.ps1 -Uninstall run' {

        # ---- live-safety snapshot BEFORE ----
        $runBefore = Get-ProductionRunValue
        $appsBefore = Get-ProductionInstalledAppsSnapshot
        $trayPidsBefore = Get-LiveFurphyTrayPids
        Write-Host "  [live-safety BEFORE] Run value present: $([bool]$runBefore) | Installed-Apps key present: $([bool]$appsBefore) | live tray pids: $($trayPidsBefore -join ',')"

        $installed = New-OrphanServerScratchInstall
        $installed.ExitCode | Should Be 0
        (Test-Path -LiteralPath (Join-Path $installed.AppDest 'addon-server.ps1')) | Should Be $true

        $appDestNorm = $installed.AppDest.TrimEnd('\').ToLowerInvariant()
        $appsKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FurphyAddonManager.Test'
        (Test-Path -LiteralPath $appsKeyPath) | Should Be $true

        $server = $null
        try {
            # Mirrors exactly what Addon Manager.vbs does on first app
            # open: a bare powershell.exe -File <AppDest>\addon-server.ps1
            # process, deliberately left running once the window closes -
            # the finding's own precondition.
            $server = Start-TestServer -Root $installed.AppDest -Port 47903 -ScriptPath (Join-Path $installed.AppDest 'addon-server.ps1')
            (Test-PortOpen -Port 47903 -TimeoutMs 1000) | Should Be $true
            $server.Process.HasExited | Should Be $false

            $orphanBefore = Get-OrphanAddonServerProcesses -AppDestNorm $appDestNorm
            $orphanBefore.Count | Should BeGreaterThan 0

            # THE REPRO: install.ps1 -Uninstall run DIRECTLY against the
            # same -WowPath, exactly as README describes for the
            # "advanced"/Installed-Apps path - never a POST to the
            # already-running server's own /api/uninstall (that path was
            # never broken; this one was).
            $installScript = Join-Path -Path $Script:FurphyBuildRoot 'install.ps1'
            $uninstall = Invoke-CliProcess -ScriptPath $installScript -ArgumentList @('-WowPath', $installed.WowRoot, '-NoShortcuts', '-NoProtocol', '-Uninstall', '-Console', '-Quiet') -TimeoutSec 60
            $uninstall.ExitCode | Should Be 0

            # The port the orphaned server was answering on must actually
            # close...
            $portClosed = Wait-ForCondition -TimeoutSec 30 -Condition { -not (Test-PortOpen -Port 47903 -TimeoutMs 300) }
            $portClosed | Should Be $true

            # ...its own process handle must actually exit (not just "we
            # stopped seeing it answer HTTP")...
            $procGone = Wait-ForCondition -TimeoutSec 15 -Condition { $server.Process.Refresh(); $server.Process.HasExited }
            $procGone | Should Be $true

            # ...and an independent, from-scratch process scan (not
            # relying on $server.Process at all) must find nothing left
            # referencing this install's own addon-server.ps1 - the exact
            # thing install.ps1's own Get-InstallLiveAppDestProcesses now
            # also checks internally.
            $orphanAfter = Get-OrphanAddonServerProcesses -AppDestNorm $appDestNorm
            $orphanAfter.Count | Should Be 0

            # And the app itself is actually gone (the pre-existing half
            # of this fix - never regressed by the server-stop addition).
            (Test-Path -LiteralPath (Join-Path $installed.AppDest 'install.ps1')) | Should Be $false
            (Test-Path -LiteralPath $appsKeyPath) | Should Be $false
        } finally {
            # Belt-and-suspenders: Stop-TestServer's own graceful POST is
            # a harmless no-op if the server already shut itself down (the
            # normal, expected outcome here); its process-kill fallback
            # only fires if something is somehow still alive.
            Stop-TestServer -Server $server
            foreach ($p in @(Get-OrphanAddonServerProcesses -AppDestNorm $appDestNorm)) {
                try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
            }
            if ($installed.WowRoot -and (Test-Path -LiteralPath $installed.WowRoot)) {
                Remove-Item -LiteralPath $installed.WowRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $appsKeyPath) {
                Remove-Item -LiteralPath $appsKeyPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # ---- live-safety snapshot AFTER - must be byte-identical to BEFORE ----
        $runAfter = Get-ProductionRunValue
        $appsAfter = Get-ProductionInstalledAppsSnapshot
        $trayPidsAfter = Get-LiveFurphyTrayPids
        Write-Host "  [live-safety AFTER]  Run value present: $([bool]$runAfter) | Installed-Apps key present: $([bool]$appsAfter) | live tray pids: $($trayPidsAfter -join ',')"

        $runAfter | Should Be $runBefore
        (ConvertTo-Json -InputObject $appsAfter -Compress) | Should Be (ConvertTo-Json -InputObject $appsBefore -Compress)
        (@($trayPidsAfter) -join ',') | Should Be (@($trayPidsBefore) -join ',')
    }
}
