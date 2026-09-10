<#
  Unit tests (Pester 3 syntax): addon-sync.ps1's Sync-SingleGithubAddon
  folder-ownership collision guard (GITHUB-SOURCE-SPEC.md 3.3a, REVIEW
  FOLD-IN finding C) - a folder that already exists on disk under a
  GitHub record's own repo-name segment must NOT be silently adopted when
  $ClaimedFolders already maps that folder name to a DIFFERENT record's
  identity (mirroring the mock fixture's own CurseForge-tracked
  "Bagnon" folder, ui\app.js:415 - a coincidentally-matching folder name
  between two different tracked addons). Runs entirely offline (the
  adopt-in-place step never makes a network call).

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
    $script:ProgressTallies = New-ProgressTallies
}

function New-BagnonFolderWithToc {
    param([Parameter(Mandatory = $true)][string]$AddonsRoot)
    $dir = Join-Path $AddonsRoot 'Bagnon'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $tocPath = Join-Path $dir 'Bagnon.toc'
    [System.IO.File]::WriteAllText($tocPath, "## Interface: 110000`r`n## Title: Bagnon`r`n## Version: 8.2.3`r`n", (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}

function Get-FolderFingerprintText {
    <# A cheap "did anything under this folder change" fingerprint - every file's relative path + length + last-write-time, joined - good enough to prove no takeover happened without pulling in a full hash helper. #>
    param([string]$FolderPath)
    $items = Get-ChildItem -LiteralPath $FolderPath -Recurse -File | Sort-Object FullName
    return ($items | ForEach-Object { "$($_.FullName.Substring($FolderPath.Length))|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
}

$Script:CapClaimGuard = [bool]((Get-Command 'Sync-SingleGithubAddon' -ErrorAction SilentlyContinue) -and (Get-Command 'New-GithubAddonRecord' -ErrorAction SilentlyContinue))

Write-Host ''
Write-Host "GitHub folder-claim-guard capability probe: CapClaimGuard=$Script:CapClaimGuard" -ForegroundColor Cyan
Write-Host ''

Describe 'Sync-SingleGithubAddon - folder-ownership collision guard (3.3a)' {
    if (-not $Script:CapClaimGuard) {
        It 'refuses to adopt a folder already claimed by a different tracked record' { Write-PendingSkip 'needs Package A: Sync-SingleGithubAddon / New-GithubAddonRecord' }
        return
    }

    It 'refuses to adopt "Bagnon" when a CurseForge record already claims that folder name - Failed, installedTag stays $null, folder untouched' {
        Initialize-GithubDirectCallState
        $addonsRoot = New-TempRoot -Name 'ghclaimguard-collide-addons'
        $stagingRoot = New-TempRoot -Name 'ghclaimguard-collide-staging'
        $backupsRoot = New-TempRoot -Name 'ghclaimguard-collide-backups'
        $bagnonDir = New-BagnonFolderWithToc -AddonsRoot $addonsRoot
        $fingerprintBefore = Get-FolderFingerprintText -FolderPath $bagnonDir

        # 3.3a's own recipe: for every OTHER record's .folders, map folder
        # name (case-insensitive) -> that record's own identity string
        # (here, a plain CurseForge projectId string, matching
        # Get-TargetLabel's own CurseForge shape).
        $claimedFolders = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $claimedFolders['Bagnon'] = '12345'

        $record = New-GithubAddonRecord -Repo 'acme/Bagnon'
        $result = Sync-SingleGithubAddon -Record $record -AddonsPath $addonsRoot -StagingPath $stagingRoot -BackupsPath $backupsRoot -ClaimedFolders $claimedFolders

        $result.Status | Should Be 'Failed'
        $record.installedTag | Should Be $null
        $record.adopted | Should Be $false

        $fingerprintAfter = Get-FolderFingerprintText -FolderPath $bagnonDir
        $fingerprintAfter | Should Be $fingerprintBefore
    }

    It 'regression guard: the SAME folder adopts normally when nothing else claims it' {
        Initialize-GithubDirectCallState
        $addonsRoot = New-TempRoot -Name 'ghclaimguard-clean-addons'
        $stagingRoot = New-TempRoot -Name 'ghclaimguard-clean-staging'
        $backupsRoot = New-TempRoot -Name 'ghclaimguard-clean-backups'
        New-BagnonFolderWithToc -AddonsRoot $addonsRoot | Out-Null

        $claimedFolders = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        # No entry for 'Bagnon' at all - nothing else claims it.

        $record = New-GithubAddonRecord -Repo 'acme/Bagnon'
        $result = Sync-SingleGithubAddon -Record $record -AddonsPath $addonsRoot -StagingPath $stagingRoot -BackupsPath $backupsRoot -ClaimedFolders $claimedFolders

        $result.Status | Should Be 'Adopted'
        $record.installedTag | Should Be '8.2.3'
    }

    It 'a re-run over an ALREADY-adopted record (claimed by itself) still succeeds - not a false collision' {
        Initialize-GithubDirectCallState
        $addonsRoot = New-TempRoot -Name 'ghclaimguard-self-addons'
        $stagingRoot = New-TempRoot -Name 'ghclaimguard-self-staging'
        $backupsRoot = New-TempRoot -Name 'ghclaimguard-self-backups'
        New-BagnonFolderWithToc -AddonsRoot $addonsRoot | Out-Null

        $claimedFolders = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $claimedFolders['Bagnon'] = 'github:acme/Bagnon'

        $record = New-GithubAddonRecord -Repo 'acme/Bagnon'
        $result = Sync-SingleGithubAddon -Record $record -AddonsPath $addonsRoot -StagingPath $stagingRoot -BackupsPath $backupsRoot -ClaimedFolders $claimedFolders

        $result.Status | Should Be 'Adopted'
        $record.installedTag | Should Be '8.2.3'
    }

    It 'no $ClaimedFolders at all (null) never blocks adoption' {
        Initialize-GithubDirectCallState
        $addonsRoot = New-TempRoot -Name 'ghclaimguard-nomap-addons'
        $stagingRoot = New-TempRoot -Name 'ghclaimguard-nomap-staging'
        $backupsRoot = New-TempRoot -Name 'ghclaimguard-nomap-backups'
        New-BagnonFolderWithToc -AddonsRoot $addonsRoot | Out-Null

        $record = New-GithubAddonRecord -Repo 'acme/Bagnon'
        $result = Sync-SingleGithubAddon -Record $record -AddonsPath $addonsRoot -StagingPath $stagingRoot -BackupsPath $backupsRoot

        $result.Status | Should Be 'Adopted'
    }
}

Remove-TempRoots
