<#
  Unit tests (Pester 3 syntax): Round 37 (server perf pass) - the pure
  helper functions behind Handle-State's per-flavour toc/compat/missingDeps
  cache: Get-AddonsFolderSnapshot, Get-PresentAddonFoldersFromDirs,
  Get-HandleStateCacheKey, and Clear-StateCache. Handle-State itself (the
  full cache-hit/cache-miss/identical-JSON/5x-faster contract) is exercised
  end-to-end against a real server in
  tests\integration\Server.StateCache.Tests.ps1 - this file is the
  fingerprint/key-shape building blocks in isolation, no listener, no
  network, no real addon folders beyond a couple of throwaway directories.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

Describe 'Get-AddonsFolderSnapshot' {

    It 'returns an empty fingerprint and empty Dirs for a path that does not exist' {
        $missing = Join-Path (New-TempRoot -Name 'snap-missing') 'DoesNotExist'
        $snap = Get-AddonsFolderSnapshot -AddonsPath $missing
        $snap.Fingerprint | Should Be ''
        (@($snap.Dirs)).Count | Should Be 0
    }

    It 'returns an empty fingerprint for a null/empty -AddonsPath' {
        $snap = Get-AddonsFolderSnapshot -AddonsPath $null
        $snap.Fingerprint | Should Be ''
    }

    It 'two consecutive calls against an unchanged folder return the identical fingerprint' {
        $root = New-TempRoot -Name 'snap-stable'
        New-Item -ItemType Directory -Path (Join-Path $root 'AddonOne') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'AddonTwo') -Force | Out-Null

        $first = Get-AddonsFolderSnapshot -AddonsPath $root
        $second = Get-AddonsFolderSnapshot -AddonsPath $root
        $first.Fingerprint | Should Not Be ''
        $second.Fingerprint | Should Be $first.Fingerprint
    }

    It 'adding a new addon folder changes the fingerprint' {
        $root = New-TempRoot -Name 'snap-add'
        New-Item -ItemType Directory -Path (Join-Path $root 'AddonOne') -Force | Out-Null
        $before = (Get-AddonsFolderSnapshot -AddonsPath $root).Fingerprint

        New-Item -ItemType Directory -Path (Join-Path $root 'AddonTwo') -Force | Out-Null
        $after = (Get-AddonsFolderSnapshot -AddonsPath $root).Fingerprint

        $after | Should Not Be $before
    }

    It 'removing an addon folder changes the fingerprint' {
        $root = New-TempRoot -Name 'snap-remove'
        New-Item -ItemType Directory -Path (Join-Path $root 'AddonOne') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'AddonTwo') -Force | Out-Null
        $before = (Get-AddonsFolderSnapshot -AddonsPath $root).Fingerprint

        Remove-Item -LiteralPath (Join-Path $root 'AddonTwo') -Recurse -Force
        $after = (Get-AddonsFolderSnapshot -AddonsPath $root).Fingerprint

        $after | Should Not Be $before
    }

    It 'touching an existing addon folder''s own LastWriteTime changes the fingerprint with no add/remove' {
        $root = New-TempRoot -Name 'snap-touch'
        $addonDir = Join-Path $root 'AddonOne'
        New-Item -ItemType Directory -Path $addonDir -Force | Out-Null
        $before = (Get-AddonsFolderSnapshot -AddonsPath $root).Fingerprint

        (Get-Item -LiteralPath $addonDir).LastWriteTime = (Get-Date).AddMinutes(5)
        $after = (Get-AddonsFolderSnapshot -AddonsPath $root).Fingerprint

        $after | Should Not Be $before
    }

    It 'Dirs is sorted by name and carries real DirectoryInfo entries usable by Get-PresentAddonFoldersFromDirs' {
        $root = New-TempRoot -Name 'snap-dirs'
        New-Item -ItemType Directory -Path (Join-Path $root 'Zeta') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'Alpha') -Force | Out-Null

        $snap = Get-AddonsFolderSnapshot -AddonsPath $root
        (@($snap.Dirs)).Count | Should Be 2
        $snap.Dirs[0].Name | Should Be 'Alpha'
        $snap.Dirs[1].Name | Should Be 'Zeta'
    }
}

Describe 'Get-PresentAddonFoldersFromDirs' {

    It 'matches Get-PresentAddonFolders'' own case-insensitive name-set contract, built from a snapshot instead of a fresh listing' {
        $root = New-TempRoot -Name 'present-from-dirs'
        New-Item -ItemType Directory -Path (Join-Path $root 'MyAddon') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'OtherAddon') -Force | Out-Null

        $snap = Get-AddonsFolderSnapshot -AddonsPath $root
        $set = Get-PresentAddonFoldersFromDirs -Dirs $snap.Dirs

        # The set stores lowercased names in an ordinal (case-SENSITIVE)
        # HashSet[string] - the real, established contract every actual
        # caller (Get-MissingDeps) already follows by lowercasing its own
        # query before calling .Contains(). A mixed-case query must be
        # lowercased by the caller first, same as 'MYADDON'.ToLowerInvariant()
        # here - querying with 'MYADDON' verbatim is a caller bug, not a set
        # bug, and correctly returns $false.
        $set.Contains('myaddon') | Should Be $true
        $set.Contains('MYADDON'.ToLowerInvariant()) | Should Be $true
        $set.Contains('otheraddon') | Should Be $true
        $set.Contains('nosuchaddon') | Should Be $false
    }

    It 'returns an empty (never null) set for empty Dirs' {
        $set = Get-PresentAddonFoldersFromDirs -Dirs @()
        $null -eq $set | Should Be $false
        $set.Count | Should Be 0
    }
}

Describe 'Get-HandleStateCacheKey' {

    It 'the same inputs produce the same key' {
        $root = New-TempRoot -Name 'cachekey-stable'
        $Script:AddonsJsonPath = Join-Path $root 'addons.json'
        '[]' | Set-Content -LiteralPath $Script:AddonsJsonPath -Encoding UTF8

        $build = [PSCustomObject]@{ clientBuild = '11.0.5'; clientInterface = 110005 }
        $k1 = Get-HandleStateCacheKey -Flavor 'retail' -AddonsFingerprint 'fp-1' -ClientBuildInfo $build
        $k2 = Get-HandleStateCacheKey -Flavor 'retail' -AddonsFingerprint 'fp-1' -ClientBuildInfo $build
        $k1 | Should Be $k2
    }

    It 'a different flavour produces a different key' {
        $root = New-TempRoot -Name 'cachekey-flavour'
        $Script:AddonsJsonPath = Join-Path $root 'addons.json'
        '[]' | Set-Content -LiteralPath $Script:AddonsJsonPath -Encoding UTF8
        $build = [PSCustomObject]@{ clientBuild = '11.0.5'; clientInterface = 110005 }

        $retail = Get-HandleStateCacheKey -Flavor 'retail' -AddonsFingerprint 'fp' -ClientBuildInfo $build
        $classic = Get-HandleStateCacheKey -Flavor 'classic' -AddonsFingerprint 'fp' -ClientBuildInfo $build
        $retail | Should Not Be $classic
    }

    It 'a different AddonsFingerprint produces a different key' {
        $root = New-TempRoot -Name 'cachekey-fingerprint'
        $Script:AddonsJsonPath = Join-Path $root 'addons.json'
        '[]' | Set-Content -LiteralPath $Script:AddonsJsonPath -Encoding UTF8
        $build = [PSCustomObject]@{ clientBuild = '11.0.5'; clientInterface = 110005 }

        $k1 = Get-HandleStateCacheKey -Flavor 'retail' -AddonsFingerprint 'fp-a' -ClientBuildInfo $build
        $k2 = Get-HandleStateCacheKey -Flavor 'retail' -AddonsFingerprint 'fp-b' -ClientBuildInfo $build
        $k1 | Should Not Be $k2
    }

    It 'a different client build/interface produces a different key' {
        $root = New-TempRoot -Name 'cachekey-build'
        $Script:AddonsJsonPath = Join-Path $root 'addons.json'
        '[]' | Set-Content -LiteralPath $Script:AddonsJsonPath -Encoding UTF8

        $buildA = [PSCustomObject]@{ clientBuild = '11.0.5'; clientInterface = 110005 }
        $buildB = [PSCustomObject]@{ clientBuild = '11.0.7'; clientInterface = 110007 }
        $k1 = Get-HandleStateCacheKey -Flavor 'retail' -AddonsFingerprint 'fp' -ClientBuildInfo $buildA
        $k2 = Get-HandleStateCacheKey -Flavor 'retail' -AddonsFingerprint 'fp' -ClientBuildInfo $buildB
        $k1 | Should Not Be $k2
    }

    It 'addons.json changing mtime/length produces a different key with everything else held constant' {
        $root = New-TempRoot -Name 'cachekey-recordsfile'
        $Script:AddonsJsonPath = Join-Path $root 'addons.json'
        '[]' | Set-Content -LiteralPath $Script:AddonsJsonPath -Encoding UTF8
        $build = [PSCustomObject]@{ clientBuild = '11.0.5'; clientInterface = 110005 }

        $before = Get-HandleStateCacheKey -Flavor 'retail' -AddonsFingerprint 'fp' -ClientBuildInfo $build
        Start-Sleep -Milliseconds 50
        '[{"projectId":1}]' | Set-Content -LiteralPath $Script:AddonsJsonPath -Encoding UTF8
        $after = Get-HandleStateCacheKey -Flavor 'retail' -AddonsFingerprint 'fp' -ClientBuildInfo $build

        $after | Should Not Be $before
    }

    It 'a missing addons.json is a stable, distinct "missing" fingerprint segment' {
        $root = New-TempRoot -Name 'cachekey-missing'
        $Script:AddonsJsonPath = Join-Path $root 'addons.json'
        # Deliberately never created.
        $build = [PSCustomObject]@{ clientBuild = '11.0.5'; clientInterface = 110005 }

        $k1 = Get-HandleStateCacheKey -Flavor 'retail' -AddonsFingerprint 'fp' -ClientBuildInfo $build
        $k2 = Get-HandleStateCacheKey -Flavor 'retail' -AddonsFingerprint 'fp' -ClientBuildInfo $build
        $k1 | Should Be $k2
        ($k1 -match '\|missing\|') | Should Be $true
    }
}

Describe 'Clear-StateCache' {

    It '-Flavor clears only that one flavour''s cache entry' {
        $Script:AddonExtrasCacheByFlavour = @{
            retail  = @{ Key = 'k-retail'; Extras = @() }
            classic = @{ Key = 'k-classic'; Extras = @() }
        }
        Clear-StateCache -Flavor 'retail'
        $Script:AddonExtrasCacheByFlavour.ContainsKey('retail') | Should Be $false
        $Script:AddonExtrasCacheByFlavour.ContainsKey('classic') | Should Be $true
    }

    It 'omitting -Flavor clears every flavour''s cache entry' {
        $Script:AddonExtrasCacheByFlavour = @{
            retail  = @{ Key = 'k-retail'; Extras = @() }
            classic = @{ Key = 'k-classic'; Extras = @() }
        }
        Clear-StateCache
        $Script:AddonExtrasCacheByFlavour.Count | Should Be 0
    }

    It 'clearing a flavour with no existing entry does not throw' {
        $Script:AddonExtrasCacheByFlavour = @{}
        { Clear-StateCache -Flavor 'retail' } | Should Not Throw
    }
}
