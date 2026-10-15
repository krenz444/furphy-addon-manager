<#
=====================================================================
 tests\unit\Cli.Round49.Tests.ps1

 Unit tests (Pester 3 syntax) for the Round 49 audit LOW fixes in
 addon-sync.ps1:

   LOW 12  Offline runs: a 5xx answer or a dropped/timed-out transport is
           retried once like the rate-limit codes always were, and after
           three "cannot reach this host" failures in a row every further
           request to THAT host fails at once (a whole run on a PC with no
           network ends in seconds). Any HTTP answer resets the streak.
   LOW 10  Disk: backup folders of addons that are no longer tracked are
           removed once untouched for 30 days (plus the obsolete Round 2
           "<fileId>.filename.txt" sidecars); a tracked addon's backups,
           recent activity, unrecognised folders and an unloadable
           (empty) addon list are never touched.

 Invoke-WebRequest and Start-Sleep are shadowed (a function outranks a
 cmdlet) so no request is ever made and no wait is ever paid. The one CLI
 case runs the real script against a scratch root with a pinned GitHub
 record, which makes no network call at all.
=====================================================================
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
$Script:AddonSyncPathR49 = Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1'
. $Script:AddonSyncPathR49

# ---------------------------------------------------------------------
# Shadows + scripted responses
# ---------------------------------------------------------------------

$Script:R49Calls = New-Object 'System.Collections.Generic.List[string]'
$Script:R49Sleeps = New-Object 'System.Collections.Generic.List[string]'
$Script:R49Responses = New-Object 'System.Collections.Generic.Queue[object]'

function Start-Sleep {
    param([int]$Seconds = 0, [int]$Milliseconds = 0)
    $Script:R49Sleeps.Add("$Seconds/$Milliseconds")
}

function Invoke-WebRequest {
    param($Uri, $Headers, $UserAgent, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction, $OutFile)
    $Script:R49Calls.Add([string]$Uri)
    if ($Script:R49Responses.Count -eq 0) { throw 'R49 test: no scripted response left' }
    $next = $Script:R49Responses.Dequeue()
    if ($next.Throw) { throw $next.Throw }
    return $next.Result
}

function Reset-R49 {
    $script:HostFailureStreak = @{}
    $Script:R49Calls.Clear()
    $Script:R49Sleeps.Clear()
    $Script:R49Responses.Clear()
}

function Add-R49Ok {
    $Script:R49Responses.Enqueue(@{ Result = [PSCustomObject]@{ StatusCode = 200; Content = '{"data":[]}' } })
}

function Add-R49HttpError {
    <# An HTTP error ANSWER: Get-ExceptionStatusCode reads .Response.StatusCode off the exception, exactly as for a real WebException(ProtocolError). #>
    param([int]$StatusCode)
    $ex = New-Object System.Exception("HTTP $StatusCode (fake)")
    Add-Member -InputObject $ex -NotePropertyName 'Response' -NotePropertyValue ([PSCustomObject]@{ StatusCode = $StatusCode; Headers = @{} }) -Force
    $Script:R49Responses.Enqueue(@{ Throw = $ex })
}

function Add-R49Transport {
    <# A transport-level failure: a real System.Net.WebException carrying only a Status (no response). #>
    param([string]$Status)
    $ex = New-Object System.Net.WebException("transport failure: $Status", [System.Net.WebExceptionStatus]$Status)
    $Script:R49Responses.Enqueue(@{ Throw = $ex })
}

function Invoke-R49Cf {
    <# One CurseForge request through the real wrapper; returns @{ Ok; Message }. #>
    param([string]$Uri = 'https://www.curseforge.com/api/v1/mods/1/files')
    try {
        $null = Invoke-CfRequest -Uri $Uri
        return @{ Ok = $true; Message = '' }
    } catch {
        return @{ Ok = $false; Message = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------
# LOW 12 - classification helpers
# ---------------------------------------------------------------------

Describe 'Failure classification (Round 49, audit LOW 12)' {

    function New-R49ErrorRecord {
        param($Exception)
        return (New-Object System.Management.Automation.ErrorRecord($Exception, 'R49', [System.Management.Automation.ErrorCategory]::NotSpecified, $null))
    }

    It 'a name-resolution / connect failure / timeout is a connectivity failure; an HTTP answer never is' {
        foreach ($s in 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure', 'Timeout') {
            $er = New-R49ErrorRecord -Exception (New-Object System.Net.WebException('x', [System.Net.WebExceptionStatus]$s))
            (Test-IsConnectivityFailure -ErrorRecord $er) | Should Be $true
        }
        $http = New-Object System.Exception('503')
        Add-Member -InputObject $http -NotePropertyName 'Response' -NotePropertyValue ([PSCustomObject]@{ StatusCode = 503 }) -Force
        (Test-IsConnectivityFailure -ErrorRecord (New-R49ErrorRecord -Exception $http)) | Should Be $false
    }

    It '5xx answers and dropped/timed-out transports are transient; name-resolution/connect failures and 4xx are not' {
        $none = New-R49ErrorRecord -Exception (New-Object System.Exception('plain'))
        foreach ($code in 500, 502, 503, 504) { (Test-IsTransientFailure -ErrorRecord $none -StatusCode $code) | Should Be $true }
        foreach ($code in 400, 401, 404, 410, 501) { (Test-IsTransientFailure -ErrorRecord $none -StatusCode $code) | Should Be $false }
        foreach ($s in 'Timeout', 'ConnectionClosed', 'ReceiveFailure') {
            $er = New-R49ErrorRecord -Exception (New-Object System.Net.WebException('x', [System.Net.WebExceptionStatus]$s))
            (Test-IsTransientFailure -ErrorRecord $er -StatusCode 0) | Should Be $true
        }
        foreach ($s in 'NameResolutionFailure', 'ConnectFailure') {
            $er = New-R49ErrorRecord -Exception (New-Object System.Net.WebException('x', [System.Net.WebExceptionStatus]$s))
            (Test-IsTransientFailure -ErrorRecord $er -StatusCode 0) | Should Be $false
        }
    }

    It 'Get-UriHostKey lowercases the host and is empty for a value that is not a URL' {
        (Get-UriHostKey -Uri 'https://WWW.CurseForge.com/api/v1/mods/1') | Should Be 'www.curseforge.com'
        (Get-UriHostKey -Uri 'not a url') | Should Be ''
    }
}

# ---------------------------------------------------------------------
# LOW 12 - retry of transient failures
# ---------------------------------------------------------------------

Describe 'Transient failures are retried once (Round 49, audit LOW 12)' {

    It 'CurseForge: a 503 then a 200 succeeds on the second attempt, after the usual 5 s wait' {
        Reset-R49
        Add-R49HttpError -StatusCode 503
        Add-R49Ok
        (Invoke-R49Cf).Ok | Should Be $true
        $Script:R49Calls.Count | Should Be 2
        ($Script:R49Sleeps -contains '5/0') | Should Be $true
    }

    It 'CurseForge: a timeout then a 200 succeeds on the second attempt' {
        Reset-R49
        Add-R49Transport -Status 'Timeout'
        Add-R49Ok
        (Invoke-R49Cf).Ok | Should Be $true
        $Script:R49Calls.Count | Should Be 2
    }

    It 'CurseForge: a 503 that persists fails after exactly ONE retry (two attempts, never a loop)' {
        Reset-R49
        Add-R49HttpError -StatusCode 503
        Add-R49HttpError -StatusCode 503
        (Invoke-R49Cf).Ok | Should Be $false
        $Script:R49Calls.Count | Should Be 2
    }

    It 'CurseForge: a 404 is an answer, not a blip - never retried' {
        Reset-R49
        Add-R49HttpError -StatusCode 404
        (Invoke-R49Cf).Ok | Should Be $false
        $Script:R49Calls.Count | Should Be 1
    }

    It 'CurseForge: the existing 429 and 403 retries are unchanged' {
        Reset-R49
        Add-R49HttpError -StatusCode 429
        Add-R49Ok
        (Invoke-R49Cf).Ok | Should Be $true
        $Script:R49Calls.Count | Should Be 2
        Reset-R49
        Add-R49HttpError -StatusCode 403
        Add-R49Ok
        (Invoke-R49Cf).Ok | Should Be $true
        $Script:R49Calls.Count | Should Be 2
    }

    It 'Wago: a 500 is retried once; its own 503 retry is unchanged' {
        Reset-R49
        Add-R49HttpError -StatusCode 500
        Add-R49Ok
        $null = Invoke-WagoRequest -Uri 'https://addons.wago.io/addons/foo'
        $Script:R49Calls.Count | Should Be 2
        Reset-R49
        Add-R49HttpError -StatusCode 503
        Add-R49Ok
        $null = Invoke-WagoRequest -Uri 'https://addons.wago.io/addons/foo'
        $Script:R49Calls.Count | Should Be 2
    }

    It 'GitHub: a 502 is retried once; a 404 is still never retried' {
        Reset-R49
        Add-R49HttpError -StatusCode 502
        Add-R49Ok
        $null = Invoke-GithubRequest -Uri 'https://api.github.com/repos/acme/x/releases/latest'
        $Script:R49Calls.Count | Should Be 2

        Reset-R49
        Add-R49HttpError -StatusCode 404
        $threw = $false
        try { $null = Invoke-GithubRequest -Uri 'https://api.github.com/repos/acme/x/releases/latest' } catch { $threw = $true }
        $threw | Should Be $true
        $Script:R49Calls.Count | Should Be 1
    }
}

# ---------------------------------------------------------------------
# LOW 12 - the offline short-circuit
# ---------------------------------------------------------------------

Describe 'Per-host offline short-circuit (Round 49, audit LOW 12)' {

    It 'after three connect failures in a row the fourth request to that host fails AT ONCE, with no request made' {
        Reset-R49
        foreach ($i in 1..3) { Add-R49Transport -Status 'NameResolutionFailure' }
        foreach ($i in 1..3) { (Invoke-R49Cf).Ok | Should Be $false }
        $Script:R49Calls.Count | Should Be 3

        $fourth = Invoke-R49Cf
        $fourth.Ok | Should Be $false
        $Script:R49Calls.Count | Should Be 3    # not a fourth request
        ($fourth.Message -match 'did not answer 3 requests in a row') | Should Be $true
    }

    It 'a name-resolution failure is NOT retried (offline is not a blip), so each addon pays one attempt, not two' {
        Reset-R49
        Add-R49Transport -Status 'NameResolutionFailure'
        (Invoke-R49Cf).Ok | Should Be $false
        $Script:R49Calls.Count | Should Be 1
    }

    It 'the breaker is per host: CurseForge being unreachable does not stop Wago or GitHub requests' {
        Reset-R49
        foreach ($i in 1..3) { Add-R49Transport -Status 'ConnectFailure' }
        foreach ($i in 1..3) { $null = Invoke-R49Cf }
        (Test-HostBreakerOpen -HostKey 'www.curseforge.com') | Should Be $true

        Add-R49Ok
        $null = Invoke-WagoRequest -Uri 'https://addons.wago.io/addons/foo'
        (Test-HostBreakerOpen -HostKey 'addons.wago.io') | Should Be $false
        $Script:R49Calls.Count | Should Be 4
    }

    It 'a success in between resets the streak - two failures, a success, two failures never trips it' {
        Reset-R49
        Add-R49Transport -Status 'ConnectFailure'
        Add-R49Transport -Status 'ConnectFailure'
        Add-R49Ok
        Add-R49Transport -Status 'ConnectFailure'
        Add-R49Transport -Status 'ConnectFailure'
        foreach ($i in 1..5) { $null = Invoke-R49Cf }
        (Test-HostBreakerOpen -HostKey 'www.curseforge.com') | Should Be $false
        $Script:R49Calls.Count | Should Be 5
    }

    It 'any HTTP answer - even a 404 - proves the host is reachable and resets the streak' {
        Reset-R49
        Add-R49Transport -Status 'ConnectFailure'
        Add-R49Transport -Status 'ConnectFailure'
        Add-R49HttpError -StatusCode 404
        Add-R49Transport -Status 'ConnectFailure'
        foreach ($i in 1..4) { $null = Invoke-R49Cf }
        (Test-HostBreakerOpen -HostKey 'www.curseforge.com') | Should Be $false
    }

    It 'timeouts count toward the breaker too, and the retry stops the moment it opens' {
        # call 1: attempt 1 timeout (streak 1) -> retry attempt 2 timeout (streak 2) -> fails
        # call 2: attempt 1 timeout (streak 3, breaker opens) -> NOT retried -> fails
        Reset-R49
        foreach ($i in 1..3) { Add-R49Transport -Status 'Timeout' }
        $null = Invoke-R49Cf
        $null = Invoke-R49Cf
        $Script:R49Calls.Count | Should Be 3
        (Test-HostBreakerOpen -HostKey 'www.curseforge.com') | Should Be $true
        # a third addon in the run costs nothing
        (Invoke-R49Cf).Ok | Should Be $false
        $Script:R49Calls.Count | Should Be 3
    }

    It 'the failure is a WebException, so callers that read the status code / catch web errors need no change' {
        Reset-R49
        $script:HostFailureStreak['www.curseforge.com'] = 3
        $caught = $null
        try { $null = Invoke-CfRequest -Uri 'https://www.curseforge.com/api/v1/mods/1' } catch { $caught = $_ }
        ($caught.Exception -is [System.Net.WebException]) | Should Be $true
        (Get-ExceptionStatusCode -ErrorRecord $caught) | Should Be 0
    }
}

# ---------------------------------------------------------------------
# LOW 10 - backup folders of addons that are no longer tracked
# ---------------------------------------------------------------------

Describe 'Remove-OrphanedBackupFolders (Round 49, audit LOW 10)' {

    function New-R49BackupDir {
        <# <backups>\<key> holding one file per -Files entry, every timestamp -AgeDays old (files first, the folder last, so its own mtime is old too). #>
        param([string]$BackupsRoot, [string]$Key, [int]$AgeDays, [string[]]$Files = @('1.zip'))
        $dir = Join-Path $BackupsRoot $Key
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $when = (Get-Date).ToUniversalTime().AddDays(-1 * $AgeDays)
        foreach ($f in $Files) {
            $p = Join-Path $dir $f
            [System.IO.File]::WriteAllText($p, 'zip bytes')
            (Get-Item -LiteralPath $p).LastWriteTimeUtc = $when
        }
        (Get-Item -LiteralPath $dir).LastWriteTimeUtc = $when
        return $dir
    }

    function Get-R49Config {
        return @(
            [PSCustomObject]@{ source = 'curseforge'; projectId = 111; name = 'Tracked CF' },
            [PSCustomObject]@{ source = 'wago'; slug = 'tracked-wago'; projectId = $null; name = 'Tracked Wago' },
            [PSCustomObject]@{ source = 'github'; repo = 'acme/Tracked'; projectId = $null; name = 'Tracked GH' }
        )
    }

    It 'removes an untracked addon''s backup folder once nothing in it was touched for 30 days - for all three key shapes' {
        $root = New-TempRoot -Name 'r49-bk-orphans'
        $null = New-R49BackupDir -BackupsRoot $root -Key '222' -AgeDays 90
        $null = New-R49BackupDir -BackupsRoot $root -Key 'wago-gone-addon' -AgeDays 90
        $null = New-R49BackupDir -BackupsRoot $root -Key 'github-acme_Gone' -AgeDays 90

        $r = Remove-OrphanedBackupFolders -BackupsRoot $root -Config (Get-R49Config)

        $r.FoldersRemoved | Should Be 3
        (Test-Path -LiteralPath (Join-Path $root '222')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $root 'wago-gone-addon')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $root 'github-acme_Gone')) | Should Be $false
    }

    It 'never touches a tracked addon''s folder - CurseForge, Wago or GitHub - however old' {
        $root = New-TempRoot -Name 'r49-bk-tracked'
        $null = New-R49BackupDir -BackupsRoot $root -Key '111' -AgeDays 400
        $null = New-R49BackupDir -BackupsRoot $root -Key 'wago-tracked-wago' -AgeDays 400
        $null = New-R49BackupDir -BackupsRoot $root -Key 'github-acme_Tracked' -AgeDays 400

        $r = Remove-OrphanedBackupFolders -BackupsRoot $root -Config (Get-R49Config)

        $r.FoldersRemoved | Should Be 0
        (Test-Path -LiteralPath (Join-Path $root '111\1.zip')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $root 'wago-tracked-wago\1.zip')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $root 'github-acme_Tracked\1.zip')) | Should Be $true
    }

    It 'keeps an untracked folder with anything written inside the 30-day window (a removal can still be reconsidered)' {
        $root = New-TempRoot -Name 'r49-bk-recent'
        $dir = New-R49BackupDir -BackupsRoot $root -Key '333' -AgeDays 90 -Files @('old.zip', 'recent.zip')
        $recent = Join-Path $dir 'recent.zip'
        (Get-Item -LiteralPath $recent).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-3)

        $r = Remove-OrphanedBackupFolders -BackupsRoot $root -Config (Get-R49Config)

        $r.FoldersRemoved | Should Be 0
        (Test-Path -LiteralPath (Join-Path $root '333\old.zip')) | Should Be $true
    }

    It 'leaves folders whose name is not a backup key this code generates' {
        $root = New-TempRoot -Name 'r49-bk-foreign'
        $null = New-R49BackupDir -BackupsRoot $root -Key 'my-own-notes' -AgeDays 400
        $null = New-R49BackupDir -BackupsRoot $root -Key 'staging' -AgeDays 400

        $r = Remove-OrphanedBackupFolders -BackupsRoot $root -Config (Get-R49Config)

        $r.FoldersRemoved | Should Be 0
        (Test-Path -LiteralPath (Join-Path $root 'my-own-notes\1.zip')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $root 'staging\1.zip')) | Should Be $true
    }

    It 'an EMPTY addon list means "addons.json did not load", not "everything was removed": nothing is deleted' {
        $root = New-TempRoot -Name 'r49-bk-empty'
        $null = New-R49BackupDir -BackupsRoot $root -Key '444' -AgeDays 400

        $r = Remove-OrphanedBackupFolders -BackupsRoot $root -Config @()

        $r.FoldersRemoved | Should Be 0
        (Test-Path -LiteralPath (Join-Path $root '444\1.zip')) | Should Be $true
    }

    It 'a record that cannot be keyed aborts the sweep instead of guessing what is orphaned' {
        $root = New-TempRoot -Name 'r49-bk-unkeyable'
        $null = New-R49BackupDir -BackupsRoot $root -Key '555' -AgeDays 400
        $config = @((Get-R49Config)[0], $null)

        $r = Remove-OrphanedBackupFolders -BackupsRoot $root -Config $config

        $r.FoldersRemoved | Should Be 0
        (Test-Path -LiteralPath (Join-Path $root '555\1.zip')) | Should Be $true
    }

    It 'removes the obsolete Round 2 "<fileId>.filename.txt" sidecars from a tracked addon''s folder and keeps its zips' {
        $root = New-TempRoot -Name 'r49-bk-sidecar'
        $dir = New-R49BackupDir -BackupsRoot $root -Key '111' -AgeDays 5 -Files @('900.zip', '900.filename.txt', '901.filename.txt', 'adopted-original.zip')

        $r = Remove-OrphanedBackupFolders -BackupsRoot $root -Config (Get-R49Config)

        $r.SidecarsRemoved | Should Be 2
        (Test-Path -LiteralPath (Join-Path $dir '900.filename.txt')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $dir '901.filename.txt')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $dir '900.zip')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $dir 'adopted-original.zip')) | Should Be $true
    }

    It 'a missing backups folder is a quiet no-op' {
        $root = New-TempRoot -Name 'r49-bk-missing'
        $r = Remove-OrphanedBackupFolders -BackupsRoot (Join-Path $root 'nope') -Config (Get-R49Config)
        $r.FoldersRemoved | Should Be 0
        $r.SidecarsRemoved | Should Be 0
    }

    It 'the one-time flavours\_migration-backup-* copy is not this function''s business (it lives outside backups\)' {
        # Documented in the function's own header: FLAVORS-SPEC.md 3.3 says
        # that folder is never auto-deleted, and it sits next to - not
        # inside - the per-flavour backups folder this sweeps.
        $root = New-TempRoot -Name 'r49-bk-migration'
        $mig = Join-Path $root 'flavours\_migration-backup-20260904-234328'
        New-Item -ItemType Directory -Path $mig -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $mig 'addons.json'), '[]')
        $backups = Join-Path $root 'flavours\retail\backups'
        New-Item -ItemType Directory -Path $backups -Force | Out-Null

        $null = Remove-OrphanedBackupFolders -BackupsRoot $backups -Config (Get-R49Config)

        (Test-Path -LiteralPath (Join-Path $mig 'addons.json')) | Should Be $true
    }
}

# ---------------------------------------------------------------------
# LOW 10 - wired into a real sync run (offline: a pinned GitHub record makes no network call)
# ---------------------------------------------------------------------

Describe 'CLI: the sync run prunes orphaned backups; a check does not (Round 49, audit LOW 10)' {

    function New-R49CliLayout {
        <# A scratch root with a copy of the CLI, one GitHub record pinned to its installed tag, and an orphan + a tracked backup folder. #>
        param([string]$Name)
        $root = New-TempRoot -Name $Name
        $cliPath = Join-Path $root 'addon-sync.ps1'
        Copy-Item -LiteralPath $Script:AddonSyncPathR49 -Destination $cliPath -Force

        $wowRoot = Copy-Fixture
        $addons = Join-Path $wowRoot '_retail_\Interface\AddOns'
        New-Item -ItemType Directory -Path (Join-Path $addons 'PinMe') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $addons 'PinMe\PinMe.toc'), "## Interface: 110000`r`n## Title: PinMe`r`n## Version: v1.0.0`r`n")

        $flavourDir = Join-Path $root 'flavours\retail'
        New-Item -ItemType Directory -Path $flavourDir -Force | Out-Null
        $record = [PSCustomObject]@{
            name = 'PinMe'; projectId = $null; fileId = $null; version = 'v1.0.0'; fileName = $null
            installedAt = '2026-10-01T00:00:00Z'; folders = @('PinMe'); author = $null
            ignoreUpdates = $false; pinnedFileId = 'v1.0.0'; releaseType = $null
            previousFileId = $null; previousVersion = $null; previousFileName = $null
            requiredDeps = @(); optionalDeps = @(); source = 'github'; wagoId = $null; slug = $null; curseId = $null
            latestGameVersions = @(); latestFileDate = $null; repo = 'acme/PinMe'; installedTag = 'v1.0.0'; assetName = $null
        }
        ConvertTo-Json -InputObject @($record) -Depth 10 | Set-Content -LiteralPath (Join-Path $flavourDir 'addons.json') -Encoding UTF8

        $backups = Join-Path $flavourDir 'backups'
        $old = (Get-Date).ToUniversalTime().AddDays(-90)
        foreach ($key in 'github-acme_PinMe', '987654') {
            $d = Join-Path $backups $key
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            $z = Join-Path $d '1.zip'
            [System.IO.File]::WriteAllText($z, 'zip bytes')
            (Get-Item -LiteralPath $z).LastWriteTimeUtc = $old
            (Get-Item -LiteralPath $d).LastWriteTimeUtc = $old
        }
        return [PSCustomObject]@{ Cli = $cliPath; WowRoot = $wowRoot; Backups = $backups }
    }

    It 'a real sync removes the untracked addon''s old backup folder and keeps the tracked one' {
        $l = New-R49CliLayout -Name 'r49-cli-sync'
        $r = Invoke-CliJson -ScriptPath $l.Cli -TimeoutSec 90 -ArgumentList @('-Json', '-WowRoot', $l.WowRoot, '-Flavor', 'retail')

        $r.ExitCode | Should Be 0
        $r.Json.action | Should Be 'sync'
        (Test-Path -LiteralPath (Join-Path $l.Backups '987654')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $l.Backups 'github-acme_PinMe\1.zip')) | Should Be $true
    }

    It 'a check (-DryRun) deletes nothing' {
        $l = New-R49CliLayout -Name 'r49-cli-check'
        $r = Invoke-CliJson -ScriptPath $l.Cli -TimeoutSec 90 -ArgumentList @('-DryRun', '-Json', '-WowRoot', $l.WowRoot, '-Flavor', 'retail')

        $r.ExitCode | Should Be 0
        $r.Json.action | Should Be 'check'
        (Test-Path -LiteralPath (Join-Path $l.Backups '987654\1.zip')) | Should Be $true
    }
}

Remove-TempRoots
