<#
=====================================================================
 tests\unit\Server.Round49.Tests.ps1

 Unit tests (Pester 3 syntax) for the Round 49 audit LOW fixes that live in
 addon-server.ps1. The guarded server script is dot-sourced (it never binds
 a socket); handlers are called with the fake HttpListener context from
 tests\lib\common.ps1; every file lands under tests\.tmp.

   LOW 7    An addon put on "ignore" after the last check no longer counts
            toward the freshness headline (Get-ComputedFreshness gains
            -PendingUpdateCount; Handle-State passes the non-ignored count).
   LOW 8    A staged self-update whose folder vanished from %TEMP% is never
            launched: Handle-AppUpdateInstall answers 410 and resets the
            state; Test-AppUpdateStagedInstallerPresent is the one predicate.
   LOW 10   The one-time pre-upgrade backup folder is listed (with its size)
            and removed only on request - and nothing else is ever removed.
   LOW 13a  DNS-rebinding guard: a Host header that is not localhost /
            127.0.0.1 / [::1] is refused with 403 before routing, GET
            included.
=====================================================================
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

# Shadows the Start-Process cmdlet (a function outranks a cmdlet) so nothing
# real ever launches - what WOULD have started is recorded for inspection.
function Start-Process {
    param([string]$FilePath, $ArgumentList, [switch]$PassThru, $WindowStyle, [switch]$Wait, [switch]$NoNewWindow)
    $Script:FurphyTestStartedProcess = [PSCustomObject]@{ FilePath = $FilePath; Arguments = (@($ArgumentList) -join ' ') }
}

function Initialize-R49JobState {
    $Script:Jobs = New-Object 'System.Collections.Generic.List[object]'
    $Script:JobIdSeq = 0
    $Script:CurrentJobByFlavour = @{}
    $Script:UpdateAvailableByFlavour = @{}
    $Script:LastRunByFlavour = @{}
    $Script:UpdatesCheckedAtByFlavour = @{}
    $Script:LastCheckFailedByFlavour = @{}
    $Script:LastCheckErrorByFlavour = @{}
}

function Set-R49File {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------
# LOW 13a - Host header guard
# ---------------------------------------------------------------------

Describe 'Test-LoopbackHostHeader (Round 49, audit LOW 13a)' {

    function Test-R49Host {
        param([string]$HostValue)
        $headers = @{}
        if ($null -ne $HostValue) { $headers['Host'] = $HostValue }
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/state' -Headers $headers
        return (Test-LoopbackHostHeader -Context $ctx)
    }

    It 'accepts localhost with the server port' {
        (Test-R49Host -HostValue 'localhost:47831') | Should Be $true
    }

    It 'accepts 127.0.0.1 and [::1] with a port, and a bare localhost' {
        (Test-R49Host -HostValue '127.0.0.1:47831') | Should Be $true
        (Test-R49Host -HostValue '[::1]:47831') | Should Be $true
        (Test-R49Host -HostValue 'localhost') | Should Be $true
    }

    It 'is not case sensitive' {
        (Test-R49Host -HostValue 'LocalHost:47831') | Should Be $true
    }

    It 'rejects a foreign name - the DNS-rebinding case (attacker.example re-pointed at 127.0.0.1)' {
        (Test-R49Host -HostValue 'attacker.example:47831') | Should Be $false
        (Test-R49Host -HostValue 'attacker.example') | Should Be $false
    }

    It 'rejects look-alikes: a suffix/prefix of localhost, userinfo tricks, other loopback addresses' {
        (Test-R49Host -HostValue 'localhost.evil.com:47831') | Should Be $false
        (Test-R49Host -HostValue 'evil-localhost:47831') | Should Be $false
        (Test-R49Host -HostValue 'localhost@evil.com') | Should Be $false
        (Test-R49Host -HostValue '127.0.0.2:47831') | Should Be $false
        (Test-R49Host -HostValue '10.0.0.5:47831') | Should Be $false
    }

    It 'rejects an unparsable Host value instead of throwing' {
        (Test-R49Host -HostValue 'not a host at all') | Should Be $false
    }

    It 'lets a request with no Host header through (an HTTP/1.0 client - a browser always sends one)' {
        (Test-R49Host -HostValue $null) | Should Be $true
    }
}

Describe 'Invoke-Route answers a foreign Host header with 403 before routing (Round 49, audit LOW 13a)' {

    $Script:Port = 47899

    It 'a GET with a foreign Host is 403 "host not allowed" - the read endpoints are no longer reachable by rebinding' {
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/state' -Headers @{ Host = 'attacker.example:47899' }
        Invoke-Route -Context $ctx
        $ctx.Response.StatusCode | Should Be 403
        (Get-FakeResponseBody -Context $ctx).error | Should Be 'forbidden: host not allowed'
    }

    It 'static files are behind the same gate' {
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/index.html' -Headers @{ Host = 'attacker.example:47899' }
        Invoke-Route -Context $ctx
        $ctx.Response.StatusCode | Should Be 403
    }

    It 'the same request with a loopback Host is NOT refused by the gate (an unknown api path falls through to the normal 404)' {
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/no-such-route' -Headers @{ Host = 'localhost:47899' }
        Invoke-Route -Context $ctx
        $ctx.Response.StatusCode | Should Be 404
        (Get-FakeResponseBody -Context $ctx).error | Should Be 'not found'
    }
}

# ---------------------------------------------------------------------
# LOW 7 - ignored addons do not count toward the freshness headline
# ---------------------------------------------------------------------

Describe 'Get-ComputedFreshness -PendingUpdateCount (Round 49, audit LOW 7)' {

    It 'a map entry that belongs to an ignored addon (count 0) reads up_to_date, not updates_available' {
        Initialize-R49JobState
        $Script:UpdatesCheckedAtByFlavour['retail'] = (Get-Date).ToString('o')
        $Script:UpdateAvailableByFlavour['retail'] = @{ '12345' = @{ fileId = 999; version = 'v2' } }
        (Get-ComputedFreshness -CurrentJobView $null -Flavor 'retail' -PendingUpdateCount 0) | Should Be 'up_to_date'
    }

    It 'one actionable update (count 1) is updates_available' {
        Initialize-R49JobState
        $Script:UpdatesCheckedAtByFlavour['retail'] = (Get-Date).ToString('o')
        $Script:UpdateAvailableByFlavour['retail'] = @{ '12345' = @{ fileId = 999; version = 'v2' } }
        (Get-ComputedFreshness -CurrentJobView $null -Flavor 'retail' -PendingUpdateCount 1) | Should Be 'updates_available'
    }

    It 'without the argument every map entry still counts (the pre-Round-49 behaviour other callers rely on)' {
        Initialize-R49JobState
        $Script:UpdatesCheckedAtByFlavour['retail'] = (Get-Date).ToString('o')
        $Script:UpdateAvailableByFlavour['retail'] = @{ '12345' = @{ fileId = 999; version = 'v2' } }
        (Get-ComputedFreshness -CurrentJobView $null -Flavor 'retail') | Should Be 'updates_available'
    }

    It 'the count never overrides checking / check_failed / not_checked' {
        Initialize-R49JobState
        (Get-ComputedFreshness -CurrentJobView $null -Flavor 'retail' -PendingUpdateCount 3) | Should Be 'not_checked'
        $Script:LastCheckFailedByFlavour['retail'] = $true
        (Get-ComputedFreshness -CurrentJobView $null -Flavor 'retail' -PendingUpdateCount 3) | Should Be 'check_failed'
        $jobView = [PSCustomObject]@{ state = 'running'; kind = 'check' }
        (Get-ComputedFreshness -CurrentJobView $jobView -Flavor 'retail' -PendingUpdateCount 3) | Should Be 'checking'
    }
}

# ---------------------------------------------------------------------
# LOW 8 - the staged self-update must still be on disk
# ---------------------------------------------------------------------

Describe 'App-update staged copy (Round 49, audit LOW 8)' {

    function Initialize-R49AppUpdate {
        <# A scratch root + app-update.json path, and the script-scope state Handle-AppUpdateInstall reads. #>
        param([string]$Name)
        $root = New-TempRoot -Name $Name
        $Script:AppUpdatePath = Join-Path $root 'app-update.json'
        $Script:Version = '1.0.0'
        $Script:CurrentJobByFlavour = @{}
        $Script:FurphyTestStartedProcess = $null
        return $root
    }

    function Save-R49ReadyState {
        param([string]$StagedPath)
        $st = Get-DefaultAppUpdateState
        $st.state = 'ready'
        $st.latestVersion = '9.9.9'
        $st.releaseTag = 'v9.9.9'
        $st.checkedAt = '2026-10-14T12:00:00Z'
        $st.downloadedAt = '2026-10-14T12:01:00Z'
        $st.stagedPath = $StagedPath
        Save-AppUpdateState -State $st
    }

    It 'Test-AppUpdateStagedInstallerPresent is true only when stagedPath holds install.ps1' {
        $root = Initialize-R49AppUpdate -Name 'r49-au-present'
        $staged = Join-Path $root 'FurphyUpdate-v9.9.9-abc'
        $st = Get-DefaultAppUpdateState
        $st.stagedPath = $staged
        (Test-AppUpdateStagedInstallerPresent -State $st) | Should Be $false   # folder missing
        New-Item -ItemType Directory -Path $staged -Force | Out-Null
        (Test-AppUpdateStagedInstallerPresent -State $st) | Should Be $false   # folder, no install.ps1
        Set-R49File -Path (Join-Path $staged 'install.ps1') -Content '# stub'
        (Test-AppUpdateStagedInstallerPresent -State $st) | Should Be $true
        $st.stagedPath = $null
        (Test-AppUpdateStagedInstallerPresent -State $st) | Should Be $false   # no path recorded
        (Test-AppUpdateStagedInstallerPresent -State $null) | Should Be $false
    }

    It 'POST install while state=ready but the staged folder is gone: 410 with a plain reason, state reset to idle, nothing launched' {
        $root = Initialize-R49AppUpdate -Name 'r49-au-gone'
        Save-R49ReadyState -StagedPath (Join-Path $root 'FurphyUpdate-v9.9.9-gone')

        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/app-update/install' -JsonBody @{ relaunch = 'window' }
        Handle-AppUpdateInstall -Context $ctx -RouteMatch @{}

        $ctx.Response.StatusCode | Should Be 410
        ((Get-FakeResponseBody -Context $ctx).error -match 'no longer on this PC') | Should Be $true
        $Script:FurphyTestStartedProcess | Should Be $null

        $after = Get-AppUpdateState
        $after.state | Should Be 'idle'
        $after.stagedPath | Should Be $null
        $after.downloadedAt | Should Be $null
        # checkedAt cleared too, so the next (hourly) maintenance tick - not
        # a 24 h wait - looks the release up and stages it again.
        $after.checkedAt | Should Be $null
        $Script:ShuttingDown | Should Not Be $true
    }

    It 'with the staged install.ps1 present the install proceeds (dry-run seam: 200 and the command line names the STAGED script)' {
        $root = Initialize-R49AppUpdate -Name 'r49-au-ok'
        $staged = Join-Path $root 'FurphyUpdate-v9.9.9-ok'
        Set-R49File -Path (Join-Path $staged 'install.ps1') -Content '# stub installer, never run'
        Save-R49ReadyState -StagedPath $staged

        # A WoW root so Handle-AppUpdateInstall's own WoW-folder resolution succeeds.
        $wowRoot = New-TempRoot -Name 'r49-au-wow'
        New-Item -ItemType Directory -Path (Join-Path $wowRoot '_retail_\Interface\AddOns') -Force | Out-Null
        $Script:AddonsPathOverride = $null
        $Script:WowRootOverride = $wowRoot
        $Script:BuildInfoPathOverride = $null
        $Script:Root = $root
        Set-CurrentFlavourContext -Flavor 'retail'

        $originalDryRun = $env:FURPHY_TEST_APPUPDATE_DRYRUN
        $Script:ShuttingDown = $false
        try {
            $env:FURPHY_TEST_APPUPDATE_DRYRUN = '1'
            $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/app-update/install' -JsonBody @{ relaunch = 'window' }
            Handle-AppUpdateInstall -Context $ctx -RouteMatch @{}
            $ctx.Response.StatusCode | Should Be 200
            $after = Get-AppUpdateState
            $after.state | Should Be 'installing'
            ($after.testDryRunCommandLine -like ('*' + (Join-Path $staged 'install.ps1') + '*')) | Should Be $true
        } finally {
            if ($null -eq $originalDryRun) { Remove-Item Env:\FURPHY_TEST_APPUPDATE_DRYRUN -ErrorAction SilentlyContinue }
            else { $env:FURPHY_TEST_APPUPDATE_DRYRUN = $originalDryRun }
            $Script:WowRootOverride = $null
        }
        $Script:FurphyTestStartedProcess | Should Be $null
    }

    It 'a busy server still answers 409 first (the staging check never masks the job-running deferral)' {
        $root = Initialize-R49AppUpdate -Name 'r49-au-busy'
        Save-R49ReadyState -StagedPath (Join-Path $root 'FurphyUpdate-v9.9.9-gone')
        $Script:CurrentJobByFlavour = @{ retail = [PSCustomObject]@{ id = 'job-1'; state = 'running'; kind = 'sync'; flavour = 'retail'; Process = $null } }

        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/app-update/install' -JsonBody @{ relaunch = 'window' }
        Handle-AppUpdateInstall -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 409
        # state untouched by the refusal beyond the deferral marker
        (Get-AppUpdateState).state | Should Be 'ready'
        $Script:CurrentJobByFlavour = @{}
    }

    It 'Reset-AppUpdateLostStaging clears the staging markers and persists them' {
        $root = Initialize-R49AppUpdate -Name 'r49-au-reset'
        Save-R49ReadyState -StagedPath (Join-Path $root 'FurphyUpdate-v9.9.9-gone')
        $st = Get-AppUpdateState
        $st.lastError = 'stale error text'
        $result = Reset-AppUpdateLostStaging -State $st
        $result.state | Should Be 'idle'
        $disk = Get-AppUpdateState
        $disk.state | Should Be 'idle'
        $disk.stagedPath | Should Be $null
        $disk.lastError | Should Be $null
        # the release facts survive - they are still true, only the files are gone
        $disk.latestVersion | Should Be '9.9.9'
    }
}

# ---------------------------------------------------------------------
# LOW 10 - the pre-upgrade backup folder: listed, removed on request only
# ---------------------------------------------------------------------

Describe 'Migration backup folder (Round 49, audit LOW 10)' {

    function New-R49MigrationRoot {
        <# <root>\flavours with one real _migration-backup-* folder (3000 bytes) plus decoys that must never be touched. #>
        param([string]$Name, [switch]$WithBackup)
        $root = New-TempRoot -Name $Name
        $Script:Root = $root
        Set-R49File -Path (Join-Path $root 'flavours\retail\addons.json') -Content '[]'
        Set-R49File -Path (Join-Path $root 'flavours\_migration-backup-notes\readme.txt') -Content 'not a backup folder name'
        Set-R49File -Path (Join-Path $root 'flavours\_migration-backup-20260904-234328.zip') -Content 'a FILE, not a folder'
        if ($WithBackup) {
            $bk = Join-Path $root 'flavours\_migration-backup-20260904-234328'
            Set-R49File -Path (Join-Path $bk 'addons.json') -Content ('x' * 1000)
            Set-R49File -Path (Join-Path $bk 'backups\111\222.zip') -Content ('y' * 2000)
        }
        return $root
    }

    It 'GET lists nothing when the upgrade never made one' {
        $null = New-R49MigrationRoot -Name 'r49-mb-none'
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/migration-backup'
        Handle-MigrationBackupGet -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        (@((Get-FakeResponseBody -Context $ctx).items)).Count | Should Be 0
    }

    It 'GET lists the exact-name folder with its recursive size, and ignores look-alikes' {
        $null = New-R49MigrationRoot -Name 'r49-mb-list' -WithBackup
        $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/migration-backup'
        Handle-MigrationBackupGet -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        $items = @((Get-FakeResponseBody -Context $ctx).items)
        $items.Count | Should Be 1
        $items[0].name | Should Be '_migration-backup-20260904-234328'
        $items[0].sizeBytes | Should Be 3000
    }

    It 'POST delete removes only that folder - the live flavour data and the look-alikes are untouched' {
        $root = New-R49MigrationRoot -Name 'r49-mb-delete' -WithBackup
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/migration-backup/delete' -JsonBody @{}
        Handle-MigrationBackupDelete -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        (Get-FakeResponseBody -Context $ctx).removed | Should Be 1
        (Test-Path -LiteralPath (Join-Path $root 'flavours\_migration-backup-20260904-234328')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $root 'flavours\retail\addons.json')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $root 'flavours\_migration-backup-notes\readme.txt')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $root 'flavours\_migration-backup-20260904-234328.zip')) | Should Be $true
    }

    It 'the delete route is behind the same-origin guard: a request with no Origin is 403 and removes nothing' {
        $Script:Port = 47899
        $root = New-R49MigrationRoot -Name 'r49-mb-csrf' -WithBackup
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/migration-backup/delete' -JsonBody @{} -Headers @{ Host = 'localhost:47899' }
        Invoke-Route -Context $ctx
        $ctx.Response.StatusCode | Should Be 403
        (Test-Path -LiteralPath (Join-Path $root 'flavours\_migration-backup-20260904-234328')) | Should Be $true
    }

    It '/api/open "migration-backup" opens that exact folder in Explorer, never a caller-supplied path' {
        $root = New-R49MigrationRoot -Name 'r49-mb-open' -WithBackup
        $Script:FurphyTestStartedProcess = $null
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/open' -JsonBody @{ what = 'migration-backup'; path = 'C:\Windows' }
        Handle-Open -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 200
        $Script:FurphyTestStartedProcess.FilePath | Should Be 'explorer.exe'
        ($Script:FurphyTestStartedProcess.Arguments -like '*_migration-backup-20260904-234328*') | Should Be $true
        ($Script:FurphyTestStartedProcess.Arguments -like '*Windows*') | Should Be $false
    }

    It '/api/open "migration-backup" is a clean 400 when there is none' {
        $null = New-R49MigrationRoot -Name 'r49-mb-open-none'
        $Script:FurphyTestStartedProcess = $null
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/open' -JsonBody @{ what = 'migration-backup' }
        Handle-Open -Context $ctx -RouteMatch @{}
        $ctx.Response.StatusCode | Should Be 400
        $Script:FurphyTestStartedProcess | Should Be $null
    }
}

Remove-TempRoots
