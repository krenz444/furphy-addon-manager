<#
=====================================================================
 tests\integration\Github.TokenNeverInStateOrSettings.Tests.ps1

 GITHUB-SOURCE-SPEC.md 7.3, scenario 5 - the direct-API counterpart to
 the leak check inside Github.PrivateRepoNeedsToken.Tests.ps1: with a
 real (obviously-fake) token configured, hit GET /api/state and GET
 /api/settings directly (raw HTTP, not through any UI) and assert
 neither response body contains the token substring anywhere. Needs no
 job/sync activity at all to prove - just a PUT to set the token, then
 the two GETs - kept as its own file per the spec's own instruction
 rather than folded into the other file's already-large scenario set.

 Scratch server on port 47956 (this file's own assigned port in the
 47950-47969 range), Copy-Fixture WoW root + Copy-FurphyAppFiles app
 root, fake token only, per this build's own hard rules.
=====================================================================
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

$Script:GithubStateSettingsPort = 47956

$Script:ServerSourceText = Get-Content -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1') -Raw
$Script:CapGithubServer = [bool](
    ($Script:ServerSourceText -match 'hasGithubToken') -and
    ($Script:ServerSourceText -match 'githubTokenHint')
)

Write-Host ''
Write-Host "GitHub token-never-in-state-or-settings capability probe: CapGithubServer=$Script:CapGithubServer" -ForegroundColor Cyan
Write-Host ''

Describe 'GitHub token never appears in GET /api/state or GET /api/settings (7.3 scenario 5)' {
    if (-not $Script:CapGithubServer) {
        It 'neither raw response body ever contains the configured token' { Write-PendingSkip 'needs Package B: hasGithubToken/githubTokenHint in Get-SettingsView' }
        return
    }

    $wowRoot = Copy-Fixture
    $appRoot = New-TempRoot -Name 'gh-tokenleak-app'
    Copy-FurphyAppFiles -Destination $appRoot | Out-Null
    $token = 'github_pat_TESTONLY_0000'

    $server = Start-TestServer -Root $appRoot -Port $Script:GithubStateSettingsPort -WowRoot $wowRoot

    It 'PUT a real token, then GET /api/state and GET /api/settings both come back with hasGithubToken info but never the raw token text' {
        try {
            $putResp = Invoke-Api -Port $Script:GithubStateSettingsPort -Method Put -Path '/api/settings' -Body @{ githubToken = $token }
            $putResp.StatusCode | Should Be 200
            $putResp.Body.hasGithubToken | Should Be $true
            $putResp.Body.githubTokenHint | Should Be '0000'
            ($putResp.RawText -like "*$token*") | Should Be $false

            $stateResp = Invoke-Api -Port $Script:GithubStateSettingsPort -Method Get -Path '/api/state'
            $stateResp.StatusCode | Should Be 200
            ($stateResp.RawText -like "*$token*") | Should Be $false

            $settingsResp = Invoke-Api -Port $Script:GithubStateSettingsPort -Method Get -Path '/api/settings'
            $settingsResp.StatusCode | Should Be 200
            $settingsResp.Body.hasGithubToken | Should Be $true
            $settingsResp.Body.githubTokenHint | Should Be '0000'
            ($settingsResp.RawText -like "*$token*") | Should Be $false
            ($settingsResp.Body.PSObject.Properties.Name -contains 'githubToken') | Should Be $false
        } finally {
            Stop-TestServer -Server $server
        }
    }
}

Remove-TempRoots
