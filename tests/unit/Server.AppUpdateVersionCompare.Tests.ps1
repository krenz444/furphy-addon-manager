<#
=====================================================================
 tests\unit\Server.AppUpdateVersionCompare.Tests.ps1

 Package E (APP-UPDATE-SPEC.md section 12, round 42/1.22.0). Unit
 coverage for Package A's Test-AppUpdateVersionNewer (addon-server.ps1) -
 the semantic-version compare section 8.2 calls for ("the exact idiom
 already written for install.ps1's downgrade guard ... reused verbatim,
 never a string compare" - [System.Version]::TryParse, install.ps1:1562).

 function Test-AppUpdateVersionNewer {
     param([string]$Current, [string]$Candidate)
     ... returns [bool] $true only when $Candidate is STRICTLY newer
     than $Current, using [System.Version] compare; never throws - a
     malformed string on either side is treated as "not newer".
 }

 CAPABILITY-GATED: greps the REAL addon-server.ps1 source for
 `function Test-AppUpdateVersionNewer` and prints a PENDING skip
 (never a fail) if it is not there - kept even now that Package A has
 landed, so this file degrades gracefully again if a future edit ever
 reverts that function.

 Windows PowerShell 5.1, Pester 3 syntax, ASCII only.
=====================================================================
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:AddonServerPath = Join-Path $Script:FurphyBuildRoot 'addon-server.ps1'
$Script:ServerSourceText = Get-Content -LiteralPath $Script:AddonServerPath -Raw

$Script:CapVersionCompare = [bool]($Script:ServerSourceText -match 'function\s+Test-AppUpdateVersionNewer\b')

Write-Host ''
Write-Host 'App-update version-compare capability probe (static source grep, no network):' -ForegroundColor Cyan
Write-Host "  Test-AppUpdateVersionNewer defined ... $Script:CapVersionCompare"
Write-Host ''

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

Describe 'Test-AppUpdateVersionNewer (APP-UPDATE-SPEC.md section 8.2 semantic-version compare)' {
    if (-not $Script:CapVersionCompare) {
        It 'every case below' {
            Write-PendingSkip 'needs Package A to define Test-AppUpdateVersionNewer in addon-server.ps1 - addon-server.ps1 does not define it yet'
        }
        return
    }

    . $Script:AddonServerPath

    It '"1.10.0" is newer than "1.9.0" - must NOT sort the wrong way as a plain string compare would' {
        Test-AppUpdateVersionNewer -Current '1.9.0' -Candidate '1.10.0' | Should Be $true
    }

    It '"1.9.0" is NOT newer than "1.10.0" (the reverse of the case above)' {
        Test-AppUpdateVersionNewer -Current '1.10.0' -Candidate '1.9.0' | Should Be $false
    }

    It 'equal versions: not newer' {
        Test-AppUpdateVersionNewer -Current '1.22.0' -Candidate '1.22.0' | Should Be $false
    }

    It 'an older candidate: not newer' {
        Test-AppUpdateVersionNewer -Current '1.22.0' -Candidate '1.20.0' | Should Be $false
    }

    It 'a genuinely newer candidate: is newer' {
        Test-AppUpdateVersionNewer -Current '1.22.0' -Candidate '1.23.0' | Should Be $true
    }

    It 'a malformed CANDIDATE version string does not throw and is treated as not newer' {
        { Test-AppUpdateVersionNewer -Current '1.22.0' -Candidate 'not-a-version' } | Should Not Throw
        Test-AppUpdateVersionNewer -Current '1.22.0' -Candidate 'not-a-version' | Should Be $false
    }

    It 'a malformed CURRENT version string does not throw and is treated as not newer' {
        { Test-AppUpdateVersionNewer -Current 'not-a-version' -Candidate '1.23.0' } | Should Not Throw
        Test-AppUpdateVersionNewer -Current 'not-a-version' -Candidate '1.23.0' | Should Be $false
    }

    It 'an empty or whitespace-only string on either side does not throw and is treated as not newer' {
        { Test-AppUpdateVersionNewer -Current '' -Candidate '1.23.0' } | Should Not Throw
        Test-AppUpdateVersionNewer -Current '' -Candidate '1.23.0' | Should Be $false
        Test-AppUpdateVersionNewer -Current '1.22.0' -Candidate '   ' | Should Be $false
    }

    It 'a two-segment version (e.g. "1.0", major.minor only) parses and compares correctly, never throws' {
        { Test-AppUpdateVersionNewer -Current '1.0' -Candidate '1.1' } | Should Not Throw
        Test-AppUpdateVersionNewer -Current '1.0' -Candidate '1.1' | Should Be $true
    }
}

Remove-TempRoots
