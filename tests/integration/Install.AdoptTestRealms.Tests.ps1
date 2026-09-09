<#
=====================================================================
 tests\integration\Install.AdoptTestRealms.Tests.ps1

 multi-client:install-adopt-loop-includes-hidden-ptr-flavour regression
 test.

 FLAVORS-SPEC.md S2.5 says PTR/XPTR/Beta stay "detected but excluded from
 the switcher and from tray background sync by default" until the player
 turns on Settings > Advanced > "Show test realms". install.ps1's
 first-run "Adopt existing addon folders" step used to iterate the
 UNFILTERED installed-flavour list (PTR/XPTR/Beta included) rather than
 the first-class-only subset every other multi-flavour surface
 (Store.visibleFlavours() in ui/app.js, addon-server.ps1's
 update-all-flavours fan-out) already respects - a first-time install on
 a machine with a live PTR client would scan and offer to take over PTR
 addons before the player ever opted into seeing/managing PTR anywhere
 else in the app. The loop now iterates $script:firstClassInstalled.

 No live CurseForge/Wago traffic: since the untracked PTR addon is
 filtered OUT of the loop before any -Scan/-Add call is ever made for
 that flavour, and the fixture's retail AddOns folder has nothing
 untracked either, this test never triggers a real network call.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:InstallScript = Join-Path $Script:FurphyBuildRoot 'install.ps1'

function New-PtrAdoptWowRoot {
    $rootPath = Join-Path $env:TEMP ('furphy-ptradopt-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $rootPath '_retail_\Interface\AddOns') -Force | Out-Null
    $ptrAddonDir = Join-Path $rootPath '_ptr_\Interface\AddOns\SomePtrAddon'
    New-Item -ItemType Directory -Path $ptrAddonDir -Force | Out-Null
    @'
## Interface: 120100
## Title: Some Ptr Addon
## Version: 1.0.0
## X-Curse-Project-ID: 925037
'@ | Set-Content -LiteralPath (Join-Path $ptrAddonDir 'SomePtrAddon.toc') -Encoding Ascii
    return $rootPath
}

Describe 'install.ps1 adopt loop excludes PTR by default (multi-client:install-adopt-loop-includes-hidden-ptr-flavour)' {

    It 'a Retail+PTR machine never scans/adopts the untracked PTR addon on a default first install' {
        $wowRoot = New-PtrAdoptWowRoot
        $appDest = Join-Path $wowRoot '_retail_\AddonSync'
        try {
            $result = Invoke-CliProcess -ScriptPath $Script:InstallScript -ArgumentList @('-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-Console') -TimeoutSec 120
            $result.ExitCode | Should Be 0

            # Never scanned/offered PTR at all - no "-- PTR --" header (the
            # OLD bug: $showFlavourHeader keyed off the unfiltered count),
            # and the untracked addon was left completely alone.
            $result.StdOut | Should Not Match '-- PTR --'
            (Test-Path -LiteralPath (Join-Path $appDest 'flavours\ptr')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $appDest 'flavours\ptr\addons.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $wowRoot '_ptr_\Interface\AddOns\SomePtrAddon\SomePtrAddon.toc')) | Should Be $true
        } finally {
            if (Test-Path -LiteralPath $wowRoot) { Remove-Item -LiteralPath $wowRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'a Retail-only machine (no PTR installed) is unaffected by the filter (adopt step still runs for retail)' {
        $rootPath = Join-Path $env:TEMP ('furphy-ptradopt-none-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path (Join-Path $rootPath '_retail_\Interface\AddOns') -Force | Out-Null
        $appDest = Join-Path $rootPath '_retail_\AddonSync'
        try {
            $result = Invoke-CliProcess -ScriptPath $Script:InstallScript -ArgumentList @('-WowPath', $rootPath, '-NoShortcuts', '-NoProtocol', '-Console') -TimeoutSec 120
            $result.ExitCode | Should Be 0
            # ADOPT-SPEC.md 3.4/3.5: "Looking for existing addons to take
            # over" (re-download-and-overwrite wording) was replaced with
            # "Looking for addons you already have" (no-download, honest
            # wording) - see Install.AdoptWording.Tests.ps1 for the full
            # wording regression suite.
            $result.StdOut | Should Match 'Looking for addons you already have'
            $result.StdOut | Should Not Match 'Could not read scan results'
        } finally {
            if (Test-Path -LiteralPath $rootPath) { Remove-Item -LiteralPath $rootPath -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
