<#
=====================================================================
 tests\integration\Install.Downgrade.Tests.ps1

 upgrade-1.1.0:upgrade-1.1.0-downgrade-hides-addons regression test.

 Running an OLDER installer (e.g. a stale cached dist zip's own
 install.ps1) over a current, already-migrated install used to silently
 downgrade addon-sync.ps1/addon-server.ps1/ui\ to pre-flavour code while
 leaving settings.json's schemaVersion untouched - the old code has no
 idea flavours\<id>\addons.json exists, so it reports the user has ZERO
 tracked addons even though nothing was actually deleted on disk.
 Invoke-FurphyInstallSteps now refuses to copy an older installer's code
 over a newer on-disk VERSION unless -Force is passed.

 Scratch-only: every install this file runs uses -NoShortcuts -NoProtocol
 -SkipAdopt -Console against a fixture WoW root under tests\.tmp\, with
 settings.json forced to this round's assigned scratch port (47903) before
 any install ever runs, per the build round's hard rules.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:InstallScript = Join-Path $Script:FurphyBuildRoot 'install.ps1'

function New-DowngradeTestWowRoot {
    $rootPath = Join-Path $env:TEMP ('furphy-downgrade-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $rootPath '_retail_\Interface\AddOns') -Force | Out-Null
    return $rootPath
}

function New-StaleInstallerSource {
    <#
      A COMPLETE copy of the current build root's own app files (so a
      -Force run has everything it needs to actually install), with just
      the VERSION file swapped for an older one - mirrors "an old dist
      zip's own install.ps1" without needing a real historical zip on
      disk.
    #>
    param([Parameter(Mandatory = $true)][string]$StaleVersion)

    $staleSrc = Join-Path $env:TEMP ('furphy-stalesrc-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $staleSrc -Force | Out-Null
    foreach ($f in @('install.ps1', 'addon-sync.ps1', 'addon-server.ps1', 'Addon Manager.vbs', 'curseforge-handler.vbs', 'register-protocol.ps1', 'README.txt', 'CHANGELOG.md', 'icon.ico')) {
        $s = Join-Path $Script:FurphyBuildRoot $f
        if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination (Join-Path $staleSrc $f) -Force }
    }
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'ui') -Destination (Join-Path $staleSrc 'ui') -Recurse -Force
    $StaleVersion | Set-Content -LiteralPath (Join-Path $staleSrc 'VERSION') -Encoding Ascii -NoNewline
    return $staleSrc
}

Describe 'install.ps1 downgrade guard (upgrade-1.1.0:upgrade-1.1.0-downgrade-hides-addons)' {

    It 'refuses an older installer over a newer on-disk install: code/ui/settings unchanged, warns, exits 0' {
        $wowRoot = New-DowngradeTestWowRoot
        $staleSrc = New-StaleInstallerSource -StaleVersion '1.1.0'
        $appDest = Join-Path $wowRoot '_retail_\AddonSync'

        try {
            $fresh = Invoke-CliProcess -ScriptPath $Script:InstallScript -ArgumentList @('-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-SkipAdopt', '-Console') -TimeoutSec 120
            $fresh.ExitCode | Should Be 0
            '{ "releaseType": 1, "port": 47903 }' | Set-Content -LiteralPath (Join-Path $appDest 'settings.json') -Encoding Ascii

            $currentVersion = (Get-Content -LiteralPath (Join-Path $appDest 'VERSION')).Trim()
            $beforeHash = (Get-FileHash -LiteralPath (Join-Path $appDest 'addon-server.ps1') -Algorithm SHA256).Hash
            $beforeSettings = Get-Content -Raw -LiteralPath (Join-Path $appDest 'settings.json')
            $beforeUi = (Get-FileHash -LiteralPath (Join-Path $appDest 'ui\app.js') -Algorithm SHA256).Hash

            $stale = Invoke-CliProcess -ScriptPath (Join-Path $staleSrc 'install.ps1') -ArgumentList @('-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-SkipAdopt', '-Console') -TimeoutSec 120
            # (a) code/ui/settings unchanged
            $stale.ExitCode | Should Be 0
            (Get-Content -LiteralPath (Join-Path $appDest 'VERSION')).Trim() | Should Be $currentVersion
            (Get-FileHash -LiteralPath (Join-Path $appDest 'addon-server.ps1') -Algorithm SHA256).Hash | Should Be $beforeHash
            (Get-FileHash -LiteralPath (Join-Path $appDest 'ui\app.js') -Algorithm SHA256).Hash | Should Be $beforeUi
            (Get-Content -Raw -LiteralPath (Join-Path $appDest 'settings.json')) | Should Be $beforeSettings

            # (b) console output contains the downgrade warning
            $stale.StdOut | Should Match 'older than what''s already installed'
            $stale.StdOut | Should Match '1\.1\.0'
            $stale.StdOut | Should Match ([regex]::Escape($currentVersion))

            # (c) -Force proceeds with the copy exactly as today
            $forced = Invoke-CliProcess -ScriptPath (Join-Path $staleSrc 'install.ps1') -ArgumentList @('-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-SkipAdopt', '-Console', '-Force') -TimeoutSec 120
            $forced.ExitCode | Should Be 0
            (Get-Content -LiteralPath (Join-Path $appDest 'VERSION')).Trim() | Should Be '1.1.0'
        } finally {
            if (Test-Path -LiteralPath $wowRoot) { Remove-Item -LiteralPath $wowRoot -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $staleSrc) { Remove-Item -LiteralPath $staleSrc -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'a same-version repair run is NOT treated as a downgrade (copy proceeds normally, no warning)' {
        $wowRoot = New-DowngradeTestWowRoot
        $appDest = Join-Path $wowRoot '_retail_\AddonSync'
        try {
            $fresh = Invoke-CliProcess -ScriptPath $Script:InstallScript -ArgumentList @('-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-SkipAdopt', '-Console') -TimeoutSec 120
            $fresh.ExitCode | Should Be 0
            '{ "releaseType": 1, "port": 47903 }' | Set-Content -LiteralPath (Join-Path $appDest 'settings.json') -Encoding Ascii

            # Re-run the SAME (current) install.ps1 again - a normal repair,
            # never a downgrade.
            $repair = Invoke-CliProcess -ScriptPath $Script:InstallScript -ArgumentList @('-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-SkipAdopt', '-Console') -TimeoutSec 120
            $repair.ExitCode | Should Be 0
            $repair.StdOut | Should Not Match 'older than what''s already installed'
            (Test-Path -LiteralPath (Join-Path $appDest 'addon-server.ps1')) | Should Be $true
        } finally {
            if (Test-Path -LiteralPath $wowRoot) { Remove-Item -LiteralPath $wowRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
