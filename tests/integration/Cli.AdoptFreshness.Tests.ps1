<#
=====================================================================
 tests\integration\Cli.AdoptFreshness.Tests.ps1

 ADOPT-SPEC.md sections 2.5 (how the freshness check treats an adopted
 record) and 2.6/2.6.1 (an adopted record's first real update backs up
 its pre-existing folders first, and that backup survives a later
 prune).

 Get-NormalizedVersionString (section 2.5's own helper) is tested
 directly, dot-sourced, fully offline - no network, no 'Network' tag.

 Every OTHER Describe here needs a real CurseForge file list to compare
 an adopted record's recorded version against ("matches the latest" /
 "differs from the latest" are meaningless without a real "latest" to
 compare to), so they are tagged 'Network' and, like every other real-
 network Describe in this suite (Cli.InstallRollback.Tests.ps1), are
 skipped by -Quick/-NoNetwork runs. This repo has no existing stub for
 CurseForge's own /api/v1/mods/<id>/files endpoint (the CF catalogue stub
 in tests\lib\common.ps1 is a DIFFERENT endpoint - addon-server.ps1's
 raw.githubusercontent.com enrichment feed, not this one), so building a
 synthetic one from scratch was judged not worth the risk of drifting
 from CurseForge's real response shape versus reusing the same small,
 already-relied-upon real project (AtlasLootClassic, 326516,
 classic_era) Cli.InstallRollback.Tests.ps1 already exercises live.

 Pattern used throughout: a normal real `-Add` install captures the
 addon's OWN actual current version/folders/file content, then the
 resulting addons.json record is hand-edited into the shape an -Adopt
 call would have produced (adopted=true, adoptedAt set, fileId cleared
 back to null, folders/version left exactly as scanned) - this is
 byte-for-byte what ADOPT-SPEC.md 2.3 says -Adopt itself writes, without
 needing -Adopt to exist yet to set up the freshness scenario. Every
 assertion that follows is about Sync-SingleAddon's OWN new adopted-
 record branch (section 2.5) and Save-PreAdoptBackupZip (section 2.6),
 not about -Adopt's own write path (that is Cli.Adopt.Tests.ps1's job).

 Depends on: Sync-SingleAddon's section 2.5 branch, Save-PreAdoptBackupZip
 (2.6), and Save-BackupZip's keepIds fix (2.6.1) actually existing.
 Get-NormalizedVersionString's own Describe fails until section 2.5 lands
 (the function does not exist pre-ADOPT-SPEC.md); every real-network
 Describe below runs against TODAY's code regardless (a plain sync of a
 hand-edited "adopted" record with no matching new-record branch yet just
 falls through the ordinary already-has-fileId/no-fileId logic), so a
 real network failure there is a genuine regression signal even before
 the CLI package lands - only the ADOPTED-SPECIFIC assertions (Up-to-date
 with zero folder writes when versions match; the adopted-original.zip
 backup) are expected to fail until section 2.5/2.6 land.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1')

$Script:ProjectId = 326516
$Script:Flavor = 'classic_era'

function New-FreshnessScratch {
    <# One throwaway WoW root + its own addon-sync.ps1 copy (Cli.InstallRollback.Tests.ps1's own pattern). #>
    param([string]$Name = 'cli-adopt-freshness')

    $wowRoot = Copy-Fixture
    $cliDir = New-TempRoot -Name $Name
    $cliPath = Join-Path -Path $cliDir -ChildPath 'addon-sync.ps1'
    Copy-Item -LiteralPath (Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'addon-sync.ps1') -Destination $cliPath -Force

    return [PSCustomObject]@{
        WowRoot     = $wowRoot
        CliPath     = $cliPath
        AddonsPath  = Join-Path -Path $wowRoot -ChildPath '_classic_era_\Interface\AddOns'
        RecordsPath = Join-Path -Path $cliDir -ChildPath 'flavours\classic_era\addons.json'
    }
}

function ConvertTo-AdoptedStubRecord {
    <#
      Rewrites the real record a normal -Add just created into exactly the
      shape ADOPT-SPEC.md 2.3 says -Adopt itself produces: fileId back to
      null (Furphy "has not installed anything for it yet"), adopted=true,
      adoptedAt stamped, folders/projectId/name left as -Add's own real
      scan already set them. -VersionOverride replaces .version (default:
      leave the real captured version in place - the "matches" scenario).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RecordsPath,
        [Parameter(Mandatory = $true)][int]$ProjectId,
        [string]$VersionOverride,
        [switch]$ClearVersion
    )

    $records = Read-JsonRecordsFile -Path $RecordsPath
    $mine = @($records | Where-Object { [string]$_.projectId -eq [string]$ProjectId })
    if ($mine.Count -eq 0) { throw "ConvertTo-AdoptedStubRecord: no record found for project $ProjectId in $RecordsPath" }
    $mine = $mine[0]
    $mine.fileId = $null
    $mine | Add-Member -NotePropertyName 'adopted' -NotePropertyValue $true -Force
    $mine | Add-Member -NotePropertyName 'adoptedAt' -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -Force
    if ($ClearVersion) {
        $mine.version = $null
    } elseif ($VersionOverride) {
        $mine.version = $VersionOverride
    }
    ConvertTo-Json -InputObject @($records) -Depth 8 | Set-Content -LiteralPath $RecordsPath -Encoding UTF8
    return $mine
}

Describe 'Get-NormalizedVersionString (ADOPT-SPEC.md 2.5) - offline' {
    It '"v1.2.3" and "1.2.3" normalize equal (leading v/V stripped)' {
        (Get-NormalizedVersionString -Version 'v1.2.3') | Should Be (Get-NormalizedVersionString -Version '1.2.3')
        (Get-NormalizedVersionString -Version 'V1.2.3') | Should Be '1.2.3'
    }

    It 'surrounding whitespace is stripped: "  1.2.3  " and "1.2.3" normalize equal' {
        (Get-NormalizedVersionString -Version '  1.2.3  ') | Should Be (Get-NormalizedVersionString -Version '1.2.3')
    }

    It '"1.2" and "1.2.0" do NOT normalize equal (loose but not numeric)' {
        (Get-NormalizedVersionString -Version '1.2') | Should Not Be (Get-NormalizedVersionString -Version '1.2.0')
    }

    It '$null, empty and whitespace-only all normalize to $null' {
        (Get-NormalizedVersionString -Version $null) | Should Be $null
        (Get-NormalizedVersionString -Version '') | Should Be $null
        (Get-NormalizedVersionString -Version '   ') | Should Be $null
    }

    It 'is case-insensitive' {
        (Get-NormalizedVersionString -Version 'Classic-1.15.2B') | Should Be (Get-NormalizedVersionString -Version 'classic-1.15.2b')
    }
}

Describe 'an adopted record whose recorded version matches the latest is Up-to-date with no folder write' -Tags 'Network' {
    $scratch = New-FreshnessScratch -Name 'cli-adopt-fresh-match'

    $addResult = Invoke-CliJson -ScriptPath $scratch.CliPath -TimeoutSec 90 -ArgumentList @(
        '-Add', $Script:ProjectId, '-Flavor', $Script:Flavor, '-Json', '-WowRoot', $scratch.WowRoot)

    It 'setup: the real install succeeded (sanity, not the real assertion)' {
        $addResult.ExitCode | Should Be 0
        $row = @($addResult.Json.results) | Where-Object { [string]$_.projectId -eq [string]$Script:ProjectId }
        $row[0].status | Should Be 'Installed'
    }

    $adopted = ConvertTo-AdoptedStubRecord -RecordsPath $scratch.RecordsPath -ProjectId $Script:ProjectId
    $before = Get-TreeFingerprint -Path $scratch.AddonsPath

    $r = Invoke-CliJson -ScriptPath $scratch.CliPath -TimeoutSec 90 -ArgumentList @(
        '-Only', $Script:ProjectId, '-Flavor', $Script:Flavor, '-Json', '-WowRoot', $scratch.WowRoot)

    It 'reports Up-to-date (never re-downloads just because fileId was null)' {
        $r.ExitCode | Should Be 0
        $row = @($r.Json.results) | Where-Object { [string]$_.projectId -eq [string]$Script:ProjectId }
        @($row).Count | Should Be 1
        $row[0].status | Should Be 'Up-to-date'
    }

    It 'fileId was backfilled on disk (the record now looks like any other up-to-date managed addon)' {
        $onDiskRecords = Read-JsonRecordsFile -Path $scratch.RecordsPath
        $onDisk = @($onDiskRecords | Where-Object { [string]$_.projectId -eq [string]$Script:ProjectId })[0]
        ([string]::IsNullOrEmpty($onDisk.fileId)) | Should Be $false
        $onDisk.adopted | Should Be $true
    }

    It 'the AddOns folder was not touched at all (no install happened)' {
        $after = Get-TreeFingerprint -Path $scratch.AddonsPath
        (Compare-Object -ReferenceObject $before -DifferenceObject $after) | Should BeNullOrEmpty
    }
}

Describe 'an adopted record whose recorded version differs from the latest is offered as a normal update' -Tags 'Network' {
    $scratch = New-FreshnessScratch -Name 'cli-adopt-fresh-differ'

    $addResult = Invoke-CliJson -ScriptPath $scratch.CliPath -TimeoutSec 90 -ArgumentList @(
        '-Add', $Script:ProjectId, '-Flavor', $Script:Flavor, '-Json', '-WowRoot', $scratch.WowRoot)
    $addResult.ExitCode | Should Be 0

    # Deliberately never a real CurseForge version string, so this can
    # never accidentally normalize-equal the real latest.
    ConvertTo-AdoptedStubRecord -RecordsPath $scratch.RecordsPath -ProjectId $Script:ProjectId -VersionOverride 'zzz-adopt-test-never-a-real-version-zzz' | Out-Null

    $dry = Invoke-CliJson -ScriptPath $scratch.CliPath -TimeoutSec 90 -ArgumentList @(
        '-Only', $Script:ProjectId, '-Flavor', $Script:Flavor, '-DryRun', '-Json', '-WowRoot', $scratch.WowRoot)

    It 'DryRun reports Would-update with a real (non-empty) FileId' {
        $dry.ExitCode | Should Be 0
        $row = @($dry.Json.results) | Where-Object { [string]$_.projectId -eq [string]$Script:ProjectId }
        @($row).Count | Should Be 1
        $row[0].status | Should Be 'Would-update'
        ([string]::IsNullOrEmpty($row[0].fileId)) | Should Be $false
    }

    $real = Invoke-CliJson -ScriptPath $scratch.CliPath -TimeoutSec 90 -ArgumentList @(
        '-Only', $Script:ProjectId, '-Flavor', $Script:Flavor, '-Json', '-WowRoot', $scratch.WowRoot)

    It 'a real (non-DryRun) run actually installs it: fileId ends up set, folders present on disk' {
        $real.ExitCode | Should Be 0
        $row = @($real.Json.results) | Where-Object { [string]$_.projectId -eq [string]$Script:ProjectId }
        @($row).Count | Should Be 1
        (@('Installed', 'Updated') -contains $row[0].status) | Should Be $true
        (Test-Path -LiteralPath (Join-Path -Path $scratch.AddonsPath -ChildPath 'AtlasLootClassic') -PathType Container) | Should Be $true
    }
}

Describe 'an adopted record with no recorded version never silently reports Up-to-date' -Tags 'Network' {
    $scratch = New-FreshnessScratch -Name 'cli-adopt-fresh-noversion'

    $addResult = Invoke-CliJson -ScriptPath $scratch.CliPath -TimeoutSec 90 -ArgumentList @(
        '-Add', $Script:ProjectId, '-Flavor', $Script:Flavor, '-Json', '-WowRoot', $scratch.WowRoot)
    $addResult.ExitCode | Should Be 0

    ConvertTo-AdoptedStubRecord -RecordsPath $scratch.RecordsPath -ProjectId $Script:ProjectId -ClearVersion | Out-Null

    $dry = Invoke-CliJson -ScriptPath $scratch.CliPath -TimeoutSec 90 -ArgumentList @(
        '-Only', $Script:ProjectId, '-Flavor', $Script:Flavor, '-DryRun', '-Json', '-WowRoot', $scratch.WowRoot)

    It 'DryRun reports Would-update, never Up-to-date, when there is no recorded version to compare' {
        $dry.ExitCode | Should Be 0
        $row = @($dry.Json.results) | Where-Object { [string]$_.projectId -eq [string]$Script:ProjectId }
        @($row).Count | Should Be 1
        $row[0].status | Should Be 'Would-update'
    }
}

Describe 'an adopted record''s first real update backs up its pre-existing folders (ADOPT-SPEC.md 2.6/2.6.1)' -Tags 'Network' {
    $scratch = New-FreshnessScratch -Name 'cli-adopt-fresh-backup'
    $backupZipPath = Join-Path -Path (Split-Path -Path $scratch.RecordsPath -Parent) -ChildPath 'backups\326516\adopted-original.zip'

    $addResult = Invoke-CliJson -ScriptPath $scratch.CliPath -TimeoutSec 90 -ArgumentList @(
        '-Add', $Script:ProjectId, '-Flavor', $Script:Flavor, '-Json', '-WowRoot', $scratch.WowRoot)
    $addResult.ExitCode | Should Be 0

    # Snapshot exactly what the player "already had" BEFORE it is converted
    # to an adopted stub and updated - this is what adopted-original.zip
    # must end up preserving byte-for-byte. ONLY this record's own folders
    # (never the whole AddOns tree - Copy-Fixture's classic_era flavour
    # already ships its own unrelated pre-existing fixture addons
    # (MultiFlavourAddon, PreExistingEraAddon), and Save-PreAdoptBackupZip
    # itself only ever zips $Record.folders, section 2.6 - snapshotting
    # anything wider would make this comparison fail for a reason that has
    # nothing to do with the product).
    $addedRecord = @($addResult.Json.addons) | Where-Object { [string]$_.projectId -eq [string]$Script:ProjectId }
    $addedFolders = @($addedRecord[0].folders)
    $addedFolders.Count | Should BeGreaterThan 0

    $originalFolderCopy = New-TempRoot -Name 'cli-adopt-fresh-backup-original-copy'
    foreach ($folderName in $addedFolders) {
        Copy-Item -LiteralPath (Join-Path -Path $scratch.AddonsPath -ChildPath $folderName) -Destination $originalFolderCopy -Recurse -Force
    }
    $originalFingerprint = Get-TreeFingerprint -Path $originalFolderCopy

    ConvertTo-AdoptedStubRecord -RecordsPath $scratch.RecordsPath -ProjectId $Script:ProjectId -VersionOverride 'zzz-adopt-test-never-a-real-version-zzz' | Out-Null

    It 'adopted-original.zip does not exist before the first update' {
        (Test-Path -LiteralPath $backupZipPath) | Should Be $false
    }

    $firstUpdate = Invoke-CliJson -ScriptPath $scratch.CliPath -TimeoutSec 90 -ArgumentList @(
        '-Only', $Script:ProjectId, '-Flavor', $Script:Flavor, '-Json', '-WowRoot', $scratch.WowRoot)

    It 'the first real update creates adopted-original.zip, byte-identical to what was on disk before the update' {
        $firstUpdate.ExitCode | Should Be 0
        (Test-Path -LiteralPath $backupZipPath) | Should Be $true

        $extractDir = New-TempRoot -Name 'cli-adopt-fresh-backup-extract-1'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($backupZipPath, $extractDir)
        $extractedFingerprint = Get-TreeFingerprint -Path $extractDir
        (Compare-Object -ReferenceObject $originalFingerprint -DifferenceObject $extractedFingerprint) | Should BeNullOrEmpty
    }

    $firstZipHash = (Get-FileHash -LiteralPath $backupZipPath -Algorithm SHA256).Hash

    # A second real update (ADOPT-SPEC.md 6.3's "stub now serving a newer
    # version again" - substituted here with -Force, since this Describe
    # drives real CurseForge rather than a stub: -Force guarantees a
    # second genuine install/backup pass regardless of whether CurseForge
    # happens to have shipped a new file in between, without depending on
    # network timing). $Record.adopted is still true but fileId is now
    # non-null (set by the first update above), so $isNewInstall is false
    # this time - Save-PreAdoptBackupZip's own guard must NOT fire again,
    # and 2.6.1's Save-BackupZip prune fix must not delete the zip
    # Save-PreAdoptBackupZip already wrote.
    $secondUpdate = Invoke-CliJson -ScriptPath $scratch.CliPath -TimeoutSec 90 -ArgumentList @(
        '-Only', $Script:ProjectId, '-Flavor', $Script:Flavor, '-Force', '-Json', '-WowRoot', $scratch.WowRoot)

    It 'a second real update never overwrites adopted-original.zip (2.6.1 regression check)' {
        $secondUpdate.ExitCode | Should Be 0
        (Test-Path -LiteralPath $backupZipPath) | Should Be $true
        (Get-FileHash -LiteralPath $backupZipPath -Algorithm SHA256).Hash | Should Be $firstZipHash
    }
}

Describe 'a normally-added (non-adopted) record never gets an adopted-original.zip' -Tags 'Network' {
    $scratch = New-FreshnessScratch -Name 'cli-adopt-fresh-notadopted'
    $backupZipPath = Join-Path -Path (Split-Path -Path $scratch.RecordsPath -Parent) -ChildPath 'backups\326516\adopted-original.zip'

    $addResult = Invoke-CliJson -ScriptPath $scratch.CliPath -TimeoutSec 90 -ArgumentList @(
        '-Add', $Script:ProjectId, '-Flavor', $Script:Flavor, '-Json', '-WowRoot', $scratch.WowRoot)

    It 'a plain -Add install (never adopted) never creates adopted-original.zip' {
        $addResult.ExitCode | Should Be 0
        (Test-Path -LiteralPath $backupZipPath) | Should Be $false
    }

    $forceUpdate = Invoke-CliJson -ScriptPath $scratch.CliPath -TimeoutSec 90 -ArgumentList @(
        '-Only', $Script:ProjectId, '-Flavor', $Script:Flavor, '-Force', '-Json', '-WowRoot', $scratch.WowRoot)

    It 'nor does a later forced re-install of that same non-adopted record' {
        $forceUpdate.ExitCode | Should Be 0
        (Test-Path -LiteralPath $backupZipPath) | Should Be $false
    }
}

Remove-TempRoots
