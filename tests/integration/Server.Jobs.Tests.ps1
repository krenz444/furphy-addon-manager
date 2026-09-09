<#
=====================================================================
 tests\integration\Server.Jobs.Tests.ps1

 POST /api/jobs validation, argv-safety for a value containing a space,
 per-flavour job concurrency (409 same flavour / 202 different flavours),
 job-status view shape (progress field present), and GET /api/jobs/{id}
 never 404ing for a job that is still current.

 =====================================================================
 kind=adopt (Round 46, ADOPT-SPEC.md app-side opt-in / Eric 2026-09-09
 follow-up): the SPA's own Settings "Folders Furphy isn't managing yet"
 section and first-run Welcome dialog stop re-downloading addons to
 establish a record (the old kind=add-based "Take over" flow) and
 instead adopt them IN PLACE, exactly like install.ps1's own first-run
 step already does via addon-sync.ps1's -Adopt (ADOPT-SPEC.md section 2,
 already shipped and covered by tests\unit\Cli.Adopt.Tests.ps1 - this
 file only covers the server-side job kind that fronts it for the
 running app).

 CONTRACT (confirmed live against the Round 46 Handle-JobsPost/
 Build-CliArgs/Update-JobStatus/Get-JobStatusView implementation -
 addon-server.ps1:2466-2486, 7444-7481, 4121-4148, 4228-4233):

   POST /api/jobs?flavour=<f>
   { "kind": "adopt", "folders": ["<name1>", "<name2>", ...] }
   -- always a plural array, even for the per-row "Manage" button's
      single-name case; there is no singular "folder" shape. --

   Maps to addon-sync.ps1's own `-Adopt <comma-joined folder names>` (one
   argv token, same argv-binding-safety reasoning as every other multi-
   value case in Build-CliArgs) - config-only/network-free, so it joins
   'remove's un-progress-tracked single-phase path. `Job.results` is
   -Adopt -Json's own `.results` rows verbatim (status/name/version/
   projectId/fileId/wagoSlug/folders/reason - ADOPT-SPEC.md section 2.8).
   On TOP of that, a finished 'adopt' job's status view carries three
   more fields (Get-JobStatusView, $null/safe-NoteProperty-read for every
   OTHER kind, exactly like .progress/.choices):
     - adoptedCount: int, count of Adopted rows
     - adopted:      [{name, folders}], one entry per newly-adopted group
     - leftAlone:    [string], every folder name from every NON-Adopted
                      row (no recognizable id, already tracked, id not
                      usable - -Adopt's own "skip, never abort the batch"
                      contract, ADOPT-SPEC.md section 2.3), flattened to
                      one entry per folder rather than grouped by row.

   Before ever touching the CLI, Handle-JobsPost 400s on:
     - `folders` missing, not present, or an empty array
         -> { error: 'bad request: folders required' }
     - any given name containing a path separator (\ or /) or ".." or
       blank - defense-in-depth against Join-Path escaping AddonsPath,
       the same shape guard Resolve-RequestFlavour already applies to
       ?flavour=
         -> { error: 'bad request: invalid folder name' }
     - a syntactically-clean name whose resolved path escapes the
       flavour's own AddOns folder (containment check, not just
       syntactic)
         -> { error: 'bad request: invalid folder path' }
     - a name that does not exist under the AddOns folder RIGHT NOW
       (unlike the bare CLI's own -Adopt, which Skips a missing folder
       gracefully - ADOPT-SPEC.md section 2.3 - the HTTP layer 400s it
       before a job is ever created at all, since the SPA is always
       acting on a scan result it just displayed)
         -> { error: "bad request: folder not found: <name>" }

   Same CSRF/Origin gate as every other state-changing endpoint (generic,
   router-level, already true regardless of kind - see
   Server.Security.Tests.ps1's own new coverage) and the same generic
   ?flavour= resolution as every other kind (also router-level - an
   unrecognized/not-installed flavour 400s in Resolve-RequestFlavour
   BEFORE Handle-JobsPost's own kind switch ever runs).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Wait-JobDone {
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

Describe 'POST /api/jobs - basic validation' {
    $root = New-TempRoot -Name 'jobs-validation'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port 47899

        It 'an unknown kind is 400' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs' -Body @{ kind = 'not-a-real-kind' }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
        }

        It 'missing kind entirely is 400' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs' -Body @{}
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
        }

        It 'kind=install missing fileId is 400' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs' -Body @{ kind = 'install'; projectId = 12345 }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
        }

        It 'kind=rollback missing projectId is 400' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs' -Body @{ kind = 'rollback' }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
        }
    } finally {
        Stop-TestServer -Server $server
    }
}

Describe 'a projectId containing a space survives as ONE argv token and fails cleanly citing it' {
    # Needs a resolvable AddonsPath (-WowRoot) so the CLI gets far enough to
    # reach its own -Add argument classifier - without one it exits 2 for an
    # entirely different, earlier reason ("AddonsPath was not specified"),
    # never touching the code this Describe is actually testing.
    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'jobs-space-id'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot

        It 'kind=add projectId="123 456" reaches the CLI as one token and the job fails, citing the whole string' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs' -Body @{ kind = 'add'; projectId = '123 456' }
            $r.Ok | Should Be $true
            $r.StatusCode | Should Be 202
            $jobId = $r.Body.jobId
            $done = Wait-JobDone -Port 47899 -JobId $jobId -TimeoutSec 30
            $done.Ok | Should Be $true
            $done.Body.state | Should Be 'failed'
            $done.Body.exitCode | Should Be 2
            # the descriptive "-Add value '123 456' is not a valid ..." message
            # is Write-Log'd to sync.log BEFORE the CLI exits, and
            # Update-JobStatus's one final tail (taken on the very poll that
            # discovers the process has exited) captures it into job.log - see
            # notesForNext for why job.error itself does NOT carry this text.
            $logText = ($done.Body.log -join "`n")
            ($logText -like '*123 456*') | Should Be $true
        }
    } finally {
        Stop-TestServer -Server $server
    }
}

Describe 'per-flavour job concurrency: SAME flavour is 409' -Tags 'Network' {
    # Review fix: this Describe used to run its "second request while the
    # first is running" check against a zero-tracked-addon 'check' job -
    # exactly the kind of job the sibling Describe in
    # Server.FreshnessAndFlavours.Tests.ps1 documents as finishing "almost
    # instantly" for the identical reason (nothing to iterate). The old It
    # only asserted the 409 shape INSIDE `if (-not $r2.Ok)`, so a race where
    # the first job finished before the second POST landed made the whole
    # It pass having observed a fresh 202 and NEVER exercised
    # Test-JobBusy's per-flavour busy-scoping at all - a real, confirmed gap
    # (not hypothetical: the plausibility is exactly why the freshness
    # Describe had to add the same slow-job trick for its own, unrelated
    # assertion). Fixed the same way that sibling Describe fixes it: seed a
    # few nonexistent-but-numeric CurseForge project ids via -Add first (a
    # handful of real, fast-404 network requests, each still subject to
    # addon-sync.ps1's own unconditional 300ms post-request pacing), so the
    # 'check' job this Describe starts is reliably still running when the
    # second POST lands - and now HARD-asserts the 409 is actually observed
    # rather than accepting a fresh 202 as a silent pass.
    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'jobs-concurrency-same-flavour'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot

        $bogusIds = @(900000011, 900000012, 900000013, 900000014, 900000015)
        Invoke-CliJson -ScriptPath (Join-Path $root 'addon-sync.ps1') `
            -ArgumentList @('-Add', ($bogusIds -join ','), '-Json', '-WowRoot', $wowRoot, '-Flavor', 'retail') | Out-Null
        # (every id is expected to report Failed on add - fine, not asserted
        # on here; it only needs the records to EXIST in addons.json so the
        # 'check' job below actually iterates them instead of finishing with
        # nothing to do.)

        It 'a second sync/check job for the SAME flavour while one is genuinely still running is 409, not a fresh 202' {
            $r1 = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'check' }
            $r1.Ok | Should Be $true

            # Confirm the first job is actually still running before firing
            # the second request - without this, a slow first POST/response
            # round-trip could still let the check job finish first even
            # with slow-network bogus ids, silently reintroducing the exact
            # race this rewrite exists to close.
            $g1 = Invoke-Api -Port 47899 -Method Get -Path "/api/jobs/$($r1.Body.jobId)"
            $g1.Body.state | Should Be 'running'

            $r2 = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'check' }
            # A fresh 202 here would mean the busy-scoping guard was never
            # exercised at all - that is a hard failure now, not an
            # accepted alternative outcome.
            $r2.Ok | Should Be $false
            $r2.StatusCode | Should Be 409
            $r2.Body.jobId | Should Be $r1.Body.jobId

            Wait-JobDone -Port 47899 -JobId $r1.Body.jobId -TimeoutSec 30 | Out-Null
        }
    } finally {
        Stop-TestServer -Server $server
    }
}

Describe 'per-flavour job concurrency: other shapes' {
    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'jobs-concurrency'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot

        It 'GET /api/jobs/{id} never 404s for a job that was just started' {
            $r1 = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=classic_era' -Body @{ kind = 'check' }
            $r1.Ok | Should Be $true
            $g = Invoke-Api -Port 47899 -Method Get -Path "/api/jobs/$($r1.Body.jobId)"
            $g.StatusCode | Should Not Be 404
            Wait-JobDone -Port 47899 -JobId $r1.Body.jobId -TimeoutSec 30 | Out-Null
        }

        It 'the job-status view carries a "progress" property (present even when null)' {
            $r1 = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=classic' -Body @{ kind = 'check' }
            $r1.Ok | Should Be $true
            $g = Invoke-Api -Port 47899 -Method Get -Path "/api/jobs/$($r1.Body.jobId)"
            ($g.Body.PSObject.Properties.Name -contains 'progress') | Should Be $true
            Wait-JobDone -Port 47899 -JobId $r1.Body.jobId -TimeoutSec 30 | Out-Null
        }

        It 'two DIFFERENT flavours may run a job concurrently (per-flavour busy scoping)' {
            $rA = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'check' }
            $rA.Ok | Should Be $true
            $rB = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=classic_era' -Body @{ kind = 'check' }
            $rB.Ok | Should Be $true
            $rA.Body.jobId | Should Not Be $rB.Body.jobId
            Wait-JobDone -Port 47899 -JobId $rA.Body.jobId -TimeoutSec 30 | Out-Null
            Wait-JobDone -Port 47899 -JobId $rB.Body.jobId -TimeoutSec 30 | Out-Null
        }
    } finally {
        Stop-TestServer -Server $server
    }
}

# =====================================================================
# GAME-MODE-SPEC.md (2026-09-08) section 8, new-coverage item 4: the
# net-new job.reloadNeeded/gameRunningAtStart pair (section 4.1). No
# existing test covered this either way - net-new coverage, not an
# inversion. gameRunningAtStart is captured once, at job-creation time,
# from Test-GameRunning; reloadNeeded (Get-JobStatusView) is true only
# when gameRunningAtStart was true AND at least one result row is
# Installed/Updated/Rolled-back (never Pinned/Unpinned/Ignored/
# Unignored/Removed/Would-update/Up-to-date/Failed/Skipped).
# =====================================================================

Describe 'job.reloadNeeded / gameRunningAtStart' -Tags 'Network' {
    <#
      A real network -Add against a real CurseForge project (id 2382,
      BigWigs - retail-compatible, already used elsewhere in this suite
      for the same reason, e.g. tests\host\Host.Tests.ps1's single-
      flavour tooltip Describes) is the simplest way to reach a genuine
      'Installed' result row without a live-network-unsafe fixture hack.
    #>
    function New-FakeWowProcessForJobsReloadTest {
        param([Parameter(Mandatory = $true)][string]$Root)
        $fakeProcName = 'WowFakeJobsReload' + (Get-Random -Maximum 99999)
        $fakeExePath = Join-Path $Root ($fakeProcName + '.exe')
        Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\timeout.exe') -Destination $fakeExePath -Force
        $proc = Start-Process -FilePath $fakeExePath -ArgumentList @('/t', '120', '/nobreak') -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 500
        return [PSCustomObject]@{ Process = $proc; ProcessName = $fakeProcName }
    }
    function Stop-FakeWowProcessForJobsReloadTest {
        param($FakeWow)
        if (-not $FakeWow -or -not $FakeWow.Process) { return }
        try { if (-not $FakeWow.Process.HasExited) { Stop-Process -Id $FakeWow.Process.Id -Force -ErrorAction SilentlyContinue } } catch { }
    }

    $projectId = 2382 # BigWigs

    It 'an add job that genuinely installs, started while GameRunning is true, reports reloadNeeded:true' {
        $wowRoot = Copy-Fixture
        $root = New-TempRoot -Name 'jobs-reload-installed-gamerunning'
        $server = $null
        $fakeWow = $null
        try {
            $fakeWow = New-FakeWowProcessForJobsReloadTest -Root $root
            $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', $fakeWow.ProcessName)

            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'add'; projectId = $projectId }
            $r.Ok | Should Be $true
            $done = Wait-JobDone -Port 47899 -JobId $r.Body.jobId -TimeoutSec 90
            $done.Ok | Should Be $true
            $done.Body.state | Should Be 'done'
            $installedRow = @($done.Body.results) | Where-Object { [string]$_.projectId -eq [string]$projectId }
            @($installedRow).Count | Should Be 1
            $installedRow[0].status | Should Be 'Installed'

            $done.Body.reloadNeeded | Should Be $true
        } finally {
            Stop-FakeWowProcessForJobsReloadTest -FakeWow $fakeWow
            Stop-TestServer -Server $server
        }
    }

    It 'a check-only job started while GameRunning is true reports reloadNeeded:false (no Installed/Updated/Rolled-back rows to trigger it)' {
        $wowRoot = Copy-Fixture
        $root = New-TempRoot -Name 'jobs-reload-checkonly-gamerunning'
        $server = $null
        $fakeWow = $null
        try {
            $fakeWow = New-FakeWowProcessForJobsReloadTest -Root $root
            $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', $fakeWow.ProcessName)

            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'check' }
            $r.Ok | Should Be $true
            $done = Wait-JobDone -Port 47899 -JobId $r.Body.jobId -TimeoutSec 30
            $done.Ok | Should Be $true
            $done.Body.reloadNeeded | Should Be $false
        } finally {
            Stop-FakeWowProcessForJobsReloadTest -FakeWow $fakeWow
            Stop-TestServer -Server $server
        }
    }

    It 'an add job that genuinely installs, started while GameRunning is FALSE, reports reloadNeeded:false even though a file was written' {
        $wowRoot = Copy-Fixture
        $root = New-TempRoot -Name 'jobs-reload-installed-notrunning'
        $server = $null
        try {
            $notRunningName = 'WowFakeJobsReloadNotRunning' + (Get-Random -Maximum 99999)
            $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', $notRunningName)

            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'add'; projectId = $projectId }
            $r.Ok | Should Be $true
            $done = Wait-JobDone -Port 47899 -JobId $r.Body.jobId -TimeoutSec 90
            $done.Ok | Should Be $true
            $installedRow = @($done.Body.results) | Where-Object { [string]$_.projectId -eq [string]$projectId }
            @($installedRow).Count | Should Be 1
            $installedRow[0].status | Should Be 'Installed'

            $done.Body.reloadNeeded | Should Be $false
        } finally {
            Stop-TestServer -Server $server
        }
    }
}

# =====================================================================
# GAME-MODE-SPEC.md (2026-09-08) section 8, new-coverage item 7 - a real
# bug closed by the same spec's section 4.1: Load-CheckState's job-
# reconstruction loop never restored gameRunningAtStart, so EVERY job
# that survived a server restart silently reported reloadNeeded:false
# from then on via GET /api/jobs*, /api/state.job, and every later
# Save-CheckState re-derivation - even one that genuinely updated an
# addon while WoW was running.
# =====================================================================

Describe 'gameRunningAtStart / reloadNeeded survive a server restart (Load-CheckState round-trip)' -Tags 'Network' {
    function New-FakeWowProcessForRestartTest {
        param([Parameter(Mandatory = $true)][string]$Root)
        $fakeProcName = 'WowFakeRestartReload' + (Get-Random -Maximum 99999)
        $fakeExePath = Join-Path $Root ($fakeProcName + '.exe')
        Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\timeout.exe') -Destination $fakeExePath -Force
        $proc = Start-Process -FilePath $fakeExePath -ArgumentList @('/t', '180', '/nobreak') -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 500
        return [PSCustomObject]@{ Process = $proc; ProcessName = $fakeProcName }
    }
    function Stop-FakeWowProcessForRestartTest {
        param($FakeWow)
        if (-not $FakeWow -or -not $FakeWow.Process) { return }
        try { if (-not $FakeWow.Process.HasExited) { Stop-Process -Id $FakeWow.Process.Id -Force -ErrorAction SilentlyContinue } } catch { }
    }

    $projectId = 2382 # BigWigs

    It 'a job that reported reloadNeeded:true still reports it after the server restarts against the same state.json' {
        $wowRoot = Copy-Fixture
        $root = New-TempRoot -Name 'jobs-reload-restart'
        $server1 = $null
        $server2 = $null
        $fakeWow = $null
        try {
            $fakeWow = New-FakeWowProcessForRestartTest -Root $root
            $server1 = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', $fakeWow.ProcessName)

            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'add'; projectId = $projectId }
            $r.Ok | Should Be $true
            $jobId = $r.Body.jobId
            $done = Wait-JobDone -Port 47899 -JobId $jobId -TimeoutSec 90
            $done.Ok | Should Be $true
            $done.Body.reloadNeeded | Should Be $true

            # Apply-JobCompletionSideEffects' own Save-CheckState call runs
            # synchronously as part of completing the job, so state.json
            # should already carry it - belt-and-suspenders poll rather
            # than assume zero latency before stopping this server.
            $statePath = Join-Path $root 'state.json'
            $deadline = (Get-Date).AddSeconds(10)
            $sawJob = $false
            while ((Get-Date) -lt $deadline) {
                if (Test-Path -LiteralPath $statePath) {
                    $onDisk = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if (@($onDisk.jobs | Where-Object { [string]$_.id -eq [string]$jobId }).Count -gt 0) { $sawJob = $true; break }
                }
                Start-Sleep -Milliseconds 200
            }
            $sawJob | Should Be $true

            Stop-TestServer -Server $server1
            $server1 = $null

            # Restart against the SAME root/state.json - the fake WoW
            # process is still alive (irrelevant to this job's own
            # ALREADY-CAPTURED gameRunningAtStart, which must not be
            # re-derived from the current moment on reload).
            $server2 = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', $fakeWow.ProcessName)
            $g = Invoke-Api -Port 47899 -Method Get -Path "/api/jobs/$jobId"
            $g.Ok | Should Be $true
            $g.Body.reloadNeeded | Should Be $true
        } finally {
            Stop-FakeWowProcessForRestartTest -FakeWow $fakeWow
            if ($server1) { Stop-TestServer -Server $server1 }
            if ($server2) { Stop-TestServer -Server $server2 }
        }
    }

    It 'a job persisted by code from before this round (no gameRunningAtStart key in state.json) reloads with reloadNeeded:false, not an error' {
        $wowRoot = Copy-Fixture
        $root = New-TempRoot -Name 'jobs-reload-restart-precompat'
        $server = $null
        try {
            # Hand-craft a pre-this-round state.json: a job whose row
            # WOULD trigger reloadNeeded:true (an Installed result) IF
            # gameRunningAtStart were present - it deliberately is not,
            # simulating a job persisted by the server build that shipped
            # before this field existed ([bool]$null is $false, never an
            # error - the exact back-compat behavior section 4.1 names).
            $stateFixture = [PSCustomObject]@{
                updatesCheckedAt = @{}
                updateAvailable  = @{}
                lastRun          = @{}
                jobs             = @(
                    [PSCustomObject]@{
                        id         = '1'
                        kind       = 'add'
                        params     = $null
                        state      = 'done'
                        startedAt  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                        finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                        exitCode   = 0
                        log        = @()
                        results    = @([PSCustomObject]@{ projectId = 999; name = 'Old Addon'; status = 'Installed' })
                        error      = $null
                        flavour    = 'retail'
                        # gameRunningAtStart deliberately absent.
                    }
                )
            }
            ($stateFixture | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $root 'state.json') -Encoding UTF8

            $notRunningName = 'WowFakeRestartReloadNotRunning' + (Get-Random -Maximum 99999)
            $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot -ExtraArgs @('-WowFakeProcessName', $notRunningName)
            $g = Invoke-Api -Port 47899 -Method Get -Path '/api/jobs/1'
            $g.Ok | Should Be $true
            $g.Body.reloadNeeded | Should Be $false
        } finally {
            Stop-TestServer -Server $server
        }
    }
}

# =====================================================================
# kind=adopt (Round 46, ADOPT-SPEC.md app-side opt-in) - see this file's
# own header comment for the confirmed request/result contract.
# =====================================================================

function New-AdoptJobWowRoot {
    <#
      A throwaway _retail_-only WoW root with three untracked top-level
      AddOns folders, entirely offline (no CurseForge/Wago traffic - the
      CLI's own -Adopt never makes one, ADOPT-SPEC.md section 2.3.1):
        - AdoptJobCfAddon    (a real X-Curse-Project-ID)
        - AdoptJobWagoAddon  (a real X-Wago-ID, no CurseForge id)
        - AdoptJobMysteryAddon (neither id - stays "left alone")
      Same minimal shape as Install.AdoptTestRealms.Tests.ps1's own
      New-PtrAdoptWowRoot (only Interface\AddOns needs to exist for
      Get-InstalledFlavours to count a flavour as installed - no Wow.exe
      needed).
    #>
    $rootPath = Join-Path $env:TEMP ('furphy-adoptjob-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $addonsPath = Join-Path $rootPath '_retail_\Interface\AddOns'
    New-Item -ItemType Directory -Path $addonsPath -Force | Out-Null

    $cfDir = Join-Path $addonsPath 'AdoptJobCfAddon'
    New-Item -ItemType Directory -Path $cfDir -Force | Out-Null
    @'
## Interface: 120100
## Title: Adopt Job Cf Addon
## Version: 3.1.0
## X-Curse-Project-ID: 700101
'@ | Set-Content -LiteralPath (Join-Path $cfDir 'AdoptJobCfAddon.toc') -Encoding Ascii

    $wagoDir = Join-Path $addonsPath 'AdoptJobWagoAddon'
    New-Item -ItemType Directory -Path $wagoDir -Force | Out-Null
    @'
## Interface: 120100
## Title: Adopt Job Wago Addon
## Version: 1.2.0
## X-Wago-ID: adopt-job-wago-slug
'@ | Set-Content -LiteralPath (Join-Path $wagoDir 'AdoptJobWagoAddon.toc') -Encoding Ascii

    $mysteryDir = Join-Path $addonsPath 'AdoptJobMysteryAddon'
    New-Item -ItemType Directory -Path $mysteryDir -Force | Out-Null
    @'
## Interface: 120100
## Title: Adopt Job Mystery Addon
## Version: 1.0.0
'@ | Set-Content -LiteralPath (Join-Path $mysteryDir 'AdoptJobMysteryAddon.toc') -Encoding Ascii

    return $rootPath
}

Describe 'POST /api/jobs kind=adopt - happy path and results shape' {
    $wowRoot = New-AdoptJobWowRoot
    $root = New-TempRoot -Name 'jobs-adopt-happy'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot

        It 'two recognizable folders (one CurseForge, one Wago) are Adopted in one job, addons.json gets adopted:true records, and the AddOns tree is byte-for-byte unchanged (no download)' {
            $addonsPath = Join-Path $wowRoot '_retail_\Interface\AddOns'
            $before = Get-TreeFingerprint -Path $addonsPath

            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{
                kind    = 'adopt'
                folders = @('AdoptJobCfAddon', 'AdoptJobWagoAddon')
            }
            $r.Ok | Should Be $true
            $r.StatusCode | Should Be 202

            $done = Wait-JobDone -Port 47899 -JobId $r.Body.jobId -TimeoutSec 30
            $done.Ok | Should Be $true
            $done.Body.state | Should Be 'done'
            $done.Body.kind | Should Be 'adopt'

            # The Round 46 summary fields the SPA's job panel actually
            # reads (addon-server.ps1:4121-4148/4228-4233) - not just the
            # raw CLI results rows underneath them.
            $done.Body.adoptedCount | Should Be 2
            $adoptedNames = @($done.Body.adopted | ForEach-Object { $_.name }) | Sort-Object
            $adoptedNames | Should Be (@('Adopt Job Cf Addon', 'Adopt Job Wago Addon') | Sort-Object)
            @($done.Body.leftAlone) | Should BeNullOrEmpty

            $cfAdopted = @($done.Body.adopted | Where-Object { $_.name -eq 'Adopt Job Cf Addon' })
            @($cfAdopted).Count | Should Be 1
            @($cfAdopted[0].folders) | Should Be @('AdoptJobCfAddon')

            # The raw CLI rows are still there underneath (job.results,
            # untouched pass-through of -Adopt -Json's own .results).
            $rows = @($done.Body.results)
            $cfRow = @($rows | Where-Object { @($_.folders) -contains 'AdoptJobCfAddon' })
            @($cfRow).Count | Should Be 1
            $cfRow[0].status | Should Be 'Adopted'
            ($null -eq $cfRow[0].fileId -or $cfRow[0].fileId -eq '') | Should Be $true

            $wagoRow = @($rows | Where-Object { @($_.folders) -contains 'AdoptJobWagoAddon' })
            @($wagoRow).Count | Should Be 1
            $wagoRow[0].status | Should Be 'Adopted'
            [string]$wagoRow[0].wagoSlug | Should Be 'adopt-job-wago-slug'

            # On-disk record check - real adopted:true records, not just the
            # transient -Json results row (mirrors Cli.Adopt.Tests.ps1's own
            # "the on-disk record is really adopted=true" assertion).
            $records = Read-JsonRecordsFile -Path (Join-Path $root 'flavours\retail\addons.json')
            $cfRecord = @($records | Where-Object { [string]$_.projectId -eq '700101' })
            @($cfRecord).Count | Should Be 1
            $cfRecord[0].adopted | Should Be $true
            ([string]::IsNullOrWhiteSpace($cfRecord[0].adoptedAt)) | Should Be $false
            ($null -eq $cfRecord[0].fileId -or $cfRecord[0].fileId -eq '') | Should Be $true

            $wagoRecord = @($records | Where-Object { [string]$_.slug -eq 'adopt-job-wago-slug' })
            @($wagoRecord).Count | Should Be 1
            $wagoRecord[0].adopted | Should Be $true

            # The whole point of adopting rather than "taking over": nothing
            # under the AddOns folder was downloaded, moved, or overwritten.
            $after = Get-TreeFingerprint -Path $addonsPath
            (Compare-Object -ReferenceObject $before -DifferenceObject $after) | Should BeNullOrEmpty
        }

        It 'a folder with no recognizable source in the batch ends up in leftAlone, not an error, and does not block the recognizable one' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{
                kind    = 'adopt'
                folders = @('AdoptJobMysteryAddon')
            }
            $r.Ok | Should Be $true
            $r.StatusCode | Should Be 202

            $done = Wait-JobDone -Port 47899 -JobId $r.Body.jobId -TimeoutSec 30
            $done.Ok | Should Be $true
            # Never a failed job just because one folder had nothing to
            # recognize - matches -Adopt's own always-exit-0 contract
            # (Cli.Adopt.Tests.ps1's "a folder with neither id is skipped,
            # not adopted").
            $done.Body.state | Should Be 'done'
            $done.Body.adoptedCount | Should Be 0
            @($done.Body.adopted) | Should BeNullOrEmpty
            @($done.Body.leftAlone) | Should Be @('AdoptJobMysteryAddon')

            $row = @($done.Body.results | Where-Object { @($_.folders) -contains 'AdoptJobMysteryAddon' })
            @($row).Count | Should Be 1
            $row[0].status | Should Be 'Skipped'
            ([string]$row[0].reason) | Should Match '(?i)no recognizable'

            $records = Read-JsonRecordsFile -Path (Join-Path $root 'flavours\retail\addons.json')
            @($records | Where-Object { $_.name -eq 'Adopt Job Mystery Addon' }).Count | Should Be 0
        }

        It 're-adopting an already-tracked folder is a graceful leftAlone entry, never an error (idempotent re-run)' {
            # AdoptJobCfAddon was already adopted by the first It above.
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{
                kind    = 'adopt'
                folders = @('AdoptJobCfAddon')
            }
            $r.Ok | Should Be $true
            $r.StatusCode | Should Be 202
            $done = Wait-JobDone -Port 47899 -JobId $r.Body.jobId -TimeoutSec 30
            $done.Ok | Should Be $true
            $done.Body.state | Should Be 'done'
            $done.Body.adoptedCount | Should Be 0
            @($done.Body.leftAlone) | Should Be @('AdoptJobCfAddon')

            $row = @($done.Body.results | Where-Object { @($_.folders) -contains 'AdoptJobCfAddon' })
            @($row).Count | Should Be 1
            $row[0].status | Should Be 'Skipped'
            ([string]$row[0].reason) | Should Match '(?i)already tracked'

            # Still exactly one record for that project id - no duplicate.
            $records = Read-JsonRecordsFile -Path (Join-Path $root 'flavours\retail\addons.json')
            @($records | Where-Object { [string]$_.projectId -eq '700101' }).Count | Should Be 1
        }
    } finally {
        Stop-TestServer -Server $server
        if ($wowRoot -and (Test-Path -LiteralPath $wowRoot)) { Remove-Item -LiteralPath $wowRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'POST /api/jobs kind=adopt - request validation' {
    $wowRoot = New-AdoptJobWowRoot
    $root = New-TempRoot -Name 'jobs-adopt-validation'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot

        It '"folders" missing entirely is 400 ("folders required")' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'adopt' }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be 'bad request: folders required'
        }

        It '"folders": [] (empty array) is 400 ("folders required")' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'adopt'; folders = @() }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be 'bad request: folders required'
        }

        It 'a folder name containing a backslash is rejected 400 ("invalid folder name") before ever reaching the CLI - defense-in-depth against Join-Path escaping AddonsPath' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'adopt'; folders = @('..\..\Windows') }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be 'bad request: invalid folder name'

            # Never even shelled out - no job was created for this request,
            # and nothing under the real AddOns folder moved.
            $g = Invoke-Api -Port 47899 -Method Get -Path '/api/jobs'
            @($g.Body | Where-Object { $_.kind -eq 'adopt' }).Count | Should Be 0
        }

        It 'a folder name containing a forward slash is also rejected 400 ("invalid folder name")' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'adopt'; folders = @('foo/bar') }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be 'bad request: invalid folder name'
        }

        It 'a folder name that does not exist under this flavour''s AddOns folder right now is rejected 400 ("folder not found"), never silently skipped the way the bare CLI would' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'adopt'; folders = @('DoesNotExistOnDisk') }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be 'bad request: folder not found: DoesNotExistOnDisk'
        }

        It 'one bad name in an otherwise-valid batch still 400s the WHOLE request (validated up front, before any job starts - no partial job)' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{
                kind    = 'adopt'
                folders = @('AdoptJobCfAddon', 'DoesNotExistOnDisk')
            }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400

            $g = Invoke-Api -Port 47899 -Method Get -Path '/api/jobs'
            @($g.Body | Where-Object { $_.kind -eq 'adopt' }).Count | Should Be 0
        }

        It 'an unrecognized ?flavour= is 400, same generic Resolve-RequestFlavour gate every other kind already gets' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=not_a_real_flavour' -Body @{
                kind    = 'adopt'
                folders = @('AdoptJobCfAddon')
            }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
        }
    } finally {
        Stop-TestServer -Server $server
        if ($wowRoot -and (Test-Path -LiteralPath $wowRoot)) { Remove-Item -LiteralPath $wowRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
