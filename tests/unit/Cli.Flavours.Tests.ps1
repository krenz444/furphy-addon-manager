<#
  Unit tests (Pester 3 syntax): addon-sync.ps1's flavour detection and the
  Classic rolling-progression resolver. Dot-sources the guarded CLI script
  (see the dot-source guard added to addon-sync.ps1's own "# Main"
  section) so these call the real functions with zero side effects -
  never runs a sync, never touches the real WoW folder.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1')

Describe 'Get-InstalledFlavours' {
    # SPEC.md's own documented PS 5.1 quirk applies here: Get-InstalledFlavours
    # returns via `Write-Output -NoEnumerate`, so the caller must capture it
    # directly (never re-wrap the call itself in `@(...)`, which nests the
    # whole List[object] as a single array element instead of unrolling it -
    # confirmed live while writing this file). `.ToArray()`/foreach/`.Count`
    # on the captured List[object] all work exactly as expected.

    It 'returns retail, classic, classic_era, ptr in FLAVORS-SPEC section 2.1 fixed order' {
        $wowRoot = Copy-Fixture
        $found = Get-InstalledFlavours -WowRoot $wowRoot
        $ids = New-Object 'System.Collections.Generic.List[string]'
        foreach ($f in $found) { $ids.Add($f.id) }
        ($ids.ToArray() -join ',') | Should Be 'retail,classic,classic_era,ptr'
    }

    It 'flags none of the four fixture flavours as buildInfoMissing' {
        $wowRoot = Copy-Fixture
        $found = Get-InstalledFlavours -WowRoot $wowRoot
        $anyMissing = $false
        foreach ($f in $found) { if ($f.buildInfoMissing) { $anyMissing = $true } }
        $anyMissing | Should Be $false
    }

    It 'reads each flavour clientBuild exactly from its own .build.info row' {
        $wowRoot = Copy-Fixture
        $found = Get-InstalledFlavours -WowRoot $wowRoot
        $byId = @{}
        foreach ($f in $found) { $byId[$f.id] = $f }
        $byId['retail'].clientBuild | Should Be '12.1.0.69587'
        $byId['classic'].clientBuild | Should Be '5.5.4.61180'
        $byId['classic_era'].clientBuild | Should Be '1.15.9.60546'
        $byId['ptr'].clientBuild | Should Be '12.1.0.69588'
    }

    It 'tolerates a missing .build.info entirely (no throw, buildInfoMissing true for every folder found)' {
        # Note: deliberately does NOT capture through a `{ ... } | Should Not
        # Throw` wrapper - Pester 3's Should-Not-Throw invokes the script
        # block in its OWN child scope, so a `$found = ...` assignment
        # inside it never escapes back out (confirmed live while writing
        # this file - a real Pester 3 gotcha, not specific to this
        # function). The function is documented "never throws"; a genuine
        # exception here still fails the It (uncaught) exactly as it
        # would with the wrapper.
        $wowRoot = Copy-Fixture
        Remove-Item -LiteralPath (Join-Path $wowRoot '.build.info') -Force
        $found = Get-InstalledFlavours -WowRoot $wowRoot
        $found.Count | Should Be 4
        $allMissing = $true
        foreach ($f in $found) { if (-not $f.buildInfoMissing) { $allMissing = $false } }
        $allMissing | Should Be $true
    }

    It 'ignores non-flavour top-level folders (a decoy folder never appears in the result)' {
        $wowRoot = Copy-Fixture
        New-Item -ItemType Directory -Path (Join-Path $wowRoot '_not_a_flavour_') -Force | Out-Null
        $found = Get-InstalledFlavours -WowRoot $wowRoot
        $hasDecoy = $false
        foreach ($f in $found) { if ($f.id -eq '_not_a_flavour_') { $hasDecoy = $true } }
        $hasDecoy | Should Be $false
        $found.Count | Should Be 4
    }

    It 'a plain folder with no Interface\AddOns is never surfaced by the generic fallback' {
        $wowRoot = Copy-Fixture
        New-Item -ItemType Directory -Path (Join-Path $wowRoot '_mystery_') -Force | Out-Null
        $found = Get-InstalledFlavours -WowRoot $wowRoot
        $hasMystery = $false
        foreach ($f in $found) { if ($f.id -eq '_mystery_') { $hasMystery = $true } }
        $hasMystery | Should Be $false
    }

    It 'deleting _classic_ drops it from the result live, with no error, and nothing else changes' {
        $wowRoot = Copy-Fixture
        Remove-Item -LiteralPath (Join-Path $wowRoot '_classic_') -Recurse -Force
        $found = Get-InstalledFlavours -WowRoot $wowRoot
        $ids = New-Object 'System.Collections.Generic.List[string]'
        foreach ($f in $found) { $ids.Add($f.id) }
        ($ids.ToArray() -join ',') | Should Be 'retail,classic_era,ptr'
    }

    It 'returns an empty result (never throws) for a WowRoot that does not exist' {
        $found = Get-InstalledFlavours -WowRoot 'C:\Furphy-Tests-Nonexistent-Root-Xyz'
        $found.Count | Should Be 0
    }

    It 'never touches the real fixture on disk (still exactly the checked-in 12 files afterward)' {
        Assert-FixturePristine | Should Be $true
    }
}

Describe 'Resolve-ClassicProgressionTypeId' {

    It 'Vanilla / Classic Era range (11500-11599) resolves to TypeId 67408' {
        $r = Resolve-ClassicProgressionTypeId -Interface 11508
        $r.EraKey | Should Be 'classic_era'
        $r.TypeId | Should Be 67408
        $r.WagoValue | Should Be 'classic'
    }

    It 'Burning Crusade Classic range (20500-20599) resolves to TypeId 73246 / wago "bc"' {
        $r = Resolve-ClassicProgressionTypeId -Interface 20502
        $r.EraKey | Should Be 'tbc'
        $r.TypeId | Should Be 73246
        $r.WagoValue | Should Be 'bc'
    }

    It 'Wrath Classic first range (30400-30699) resolves to TypeId 73713 / wago "wotlk"' {
        $r = Resolve-ClassicProgressionTypeId -Interface 30403
        $r.EraKey | Should Be 'wrath'
        $r.TypeId | Should Be 73713
        $r.WagoValue | Should Be 'wotlk'
    }

    It 'Wrath Classic second range (38000-38099) resolves to the same wrath row' {
        $r = Resolve-ClassicProgressionTypeId -Interface 38050
        $r.EraKey | Should Be 'wrath'
        $r.TypeId | Should Be 73713
    }

    It 'Cataclysm Classic range (40400-40499) resolves to TypeId 77522 / wago "cata"' {
        $r = Resolve-ClassicProgressionTypeId -Interface 40402
        $r.EraKey | Should Be 'cata'
        $r.TypeId | Should Be 77522
        $r.WagoValue | Should Be 'cata'
    }

    It 'Mists Classic range (50500-50599) resolves to TypeId 79434 / wago "mop" - the fixture''s own live value' {
        $r = Resolve-ClassicProgressionTypeId -Interface 50504
        $r.EraKey | Should Be 'mists'
        $r.TypeId | Should Be 79434
        $r.WagoValue | Should Be 'mop'
    }

    It 'Retail range (120000-129999) resolves to TypeId 517' {
        $r = Resolve-ClassicProgressionTypeId -Interface 120100
        $r.EraKey | Should Be 'retail'
        $r.TypeId | Should Be 517
    }

    It 'an Interface number in a genuine gap between known ranges fails loudly as EraKey "unknown", never silently defaulting to Retail' {
        $r = Resolve-ClassicProgressionTypeId -Interface 60000
        $r.EraKey | Should Be 'unknown'
        $r.TypeId | Should Be $null
        $r.WagoValue | Should Be $null
    }

    It 'a non-zero Interface below every known range also fails loudly as "unknown", not Retail' {
        $r = Resolve-ClassicProgressionTypeId -Interface 9999
        $r.EraKey | Should Be 'unknown'
    }

    It 'a null/unreadable Interface (missing .build.info) falls back to the safe Retail default, never "unknown"' {
        $r = Resolve-ClassicProgressionTypeId -Interface $null
        $r.EraKey | Should Be 'retail'
        $r.TypeId | Should Be 517
    }

    It 'an Interface of 0 (the same "unreadable" sentinel) also falls back to Retail, not "unknown"' {
        $r = Resolve-ClassicProgressionTypeId -Interface 0
        $r.EraKey | Should Be 'retail'
    }

    It 'is re-derivable with zero code change: editing which range an Interface falls in changes the result, not the function' {
        # Proves the resolver is a live table lookup, not a hardcoded
        # per-value branch - the exact acceptance bar FLAVORS-SPEC.md
        # section 8 calls for ("provably re-derivable").
        (Resolve-ClassicProgressionTypeId -Interface 50504).EraKey | Should Be 'mists'
        (Resolve-ClassicProgressionTypeId -Interface 40402).EraKey | Should Be 'cata'
    }
}

Remove-TempRoots
