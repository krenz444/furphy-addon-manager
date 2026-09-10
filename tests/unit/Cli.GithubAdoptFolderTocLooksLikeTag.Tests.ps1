<#
  Unit tests (Pester 3 syntax): addon-sync.ps1's Sync-SingleGithubAddon
  adopt-in-place step (GITHUB-SOURCE-SPEC.md 3.7) - specifically the
  "looks like a tag" regex (^[vV]?[0-9][\w.\-]*$) that decides whether an
  already-installed folder's own ".toc ## Version" text becomes the new
  record's installedTag verbatim, or the literal string "unknown" when it
  does not look tag-shaped. This step runs entirely OFFLINE (before any
  network call at all, per 3.7's own contract) so this file starts no
  stub server - a real on-disk folder plus a real .toc file is the whole
  fixture.

  Not factored into a standalone pure regex-testing function in the
  landed implementation, so this file drives Sync-SingleGithubAddon's own
  adopt-in-place step directly (Record.installedTag starts $null, a
  folder named after the repo already exists with the given .toc Version
  text) and reads back Record.installedTag after the call - the same
  "exercise the real function, not a re-implementation of its regex"
  approach GITHUB-SOURCE-SPEC.md 7.1 asks for.

  Package D (Tests+Docs) owns this file. Package A (addon-sync.ps1) owns
  Sync-SingleGithubAddon/New-GithubAddonRecord and may not have landed
  them yet - gated on both existing.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1')

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

function Initialize-GithubDirectCallState {
    <# See Cli.GithubAssetSelect.Tests.ps1's own doc comment for why this is needed before any direct Sync-SingleGithubAddon call outside Main. #>
    $script:ProgressTallies = New-ProgressTallies
}

function New-AdoptCandidateFolder {
    <# Builds <AddonsRoot>\<FolderName>\<FolderName>.toc with the given "## Version:" text, mirroring Eric's own two real .toc files' shape. #>
    param([Parameter(Mandatory = $true)][string]$AddonsRoot, [Parameter(Mandatory = $true)][string]$FolderName, [string]$VersionText)
    $dir = Join-Path $AddonsRoot $FolderName
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $toc = "## Interface: 110000`r`n## Title: $FolderName`r`n"
    if ($null -ne $VersionText) { $toc += "## Version: $VersionText`r`n" }
    [System.IO.File]::WriteAllText((Join-Path $dir "$FolderName.toc"), $toc, (New-Object System.Text.UTF8Encoding($false)))
}

$Script:CapAdopt = [bool]((Get-Command 'Sync-SingleGithubAddon' -ErrorAction SilentlyContinue) -and (Get-Command 'New-GithubAddonRecord' -ErrorAction SilentlyContinue))

Write-Host ''
Write-Host "GitHub adopt-in-place capability probe: CapAdopt=$Script:CapAdopt" -ForegroundColor Cyan
Write-Host ''

Describe 'Sync-SingleGithubAddon - adopt-in-place "looks like a tag" (3.7)' {
    if (-not $Script:CapAdopt) {
        It 'v454 (TimelineReminders real shape) is adopted verbatim as installedTag' { Write-PendingSkip 'needs Package A: Sync-SingleGithubAddon / New-GithubAddonRecord' }
        return
    }

    function Invoke-AdoptScenario {
        param([string]$FolderName, [string]$VersionText)
        Initialize-GithubDirectCallState
        $addonsRoot = New-TempRoot -Name 'ghadopttag-addons'
        $stagingRoot = New-TempRoot -Name 'ghadopttag-staging'
        $backupsRoot = New-TempRoot -Name 'ghadopttag-backups'
        New-AdoptCandidateFolder -AddonsRoot $addonsRoot -FolderName $FolderName -VersionText $VersionText
        $record = New-GithubAddonRecord -Repo "acme/$FolderName"
        $result = Sync-SingleGithubAddon -Record $record -AddonsPath $addonsRoot -StagingPath $stagingRoot -BackupsPath $backupsRoot
        return [PSCustomObject]@{ Result = $result; Record = $record }
    }

    It 'accepts "v454" verbatim (TimelineReminders'' own real .toc Version)' {
        $r = Invoke-AdoptScenario -FolderName 'TimelineReminders' -VersionText 'v454'
        $r.Result.Status | Should Be 'Adopted'
        $r.Record.installedTag | Should Be 'v454'
        $r.Record.adopted | Should Be $true
    }

    It 'accepts "164" verbatim, bare digit with no v prefix (AuraUpdater'' own real .toc Version)' {
        $r = Invoke-AdoptScenario -FolderName 'AuraUpdater' -VersionText '164'
        $r.Result.Status | Should Be 'Adopted'
        $r.Record.installedTag | Should Be '164'
    }

    It 'an empty Version falls through to the literal "unknown"' {
        $r = Invoke-AdoptScenario -FolderName 'EmptyVersionAddon' -VersionText ''
        $r.Result.Status | Should Be 'Adopted'
        $r.Record.installedTag | Should Be 'unknown'
    }

    It '"dev build" (a sentence, not a tag) falls through to "unknown"' {
        $r = Invoke-AdoptScenario -FolderName 'DevBuildAddon' -VersionText 'dev build'
        $r.Record.installedTag | Should Be 'unknown'
    }

    It '"2026-09-01" (a date stamp with dashes but no leading digit-then-dot/dash shape starting the string oddly) still evaluated - must fall to "unknown" only if it truly does not match; per the regex a leading digit DOES match "2026-09-01", so this case actually documents the regex accepting a date-shaped string as tag-like' {
        # NOTE: ^[vV]?[0-9][\w.\-]*$ matches "2026-09-01" (starts with a
        # digit, followed by digits/dashes) - this is a deliberately
        # permissive regex (3.7's own text: "accepts a BARE number with no
        # v prefix"), not a strict semver validator. Documented here so a
        # future reader does not mistake this for an oversight: the
        # exact case the spec's own prose calls out as a REJECTION example
        # is "a sentence" and "dev"/"Season 2" (contains a space), not a
        # bare dashed numeric string.
        $r = Invoke-AdoptScenario -FolderName 'DateStampAddon' -VersionText '2026-09-01'
        $r.Record.installedTag | Should Be '2026-09-01'
    }

    It '"Season 2" (contains whitespace) falls through to "unknown"' {
        $r = Invoke-AdoptScenario -FolderName 'SeasonAddon' -VersionText 'Season 2'
        $r.Record.installedTag | Should Be 'unknown'
    }
}

Remove-TempRoots
