<#
=====================================================================
 tests\integration\Cli.LauncherBudgetOverride.Tests.ps1

 Round 26 (hardening, item 2): proves the -Launcher wall-clock budget cap
 (Test-LauncherBudgetExceeded, addon-sync.ps1) actually bounds a real
 launch chain even when every CurseForge HTTP call would otherwise hang
 for its own -TimeoutSec, by pointing addon-sync.ps1's CurseForge base URL
 at a local black-hole TCP listener (Start-BlackHoleListener, tests\lib\
 common.ps1) via the TEST-ONLY FURPHY_TEST_CF_BASEURL environment
 variable override.

 NOT tagged 'Network' - unlike the other -Launcher Describes in
 Cli.InstallRollbackLauncher.Tests.ps1, this makes no real internet call
 at all (the "network" it talks to is a local TcpListener this file
 itself starts and stops), so it stays Quick-visible and never depends on
 real CurseForge being reachable.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

Describe 'addon-sync.ps1 FURPHY_TEST_CF_BASEURL/FURPHY_TEST_WAGO_BASEURL override (Round 26 hardening, item 2)' {

    It '-Launcher against a black-hole CurseForge endpoint still returns within the 45s task-brief budget (asserted < 50s), chain still proceeding' {
        $blackHolePort = Get-FreeStaticPort
        $listener = Start-BlackHoleListener -Port $blackHolePort
        try {
            $wowRoot = Copy-Fixture
            $tempRoot = New-TempRoot -Name 'cli-launcher-blackhole'
            $cliPath = Join-Path $tempRoot 'addon-sync.ps1'
            Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force

            $settings = @{ releaseType = 1; autoUpdateOnLaunch = $true; port = 47831; schemaVersion = 2 }
            ConvertTo-Json -InputObject $settings -Depth 4 | Set-Content -LiteralPath (Join-Path $tempRoot 'settings.json') -Encoding UTF8

            # One real, otherwise-checkable CurseForge-sourced record - a
            # single addon is deliberate: Get-CfFiles' own single HTTP call
            # against the black hole already costs its full -TimeoutSec 30
            # before the per-addon loop even reaches its NEXT budget check
            # (the cap only stops STARTING another addon once the 40s mark
            # has passed - it does not interrupt one already mid-flight, per
            # that check's own comment in Main) - one addon is exactly the
            # shape the task brief's "never delay the game more than 45s
            # total" cares about (a single hung call, not a stack of them).
            $flavourDir = Join-Path $tempRoot 'flavours\retail'
            New-Item -ItemType Directory -Path $flavourDir -Force | Out-Null
            $record = [PSCustomObject]@{
                name          = 'BlackHoleAddon'
                projectId     = 424243
                fileId        = 1000
                version       = '1.0.0'
                fileName      = 'BlackHoleAddon-1.0.0.zip'
                installedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                folders       = @('BlackHoleAddon')
                author        = $null
                ignoreUpdates = $false
                pinnedFileId  = $null
                releaseType   = $null
                previousFileId  = $null
                previousVersion = $null
            }
            ConvertTo-Json -InputObject @($record) -Depth 6 | Set-Content -LiteralPath (Join-Path $flavourDir 'addons.json') -Encoding UTF8

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 55 -ArgumentList @(
                '-Launcher', '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot,
                '-AddonsPath', (Join-Path $wowRoot '_retail_\Interface\AddOns')) `
                -EnvironmentOverrides @{ FURPHY_TEST_CF_BASEURL = "http://127.0.0.1:$blackHolePort" }
            $sw.Stop()

            # The chain still PROCEEDED (reached the real per-addon sync,
            # attempted the black-holed record, got a real row back) rather
            # than crashing or hanging past the process's own -TimeoutSec.
            $r.ExitCode | Should Be 0
            @($r.Json.results).Count | Should Be 1
            $r.Json.results[0].projectId | Should Be 424243

            # Task brief: "never delay the game more than 45s total". The
            # single black-holed call costs ~30s (Invoke-CfRequest's own
            # -TimeoutSec 30) plus a little fixed overhead - well inside the
            # 45s cap, asserted here with a bit of margin for a loaded CI
            # box (< 50s, not a razor's-edge 45s.000).
            ($sw.Elapsed.TotalSeconds -lt 50) | Should Be $true
        } finally {
            Stop-BlackHoleListener -Listener $listener
        }
    }
}

Describe 'addon-sync.ps1 -Launcher against a black-hole CurseForge endpoint with 2+ addons stays within budget (Round 26 hardening review finding)' {
    <#
      Review finding: Test-LauncherBudgetExceeded is only evaluated at the
      TOP of each addon's turn in the per-addon loop - it never interrupts
      a call already in flight. Before this fix, each CurseForge HTTP call
      still carried its own independent, unshrinking -TimeoutSec 30, so two
      black-holed addons could cost ~30s + ~30s = ~60s total, well past the
      45s task-brief cap, even though the single-addon Describe above (by
      design) never exercised that compounding path. Get-LauncherAwareTimeoutSec
      now shrinks each call's own timeout to whatever is left of the 40s
      budget once armed by -Launcher, so addon 2's (black-holed) call can
      itself only ever run for the remaining handful of seconds - the
      combined total stays close to the single-call ~30s cost instead of
      doubling per additional hung addon.
    #>

    It '-Launcher with TWO black-holed CurseForge addons still returns within the 45s task-brief budget (asserted < 50s)' {
        $blackHolePort = Get-FreeStaticPort
        $listener = Start-BlackHoleListener -Port $blackHolePort
        try {
            $wowRoot = Copy-Fixture
            $tempRoot = New-TempRoot -Name 'cli-launcher-blackhole-multi'
            $cliPath = Join-Path $tempRoot 'addon-sync.ps1'
            Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force

            $settings = @{ releaseType = 1; autoUpdateOnLaunch = $true; port = 47831; schemaVersion = 2 }
            ConvertTo-Json -InputObject $settings -Depth 4 | Set-Content -LiteralPath (Join-Path $tempRoot 'settings.json') -Encoding UTF8

            $flavourDir = Join-Path $tempRoot 'flavours\retail'
            New-Item -ItemType Directory -Path $flavourDir -Force | Out-Null
            $records = @(
                [PSCustomObject]@{
                    name          = 'BlackHoleAddonOne'
                    projectId     = 424243
                    fileId        = 1000
                    version       = '1.0.0'
                    fileName      = 'BlackHoleAddonOne-1.0.0.zip'
                    installedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                    folders       = @('BlackHoleAddonOne')
                    author        = $null
                    ignoreUpdates = $false
                    pinnedFileId  = $null
                    releaseType   = $null
                    previousFileId  = $null
                    previousVersion = $null
                },
                [PSCustomObject]@{
                    name          = 'BlackHoleAddonTwo'
                    projectId     = 424244
                    fileId        = 2000
                    version       = '1.0.0'
                    fileName      = 'BlackHoleAddonTwo-1.0.0.zip'
                    installedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                    folders       = @('BlackHoleAddonTwo')
                    author        = $null
                    ignoreUpdates = $false
                    pinnedFileId  = $null
                    releaseType   = $null
                    previousFileId  = $null
                    previousVersion = $null
                }
            )
            ConvertTo-Json -InputObject $records -Depth 6 | Set-Content -LiteralPath (Join-Path $flavourDir 'addons.json') -Encoding UTF8

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 55 -ArgumentList @(
                '-Launcher', '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot,
                '-AddonsPath', (Join-Path $wowRoot '_retail_\Interface\AddOns')) `
                -EnvironmentOverrides @{ FURPHY_TEST_CF_BASEURL = "http://127.0.0.1:$blackHolePort" }
            $sw.Stop()

            # Both black-holed records were attempted (neither was skipped by
            # the between-addon budget check before its own call started) -
            # the chain still proceeded through both rather than crashing.
            $r.ExitCode | Should Be 0
            @($r.Json.results).Count | Should Be 2

            # The compounding bug this test targets would cost ~60s+ (two
            # independent, unshrinking 30s hangs); the fix keeps the SECOND
            # addon's call bounded to whatever the 40s budget has left after
            # the first, so the total stays close to a single call's cost
            # instead of roughly doubling. Same < 50s task-brief margin as
            # the single-addon Describe above.
            ($sw.Elapsed.TotalSeconds -lt 50) | Should Be $true
        } finally {
            Stop-BlackHoleListener -Listener $listener
        }
    }
}

Describe 'addon-sync.ps1 FURPHY_TEST_CF_BASEURL empty/whitespace is ignored (Round 26 hardening, item 2)' -Tags 'Network' {
    # A real (fast, offline-safe - bogus numeric id, 404s immediately)
    # CurseForge round trip, in its own Describe (tagged 'Network' -
    # unlike the black-hole Describe above, which needs no real internet
    # and stays untagged) so -NoNetwork/a real-network-less machine can
    # still run everything else in this file. Confirms the "empty is the
    # same as unset" contract end to end: if an empty override were NOT
    # ignored, this would build a URI like " /api/v1/mods/..." (a blank
    # base) and the CLI would fail in some OTHER way (a URI-parse
    # exception, not a clean per-row status) - tests\unit\
    # Cli.BaseUrlOverride.Tests.ps1 covers the same contract directly
    # against $script:CfBaseUrl without a real network call.

    It 'a real (non-black-hole) call still reaches the real CurseForge host' {
        $wowRoot = Copy-Fixture
        $tempRoot = New-TempRoot -Name 'cli-launcher-blank-override'
        $cliPath = Join-Path $tempRoot 'addon-sync.ps1'
        Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force

        $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 30 -ArgumentList @(
            '-Add', '999999996', '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot) `
            -EnvironmentOverrides @{ FURPHY_TEST_CF_BASEURL = '   ' }
        $r.ExitCode | Should Be 0
        $row = @($r.Json.results) | Where-Object { [string]$_.projectId -eq '999999996' }
        @($row).Count | Should Be 1
        # A bogus-but-numeric id against the REAL host reports a clean
        # Failed/not-found style status, never a URI-parse crash - proves
        # the blank override never made it into the URL.
        ($row[0].status -ne $null) | Should Be $true
    }
}
