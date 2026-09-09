<#
=====================================================================
 tests\integration\Server.AppUpdate.Tests.ps1  (Package E)

 Integration coverage for APP-UPDATE-SPEC.md sections 4/5/7/8 - the
 check/download/verify/install state machine, the three new
 /api/app-update/* routes, the game/job/window gates, and the
 windowOpenAt "is a window open" signal - against a REAL scratch
 addon-server.ps1 (Start-TestServer) with $env:FURPHY_TEST_GITHUB_BASEURL
 pointed at the real local Start-GitHubReleaseStubServer stub
 (tests\lib\common.ps1), never the real github.com/api.github.com.

 LOAD-BEARING ORDERING, found live while writing this file: the env var
 MUST be set BEFORE Start-TestServer is called, never only around a
 later Invoke-Api call - addon-server.ps1's own maintenance child AND
 its -AppUpdateOnly child are both spawned via Start-Process FROM
 WITHIN the already-running server process, which inherits ITS OWN
 environment block as a fixed snapshot taken at ITS OWN spawn time; a
 later change to this test SCRIPT's own $env: value has no effect on an
 already-running server process or anything it later spawns. Every
 Describe below therefore follows the exact
 `$env:FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl; try { Start-TestServer
 ... } finally { Remove-Item Env:... }` shape
 tests\integration\Server.WagoBrowse.Tests.ps1 already uses for
 FURPHY_TEST_WAGO_BASEURL - removing the var from THIS script's own
 process right after Start-TestServer returns is safe and does not
 affect the server, which already has its own fixed copy.

 A SECOND, related bug this file's own authoring exposed and fixed in
 tests\lib\common.ps1 itself (not scoped to this file - it affects every
 caller of Start-TestServer in the whole suite): Invoke-MaintenanceTick's
 very first tick after ANY fresh server startup "always qualifies" and
 unconditionally also runs Invoke-AppUpdateMaintenance now that Package A
 has landed - so a real, unauthenticated GET to api.github.com fired on
 every single Start-TestServer call in this entire test suite, before
 this fix, regardless of which file was calling it. Start-TestServer now
 defaults $env:FURPHY_TEST_GITHUB_BASEURL to a guaranteed-closed loopback
 port unless a caller (like this file) has already pointed it at a real
 stub - see that function's own updated doc comment.

 CAPABILITY-GATED, ON PURPOSE, same shape as
 tests\integration\Server.WagoBrowse.Tests.ps1's own capability probe -
 kept even now that Package A has landed, so this file degrades
 gracefully again if a future edit ever reverts a piece of its change
 set.

 "The server" this file drives always listens on port 47935 (one fixed
 port in this round's assigned 47934-47939 range for this file, reused
 sequentially across Describes with a Stop-TestServer in every finally
 before the next Describe starts, matching Server.WagoBrowse.Tests.ps1's
 own single-shared-port lifecycle) - never 47831, never the
 fixture-acceptance file's own 47940. The GitHub stub itself uses the
 existing tests\lib\common.ps1 static/stub port pool (Get-FreeStaticPort,
 47890-47897) via Start-GitHubReleaseStubServer's own default - it is a
 throwaway fixture process, not "the server" the round's port assignment
 names.

 A THIRD consequence of the same discovery, load-bearing for how the
 assertions below are written: because $env:FURPHY_TEST_GITHUB_BASEURL
 must be set before Start-TestServer, the server's own automatic
 startup maintenance tick ("the very first tick after startup always
 qualifies") now ALSO reaches this file's stub, racing this file's own
 explicit POST /api/app-update/check. Both callers run the identical
 Invoke-AppUpdateMaintenanceCore, so which one "wins" the race changes
 nothing about pipeline correctness - only the exact HTTP status POST
 /api/app-update/check itself happens to return (202 "spawned a fresh
 check", or 200 "one was already checking/downloading") depends on
 that race, so assertions below accept either rather than hard-coding
 202, and the rate-limit Describe asserts "no growth between two polls"
 rather than "exactly one request ever" for the same reason.

 One Describe (job-running 409) is tagged 'Network': it reuses
 Server.Jobs.Tests.ps1's own "seed a handful of bogus CurseForge project
 ids first, so a real 'check' job is reliably still running a moment
 later" technique (real, fast-404 requests to curseforge.com - never
 github.com) to hold a job open long enough to observe the 409. Every
 other Describe is fully offline.

 Windows PowerShell 5.1, Pester 3 syntax, ASCII only.
=====================================================================
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

# Litter-cleanup cutoff (this round's fixer task) - captured as the very
# first thing this file does, before any Describe below can possibly
# stage a real release into %TEMP%. Every Describe that reaches
# state=ready via a REAL local GitHub stub (never the -AppUpdateOnly
# direct-state-file Describes, which never touch %TEMP% at all) removes
# its own %TEMP%\FurphyUpdate-<its own exact tag>-<guid> folder in its
# own finally block, using this same cutoff - see
# tests\lib\common.ps1's own Remove-AppUpdateTempLitter doc comment for
# why the cutoff (never a blind "sweep everything matching the prefix")
# is what makes this safe to run alongside another fixer's own
# concurrently-running test session on this same shared machine.
$Script:LitterCutoffUtc = (Get-Date).ToUniversalTime()

$Script:AddonServerPath = Join-Path $Script:FurphyBuildRoot 'addon-server.ps1'
$Script:ServerSourceText = Get-Content -LiteralPath $Script:AddonServerPath -Raw

# APPUPD-1: the $Script:GitHubBaseUrl / FURPHY_TEST_GITHUB_BASEURL seam
# (section 8.1) - without this, nothing here can ever be pointed at the
# local stub instead of the real api.github.com.
$Script:CapSeam = [bool]($Script:ServerSourceText -match 'FURPHY_TEST_GITHUB_BASEURL')

# APPUPD-2: the three new routes + handlers (section 5).
$Script:CapRoutes = [bool](
    ($Script:ServerSourceText -match 'function\s+Handle-AppUpdateStatus\b') -and
    ($Script:ServerSourceText -match 'function\s+Handle-AppUpdateCheck\b') -and
    ($Script:ServerSourceText -match 'function\s+Handle-AppUpdateInstall\b') -and
    ($Script:ServerSourceText -match [regex]::Escape("Pattern = '^/api/app-update/status$'")) -and
    ($Script:ServerSourceText -match [regex]::Escape("Pattern = '^/api/app-update/check$'")) -and
    ($Script:ServerSourceText -match [regex]::Escape("Pattern = '^/api/app-update/install$'"))
)

# APPUPD-3: -AppUpdateOnly switch + Invoke-AppUpdateMaintenance (sections
# 7/8.1-8.4) - the actual check/download/verify/extract pipeline.
$Script:CapMaintenance = [bool](
    ($Script:ServerSourceText -match 'AppUpdateOnly') -and
    ($Script:ServerSourceText -match 'function\s+Invoke-AppUpdateMaintenance\b')
)

# APPUPD-4: Handle-State stamps windowOpenAt and folds appUpdate into its
# response (section 7/5).
$Script:CapWindowOpenAt = [bool]($Script:ServerSourceText -match 'windowOpenAt')

$Script:CapCore = $Script:CapSeam -and $Script:CapRoutes

Write-Host ''
Write-Host 'App-update server capability probe (static source grep, no network):' -ForegroundColor Cyan
Write-Host "  APPUPD-1 GitHubBaseUrl seam ............ $Script:CapSeam"
Write-Host "  APPUPD-2 routes + handlers .............. $Script:CapRoutes"
Write-Host "  APPUPD-3 Invoke-AppUpdateMaintenance ..... $Script:CapMaintenance"
Write-Host "  APPUPD-4 windowOpenAt signal ............. $Script:CapWindowOpenAt"
Write-Host ''

function Write-PendingSkip {
    param([string]$Reason)
    Write-Host "  (skipped: PENDING - $Reason)" -ForegroundColor Yellow
}

$Script:AppUpdatePort = 47935

function Get-NotRunningFakeWowName {
    <# A fresh, deliberately nonexistent process name each call, so Test-GameRunning's real Get-Process lookup always misses regardless of the dev machine's own state - mirrors Server.WagoBrowse.Tests.ps1's own helper of the same shape. #>
    return 'WowFakeAppUpdateNotRunning' + (Get-Random -Maximum 99999)
}

function New-FakeWowProcess {
    <#
      Mirrors Server.WagoBrowse.Tests.ps1's own New-FakeWowProcess: a
      renamed timeout.exe, started hidden with no stdin redirect.
      -ProcessName lets a caller supply a name it ALREADY told the
      server about via -WowFakeProcessName at server startup (so "game
      running" can be flipped from false to true mid-Describe, by
      starting this process only once the false-reading phase is done)
      rather than generating a fresh one that the running server has
      never heard of.
    #>
    param([Parameter(Mandatory = $true)][string]$Root, [string]$ProcessName)
    $fakeProcName = $ProcessName
    if (-not $fakeProcName) { $fakeProcName = 'WowFakeAppUpdate' + (Get-Random -Maximum 99999) }
    $fakeExePath = Join-Path $Root ($fakeProcName + '.exe')
    Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\timeout.exe') -Destination $fakeExePath -Force
    $proc = Start-Process -FilePath $fakeExePath -ArgumentList @('/t', '900', '/nobreak') -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    return [PSCustomObject]@{ Process = $proc; ProcessName = $fakeProcName }
}

function Stop-FakeWowProcess {
    param($FakeWow)
    if (-not $FakeWow -or -not $FakeWow.Process) { return }
    try { if (-not $FakeWow.Process.HasExited) { Stop-Process -Id $FakeWow.Process.Id -Force -ErrorAction SilentlyContinue } } catch { }
}

function Start-AppUpdateTestServer {
    <#
      Starts a GitHub release stub, points $env:FURPHY_TEST_GITHUB_BASEURL
      at it BEFORE calling Start-TestServer (load-bearing ordering - see
      this file's own header), then starts the scratch addon-server.ps1
      on $Script:AppUpdatePort. -StubArgs is a hashtable splatted straight
      into Start-GitHubReleaseStubServer. -ExtraServerArgs is passed to
      Start-TestServer AS-IS with no special-casing; omit it to get the
      default "-WowFakeProcessName <a fresh, never-started name>" (game
      never reads as running) - pass your own
      @('-WowFakeProcessName', $someName) explicitly when a Describe
      needs to start a REAL process under that exact name later (see
      the WoW-running Describe below for why). Returns {Stub; Server};
      the env var is removed from THIS script's own process immediately
      after Start-TestServer returns (safe - the server already has its
      own fixed copy). Caller stops both in its own finally
      (Stop-GitHubReleaseStubServer then Stop-TestServer).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [hashtable]$StubArgs = @{},
        [string[]]$ExtraServerArgs
    )
    $stub = Start-GitHubReleaseStubServer @StubArgs
    $env:FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl
    $server = $null
    try {
        $finalArgs = $ExtraServerArgs
        if (-not $finalArgs) { $finalArgs = @('-WowFakeProcessName', (Get-NotRunningFakeWowName)) }
        $server = Start-TestServer -Root $Root -Port $Script:AppUpdatePort -ExtraArgs $finalArgs
    } finally {
        Remove-Item Env:\FURPHY_TEST_GITHUB_BASEURL -ErrorAction SilentlyContinue
    }
    return [PSCustomObject]@{ Stub = $stub; Server = $server }
}

function Wait-JobDone {
    <# Mirrors Server.Jobs.Tests.ps1's own local helper of the same name (not part of tests\lib\common.ps1) - polls a job until it leaves the 'running' state. #>
    param([int]$Port, [string]$JobId, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-Api -Port $Port -Method Get -Path "/api/jobs/$JobId"
        $last = $r
        if ($r.Ok -and $r.Body.state -ne 'running') { return $r }
        Start-Sleep -Milliseconds 150
    }
    return $last
}

function Wait-AppUpdateState {
    <# Polls GET /api/app-update/status until .state is one of -Until, or -TimeoutSec elapses. Returns the last status Body either way (Pester's own failure message reads better against the real last-seen state than a thrown timeout). #>
    param([int]$Port, [string[]]$Until, [int]$TimeoutSec = 30, [int]$PollMs = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-Api -Port $Port -Method Get -Path '/api/app-update/status'
        if ($r.Ok) {
            $last = $r.Body
            if ($Until -contains $last.state) { return $last }
        }
        Start-Sleep -Milliseconds $PollMs
    }
    return $last
}

# =====================================================================
# REFIX (this round) helpers - the stuck-"checking" dedup-lock fix adds
# three Describes below that drive Invoke-AppUpdateMaintenance directly
# via a raw "-AppUpdateOnly" child (no full HTTP server, hence no GET
# /api/app-update/status to poll - Read-AppUpdateStateFile reads
# app-update.json straight off disk instead) for the two Describes that
# are about the state machine/lock file itself, not the routes around it;
# the third Describe (the actual race) still drives the full server like
# every Describe above, since that bug only exists in the interaction
# between Handle-AppUpdateCheck and the automatic maintenance tick.
# =====================================================================

function Invoke-AppUpdateOnlyPass {
    <#
      Spawns "addon-server.ps1 -Root <Root> -AppUpdateOnly" as its own
      SYNCHRONOUS child process and waits for it to exit - the exact same
      switch/function (Invoke-AppUpdateMaintenance -Force ->
      Invoke-AppUpdateMaintenanceCore) the real server spawns on demand
      from POST /api/app-update/check (Handle-AppUpdateCheck) and,
      unforced, from its own hourly -MaintenanceOnly tick
      (Invoke-MaintenanceTick) - used here as "the next maintenance pass"
      over app-update.json for Describes that only care about this one
      pipeline's own state-machine behavior. Deliberately -AppUpdateOnly,
      not -MaintenanceOnly: the latter ALSO runs the CurseForge catalogue
      refresh and the Wago growth crawl first (both real, live network
      calls unless a caller sets up the same FURPHY_TEST_SKIP_* env vars
      Start-TestServer sets automatically for a full server) - irrelevant
      to app-update state, and a needless live-network risk for a helper
      that only exists to reach Invoke-AppUpdateMaintenance.

      $env:FURPHY_TEST_GITHUB_BASEURL is set for the duration of the spawn
      only (defaults to a guaranteed-closed loopback port, same as
      Start-TestServer's own default, unless -GitHubBaseUrl points it at a
      real local stub) and restored to its exact prior value afterward -
      same inherit-then-restore pattern this file's own header documents
      for Start-TestServer. -TimeoutSec bounds the wait (a real release
      lookup against a real local stub settles in well under a second; a
      much larger ceiling here only guards against a genuinely hung
      child).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$GitHubBaseUrl,
        [int]$TimeoutSec = 30
    )
    $originalGitHubBaseUrlEnv = $env:FURPHY_TEST_GITHUB_BASEURL
    $env:FURPHY_TEST_GITHUB_BASEURL = if ($GitHubBaseUrl) { $GitHubBaseUrl } else { 'http://127.0.0.1:1' }
    $proc = $null
    try {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script:AddonServerPath, '-Root', $Root, '-AppUpdateOnly')
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru
        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $exited) {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
            throw "Invoke-AppUpdateOnlyPass: -AppUpdateOnly child (pid $($proc.Id)) did not exit within ${TimeoutSec}s"
        }
    } finally {
        if ($null -eq $originalGitHubBaseUrlEnv) {
            Remove-Item Env:\FURPHY_TEST_GITHUB_BASEURL -ErrorAction SilentlyContinue
        } else {
            $env:FURPHY_TEST_GITHUB_BASEURL = $originalGitHubBaseUrlEnv
        }
    }
}

function Read-AppUpdateStateFile {
    <# Reads Root\app-update.json directly off disk and parses it - for
       Describes that drive the pipeline via Invoke-AppUpdateOnlyPass
       rather than a running server, so there is no GET
       /api/app-update/status to poll. Returns $null if the file does not
       exist. #>
    param([Parameter(Mandatory = $true)][string]$Root)
    $path = Join-Path $Root 'app-update.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

function Write-AppUpdateStateFile {
    <# Writes Root\app-update.json directly (bypassing Save-AppUpdateState
       entirely - there is no running server for the Describe that uses
       this) with exactly the fields in -Fields; every other field is
       simply absent, which Get-AppUpdateState's own read-merge-with-
       defaults contract (Get-DefaultAppUpdateState's own doc comment,
       addon-server.ps1) already tolerates - the same "no migration
       needed" shape every other fixture in this suite already leans on.
       Same UTF8-no-BOM encoding Save-AppUpdateState itself uses, for
       consistency.

       -BackdateMinutes, when given, sets the FILE's own LastWriteTimeUtc
       back by that many minutes right after writing it - Invoke-
       AppUpdateMaintenanceCore's stuck-checking/downloading watchdog
       (addon-server.ps1) anchors its age check on this file's own mtime,
       not on any JSON field inside it (see that function's own doc
       comment for why), so a fixture that wants to simulate "this record
       has been sitting untouched for N minutes" needs to backdate the
       file itself, not just a timestamp field within it. #>
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][hashtable]$Fields, [int]$BackdateMinutes = 0)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
    $path = Join-Path $Root 'app-update.json'
    $json = ConvertTo-Json -InputObject $Fields -Depth 5
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $json, $encoding)
    if ($BackdateMinutes -gt 0) {
        $backdated = (Get-Date).ToUniversalTime().AddMinutes(-$BackdateMinutes)
        [System.IO.File]::SetLastWriteTimeUtc($path, $backdated)
    }
}

# =====================================================================
# 1) Happy path: check finds a newer fixture release, downloads,
#    verifies, extracts -> ready, stagedPath set (section 12, items 1-2).
# =====================================================================

Describe 'App-update: happy path (check -> available -> ready)' {
    if (-not ($Script:CapCore -and $Script:CapMaintenance)) {
        It 'a good newer release ends at state=ready, latestVersion/releaseTag set, checkedAt/downloadedAt populated' {
            Write-PendingSkip 'needs APPUPD-1 (GitHubBaseUrl seam), APPUPD-2 (routes/handlers) and APPUPD-3 (Invoke-AppUpdateMaintenance)'
        }
        return
    }

    $root = New-TempRoot -Name 'appupdate-happy'
    $started = $null
    try {
        $started = Start-AppUpdateTestServer -Root $root -StubArgs @{ TagName = 'v99.0.0'; ZipEntries = @{ VERSION = '99.0.0' } }

        It 'POST /api/app-update/check is accepted (202 fresh, or 200 if the automatic startup tick is already checking/downloading) and the cycle reaches ready' {
            $check = Invoke-Api -Port $Script:AppUpdatePort -Method Post -Path '/api/app-update/check'
            @(200, 202) -contains $check.StatusCode | Should Be $true

            # NOTE ON MAX-EFFORT VS EXACT-EFFORT: this only asserts the
            # FINAL resting state, never that "available" was itself
            # observed mid-poll - a fast local stub can legitimately move
            # from checking straight through available to ready between
            # two poll ticks, and asserting an exact intermediate state
            # here would make this test flaky against nothing but its own
            # poll interval, not a real defect.
            $final = Wait-AppUpdateState -Port $Script:AppUpdatePort -Until @('ready', 'error') -TimeoutSec 30
            $final.state | Should Be 'ready'
            $final.latestVersion | Should Be '99.0.0'
            $final.releaseTag | Should Be 'v99.0.0'
            ([string]::IsNullOrEmpty($final.checkedAt)) | Should Be $false
            ([string]::IsNullOrEmpty($final.downloadedAt)) | Should Be $false
        }
    } finally {
        if ($started) {
            Stop-GitHubReleaseStubServer -Stub $started.Stub
            Stop-TestServer -Server $started.Server
        }
        # This Describe reaches state=ready, which really does extract a
        # real %TEMP%\FurphyUpdate-v99.0.0-<guid> folder (section 8.4) -
        # narrowly scoped to this Describe's own exact tag, never a blind
        # "FurphyUpdate-" sweep (see this file's own header + common.ps1's
        # Remove-AppUpdateTempLitter doc comment).
        Remove-AppUpdateTempLitter -Prefix 'FurphyUpdate-v99.0.0-' -CreatedAfterUtc $Script:LitterCutoffUtc | Out-Null
    }
}

# =====================================================================
# 2) A TAMPERED sha256 -> error, never extracted, never advances past
#    the pre-download state (section 12, item 3).
# =====================================================================

Describe 'App-update: tampered sha256 is refused before extraction' {
    if (-not ($Script:CapCore -and $Script:CapMaintenance)) {
        It 'a release whose .sha256 does not match its zip -> state=error, integrity-check lastError' {
            Write-PendingSkip 'needs APPUPD-1 (GitHubBaseUrl seam), APPUPD-2 (routes/handlers) and APPUPD-3 (Invoke-AppUpdateMaintenance)'
        }
        return
    }

    $root = New-TempRoot -Name 'appupdate-tampered-sha'
    $started = $null
    try {
        $started = Start-AppUpdateTestServer -Root $root -StubArgs @{ TagName = 'v99.0.1'; ZipEntries = @{ VERSION = '99.0.1' }; TamperSha256 = $true }

        It 'the download is discarded, never extracted; state ends in error with an integrity-check lastError' {
            $check = Invoke-Api -Port $Script:AppUpdatePort -Method Post -Path '/api/app-update/check'
            @(200, 202) -contains $check.StatusCode | Should Be $true

            $final = Wait-AppUpdateState -Port $Script:AppUpdatePort -Until @('error', 'ready') -TimeoutSec 30
            $final.state | Should Be 'error'
            $final.lastError | Should Be 'integrity check failed'
        }
    } finally {
        if ($started) {
            Stop-GitHubReleaseStubServer -Stub $started.Stub
            Stop-TestServer -Server $started.Server
        }
    }
}

# =====================================================================
# 3) A zip whose extracted VERSION does not match the release tag ->
#    error, same non-advancement (section 12, item 4).
# =====================================================================

Describe 'App-update: VERSION-vs-tag mismatch is refused after extraction' {
    if (-not ($Script:CapCore -and $Script:CapMaintenance)) {
        It 'a release whose zip VERSION does not equal its own tag -> state=error, never installs' {
            Write-PendingSkip 'needs APPUPD-1 (GitHubBaseUrl seam), APPUPD-2 (routes/handlers) and APPUPD-3 (Invoke-AppUpdateMaintenance)'
        }
        return
    }

    $root = New-TempRoot -Name 'appupdate-version-mismatch'
    $started = $null
    try {
        # Sidecar is computed from the REAL zip bytes (so the sha256 check
        # itself passes cleanly) - only the VERSION file INSIDE the zip is
        # deliberately wrong versus the v99.0.2 release tag.
        $started = Start-AppUpdateTestServer -Root $root -StubArgs @{ TagName = 'v99.0.2'; ZipEntries = @{ VERSION = '1.0.0' } }

        It 'sha256 passes, extraction happens, then the VERSION check refuses and errors' {
            $check = Invoke-Api -Port $Script:AppUpdatePort -Method Post -Path '/api/app-update/check'
            @(200, 202) -contains $check.StatusCode | Should Be $true

            $final = Wait-AppUpdateState -Port $Script:AppUpdatePort -Until @('error', 'ready') -TimeoutSec 30
            $final.state | Should Be 'error'
            $final.lastError | Should Be "downloaded package's VERSION did not match the release"
        }
    } finally {
        if ($started) {
            Stop-GitHubReleaseStubServer -Stub $started.Stub
            Stop-TestServer -Server $started.Server
        }
    }
}

# =====================================================================
# 4) POST /api/app-update/install while WoW is (fakely) running -> 409
#    (section 12, item 5).
# =====================================================================

Describe 'App-update: install refused while WoW is running' {
    if (-not ($Script:CapCore -and $Script:CapMaintenance)) {
        It 'POST /api/app-update/install -> 409 "WoW is running" when Test-GameRunning is true' {
            Write-PendingSkip 'needs APPUPD-1 (GitHubBaseUrl seam), APPUPD-2 (routes/handlers) and APPUPD-3 (Invoke-AppUpdateMaintenance)'
        }
        return
    }

    # Handle-AppUpdateInstall's real, landed order (confirmed live while
    # writing this file) checks state=="ready" FIRST (400 "nothing
    # staged" otherwise) and only reaches the job/game-running gates once
    # something genuinely is - so this Describe must stage a real ready
    # update before it can observe the WoW-running 409 at all. The fake
    # WoW process name is picked and told to the server UP FRONT (so
    # -WowFakeProcessName is fixed for the server's whole lifetime, per
    # Test-GameRunning's own design) but the process itself is started
    # only AFTER staging completes, so "game running" reads false during
    # the check/download/verify pipeline and true only for the install
    # attempt this Describe is actually about.
    # Handle-AppUpdateInstall also resolves a real WoW root
    # (Get-FlavourWowRootPath) before it ever reaches the game-running
    # check - a scratch server with no WoW root behind it 500s with
    # "Could not resolve the WoW folder for this install." instead
    # (found live while writing this file), so this Describe needs a
    # real Copy-Fixture root too.
    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'appupdate-game-running'
    $fakeName = 'WowFakeAppUpdate' + (Get-Random -Maximum 99999)
    $started = $null
    $fakeWow = $null
    try {
        $started = Start-AppUpdateTestServer -Root $root -StubArgs @{ TagName = 'v99.0.4'; ZipEntries = @{ VERSION = '99.0.4' } } -ExtraServerArgs @('-WowFakeProcessName', $fakeName, '-WowRoot', $wowRoot)
        Invoke-Api -Port $Script:AppUpdatePort -Method Post -Path '/api/app-update/check' | Out-Null
        $ready = Wait-AppUpdateState -Port $Script:AppUpdatePort -Until @('ready', 'error') -TimeoutSec 30
        $ready.state | Should Be 'ready'

        $fakeWow = New-FakeWowProcess -Root $root -ProcessName $fakeName

        It 'returns 409 with an error mentioning WoW, even though state=ready (the WoW-running gate is checked, not skipped, once staged)' {
            # Test-GameRunning caches its answer for $Script:GameProbeIntervalSeconds
            # (30, confirmed live in addon-server.ps1) - the staging phase
            # above already primed that cache to "not running" (nothing
            # named $fakeName existed yet at that point), so a call made
            # right after starting the fake process would still read the
            # STALE cached "false" and 200 instead of 409 (confirmed live
            # while writing this file - a real, once-per-30s throttle, not
            # a test bug to work around any other way). Wait past that
            # window so this call observes a genuinely fresh read.
            Start-Sleep -Seconds 31
            $r = Invoke-Api -Port $Script:AppUpdatePort -Method Post -Path '/api/app-update/install' -Body @{ relaunch = 'window' }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 409
            $r.Body.error | Should Be 'WoW is running'
        }
    } finally {
        Stop-FakeWowProcess -FakeWow $fakeWow
        if ($started) {
            Stop-GitHubReleaseStubServer -Stub $started.Stub
            Stop-TestServer -Server $started.Server
        }
        Remove-AppUpdateTempLitter -Prefix 'FurphyUpdate-v99.0.4-' -CreatedAfterUtc $Script:LitterCutoffUtc | Out-Null
    }
}

# =====================================================================
# 5) POST /api/app-update/install while an addon job is genuinely still
#    running -> 409, deferredReason=job-running on the next status poll
#    (section 12, item 6).
# =====================================================================

Describe 'App-update: install deferred while an addon job is running' -Tags 'Network' {
    if (-not ($Script:CapCore -and $Script:CapMaintenance)) {
        It 'POST /api/app-update/install -> 409 "busy: a job is running"; status.deferredReason becomes job-running' {
            Write-PendingSkip 'needs APPUPD-1 (GitHubBaseUrl seam), APPUPD-2 (routes/handlers) and APPUPD-3 (Invoke-AppUpdateMaintenance)'
        }
        return
    }

    # Same real ordering constraint as the WoW-running Describe above:
    # Handle-AppUpdateInstall checks state=="ready" before the job-running
    # gate, so a real update must be staged first via the stub.
    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'appupdate-job-running'
    $started = $null
    try {
        $started = Start-AppUpdateTestServer -Root $root -StubArgs @{ TagName = 'v99.0.5'; ZipEntries = @{ VERSION = '99.0.5' } } -ExtraServerArgs @('-WowFakeProcessName', (Get-NotRunningFakeWowName), '-WowRoot', $wowRoot)
        Invoke-Api -Port $Script:AppUpdatePort -Method Post -Path '/api/app-update/check' | Out-Null
        $ready = Wait-AppUpdateState -Port $Script:AppUpdatePort -Until @('ready', 'error') -TimeoutSec 30
        $ready.state | Should Be 'ready'

        # Same slow-job trick as Server.Jobs.Tests.ps1's "SAME flavour is
        # 409" Describe - a handful of bogus-but-numeric CurseForge
        # project ids, real fast-404 requests (never github.com), just
        # enough real network round-trips to keep a 'check' job reliably
        # running a moment later.
        $bogusIds = @(900000021, 900000022, 900000023, 900000024, 900000025)
        Invoke-CliJson -ScriptPath (Join-Path $root 'addon-sync.ps1') `
            -ArgumentList @('-Add', ($bogusIds -join ','), '-Json', '-WowRoot', $wowRoot, '-Flavor', 'retail') | Out-Null

        It 'is 409 while the job is genuinely running, and the next status poll shows deferredReason=job-running' {
            $jobStart = Invoke-Api -Port $Script:AppUpdatePort -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'check' }
            $jobStart.Ok | Should Be $true

            $jobStatus = Invoke-Api -Port $Script:AppUpdatePort -Method Get -Path "/api/jobs/$($jobStart.Body.jobId)"
            $jobStatus.Body.state | Should Be 'running'

            $install = Invoke-Api -Port $Script:AppUpdatePort -Method Post -Path '/api/app-update/install' -Body @{ relaunch = 'window' }
            $install.Ok | Should Be $false
            $install.StatusCode | Should Be 409
            $install.Body.error | Should Be 'busy: a job is running'

            $status = Invoke-Api -Port $Script:AppUpdatePort -Method Get -Path '/api/app-update/status'
            $status.Body.deferredReason | Should Be 'job-running'

            Wait-JobDone -Port $Script:AppUpdatePort -JobId $jobStart.Body.jobId -TimeoutSec 30 | Out-Null
        }
    } finally {
        if ($started) {
            Stop-GitHubReleaseStubServer -Stub $started.Stub
            Stop-TestServer -Server $started.Server
        }
        Remove-AppUpdateTempLitter -Prefix 'FurphyUpdate-v99.0.5-' -CreatedAfterUtc $Script:LitterCutoffUtc | Out-Null
    }
}

# =====================================================================
# 6) windowOpenAt: GET /api/state stamps it; plain /api/ping + /api/jobs
#    traffic (the tray's own PingUrl/JobsUrl/JobUrl pattern) never does
#    (section 7 / section 12, items 7-8).
# =====================================================================

Describe 'App-update: windowOpenAt is stamped only by GET /api/state, never by tray-style ping/jobs traffic' {
    if (-not ($Script:CapCore -and $Script:CapWindowOpenAt)) {
        It 'GET /api/state stamps windowOpenAt; GET /api/ping and GET /api/jobs never do' {
            Write-PendingSkip 'needs APPUPD-1 (GitHubBaseUrl seam), APPUPD-2 (routes/handlers) and APPUPD-4 (windowOpenAt signal)'
        }
        return
    }

    $root = New-TempRoot -Name 'appupdate-windowopen'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port $Script:AppUpdatePort -ExtraArgs @('-WowFakeProcessName', (Get-NotRunningFakeWowName))

        It 'plain ping/jobs traffic alone reads windowOpen=false' {
            Invoke-Api -Port $Script:AppUpdatePort -Method Get -Path '/api/ping' | Out-Null
            Invoke-Api -Port $Script:AppUpdatePort -Method Get -Path '/api/jobs' | Out-Null
            Invoke-Api -Port $Script:AppUpdatePort -Method Get -Path '/api/ping' | Out-Null

            $status = Invoke-Api -Port $Script:AppUpdatePort -Method Get -Path '/api/app-update/status'
            $status.Body.windowOpen | Should Be $false
        }

        It 'a single GET /api/state makes windowOpen read true immediately afterward' {
            Invoke-Api -Port $Script:AppUpdatePort -Method Get -Path '/api/state' | Out-Null
            $status = Invoke-Api -Port $Script:AppUpdatePort -Method Get -Path '/api/app-update/status'
            $status.Body.windowOpen | Should Be $true
        }
    } finally {
        Stop-TestServer -Server $server
    }
}

# =====================================================================
# 7) A window-relaunch install is never falsely 409'd by a stale/absent
#    windowOpenAt reading (section 12, item 7, restated as its own
#    positive case): stamp it via GET /api/state, reach state=ready, then
#    POST /api/app-update/install {relaunch:"window"} succeeds. Uses
#    $env:FURPHY_TEST_APPUPDATE_DRYRUN (Package A's own test-only seam,
#    confirmed live in Handle-AppUpdateInstall) so this Describe never
#    actually spawns install.ps1/relaunches anything on this machine -
#    it only proves the ROUTE itself is not falsely blocked, which is
#    all this Describe is about; the real end-to-end relaunch mechanics
#    are Package B's own file and this file's sibling
#    AppUpdate.SilentUpgrade.Tests.ps1's job, never this one's.
# =====================================================================

Describe 'App-update: a window-initiated install is not falsely blocked by the window signal' {
    if (-not ($Script:CapCore -and $Script:CapMaintenance -and $Script:CapWindowOpenAt)) {
        It 'GET /api/state once, then POST /api/app-update/install {relaunch:"window"} while state=ready -> not a 409' {
            Write-PendingSkip 'needs APPUPD-1 (GitHubBaseUrl seam), APPUPD-2 (routes/handlers), APPUPD-3 (Invoke-AppUpdateMaintenance) and APPUPD-4 (windowOpenAt signal)'
        }
        return
    }

    # Handle-AppUpdateInstall resolves a real WoW root (Get-FlavourWowRootPath)
    # before it ever reaches -Relaunch/-Upgrade construction, even under
    # the dry-run seam - a scratch server with no WoW root behind it 500s
    # with "Could not resolve the WoW folder for this install." (found
    # live while writing this file), so this Describe needs a real
    # Copy-Fixture root, same as the job-running Describe above.
    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'appupdate-window-install'
    $started = $null
    $originalDryRun = $env:FURPHY_TEST_APPUPDATE_DRYRUN
    try {
        # Set BEFORE Start-TestServer, same load-bearing ordering as
        # FURPHY_TEST_GITHUB_BASEURL above - Handle-AppUpdateInstall reads
        # this env var live at request time (it is not read at server
        # startup), so either ordering would work for THIS particular
        # var, but setting it up front keeps this Describe's own shape
        # consistent with the rest of this file and removes any doubt.
        $env:FURPHY_TEST_APPUPDATE_DRYRUN = '1'
        $started = Start-AppUpdateTestServer -Root $root -StubArgs @{ TagName = 'v99.0.3'; ZipEntries = @{ VERSION = '99.0.3' } } -ExtraServerArgs @('-WowFakeProcessName', (Get-NotRunningFakeWowName), '-WowRoot', $wowRoot)
        Invoke-Api -Port $Script:AppUpdatePort -Method Post -Path '/api/app-update/check' | Out-Null
        $ready = Wait-AppUpdateState -Port $Script:AppUpdatePort -Until @('ready', 'error') -TimeoutSec 30
        $ready.state | Should Be 'ready'

        It 'succeeds (200 ok:true) - never a false 409, because the dry-run seam never actually spawns/relaunches anything' {
            Invoke-Api -Port $Script:AppUpdatePort -Method Get -Path '/api/state' | Out-Null

            $install = Invoke-Api -Port $Script:AppUpdatePort -Method Post -Path '/api/app-update/install' -Body @{ relaunch = 'window' }
            $install.StatusCode | Should Not Be 409
            $install.Ok | Should Be $true
            $install.Body.ok | Should Be $true
        }
    } finally {
        if ($null -eq $originalDryRun) { Remove-Item Env:\FURPHY_TEST_APPUPDATE_DRYRUN -ErrorAction SilentlyContinue }
        else { $env:FURPHY_TEST_APPUPDATE_DRYRUN = $originalDryRun }
        if ($started) {
            Stop-GitHubReleaseStubServer -Stub $started.Stub
            Stop-TestServer -Server $started.Server
        }
        Remove-AppUpdateTempLitter -Prefix 'FurphyUpdate-v99.0.3-' -CreatedAfterUtc $Script:LitterCutoffUtc | Out-Null
    }
}

# =====================================================================
# 8) Rate-limit backoff (APP-UPDATE-SPEC.md section 16 Q2's resolution,
#    "add rate-limit backoff: on HTTP 403/429 honour Retry-After or
#    X-RateLimit-Reset ... before the next automatic check, no auth
#    token" - additional coverage beyond section 12's own literal list,
#    since this decision is explicitly binding for this round).
# =====================================================================

Describe 'App-update: a 403/429 from GitHub never regresses state, never throws, sets lastError' {
    if (-not ($Script:CapCore -and $Script:CapMaintenance)) {
        It 'GitHub 403 with Retry-After -> state unchanged (never regressed to available/ready), lastError mentions rate limit' {
            Write-PendingSkip 'needs APPUPD-1 (GitHubBaseUrl seam), APPUPD-2 (routes/handlers) and APPUPD-3 (Invoke-AppUpdateMaintenance)'
        }
        return
    }

    $root = New-TempRoot -Name 'appupdate-ratelimit'
    $started = $null
    try {
        $started = Start-AppUpdateTestServer -Root $root -StubArgs @{ ReleaseStatus = 403; RetryAfterSeconds = 120 }

        It 'the check ends in error/idle (never available/downloading/ready) with a rate-limit lastError, and hitting the limit does not trigger a tight retry loop' {
            $pre = (Invoke-Api -Port $Script:AppUpdatePort -Method Get -Path '/api/app-update/status').Body
            Invoke-Api -Port $Script:AppUpdatePort -Method Post -Path '/api/app-update/check' | Out-Null

            # Round 42.1: a fresh app-update.json starts out "idle", so waiting
            # for "idle" alone can return before any check has run at all
            # (the server's own startup check may still be in flight). Wait
            # for evidence that a check actually completed: a terminal
            # non-idle state, or idle with a lastError/checkedAt that moved.
            $final = $null
            $deadline = (Get-Date).AddSeconds(45)
            while ((Get-Date) -lt $deadline) {
                $r = Invoke-Api -Port $Script:AppUpdatePort -Method Get -Path '/api/app-update/status'
                if ($r.Ok) {
                    $final = $r.Body
                    if (@('error', 'available', 'ready') -contains $final.state) { break }
                    if ($final.state -eq 'idle' -and ($final.lastError -or ([string]$final.checkedAt -ne [string]$pre.checkedAt))) { break }
                }
                Start-Sleep -Milliseconds 300
            }
            @('available', 'downloading', 'ready') -contains $final.state | Should Be $false
            $final.lastError | Should Be 'GitHub rate limit reached - try again later.'

            # "Never retry in a tight loop" (section 8.1), asserted as
            # "the request count stops growing" rather than "exactly one
            # request ever" - this file's own header explains why an
            # exact count is not meaningful here (the automatic startup
            # tick and this Describe's own explicit POST both legitimately
            # race to make their own single request against the
            # always-403 stub before either settles).
            $reqs = @(Get-GitHubReleaseStubRequests -Stub $started.Stub | Where-Object { $_.path -eq '/repos/krenz444/furphy-addon-manager/releases/latest' })
            $countAfterSettling = @($reqs).Count
            $countAfterSettling | Should BeGreaterThan 0
            Start-Sleep -Seconds 3
            $reqsLater = @(Get-GitHubReleaseStubRequests -Stub $started.Stub | Where-Object { $_.path -eq '/repos/krenz444/furphy-addon-manager/releases/latest' })
            @($reqsLater).Count | Should Be $countAfterSettling
        }
    } finally {
        if ($started) {
            Stop-GitHubReleaseStubServer -Stub $started.Stub
            Stop-TestServer -Server $started.Server
        }
    }
}

# =====================================================================
# 9) REFIX (verifier pass 1, finding 4): POST /api/app-update/install
#    rejects any relaunch value other than exactly "window" or "tray"
#    with 400, rather than silently defaulting to "window" (previously
#    the RISKIER of the two real actions on unrecognized input - see
#    Handle-AppUpdateInstall's own comment). This validation runs before
#    app-update.json is even read, so unlike every Describe above, no
#    staged/ready update, no WoW root, and no GitHub stub are needed for
#    any assertion below - only APPUPD-2 (the route existing).
# =====================================================================

Describe 'App-update: POST /api/app-update/install validates relaunch strictly' {
    if (-not $Script:CapRoutes) {
        It 'a missing/invalid relaunch value is refused with 400, never defaulted to "window"' {
            Write-PendingSkip 'needs APPUPD-2 (routes/handlers)'
        }
        return
    }

    $root = New-TempRoot -Name 'appupdate-relaunch-validation'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port $Script:AppUpdatePort -ExtraArgs @('-WowFakeProcessName', (Get-NotRunningFakeWowName))

        It 'relaunch:"none" (install.ps1''s own TEST-ONLY CLI value, never a real HTTP caller) is refused with 400, not silently treated as "window"' {
            $r = Invoke-Api -Port $Script:AppUpdatePort -Method Post -Path '/api/app-update/install' -Body @{ relaunch = 'none' }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be "relaunch must be 'window' or 'tray'"
        }

        It 'a missing relaunch field is refused with 400, not silently defaulted to "window"' {
            $r = Invoke-Api -Port $Script:AppUpdatePort -Method Post -Path '/api/app-update/install' -Body @{}
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be "relaunch must be 'window' or 'tray'"
        }

        It 'a well-formed relaunch:"tray" passes validation (falls through to the state check -> 400 "nothing staged", never the relaunch 400)' {
            $r = Invoke-Api -Port $Script:AppUpdatePort -Method Post -Path '/api/app-update/install' -Body @{ relaunch = 'tray' }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be 'nothing staged to install'
        }
    } finally {
        Stop-TestServer -Server $server
    }
}

# =====================================================================
# 10) REFIX (this round, stuck-"checking" dedup-lock fix, part (a)):
#     Test-AppUpdateChildRunning must not trust a bare PID forever - a
#     lock file recording a PID that is alive but belongs to an unrelated
#     process (Windows recycling PIDs) must be treated as stale, not as
#     "still running", or the app-update pipeline is blocked from EVER
#     running again. Drives Invoke-AppUpdateMaintenance directly via a raw
#     -AppUpdateOnly child (Invoke-AppUpdateOnlyPass above) rather than
#     through a full HTTP server - this Describe is about the lock file
#     itself, not the routes around it.
# =====================================================================

Describe 'App-update: a stale lock recording a reused PID is ignored, not treated as still running' {
    if (-not ($Script:CapCore -and $Script:CapMaintenance)) {
        It 'a lock file whose PID is alive but whose recorded start time does not match it is deleted, and the check proceeds' {
            Write-PendingSkip 'needs APPUPD-1 (GitHubBaseUrl seam), APPUPD-2 (routes/handlers) and APPUPD-3 (Invoke-AppUpdateMaintenance)'
        }
        return
    }

    $root = New-TempRoot -Name 'appupdate-stale-lock-reused-pid'
    $stub = $null
    try {
        $stub = Start-GitHubReleaseStubServer -TagName 'v99.1.0' -ZipEntries @{ VERSION = '99.1.0' }

        It 'proceeds to a real, settled check instead of staying blocked by the bogus lock' {
            # Plant a lock file naming THIS TEST PROCESS's own PID -
            # genuinely alive, per the task brief's own framing, but with a
            # start-time value that deliberately does not match this
            # process's real StartTime, simulating a PID Windows has since
            # reused for an unrelated process (this test process itself
            # stands in for "unrelated" here - it is certainly not an
            # app-update child).
            $cacheDir = Join-Path $root 'cache'
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
            $lockPath = Join-Path $cacheDir 'app-update-maintenance.lock'
            $realStartTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
            $bogusStartTicks = $realStartTicks + 864000000000  # +1 day in ticks - guaranteed mismatch, still a valid positive long
            [System.IO.File]::WriteAllText($lockPath, ('{0}:{1}' -f $PID, $bogusStartTicks))

            Invoke-AppUpdateOnlyPass -Root $root -GitHubBaseUrl $stub.BaseUrl -TimeoutSec 30

            $state = Read-AppUpdateStateFile -Root $root
            $state | Should Not Be $null
            $state.state | Should Be 'ready'
            $state.latestVersion | Should Be '99.1.0'

            # The real pipeline ran through its own normal acquire/release
            # cycle (Invoke-AppUpdateMaintenance's own finally) and left no
            # lock behind - the bogus one was replaced and cleaned up, not
            # just ignored in place.
            (Test-Path -LiteralPath $lockPath) | Should Be $false
        }
    } finally {
        if ($stub) { Stop-GitHubReleaseStubServer -Stub $stub }
        Remove-AppUpdateTempLitter -Prefix 'FurphyUpdate-v99.1.0-' -CreatedAfterUtc $Script:LitterCutoffUtc | Out-Null
    }
}

# =====================================================================
# 11) REFIX (this round, stuck-"checking" dedup-lock fix, part (c)): a
#     state=checking record left over from an abandoned attempt (its
#     on-disk record untouched for a while, no live lock) must be reset
#     by the stuck-checking/downloading watchdog in
#     Invoke-AppUpdateMaintenanceCore - never silently folded back to idle
#     by the 24h-freshness gate (which would leave it retrying only once
#     every 24h with no visible explanation of what went wrong) and never
#     left sitting forever.
# =====================================================================

Describe 'App-update: a stale state=checking record with no lock is reset to error by the next maintenance pass' {
    if (-not ($Script:CapCore -and $Script:CapMaintenance)) {
        It 'a record untouched for over 10 minutes with no lock file -> state=error with the watchdogs own lastError' {
            Write-PendingSkip 'needs APPUPD-1 (GitHubBaseUrl seam), APPUPD-2 (routes/handlers) and APPUPD-3 (Invoke-AppUpdateMaintenance)'
        }
        return
    }

    $root = New-TempRoot -Name 'appupdate-stale-checking'

    It 'the watchdog fires on the very next maintenance pass, without ever reaching the network' {
        # The watchdog anchors on app-update.json's own on-disk
        # LastWriteTimeUtc, not on a `checkedAt` field inside it (see
        # Invoke-AppUpdateMaintenanceCore's own doc comment for why) - so
        # this fixture backdates the FILE itself 15 minutes, comfortably
        # past the watchdog's own 10-minute "checking" threshold.
        Write-AppUpdateStateFile -Root $root -Fields @{ state = 'checking' } -BackdateMinutes 15
        (Test-Path -LiteralPath (Join-Path $root 'cache\app-update-maintenance.lock')) | Should Be $false

        # No GitHub stub at all here, on purpose - a working watchdog never
        # reaches the release-lookup step for a record this old;
        # Invoke-AppUpdateOnlyPass's own default (a guaranteed-closed
        # loopback port) turns any regression that DOES reach the network
        # into a fast, obvious failure instead of a slow timeout.
        Invoke-AppUpdateOnlyPass -Root $root -TimeoutSec 30

        $state = Read-AppUpdateStateFile -Root $root
        $state | Should Not Be $null
        $state.state | Should Be 'error'
        $state.lastError | Should Be 'the last update check did not finish - try Check now again.'
        ([string]::IsNullOrEmpty($state.lastErrorAt)) | Should Be $false
    }
}

# =====================================================================
# 12) REFIX (this round, the race itself): a "Check now" landing within
#     about a second of a fresh server start - the exact window where the
#     server's own first, unforced -MaintenanceOnly tick is ALSO racing to
#     run Invoke-AppUpdateMaintenance (this file's own header, "A THIRD
#     consequence") - must always resolve to a settled state within a
#     reasonable time, never sit at state=checking forever. Runs the full
#     server (not the direct -AppUpdateOnly path the two Describes above
#     use), because this specific bug lives in the interaction between
#     Handle-AppUpdateCheck (section 5) and the automatic tick, which only
#     exists with a real running server.
# =====================================================================

Describe 'App-update: Check-now immediately after server start never leaves state stuck at checking' {
    if (-not ($Script:CapCore -and $Script:CapMaintenance)) {
        It 'POST /api/app-update/check right after startup settles within 60s, never stays at checking' {
            Write-PendingSkip 'needs APPUPD-1 (GitHubBaseUrl seam), APPUPD-2 (routes/handlers) and APPUPD-3 (Invoke-AppUpdateMaintenance)'
        }
        return
    }

    $root = New-TempRoot -Name 'appupdate-race'
    $started = $null
    try {
        # Start-AppUpdateTestServer already points FURPHY_TEST_GITHUB_BASEURL
        # at a real stub BEFORE Start-TestServer, per this file's own
        # header - exactly the precondition the reported race needs (the
        # server's own first maintenance tick reaches this same stub too).
        $started = Start-AppUpdateTestServer -Root $root -StubArgs @{ TagName = 'v99.1.1'; ZipEntries = @{ VERSION = '99.1.1' } }

        It 'settles to idle/available/ready/error within 60s of a Check-now fired immediately after startup' {
            $check = Invoke-Api -Port $Script:AppUpdatePort -Method Post -Path '/api/app-update/check'
            @(200, 202) -contains $check.StatusCode | Should Be $true

            $final = Wait-AppUpdateState -Port $Script:AppUpdatePort -Until @('idle', 'available', 'ready', 'error') -TimeoutSec 60
            $final | Should Not Be $null
            @('idle', 'available', 'ready', 'error') -contains $final.state | Should Be $true
        }
    } finally {
        if ($started) {
            Stop-GitHubReleaseStubServer -Stub $started.Stub
            Stop-TestServer -Server $started.Server
        }
        # This race can legitimately settle on 'ready' (a real staged
        # %TEMP%\FurphyUpdate-v99.1.1-<guid> folder) or on idle/available/
        # error (no folder at all, per this file's own header) -
        # Remove-AppUpdateTempLitter is a safe no-op when nothing matches,
        # so this always runs rather than branching on which outcome won.
        Remove-AppUpdateTempLitter -Prefix 'FurphyUpdate-v99.1.1-' -CreatedAfterUtc $Script:LitterCutoffUtc | Out-Null
    }
}

# =====================================================================
# 13/14) This round's fixer task, item 3: a stale `stagedPath` left over
#     from a prior FAILED/rolled-back install attempt (exactly this
#     round's own root-caused incident - install.ps1's own rollback write
#     is a read-merge-write of state/lastError/lastErrorAt only, per
#     Remove-AppUpdateStaleStaging's own doc comment in addon-server.ps1,
#     so the OLD `stagedPath` value and its folder both survive on disk
#     untouched by that write) must be gone - both the JSON field AND the
#     folder on disk - once the NEXT maintenance pass has actually
#     confirmed one of the two spec-named outcomes that make it safe to
#     reclaim (section 8.8): "idle" (still not newer) or "ready" (a fresh
#     newer tag supersedes it). Uses the SAME -AppUpdateOnly / direct-
#     state-file seam Describes 10/11 already use above - no HTTP server,
#     no real relaunch, nothing install.ps1-shaped at all (that mechanism
#     is this file's sibling AppUpdate.SilentUpgrade.Tests.ps1's own job,
#     never this file's, per Describe 7's own header note) - this file's
#     own version of "dry-run/none": no real subprocess relaunch, no real
#     window/tray, ever.
#
#     The synthetic "stale" folder each Describe below plants lives under
#     tests\.tmp (New-TempRoot), deliberately NEVER the real %TEMP% -
#     Remove-AppUpdateStaleStaging (addon-server.ps1) never cares which
#     directory a stagedPath value points at, and a tests\.tmp path makes
#     the "was it actually deleted" assertion unambiguous with zero risk
#     of colliding with a REAL %TEMP%\FurphyUpdate-*/FurphyRollback-*
#     folder some other process on this shared machine is concurrently
#     using (this file's own header explains the same reasoning for
#     Remove-AppUpdateTempLitter's -CreatedAfterUtc cutoff above - this
#     sidesteps the need for that guard entirely by never touching the
#     real %TEMP% for the STALE side of the fixture at all). The "ready"
#     Describe's own FRESH stagedPath, unavoidably, IS a real
#     %TEMP%\FurphyUpdate-<tag>-<guid> folder (addon-server.ps1's own
#     section 8.4 extraction target - not something a test seam can
#     redirect) - that one is removed by its own exact, just-returned
#     path in its own finally block, never a prefix sweep.
# =====================================================================

Describe 'App-update: a stale stagedPath from a prior failed install is cleared on the next check (idle outcome - still not newer)' {
    if (-not ($Script:CapCore -and $Script:CapMaintenance)) {
        It 'stagedPath is cleared to null and the leftover folder is deleted once the check confirms still-not-newer' {
            Write-PendingSkip 'needs APPUPD-1 (GitHubBaseUrl seam), APPUPD-2 (routes/handlers) and APPUPD-3 (Invoke-AppUpdateMaintenance)'
        }
        return
    }

    $root = New-TempRoot -Name 'appupdate-stale-staged-idle'
    $stub = $null
    try {
        # v0.0.1 is older than ANY reasonable running $Script:Version
        # (this scratch server has no VERSION file of its own, so it
        # falls back to addon-server.ps1's own hardcoded default - see
        # that file's own E18 comment near its bottom) - deliberately NOT
        # hardcoding that default's exact current value here, so this
        # Describe keeps working unchanged if that default is ever bumped.
        $stub = Start-GitHubReleaseStubServer -TagName 'v0.0.1' -ZipEntries @{ VERSION = '0.0.1' }

        It 'a stale stagedPath and its folder both disappear once this check confirms still-not-newer' {
            $staleFolder = New-TempRoot -Name 'appupdate-stale-staged-folder-idle'
            'stale leftover from an abandoned/rolled-back install attempt' | Set-Content -LiteralPath (Join-Path $staleFolder 'VERSION') -Encoding Ascii
            (Test-Path -LiteralPath $staleFolder -PathType Container) | Should Be $true

            Write-AppUpdateStateFile -Root $root -Fields @{ state = 'error'; stagedPath = $staleFolder; lastError = 'rolled back to 0.0.0 after post-install health check failed' }

            Invoke-AppUpdateOnlyPass -Root $root -GitHubBaseUrl $stub.BaseUrl -TimeoutSec 30

            $state = Read-AppUpdateStateFile -Root $root
            $state | Should Not Be $null
            $state.state | Should Be 'idle'
            ([string]::IsNullOrEmpty([string]$state.stagedPath)) | Should Be $true
            (Test-Path -LiteralPath $staleFolder) | Should Be $false
        }
    } finally {
        if ($stub) { Stop-GitHubReleaseStubServer -Stub $stub }
    }
}

Describe 'App-update: a stale stagedPath from a prior failed install is cleared when a fresh newer release supersedes it (ready outcome)' {
    if (-not ($Script:CapCore -and $Script:CapMaintenance)) {
        It 'the OLD stale folder is deleted; stagedPath now points at the FRESH staged release' {
            Write-PendingSkip 'needs APPUPD-1 (GitHubBaseUrl seam), APPUPD-2 (routes/handlers) and APPUPD-3 (Invoke-AppUpdateMaintenance)'
        }
        return
    }

    $root = New-TempRoot -Name 'appupdate-stale-staged-ready'
    $stub = $null
    # $script: (never a bare local $newStagedPath) - REQUIRED, found live
    # while verifying this file: Pester's own It scriptblock runs in its
    # OWN child scope, so a plain `$newStagedPath = ...` assignment made
    # INSIDE the It below stays local to that It and is never visible to
    # this Describe's own `finally` (which runs OUTSIDE any It) - the
    # `finally` block's own read of a bare $newStagedPath silently saw
    # $null every time, and its cleanup never ran, leaving a real
    # %TEMP%\FurphyUpdate-v99.2.0-<guid> folder behind on every run (found
    # live via leftover folders after this file's own Pester runs -
    # exactly the class of litter task item 1 exists to catch). $script:
    # is this file's own script scope (Pester creates one script scope per
    # file, not per Describe/It - the same scope every other $Script:
    # variable in this file already uses), reachable for both read and
    # write from inside the It below AND from this finally block outside
    # it.
    $Script:newStagedPath = $null
    try {
        $stub = Start-GitHubReleaseStubServer -TagName 'v99.2.0' -ZipEntries @{ VERSION = '99.2.0' }

        It 'the old stale folder is gone; app-update.json''s stagedPath now points at the new one, which DOES exist' {
            $staleFolder = New-TempRoot -Name 'appupdate-stale-staged-folder-ready'
            'stale leftover from an abandoned/rolled-back install attempt' | Set-Content -LiteralPath (Join-Path $staleFolder 'VERSION') -Encoding Ascii
            (Test-Path -LiteralPath $staleFolder -PathType Container) | Should Be $true

            Write-AppUpdateStateFile -Root $root -Fields @{ state = 'error'; stagedPath = $staleFolder; lastError = 'rolled back to 0.0.0 after post-install health check failed' }

            Invoke-AppUpdateOnlyPass -Root $root -GitHubBaseUrl $stub.BaseUrl -TimeoutSec 30

            $state = Read-AppUpdateStateFile -Root $root
            $state | Should Not Be $null
            $state.state | Should Be 'ready'
            $state.latestVersion | Should Be '99.2.0'
            ([string]::IsNullOrEmpty([string]$state.stagedPath)) | Should Be $false
            ([string]$state.stagedPath) | Should Not Be $staleFolder
            $Script:newStagedPath = [string]$state.stagedPath
            (Test-Path -LiteralPath $staleFolder) | Should Be $false
            (Test-Path -LiteralPath $Script:newStagedPath -PathType Container) | Should Be $true
        }
    } finally {
        if ($stub) { Stop-GitHubReleaseStubServer -Stub $stub }
        # The FRESH stagedPath this outcome creates is a real
        # %TEMP%\FurphyUpdate-v99.2.0-<guid> folder (addon-server.ps1's
        # own section 8.4 extraction, not something this test seam
        # redirects) - removed here by its own exact, just-asserted path,
        # never a prefix sweep, so this can never touch anything this
        # Describe did not itself just create.
        if ($Script:newStagedPath -and (Test-Path -LiteralPath $Script:newStagedPath)) {
            Remove-Item -LiteralPath $Script:newStagedPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Remove-TempRoots
