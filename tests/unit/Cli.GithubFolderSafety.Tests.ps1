<#
  Unit tests (Pester 3 syntax): addon-sync.ps1's ConvertTo-NormalizedGithubZip
  defense-in-depth path-safety guard (GITHUB-SOURCE-SPEC.md 3.6.3, REVIEW
  FOLD-IN finding A/1) - a -RepoName of "..", ".", "", or containing a
  path separator MUST throw the guard's own specific message BEFORE any
  filesystem operation runs (Join-Path/Move-Item resolving ".."/"." at the
  OS level is the actual danger this guard exists to prevent - see the
  spec's own empirical note). A normal -RepoName must still proceed
  normally (regression guard against the new check being too strict).

  Package D (Tests+Docs) owns this file. Package A (addon-sync.ps1) owns
  ConvertTo-NormalizedGithubZip and may not have landed it yet - every
  Describe below is gated on the function actually existing, and prints a
  PENDING note instead of failing when it is not.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1')

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

$Script:CapNormalize = [bool](Get-Command 'ConvertTo-NormalizedGithubZip' -ErrorAction SilentlyContinue)

Write-Host ''
Write-Host "GitHub zip-normalize capability probe: CapNormalize=$Script:CapNormalize" -ForegroundColor Cyan
Write-Host ''

Describe 'ConvertTo-NormalizedGithubZip - path-safety guard (3.6.3, finding A/1)' {
    if (-not $Script:CapNormalize) {
        It 'rejects ".." before touching the filesystem' { Write-PendingSkip 'needs Package A: ConvertTo-NormalizedGithubZip' }
        return
    }

    # A raw zip and staging path that both do NOT exist - if the guard
    # runs first (as specced), the throw happens immediately with its own
    # message and neither path is ever touched; if some later
    # Join-Path/Move-Item/Extract call ran first instead, the error message
    # would be a completely different one (a "cannot find path" .NET
    # exception, not this function's own text), so asserting the EXACT
    # message proves which line actually threw.
    $missingRawZip = Join-Path $Script:FurphyTmpRoot 'does-not-exist-raw.zip'
    $missingStaging = Join-Path $Script:FurphyTmpRoot 'does-not-exist-staging-root'

    foreach ($bad in @('..', '.', '...')) {
        It "rejects a RepoName of '$bad'" {
            { ConvertTo-NormalizedGithubZip -RawZipPath $missingRawZip -RepoName $bad -StagingPath $missingStaging } |
                Should Throw 'unsafe repo-derived folder name'
        }
    }

    It 'rejects an empty RepoName' {
        { ConvertTo-NormalizedGithubZip -RawZipPath $missingRawZip -RepoName '' -StagingPath $missingStaging } |
            Should Throw 'unsafe repo-derived folder name'
    }

    It 'rejects a RepoName containing a path separator' {
        { ConvertTo-NormalizedGithubZip -RawZipPath $missingRawZip -RepoName 'sub/dir' -StagingPath $missingStaging } |
            Should Throw 'unsafe repo-derived folder name'
        { ConvertTo-NormalizedGithubZip -RawZipPath $missingRawZip -RepoName 'sub\dir' -StagingPath $missingStaging } |
            Should Throw 'unsafe repo-derived folder name'
    }

    It 'a normal RepoName (regression guard) still proceeds past the safety check and normalizes a real subfolder-shaped zipball' {
        $stagingRoot = New-TempRoot -Name 'ghzip-safety-staging'
        $rawZip = Join-Path (New-TempRoot -Name 'ghzip-safety-raw') 'raw.zip'
        New-GitHubZipballFixtureZip -DestinationZipPath $rawZip -Owner 'acme' -RepoName 'AuraUpdater' -ShaSuffix 'abc1234' | Out-Null

        $normalized = ConvertTo-NormalizedGithubZip -RawZipPath $rawZip -RepoName 'AuraUpdater' -StagingPath $stagingRoot
        (Test-Path -LiteralPath $normalized -PathType Leaf) | Should Be $true

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $extractDir = Join-Path $stagingRoot 'extract-check'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($normalized, $extractDir)
        $top = @(Get-ChildItem -LiteralPath $extractDir)
        $top.Count | Should Be 1
        $top[0].Name | Should Be 'AuraUpdater'
        (Test-Path -LiteralPath (Join-Path $top[0].FullName 'AuraUpdater.toc') -PathType Leaf) | Should Be $true
    }
}

Remove-TempRoots
