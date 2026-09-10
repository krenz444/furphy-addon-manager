<#
  Unit tests (Pester 3 syntax): addon-sync.ps1's ConvertTo-NormalizedGithubZip
  (GITHUB-SOURCE-SPEC.md 3.6.3) against two hand-built zipball fixtures -
  the normal "wrapper holds ONE subfolder with a .toc" case (output zip's
  top-level entry is that subfolder, unchanged name) and the "wrapper's
  OWN root holds the .toc directly" case (output zip's single top-level
  entry is renamed to the repo name, per decision 1's own parenthetical).
  Both fixtures are fed straight into the REAL, UNMODIFIED
  Install-AddonPackage (already fully general-purpose - see 3.6.4;
  Round 47 does not change it at all), proving 3.6.3's own claim that
  Install-AddonPackage needs no GitHub-specific code.

  Package D (Tests+Docs) owns this file. Package A (addon-sync.ps1) owns
  ConvertTo-NormalizedGithubZip and may not have landed it yet - gated on
  the function existing; Install-AddonPackage itself already exists in
  every build (unchanged by this round), so the "fed into the real
  installer" half of each It can run the moment ConvertTo-
  NormalizedGithubZip lands, with no further Package A dependency.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1')

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

$Script:CapNormalize = [bool](Get-Command 'ConvertTo-NormalizedGithubZip' -ErrorAction SilentlyContinue)

Describe 'ConvertTo-NormalizedGithubZip - subfolder case (normal, 3.6.3)' {
    if (-not $Script:CapNormalize) {
        It 'normalizes a subfolder-shaped zipball into an Install-AddonPackage-ready zip' { Write-PendingSkip 'needs Package A: ConvertTo-NormalizedGithubZip' }
        return
    }

    It 'the output zip top-level entry is the addon subfolder, unchanged name, and installs cleanly' {
        $stagingRoot = New-TempRoot -Name 'ghzip-normalize-sub-staging'
        $addonsRoot = New-TempRoot -Name 'ghzip-normalize-sub-addons'
        $rawZip = Join-Path (New-TempRoot -Name 'ghzip-normalize-sub-raw') 'raw.zip'
        New-GitHubZipballFixtureZip -DestinationZipPath $rawZip -Owner 'bart-dev-wow' -RepoName 'TimelineReminders' -ShaSuffix 'a1b2c3d' -TocVersion 'v454' | Out-Null

        $normalized = ConvertTo-NormalizedGithubZip -RawZipPath $rawZip -RepoName 'TimelineReminders' -StagingPath $stagingRoot
        (Test-Path -LiteralPath $normalized -PathType Leaf) | Should Be $true

        $installed = Install-AddonPackage -ZipPath $normalized -ProjectId 'github-bart-dev-wow_TimelineReminders' -StagingPath $stagingRoot -AddonsPath $addonsRoot -PreviousFolders $null
        # PS 5.1/Pester 3 trap, confirmed live against this exact build in
        # complete isolation (no addon-sync.ps1 involved): wrapping a real
        # System.Collections.Generic.List[object] in the `@()` array
        # subexpression operator - `@($installed)` - throws a raw
        # "ArgumentException: Argument types do not match" when evaluated
        # inside a Pester `It` block specifically (a plain script has no
        # such issue). $installed.Count and index access both work fine
        # directly on the List[object] with no `@()` wrap needed at all -
        # used here instead.
        $installed.Count | Should Be 1
        [string]$installed[0] | Should Be 'TimelineReminders'
        (Test-Path -LiteralPath (Join-Path $addonsRoot 'TimelineReminders\TimelineReminders.toc') -PathType Leaf) | Should Be $true
    }
}

Describe 'ConvertTo-NormalizedGithubZip - root-.toc case (decision 1 parenthetical, 3.6.3)' {
    if (-not $Script:CapNormalize) {
        It 'renames the single top-level entry to the repo name when the wrapper root holds the .toc directly' { Write-PendingSkip 'needs Package A: ConvertTo-NormalizedGithubZip' }
        return
    }

    It 'the output zip top-level entry is renamed to the repo name, and installs cleanly' {
        $stagingRoot = New-TempRoot -Name 'ghzip-normalize-root-staging'
        $addonsRoot = New-TempRoot -Name 'ghzip-normalize-root-addons'
        $rawZip = Join-Path (New-TempRoot -Name 'ghzip-normalize-root-raw') 'raw.zip'
        New-GitHubZipballFixtureZip -DestinationZipPath $rawZip -Owner 'bart-dev-wow' -RepoName 'AuraUpdater' -ShaSuffix 'e5f6a7b' -RootToc -TocVersion '164' | Out-Null

        $normalized = ConvertTo-NormalizedGithubZip -RawZipPath $rawZip -RepoName 'AuraUpdater' -StagingPath $stagingRoot
        (Test-Path -LiteralPath $normalized -PathType Leaf) | Should Be $true

        $installed = Install-AddonPackage -ZipPath $normalized -ProjectId 'github-bart-dev-wow_AuraUpdater' -StagingPath $stagingRoot -AddonsPath $addonsRoot -PreviousFolders $null
        # See the sibling Describe's own It above for why this reads
        # $installed.Count/[0] directly rather than wrapping in @() first.
        $installed.Count | Should Be 1
        [string]$installed[0] | Should Be 'AuraUpdater'
        (Test-Path -LiteralPath (Join-Path $addonsRoot 'AuraUpdater\AuraUpdater.toc') -PathType Leaf) | Should Be $true
    }
}

Remove-TempRoots
