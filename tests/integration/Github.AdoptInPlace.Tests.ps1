<#
=====================================================================
 tests\integration\Github.AdoptInPlace.Tests.ps1

 GITHUB-SOURCE-SPEC.md 7.3, scenario 4: adopt-in-place (3.7) through the
 REAL addon-sync.ps1 CLI. A WoW root already has a folder named exactly
 the repo's own name, containing a .toc with "## Version: v454" (mirrors
 Eric's real TimelineReminders.toc exactly) - -Add the repo with
 $env:FURPHY_TEST_GITHUB_BASEURL pointed at a GUARANTEED-CLOSED loopback
 port (no stub reachable at all - the same "immediate connection refusal,
 never a slow timeout" trick tests\lib\common.ps1's own Start-TestServer
 uses for the identical purpose) - the add must still succeed (Adopted),
 installedTag becomes "v454", proving 3.7's own "no download" claim by
 the ADD ITSELF SUCCEEDING WITH NO REACHABLE NETWORK AT ALL, not merely
 by absence of a logged error.

 A second sub-case repeats the same fixture with a REAL stub server
 running (reachable, would happily answer) and asserts the stub's own
 request log stays at ZERO requests for this repo after the adopt - the
 positive-and-negative pair together prove "no download", not just "no
 error if there happened to be no network".

 Never the real WoW install, never a real token (adopt-in-place needs
 none), never github.com.
=====================================================================
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

$Script:AddonSyncSourceText = Get-Content -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Raw
$Script:CapGithubCli = [bool]($Script:AddonSyncSourceText -match 'function\s+Sync-SingleGithubAddon\b')

Write-Host ''
Write-Host "GitHub adopt-in-place CLI capability probe: CapGithubCli=$Script:CapGithubCli" -ForegroundColor Cyan
Write-Host ''

Describe 'GitHub adopt-in-place: an existing folder is adopted with no network call (7.3 scenario 4)' {
    if (-not $Script:CapGithubCli) {
        It 'adopts a pre-existing folder with no reachable network at all' { Write-PendingSkip 'needs Package A: Sync-SingleGithubAddon (3.7 adopt-in-place)' }
        return
    }

    function New-GithubCliRoot {
        param([string]$Name)
        $cliRoot = New-TempRoot -Name $Name
        $cliPath = Join-Path $cliRoot 'addon-sync.ps1'
        Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force
        return $cliPath
    }

    function New-PreExistingAddonFolder {
        <# Mirrors Eric's own two real .toc files: TimelineReminders "## Version: v454" (default), AuraUpdater "## Version: 164" (bare digit, no v prefix) - -VersionText selects which. #>
        param([string]$WowRoot, [string]$FolderName, [string]$VersionText = 'v454')
        $dir = Join-Path $WowRoot "_retail_\Interface\AddOns\$FolderName"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $toc = "## Interface: 110000`r`n## Title: $FolderName`r`n## Version: $VersionText`r`n## X-Flavor: Mainline`r`n"
        [System.IO.File]::WriteAllText((Join-Path $dir "$FolderName.toc"), $toc, (New-Object System.Text.UTF8Encoding($false)))
    }

    It 'the add succeeds (Adopted) with NO reachable network at all - a guaranteed-closed port, never a real stub' {
        $wowRoot = Copy-Fixture
        $cliPath = New-GithubCliRoot -Name 'gh-adopt-noserver'
        New-PreExistingAddonFolder -WowRoot $wowRoot -FolderName 'TimelineReminders'

        # Same trick Start-TestServer's own header comment documents: an
        # immediate connection refusal (nothing listens on port 1 locally),
        # never a slow timeout - if 3.7's own "adopt BEFORE any network
        # call" contract were ever violated, this add would hang/fail
        # loudly rather than silently succeeding by luck.
        $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 30 -ArgumentList @(
            '-Add', 'bart-dev-wow/TimelineReminders', '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot
        ) -EnvironmentOverrides @{ FURPHY_TEST_GITHUB_BASEURL = 'http://127.0.0.1:1' }
        $r.ExitCode | Should Be 0

        $row = @($r.Json.results) | Where-Object { [string]$_.name -like '*TimelineReminders*' }
        @($row).Count | Should Be 1
        $row[0].status | Should Be 'Adopted'

        $record = @($r.Json.addons) | Where-Object { $_.source -eq 'github' -and $_.repo -eq 'bart-dev-wow/TimelineReminders' }
        @($record).Count | Should Be 1
        $record[0].installedTag | Should Be 'v454'
        $record[0].adopted | Should Be $true
    }

    It 'a REAL, reachable stub sees ZERO requests for this repo after the adopt (positive proof, not just absence of an error)' {
        $wowRoot = Copy-Fixture
        $cliPath = New-GithubCliRoot -Name 'gh-adopt-withserver'
        New-PreExistingAddonFolder -WowRoot $wowRoot -FolderName 'AuraUpdater' -VersionText '164'

        $stub = Start-GitHubReleaseStubServer -TagName 'v999.0.0' -Owner 'bart-dev-wow' -RepoName 'AuraUpdater'
        try {
            $r = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 30 -ArgumentList @(
                '-Add', 'bart-dev-wow/AuraUpdater', '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot
            ) -EnvironmentOverrides @{ FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl }
            $r.ExitCode | Should Be 0

            $row = @($r.Json.results) | Where-Object { [string]$_.name -like '*AuraUpdater*' }
            @($row).Count | Should Be 1
            $row[0].status | Should Be 'Adopted'

            # AuraUpdater's real .toc has no v-prefix, a bare number - this
            # fixture uses the same shape as Eric's real one so this test
            # also regression-guards the bare-digit branch of the "looks
            # like a tag" rule while it is at it, without needing its own
            # separate scenario.
            $record = @($r.Json.addons) | Where-Object { $_.source -eq 'github' -and $_.repo -eq 'bart-dev-wow/AuraUpdater' }
            @($record).Count | Should Be 1
            $record[0].installedTag | Should Be '164'

            $reqs = @(Get-GitHubReleaseStubRequests -Stub $stub) | Where-Object { $_.path -like '*bart-dev-wow/AuraUpdater*' }
            @($reqs).Count | Should Be 0
        } finally {
            Stop-GitHubReleaseStubServer -Stub $stub
        }
    }
}

Remove-TempRoots
