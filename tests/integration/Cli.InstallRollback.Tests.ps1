<#
=====================================================================
 tests\integration\Cli.InstallRollback.Tests.ps1

 A real -Flavor classic_era CurseForge install/update cycle (tagged
 'Network' - skipped by -Quick/-NoNetwork), a bogus project id failing with
 a clear per-row message, rollback with a missing backup failing cleanly
 (fully offline), and install.ps1's legacy-launcher-file/shortcut cleanup
 now running on a plain upgrade (no -Uninstall flag), not just uninstall
 (Round 34 - see CHANGELOG.md).

 Renamed from Cli.InstallRollbackLauncher.Tests.ps1 (Round 34): the four
 -Launcher-specific Describes this file used to carry (dry behaviour,
 skip-if-recently-checked, does-NOT-skip-when-stale, two-real-child-
 processes self-write race) were removed along with the CLI's -Launcher
 mode itself - removed at Eric's request, 2026-09-07, see CHANGELOG.md
 Round 34. "Launcher" no longer describes anything left in this file.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

Describe 'Real CurseForge install into classic_era_ (AtlasLootClassic, project 326516)' -Tags 'Network' {
    $wowRoot = Copy-Fixture
    $cliPath = Join-Path (New-TempRoot -Name 'cli-install') 'addon-sync.ps1'
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force
    $projectId = 326516

    It 'installs a real classic-era-compatible file and reports Installed' {
        $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 90 -ArgumentList @(
            '-Add', $projectId, '-Flavor', 'classic_era', '-Json', '-WowRoot', $wowRoot)
        $r.ExitCode | Should Be 0
        $row = @($r.Json.results) | Where-Object { [string]$_.projectId -eq [string]$projectId }
        @($row).Count | Should Be 1
        $row[0].status | Should Be 'Installed'
        ([string]::IsNullOrEmpty($row[0].fileId)) | Should Be $false
        ([string]::IsNullOrEmpty($row[0].version)) | Should Be $false

        $addonsPath = Join-Path $wowRoot '_classic_era_\Interface\AddOns'
        (Test-Path -LiteralPath (Join-Path $addonsPath 'AtlasLootClassic') -PathType Container) | Should Be $true

        $record = @($r.Json.addons) | Where-Object { [string]$_.projectId -eq [string]$projectId }
        @($record).Count | Should Be 1
        $record[0].source | Should Not Be 'wago'
    }

    It 'running again (no -Force) reports Up-to-date for that same addon' {
        $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 90 -ArgumentList @(
            '-Only', $projectId, '-Flavor', 'classic_era', '-Json', '-WowRoot', $wowRoot)
        $r.ExitCode | Should Be 0
        $row = @($r.Json.results) | Where-Object { [string]$_.projectId -eq [string]$projectId }
        @($row).Count | Should Be 1
        $row[0].status | Should Be 'Up-to-date'
    }
}

Describe 'a bogus/nonexistent project id fails with a clear per-row message' -Tags 'Network' {
    $wowRoot = Copy-Fixture
    $cliPath = Join-Path (New-TempRoot -Name 'cli-bogus') 'addon-sync.ps1'
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force

    It 'reports a clean non-install status naming the project id, with the real reason in sync.log, and exits 0' {
        # A -Add for a project id CurseForge has no file for (never existed,
        # or exists but has nothing matching this client's flavour) comes
        # back "Skipped", not "Failed" - addon-sync.ps1 treats "no
        # installable file was found" as declining to create a placeholder
        # record at all (confirmed live: no record is added to addons.json)
        # rather than an error condition. Either way the row's Name always
        # cites "project <id>" and the real "No <flavour> file found for
        # project <id>" reason lands in sync.log - that citation, not any
        # specific status string, is the "clear message" this test checks.
        $bogusId = 999999999
        $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 60 -ArgumentList @(
            '-Add', $bogusId, '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot)
        $r.ExitCode | Should Be 0
        $row = @($r.Json.results) | Where-Object { [string]$_.projectId -eq [string]$bogusId }
        @($row).Count | Should Be 1
        (@('Skipped', 'Failed') -contains $row[0].status) | Should Be $true
        ($row[0].name -like "*$bogusId*") | Should Be $true
        @($r.Json.addons).Count | Should Be 0

        $syncLog = Join-Path (Split-Path -Path $cliPath -Parent) 'sync.log'
        $logText = Get-Content -LiteralPath $syncLog -Raw
        ($logText -like "*$bogusId*") | Should Be $true
    }
}

Describe 'rollback with no recorded previous version fails cleanly (fully offline)' {
    $wowRoot = Copy-Fixture
    $tempRoot = New-TempRoot -Name 'cli-rollback'
    $cliPath = Join-Path $tempRoot 'addon-sync.ps1'
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force

    # Hand-crafted addons.json record for retail with NO previousFileId (as
    # a fresh install always looks - previousFileId is only ever set on an
    # UPDATE, never a first install) and no backup zip on disk at all -
    # Invoke-RollbackForRecord's documented "Failed (no network) when
    # previousFileId is null" path, entirely local/offline.
    #
    # addons.json/settings.json/flavours\ live next to addon-sync.ps1 ITSELF
    # (per the script's own header comment - "relative to the folder this
    # script lives in"), never under -WowRoot (which only affects flavour/
    # AddOns-path DETECTION) - so this must sit under $tempRoot, not $wowRoot.
    $flavourDir = Join-Path $tempRoot 'flavours\retail'
    New-Item -ItemType Directory -Path $flavourDir -Force | Out-Null
    $record = [PSCustomObject]@{
        name          = 'SingleFlavourAddon'
        projectId     = 424242
        fileId        = 1000
        version       = '1.0.0'
        fileName      = 'SingleFlavourAddon-1.0.0.zip'
        installedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        folders       = @('SingleFlavourAddon')
        author        = $null
        ignoreUpdates = $false
        pinnedFileId  = $null
        releaseType   = $null
        previousFileId  = $null
        previousVersion = $null
    }
    $recordsPath = Join-Path $flavourDir 'addons.json'
    ConvertTo-Json -InputObject @($record) -Depth 6 | Set-Content -LiteralPath $recordsPath -Encoding UTF8

    It 'reports Failed for that project id, no network, no crash' {
        $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 30 -ArgumentList @(
            '-Rollback', 424242, '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot)
        $r.ExitCode | Should Be 0
        $row = @($r.Json.results) | Where-Object { [string]$_.projectId -eq '424242' }
        @($row).Count | Should Be 1
        $row[0].status | Should Be 'Failed'
    }
}

Describe 'install.ps1 upgrade path removes legacy launcher files (Round 34, CS-R12)' {
    # Round 34 (removed at Eric's request, 2026-09-07): -Launcher/the
    # per-flavour launcher pair is gone from install.ps1's own write path
    # (CS-R11), but an existing install from before this round still has
    # the files sitting on disk. Before this fix, the cleanup loop for
    # them only ran under -Uninstall - a plain upgrade (install.ps1 run
    # again, no -Uninstall, exactly what shipping this removal does) left
    # them behind forever. This proves the cleanup now also runs
    # unconditionally from inside Invoke-FurphyInstallSteps, on every
    # install/upgrade.
    #
    # -NoShortcuts is always passed here, same as every other test in
    # this suite: [Environment]::GetFolderPath('Desktop') always resolves
    # the REAL machine Desktop with no way to scope/redirect it (see
    # install.ps1's own CS-F5 incident comment above its shortcut-removal
    # block), so a builder-level automated test must never omit
    # -NoShortcuts. That means the Desktop-shortcut half of CS-R12's
    # cleanup is exercised only by the by-hand deploy checklist
    # (SPEC.md/DISTRIBUTION-SPEC.md section 4), never here. The
    # per-flavour launcher-file removal loop this Describe DOES cover is
    # unconditional on -NoShortcuts (it is a separate loop, gated only on
    # -Uninstall today, moved to run on upgrade too by CS-R12) - safe to
    # exercise directly.
    $wowRoot = Copy-Fixture

    # Seed a stale launcher pair under _retail_, mimicking a
    # pre-2026-09-06 install.
    $retailDir = Join-Path $wowRoot '_retail_'
    $legacyCmd = Join-Path $retailDir 'update-addons-and-launch.cmd'
    $legacyVbs = Join-Path $retailDir 'Launch WoW (Updated).vbs'
    Set-Content -LiteralPath $legacyCmd -Value '@echo off' -Encoding ASCII
    Set-Content -LiteralPath $legacyVbs -Value "' legacy launcher" -Encoding ASCII

    It 'a plain upgrade run (no -Uninstall) removes the stale launcher pair' {
        (Test-Path -LiteralPath $legacyCmd) | Should Be $true
        (Test-Path -LiteralPath $legacyVbs) | Should Be $true

        $installScript = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'install.ps1'
        $r = Invoke-CliProcess -ScriptPath $installScript -TimeoutSec 90 -ArgumentList @(
            '-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-SkipAdopt', '-Console')
        $r.ExitCode | Should Be 0

        (Test-Path -LiteralPath $legacyCmd) | Should Be $false
        (Test-Path -LiteralPath $legacyVbs) | Should Be $false
    }
}

Describe 'install.ps1 writes no launcher files on a fresh install (Round 34, CS-R11 companion)' {
    # Companion to the upgrade-path cleanup Describe above: a brand-new
    # install must never CREATE update-addons-and-launch.cmd/Launch WoW
    # (Updated).vbs anywhere under the WoW root in the first place.
    # -NoShortcuts is passed for the same real-Desktop reason noted above
    # - "exactly one Desktop shortcut, Furphy Addon Manager.lnk" is
    # verified by the by-hand deploy checklist, not here.
    $wowRoot = Copy-Fixture

    It 'creates no legacy launcher file anywhere under the WoW root' {
        $installScript = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'install.ps1'
        $r = Invoke-CliProcess -ScriptPath $installScript -TimeoutSec 90 -ArgumentList @(
            '-WowPath', $wowRoot, '-NoShortcuts', '-NoProtocol', '-SkipAdopt', '-Console')
        $r.ExitCode | Should Be 0

        # Named-file match, not a blanket *.cmd/*.vbs extension search: a
        # normal install legitimately ships its own Addon Manager.vbs and
        # curseforge-handler.vbs into $appDest (install.ps1's $codeFiles,
        # unconditional on -NoShortcuts/-NoProtocol - those flags gate only
        # the real-Desktop shortcut and the curseforge:// registry
        # registration, not the app payload itself), so an extension-only
        # filter always finds those 2 legitimate files and can never read
        # 0 here. This Describe's actual claim (see the docstring above) is
        # only about the two named legacy files never being created.
        $legacyNames = @('update-addons-and-launch.cmd', 'Launch WoW (Updated).vbs')
        $stray = Get-ChildItem -LiteralPath $wowRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in $legacyNames }
        @($stray).Count | Should Be 0
    }
}
