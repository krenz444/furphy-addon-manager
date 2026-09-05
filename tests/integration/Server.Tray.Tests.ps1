<#
=====================================================================
 tests\integration\Server.Tray.Tests.ps1

 Tray lifecycle (POST /api/tray/start|stop, GET /api/tray/status) and
 start-with-Windows registration (POST /api/startup/register|unregister,
 GET /api/startup/status). Tagged 'Tray' per the task brief - these start a
 REAL host\bin\FurphyHost.exe --tray process and write/remove a REAL HKCU
 Run value, so they are skipped in a -Quick run.

 Everything runs inside ONE It with a try/finally: the tray process and the
 HKCU value are real OS state, and Pester 3 has no Describe-level
 AfterAll/BeforeAll to hang cleanup off of - a try/finally around the whole
 sequence is what guarantees the Run value is removed and the process is
 gone even if an assertion partway through fails.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

Describe 'Tray lifecycle and start-with-Windows registration' -Tags 'Tray' {
    $root = New-TempRoot -Name 'tray'
    $server = $null

    It 'start -> real --tray process appears -> 409 on a second start -> stop -> gone within 5s; startup register/unregister write/remove the exact Run value' {
        $builtExePath = Join-Path $Script:FurphyBuildRoot 'host\bin\FurphyHost.exe'
        if (-not (Test-Path -LiteralPath $builtExePath -PathType Leaf)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe was not built - run host\build-host.ps1 first)'
            return
        }
        # Get-TrayExePath resolves "<Root>\host\bin\FurphyHost.exe" against
        # THIS server's own -Root (production layout: host\ sits next to
        # addon-server.ps1) - a bare temp root has no host\ at all, so it
        # must be copied in, same reasoning as Start-TestServer copying in
        # ui\/addon-sync.ps1 for every other test.
        Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'host\bin') -Destination (Join-Path $root 'host\bin') -Recurse -Force
        $exePath = Join-Path $root 'host\bin\FurphyHost.exe'

        $keyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $valueName = 'FurphyAddonManager'
        $registeredByThisTest = $false

        try {
            $server = Start-TestServer -Root $root -Port 47899

            # ---- status shape before anything started ----
            $status0 = Invoke-Api -Port 47899 -Method Get -Path '/api/tray/status'
            $status0.Ok | Should Be $true
            ($status0.Body.PSObject.Properties.Name -contains 'running') | Should Be $true
            ($status0.Body.PSObject.Properties.Name -contains 'startupRegistered') | Should Be $true
            $status0.Body.running | Should Be $false

            # ---- start ----
            $start1 = Invoke-Api -Port 47899 -Method Post -Path '/api/tray/start'
            $start1.Ok | Should Be $true
            $start1.StatusCode | Should Be 202

            $sawRunning = $false
            $trayPid = $null
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline) {
                $st = Invoke-Api -Port 47899 -Method Get -Path '/api/tray/status'
                if ($st.Ok -and $st.Body.running) {
                    $sawRunning = $true
                    $trayPid = [int]$st.Body.state.pid
                    break
                }
                Start-Sleep -Milliseconds 250
            }
            $sawRunning | Should Be $true

            # confirm it is a REAL process, actually FurphyHost, actually --tray
            $realProc = Get-Process -Id $trayPid -ErrorAction SilentlyContinue
            $realProc | Should Not Be $null
            $realProc.ProcessName | Should Be 'FurphyHost'

            # ---- second start while one is already running -> 409 ----
            $start2 = Invoke-Api -Port 47899 -Method Post -Path '/api/tray/start'
            $start2.Ok | Should Be $false
            $start2.StatusCode | Should Be 409

            # ---- stop -> gone within 5s ----
            $stop = Invoke-Api -Port 47899 -Method Post -Path '/api/tray/stop'
            $stop.Ok | Should Be $true
            $stop.Body.ok | Should Be $true

            $goneWithin5s = $false
            $deadline = (Get-Date).AddSeconds(5)
            while ((Get-Date) -lt $deadline) {
                $st = Invoke-Api -Port 47899 -Method Get -Path '/api/tray/status'
                if ($st.Ok -and -not $st.Body.running) { $goneWithin5s = $true; break }
                Start-Sleep -Milliseconds 200
            }
            $goneWithin5s | Should Be $true

            # ---- startup register: writes the exact Run string ----
            $reg = Invoke-Api -Port 47899 -Method Post -Path '/api/startup/register'
            $reg.Ok | Should Be $true
            $registeredByThisTest = $true

            $expectedRunValue = '"' + $exePath + '" --tray'
            $prop = Get-ItemProperty -LiteralPath $keyPath -Name $valueName -ErrorAction SilentlyContinue
            $prop | Should Not Be $null
            ([string]$prop.$valueName) | Should Be $expectedRunValue

            $statusReg = Invoke-Api -Port 47899 -Method Get -Path '/api/startup/status'
            $statusReg.Body.registered | Should Be $true

            # ---- startup unregister: removes it ----
            $unreg = Invoke-Api -Port 47899 -Method Post -Path '/api/startup/unregister'
            $unreg.Ok | Should Be $true
            $registeredByThisTest = $false

            $propAfter = Get-ItemProperty -LiteralPath $keyPath -Name $valueName -ErrorAction SilentlyContinue
            $propAfter | Should Be $null

            $statusUnreg = Invoke-Api -Port 47899 -Method Get -Path '/api/startup/status'
            $statusUnreg.Body.registered | Should Be $false
        } finally {
            # Belt-and-braces: stop any tray process this test may have left
            # running (a failed assertion above would otherwise skip the
            # normal stop step) and always remove the Run value regardless
            # of how far the test got.
            try { Invoke-Api -Port 47899 -Method Post -Path '/api/tray/stop' -TimeoutSec 5 | Out-Null } catch { }
            if ($registeredByThisTest) {
                try { Invoke-Api -Port 47899 -Method Post -Path '/api/startup/unregister' -TimeoutSec 5 | Out-Null } catch { }
            }
            try {
                $leftover = Get-ItemProperty -LiteralPath $keyPath -Name $valueName -ErrorAction SilentlyContinue
                if ($leftover) { Remove-ItemProperty -LiteralPath $keyPath -Name $valueName -ErrorAction SilentlyContinue }
            } catch { }
            # Also hard-kill any surviving FurphyHost --tray process by
            # command line, in case the graceful stop above didn't run
            # (server already gone, etc.) - never touches a non-tray
            # FurphyHost.exe instance.
            try {
                $stragglers = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'FurphyHost.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -like '*--tray*' }
                foreach ($s in @($stragglers)) {
                    try { Stop-Process -Id $s.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
                }
            } catch { }
            Stop-TestServer -Server $server
        }
    }
}
