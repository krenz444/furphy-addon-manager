<#
=====================================================================
 tests\unit\Server.AppUpdateReleaseParse.Tests.ps1

 Package E (APP-UPDATE-SPEC.md section 12, round 42/1.22.0). Unit
 coverage for Package A's Get-AppUpdateAssetsFromRelease (addon-server.ps1)
 - section 8.2's asset-selection rule against a fixture releases/latest
 JSON body: "find entries named EXACTLY
 FurphyAddonManager-<tag-without-v>.zip and that name + .sha256 - never
 construct a download URL by hand; always use each asset's own
 browser_download_url ... If no newer tag, or no matching pair of
 assets: state='idle' ..., nothing downloaded."

 function Get-AppUpdateAssetsFromRelease {
     param($Release)
     ... returns $null if EITHER the zip or the .sha256 asset is
     missing (or $Release/$Release.tag_name itself is empty); otherwise
     a PSCustomObject { ZipUrl; ShaUrl; Version; Tag; ReleaseUrl } built
     from each matched asset's own browser_download_url - never a
     hand-built URL.
 }

 CAPABILITY-GATED: greps the REAL addon-server.ps1 source for
 `function Get-AppUpdateAssetsFromRelease` and prints a PENDING skip
 (never a fail) if it is not there - kept even now that Package A has
 landed, so this file degrades gracefully again if a future edit ever
 reverts that function.

 Windows PowerShell 5.1, Pester 3 syntax, ASCII only.
=====================================================================
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:AddonServerPath = Join-Path $Script:FurphyBuildRoot 'addon-server.ps1'
$Script:ServerSourceText = Get-Content -LiteralPath $Script:AddonServerPath -Raw

$Script:CapReleaseParse = [bool]($Script:ServerSourceText -match 'function\s+Get-AppUpdateAssetsFromRelease\b')

Write-Host ''
Write-Host 'App-update release-parse capability probe (static source grep, no network):' -ForegroundColor Cyan
Write-Host "  Get-AppUpdateAssetsFromRelease defined ... $Script:CapReleaseParse"
Write-Host ''

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

function New-FixtureRelease {
    <# Builds a releases/latest-shaped PSCustomObject: {tag_name; html_url; assets: [{name; browser_download_url}, ...]}. #>
    param(
        [string]$TagName = 'v1.23.0',
        [string[]]$AssetNames = @('FurphyAddonManager-1.23.0.zip', 'FurphyAddonManager-1.23.0.zip.sha256')
    )
    $assets = @()
    foreach ($n in $AssetNames) {
        $assets += [PSCustomObject]@{ name = $n; browser_download_url = "https://example.invalid/download/$n" }
    }
    return [PSCustomObject]@{
        tag_name = $TagName
        html_url = "https://github.com/krenz444/furphy-addon-manager/releases/tag/$TagName"
        assets   = $assets
    }
}

Describe 'Get-AppUpdateAssetsFromRelease (APP-UPDATE-SPEC.md section 8.2 asset selection)' {
    if (-not $Script:CapReleaseParse) {
        It 'every case below' {
            Write-PendingSkip 'needs Package A to define Get-AppUpdateAssetsFromRelease in addon-server.ps1 - addon-server.ps1 does not define it yet'
        }
        return
    }

    . $Script:AddonServerPath

    It 'exact-name match: both the zip and .sha256 are found by their EXACT expected names, URLs come from browser_download_url, never hand-built' {
        $release = New-FixtureRelease
        $result = Get-AppUpdateAssetsFromRelease -Release $release

        $result | Should Not Be $null
        $result.ZipUrl | Should Be 'https://example.invalid/download/FurphyAddonManager-1.23.0.zip'
        $result.ShaUrl | Should Be 'https://example.invalid/download/FurphyAddonManager-1.23.0.zip.sha256'
        $result.Version | Should Be '1.23.0'
        $result.Tag | Should Be 'v1.23.0'
        $result.ReleaseUrl | Should Be 'https://github.com/krenz444/furphy-addon-manager/releases/tag/v1.23.0'
    }

    It 'a release missing the .sha256 asset: returns $null (nothing downloaded per section 8.2)' {
        $release = New-FixtureRelease -AssetNames @('FurphyAddonManager-1.23.0.zip')
        Get-AppUpdateAssetsFromRelease -Release $release | Should Be $null
    }

    It 'a release missing the zip asset: returns $null' {
        $release = New-FixtureRelease -AssetNames @('FurphyAddonManager-1.23.0.zip.sha256')
        Get-AppUpdateAssetsFromRelease -Release $release | Should Be $null
    }

    It 'a release with EXTRA unrelated assets present still picks the right pair by EXACT name, never "first .zip found"' {
        $release = New-FixtureRelease -AssetNames @(
            'FurphyAddonManager-latest.zip',
            'FurphyAddonManager-1.23.0.zip',
            'README.txt',
            'FurphyAddonManager-1.23.0.zip.sha256',
            'source-code.tar.gz'
        )
        $result = Get-AppUpdateAssetsFromRelease -Release $release
        $result | Should Not Be $null
        $result.ZipUrl | Should Be 'https://example.invalid/download/FurphyAddonManager-1.23.0.zip'
        $result.ShaUrl | Should Be 'https://example.invalid/download/FurphyAddonManager-1.23.0.zip.sha256'
    }

    It 'a release with NO assets at all: returns $null, never throws' {
        $release = New-FixtureRelease -AssetNames @()
        { Get-AppUpdateAssetsFromRelease -Release $release } | Should Not Throw
        Get-AppUpdateAssetsFromRelease -Release $release | Should Be $null
    }

    It 'the expected asset names are derived from tag_name with a leading "v" stripped, case-insensitively' {
        $release = New-FixtureRelease -TagName 'V2.0.0' -AssetNames @('FurphyAddonManager-2.0.0.zip', 'FurphyAddonManager-2.0.0.zip.sha256')
        $result = Get-AppUpdateAssetsFromRelease -Release $release
        $result | Should Not Be $null
        $result.Version | Should Be '2.0.0'
    }

    It 'a release with no tag_name at all: returns $null, never throws' {
        $release = [PSCustomObject]@{ tag_name = ''; html_url = ''; assets = @() }
        { Get-AppUpdateAssetsFromRelease -Release $release } | Should Not Throw
        Get-AppUpdateAssetsFromRelease -Release $release | Should Be $null
    }

    It 'a completely $null release: returns $null, never throws' {
        { Get-AppUpdateAssetsFromRelease -Release $null } | Should Not Throw
        Get-AppUpdateAssetsFromRelease -Release $null | Should Be $null
    }
}

Remove-TempRoots
