<#
=====================================================================
 tests\integration\Server.MaintenanceTick.Tests.ps1

 F1 (launch-round follow-up): Invoke-MaintenanceTick's spawned
 -MaintenanceOnly child used to write cache\maintenance.lock via
 [System.IO.File]::WriteAllText BEFORE ever creating ROOT\cache\ itself -
 on a genuinely fresh install (nothing has ever written to cache\ yet),
 that threw immediately, caught by the child's own try/catch, and logged
 "Maintenance child: could not write lock file, continuing anyway" on
 literally every fresh install's first maintenance tick. Fixed by
 creating $Script:CacheDir (New-Item -Force) right before the
 WriteAllText call, mirroring the same guarded pattern already used at
 every other CacheDir call site in this file.

 A genuinely fresh -Root (New-TempRoot, no pre-seeded cache\ directory at
 all) is exactly the condition that reproduced this - Start-TestServer's
 own default env (FURPHY_TEST_SKIP_WAGO_GROWTH/FURPHY_TEST_SKIP_CF_CATALOGUE,
 set automatically unless a caller opts into a real fetch) keeps the
 maintenance child's own network-capable work a fast no-op either way, so
 this stays network-free while still exercising the exact lock-file
 write path under test.

 Run standalone:
     Invoke-Pester -Script tests\integration\Server.MaintenanceTick.Tests.ps1 -PassThru
 47899 must be free first.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Wait-ForLogLine {
    <#
      TimeoutSec default 30, not 20 (widened 2026-09-09 per verifier
      report: a real maintenance-child spawn/finish round trip observed a
      single 20s timeout under concurrent build/test system load, passing
      clean on an immediate isolated rerun - no code-level cause, matches
      this suite's own documented timing-flakiness history, see
      Server.AppUpdate.Tests.ps1 and this file's -WowFakeProcessName
      Describe). 30s matches the -TimeoutSec convention already used
      throughout tests\integration\Server.AppUpdate.Tests.ps1's own
      Wait-AppUpdateState/Wait-JobDone helpers.
    #>
    param([string]$Path, [string]$Pattern, [int]$TimeoutSec = 30, [int]$PollMs = 200)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
            if ($text -and ($text -match $Pattern)) { return $true }
        }
        Start-Sleep -Milliseconds $PollMs
    }
    return $false
}

Describe 'Invoke-MaintenanceTick - fresh install, no pre-existing cache\ directory (F1)' {

    It 'the first maintenance child on a fresh root writes/removes its lock file cleanly - never "could not write lock file"' {
        $root = New-TempRoot -Name 'maintenance-fresh'
        (Test-Path -LiteralPath (Join-Path $root 'cache')) | Should Be $false

        $server = $null
        try {
            $server = Start-TestServer -Root $root -Port 47899

            $logPath = Join-Path $root 'server.log'
            $started = Wait-ForLogLine -Path $logPath -Pattern 'Maintenance child started' -TimeoutSec 30
            $started | Should Be $true
            $finished = Wait-ForLogLine -Path $logPath -Pattern 'Maintenance child finished' -TimeoutSec 30
            $finished | Should Be $true

            $logText = Get-Content -LiteralPath $logPath -Raw
            ($logText -match 'could not write lock file') | Should Be $false

            # cache\ now exists (the child created it) and the lock file
            # itself is cleaned up again once the child finished (its own
            # `finally { Remove-Item ... maintenance.lock }`).
            (Test-Path -LiteralPath (Join-Path $root 'cache')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $root 'cache\maintenance.lock')) | Should Be $false
        } finally {
            Stop-TestServer -Server $server
        }
    }
}

Describe 'Invoke-MaintenanceTick - spawns while GameRunning is true (GAME-MODE-SPEC.md 2026-09-08)' {
    <#
      New coverage (section 8 new-coverage item 1) - no test existed for
      this gate either way before this round. Invoke-MaintenanceTick used
      to take a $GameRunning param and `if ($GameRunning) { return }` as
      its very first line, refusing to spawn the maintenance child at all
      (catalogue refresh + Wago growth crawl + hourly self-update check,
      all together) for as long as WoW stayed running. That param/check is
      gone - the child now spawns on its normal interval regardless of
      game state, same as this file's other Describe proves for the
      earlier no-pre-existing-cache-dir fix.
    #>

    It 'the maintenance child still spawns and finishes cleanly while a fake WoW process is running' {
        $root = New-TempRoot -Name 'maintenance-gamerunning'
        $fakeProcName = 'WowFakeMaintenanceTick' + (Get-Random -Maximum 99999)
        $fakeExePath = Join-Path $root ($fakeProcName + '.exe')
        Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\timeout.exe') -Destination $fakeExePath -Force
        $fakeWow = $null
        $server = $null
        try {
            $fakeWow = Start-Process -FilePath $fakeExePath -ArgumentList @('/t', '120', '/nobreak') -WindowStyle Hidden -PassThru
            Start-Sleep -Milliseconds 500

            $server = Start-TestServer -Root $root -Port 47899 -ExtraArgs @('-WowFakeProcessName', $fakeProcName)

            $logPath = Join-Path $root 'server.log'
            $started = Wait-ForLogLine -Path $logPath -Pattern 'Maintenance child started' -TimeoutSec 30
            $started | Should Be $true
            $finished = Wait-ForLogLine -Path $logPath -Pattern 'Maintenance child finished' -TimeoutSec 30
            $finished | Should Be $true

            # The old gate's own log line ("Maintenance tick skipped -
            # WoW is running" or similar) must never appear - confirmed by
            # reading the removed code directly (GAME-MODE-SPEC.md section
            # 4.4) rather than guessing at exact wording, so this asserts
            # the STRUCTURAL proof instead: a real spawn+finish pair was
            # observed above while the fake WoW process was alive for the
            # server's entire startup and first tick.
            (Test-Path -LiteralPath (Join-Path $root 'cache\maintenance.lock')) | Should Be $false
        } finally {
            if ($fakeWow -and -not $fakeWow.HasExited) { try { Stop-Process -Id $fakeWow.Id -Force -ErrorAction SilentlyContinue } catch { } }
            Stop-TestServer -Server $server
        }
    }
}
