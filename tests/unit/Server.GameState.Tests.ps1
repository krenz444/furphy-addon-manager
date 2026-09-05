<#
  Unit tests (Pester 3 syntax): addon-server.ps1's P1 perf-pass game-state
  probe - Test-GameRunning and its cache (Get-CfEnrichmentNoKey/Initialize-
  CfCatalogueIndex's own gating on it is covered by inspection/CHANGELOG,
  not re-tested here - this file is the probe/cache contract itself).

  No Mock anywhere: Get-Process is a real cmdlet, not something this
  script defines, so (unlike the dot-sourced-function gotcha TESTING.md
  documents elsewhere in this suite) it is safe to call for real here.
  Rather than mock it anyway, these tests drive Test-GameRunning's
  -WowFakeProcessName substitution with a name we KNOW is really running
  (this very test process's own name, "powershell") for the true case, and
  a name that cannot exist for the false case - both fully real, no mock,
  no network, no child process spawned.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

# The current process's own name (works whether this suite runs under
# Windows PowerShell "powershell" or PowerShell 7's "pwsh") - guaranteed to
# be a really-running process for the duration of this test, with zero
# network and zero extra process spawned.
$RealRunningName = (Get-Process -Id $PID).ProcessName
$BogusName = 'ThisProcessDefinitelyDoesNotExist12345'

Describe 'Test-GameRunning' {

    It 'reports $false when the substituted process name does not exist' {
        $Script:WowFakeProcessNameOverride = $BogusName
        $Script:GameRunningCache = $false
        $Script:GameRunningCacheAt = [DateTime]::MinValue
        (Test-GameRunning) | Should Be $false
    }

    It 'reports $true when the substituted process name is really running' {
        $Script:WowFakeProcessNameOverride = $RealRunningName
        $Script:GameRunningCache = $false
        $Script:GameRunningCacheAt = [DateTime]::MinValue
        (Test-GameRunning) | Should Be $true
    }

    It 'caches its answer for $Script:GameProbeIntervalSeconds - a changed process name is NOT reflected until the cache goes stale' {
        # Prime a fresh (not-stale) $true answer.
        $Script:WowFakeProcessNameOverride = $RealRunningName
        $Script:GameRunningCache = $false
        $Script:GameRunningCacheAt = [DateTime]::MinValue
        (Test-GameRunning) | Should Be $true

        # Flip the substituted name to one that cannot possibly be running -
        # a correct cache would still return the STALE $true answer, since
        # $Script:GameRunningCacheAt was just set to "now" by the call above.
        $Script:WowFakeProcessNameOverride = $BogusName
        (Test-GameRunning) | Should Be $true

        # Force the cache stale (older than the probe interval) and confirm
        # it now actually re-probes and reports the real (bogus-name) answer.
        $Script:GameRunningCacheAt = (Get-Date).AddSeconds(-1 * ($Script:GameProbeIntervalSeconds + 5))
        (Test-GameRunning) | Should Be $false
    }
}

Describe 'gameRunning surfaced on GET /api/ping and GET /api/state' {

    It 'GET /api/ping carries a boolean gameRunning field' {
        $Script:WowFakeProcessNameOverride = $BogusName
        $Script:GameRunningCache = $false
        $Script:GameRunningCacheAt = [DateTime]::MinValue
        # Handle-Ping also reads these three - normally seeded by the
        # "Startup" section the dot-source guard skips entirely.
        $Script:StartTime = Get-Date
        $Script:AppName = 'Furphy Addon Manager'
        $Script:Version = '0.0.0-test'
        $Script:HostKind = 'edge-app'

        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/ping'
        Handle-Ping -Context $ctx -RouteMatch $null
        $body = Get-FakeResponseBody -Context $ctx
        ($body.gameRunning -is [bool]) | Should Be $true
        $body.gameRunning | Should Be $false
    }
}
