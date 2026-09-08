<#
=====================================================================
 tests\unit\Cli.SyncFailPhase.Tests.ps1

 Unit tests (Pester 3 syntax): addon-sync.ps1's Sync-SingleAddon /
 Sync-SingleWagoAddon must stamp a DIFFERENT FailPhase for a
 network/parse failure while fetching the file/release list than for a
 genuine "no such file id" / "no compatible file" outcome - see
 failure-modes:cf-outage-misdiagnosed-as-incompatible. Before the fix,
 every failure reached while $currentPhase was still 'checking' (an
 outage AND a real incompatibility alike) was indistinguishable, and
 ui/app.js's failureReason() mapped that single phase to the fixed
 string "No matching version found" even for a transient CurseForge/Wago
 hiccup.

 Uses Pester's Mock (not a real HTTP stub) to isolate this purely
 internal phase-tracking logic from the HTTP layer itself, which other
 tests already exercise for real (Cli.BaseUrlOverride.Tests.ps1,
 Cli.InstallRollback.Tests.ps1's 'Network'-tagged Describes). Mock
 reliably intercepts Get-CfFiles/Get-CfFileById/Get-WagoAllReleases/
 Get-WagoReleaseById here because addon-sync.ps1 is dot-sourced at file
 scope below, exactly the same pattern Cli.ProgressMigrationZip.Tests.ps1
 already uses to call Install-AddonPackage/Invoke-FlavourMigration
 directly.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1')

function New-TestCfRecord {
    <# A minimal, already-installed CurseForge record - "routine sync of an existing addon", not a fresh add, matching the finding's own emphasis that this bug fires on the single most common action in the app. #>
    param([int64]$FileId = 1000)
    $rec = New-AddonRecord -ProjectId 925037
    $rec.name = 'BigWigs'
    $rec.fileId = $FileId
    $rec.version = 'BigWigs-v1'
    $rec.fileName = 'BigWigs-v1.zip'
    $rec.installedAt = '2026-01-01T00:00:00Z'
    $rec.folders = @('BigWigs')
    return $rec
}

function New-TestWagoRecord {
    param([string]$Slug = 'testaddon', [string]$FileId = '1000')
    $rec = New-WagoAddonRecord -Slug $Slug
    $rec.name = 'TestAddon'
    $rec.fileId = $FileId
    $rec.version = 'v1'
    $rec.fileName = "$Slug-1000.zip"
    $rec.installedAt = '2026-01-01T00:00:00Z'
    $rec.folders = @('TestAddon')
    return $rec
}

Describe 'Sync-SingleAddon - checking-network vs checking FailPhase (failure-modes:cf-outage-misdiagnosed-as-incompatible)' {

    It 'a network/HTTP failure from Get-CfFiles (routine non-pinned check) is reported FailPhase=checking-network' {
        Mock Get-CfFiles { throw 'The remote server returned an error: (503) Server Unavailable.' }
        $record = New-TestCfRecord
        $result = Sync-SingleAddon -Record $record -AddonsPath (New-TempRoot -Name 'a1') -StagingPath (New-TempRoot -Name 's1') -BackupsPath (New-TempRoot -Name 'b1') -Flavor 'retail'
        $result.Status | Should Be 'Failed'
        $result.FailPhase | Should Be 'checking-network'
    }

    It 'a JSON-parse failure from Get-CfFiles (e.g. a bot-challenge HTML page) is ALSO reported FailPhase=checking-network' {
        Mock Get-CfFiles { throw 'Invalid JSON primitive: <.' }
        $record = New-TestCfRecord
        $result = Sync-SingleAddon -Record $record -AddonsPath (New-TempRoot -Name 'a2') -StagingPath (New-TempRoot -Name 's2') -BackupsPath (New-TempRoot -Name 'b2') -Flavor 'retail'
        $result.Status | Should Be 'Failed'
        $result.FailPhase | Should Be 'checking-network'
    }

    It 'a network failure from Get-CfFileById (a -FileId pin request) is also reported FailPhase=checking-network' {
        Mock Get-CfFileById { throw 'The remote server returned an error: (503) Server Unavailable.' }
        $record = New-TestCfRecord
        $result = Sync-SingleAddon -Record $record -AddonsPath (New-TempRoot -Name 'a3') -StagingPath (New-TempRoot -Name 's3') -BackupsPath (New-TempRoot -Name 'b3') -Flavor 'retail' -FileIdOverride 9999999
        $result.Status | Should Be 'Failed'
        $result.FailPhase | Should Be 'checking-network'
    }

    It 'contrast: a genuine "file id not found" (Get-CfFileById returns $null, no exception) keeps FailPhase=checking, unchanged' {
        Mock Get-CfFileById { return $null }
        $record = New-TestCfRecord
        $result = Sync-SingleAddon -Record $record -AddonsPath (New-TempRoot -Name 'a4') -StagingPath (New-TempRoot -Name 's4') -BackupsPath (New-TempRoot -Name 'b4') -Flavor 'retail' -FileIdOverride 424242
        $result.Status | Should Be 'Failed'
        $result.FailPhase | Should Be 'checking'
    }

    It 'contrast: a genuine "no compatible flavour file" (Get-CfFiles succeeds, nothing matches) is Skipped, not Failed - unaffected by the new phase' {
        # A non-empty list with one file that matches NO flavour (wrong
        # TypeId, wrong gameVersions prefix) - deliberately not an EMPTY
        # list: returning an empty List[object] from a mock function body
        # enumerates to zero pipeline objects, so the caller's
        # "$files = Get-CfFiles ..." would capture $null instead (a plain
        # PowerShell pipeline-unrolling quirk, not the fetch/parse failure
        # this Describe is about) - a real CurseForge response for a
        # tracked addon is never actually empty either.
        $nonMatchingFile = [PSCustomObject]@{
            id = 1; releaseType = 1; gameVersionTypeIds = @(999999); gameVersions = @('1.15.0')
        }
        Mock Get-CfFiles { return @($nonMatchingFile) }
        $record = New-TestCfRecord
        $result = Sync-SingleAddon -Record $record -AddonsPath (New-TempRoot -Name 'a5') -StagingPath (New-TempRoot -Name 's5') -BackupsPath (New-TempRoot -Name 'b5') -Flavor 'retail'
        $result.Status | Should Be 'Skipped'
    }
}

Describe 'Sync-SingleWagoAddon - checking-network vs checking FailPhase (failure-modes:cf-outage-misdiagnosed-as-incompatible)' {

    It 'a network failure from Get-WagoAllReleases (routine non-pinned check) is reported FailPhase=checking-network' {
        Mock Get-WagoAllReleases { throw 'The remote server returned an error: (503) Server Unavailable.' }
        $record = New-TestWagoRecord -Slug 'wago-network-1'
        $result = Sync-SingleAddon -Record $record -AddonsPath (New-TempRoot -Name 'w1') -StagingPath (New-TempRoot -Name 'ws1') -BackupsPath (New-TempRoot -Name 'wb1') -Flavor 'retail'
        $result.Status | Should Be 'Failed'
        $result.FailPhase | Should Be 'checking-network'
    }

    It 'a network failure from Get-WagoReleaseById (a -FileId pin request) is also reported FailPhase=checking-network' {
        Mock Get-WagoReleaseById { throw 'Empty response reading Wago page.' }
        $record = New-TestWagoRecord -Slug 'wago-network-2'
        $result = Sync-SingleAddon -Record $record -AddonsPath (New-TempRoot -Name 'w2') -StagingPath (New-TempRoot -Name 'ws2') -BackupsPath (New-TempRoot -Name 'wb2') -Flavor 'retail' -FileIdOverride '9999999'
        $result.Status | Should Be 'Failed'
        $result.FailPhase | Should Be 'checking-network'
    }

    It 'contrast: a genuine "release id not found" (Get-WagoReleaseById returns $null, no exception) keeps FailPhase=checking' {
        Mock Get-WagoReleaseById { return $null }
        $record = New-TestWagoRecord -Slug 'wago-notfound-1'
        $result = Sync-SingleAddon -Record $record -AddonsPath (New-TempRoot -Name 'w3') -StagingPath (New-TempRoot -Name 'ws3') -BackupsPath (New-TempRoot -Name 'wb3') -Flavor 'retail' -FileIdOverride '424242'
        $result.Status | Should Be 'Failed'
        $result.FailPhase | Should Be 'checking'
    }

    It 'contrast: a genuine "no allowed release" (Get-WagoAllReleases succeeds, nothing matches) is Skipped, not Failed' {
        # Same "non-empty, deliberately non-matching" reasoning as the CF
        # contrast test above - stability 'alpha' (rank 3) is above the
        # default MaxReleaseType 1 (stable only), a genuine no-match.
        $nonMatchingRelease = [PSCustomObject]@{
            id = 1; stability = 'alpha'; supported_retail_patches = @()
        }
        Mock Get-WagoAllReleases { return @($nonMatchingRelease) }
        $record = New-TestWagoRecord -Slug 'wago-nomatch-1'
        $result = Sync-SingleAddon -Record $record -AddonsPath (New-TempRoot -Name 'w4') -StagingPath (New-TempRoot -Name 'ws4') -BackupsPath (New-TempRoot -Name 'wb4') -Flavor 'retail'
        $result.Status | Should Be 'Skipped'
    }
}

Remove-TempRoots
