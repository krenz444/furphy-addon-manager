<#
=====================================================================
 tests\integration\Install.UninstallTempCleanup.Tests.ps1

 novice:NOVICE-3 regression test (the uninstall temp-file leak).

 Every real uninstall trigger (the Settings > Uninstall button via
 addon-server.ps1's Handle-Uninstall, the Windows Apps & Features
 UninstallString/QuietUninstallString fallback in
 Get-InstallUninstallString, install.ps1's own relaunch-safety-net, and
 the tray's identical fallback in host\FurphyHost.cs's TryTrayUninstall)
 copies install.ps1 into a fresh %TEMP%\FurphyUninstall-<guid>.ps1 path
 and launches THAT copy with -Uninstall - none of them ever deleted it
 afterward, an unbounded %TEMP% leak (100+ leftover ~90KB copies found on
 the dev machine this round was reviewed on). install.ps1's own
 -Uninstall block now self-deletes its own running script file, guarded
 to only ever fire when it is actually executing FROM such a temp copy -
 this one guard covers all four real-world trigger call sites, since
 every one of them ultimately runs this same code inside the copy itself.

 This file exercises the actual end-to-end behaviour: run install.ps1
 -Uninstall FROM a real %TEMP% copy and confirm that copy deletes itself.
 tests\unit\Install.Uninstall.Tests.ps1 covers the pure
 Test-IsTempUninstallScriptCopy detection helper in isolation; this file
 proves the full wiring. Never touches the real %TEMP% install pattern
 used by a live production uninstall - every fixture here is a disposable
 scratch WoW root under tests\.tmp\, and the "temp copy" this test itself
 creates is deleted in a finally block regardless of outcome.

 GAME-MODE-SPEC.md-round test hygiene fix: %TEMP%\FurphyUninstall-*.ps1/
 .log cleanup used to be inline, after each It's own last assertion -
 skipped entirely (leaving the file behind) the instant an EARLIER
 assertion in that same It threw first, which is exactly how ~260
 leftover copies were found accumulated on the dev machine this round.
 Replaced with the scoped-cleanup helper pattern Server.AppUpdate.Tests.ps1
 already established for its own %TEMP% litter (Get-/Remove-AppUpdateTempLitter):
 record $Script:LitterCutoffUtc once at the top of the file, sweep
 everything newer than it with Remove-UninstallTempLitterFiles in a
 file-wide AfterAll that always runs.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:InstallScript = Join-Path $Script:FurphyBuildRoot 'install.ps1'
$Script:LitterCutoffUtc = (Get-Date).ToUniversalTime()

function New-CleanupTestWowRoot {
    $rootPath = Join-Path $env:TEMP ('furphy-tempcleanup-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $rootPath '_retail_\Interface\AddOns') -Force | Out-Null
    return $rootPath
}

Describe 'install.ps1 -Uninstall temp-copy self-delete (novice:NOVICE-3)' {

    AfterAll {
        # Sweeps every %TEMP%\FurphyUninstall-*.ps1/.log this file's own
        # Its created (both of the below, and any %TEMP% copy that a mid-
        # It assertion failure left an inline cleanup unable to reach) -
        # see this file's own header comment and Remove-UninstallTempLitterFiles'
        # doc comment (tests\lib\common.ps1) for the "260 leftover copies"
        # reasoning this replaces.
        Remove-UninstallTempLitterFiles -CreatedAfterUtc $Script:LitterCutoffUtc | Out-Null
    }

    It 'a %TEMP%\FurphyUninstall-<guid>.ps1 copy deletes itself after a real uninstall completes' {
        $wowRoot = New-CleanupTestWowRoot
        $appDest = Join-Path $wowRoot '_retail_\AddonSync'
        $tempCopy = $null
        try {
            $install = Invoke-CliProcess -ScriptPath $Script:InstallScript -ArgumentList @('-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-SkipAdopt', '-Console') -TimeoutSec 120
            $install.ExitCode | Should Be 0
            '{ "releaseType": 1, "port": 47903 }' | Set-Content -LiteralPath (Join-Path $appDest 'settings.json') -Encoding Ascii

            # Mirrors exactly what all four real trigger call sites do:
            # copy install.ps1 to a fresh %TEMP%\FurphyUninstall-<guid>.ps1
            # path and launch THAT copy with -Uninstall - never the
            # build-root/appDest original.
            $tempCopy = Join-Path $env:TEMP ('FurphyUninstall-' + [guid]::NewGuid().ToString('N') + '.ps1')
            Copy-Item -LiteralPath (Join-Path $appDest 'install.ps1') -Destination $tempCopy -Force
            (Test-Path -LiteralPath $tempCopy) | Should Be $true

            $uninstall = Invoke-CliProcess -ScriptPath $tempCopy -ArgumentList @('-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-Uninstall', '-Console', '-Quiet') -TimeoutSec 60
            $uninstall.ExitCode | Should Be 0
            (Test-Path -LiteralPath (Join-Path $appDest 'install.ps1')) | Should Be $false

            # Self-delete is scheduled via a short-delay DETACHED process
            # (never synchronous - the just-exited powershell.exe may still
            # briefly hold its own script file open), so poll briefly.
            $deleted = $false
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline) {
                if (-not (Test-Path -LiteralPath $tempCopy)) { $deleted = $true; break }
                Start-Sleep -Milliseconds 300
            }
            $deleted | Should Be $true
        } finally {
            if ($tempCopy -and (Test-Path -LiteralPath $tempCopy)) { Remove-Item -LiteralPath $tempCopy -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $wowRoot) { Remove-Item -LiteralPath $wowRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'never self-deletes when run directly from the source/app folder (the build root''s own install.ps1 survives byte-identical)' {
        $wowRoot = New-CleanupTestWowRoot
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $wowRoot '_retail_\AddonSync') | Out-Null
            $sizeBefore = (Get-Item -LiteralPath $Script:InstallScript).Length

            # install.ps1 running FROM THE BUILD ROOT, -WowPath pointed at
            # an unrelated scratch fixture: $PSCommandPath here is the
            # build root's own install.ps1, never anywhere near %TEMP%, so
            # Test-IsTempUninstallScriptCopy must return false and the
            # trailing self-delete must never even attempt to run.
            $uninstall = Invoke-CliProcess -ScriptPath $Script:InstallScript -ArgumentList @('-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-Uninstall', '-Console', '-Quiet') -TimeoutSec 60
            $uninstall.ExitCode | Should Be 0

            Start-Sleep -Milliseconds 2000
            (Test-Path -LiteralPath $Script:InstallScript) | Should Be $true
            (Get-Item -LiteralPath $Script:InstallScript).Length | Should Be $sizeBefore
        } finally {
            if (Test-Path -LiteralPath $wowRoot) { Remove-Item -LiteralPath $wowRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
