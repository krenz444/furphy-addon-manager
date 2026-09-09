<#
=====================================================================
 tests\integration\Install.NoAddonDataChange.Tests.ps1

 ADOPT-SPEC.md section 1's invariant, made a standing regression test:
 installing, upgrading, or uninstalling Furphy Addon Manager must never
 create, modify, or delete anything under Interface\AddOns or WTF. This
 is Eric's second verbatim request ("none of the users existing addon
 data is corrupted, removed, or anything, it needs to be a clean switch
 over") turned into an enforced check rather than a read of the code.

 Method: hash every file under _retail_\Interface\AddOns and _retail_\WTF
 before a fresh install, after a second (upgrade) run, and after
 -Uninstall - all three snapshots must be byte-for-byte identical to the
 one taken before anything ran. Get-TreeFingerprint (tests\lib\common.ps1)
 does the hashing; a real recognizable-id addon folder is added to the
 fixture copy first so the -Scan/-Adopt path in step 8 of install.ps1 is
 actually exercised (the checked-in fixtures\wowroot has no addon with an
 X-Curse-Project-ID/X-Wago-ID tag at all - confirmed by reading every .toc
 in it), not skipped as "nothing to adopt".

 Entirely offline: -Adopt (ADOPT-SPEC.md section 2) never makes a network
 call, so this file needs no CurseForge/Wago stub and carries no 'Network'
 tag. Always -NoShortcuts -NoProtocol -Console, matching every other
 automated install.ps1 test in this suite - the real Desktop/registry are
 never touched.

 Depends on the CLI package's new -Adopt mode (ADOPT-SPEC.md section 2)
 and the Installer package's rewritten step 8 (ADOPT-SPEC.md section 3.5)
 actually existing - see ADOPT-SPEC.md section 8's own caveat. Until both
 land, this file is EXPECTED to fail (today's install.ps1 still calls the
 CLI's -Add, which downloads and overwrites the recognizable-id fixture
 folder this test seeds - the exact behavior this test exists to catch).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:InstallScript = Join-Path $Script:FurphyBuildRoot 'install.ps1'

function New-RecognizableAdoptAddon {
    <#
      Hand-adds one real-shaped, recognizable-id addon folder under
      $WowRoot\_retail_\Interface\AddOns\ - same "New-PtrAdoptWowRoot-style
      hand-built fixture" approach ADOPT-SPEC.md section 6.1 points at
      (Install.AdoptTestRealms.Tests.ps1's own helper), added to a Copy-
      Fixture COPY, never the checked-in fixture itself.
    #>
    param([Parameter(Mandatory = $true)][string]$WowRoot)

    $dir = Join-Path -Path $WowRoot -ChildPath '_retail_\Interface\AddOns\PreOwnedAdoptAddon'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    @'
## Interface: 120100
## Title: Pre-Owned Adopt Addon
## Version: 3.1.4
## X-Curse-Project-ID: 555111
'@ | Set-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'PreOwnedAdoptAddon.toc') -Encoding Ascii

    # A second file inside the same folder (a Lua module, not just the
    # .toc) so the fingerprint actually covers more than one file per
    # addon - a bug that only re-downloads/rewrites the .toc and leaves a
    # sibling file alone would otherwise slip past a .toc-only check.
    "-- fake addon code, never touched by Furphy's own install/upgrade/uninstall`nlocal x = 1`n" |
        Set-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'PreOwnedAdoptAddon.lua') -Encoding Ascii
}

function New-FakeWtfSavedVariables {
    <#
      The checked-in fixtures\wowroot carries no WTF\ folder at all
      (confirmed: only Interface\AddOns exists under any flavour) - ADOPT-
      SPEC.md section 6.1 requires seeding one by hand so the "never
      touches WTF" half of the invariant is actually exercised, not
      vacuously true over an absent folder.
    #>
    param([Parameter(Mandatory = $true)][string]$WowRoot)

    $dir = Join-Path -Path $WowRoot -ChildPath '_retail_\WTF\Account\FAKEACCOUNT\SavedVariables'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    "PreOwnedAdoptAddonDB = {`n    [`"someSetting`"] = true,`n}`n" |
        Set-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'PreOwnedAdoptAddon.lua') -Encoding Ascii
}

Describe 'install.ps1 never touches Interface\AddOns or WTF across install/upgrade/uninstall (ADOPT-SPEC.md section 1)' {

    $wowRoot = Copy-Fixture
    New-RecognizableAdoptAddon -WowRoot $wowRoot
    New-FakeWtfSavedVariables -WowRoot $wowRoot

    $addonsPath = Join-Path -Path $wowRoot -ChildPath '_retail_\Interface\AddOns'
    $wtfPath = Join-Path -Path $wowRoot -ChildPath '_retail_\WTF'

    $before = Get-TreeFingerprint -Path $addonsPath
    $beforeWtf = Get-TreeFingerprint -Path $wtfPath

    It 'the seeded fixtures are really there before anything runs (sanity, not the real assertion)' {
        ($before -join "`n") | Should Match 'PreOwnedAdoptAddon\.toc'
        ($before -join "`n") | Should Match 'PreOwnedAdoptAddon\.lua'
        ($beforeWtf -join "`n") | Should Match 'PreOwnedAdoptAddon\.lua'
        $before.Count | Should BeGreaterThan 1
    }

    It 'a fresh install leaves Interface\AddOns and WTF byte-for-byte unchanged' {
        $r = Invoke-CliProcess -ScriptPath $Script:InstallScript -TimeoutSec 120 -ArgumentList @(
            '-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-Console')
        $r.ExitCode | Should Be 0

        $afterInstall = Get-TreeFingerprint -Path $addonsPath
        $afterInstallWtf = Get-TreeFingerprint -Path $wtfPath

        (Compare-Object -ReferenceObject $before -DifferenceObject $afterInstall) | Should BeNullOrEmpty
        (Compare-Object -ReferenceObject $beforeWtf -DifferenceObject $afterInstallWtf) | Should BeNullOrEmpty
    }

    It 'the addon was really recorded as managed (adopted), proving this is not a vacuous "nothing to scan" pass' {
        $appDest = Join-Path -Path $wowRoot -ChildPath '_retail_\AddonSync'
        $recordsPath = Join-Path -Path $appDest -ChildPath 'flavours\retail\addons.json'
        (Test-Path -LiteralPath $recordsPath) | Should Be $true
        $records = Read-JsonRecordsFile -Path $recordsPath
        $mine = @($records | Where-Object { [string]$_.projectId -eq '555111' })
        @($mine).Count | Should Be 1
        $mine[0].adopted | Should Be $true
        ([string]::IsNullOrEmpty($mine[0].fileId)) | Should Be $true
    }

    It 're-running install.ps1 over the existing install (an "upgrade" run) still leaves both trees unchanged' {
        $r = Invoke-CliProcess -ScriptPath $Script:InstallScript -TimeoutSec 120 -ArgumentList @(
            '-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-Console')
        $r.ExitCode | Should Be 0

        $afterUpgrade = Get-TreeFingerprint -Path $addonsPath
        $afterUpgradeWtf = Get-TreeFingerprint -Path $wtfPath

        (Compare-Object -ReferenceObject $before -DifferenceObject $afterUpgrade) | Should BeNullOrEmpty
        (Compare-Object -ReferenceObject $beforeWtf -DifferenceObject $afterUpgradeWtf) | Should BeNullOrEmpty
    }

    It '-Uninstall leaves both trees unchanged too (app files/registry only, never AddOns/WTF)' {
        $r = Invoke-CliProcess -ScriptPath $Script:InstallScript -TimeoutSec 120 -ArgumentList @(
            '-WowPath', $wowRoot, '-NoShortcuts', '-Uninstall', '-Console')
        $r.ExitCode | Should Be 0

        $afterUninstall = Get-TreeFingerprint -Path $addonsPath
        $afterUninstallWtf = Get-TreeFingerprint -Path $wtfPath

        (Compare-Object -ReferenceObject $before -DifferenceObject $afterUninstall) | Should BeNullOrEmpty
        (Compare-Object -ReferenceObject $beforeWtf -DifferenceObject $afterUninstallWtf) | Should BeNullOrEmpty
    }
}

# $wowRoot came from Copy-Fixture's default (New-TempRoot), so this sweeps
# it (and any other temp root this file created) away - PROJECT's own
# "tests clean their own scratch/TEMP residue" requirement.
Remove-TempRoots
