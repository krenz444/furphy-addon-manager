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

    # security:security-install-uninstall-wowpath-arg-splitting regression:
    # the fallback used to build -ArgumentList as a comma-separated array
    # literal ('-NoProfile','-ExecutionPolicy',...,'-WowPath','$wowRootEsc',
    # ...) - Start-Process joins array elements with a bare, unquoted space
    # under PS 5.1, so a WoW root containing a space (the DEFAULT Windows
    # install path, "C:\Program Files (x86)\World of Warcraft\_retail_")
    # got split into extra argv tokens by the relaunched child, truncating
    # -WowPath. Fixed by having the inner fallback script build ONE
    # pre-quoted argument string instead.
    It 'no longer embeds the vulnerable comma-array -ArgumentList shape' {
        $cmd = Get-InstallUninstallString -Port 47831 -AppDest 'C:\Program Files (x86)\World of Warcraft\_retail_\AddonSync' -WowRootPath 'C:\Program Files (x86)\World of Warcraft'
        $cmd | Should Not Match "'-NoProfile','-ExecutionPolicy'"
        $cmd | Should Not Match "'-WowPath','"
        # The new shape: the inner script builds one $fArgs string via
        # [char]34-based double-quoting, never a literal " character
        # embedded directly in the outer -Command "..." body (which would
        # prematurely terminate that outer double-quoted wrapper).
        $cmd | Should Match ([regex]::Escape('[char]34'))
        $cmd | Should Not Match '""'
    }

    It 'the inner fallback script is syntactically valid PowerShell (parses with zero errors)' {
        $cmd = Get-InstallUninstallString -Port 47831 -AppDest 'C:\Program Files (x86)\World of Warcraft\_retail_\AddonSync' -WowRootPath 'C:\Program Files (x86)\World of Warcraft'
        if ($cmd -notmatch '-Command "(.*)"$') { throw 'could not extract the inner -Command body from the generated string' }
        $inner = $Matches[1]
        $parseErrors = $null
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($inner, [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count | Should Be 0
    }

    It 'end-to-end: a WowRootPath containing a space AND parens (the real default install path shape) reaches the relaunched child untruncated' {
        # Isolated repro matching the QA finding's own methodology: a stub
        # "install.ps1" that just logs its own bound -WowPath, then
        # actually execute the generated command line (as Windows would
        # execute a registry UninstallString) against a port nothing is
        # listening on, so the try{} branch fails fast and the catch{}
        # fallback (the vulnerable code path) actually runs.
        $stubRoot = New-TempRoot -Name 'uninstallstring-e2e'
        $stubAppDest = Join-Path $stubRoot 'World of Warcraft (x86)\_retail_\AddonSync'
        New-Item -ItemType Directory -Force -Path $stubAppDest | Out-Null
        $stubInstallPs1 = Join-Path $stubAppDest 'install.ps1'
        @'
param([string]$WowPath, [switch]$Uninstall, [switch]$NoShortcuts, [switch]$NoProtocol, [switch]$Console, [switch]$Quiet)
$logPath = Join-Path $env:TEMP ('furphy-unit-uninstallstring-' + $PID + '.txt')
"WowPathReceived=[$WowPath]`nUninstallSwitch=[$Uninstall]`nRawExtraArgs=[$($args -join '|')]" | Set-Content -LiteralPath $logPath -Encoding Ascii
'@ | Set-Content -LiteralPath $stubInstallPs1 -Encoding Ascii

        $wowRootWithSpaceAndParens = Join-Path $stubRoot 'World of Warcraft (x86)'
        $logPath = $null
        try {
            $cmd = Get-InstallUninstallString -Port 47903 -AppDest $stubAppDest -WowRootPath $wowRootWithSpaceAndParens
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'powershell.exe'
            $psi.Arguments = $cmd.Substring('powershell.exe '.Length)
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.WaitForExit(20000) | Out-Null

            $logFound = $false
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline) {
                $candidates = @(Get-ChildItem -Path $env:TEMP -Filter 'furphy-unit-uninstallstring-*.txt' -ErrorAction SilentlyContinue)
                if ($candidates.Count -gt 0) { $logPath = $candidates[0].FullName; $logFound = $true; break }
                Start-Sleep -Milliseconds 300
            }
            $logFound | Should Be $true

            $content = Get-Content -Raw -LiteralPath $logPath
            $content | Should Match ([regex]::Escape("WowPathReceived=[$wowRootWithSpaceAndParens]"))
            $content | Should Match 'UninstallSwitch=\[True\]'
            $content | Should Match 'RawExtraArgs=\[\]'
        } finally {
            if ($logPath -and (Test-Path -LiteralPath $logPath)) { Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $stubRoot) { Remove-Item -LiteralPath $stubRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'install.ps1 -Uninstall self-relaunch safety net (security:security-install-uninstall-wowpath-arg-splitting)' {
    # Mirrors the QA finding's own isolated repro shape exactly: builds
    # $relaunchArgs the same way the -Uninstall block does (now via
    # ConvertTo-SafeProcessArg on every element) and actually executes it
    # via Start-Process -ArgumentList against a stub that echoes its own
    # bound -WowPath, with a WowRootPath containing a space AND parens
    # (the real default "C:\Program Files (x86)\World of
    # Warcraft\_retail_" shape).
    It 'ConvertTo-SafeProcessArg is defined above the dot-source guard (loads without running the installer)' {
        (Get-Command ConvertTo-SafeProcessArg -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
    }

    It 'a WowRootPath with a space and parens reaches the relaunched child untruncated via the fixed ArgumentList shape' {
        $stubRoot = New-TempRoot -Name 'relaunch-argsplit-e2e'
        $stubInstallPs1 = Join-Path $stubRoot 'install.ps1'
        @'
param([string]$WowPath, [switch]$Uninstall, [switch]$NoShortcuts, [switch]$NoProtocol)
$logPath = Join-Path $env:TEMP ('furphy-unit-relaunchargs-' + $PID + '.txt')
"WowPathReceived=[$WowPath]`nUninstallSwitch=[$Uninstall]`nRawExtraArgs=[$($args -join '|')]" | Set-Content -LiteralPath $logPath -Encoding Ascii
'@ | Set-Content -LiteralPath $stubInstallPs1 -Encoding Ascii

        $wowRoot = Join-Path $stubRoot 'Program Files (x86)\World of Warcraft'
        $logPath = $null
        try {
            $relaunchArgs = New-Object 'System.Collections.Generic.List[string]'
            $relaunchArgs.Add((ConvertTo-SafeProcessArg '-NoProfile')); $relaunchArgs.Add((ConvertTo-SafeProcessArg '-ExecutionPolicy')); $relaunchArgs.Add((ConvertTo-SafeProcessArg 'Bypass'))
            $relaunchArgs.Add((ConvertTo-SafeProcessArg '-File')); $relaunchArgs.Add((ConvertTo-SafeProcessArg $stubInstallPs1))
            $relaunchArgs.Add((ConvertTo-SafeProcessArg '-WowPath')); $relaunchArgs.Add((ConvertTo-SafeProcessArg $wowRoot))
            $relaunchArgs.Add((ConvertTo-SafeProcessArg '-Uninstall'))

            $relaunchProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunchArgs.ToArray() -NoNewWindow -PassThru -Wait

            $candidates = @(Get-ChildItem -Path $env:TEMP -Filter 'furphy-unit-relaunchargs-*.txt' -ErrorAction SilentlyContinue)
            $candidates.Count | Should BeGreaterThan 0
            $logPath = $candidates[0].FullName
            $content = Get-Content -Raw -LiteralPath $logPath
            $content | Should Match ([regex]::Escape("WowPathReceived=[$wowRoot]"))
            $content | Should Match 'UninstallSwitch=\[True\]'
            $content | Should Match 'RawExtraArgs=\[\]'
        } finally {
            if ($logPath -and (Test-Path -LiteralPath $logPath)) { Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $stubRoot) { Remove-Item -LiteralPath $stubRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Test-IsTempUninstallScriptCopy (novice:NOVICE-3: gates the -Uninstall block''s trailing self-delete)' {
    It 'true for a %TEMP%\FurphyUninstall-<hex>.ps1 shaped path' {
        $p = Join-Path $env:TEMP ('FurphyUninstall-' + [guid]::NewGuid().ToString('N') + '.ps1')
        Test-IsTempUninstallScriptCopy -Path $p | Should Be $true
    }

    It 'false for the build root''s own install.ps1 (never deletes the source/app-folder copy a developer is running directly)' {
        Test-IsTempUninstallScriptCopy -Path $Script:InstallScript | Should Be $false
    }

    It 'false for a correctly-named file outside %TEMP%' {
        $p = Join-Path (Split-Path -Path $env:TEMP -Parent) ('FurphyUninstall-' + [guid]::NewGuid().ToString('N') + '.ps1')
        Test-IsTempUninstallScriptCopy -Path $p | Should Be $false
    }

    It 'false for a differently-named file inside %TEMP%' {
        Test-IsTempUninstallScriptCopy -Path (Join-Path $env:TEMP 'NotAFurphyFile.ps1') | Should Be $false
    }

    It 'false for null/empty' {
        Test-IsTempUninstallScriptCopy -Path $null | Should Be $false
        Test-IsTempUninstallScriptCopy -Path '' | Should Be $false
    }
}
