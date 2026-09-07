<#
  Unit tests (Pester 3 syntax): addon-server.ps1's Handle-Open URL
  allow-list parser (POST /api/open {what:'url'}), the job-history
  retention guarantee (a 20-item rolling list must never lose track of a
  still-running job, even once it rotates out of that list), and
  Get-ComputedFreshness (the one freshness enum, computed from job state
  + check state, never cached).

  Open-InBrowser is shadowed (redefined) after dot-sourcing so no real
  browser/process is ever launched - it just records the URL it was asked
  to open, into $Script:FurphyTestOpenedUrl, for the test to inspect.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

function Open-InBrowser {
    param([string]$Url)
    $Script:FurphyTestOpenedUrl = $Url
}

# Round 33: shadows the real Start-Process cmdlet (a function outranks a
# cmdlet in command lookup) so Handle-Open's explorer.exe / notepad.exe
# launches never actually happen under test - what WOULD have launched is
# recorded in $Script:FurphyTestStartedProcess for the test to inspect.
function Start-Process {
    param([string]$FilePath, $ArgumentList, [switch]$PassThru, $WindowStyle, [switch]$Wait, [switch]$NoNewWindow)
    $Script:FurphyTestStartedProcess = [PSCustomObject]@{ FilePath = $FilePath; Arguments = (@($ArgumentList) -join ' ') }
}

function New-FakeWowRoot {
    <# A throwaway <WowRoot>\<flavour folder>\Interface\AddOns tree under tests\.tmp - never the real install. #>
    param([string[]]$FlavourFolders = @('_retail_'))
    $wowRoot = New-TempRoot -Name 'wowroot-open'
    foreach ($f in $FlavourFolders) {
        New-Item -ItemType Directory -Path (Join-Path (Join-Path $wowRoot $f) 'Interface\AddOns') -Force | Out-Null
    }
    return $wowRoot
}

function Use-FakeWowRoot {
    <# Points path resolution at -WowRoot and stashes -Flavour exactly the way Invoke-Route does for a request carrying ?flavour=<id> (Set-CurrentFlavourContext). #>
    param([string]$WowRoot, [string]$Flavour = 'retail')
    $Script:AddonsPathOverride = $null
    $Script:WowRootOverride = $WowRoot
    $Script:BuildInfoPathOverride = $null
    $Script:Root = New-TempRoot -Name 'approot-open'
    Set-CurrentFlavourContext -Flavor $Flavour
    $Script:FurphyTestStartedProcess = $null
}

function Initialize-JobState {
    <# Minimal script-scope state Handle-JobsGetOne/Add-JobToHistory/Get-ComputedFreshness need - normally set up by the "# Startup" section this dot-source guard skips. #>
    $Script:Jobs = New-Object 'System.Collections.Generic.List[object]'
    $Script:JobIdSeq = 0
    $Script:CurrentJobByFlavour = @{}
    $Script:UpdateAvailableByFlavour = @{}
    $Script:LastRunByFlavour = @{}
    $Script:UpdatesCheckedAtByFlavour = @{}
    $Script:LastCheckFailedByFlavour = @{}
    $Script:LastCheckErrorByFlavour = @{}
}

function New-FakeJob {
    param([string]$Id, [string]$State = 'done', [string]$Kind = 'sync', [string]$Flavour = 'retail')
    return [PSCustomObject]@{
        id         = $Id
        kind       = $Kind
        params     = $null
        state      = $State
        startedAt  = (Get-Date).ToString('o')
        finishedAt = $null
        exitCode   = $null
        log        = (New-Object 'System.Collections.Generic.List[object]')
        results    = (New-Object 'System.Collections.Generic.List[object]')
        error      = $null
        flavour    = $Flavour
    }
}

Describe 'Handle-Open (POST /api/open, what=url)' {

    It 'a well-formed curseforge.com URL is allowed and opened verbatim' {
        $Script:FurphyTestOpenedUrl = $null
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/open' -JsonBody @{ what = 'url'; url = 'https://www.curseforge.com/wow/addons/bigwigs' }
        Handle-Open -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        $Script:FurphyTestOpenedUrl | Should Be 'https://www.curseforge.com/wow/addons/bigwigs'
    }

    It 'addons.wago.io is also an allowed exact host' {
        $Script:FurphyTestOpenedUrl = $null
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/open' -JsonBody @{ what = 'url'; url = 'https://addons.wago.io/addons/details' }
        Handle-Open -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        $Script:FurphyTestOpenedUrl | Should Be 'https://addons.wago.io/addons/details'
    }

    It 'a smuggled-space command-line-injection URL is neutralized (opened URL has no literal space, never reaches Start-Process unescaped)' {
        $Script:FurphyTestOpenedUrl = $null
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/open' -JsonBody @{ what = 'url'; url = 'https://www.curseforge.com/x --app=http://evil/phish' }
        Handle-Open -Context $ctx -RouteMatch @{}
        # Round 20's own fix (server-3): the URI is reparsed and only
        # .AbsoluteUri is passed onward, which percent-encodes the space -
        # so even though the request is accepted (curseforge.com is an
        # allowed host), nothing that could smuggle an extra command-line
        # switch is ever handed to Start-Process.
        $ctx.Response.StatusCode | Should Be 200
        $Script:FurphyTestOpenedUrl | Should Not Be $null
        ($Script:FurphyTestOpenedUrl.Contains(' ')) | Should Be $false
        ($Script:FurphyTestOpenedUrl.Contains('%20')) | Should Be $true
    }

    It 'a different host entirely is rejected with 400, and nothing is opened' {
        $Script:FurphyTestOpenedUrl = $null
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/open' -JsonBody @{ what = 'url'; url = 'https://evil.example.com/x' }
        Handle-Open -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 400
        $Script:FurphyTestOpenedUrl | Should Be $null
    }

    It 'a host that merely CONTAINS an allowed name (not an exact match) is rejected' {
        $Script:FurphyTestOpenedUrl = $null
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/open' -JsonBody @{ what = 'url'; url = 'https://www.curseforge.com.evil.net/x' }
        Handle-Open -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 400
        $Script:FurphyTestOpenedUrl | Should Be $null
    }

    It 'an http (non-https) URL to an otherwise-allowed host is rejected' {
        $Script:FurphyTestOpenedUrl = $null
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/open' -JsonBody @{ what = 'url'; url = 'http://www.curseforge.com/x' }
        Handle-Open -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 400
        $Script:FurphyTestOpenedUrl | Should Be $null
    }

    It 'a missing url field is a 400 "url required"' {
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/open' -JsonBody @{ what = 'url' }
        Handle-Open -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 400
        (Get-FakeResponseBody -Context $ctx).error | Should Be 'url required'
    }

    It 'an unrecognized "what" value is a 400, never a 500' {
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/open' -JsonBody @{ what = 'launch-the-missiles' }
        Handle-Open -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 400
    }
}

# Round 33: Settings > Advanced > Game folders. "World of Warcraft folder" >
# "Open" had been wired to 'folder' (the AddOns SUBfolder) and "AddOns
# folder" > "Open" to 'addons' (addons.json in Notepad) - neither opened
# what its row showed. Invisible under ?mock=1 (whose /api/open stub
# answered ok for anything), so these pin the real handler's behaviour.
Describe 'Handle-Open (POST /api/open, what=wowfolder / folder / addons - Settings > Game folders, round 33)' {

    It "'wowfolder' opens the flavour's own WoW folder (<WowRoot>\_retail_, the path the Settings row shows) in Explorer - not the AddOns subfolder" {
        $wowRoot = New-FakeWowRoot
        Use-FakeWowRoot -WowRoot $wowRoot
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/open' -JsonBody @{ what = 'wowfolder' }
        Handle-Open -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        (Get-FakeResponseBody -Context $ctx).ok | Should Be $true
        $Script:FurphyTestStartedProcess.FilePath | Should Be 'explorer.exe'
        $Script:FurphyTestStartedProcess.Arguments | Should Be ('"' + (Join-Path $wowRoot '_retail_') + '"')
    }

    It "'folder' still opens the AddOns folder (<WowRoot>\_retail_\Interface\AddOns) in Explorer - unchanged, now behind the 'AddOns folder' row's button" {
        $wowRoot = New-FakeWowRoot
        Use-FakeWowRoot -WowRoot $wowRoot
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/open' -JsonBody @{ what = 'folder' }
        Handle-Open -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        $Script:FurphyTestStartedProcess.FilePath | Should Be 'explorer.exe'
        $Script:FurphyTestStartedProcess.Arguments | Should Be ('"' + (Join-Path $wowRoot '_retail_\Interface\AddOns') + '"')
    }

    It "both targets follow the request's flavour (?flavour=classic via Set-CurrentFlavourContext) - a multi-flavour row opens ITS folder, not the active flavour's" {
        $wowRoot = New-FakeWowRoot -FlavourFolders @('_retail_', '_classic_')
        Use-FakeWowRoot -WowRoot $wowRoot -Flavour 'classic'

        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/open' -Query '?flavour=classic' -JsonBody @{ what = 'folder' }
        Handle-Open -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        $Script:FurphyTestStartedProcess.Arguments | Should Be ('"' + (Join-Path $wowRoot '_classic_\Interface\AddOns') + '"')

        $Script:FurphyTestStartedProcess = $null
        $ctx2 = New-FakeHttpContext -Method 'POST' -Path '/api/open' -Query '?flavour=classic' -JsonBody @{ what = 'wowfolder' }
        Handle-Open -Context $ctx2 -RouteMatch @{}
        $ctx2.Response.StatusCode | Should Be 200
        $Script:FurphyTestStartedProcess.Arguments | Should Be ('"' + (Join-Path $wowRoot '_classic_') + '"')
    }

    It "'wowfolder' for a flavour whose folder does not exist is a 400 'World of Warcraft folder not found' and launches nothing" {
        $wowRoot = New-FakeWowRoot
        Use-FakeWowRoot -WowRoot $wowRoot -Flavour 'classic'
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/open' -JsonBody @{ what = 'wowfolder' }
        Handle-Open -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 400
        (Get-FakeResponseBody -Context $ctx).error | Should Be 'World of Warcraft folder not found'
        $Script:FurphyTestStartedProcess | Should Be $null
    }

    It "'addons' (now Backup & troubleshooting's 'Open addon list file') still opens the request flavour's addons.json in Notepad - demoted, not deleted" {
        $wowRoot = New-FakeWowRoot
        Use-FakeWowRoot -WowRoot $wowRoot
        New-Item -ItemType Directory -Path (Split-Path -Path $Script:AddonsJsonPath -Parent) -Force | Out-Null
        Set-Content -LiteralPath $Script:AddonsJsonPath -Value '[]' -Encoding Ascii
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/open' -JsonBody @{ what = 'addons' }
        Handle-Open -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        $Script:FurphyTestStartedProcess.FilePath | Should Be 'notepad.exe'
        $Script:FurphyTestStartedProcess.Arguments | Should Be ('"' + $Script:AddonsJsonPath + '"')
    }
}

Describe 'Job-history retention never loses a running job' {

    It 'Add-JobToHistory trims the list to 20, evicting the OLDEST entry regardless of its state' {
        Initialize-JobState
        for ($i = 1; $i -le 21; $i++) {
            Add-JobToHistory -Job (New-FakeJob -Id ([string]$i) -State 'done')
        }
        $Script:Jobs.Count | Should Be 20
        $stillPresent = $false
        foreach ($j in $Script:Jobs) { if ($j.id -eq '1') { $stillPresent = $true } }
        $stillPresent | Should Be $false
    }

    It 'a job still running is evicted from the 20-item history the same way - BUT Handle-JobsGetOne still finds it via $Script:CurrentJobByFlavour' {
        Initialize-JobState
        $runningJob = New-FakeJob -Id 'r1' -State 'running' -Flavour 'retail'
        Add-JobToHistory -Job $runningJob
        $Script:CurrentJobByFlavour['retail'] = $runningJob
        # 20 more jobs on a DIFFERENT flavour push 'r1' out of the rolling
        # history (Add-JobToHistory has no running-job exemption - see its
        # own doc comment / Round 20 server-6's fix, which lives entirely
        # in Handle-JobsGetOne's fallback instead).
        for ($i = 1; $i -le 20; $i++) {
            Add-JobToHistory -Job (New-FakeJob -Id ("other-$i") -State 'done' -Flavour 'classic_era')
        }
        $stillInHistory = $false
        foreach ($j in $Script:Jobs) { if ($j.id -eq 'r1') { $stillInHistory = $true } }
        $stillInHistory | Should Be $false

        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/jobs/r1'
        Handle-JobsGetOne -Context $ctx -RouteMatch @{ id = 'r1' }
        $ctx.Response.StatusCode | Should Be 200
        (Get-FakeResponseBody -Context $ctx).id | Should Be 'r1'
        (Get-FakeResponseBody -Context $ctx).state | Should Be 'running'
    }

    It 'a job id that is neither in the history nor any current-job map is a clean 404' {
        Initialize-JobState
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/jobs/nope'
        Handle-JobsGetOne -Context $ctx -RouteMatch @{ id = 'nope' }
        $ctx.Response.StatusCode | Should Be 404
    }
}

Describe 'Get-ComputedFreshness' {

    It 'reports "checking" while a sync/check/add/install job is running' {
        Initialize-JobState
        $Script:CurrentFlavour = 'retail'
        $jobView = [PSCustomObject]@{ state = 'running'; kind = 'sync' }
        (Get-ComputedFreshness -CurrentJobView $jobView -Flavor 'retail') | Should Be 'checking'
    }

    It 'reports "check_failed" when the flavour''s last check job failed' {
        Initialize-JobState
        $Script:LastCheckFailedByFlavour['retail'] = $true
        (Get-ComputedFreshness -CurrentJobView $null -Flavor 'retail') | Should Be 'check_failed'
    }

    It 'reports "not_checked" when updatesCheckedAt has never been set for this flavour' {
        Initialize-JobState
        (Get-ComputedFreshness -CurrentJobView $null -Flavor 'retail') | Should Be 'not_checked'
    }

    It 'reports "updates_available" when the flavour has at least one pending update' {
        Initialize-JobState
        $Script:UpdatesCheckedAtByFlavour['retail'] = (Get-Date).ToString('o')
        $Script:UpdateAvailableByFlavour['retail'] = @{ '12345' = @{ fileId = 999; version = 'v2' } }
        (Get-ComputedFreshness -CurrentJobView $null -Flavor 'retail') | Should Be 'updates_available'
    }

    It 'reports "up_to_date" when checked, not failed, and nothing is pending' {
        Initialize-JobState
        $Script:UpdatesCheckedAtByFlavour['retail'] = (Get-Date).ToString('o')
        (Get-ComputedFreshness -CurrentJobView $null -Flavor 'retail') | Should Be 'up_to_date'
    }

    It 'each flavour has its own independent freshness - a Classic Era job "checking" never leaks into Retail''s freshness' {
        Initialize-JobState
        $Script:UpdatesCheckedAtByFlavour['retail'] = (Get-Date).ToString('o')
        $jobView = [PSCustomObject]@{ state = 'running'; kind = 'sync' }
        (Get-ComputedFreshness -CurrentJobView $jobView -Flavor 'classic_era') | Should Be 'checking'
        (Get-ComputedFreshness -CurrentJobView $null -Flavor 'retail') | Should Be 'up_to_date'
    }
}

Remove-TempRoots
