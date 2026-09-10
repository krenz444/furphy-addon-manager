<#
=====================================================================
 tests\integration\Github.PublicRepoAddAndUpdate.Tests.ps1

 GITHUB-SOURCE-SPEC.md 7.3, scenario 1: a real CLI -Add/-Only/-Rollback
 cycle against a public (no token needed) GitHub repo, driven through the
 REAL addon-sync.ps1 as a child process (Invoke-CliJson/-CliProcess -
 never a direct in-process function call) with
 $env:FURPHY_TEST_GITHUB_BASEURL pointed at a real local
 Start-GitHubReleaseStubServer stub for the life of each call - never the
 real github.com/api.github.com.

 - adds "owner/repo" via -Add, asserts the folder lands with a .toc and
   installedTag is set to the stub's own tag.
 - a fresh stub instance with a NEWER tag (the "bump the tag" step -
   swapping the stub PROCESS between the two calls is equivalent to
   mutating one running stub's own tag_name and is simpler/more robust
   here, since each CLI call points at its base URL independently anyway)
   makes -Only report an update and actually install it (real run, not
   -DryRun, so the on-disk state and backup zip below are both real).
 - the OLD tag's backup zip lands at
   flavours\<flavor>\backups\github-<owner>_<repo>\<oldtag>.zip.
 - -Rollback restores the old tag with NO further network call at all -
   proven by the (now-stopped) new-tag stub's own request log staying at
   the same count across the rollback (the rollback CLI call points at a
   STILL-RUNNING stub that would show growth if it were ever hit).

 Scratch ports 47950-47969 per this build's own hard rules; never the
 real WoW install, never a real token (this scenario is public - no
 Authorization header sent at all).
=====================================================================
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

$Script:AddonSyncSourceText = Get-Content -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Raw
$Script:CapGithubCli = [bool](
    ($Script:AddonSyncSourceText -match 'function\s+Sync-SingleGithubAddon\b') -and
    ($Script:AddonSyncSourceText -match 'FURPHY_TEST_GITHUB_BASEURL')
)

Write-Host ''
Write-Host "GitHub CLI capability probe: CapGithubCli=$Script:CapGithubCli" -ForegroundColor Cyan
Write-Host ''

Describe 'GitHub public repo: add, update, rollback (7.3 scenario 1)' {
    if (-not $Script:CapGithubCli) {
        It 'adds a public GitHub repo, updates it, rolls it back offline' { Write-PendingSkip 'needs Package A: Sync-SingleGithubAddon + FURPHY_TEST_GITHUB_BASEURL seam in addon-sync.ps1' }
        return
    }

    $wowRoot = Copy-Fixture
    $cliRoot = New-TempRoot -Name 'gh-public-cli'
    $cliPath = Join-Path $cliRoot 'addon-sync.ps1'
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force

    $tocContent = "## Interface: 110000`r`n## Title: PublicAddon`r`n"

    It 'installs a public repo via -Add, then updates via -Only, then rolls back to the old tag with no network call' {
        $stubOld = Start-GitHubReleaseStubServer -TagName 'v1.0.0' -Owner 'acme' -RepoName 'PublicAddon' -ZipEntries @{ 'PublicAddon/PublicAddon.toc' = $tocContent }
        try {
            $addResult = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 60 -ArgumentList @(
                '-Add', 'acme/PublicAddon', '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot
            ) -EnvironmentOverrides @{ FURPHY_TEST_GITHUB_BASEURL = $stubOld.BaseUrl }
            $addResult.ExitCode | Should Be 0
            $addRow = @($addResult.Json.results) | Where-Object { $_.name -eq 'PublicAddon' -or $_.name -like '*PublicAddon*' }
            @($addRow).Count | Should Be 1
            $addRow[0].status | Should Be 'Installed'

            $addonsPath = Join-Path $wowRoot '_retail_\Interface\AddOns'
            (Test-Path -LiteralPath (Join-Path $addonsPath 'PublicAddon\PublicAddon.toc') -PathType Leaf) | Should Be $true

            $addedRecord = @($addResult.Json.addons) | Where-Object { $_.source -eq 'github' -and $_.repo -eq 'acme/PublicAddon' }
            @($addedRecord).Count | Should Be 1
            $addedRecord[0].installedTag | Should Be 'v1.0.0'
        } finally {
            Stop-GitHubReleaseStubServer -Stub $stubOld
        }

        $stubNew = Start-GitHubReleaseStubServer -TagName 'v1.1.0' -Owner 'acme' -RepoName 'PublicAddon' -ZipEntries @{ 'PublicAddon/PublicAddon.toc' = $tocContent }
        try {
            $updateResult = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 60 -ArgumentList @(
                '-Only', 'acme/PublicAddon', '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot
            ) -EnvironmentOverrides @{ FURPHY_TEST_GITHUB_BASEURL = $stubNew.BaseUrl }
            $updateResult.ExitCode | Should Be 0
            $updateRow = @($updateResult.Json.results) | Where-Object { $_.name -like '*PublicAddon*' }
            @($updateRow).Count | Should Be 1
            (@('Updated', 'Would-update') -contains $updateRow[0].status) | Should Be $true

            $updatedRecord = @($updateResult.Json.addons) | Where-Object { $_.source -eq 'github' -and $_.repo -eq 'acme/PublicAddon' }
            @($updatedRecord).Count | Should Be 1
            $updatedRecord[0].installedTag | Should Be 'v1.1.0'

            $backupZip = Join-Path $cliRoot 'flavours\retail\backups\github-acme_PublicAddon\v1.0.0.zip'
            (Test-Path -LiteralPath $backupZip -PathType Leaf) | Should Be $true

            $reqCountBefore = @(Get-GitHubReleaseStubRequests -Stub $stubNew).Count

            $rollbackResult = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 60 -ArgumentList @(
                '-Rollback', 'acme/PublicAddon', '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot
            ) -EnvironmentOverrides @{ FURPHY_TEST_GITHUB_BASEURL = $stubNew.BaseUrl }
            $rollbackResult.ExitCode | Should Be 0
            $rollbackRow = @($rollbackResult.Json.results) | Where-Object { $_.name -like '*PublicAddon*' }
            @($rollbackRow).Count | Should Be 1
            $rollbackRow[0].status | Should Be 'Rolled-back'

            $rolledBackRecord = @($rollbackResult.Json.addons) | Where-Object { $_.source -eq 'github' -and $_.repo -eq 'acme/PublicAddon' }
            @($rolledBackRecord).Count | Should Be 1
            $rolledBackRecord[0].installedTag | Should Be 'v1.0.0'

            # No further network call at all during the rollback - the
            # still-running $stubNew's own request log shows zero growth.
            $reqCountAfter = @(Get-GitHubReleaseStubRequests -Stub $stubNew).Count
            $reqCountAfter | Should Be $reqCountBefore
        } finally {
            Stop-GitHubReleaseStubServer -Stub $stubNew
        }
    }
}

Remove-TempRoots
