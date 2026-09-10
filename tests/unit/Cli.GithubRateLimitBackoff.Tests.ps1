<#
  Unit tests (Pester 3 syntax): addon-sync.ps1's Get-GithubRateLimitBackoffUntil
  (GITHUB-SOURCE-SPEC.md 3.4a/3.5, REVIEW FOLD-IN finding D/4) - the small
  helper factored out of Sync-SingleGithubAddon's own catch path so the
  exact Retry-After/X-RateLimit-Reset/6-hour-cap/60-second-floor
  arithmetic can be exercised directly against hand-built header shapes,
  the same boundary values Invoke-AppUpdateMaintenanceCore's own
  precedent (addon-server.ps1, ~line 9723-9749) already uses for the
  self-update path.

  A hand-built ErrorRecord stands in for a real 403/429 WebException:
  PowerShell's extended type system lets Add-Member bolt a "Response"
  note property (itself a PSCustomObject whose own "Headers" is a plain
  Hashtable, which supports the same string indexer syntax
  ($h['Retry-After']) a real System.Net.WebHeaderCollection does) onto a
  plain System.Exception - confirmed live against this exact PowerShell
  5.1 build before writing the assertions below, so a $null result here
  means the function under test rejected the shape, not that the mock
  itself failed to expose the header.

  Package D (Tests+Docs) owns this file. Package A (addon-sync.ps1) owns
  Get-GithubRateLimitBackoffUntil and may not have landed it yet - gated
  on the function existing.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1')

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

function New-FakeGithubRateLimitErrorRecord {
    param([string]$RetryAfter, [string]$RateLimitReset)
    $headers = @{}
    if ($null -ne $RetryAfter) { $headers['Retry-After'] = $RetryAfter }
    if ($null -ne $RateLimitReset) { $headers['X-RateLimit-Reset'] = $RateLimitReset }
    $response = [PSCustomObject]@{ Headers = $headers }
    $ex = New-Object System.Exception('rate limited (fake)')
    Add-Member -InputObject $ex -NotePropertyName 'Response' -NotePropertyValue $response -Force
    return New-Object System.Management.Automation.ErrorRecord($ex, 'FakeGithubRateLimit', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
}

$Script:CapBackoff = [bool](Get-Command 'Get-GithubRateLimitBackoffUntil' -ErrorAction SilentlyContinue)

Write-Host ''
Write-Host "GitHub rate-limit backoff capability probe: CapBackoff=$Script:CapBackoff" -ForegroundColor Cyan
Write-Host ''

Describe 'Get-GithubRateLimitBackoffUntil (3.4a)' {
    if (-not $Script:CapBackoff) {
        It 'a Retry-After of 120 seconds yields a timestamp ~120s in the future' { Write-PendingSkip 'needs Package A: Get-GithubRateLimitBackoffUntil' }
        return
    }

    $now = [DateTime]::new(2026, 9, 10, 12, 0, 0, [DateTimeKind]::Utc)

    It 'a Retry-After of 120 seconds yields a timestamp ~120s in the future' {
        $er = New-FakeGithubRateLimitErrorRecord -RetryAfter '120'
        $result = Get-GithubRateLimitBackoffUntil -ErrorRecord $er -NowUtc $now
        $resultDate = [DateTime]::Parse($result, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
        [Math]::Abs(($resultDate - $now).TotalSeconds - 120) | Should BeLessThan 2
    }

    It 'an X-RateLimit-Reset unix epoch with no Retry-After yields a timestamp matching that epoch' {
        $resetAt = $now.AddSeconds(300)
        $epoch = [long]([DateTimeOffset]$resetAt).ToUnixTimeSeconds()
        $er = New-FakeGithubRateLimitErrorRecord -RateLimitReset ([string]$epoch)
        $result = Get-GithubRateLimitBackoffUntil -ErrorRecord $er -NowUtc $now
        $resultDate = [DateTime]::Parse($result, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
        [Math]::Abs(($resultDate - $resetAt).TotalSeconds) | Should BeLessThan 2
    }

    It 'Retry-After is preferred over X-RateLimit-Reset when both are present' {
        $resetAt = $now.AddSeconds(9999)
        $epoch = [long]([DateTimeOffset]$resetAt).ToUnixTimeSeconds()
        $er = New-FakeGithubRateLimitErrorRecord -RetryAfter '90' -RateLimitReset ([string]$epoch)
        $result = Get-GithubRateLimitBackoffUntil -ErrorRecord $er -NowUtc $now
        $resultDate = [DateTime]::Parse($result, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
        [Math]::Abs(($resultDate - $now).TotalSeconds - 90) | Should BeLessThan 2
    }

    It 'neither header present falls back to the documented default (never throws, never near-zero)' {
        $er = New-FakeGithubRateLimitErrorRecord
        $result = Get-GithubRateLimitBackoffUntil -ErrorRecord $er -NowUtc $now
        $resultDate = [DateTime]::Parse($result, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
        ($resultDate -gt $now.AddSeconds(59)) | Should Be $true
    }

    It 'a huge Retry-After (999999s) is capped at 6 hours' {
        $er = New-FakeGithubRateLimitErrorRecord -RetryAfter '999999'
        $result = Get-GithubRateLimitBackoffUntil -ErrorRecord $er -NowUtc $now
        $resultDate = [DateTime]::Parse($result, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
        [Math]::Abs(($resultDate - $now).TotalSeconds - 21600) | Should BeLessThan 2
    }

    It 'a tiny positive Retry-After (5s) is floored at 60 seconds' {
        $er = New-FakeGithubRateLimitErrorRecord -RetryAfter '5'
        $result = Get-GithubRateLimitBackoffUntil -ErrorRecord $er -NowUtc $now
        $resultDate = [DateTime]::Parse($result, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
        [Math]::Abs(($resultDate - $now).TotalSeconds - 60) | Should BeLessThan 2
    }

    It 'a Retry-After of exactly "0" is treated as no valid value (matching the self-update precedent''s own "-gt 0" guard, addon-server.ps1 ~9737) and falls back to the documented default, not to the 60s floor' {
        $er = New-FakeGithubRateLimitErrorRecord -RetryAfter '0'
        $result = Get-GithubRateLimitBackoffUntil -ErrorRecord $er -NowUtc $now
        $resultDate = [DateTime]::Parse($result, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
        ($resultDate -gt $now.AddSeconds(59)) | Should Be $true
    }

    It 'the returned string is ISO-8601 UTC (yyyy-MM-ddTHH:mm:ssZ shape)' {
        $er = New-FakeGithubRateLimitErrorRecord -RetryAfter '60'
        $result = Get-GithubRateLimitBackoffUntil -ErrorRecord $er -NowUtc $now
        $result | Should Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
    }
}

Remove-TempRoots
