<#
  Unit tests (Pester 3 syntax): install.ps1's round-33 uninstall/
  distribution helpers (DISTRIBUTION-SPEC.md section 5.4/6.2/fix 9) - pure
  functions only, nothing here touches the registry, a window, a process,
  or any path outside %TEMP%. install.ps1 is dot-sourced through its
  round-32 guard, so only its functions load - no WoW detection, no
  copying, no registry, no uninstall, no wizard ever runs just from
  loading this file.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:InstallScript = Join-Path $Script:FurphyBuildRoot 'install.ps1'
. $Script:InstallScript

Describe 'install.ps1 dot-source guard still holds with the round-33 additions' {
    It 'defines every round-33 pure helper (all of which sit ABOVE the dot-source guard) without running the installer' {
        (Get-Command Get-InstallAppsKeyName -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
        (Get-Command Get-InstallEstimatedSizeKB -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
        (Get-Command Get-InstallUninstallString -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
        (Get-Command Get-InstallWindowTitle -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
        $script:FurphyDotSourced | Should Be $true
    }

    It 'does NOT define Invoke-FurphyInstallSteps/Show-InstallWizard when dot-sourced (both sit BELOW the guard, by design - only the pure query/name-computation helpers are meant to load without running an install)' {
        (Get-Command Invoke-FurphyInstallSteps -ErrorAction SilentlyContinue) | Should BeNullOrEmpty
        (Get-Command Show-InstallWizard -ErrorAction SilentlyContinue) | Should BeNullOrEmpty
    }
}

Describe 'Get-InstallAppsKeyName (fix 3: reuses Get-InstallStartupValueName''s scratch/null rule verbatim)' {
    $Script:KeyNameRoot = Join-Path $env:TEMP ('furphy-appskeyname-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $Script:KeyNameScratchDefault = Join-Path $Script:KeyNameRoot 'default-port\AddonSync'
    $Script:KeyNameTestPort = Join-Path $Script:KeyNameRoot 'test-port\AddonSync'
    New-Item -ItemType Directory -Path $Script:KeyNameScratchDefault -Force | Out-Null
    New-Item -ItemType Directory -Path $Script:KeyNameTestPort -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $Script:KeyNameScratchDefault 'settings.json'), '{ "port": 47831 }')
    [IO.File]::WriteAllText((Join-Path $Script:KeyNameTestPort 'settings.json'), '{ "port": 47899 }')

    AfterAll {
        if ($Script:KeyNameRoot -and (Test-Path -LiteralPath $Script:KeyNameRoot)) {
            Remove-Item -LiteralPath $Script:KeyNameRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a scratch root on the production port owns NEITHER name (null) - same as the Run value' {
        Get-InstallAppsKeyName -AppDest $Script:KeyNameScratchDefault | Should BeNullOrEmpty
    }

    It 'a test-port install gets the .Test key name' {
        Get-InstallAppsKeyName -AppDest $Script:KeyNameTestPort | Should Be 'FurphyAddonManager.Test'
    }

    It 'a real-looking production path on the production port keeps the exact legacy name' {
        $realLooking = 'C:\Program Files (x86)\World of Warcraft\_retail_\AddonSync-unit-test-does-not-exist'
        Get-InstallAppsKeyName -AppDest $realLooking | Should Be 'FurphyAddonManager'
    }

    It 'is byte-identical to Get-InstallStartupValueName for every case above (fix 3''s literal instruction)' {
        Get-InstallAppsKeyName -AppDest $Script:KeyNameScratchDefault | Should Be (Get-InstallStartupValueName -AppDest $Script:KeyNameScratchDefault)
        Get-InstallAppsKeyName -AppDest $Script:KeyNameTestPort | Should Be (Get-InstallStartupValueName -AppDest $Script:KeyNameTestPort)
    }
}

Describe 'Get-InstallEstimatedSizeKB' {
    $Script:SizeRoot = New-TempRoot -Name 'installsize'
    [IO.File]::WriteAllBytes((Join-Path $Script:SizeRoot 'a.bin'), (New-Object byte[] 2048))
    [IO.File]::WriteAllBytes((Join-Path $Script:SizeRoot 'b.bin'), (New-Object byte[] 1024))
    New-Item -ItemType Directory -Path (Join-Path $Script:SizeRoot 'sub') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $Script:SizeRoot 'sub\c.bin'), (New-Object byte[] 1024))

    It 'sums file sizes RECURSIVELY and rounds to the nearest KB' {
        Get-InstallEstimatedSizeKB -Path $Script:SizeRoot | Should Be 4
    }

    It 'returns 0 for a missing path (never throws)' {
        Get-InstallEstimatedSizeKB -Path (Join-Path $Script:SizeRoot 'does-not-exist') | Should Be 0
    }

    It 'returns 0 for an empty or null path' {
        Get-InstallEstimatedSizeKB -Path '' | Should Be 0
        Get-InstallEstimatedSizeKB -Path $null | Should Be 0
    }
}

Describe 'Get-InstallWindowTitle (fix 9: mirrors host\FurphyHost.cs AppConstants.WindowTitleFor(port) exactly)' {
    It 'the production port keeps the bare literal title' {
        Get-InstallWindowTitle -Port 47831 | Should Be 'Furphy Addon Manager'
    }
    It 'any other port gets the "[test <port>]" suffix - can never collide with a real production window' {
        Get-InstallWindowTitle -Port 47899 | Should Be 'Furphy Addon Manager [test 47899]'
        Get-InstallWindowTitle -Port 1 | Should Be 'Furphy Addon Manager [test 1]'
    }
}

Describe 'Get-InstallUninstallString (section 5.4: the converged try-server-else-copy+launch one-liner)' {
    It 'embeds the port, api url, install.ps1 path and -WowPath value in the documented shape' {
        $cmd = Get-InstallUninstallString -Port 47831 -AppDest 'C:\WoW\_retail_\AddonSync' -WowRootPath 'C:\WoW'
        $cmd | Should Match '^powershell\.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "'
        $cmd | Should Match ([regex]::Escape('http://localhost:47831/api/uninstall'))
        $cmd | Should Match ([regex]::Escape("Origin='http://localhost:47831'"))
        $cmd | Should Match ([regex]::Escape('C:\WoW\_retail_\AddonSync\install.ps1'))
        $cmd | Should Match ([regex]::Escape("'-WowPath','C:\WoW'"))
        $cmd | Should Match ([regex]::Escape('-Uninstall'))
    }

    It 'changes the port/appDest/wowRoot embedded in the string when the inputs change' {
        $a = Get-InstallUninstallString -Port 47831 -AppDest 'C:\A\_retail_\AddonSync' -WowRootPath 'C:\A'
        $b = Get-InstallUninstallString -Port 47899 -AppDest 'C:\B\_retail_\AddonSync' -WowRootPath 'C:\B'
        $a | Should Not Be $b
        $a | Should Not Match ([regex]::Escape('C:\B'))
        $b | Should Not Match ([regex]::Escape('C:\A'))
    }

    It 'doubles an embedded single quote in a path defensively (PowerShell single-quote literal escaping)' {
        $cmd = Get-InstallUninstallString -Port 47899 -AppDest "C:\Eric's WoW\_retail_\AddonSync" -WowRootPath "C:\Eric's WoW"
        $cmd | Should Match ([regex]::Escape("C:\Eric''s WoW"))
    }
}
