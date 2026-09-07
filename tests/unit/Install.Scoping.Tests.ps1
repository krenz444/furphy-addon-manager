<#
  Unit tests (Pester 3 syntax): install.ps1's round-32 per-install scoping of
  the Start-with-Windows value name and the tray stop-event name
  (DISTRIBUTION-SPEC.md section 5.1). Pure name computation - nothing here
  touches the registry, any event, any process or any file outside %TEMP%.

  Incident this guards against (2026-09-06 14:45): an -Uninstall run against
  a scratch fixture removed the REAL user's "Start with Windows" entry and
  set the machine-wide production stop event, killing the real tray.
  install.ps1 is dot-sourced through its round-32 guard, so only its
  functions load.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:InstallScript = Join-Path $Script:FurphyBuildRoot 'install.ps1'
. $Script:InstallScript

Describe 'install.ps1 dot-source guard' {
    It 'defines the scoping helpers without running the installer' {
        (Get-Command Get-InstallPort -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
        (Get-Command Get-InstallStartupValueName -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
        (Get-Command Get-InstallTrayStopEventName -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
        (Get-Command Test-LooksLikeScratchRun -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
        $script:FurphyDotSourced | Should Be $true
    }
}

Describe 'install.ps1 $Script:FlavourDefs (Round 34, REMOVAL-SPEC.md CS-R10: no more launch-only columns)' {
    # $Script:FlavourDefs sits ABOVE the dot-source guard (it is read by
    # Find-WowRoot/Get-InstalledFlavourDefs, both pure detection helpers),
    # so it is available here exactly like the scoping helpers above -
    # nothing below the guard (Invoke-FurphyInstallSteps, the -Uninstall
    # block, Remove-FurphyLegacyLauncherArtifacts) ever runs just from
    # dot-sourcing.
    It 'no longer carries BattleNetCode or Reliable - only Id/Folder/Label/FirstClass' {
        foreach ($def in $Script:FlavourDefs) {
            $propNames = @($def.PSObject.Properties.Name)
            ($propNames -contains 'BattleNetCode') | Should Be $false
            ($propNames -contains 'Reliable') | Should Be $false
            ($propNames -contains 'Id') | Should Be $true
            ($propNames -contains 'Folder') | Should Be $true
            ($propNames -contains 'Label') | Should Be $true
            ($propNames -contains 'FirstClass') | Should Be $true
        }
    }

    It 'keeps the exact six flavours in FLAVORS-SPEC S2.1 order' {
        (($Script:FlavourDefs | ForEach-Object { $_.Id }) -join ',') | Should Be 'retail,classic,classic_era,ptr,xptr,beta'
    }

    It 'Retail/Classic/Classic Era are still first-class; PTR/XPTR/Beta are not (legacy-shortcut cleanup naming still needs this)' {
        $firstClassIds = ($Script:FlavourDefs | Where-Object { $_.FirstClass } | ForEach-Object { $_.Id })
        (($firstClassIds -join ',')) | Should Be 'retail,classic,classic_era'
    }
}

Describe 'install.ps1 legacy-launcher name list (Round 34, REMOVAL-SPEC.md CS-R12) stays only in Remove-FurphyLegacyLauncherArtifacts' {
    # Remove-FurphyLegacyLauncherArtifacts itself sits BELOW the guard
    # (it deletes files, same as Remove-InstallFileWithRetry/
    # Remove-InstallFolderWithRetry, which also have no unit coverage here
    # for the same reason - see tests\integration\Server.Uninstall.Tests.ps1
    # for their live-filesystem coverage) so it cannot be invoked from a
    # dot-sourced load. This is a static regression guard instead: the
    # exact two legacy filenames must appear together, and only together,
    # everywhere install.ps1 still mentions them (the -Uninstall path's
    # call to the shared function, the shared function's own definition,
    # and Invoke-FurphyInstallSteps' call to the shared function) - if a
    # future edit reintroduces a THIRD, separate copy of this name list
    # instead of reusing the shared function, this test catches the drift.
    $Script:InstallSource = Get-Content -Raw -LiteralPath $Script:InstallScript

    It 'defines Remove-FurphyLegacyLauncherArtifacts exactly once' {
        ([regex]::Matches($Script:InstallSource, 'function Remove-FurphyLegacyLauncherArtifacts\b')).Count | Should Be 1
    }

    It 'the legacy .cmd/.vbs filename pair appears only inside that one shared function''s body (no second, drifted copy elsewhere)' {
        ([regex]::Matches($Script:InstallSource, [regex]::Escape("'update-addons-and-launch.cmd', 'Launch WoW (Updated).vbs'"))).Count | Should Be 1
    }

    It 'both the -Uninstall path and Invoke-FurphyInstallSteps call the shared cleanup function (not a hand-rolled duplicate)' {
        ([regex]::Matches($Script:InstallSource, 'Remove-FurphyLegacyLauncherArtifacts\s+-WowRootPath')).Count | Should Be 2
    }
}

Describe 'install.ps1 per-install scoping (round 32)' {
    $Script:ScratchRoot = Join-Path $env:TEMP ('furphy-scope-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $Script:ScratchRoot -Force | Out-Null
    $Script:ScratchDefault = Join-Path $Script:ScratchRoot 'default-port\AddonSync'
    $Script:ScratchTestPort = Join-Path $Script:ScratchRoot 'test-port\AddonSync'
    New-Item -ItemType Directory -Path $Script:ScratchDefault -Force | Out-Null
    New-Item -ItemType Directory -Path $Script:ScratchTestPort -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $Script:ScratchDefault 'settings.json'), '{ "port": 47831, "releaseType": 1 }')
    [IO.File]::WriteAllText((Join-Path $Script:ScratchTestPort 'settings.json'), '{ "releaseType": 1, "port": 47899 }')

    AfterAll {
        if ($Script:ScratchRoot -and (Test-Path -LiteralPath $Script:ScratchRoot)) {
            Remove-Item -LiteralPath $Script:ScratchRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reads the port from settings.json and defaults to 47831 when absent or invalid' {
        Get-InstallPort -AppDest $Script:ScratchDefault | Should Be 47831
        Get-InstallPort -AppDest $Script:ScratchTestPort | Should Be 47899
        Get-InstallPort -AppDest (Join-Path $Script:ScratchRoot 'missing') | Should Be 47831
        $bad = Join-Path $Script:ScratchRoot 'bad\AddonSync'
        New-Item -ItemType Directory -Path $bad -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $bad 'settings.json'), '{ "port": 99 }')
        Get-InstallPort -AppDest $bad | Should Be 47831
    }

    It 'a scratch root on the production port owns NEITHER production name (both null)' {
        Test-LooksLikeScratchRun -Path $Script:ScratchDefault | Should Be $true
        Get-InstallStartupValueName -AppDest $Script:ScratchDefault | Should BeNullOrEmpty
        Get-InstallTrayStopEventName -AppDest $Script:ScratchDefault | Should BeNullOrEmpty
    }

    It 'a test-port install gets the .Test value name and a port-suffixed stop event' {
        Get-InstallStartupValueName -AppDest $Script:ScratchTestPort | Should Be 'FurphyAddonManager.Test'
        Get-InstallTrayStopEventName -AppDest $Script:ScratchTestPort | Should Be 'FurphyAddonManager.TrayStop.47899'
    }

    It 'a real install path on the production port keeps the exact legacy names' {
        # Pure string computation against a non-scratch path that has no
        # settings.json (defaults to 47831) - nothing is read from or written
        # to the real install.
        $realLooking = 'C:\Program Files (x86)\World of Warcraft\_retail_\AddonSync-unit-test-does-not-exist'
        Test-LooksLikeScratchRun -Path $realLooking | Should Be $false
        Get-InstallStartupValueName -AppDest $realLooking | Should Be 'FurphyAddonManager'
        Get-InstallTrayStopEventName -AppDest $realLooking | Should Be 'FurphyAddonManager.TrayStop'
    }

    It 'the fixture wowroot counts as a scratch run' {
        Test-LooksLikeScratchRun -Path (Join-Path $Script:FurphyBuildRoot 'fixtures\wowroot\_retail_\AddonSync') | Should Be $true
    }
}
