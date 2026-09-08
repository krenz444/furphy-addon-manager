<#
=====================================================================
 tests\integration\Cli.MissingRecordFields.Tests.ps1

 Regression coverage for failure-modes:missing-record-fields-crash-loop:
 Initialize-AddonRecordFields backfilled 15 of the 22 fields
 New-AddonRecord sets, but omitted fileName/installedAt - both of which
 Sync-SingleAddon/Sync-SingleWagoAddon unconditionally dot-assign on
 every real install/update ($Record.fileName = ...,
 $Record.installedAt = ...). A record loaded from addons.json with
 either key missing entirely (hand-edited, partially restored, migrated
 from outside this app) hit a hard PSCustomObject property-not-found
 exception the moment it was next due for a real install, and hit it
 again identically on every retry, since the crash happened before the
 missing field was ever set.

 Real CurseForge project 326516 (AtlasLootClassic), -Flavor classic_era -
 the same project/flavour pairing tests\integration\Cli.InstallRollback.
 Tests.ps1's own "Real CurseForge install" Describe already exercises,
 reused here rather than standing up a brand-new CurseForge stub, so
 this reproduces the exact real code path the finding's own repro used
 (Sync-SingleAddon's real install branch) while adding no new live
 CurseForge traffic shape beyond what this suite already sends. Tagged
 'Network' like every other real-CurseForge Describe in this suite, so
 -Quick/-NoNetwork can skip it.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

Describe 'a record missing fileName/installedAt installs cleanly instead of crash-looping (failure-modes:missing-record-fields-crash-loop)' -Tags 'Network' {
    $wowRoot = Copy-Fixture
    $tempRoot = New-TempRoot -Name 'cli-missing-fields'
    $cliPath = Join-Path $tempRoot 'addon-sync.ps1'
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force
    $projectId = 326516

    $flavourDir = Join-Path $tempRoot 'flavours\classic_era'
    New-Item -ItemType Directory -Path $flavourDir -Force | Out-Null

    # Every field New-AddonRecord sets EXCEPT fileName and installedAt -
    # those two keys are deliberately absent from the object entirely (not
    # set to $null - ConvertTo-Json would still emit a null-valued key,
    # and re-parsing that DOES create the NoteProperty; the finding is
    # about the key being missing altogether), matching a record that
    # predates those two fields.
    $record = [PSCustomObject]@{
        name               = 'AtlasLootClassic'
        projectId          = $projectId
        fileId             = $null
        version            = $null
        folders            = @()
        author             = $null
        ignoreUpdates      = $false
        pinnedFileId       = $null
        releaseType        = $null
        previousFileId     = $null
        previousVersion    = $null
        previousFileName   = $null
        requiredDeps       = @()
        optionalDeps       = @()
        source             = 'curseforge'
        wagoId             = $null
        slug               = $null
        curseId            = $null
        latestGameVersions = @()
        latestFileDate     = $null
    }
    $recordsPath = Join-Path $flavourDir 'addons.json'
    ConvertTo-Json -InputObject @($record) -Depth 6 | Set-Content -LiteralPath $recordsPath -Encoding UTF8

    # Sanity-check the fixture itself really has no fileName/installedAt
    # key at all (guards against this test silently passing for the wrong
    # reason if ConvertTo-Json's shape ever changes).
    $rawJsonBefore = Get-Content -LiteralPath $recordsPath -Raw
    $parsedBefore = $rawJsonBefore | ConvertFrom-Json
    (Get-Member -InputObject $parsedBefore[0] -Name 'fileName' -MemberType NoteProperty) | Should Be $null
    (Get-Member -InputObject $parsedBefore[0] -Name 'installedAt' -MemberType NoteProperty) | Should Be $null

    It 'completes with Status=Installed (not Failed) on the first attempt, and backfills both fields on disk' {
        $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 90 -ArgumentList @(
            '-Only', $projectId, '-Flavor', 'classic_era', '-Json', '-WowRoot', $wowRoot)
        $r.ExitCode | Should Be 0
        $row = @($r.Json.results) | Where-Object { [string]$_.projectId -eq [string]$projectId }
        @($row).Count | Should Be 1
        # Before the fix this reproduced 'Failed' (property-not-found
        # inside Sync-SingleAddon's own catch) on every attempt, including
        # retry - never Installed/Updated.
        (@('Installed', 'Updated') -contains $row[0].status) | Should Be $true

        $onDisk = Get-Content -LiteralPath $recordsPath -Raw | ConvertFrom-Json
        $onDiskRecord = @($onDisk) | Where-Object { [string]$_.projectId -eq [string]$projectId }
        @($onDiskRecord).Count | Should Be 1
        ([string]::IsNullOrEmpty($onDiskRecord[0].fileName)) | Should Be $false
        ([string]::IsNullOrEmpty($onDiskRecord[0].installedAt)) | Should Be $false
    }
}
