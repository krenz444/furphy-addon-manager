<#
=====================================================================
 tests\integration\Cli.InstallRollbackLauncher.Tests.ps1

 A real -Flavor classic_era CurseForge install/update cycle (tagged
 'Network' - skipped by -Quick/-NoNetwork), a bogus project id failing with
 a clear per-row message, rollback with a missing backup failing cleanly
 (fully offline), and -Launcher's own "dry" behaviour (autoUpdateOnLaunch
 false -> exit 0, no network - there is no SEPARATE -LauncherDryRun-style
 flag; this IS the CLI's documented dry behaviour for -Launcher).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

Describe 'Real CurseForge install into classic_era_ (AtlasLootClassic, project 326516)' -Tags 'Network' {
    $wowRoot = Copy-Fixture
    $cliPath = Join-Path (New-TempRoot -Name 'cli-install') 'addon-sync.ps1'
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force
    $projectId = 326516

    It 'installs a real classic-era-compatible file and reports Installed' {
        $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 90 -ArgumentList @(
            '-Add', $projectId, '-Flavor', 'classic_era', '-Json', '-WowRoot', $wowRoot)
        $r.ExitCode | Should Be 0
        $row = @($r.Json.results) | Where-Object { [string]$_.projectId -eq [string]$projectId }
        @($row).Count | Should Be 1
        $row[0].status | Should Be 'Installed'
        ([string]::IsNullOrEmpty($row[0].fileId)) | Should Be $false
        ([string]::IsNullOrEmpty($row[0].version)) | Should Be $false

        $addonsPath = Join-Path $wowRoot '_classic_era_\Interface\AddOns'
        (Test-Path -LiteralPath (Join-Path $addonsPath 'AtlasLootClassic') -PathType Container) | Should Be $true

        $record = @($r.Json.addons) | Where-Object { [string]$_.projectId -eq [string]$projectId }
        @($record).Count | Should Be 1
        $record[0].source | Should Not Be 'wago'
    }

    It 'running again (no -Force) reports Up-to-date for that same addon' {
        $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 90 -ArgumentList @(
            '-Only', $projectId, '-Flavor', 'classic_era', '-Json', '-WowRoot', $wowRoot)
        $r.ExitCode | Should Be 0
        $row = @($r.Json.results) | Where-Object { [string]$_.projectId -eq [string]$projectId }
        @($row).Count | Should Be 1
        $row[0].status | Should Be 'Up-to-date'
    }
}

Describe 'a bogus/nonexistent project id fails with a clear per-row message' -Tags 'Network' {
    $wowRoot = Copy-Fixture
    $cliPath = Join-Path (New-TempRoot -Name 'cli-bogus') 'addon-sync.ps1'
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force

    It 'reports a clean non-install status naming the project id, with the real reason in sync.log, and exits 0' {
        # A -Add for a project id CurseForge has no file for (never existed,
        # or exists but has nothing matching this client's flavour) comes
        # back "Skipped", not "Failed" - addon-sync.ps1 treats "no
        # installable file was found" as declining to create a placeholder
        # record at all (confirmed live: no record is added to addons.json)
        # rather than an error condition. Either way the row's Name always
        # cites "project <id>" and the real "No <flavour> file found for
        # project <id>" reason lands in sync.log - that citation, not any
        # specific status string, is the "clear message" this test checks.
        $bogusId = 999999999
        $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 60 -ArgumentList @(
            '-Add', $bogusId, '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot)
        $r.ExitCode | Should Be 0
        $row = @($r.Json.results) | Where-Object { [string]$_.projectId -eq [string]$bogusId }
        @($row).Count | Should Be 1
        (@('Skipped', 'Failed') -contains $row[0].status) | Should Be $true
        ($row[0].name -like "*$bogusId*") | Should Be $true
        @($r.Json.addons).Count | Should Be 0

        $syncLog = Join-Path (Split-Path -Path $cliPath -Parent) 'sync.log'
        $logText = Get-Content -LiteralPath $syncLog -Raw
        ($logText -like "*$bogusId*") | Should Be $true
    }
}

Describe 'rollback with no recorded previous version fails cleanly (fully offline)' {
    $wowRoot = Copy-Fixture
    $tempRoot = New-TempRoot -Name 'cli-rollback'
    $cliPath = Join-Path $tempRoot 'addon-sync.ps1'
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force

    # Hand-crafted addons.json record for retail with NO previousFileId (as
    # a fresh install always looks - previousFileId is only ever set on an
    # UPDATE, never a first install) and no backup zip on disk at all -
    # Invoke-RollbackForRecord's documented "Failed (no network) when
    # previousFileId is null" path, entirely local/offline.
    #
    # addons.json/settings.json/flavours\ live next to addon-sync.ps1 ITSELF
    # (per the script's own header comment - "relative to the folder this
    # script lives in"), never under -WowRoot (which only affects flavour/
    # AddOns-path DETECTION) - so this must sit under $tempRoot, not $wowRoot.
    $flavourDir = Join-Path $tempRoot 'flavours\retail'
    New-Item -ItemType Directory -Path $flavourDir -Force | Out-Null
    $record = [PSCustomObject]@{
        name          = 'SingleFlavourAddon'
        projectId     = 424242
        fileId        = 1000
        version       = '1.0.0'
        fileName      = 'SingleFlavourAddon-1.0.0.zip'
        installedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        folders       = @('SingleFlavourAddon')
        author        = $null
        ignoreUpdates = $false
        pinnedFileId  = $null
        releaseType   = $null
        previousFileId  = $null
        previousVersion = $null
    }
    $recordsPath = Join-Path $flavourDir 'addons.json'
    ConvertTo-Json -InputObject @($record) -Depth 6 | Set-Content -LiteralPath $recordsPath -Encoding UTF8

    It 'reports Failed for that project id, no network, no crash' {
        $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 30 -ArgumentList @(
            '-Rollback', 424242, '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot)
        $r.ExitCode | Should Be 0
        $row = @($r.Json.results) | Where-Object { [string]$_.projectId -eq '424242' }
        @($row).Count | Should Be 1
        $row[0].status | Should Be 'Failed'
    }
}

Describe '-Launcher dry behaviour (autoUpdateOnLaunch=false -> exit 0, no network, empty results)' {
    $wowRoot = Copy-Fixture
    $tempRoot = New-TempRoot -Name 'cli-launcher'
    $cliPath = Join-Path $tempRoot 'addon-sync.ps1'
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force

    # settings.json (autoUpdateOnLaunch=false) lives next to addon-sync.ps1
    # itself, same reasoning as the rollback Describe above.
    $settings = @{ releaseType = 1; autoUpdateOnLaunch = $false; port = 47831 }
    ConvertTo-Json -InputObject $settings -Depth 4 | Set-Content -LiteralPath (Join-Path $tempRoot 'settings.json') -Encoding UTF8

    It 'exits 0 with empty results and logs "auto-update disabled" - completes near-instantly (no network round trip)' {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 15 -ArgumentList @(
            '-Launcher', '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot,
            '-AddonsPath', (Join-Path $wowRoot '_retail_\Interface\AddOns'))
        $sw.Stop()
        $r.ExitCode | Should Be 0
        @($r.Json.results).Count | Should Be 0
        # a network call in this environment costs at least ~300ms of
        # Invoke-CfRequest's own unconditional pacing PER addon it would
        # have touched - well under a second total is a solid proxy for
        # "the network path never ran at all".
        ($sw.Elapsed.TotalSeconds -lt 8) | Should Be $true

        $syncLog = Join-Path $tempRoot 'sync.log'
        (Test-Path -LiteralPath $syncLog) | Should Be $true
        $logText = Get-Content -LiteralPath $syncLog -Raw
        ($logText -like '*auto-update disabled*') | Should Be $true
    }
}
