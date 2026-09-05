<#
  Unit tests (Pester 3 syntax): addon-sync.ps1's .toc selection
  (Get-PrimaryTocFile), CurseForge/Wago file selection (Select-CfFile /
  Select-WagoRelease), and the interface-number parser
  (ConvertTo-InterfaceNumber). All pure/read-only - Get-PrimaryTocFile only
  lists a folder's own .toc files, never writes; the servertest\AddOns
  samples used below are read-only regression fixtures, never mutated.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1')

Describe 'Get-PrimaryTocFile' {

    It 'X-Flavor tag is authoritative: classic_era picks MultiFlavourAddon_Vanilla.toc (X-Flavor: Vanilla), not the Mainline bare file' {
        $folder = Join-Path $Script:FurphyFixtureWowRoot '_classic_era_\Interface\AddOns\MultiFlavourAddon'
        $picked = Get-PrimaryTocFile -FolderPath $folder -FolderName 'MultiFlavourAddon' -Flavor 'classic_era'
        $picked.Name | Should Be 'MultiFlavourAddon_Vanilla.toc'
    }

    It 'retail on the same multi-.toc folder picks the Mainline-tagged bare file via its X-Flavor tag' {
        $folder = Join-Path $Script:FurphyFixtureWowRoot '_classic_era_\Interface\AddOns\MultiFlavourAddon'
        $picked = Get-PrimaryTocFile -FolderPath $folder -FolderName 'MultiFlavourAddon' -Flavor 'retail'
        $picked.Name | Should Be 'MultiFlavourAddon.toc'
    }

    It 'filename-suffix table wins over a decoy bare file: classic (Mists era) picks FakeAddon_Mists.toc, not FakeAddon.toc' {
        $folder = Join-Path $Script:FurphyFixtureWowRoot '_classic_\Interface\AddOns\FakeAddon'
        $picked = Get-PrimaryTocFile -FolderPath $folder -FolderName 'FakeAddon' -Flavor 'classic' -InstalledInterface 50504
        $picked.Name | Should Be 'FakeAddon_Mists.toc'
    }

    It 'a bare-only folder (no suffix, no X-Flavor) is still picked for classic_era when it is the sole file present' {
        $folder = Join-Path $Script:FurphyFixtureWowRoot '_classic_era_\Interface\AddOns\PreExistingEraAddon'
        $picked = Get-PrimaryTocFile -FolderPath $folder -FolderName 'PreExistingEraAddon' -Flavor 'classic_era'
        $picked.Name | Should Be 'PreExistingEraAddon.toc'
    }

    It 'regression: retail against the real Details fixture picks the bare Details.toc, not any suffixed sibling' {
        $folder = Join-Path $Script:FurphyBuildRoot 'servertest\AddOns\Details'
        if (Test-Path -LiteralPath $folder -PathType Container) {
            $picked = Get-PrimaryTocFile -FolderPath $folder -FolderName 'Details' -Flavor 'retail'
            $picked.Name | Should Be 'Details.toc'
        }
    }

    It 'regression: retail against the real WeakAuras fixture picks the bare WeakAuras.toc, not any suffixed sibling' {
        $folder = Join-Path $Script:FurphyBuildRoot 'servertest\AddOns\WeakAuras'
        if (Test-Path -LiteralPath $folder -PathType Container) {
            $picked = Get-PrimaryTocFile -FolderPath $folder -FolderName 'WeakAuras' -Flavor 'retail'
            $picked.Name | Should Be 'WeakAuras.toc'
        }
    }

    It 'returns $null for a folder with no .toc file at all, never throws' {
        # (Note: calls directly, not through `{ } | Should Not Throw` -
        # Pester 3 invokes that wrapper's block in its own child scope, so
        # a variable assigned inside it never escapes back out; see
        # Cli.Flavours.Tests.ps1's header note for the live-confirmed
        # repro.) A real exception here still fails the It, uncaught.
        $empty = New-TempRoot -Name 'notoc'
        $picked = Get-PrimaryTocFile -FolderPath $empty -FolderName 'Nothing' -Flavor 'retail'
        $picked | Should Be $null
    }

    It 'a folder that does not exist also returns $null rather than throwing' {
        $picked = Get-PrimaryTocFile -FolderPath 'C:\Furphy-Tests-Nonexistent-Folder-Xyz' -FolderName 'Nothing' -Flavor 'retail'
        $picked | Should Be $null
    }
}

Describe 'Select-CfFile' {

    function New-CfFile {
        param([int[]]$TypeIds, [int]$ReleaseType, [string[]]$GameVersions)
        return [PSCustomObject]@{ gameVersionTypeIds = $TypeIds; releaseType = $ReleaseType; gameVersions = $GameVersions }
    }

    It 'picks the retail (517) release-only file over a beta one when MaxReleaseType is 1' {
        $files = @(
            (New-CfFile -TypeIds @(517) -ReleaseType 2 -GameVersions @('12.1.0')),
            (New-CfFile -TypeIds @(517) -ReleaseType 1 -GameVersions @('12.0.7'))
        )
        $picked = Select-CfFile -Files $files -MaxReleaseType 1 -TypeId 517
        $picked.releaseType | Should Be 1
    }

    It 'picks the classic_era TypeId (67408) file when asked for it, ignoring a retail (517) one in the same list' {
        $files = @(
            (New-CfFile -TypeIds @(517) -ReleaseType 1 -GameVersions @('12.1.0')),
            (New-CfFile -TypeIds @(67408) -ReleaseType 1 -GameVersions @('1.15.7'))
        )
        $picked = Select-CfFile -Files $files -MaxReleaseType 1 -TypeId 67408
        $picked.gameVersionTypeIds | Should Be 67408
    }

    It 'falls back to gameVersions-prefix match when no file carries the requested (unassigned) TypeId' {
        $files = @(New-CfFile -TypeIds @(9999) -ReleaseType 1 -GameVersions @('12.1.5'))
        $picked = Select-CfFile -Files $files -MaxReleaseType 1 -TypeId 517 -VersionPrefix '12.'
        $picked | Should Not Be $null
        $picked.gameVersions | Should Be '12.1.5'
    }

    It 'MaxReleaseType still allows a higher-channel file when nothing at the ceiling matches the TypeId (step 2, any release type)' {
        $files = @(New-CfFile -TypeIds @(517) -ReleaseType 3 -GameVersions @('12.1.0'))
        $picked = Select-CfFile -Files $files -MaxReleaseType 1 -TypeId 517
        $picked.releaseType | Should Be 3
    }

    It 'returns $null when nothing matches TypeId or the version prefix' {
        $files = @(New-CfFile -TypeIds @(9999) -ReleaseType 1 -GameVersions @('1.14.0'))
        $picked = Select-CfFile -Files $files -MaxReleaseType 1 -TypeId 517 -VersionPrefix '12.'
        $picked | Should Be $null
    }

    It 'returns $null for an empty file list' {
        $picked = Select-CfFile -Files @() -MaxReleaseType 1 -TypeId 517
        $picked | Should Be $null
    }
}

Describe 'Select-WagoRelease' {

    function New-WagoRelease {
        param([string]$Stability, [string[]]$RetailPatches, [string[]]$ClassicPatches)
        return [PSCustomObject]@{ stability = $Stability; supported_retail_patches = $RetailPatches; supported_classic_patches = $ClassicPatches }
    }

    It 'picks the newest stable release whose supported_retail_patches is non-empty' {
        $releases = @(
            (New-WagoRelease -Stability 'stable' -RetailPatches @('12.1.0')),
            (New-WagoRelease -Stability 'beta' -RetailPatches @('12.1.5'))
        )
        $picked = Select-WagoRelease -Releases $releases -MaxReleaseType 1 -WagoField 'retail'
        $picked.stability | Should Be 'stable'
    }

    It 'allows a beta release when MaxReleaseType is 2 (release+beta)' {
        $releases = @((New-WagoRelease -Stability 'beta' -RetailPatches @('12.1.5')))
        $picked = Select-WagoRelease -Releases $releases -MaxReleaseType 2 -WagoField 'retail'
        $picked | Should Not Be $null
    }

    It 'falls back to the newest allowed-stability release even with an empty patch list, when nothing satisfies both' {
        $releases = @((New-WagoRelease -Stability 'stable' -RetailPatches @()))
        $picked = Select-WagoRelease -Releases $releases -MaxReleaseType 1 -WagoField 'retail'
        $picked | Should Not Be $null
        $picked.stability | Should Be 'stable'
    }

    It 'reads the correct field for a non-retail WagoField (classic_era -> supported_classic_patches)' {
        $releases = @((New-WagoRelease -Stability 'stable' -RetailPatches @() -ClassicPatches @('1.15.7')))
        $picked = Select-WagoRelease -Releases $releases -MaxReleaseType 1 -WagoField 'classic'
        $picked | Should Not Be $null
    }

    It 'returns $null when nothing is allowed at all (every release above the stability ceiling)' {
        $releases = @((New-WagoRelease -Stability 'alpha' -RetailPatches @('12.1.5')))
        $picked = Select-WagoRelease -Releases $releases -MaxReleaseType 1 -WagoField 'retail'
        $picked | Should Be $null
    }
}

Describe 'ConvertTo-InterfaceNumber' {

    It 'parses a normal three-part version string into major*10000+minor*100+patch' {
        ConvertTo-InterfaceNumber -VersionText '12.1.0.69587' | Should Be 120100
    }

    It 'parses a Classic Era version string correctly' {
        ConvertTo-InterfaceNumber -VersionText '1.15.9.60546' | Should Be 11509
    }

    It 'returns $null for a string with fewer than 3 dot-parts' {
        ConvertTo-InterfaceNumber -VersionText '12.1' | Should Be $null
    }

    It 'returns $null for a non-numeric version string' {
        ConvertTo-InterfaceNumber -VersionText 'abc.def.ghi' | Should Be $null
    }

    It 'returns $null for an empty/null input' {
        ConvertTo-InterfaceNumber -VersionText '' | Should Be $null
        ConvertTo-InterfaceNumber -VersionText $null | Should Be $null
    }
}

Remove-TempRoots
