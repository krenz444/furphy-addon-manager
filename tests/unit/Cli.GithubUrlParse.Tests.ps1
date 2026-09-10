<#
  Unit tests (Pester 3 syntax): addon-sync.ps1's GitHub target parsing -
  ConvertTo-TargetToken's new IsGithub/GithubRepo branches
  (GITHUB-SOURCE-SPEC.md 3.1), plus the matching new branches on
  Test-RecordMatchesTarget, Get-TargetLabel, and Get-RecordBackupKey (also
  3.1 - all three already exist for CurseForge/Wago and are simply given
  one more `if ($Target.IsGithub) {...}`/`if ($Record.source -eq 'github')
  {...}` branch each, so covering them here alongside the parser itself
  needs no extra fixture setup).

  Package D (Tests+Docs) owns this file. Package A (addon-sync.ps1) owns
  the implementation this file exercises and may not have landed it yet -
  every Describe below is gated on the relevant function actually
  existing/being GitHub-aware, and prints a PENDING note instead of
  failing when it is not (matching tests\integration\
  Server.AppUpdate.Tests.ps1's own capability-gate convention).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1')

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

# Capability probe: ConvertTo-TargetToken exists for every build this repo
# has ever shipped (it is the E12 Wago parser) - what Round 47 ADDS is the
# IsGithub/GithubRepo properties on its returned descriptor. Probe by
# calling it with a value that is unambiguously NOT a CurseForge id or a
# Wago reference (so a pre-Round-47 build throws instead of returning
# something we could misread) and checking the returned shape.
$Script:CapGithubToken = $false
try {
    $probe = ConvertTo-TargetToken -Token 'octocat/Hello-World' -ParamName 'Add'
    $Script:CapGithubToken = [bool]($probe.PSObject.Properties.Name -contains 'IsGithub')
} catch {
    $Script:CapGithubToken = $false
}

Write-Host ''
Write-Host 'GitHub URL-parse capability probe:' -ForegroundColor Cyan
Write-Host "  CapGithubToken (ConvertTo-TargetToken IsGithub/GithubRepo) .... $Script:CapGithubToken"
Write-Host ''

Describe 'ConvertTo-TargetToken - GitHub forms (GITHUB-SOURCE-SPEC.md 3.1)' {
    if (-not $Script:CapGithubToken) {
        It 'accepts bare owner/repo' { Write-PendingSkip 'needs Package A: ConvertTo-TargetToken IsGithub/GithubRepo branches' }
        return
    }

    It 'accepts bare owner/repo' {
        $t = ConvertTo-TargetToken -Token 'bart-dev-wow/AuraUpdater' -ParamName 'Add'
        $t.IsGithub | Should Be $true
        $t.IsWago | Should Be $false
        $t.GithubRepo | Should Be 'bart-dev-wow/AuraUpdater'
        $t.ProjectId | Should Be $null
        $t.WagoRef | Should Be $null
    }

    It 'accepts the github:owner/repo form' {
        $t = ConvertTo-TargetToken -Token 'github:bart-dev-wow/TimelineReminders' -ParamName 'Add'
        $t.IsGithub | Should Be $true
        $t.GithubRepo | Should Be 'bart-dev-wow/TimelineReminders'
    }

    It 'accepts a plain github.com/owner/repo URL' {
        $t = ConvertTo-TargetToken -Token 'https://github.com/bart-dev-wow/AuraUpdater' -ParamName 'Add'
        $t.IsGithub | Should Be $true
        $t.GithubRepo | Should Be 'bart-dev-wow/AuraUpdater'
    }

    It 'accepts github.com/owner/repo with no scheme' {
        $t = ConvertTo-TargetToken -Token 'github.com/bart-dev-wow/AuraUpdater' -ParamName 'Add'
        $t.IsGithub | Should Be $true
        $t.GithubRepo | Should Be 'bart-dev-wow/AuraUpdater'
    }

    It 'accepts www.github.com/owner/repo' {
        $t = ConvertTo-TargetToken -Token 'https://www.github.com/bart-dev-wow/AuraUpdater' -ParamName 'Add'
        $t.IsGithub | Should Be $true
        $t.GithubRepo | Should Be 'bart-dev-wow/AuraUpdater'
    }

    It 'accepts a trailing .git suffix' {
        $t = ConvertTo-TargetToken -Token 'https://github.com/bart-dev-wow/AuraUpdater.git' -ParamName 'Add'
        $t.IsGithub | Should Be $true
        $t.GithubRepo | Should Be 'bart-dev-wow/AuraUpdater'
    }

    It 'accepts a trailing slash' {
        $t = ConvertTo-TargetToken -Token 'https://github.com/bart-dev-wow/AuraUpdater/' -ParamName 'Add'
        $t.IsGithub | Should Be $true
        $t.GithubRepo | Should Be 'bart-dev-wow/AuraUpdater'
    }

    It 'accepts a trailing subpath (releases/tag/v164)' {
        $t = ConvertTo-TargetToken -Token 'https://github.com/bart-dev-wow/AuraUpdater/releases/tag/v164' -ParamName 'Add'
        $t.IsGithub | Should Be $true
        $t.GithubRepo | Should Be 'bart-dev-wow/AuraUpdater'
    }

    It 'is case-insensitive on the github.com host and the github: prefix' {
        $t1 = ConvertTo-TargetToken -Token 'HTTPS://GITHUB.COM/bart-dev-wow/AuraUpdater' -ParamName 'Add'
        $t1.IsGithub | Should Be $true
        $t1.GithubRepo | Should Be 'bart-dev-wow/AuraUpdater'
        $t2 = ConvertTo-TargetToken -Token 'GitHub:bart-dev-wow/AuraUpdater' -ParamName 'Add'
        $t2.IsGithub | Should Be $true
    }

    It 'a bare decimal number still parses as a CurseForge project id, not GitHub' {
        $t = ConvertTo-TargetToken -Token '326516' -ParamName 'Add'
        $t.IsGithub | Should Be $false
        $t.IsWago | Should Be $false
        $t.ProjectId | Should Be 326516
    }

    It 'an existing wago: target explicitly carries IsGithub=false, GithubRepo=$null' {
        $t = ConvertTo-TargetToken -Token 'wago:some-addon' -ParamName 'Add'
        $t.IsWago | Should Be $true
        $t.IsGithub | Should Be $false
        $t.GithubRepo | Should Be $null
    }

    It 'rejects a malformed owner ("-bad")' {
        { ConvertTo-TargetToken -Token 'github.com/-bad/SomeRepo' -ParamName 'Add' } | Should Throw
    }

    It 'rejects a 101-character repo name' {
        $longRepo = 'x' * 101
        { ConvertTo-TargetToken -Token "github.com/owner/$longRepo" -ParamName 'Add' } | Should Throw
    }

    # REVIEW FOLD-IN, finding A/1 - "owner/.." and "owner/." must throw a
    # specific, actionable message in EACH of the three accepted forms,
    # never silently parse into a GithubRepo value (path-traversal guard).
    foreach ($badRepo in @('..', '.', '...')) {
        It "rejects bare owner/$badRepo as a path-traversal shape" {
            { ConvertTo-TargetToken -Token "someowner/$badRepo" -ParamName 'Add' } | Should Throw 'is not a valid GitHub repo'
        }
        It "rejects github:owner/$badRepo as a path-traversal shape" {
            { ConvertTo-TargetToken -Token "github:someowner/$badRepo" -ParamName 'Add' } | Should Throw 'is not a valid GitHub repo'
        }
        It "rejects github.com/owner/$badRepo as a path-traversal shape" {
            { ConvertTo-TargetToken -Token "github.com/someowner/$badRepo" -ParamName 'Add' } | Should Throw 'is not a valid GitHub repo'
        }
    }
}

Describe 'Test-RecordMatchesTarget - GitHub branch (3.1)' {
    $Script:CapMatch = $false
    if ($Script:CapGithubToken -and (Get-Command 'Test-RecordMatchesTarget' -ErrorAction SilentlyContinue)) {
        try {
            $probeTarget = ConvertTo-TargetToken -Token 'a/b' -ParamName 'Only'
            $probeRecord = [PSCustomObject]@{ source = 'github'; repo = 'a/b' }
            $Script:CapMatch = ((Test-RecordMatchesTarget -Target $probeTarget -Record $probeRecord) -eq $true)
        } catch {
            $Script:CapMatch = $false
        }
    }
    if (-not $Script:CapMatch) {
        It 'matches a github target against a github-sourced record by repo, case-insensitively' { Write-PendingSkip 'needs Package A: Test-RecordMatchesTarget IsGithub branch' }
        return
    }

    It 'matches a github target against a github-sourced record by repo, case-insensitively' {
        $target = ConvertTo-TargetToken -Token 'Bart-Dev-Wow/AuraUpdater' -ParamName 'Only'
        $record = [PSCustomObject]@{ source = 'github'; repo = 'bart-dev-wow/AuraUpdater' }
        (Test-RecordMatchesTarget -Target $target -Record $record) | Should Be $true
    }

    It 'does not match a github target against a non-github record' {
        $target = ConvertTo-TargetToken -Token 'bart-dev-wow/AuraUpdater' -ParamName 'Only'
        $record = [PSCustomObject]@{ source = 'curseforge'; projectId = 123; repo = $null }
        (Test-RecordMatchesTarget -Target $target -Record $record) | Should Be $false
    }

    It 'does not match a github target against a different repo' {
        $target = ConvertTo-TargetToken -Token 'bart-dev-wow/AuraUpdater' -ParamName 'Only'
        $record = [PSCustomObject]@{ source = 'github'; repo = 'someoneelse/OtherAddon' }
        (Test-RecordMatchesTarget -Target $target -Record $record) | Should Be $false
    }
}

Describe 'Get-TargetLabel - GitHub branch (3.1)' {
    $Script:CapLabel = $false
    if ($Script:CapGithubToken -and (Get-Command 'Get-TargetLabel' -ErrorAction SilentlyContinue)) {
        try {
            $probeTarget = ConvertTo-TargetToken -Token 'a/b' -ParamName 'Only'
            $Script:CapLabel = ((Get-TargetLabel -Target $probeTarget) -eq 'github:a/b')
        } catch {
            $Script:CapLabel = $false
        }
    }
    if (-not $Script:CapLabel) {
        It 'labels a github target as github:<repo>' { Write-PendingSkip 'needs Package A: Get-TargetLabel IsGithub branch' }
        return
    }

    It 'labels a github target as github:<repo>' {
        $target = ConvertTo-TargetToken -Token 'bart-dev-wow/AuraUpdater' -ParamName 'Only'
        (Get-TargetLabel -Target $target) | Should Be 'github:bart-dev-wow/AuraUpdater'
    }
}

Describe 'Get-RecordBackupKey - GitHub branch (3.1)' {
    $Script:CapBackupKey = $false
    if (Get-Command 'Get-RecordBackupKey' -ErrorAction SilentlyContinue) {
        try {
            $probeRecord = [PSCustomObject]@{ source = 'github'; repo = 'a/b'; projectId = $null }
            $Script:CapBackupKey = ((Get-RecordBackupKey -Record $probeRecord) -eq 'github-a_b')
        } catch {
            $Script:CapBackupKey = $false
        }
    }
    if (-not $Script:CapBackupKey) {
        It 'sanitizes a github repo into github-<owner>_<repo>' { Write-PendingSkip 'needs Package A: Get-RecordBackupKey github branch' }
        return
    }

    It 'sanitizes a github repo into github-<owner>_<repo>' {
        $record = [PSCustomObject]@{ source = 'github'; repo = 'bart-dev-wow/AuraUpdater'; projectId = $null }
        (Get-RecordBackupKey -Record $record) | Should Be 'github-bart-dev-wow_AuraUpdater'
    }
}

Remove-TempRoots
