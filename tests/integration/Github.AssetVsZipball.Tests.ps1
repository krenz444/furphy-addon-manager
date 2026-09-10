<#
=====================================================================
 tests\integration\Github.AssetVsZipball.Tests.ps1

 GITHUB-SOURCE-SPEC.md 7.3, scenario 3: the asset-selection/zipball-
 fallback rule (3.6.1/3.6.2/3.6.3) exercised end to end through the REAL
 addon-sync.ps1 CLI (Invoke-CliJson, a real child process, -Add against a
 real local Start-GitHubReleaseStubServer stub) - one scenario with a
 proper .zip asset (assetName recorded as that asset's real name); one
 with zipballAvailable and no .zip asset at all, -ZipballRootToc OFF
 (subfolder case) and ON (root-toc case) as two sub-cases, asserting the
 installed folder name in each (repo-name-derived only in the root-toc
 case, per 3.6.3). Public repos throughout (no token needed) - this
 scenario is entirely about asset shape, not auth.

 Never the real WoW install, never a real token, never github.com.
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
    ($Script:AddonSyncSourceText -match 'function\s+ConvertTo-NormalizedGithubZip\b')
)

Write-Host ''
Write-Host "GitHub asset-vs-zipball CLI capability probe: CapGithubCli=$Script:CapGithubCli" -ForegroundColor Cyan
Write-Host ''

Describe 'GitHub asset selection vs zipball fallback, real CLI (7.3 scenario 3)' {
    if (-not $Script:CapGithubCli) {
        It 'installs from a proper .zip asset, recording its real name' { Write-PendingSkip 'needs Package A: Sync-SingleGithubAddon / ConvertTo-NormalizedGithubZip' }
        return
    }

    function New-GithubCliRoot {
        param([string]$Name)
        $cliRoot = New-TempRoot -Name $Name
        $cliPath = Join-Path $cliRoot 'addon-sync.ps1'
        Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force
        return $cliPath
    }

    It 'a release with a real .zip asset: assetName is recorded as that asset''s own real name' {
        $wowRoot = Copy-Fixture
        $cliPath = New-GithubCliRoot -Name 'gh-avz-zipasset'
        $stub = Start-GitHubReleaseStubServer -TagName 'v1.0.0' -Owner 'acme' -RepoName 'ZipAssetAddon' -ZipEntries @{ 'ZipAssetAddon/ZipAssetAddon.toc' = "## Interface: 110000`r`n## Title: ZipAssetAddon`r`n" }
        try {
            $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 60 -ArgumentList @(
                '-Add', 'acme/ZipAssetAddon', '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot
            ) -EnvironmentOverrides @{ FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl }
            $r.ExitCode | Should Be 0
            $record = @($r.Json.addons) | Where-Object { $_.source -eq 'github' -and $_.repo -eq 'acme/ZipAssetAddon' }
            @($record).Count | Should Be 1
            $record[0].assetName | Should Be $stub.ZipAssetName
            (Test-Path -LiteralPath (Join-Path $wowRoot '_retail_\Interface\AddOns\ZipAssetAddon\ZipAssetAddon.toc') -PathType Leaf) | Should Be $true
        } finally {
            Stop-GitHubReleaseStubServer -Stub $stub
        }
    }

    It 'no .zip asset, zipball with a SUBFOLDER layout: installs under that subfolder''s own name, assetName "zipball"' {
        $wowRoot = Copy-Fixture
        $cliPath = New-GithubCliRoot -Name 'gh-avz-zipball-sub'
        $stub = Start-GitHubReleaseStubServer -TagName 'v2.0.0' -Owner 'acme' -RepoName 'ZipballSubAddon' -OmitZipAsset -OmitShaAsset -ZipballAvailable $true -ZipballShaSuffix 'sub0001' -ZipballFolderName 'InnerAddon'
        try {
            $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 60 -ArgumentList @(
                '-Add', 'acme/ZipballSubAddon', '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot
            ) -EnvironmentOverrides @{ FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl }
            $r.ExitCode | Should Be 0
            $record = @($r.Json.addons) | Where-Object { $_.source -eq 'github' -and $_.repo -eq 'acme/ZipballSubAddon' }
            @($record).Count | Should Be 1
            $record[0].assetName | Should Be 'zipball'
            # Pester 3's "Should Be" against two arrays can throw a raw
            # ArgumentException instead of comparing (confirmed live in
            # Cli.GithubZipballNormalize.Tests.ps1) - count-then-index instead.
            @($record[0].folders).Count | Should Be 1
            [string]$record[0].folders[0] | Should Be 'InnerAddon'
            (Test-Path -LiteralPath (Join-Path $wowRoot '_retail_\Interface\AddOns\InnerAddon\InnerAddon.toc') -PathType Leaf) | Should Be $true
        } finally {
            Stop-GitHubReleaseStubServer -Stub $stub
        }
    }

    It 'no .zip asset, zipball with a ROOT-.toc layout: installs under a folder renamed to the REPO name, per decision 1' {
        $wowRoot = Copy-Fixture
        $cliPath = New-GithubCliRoot -Name 'gh-avz-zipball-root'
        $stub = Start-GitHubReleaseStubServer -TagName 'v3.0.0' -Owner 'acme' -RepoName 'ZipballRootAddon' -OmitZipAsset -OmitShaAsset -ZipballAvailable $true -ZipballRootToc -ZipballShaSuffix 'root0001'
        try {
            $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 60 -ArgumentList @(
                '-Add', 'acme/ZipballRootAddon', '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot
            ) -EnvironmentOverrides @{ FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl }
            $r.ExitCode | Should Be 0
            $record = @($r.Json.addons) | Where-Object { $_.source -eq 'github' -and $_.repo -eq 'acme/ZipballRootAddon' }
            @($record).Count | Should Be 1
            $record[0].assetName | Should Be 'zipball'
            # Root-.toc case: the wrapper's own root .toc means the single
            # top-level entry is renamed to the REPO name (not any
            # ZipballFolderName), per decision 1's own parenthetical.
            @($record[0].folders).Count | Should Be 1
            [string]$record[0].folders[0] | Should Be 'ZipballRootAddon'
            (Test-Path -LiteralPath (Join-Path $wowRoot '_retail_\Interface\AddOns\ZipballRootAddon\ZipballRootAddon.toc') -PathType Leaf) | Should Be $true
        } finally {
            Stop-GitHubReleaseStubServer -Stub $stub
        }
    }
}

Remove-TempRoots
