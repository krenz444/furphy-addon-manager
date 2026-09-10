<#
=====================================================================
 tests\integration\Github.PrivateRepoNeedsToken.Tests.ps1

 GITHUB-SOURCE-SPEC.md 7.3, scenario 2 - "the single most important test
 in this whole feature" per the spec's own words: a private repo, driven
 through a REAL scratch addon-server.ps1 (Start-TestServer) with
 $env:FURPHY_TEST_GITHUB_BASEURL pointed at a real local
 Start-GitHubReleaseStubServer stub configured with -RequireToken $true,
 never the real github.com/api.github.com.

 - No githubToken configured at all -> the job's own result row shows
   FailPhase 'checking-needs-token', and sync.log contains the exact 3.5
   log line (repo name and all).
 - A WRONG (but plausible-shaped) token -> the SAME FailPhase/message
   (proving GitHub's 404-either-way is handled uniformly, 3.5) - and that
   WRONG token string never leaks either.
 - The CORRECT (obviously-fake, "github_pat_TESTONLY_0000"-shaped) token
   -> success, AND that exact fixture token string appears NOWHERE in:
   server.log, sync.log, every file under jobs\, GET /api/state's raw
   response body, GET /api/settings's raw response body (5 separate
   greps/asserts).

 Scratch server on port 47955 (this file's own assigned port in the
 47950-47969 range), Copy-Fixture WoW root + Copy-FurphyAppFiles app
 root, fake tokens only, per this build's own hard rules.
=====================================================================
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

$Script:GithubPrivatePort = 47955

$Script:ServerSourceText = Get-Content -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1') -Raw
$Script:CliSourceText = Get-Content -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Raw
$Script:CapGithubServer = [bool](
    ($Script:ServerSourceText -match 'hasGithubSourceRepo') -and
    ($Script:ServerSourceText -match 'githubToken') -and
    ($Script:CliSourceText -match 'function\s+Sync-SingleGithubAddon\b') -and
    ($Script:CliSourceText -match 'checking-needs-token')
)

Write-Host ''
Write-Host "GitHub private-repo server capability probe: CapGithubServer=$Script:CapGithubServer" -ForegroundColor Cyan
Write-Host ''

function Wait-GithubJobDone {
    <# Local helper (not part of common.ps1, mirrors every other integration file's own Wait-JobDone) - polls a job until it leaves 'running'. #>
    param([int]$Port, [string]$JobId, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-Api -Port $Port -Method Get -Path "/api/jobs/$JobId"
        $last = $r
        if ($r.Ok -and $r.Body.state -ne 'running') { return $r }
        Start-Sleep -Milliseconds 200
    }
    return $last
}

function Start-GithubPrivateTestServer {
    param([string]$Root, [string]$WowRoot, [string]$StubBaseUrl)
    $env:FURPHY_TEST_GITHUB_BASEURL = $StubBaseUrl
    try {
        return Start-TestServer -Root $Root -Port $Script:GithubPrivatePort -WowRoot $WowRoot
    } finally {
        Remove-Item Env:\FURPHY_TEST_GITHUB_BASEURL -ErrorAction SilentlyContinue
    }
}

function Assert-TokenNeverLeaks {
    param([string]$Root, [int]$Port, [string]$Token)
    $syncLog = Join-Path $Root 'sync.log'
    $serverLog = Join-Path $Root 'server.log'
    if (Test-Path -LiteralPath $syncLog) {
        ((Get-Content -LiteralPath $syncLog -Raw) -like "*$Token*") | Should Be $false
    }
    if (Test-Path -LiteralPath $serverLog) {
        ((Get-Content -LiteralPath $serverLog -Raw) -like "*$Token*") | Should Be $false
    }
    $jobsDir = Join-Path $Root 'jobs'
    if (Test-Path -LiteralPath $jobsDir) {
        $hit = Get-ChildItem -LiteralPath $jobsDir -File -ErrorAction SilentlyContinue | Where-Object {
            (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -like "*$Token*"
        }
        @($hit).Count | Should Be 0
    }
    $stateResp = Invoke-Api -Port $Port -Method Get -Path '/api/state'
    ($stateResp.RawText) | Should Not Match ([regex]::Escape($Token))
    $settingsResp = Invoke-Api -Port $Port -Method Get -Path '/api/settings'
    ($settingsResp.RawText) | Should Not Match ([regex]::Escape($Token))
}

Describe 'GitHub private repo needs a token (7.3 scenario 2)' {
    if (-not $Script:CapGithubServer) {
        It 'no token configured -> checking-needs-token' { Write-PendingSkip 'needs Package A + Package B: private-repo 404 handling and the settings/job wiring' }
        return
    }

    $wowRoot = Copy-Fixture
    $appRoot = New-TempRoot -Name 'gh-private-app'
    Copy-FurphyAppFiles -Destination $appRoot | Out-Null
    $wrongToken = 'github_pat_WRONGWRONG00000000'
    $correctToken = 'github_pat_TESTONLY_0000'

    $stub = Start-GitHubReleaseStubServer -TagName 'v1.0.0' -Owner 'bart-dev-wow' -RepoName 'PrivateAddon' -RequireToken $true -ExpectedToken $correctToken -ZipEntries @{ 'PrivateAddon/PrivateAddon.toc' = "## Interface: 110000`r`n## Title: PrivateAddon`r`n" }
    $server = $null
    try {
        $server = Start-GithubPrivateTestServer -Root $appRoot -WowRoot $wowRoot -StubBaseUrl $stub.BaseUrl

        It 'with no token configured, the add job fails with FailPhase checking-needs-token, and sync.log names the repo' {
            $addResp = Invoke-Api -Port $Script:GithubPrivatePort -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'add'; source = 'github'; repo = 'bart-dev-wow/PrivateAddon' }
            $addResp.StatusCode | Should Be 202
            $done = Wait-GithubJobDone -Port $Script:GithubPrivatePort -JobId $addResp.Body.jobId
            $row = @($done.Body.results) | Where-Object { $_.repo -eq 'bart-dev-wow/PrivateAddon' -or ([string]$_.name -like '*PrivateAddon*') -or ([string]$_.name -like '*bart-dev-wow*') }
            @($row).Count | Should BeGreaterThan 0
            $row[0].status | Should Be 'Failed'
            # failPhase itself travels through progress.json/job.progress, not
            # the job.results row (confirmed live while writing this file -
            # ui\app.js's own failureReason() reads it the same way, from
            # job.progress.failPhase, never from a results row).
            $done.Body.progress.failPhase | Should Be 'checking-needs-token'

            $syncLogPath = Join-Path $appRoot 'sync.log'
            (Test-Path -LiteralPath $syncLogPath) | Should Be $true
            $logText = Get-Content -LiteralPath $syncLogPath -Raw
            ($logText -like '*bart-dev-wow/PrivateAddon*') | Should Be $true
            ($logText -like '*Paste a current token in Settings*') | Should Be $true

            # Confirmed live: an -Add whose only sync attempt fails to find
            # an installable file is NOT persisted to addons.json (the
            # placeholder record is dropped, matching the identical
            # CurseForge/Wago "no installable file was found" precedent) -
            # so the NEXT scenario below must -Add again, not -Only/sync an
            # existing record that no longer exists.
        }

        It 'a WRONG token gives the SAME FailPhase (404 is indistinguishable from "no access"), and the wrong token never leaks' {
            $putResp = Invoke-Api -Port $Script:GithubPrivatePort -Method Put -Path '/api/settings' -Body @{ githubToken = $wrongToken }
            $putResp.StatusCode | Should Be 200
            $putResp.Body.hasGithubToken | Should Be $true

            $addResp = Invoke-Api -Port $Script:GithubPrivatePort -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'add'; source = 'github'; repo = 'bart-dev-wow/PrivateAddon' }
            (@(200, 202) -contains $addResp.StatusCode) | Should Be $true
            $done = Wait-GithubJobDone -Port $Script:GithubPrivatePort -JobId $addResp.Body.jobId
            $row = @($done.Body.results) | Where-Object { ([string]$_.name -like '*PrivateAddon*') -or ([string]$_.repo -eq 'bart-dev-wow/PrivateAddon') }
            @($row).Count | Should BeGreaterThan 0
            $row[0].status | Should Be 'Failed'
            $done.Body.progress.failPhase | Should Be 'checking-needs-token'

            Assert-TokenNeverLeaks -Root $appRoot -Port $Script:GithubPrivatePort -Token $wrongToken
        }

        It 'the CORRECT token succeeds, and the fixture token string appears nowhere: server.log, sync.log, every jobs\ file, GET /api/state, GET /api/settings' {
            $putResp = Invoke-Api -Port $Script:GithubPrivatePort -Method Put -Path '/api/settings' -Body @{ githubToken = $correctToken }
            $putResp.StatusCode | Should Be 200

            $addResp = Invoke-Api -Port $Script:GithubPrivatePort -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'add'; source = 'github'; repo = 'bart-dev-wow/PrivateAddon' }
            (@(200, 202) -contains $addResp.StatusCode) | Should Be $true
            $done = Wait-GithubJobDone -Port $Script:GithubPrivatePort -JobId $addResp.Body.jobId
            $row = @($done.Body.results) | Where-Object { ([string]$_.name -like '*PrivateAddon*') -or ([string]$_.repo -eq 'bart-dev-wow/PrivateAddon') }
            @($row).Count | Should BeGreaterThan 0
            (@('Installed', 'Updated') -contains $row[0].status) | Should Be $true

            $addonsPath = Join-Path $wowRoot '_retail_\Interface\AddOns'
            (Test-Path -LiteralPath (Join-Path $addonsPath 'PrivateAddon\PrivateAddon.toc') -PathType Leaf) | Should Be $true

            # The 5-way leak check - the single most important assertion here.
            Assert-TokenNeverLeaks -Root $appRoot -Port $Script:GithubPrivatePort -Token $correctToken
        }
    } finally {
        if ($server) { Stop-TestServer -Server $server }
        Stop-GitHubReleaseStubServer -Stub $stub
    }
}

Remove-TempRoots
