<#
  Integration tests (Pester 3 syntax): install.ps1 against a WoW root with
  EXACTLY ONE installed client - the retail-only machine, i.e. the most common
  real install. Round-36 regression: Get-InstalledFlavourDefs returned its
  List[object] with `return $result`, PowerShell unrolled the single item into
  a bare PSCustomObject, its .Count was empty, Find-WowRoot's
  `.Count -gt 0` check failed and a fresh console/wizard install ended with
  "Could not find a World of Warcraft installation". Two or more clients never
  hit it, and deploy.ps1 bypasses detection entirely, which is why the live
  machine never showed it.

  Scratch-only: the fixture lives under %TEMP%, the install runs with
  -NoShortcuts -NoProtocol -SkipAdopt -Console, settings.json is forced to
  port 47899, and the uninstall at the end runs against the same scratch root
  (install.ps1's per-install scoping keeps it off every production name).
  No server, no port, no registry outside the ".Test" names.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:InstallScript = Join-Path $Script:FurphyBuildRoot 'install.ps1'

function New-SingleFlavourWowRoot {
    $root = Join-Path $env:TEMP ('furphy-1fl-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $root '_retail_\Interface\AddOns') -Force | Out-Null
    # A realistic .build.info so flavour detection has something to read if it wants to.
    [IO.File]::WriteAllText((Join-Path $root '.build.info'), "Branch!STRING:0|Product!STRING:0|Version!STRING:0`r`nus|wow|12.1.0.69587`r`n")
    return $root
}

Describe 'Get-InstalledFlavourDefs with exactly one installed client (Round 36)' {
    . $Script:InstallScript
    $Script:OneRoot = New-SingleFlavourWowRoot

    AfterAll {
        if ($Script:OneRoot -and (Test-Path -LiteralPath $Script:OneRoot)) { Remove-Item -LiteralPath $Script:OneRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'the @(...) call-site pattern yields exactly one record for one client' {
        $r = @(Get-InstalledFlavourDefs -WowRootPath $Script:OneRoot)
        $r.Count | Should Be 1
        $r[0].Id | Should Be 'retail'
    }

    It 'every call site in install.ps1 wraps Get-InstalledFlavourDefs in @(...) (static guard)' {
        $src = Get-Content -Raw -LiteralPath $Script:InstallScript
        $calls = [regex]::Matches($src, '(?<!function )Get-InstalledFlavourDefs -WowRootPath')
        $wrapped = [regex]::Matches($src, '@\(Get-InstalledFlavourDefs -WowRootPath')
        $calls.Count | Should BeGreaterThan 0
        $wrapped.Count | Should Be $calls.Count
    }

    It 'returns an empty array (Count 0) for a root with no clients and for no root at all' {
        $empty = Join-Path $env:TEMP ('furphy-0fl-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        try {
            @(Get-InstalledFlavourDefs -WowRootPath $empty).Count | Should Be 0
            @(Get-InstalledFlavourDefs -WowRootPath '').Count | Should Be 0
        } finally { Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Find-WowRoot accepts a single-client override' {
        Find-WowRoot -Override $Script:OneRoot | Should Be $Script:OneRoot
    }
}

Describe 'install.ps1 console install succeeds on a single-client WoW root (Round 36)' {
    $Script:InstallRoot = New-SingleFlavourWowRoot

    AfterAll {
        if ($Script:InstallRoot -and (Test-Path -LiteralPath $Script:InstallRoot)) { Remove-Item -LiteralPath $Script:InstallRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'exits 0 and creates _retail_\AddonSync with the app files' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script:InstallScript -WowPath $Script:InstallRoot -NoShortcuts -NoProtocol -SkipAdopt -Console 2>&1
        $text = ($out | ForEach-Object { [string]$_ }) -join "`n"
        $LASTEXITCODE | Should Be 0
        $text | Should Not Match 'Could not find a World of Warcraft installation'
        $text | Should Not Match 'No known WoW client folder'
        $appDest = Join-Path $Script:InstallRoot '_retail_\AddonSync'
        (Test-Path -LiteralPath (Join-Path $appDest 'addon-server.ps1')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $appDest 'install.ps1')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $appDest 'settings.json')) | Should Be $true
    }

    It 'the scratch install uninstalls cleanly (scoped, quiet) and leaves production untouched' {
        $appDest = Join-Path $Script:InstallRoot '_retail_\AddonSync'
        $settingsPath = Join-Path $appDest 'settings.json'
        # Force the test port so every scoped name resolves to the .Test variants.
        [IO.File]::WriteAllText($settingsPath, '{ "releaseType": 1, "port": 47899 }')
        $runBefore = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).PSObject.Properties['FurphyAddonManager']
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script:InstallScript -WowPath $Script:InstallRoot -NoShortcuts -NoProtocol -Uninstall -Console -Quiet 2>&1
        $LASTEXITCODE | Should Be 0
        (Test-Path -LiteralPath (Join-Path $appDest 'addon-server.ps1')) | Should Be $false
        $runAfter = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).PSObject.Properties['FurphyAddonManager']
        ([string]$runAfter.Value) | Should Be ([string]$runBefore.Value)
    }
}
