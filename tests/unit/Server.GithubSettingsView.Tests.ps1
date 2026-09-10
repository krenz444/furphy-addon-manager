<#
  Unit tests (Pester 3 syntax): addon-server.ps1's githubToken settings
  round-trip (GITHUB-SOURCE-SPEC.md 4.1-4.3) driven directly against
  Handle-SettingsGet/Handle-SettingsPut via New-FakeHttpContext (no real
  socket/listener) - the same pattern this suite already uses for other
  handler functions:
    - PUT a token -> GET (and the PUT's own response) shows
      hasGithubToken=true, githubTokenHint equal to its last 4 chars, and
      the RAW TOKEN VALUE never appears anywhere in either response body's
      text.
    - PUT an empty string -> clears it (hasGithubToken=false,
      githubTokenHint=null); a FOLLOW-UP GET still shows cleared.
    - PUT omitting githubToken entirely leaves a previously-set token
      untouched.

  Package D (Tests+Docs) owns this file. Package B (addon-server.ps1)
  owns Handle-SettingsGet/Handle-SettingsPut/Get-SettingsView and may not
  have landed the githubToken pieces yet - every Describe below is gated
  on a live behavioral probe, not just function existence.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

function Initialize-ServerDirectCallState {
    <#
      Handle-SettingsGet/-Put and their own Get-Settings/Save-Settings/
      Get-SettingsView helpers all read $Script:SettingsPath/$Script:Root
      - set only by addon-server.ps1's own "Main" section (past the
      dot-source guard every unit test relies on), so a test calling
      these handlers directly must set them up itself, pointed at a
      fresh scratch folder every time so tests never share state through
      a real settings.json. Confirmed live while writing this file:
      Get-SettingsView -> Resolve-EffectiveAddonsPath reads $Script:Root
      even on a plain settings PUT/GET (it folds addon-compat info into
      the view) - $Script:Root left unset throws "Cannot bind argument to
      parameter 'Path' because it is an empty string" out of Split-Path.
    #>
    param([Parameter(Mandatory = $true)][string]$SettingsPath)
    $script:SettingsPath = $SettingsPath
    $script:ServerLogPath = Join-Path (Split-Path -Path $SettingsPath -Parent) 'server.log'
    $script:Root = Split-Path -Path $SettingsPath -Parent
}

function Invoke-SettingsPut {
    param($Body)
    $ctx = New-FakeHttpContext -Method 'PUT' -Path '/api/settings' -JsonBody $Body
    Handle-SettingsPut -Context $ctx -RouteMatch $null
    return [PSCustomObject]@{ StatusCode = $ctx.Response.StatusCode; Body = (Get-FakeResponseBody -Context $ctx); RawText = [System.Text.Encoding]::UTF8.GetString($ctx.Response.OutputStream.Buffer.ToArray()) }
}

function Invoke-SettingsGet {
    $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/settings'
    Handle-SettingsGet -Context $ctx -RouteMatch $null
    return [PSCustomObject]@{ StatusCode = $ctx.Response.StatusCode; Body = (Get-FakeResponseBody -Context $ctx); RawText = [System.Text.Encoding]::UTF8.GetString($ctx.Response.OutputStream.Buffer.ToArray()) }
}

$Script:CapSettingsView = $false
try {
    $probeRoot = New-TempRoot -Name 'ghsettingsview-probe'
    Initialize-ServerDirectCallState -SettingsPath (Join-Path $probeRoot 'settings.json')
    $probeResult = Invoke-SettingsPut -Body @{ githubToken = 'github_pat_TESTONLY_0000' }
    $Script:CapSettingsView = [bool]($probeResult.Body.PSObject.Properties.Name -contains 'hasGithubToken')
} catch {
    $Script:CapSettingsView = $false
}

Write-Host ''
Write-Host "GitHub settings-view capability probe: CapSettingsView=$Script:CapSettingsView" -ForegroundColor Cyan
Write-Host ''

Describe 'githubToken settings round-trip (4.1-4.3)' {
    if (-not $Script:CapSettingsView) {
        It 'PUT a token, GET shows hasGithubToken=true and the correct last-4-chars hint, raw token never in either response' { Write-PendingSkip 'needs Package B: githubToken in Get-SettingsView/Handle-SettingsPut' }
        return
    }

    It 'PUT a token: GET shows hasGithubToken=true and the correct last-4-chars hint, and the raw token never appears in either response body text' {
        $root = New-TempRoot -Name 'ghsettingsview-put'
        Initialize-ServerDirectCallState -SettingsPath (Join-Path $root 'settings.json')
        $token = 'github_pat_TESTONLY_0000'

        $putResult = Invoke-SettingsPut -Body @{ githubToken = $token }
        $putResult.StatusCode | Should Be 200
        $putResult.Body.hasGithubToken | Should Be $true
        $putResult.Body.githubTokenHint | Should Be '0000'
        ($putResult.RawText -like "*$token*") | Should Be $false

        $getResult = Invoke-SettingsGet
        $getResult.StatusCode | Should Be 200
        $getResult.Body.hasGithubToken | Should Be $true
        $getResult.Body.githubTokenHint | Should Be '0000'
        ($getResult.RawText -like "*$token*") | Should Be $false
        # githubToken (the raw field name/value) never appears at all in the
        # GET response - only the two view fields do.
        ($getResult.Body.PSObject.Properties.Name -contains 'githubToken') | Should Be $false
    }

    It 'PUT an empty string clears it: hasGithubToken=false, githubTokenHint=null, and a follow-up GET still shows cleared' {
        $root = New-TempRoot -Name 'ghsettingsview-clear'
        Initialize-ServerDirectCallState -SettingsPath (Join-Path $root 'settings.json')
        Invoke-SettingsPut -Body @{ githubToken = 'github_pat_TESTONLY_0000' } | Out-Null

        $clearResult = Invoke-SettingsPut -Body @{ githubToken = '' }
        $clearResult.StatusCode | Should Be 200
        $clearResult.Body.hasGithubToken | Should Be $false
        $clearResult.Body.githubTokenHint | Should Be $null

        $getResult = Invoke-SettingsGet
        $getResult.Body.hasGithubToken | Should Be $false
        $getResult.Body.githubTokenHint | Should Be $null
    }

    It 'PUT omitting githubToken entirely leaves a previously-set token untouched' {
        $root = New-TempRoot -Name 'ghsettingsview-untouched'
        Initialize-ServerDirectCallState -SettingsPath (Join-Path $root 'settings.json')
        Invoke-SettingsPut -Body @{ githubToken = 'github_pat_TESTONLY_0000' } | Out-Null

        $unrelatedPut = Invoke-SettingsPut -Body @{ releaseType = 2 }
        $unrelatedPut.StatusCode | Should Be 200
        $unrelatedPut.Body.hasGithubToken | Should Be $true
        $unrelatedPut.Body.githubTokenHint | Should Be '0000'

        $getResult = Invoke-SettingsGet
        $getResult.Body.hasGithubToken | Should Be $true
        $getResult.Body.githubTokenHint | Should Be '0000'
    }

    It 'a token 4 characters or fewer hints as the whole token (documented edge case, never hit by a real PAT)' {
        $root = New-TempRoot -Name 'ghsettingsview-short'
        Initialize-ServerDirectCallState -SettingsPath (Join-Path $root 'settings.json')
        $putResult = Invoke-SettingsPut -Body @{ githubToken = 'abcd' }
        $putResult.Body.githubTokenHint | Should Be 'abcd'
    }

    It 'a githubToken longer than 512 characters is rejected with 400, never written' {
        $root = New-TempRoot -Name 'ghsettingsview-toolong'
        Initialize-ServerDirectCallState -SettingsPath (Join-Path $root 'settings.json')
        $tooLong = 'github_pat_' + ('x' * 520)
        $putResult = Invoke-SettingsPut -Body @{ githubToken = $tooLong }
        $putResult.StatusCode | Should Be 400

        $getResult = Invoke-SettingsGet
        $getResult.Body.hasGithubToken | Should Be $false
    }
}

Remove-TempRoots
