<#
=====================================================================
 tests\integration\Server.TrayStopScope.Tests.ps1

 Round 29 live-safety regression test: proves POST /api/tray/stop is
 scoped per port and can never reach a tray on a DIFFERENT port. Tagged
 'Tray' (same as tests\integration\Server.Tray.Tests.ps1) since it starts
 REAL host\bin\FurphyHost.exe --tray processes.

 SAFETY, read before touching this file: this test NEVER opens, sets, or
 creates the production-named event or mutex (the bare, unsuffixed
 "FurphyAddonManager.TrayStop" / "FurphyAddonManager.Tray"), and never
 uses port 47831 anywhere. Every actual EventWaitHandle/Mutex name this
 test's own code touches is computed live, inside FurphyHost.exe itself,
 from an explicit --port argument this file passes (47899/47898, never
 47831) - this file's own code never spells out or opens either name
 directly at all, by design, so there is no path through it - not even a
 typo - that could reach the real names a live production tray owns.

 Two ports are used, both far from 47831 and from the 47899/47890-47897
 pool tests\run-all.ps1's own hygiene sweep already covers:
   - 47899: the "stop target" - a real addon-server.ps1 test server (via
     Start-TestServer, which already only ever uses non-production ports)
     runs here, and a real --tray process is launched with --port 47899
     to match it.
   - 47898: the "control" - a second, completely independent --tray
     process with NO server behind it at all (nothing in this file ever
     binds a listener on 47898 - the tray itself is a client, not a
     listener, so there is nothing here for tests\run-all.ps1's port
     sweep to need to know about; this file kills it directly by pid in
     its own finally block regardless of how the test ends).

 Why this does NOT use POST /api/tray/start (unlike
 tests\integration\Server.Tray.Tests.ps1's own tray test): Handle-TrayStart
 (addon-server.ps1) launches host\bin\FurphyHost.exe with just '--tray',
 never forwarding -Port to the child process - a separate, pre-existing
 gap this round's task brief did not ask to fix. A tray launched that way
 falls back to reading settings.json's own "port" field for its port,
 which Get-DefaultSettings hardcodes to 47831 for a freshly created file -
 so a tray started via that endpoint against a fresh test root actually
 resolves port 47831 (production), not whatever port the server itself is
 listening on. Launching FurphyHost.exe directly with an explicit --port
 (exactly like tests\host\Host.Tests.ps1 already does for --tray-selftest)
 sidesteps that gap entirely and is what actually proves THIS round's own
 fix (the stop EVENT name, not the start path).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Wait-ProcessExited {
    param([System.Diagnostics.Process]$Process, [int]$TimeoutSec = 5)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { if ($Process.HasExited) { return $true } } catch { return $true }
        Start-Sleep -Milliseconds 150
    }
    try { return [bool]$Process.HasExited } catch { return $true }
}

Describe 'Tray stop signal is scoped per port (round 29 live-safety fix)' -Tags 'Tray' {
    $builtExePath = Join-Path $Script:FurphyBuildRoot 'host\bin\FurphyHost.exe'

    It 'POST /api/tray/stop against a 47899 server stops only the --tray --port 47899 process, leaving an independent --port 47898 process running' {
        if (-not (Test-Path -LiteralPath $builtExePath -PathType Leaf)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe was not built - run host\build-host.ps1 first)'
            return
        }

        # Each --tray instance gets its own copied host\bin\ (same reasoning
        # as Server.Tray.Tests.ps1: FindUpward resolves settings.json/
        # addon-server.ps1 relative to the exe's OWN directory, and a bare
        # temp root has neither - which is exactly what we want here, since
        # both instances are launched with an explicit --port and must
        # never fall back to reading a settings.json port field at all).
        $rootA = New-TempRoot -Name 'traystopscope-47899'
        $rootB = New-TempRoot -Name 'traystopscope-47898'
        Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'host\bin') -Destination (Join-Path $rootA 'host\bin') -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'host\bin') -Destination (Join-Path $rootB 'host\bin') -Recurse -Force
        $exeA = Join-Path $rootA 'host\bin\FurphyHost.exe'
        $exeB = Join-Path $rootB 'host\bin\FurphyHost.exe'

        $server = $null
        $procA = $null
        $procB = $null

        try {
            # ---- launch the two independent --tray processes directly,
            # each with its own explicit, non-production port ----
            $procA = Start-Process -FilePath $exeA -ArgumentList @('--tray', '--port', '47899') `
                -WorkingDirectory (Split-Path -Path $exeA -Parent) -PassThru
            $procB = Start-Process -FilePath $exeB -ArgumentList @('--tray', '--port', '47898') `
                -WorkingDirectory (Split-Path -Path $exeB -Parent) -PassThru

            # Give both a moment to actually come up (WriteStateFile(true)
            # happens immediately in TrayForm's constructor, well before any
            # network activity) and confirm neither exited immediately (a
            # startup crash, or - if this fix ever regresses back to a
            # shared literal name - the round 28 mutex fix's own busy path).
            Start-Sleep -Milliseconds 1500
            $procA.Refresh(); $procB.Refresh()
            $procA.HasExited | Should Be $false
            $procB.HasExited | Should Be $false

            # ---- start the ONE addon-server.ps1 that will handle the
            # stop request, on port 47899 (matching process A) ----
            $serverRoot = New-TempRoot -Name 'traystopscope-server'
            $server = Start-TestServer -Root $serverRoot -Port 47899

            # ---- the actual assertion: POST /api/tray/stop on the 47899
            # server must stop ONLY process A ----
            $stop = Invoke-Api -Port 47899 -Method Post -Path '/api/tray/stop'
            $stop.Ok | Should Be $true

            $aExited = Wait-ProcessExited -Process $procA -TimeoutSec 5
            $aExited | Should Be $true

            # Process B must still be alive - if the stop event were still
            # the bare, unscoped literal name (the round 29 defect this
            # test guards against), the SAME .Set() call above would have
            # reached it too and it would already be gone here.
            $procB.Refresh()
            $procB.HasExited | Should Be $false
        } finally {
            Stop-TestServer -Server $server
            try {
                if ($procA -and -not $procA.HasExited) { Stop-Process -Id $procA.Id -Force -ErrorAction SilentlyContinue }
            } catch { }
            try {
                if ($procB -and -not $procB.HasExited) { Stop-Process -Id $procB.Id -Force -ErrorAction SilentlyContinue }
            } catch { }
        }
    }
}
