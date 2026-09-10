<#
  Unit tests (Pester 3 syntax): Get-RedactedLogText (GITHUB-SOURCE-SPEC.md
  4.4/6.2) - the defense-in-depth log/error scrub for github_pat_.../
  gh[pousr]_... shaped substrings. Duplicated ONCE in each of
  addon-server.ps1 and addon-sync.ps1 (the two files share no dependency),
  so this file tests BOTH copies against the identical scenario set -
  re-dot-sourcing the OTHER file between the two Describes (last
  dot-source wins when both define a same-named function in the same
  script scope), never assuming testing one proves anything about the
  other.

  REVIEW FOLD-IN, finding E/5: the redaction floor is {8,}, not a
  stricter number, SPECIFICALLY so the project's own mandated
  canonical fake-token literal "github_pat_TESTONLY_0000" (13-character
  suffix) is still caught - this file uses exactly that literal as one of
  its embedded-token cases, per the spec's own instruction, so a
  regression back to a stricter floor (e.g. {20,}) would be caught here
  directly.

  Package D (Tests+Docs) owns this file. Both Package A (addon-sync.ps1)
  and Package B (addon-server.ps1) own their own copy of
  Get-RedactedLogText - each Describe is gated independently.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

function Test-RedactionScenarios {
    <# Shared scenario set run identically against whichever copy of Get-RedactedLogText is currently in scope. #>

    It 'redacts a github_pat_ token embedded mid-sentence, preserving the surrounding text' {
        $text = 'Paste your token github_pat_11ABCDEFG0123456789abcdefghijklmnopqrstuvwxyz here please'
        $result = Get-RedactedLogText -Text $text
        ($result -like '*github_pat_11ABCDEFG0123456789abcdefghijklmnopqrstuvwxyz*') | Should Be $false
        ($result -like 'Paste your token github_pat_*REDACTED*here please') | Should Be $true
    }

    It 'redacts the project''s own mandated canonical fake-token literal "github_pat_TESTONLY_0000" (13-char suffix, clears the {8,} floor)' {
        $text = 'using token github_pat_TESTONLY_0000 for this request'
        $result = Get-RedactedLogText -Text $text
        ($result -like '*github_pat_TESTONLY_0000*') | Should Be $false
        ($result -like '*REDACTED*') | Should Be $true
    }

    It 'redacts a classic ghp_ token' {
        $text = "Authorization: Bearer ghp_1234567890abcdefABCDEF1234"
        $result = Get-RedactedLogText -Text $text
        ($result -like '*ghp_1234567890abcdefABCDEF1234*') | Should Be $false
    }

    It 'redacts the other GitHub OAuth/app token prefixes too (gho_/ghu_/ghs_/ghr_), even though this app never issues them' {
        foreach ($prefix in @('gho_', 'ghu_', 'ghs_', 'ghr_')) {
            $text = "token=${prefix}ABCDEFGHIJ0123456789"
            $result = Get-RedactedLogText -Text $text
            ($result -like "*${prefix}ABCDEFGHIJ0123456789*") | Should Be $false
        }
    }

    It 'a plain string with no token passes through byte-for-byte unchanged' {
        $text = 'GitHub addon acme/AuraUpdater (AuraUpdater): release v164 has no .zip asset and no zipball URL.'
        (Get-RedactedLogText -Text $text) | Should Be $text
    }

    It 'an empty or null string passes through unchanged, never throws' {
        (Get-RedactedLogText -Text '') | Should Be ''
        # NOTE: the function's own -Text parameter is typed [string], so
        # PowerShell's parameter binder itself coerces a $null argument to
        # "" before the function body ever runs (standard PS behavior for
        # a [string]-typed parameter, not something this function's own
        # [string]::IsNullOrWhiteSpace check controls) - "" is therefore
        # the correct, only-possible observation here, confirmed live.
        (Get-RedactedLogText -Text $null) | Should Be ''
    }

    It 'does not over-mangle an ordinary word that merely starts with "gh" (e.g. "ghost", "ghastly")' {
        $text = 'the ghost of a ghastly bug'
        (Get-RedactedLogText -Text $text) | Should Be $text
    }
}

$Script:CapServerRedact = [bool](Get-Command 'Get-RedactedLogText' -ErrorAction SilentlyContinue)
try {
    . (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')
    $Script:CapServerRedact = [bool](Get-Command 'Get-RedactedLogText' -ErrorAction SilentlyContinue)
} catch {
    $Script:CapServerRedact = $false
}

Describe 'Get-RedactedLogText - addon-server.ps1''s own copy (4.4)' {
    if (-not $Script:CapServerRedact) {
        It 'redacts a github_pat_ token embedded mid-sentence, preserving the surrounding text' { Write-PendingSkip 'needs Package B: Get-RedactedLogText in addon-server.ps1' }
        return
    }
    . (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')
    Test-RedactionScenarios
}

$Script:CapCliRedact = $false
try {
    . (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1')
    $Script:CapCliRedact = [bool](Get-Command 'Get-RedactedLogText' -ErrorAction SilentlyContinue)
} catch {
    $Script:CapCliRedact = $false
}

Describe 'Get-RedactedLogText - addon-sync.ps1''s own copy (4.4, Package A)' {
    if (-not $Script:CapCliRedact) {
        It 'redacts a github_pat_ token embedded mid-sentence, preserving the surrounding text' { Write-PendingSkip 'needs Package A: Get-RedactedLogText in addon-sync.ps1' }
        return
    }
    . (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1')
    Test-RedactionScenarios
}

Remove-TempRoots
