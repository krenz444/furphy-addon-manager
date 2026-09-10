<#
  Unit tests (Pester 3 syntax): addon-sync.ps1's GitHub release asset
  selection rule (GITHUB-SOURCE-SPEC.md 3.6.1/3.6.2, inside
  Sync-SingleGithubAddon - not factored into a standalone pure function in
  the landed implementation, so this file drives Sync-SingleGithubAddon
  itself against a real local GitHub-release-stub server rather than a
  literal hand-built JSON string; the stub's OWN manifest.json is the
  "hand-built release fixture" 7.1 asks for, just served over a real
  local HTTP call instead of passed as a string - never a real network
  call, never touches github.com/api.github.com):
    - one .zip asset -> that one wins.
    - several .zip assets, one matching the repo name -> that one wins
      over an earlier-listed non-matching one (proves "prefer" is not
      just "first").
    - zero .zip assets but a zipball_url present -> the zipball path is
      chosen, assetName recorded as "zipball".
    - zero .zip assets AND no zipball_url -> Status 'Skipped', not
      'Failed' (matches 3.6.2's exact branch).

  Package D (Tests+Docs) owns this file. Package A (addon-sync.ps1) owns
  Sync-SingleGithubAddon/New-GithubAddonRecord and may not have landed
  them yet - gated on both existing.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
$Script:AddonSyncPathForGithubAssetTest = Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1'
. $Script:AddonSyncPathForGithubAssetTest

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

function Initialize-GithubDirectCallState {
    <#
      Sync-SingleGithubAddon reads/writes $script:ProgressTallies
      unconditionally (Write-ProgressStep is itself a safe no-op with no
      -ProgressPath set, but Update-ProgressTallies is NOT - it throws on a
      $null -Tallies argument). Main's own startup (addon-sync.ps1, "Main"
      section) sets this via New-ProgressTallies before Sync-SingleAddon
      is ever reachable - but that whole section returns immediately when
      the script is dot-sourced (the guard every unit test relies on), so
      a test calling Sync-SingleGithubAddon directly must set this up
      itself, once per re-dot-source, exactly like Main would. Confirmed
      live while writing this file: without this, every call throws
      "Cannot bind argument to parameter 'Tallies' because it is null."
    #>
    $script:ProgressTallies = New-ProgressTallies
}

function New-TestAddonZipBytes {
    <# Builds a minimal, real, installable addon zip (one top-level folder -FolderName containing -FolderName.toc) in memory and returns its bytes - used to feed Start-GitHubReleaseStubServer's -ExtraAssets (byte[] content, Round 47 addition) a SECOND, real, installable .zip release asset alongside the main one. #>
    param([Parameter(Mandatory = $true)][string]$FolderName, [string]$Version = 'v1.0.0')
    $stage = New-TempRoot -Name 'ghassetselect-zipsrc'
    $addonDir = Join-Path $stage $FolderName
    New-Item -ItemType Directory -Path $addonDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $addonDir "$FolderName.toc"), "## Interface: 110000`r`n## Title: $FolderName`r`n## Version: $Version`r`n", (New-Object System.Text.UTF8Encoding($false)))
    $zipPath = Join-Path (New-TempRoot -Name 'ghassetselect-zipout') 'asset.zip'
    Push-Location $stage
    try {
        Compress-Archive -Path '.\*' -DestinationPath $zipPath -Force
    } finally {
        Pop-Location
    }
    # PS 5.1 trap: a bare `return [byte[]]` unrolls onto the pipeline and
    # gets re-collected by the caller as a generic Object[] (confirmed
    # live while writing this file) - Write-Output -NoEnumerate keeps it a
    # real byte[] all the way out, which matters here since
    # Start-GitHubReleaseStubServer's -ExtraAssets specifically checks for
    # [byte[]] content to write raw bytes instead of stringifying it.
    Write-Output -NoEnumerate ([System.IO.File]::ReadAllBytes($zipPath))
}

$Script:CapAssetSelect = [bool]((Get-Command 'Sync-SingleGithubAddon' -ErrorAction SilentlyContinue) -and (Get-Command 'New-GithubAddonRecord' -ErrorAction SilentlyContinue))

Write-Host ''
Write-Host "GitHub asset-select capability probe: CapAssetSelect=$Script:CapAssetSelect" -ForegroundColor Cyan
Write-Host ''

Describe 'Sync-SingleGithubAddon - asset selection (3.6.1/3.6.2)' {
    if (-not $Script:CapAssetSelect) {
        It 'picks the sole .zip asset when only one is present' { Write-PendingSkip 'needs Package A: Sync-SingleGithubAddon / New-GithubAddonRecord' }
        return
    }

    AfterEach {
        Remove-Item Env:\FURPHY_TEST_GITHUB_BASEURL -ErrorAction SilentlyContinue
    }

    It 'picks the sole .zip asset when only one is present, and records its real name as assetName' {
        $stub = Start-GitHubReleaseStubServer -TagName 'v1.0.0' -Owner 'acme' -RepoName 'SoloAsset' -ZipEntries @{ 'SoloAsset/SoloAsset.toc' = "## Interface: 110000`r`n## Title: SoloAsset`r`n## Version: v1.0.0`r`n" }
        try {
            $env:FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl
            . $Script:AddonSyncPathForGithubAssetTest
            Initialize-GithubDirectCallState

            $addonsRoot = New-TempRoot -Name 'ghassetselect-solo-addons'
            $stagingRoot = New-TempRoot -Name 'ghassetselect-solo-staging'
            $backupsRoot = New-TempRoot -Name 'ghassetselect-solo-backups'
            $record = New-GithubAddonRecord -Repo 'acme/SoloAsset'

            $result = Sync-SingleGithubAddon -Record $record -AddonsPath $addonsRoot -StagingPath $stagingRoot -BackupsPath $backupsRoot
            $result.Status | Should Be 'Installed'
            $record.assetName | Should Be $stub.ZipAssetName
            (Test-Path -LiteralPath (Join-Path $addonsRoot 'SoloAsset\SoloAsset.toc') -PathType Leaf) | Should Be $true
        } finally {
            Stop-GitHubReleaseStubServer -Stub $stub
        }
    }

    It 'with several .zip assets, prefers the one whose name matches the repo over an earlier-listed non-matching one' {
        $matchBytes = New-TestAddonZipBytes -FolderName 'AuraUpdater' -Version 'v1.0.0'
        # The stub's own MAIN zip asset (name "FurphyAddonManager-1.0.0.zip",
        # listed FIRST in assets[]) is deliberately the non-matching decoy
        # here (its -ZipEntries content is the decoy's own bytes, reusing
        # the main slot rather than building a THIRD asset) - "AuraUpdater-
        # v1.0.0.zip" is listed SECOND, via -ExtraAssets, and is the one
        # whose name actually contains the repo name.
        $stub = Start-GitHubReleaseStubServer -TagName 'v1.0.0' -Owner 'acme' -RepoName 'AuraUpdater' `
            -ZipEntries @{ 'DecoyAddon/DecoyAddon.toc' = "## Interface: 110000`r`n## Title: Decoy`r`n## Version: v0.0.1`r`n" } `
            -OmitShaAsset `
            -ExtraAssets @(@{ name = 'AuraUpdater-v1.0.0.zip'; content = $matchBytes })
        try {
            $env:FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl
            . $Script:AddonSyncPathForGithubAssetTest
            Initialize-GithubDirectCallState

            $addonsRoot = New-TempRoot -Name 'ghassetselect-pref-addons'
            $stagingRoot = New-TempRoot -Name 'ghassetselect-pref-staging'
            $backupsRoot = New-TempRoot -Name 'ghassetselect-pref-backups'
            $record = New-GithubAddonRecord -Repo 'acme/AuraUpdater'

            $result = Sync-SingleGithubAddon -Record $record -AddonsPath $addonsRoot -StagingPath $stagingRoot -BackupsPath $backupsRoot
            $result.Status | Should Be 'Installed'
            $record.assetName | Should Be 'AuraUpdater-v1.0.0.zip'
            (Test-Path -LiteralPath (Join-Path $addonsRoot 'AuraUpdater\AuraUpdater.toc') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $addonsRoot 'DecoyAddon') -PathType Container) | Should Be $false
        } finally {
            Stop-GitHubReleaseStubServer -Stub $stub
        }
    }

    It 'falls back to the zipball when there is no .zip asset at all, and records assetName as "zipball"' {
        $stub = Start-GitHubReleaseStubServer -TagName 'v2.0.0' -Owner 'acme' -RepoName 'ZipballOnly' -OmitZipAsset -OmitShaAsset -ZipballAvailable $true -ZipballShaSuffix 'abc0001'
        try {
            $env:FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl
            . $Script:AddonSyncPathForGithubAssetTest
            Initialize-GithubDirectCallState

            $addonsRoot = New-TempRoot -Name 'ghassetselect-zb-addons'
            $stagingRoot = New-TempRoot -Name 'ghassetselect-zb-staging'
            $backupsRoot = New-TempRoot -Name 'ghassetselect-zb-backups'
            $record = New-GithubAddonRecord -Repo 'acme/ZipballOnly'

            $result = Sync-SingleGithubAddon -Record $record -AddonsPath $addonsRoot -StagingPath $stagingRoot -BackupsPath $backupsRoot
            $result.Status | Should Be 'Installed'
            $record.assetName | Should Be 'zipball'
            (Test-Path -LiteralPath (Join-Path $addonsRoot 'ZipballOnly\ZipballOnly.toc') -PathType Leaf) | Should Be $true
        } finally {
            Stop-GitHubReleaseStubServer -Stub $stub
        }
    }

    It 'reports Skipped (never Failed) when there is neither a .zip asset nor a zipball URL' {
        $stub = Start-GitHubReleaseStubServer -TagName 'v3.0.0' -Owner 'acme' -RepoName 'NoAssetsAtAll' -OmitZipAsset -OmitShaAsset -ZipballAvailable $false
        try {
            $env:FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl
            . $Script:AddonSyncPathForGithubAssetTest
            Initialize-GithubDirectCallState

            $addonsRoot = New-TempRoot -Name 'ghassetselect-none-addons'
            $stagingRoot = New-TempRoot -Name 'ghassetselect-none-staging'
            $backupsRoot = New-TempRoot -Name 'ghassetselect-none-backups'
            $record = New-GithubAddonRecord -Repo 'acme/NoAssetsAtAll'

            $result = Sync-SingleGithubAddon -Record $record -AddonsPath $addonsRoot -StagingPath $stagingRoot -BackupsPath $backupsRoot
            $result.Status | Should Be 'Skipped'
        } finally {
            Stop-GitHubReleaseStubServer -Stub $stub
        }
    }
}

Remove-TempRoots
