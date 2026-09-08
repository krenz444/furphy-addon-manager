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
    param([string]$Path, [string]$Pattern, [int]$TimeoutSec = 20, [int]$PollMs = 200)
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
            $started = Wait-ForLogLine -Path $logPath -Pattern 'Maintenance child started' -TimeoutSec 20
            $started | Should Be $true
            $finished = Wait-ForLogLine -Path $logPath -Pattern 'Maintenance child finished' -TimeoutSec 20
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
