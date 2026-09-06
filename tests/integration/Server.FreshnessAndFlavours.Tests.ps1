<#
=====================================================================
 tests\integration\Server.FreshnessAndFlavours.Tests.ps1

 Get-ComputedFreshness's not_checked/checking/up_to_date/check_failed
 transitions, driven through a real "check" job, plus
 update-all-flavours's PTR/showTestRealms fan-out exclusion.

 The not_checked/up_to_date and check_failed legs below are fully OFFLINE
 and deterministic (zero tracked addons -> zero CurseForge calls at all;
 check_failed is forced via a broken -AddonsPath so the CLI exits 2 before
 any network call). The "checking" mid-flight leg needs the job to still be
 running when polled, which needs real wall-clock duration - that Describe
 is tagged 'Network' and adds a few nonexistent numeric project ids so each
 gets a real (fast-failing) CurseForge round trip plus addon-sync.ps1's own
 unconditional 300ms per-request pacing.
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

Describe 'Freshness: not_checked -> up_to_date (offline, zero tracked addons)' {
    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'fresh-offline'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot

        It 'starts not_checked' {
            $s = Invoke-Api -Port 47899 -Method Get -Path '/api/state?flavour=retail'
            $s.Body.freshness | Should Be 'not_checked'
            $s.Body.updatesCheckedAt | Should Be $null
        }

        It 'a completed check job (zero addons -> no network needed) moves freshness to up_to_date' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'check' }
            $r.Ok | Should Be $true
            $done = Wait-JobDone -Port 47899 -JobId $r.Body.jobId -TimeoutSec 20
            $done.Body.state | Should Be 'done'

            $s = Invoke-Api -Port 47899 -Method Get -Path '/api/state?flavour=retail'
            $s.Body.freshness | Should Be 'up_to_date'
            $s.Body.updatesCheckedAt | Should Not Be $null
            $s.Body.lastCheckFailed | Should Be $false
        }
    } finally {
        Stop-TestServer -Server $server
    }
}

Describe 'Freshness: check_failed (offline - forced via an unresolvable AddonsPath)' {
    $root = New-TempRoot -Name 'fresh-failed'
    $server = $null
    try {
        # No -WowRoot AND an explicit -AddonsPath that does not exist: every
        # CLI child process this server spawns exits 2
        # ("AddonsPath ... could not be inferred") before touching the
        # network - a fully offline, deterministic way to force a job
        # failure for the freshness computation to react to.
        $bogusAddonsPath = Join-Path $root 'nonexistent\Interface\AddOns'
        $server = Start-TestServer -Root $root -Port 47899 -ExtraArgs @('-AddonsPath', $bogusAddonsPath)

        It 'a failed check job sets freshness to check_failed with a non-empty lastCheckError' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs' -Body @{ kind = 'check' }
            $r.Ok | Should Be $true
            $done = Wait-JobDone -Port 47899 -JobId $r.Body.jobId -TimeoutSec 20
            $done.Body.state | Should Be 'failed'

            $s = Invoke-Api -Port 47899 -Method Get -Path '/api/state'
            $s.Body.freshness | Should Be 'check_failed'
            $s.Body.lastCheckFailed | Should Be $true
            ([string]::IsNullOrEmpty($s.Body.lastCheckError)) | Should Be $false
        }
    } finally {
        Stop-TestServer -Server $server
    }
}

Describe 'Freshness: checking (mid-flight)' -Tags 'Network' {
    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'fresh-checking'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot

        # A handful of nonexistent-but-numeric CurseForge project ids so the
        # check job makes several real (fast 404) requests, each still
        # subject to addon-sync.ps1's own unconditional 300ms post-request
        # pacing (Invoke-CfRequest) - long enough to reliably observe
        # freshness=='checking' on an immediate poll.
        $bogusIds = @(900000001, 900000002, 900000003, 900000004, 900000005)
        $addForFlavour = Invoke-CliJson -ScriptPath (Join-Path $root 'addon-sync.ps1') `
            -ArgumentList @('-Add', ($bogusIds -join ','), '-Json', '-WowRoot', $wowRoot, '-Flavor', 'retail')
        # (the add itself is expected to report every id Failed - that is
        # fine and not asserted on here; it only needs the records to EXIST
        # in addons.json so the next -DryRun/check job iterates them.)

        It 'is observed at least once while a slow check job is still running, then settles to up_to_date' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'check' }
            $r.Ok | Should Be $true

            $sawChecking = $false
            $deadline = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $deadline) {
                $s = Invoke-Api -Port 47899 -Method Get -Path '/api/state?flavour=retail'
                if ($s.Body.freshness -eq 'checking') { $sawChecking = $true; break }
                if ($s.Body.job -and $s.Body.job.state -ne 'running') { break }
                Start-Sleep -Milliseconds 100
            }
            $sawChecking | Should Be $true

            $done = Wait-JobDone -Port 47899 -JobId $r.Body.jobId -TimeoutSec 30
            $done.Body.state | Should Be 'done'
            $sAfter = Invoke-Api -Port 47899 -Method Get -Path '/api/state?flavour=retail'
            $sAfter.Body.freshness | Should Be 'up_to_date'
        }
    } finally {
        Stop-TestServer -Server $server
    }
}

Describe 'update-all-flavours excludes ptr unless showTestRealms' {
    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'update-all-flavours'
    $server = $null
    try {
        # fixture: retail, classic, classic_era, ptr installed (xptr/beta are not).
        $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot

        It 'showTestRealms=false (default): ptr is excluded from the fan-out' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs' -Body @{ kind = 'update-all-flavours' }
            $r.Ok | Should Be $true
            $flavoursOut = @($r.Body.jobs | ForEach-Object { $_.flavour })
            ($flavoursOut -contains 'ptr') | Should Be $false
            ($flavoursOut -contains 'retail') | Should Be $true
            ($flavoursOut -contains 'classic') | Should Be $true
            ($flavoursOut -contains 'classic_era') | Should Be $true
            $flavoursOut.Count | Should Be 3
            foreach ($j in @($r.Body.jobs)) {
                if ($j.jobId) { Wait-JobDone -Port 47899 -JobId $j.jobId -TimeoutSec 20 | Out-Null }
            }
        }

        It 'showTestRealms=true: ptr is included' {
            Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ showTestRealms = $true } | Out-Null
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs' -Body @{ kind = 'update-all-flavours' }
            $r.Ok | Should Be $true
            $flavoursOut = @($r.Body.jobs | ForEach-Object { $_.flavour })
            ($flavoursOut -contains 'ptr') | Should Be $true
            $flavoursOut.Count | Should Be 4
            foreach ($j in @($r.Body.jobs)) {
                if ($j.jobId) { Wait-JobDone -Port 47899 -JobId $j.jobId -TimeoutSec 20 | Out-Null }
            }
        }
    } finally {
        Stop-TestServer -Server $server
    }
}

Describe 'Round 28: progress.json tallies pass through to job.progress on a real check job' -Tags 'Network' {
    <#
      NOT the same trick as the 'Freshness: checking'/per-flavour-concurrency
      Describes' "-Add a few bogus-but-numeric project ids first" seed: that
      trick only needs those jobs to still be RUNNING when polled, so it
      never noticed that CurseForge's files-list endpoint returns a plain
      200 with an empty "data":[] for a project id that does not exist
      (never a 404) - Select-CfFile then finds no matching file and
      Sync-SingleAddon returns Status='Skipped', not 'Failed', and (since
      this happens during the -Add run itself) addon-sync.ps1's own "drop
      placeholder records that never got an installable file" cleanup
      (CHANGELOG-documented, S. "Persist config") then deletes every one of
      those records from addons.json before the CLI process even exits -
      so a later 'check' job over that flavour has ZERO tracked addons to
      iterate, not three, and every tally stays 0 (this is exactly the
      "checked=0" verify failure this Describe used to reproduce).
      Confirmed live: `-Add 900000011,900000012,900000013` against the
      real curseforge.com API leaves addons.json as `[]`.

      Fixed the way Cli.InstallRollbackLauncher.Tests.ps1's offline rollback
      Describe already does it: hand-craft the addons.json records directly
      (next to the copied addon-sync.ps1 under $root - Start-TestServer
      already put one there - never under $wowRoot, which only affects
      flavour/AddOns-path DETECTION), so the "drop placeholder" cleanup
      never runs against them at all (that cleanup is -Add-only). Each
      record carries a pinnedFileId that does not exist for its (also
      bogus) project - Sync-SingleAddon's pin path (addon-sync.ps1's own
      -FileId/pinnedFileId branch) then makes exactly ONE real
      Get-CfFileById request per addon (still paced 300ms apart, so the
      job stays observably 'running' for a beat, same as the older trick),
      gets back a genuine `{"data":null}` for a fileId that belongs to no
      project, and returns Status='Failed' deterministically - proven by a
      live run against curseforge.com before landing this fix. This never
      touches -Add at all, so the placeholder-drop cleanup is a complete
      non-issue here.
    #>
    $wowRoot = Copy-Fixture
    $root = New-TempRoot -Name 'fresh-tallies'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port 47899 -WowRoot $wowRoot

        $bogusIds = @(900000011, 900000012, 900000013)
        $flavourDir = Join-Path $root 'flavours\retail'
        New-Item -ItemType Directory -Path $flavourDir -Force | Out-Null
        $records = New-Object 'System.Collections.Generic.List[object]'
        foreach ($id in $bogusIds) {
            $records.Add([PSCustomObject]@{
                    name             = "project $id"
                    projectId        = $id
                    fileId           = 1
                    version          = '0.0.0'
                    fileName         = 'fake.zip'
                    installedAt      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                    folders          = @("Fake$id")
                    author           = $null
                    ignoreUpdates    = $false
                    # A file id that cannot belong to ANY project (let alone
                    # this bogus one) - Get-CfFileById's own doc comment: "a
                    # fileId that does not belong to the project naturally
                    # 404s (caller treats any failure as Failed)".
                    pinnedFileId     = 999999999
                    releaseType      = $null
                    previousFileId   = $null
                    previousVersion  = $null
                    previousFileName = $null
                    requiredDeps     = @()
                    optionalDeps     = @()
                    source           = 'curseforge'
                    wagoId           = $null
                    slug             = $null
                    curseId          = $null
                    latestGameVersions = @()
                    latestFileDate     = $null
                })
        }
        ConvertTo-Json -InputObject $records.ToArray() -Depth 10 | Set-Content -LiteralPath (Join-Path $flavourDir 'addons.json') -Encoding UTF8

        It 'job.progress carries the tallies, ends checked=3 failed=3 updated=0 upToDate=0 updatesFound=0' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/jobs?flavour=retail' -Body @{ kind = 'check' }
            $r.Ok | Should Be $true

            # Confirm the tallies fields are present at least once WHILE the
            # job is still running (not just after it lands), so a tray/UI
            # poller mid-cycle genuinely has them to read - not merely a
            # coincidence of the final snapshot.
            $sawTalliesFieldsMidRun = $false
            $deadline = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $deadline) {
                $g = Invoke-Api -Port 47899 -Method Get -Path "/api/jobs/$($r.Body.jobId)"
                if ($g.Body.progress -and ($g.Body.progress.PSObject.Properties.Name -contains 'checked')) {
                    $sawTalliesFieldsMidRun = $true
                }
                if ($g.Body.state -ne 'running') { break }
                Start-Sleep -Milliseconds 100
            }
            $sawTalliesFieldsMidRun | Should Be $true

            $done = Wait-JobDone -Port 47899 -JobId $r.Body.jobId -TimeoutSec 30
            $done.Body.state | Should Be 'done'
            $done.Body.progress.checked | Should Be 3
            $done.Body.progress.failed | Should Be 3
            $done.Body.progress.updated | Should Be 0
            $done.Body.progress.upToDate | Should Be 0
            $done.Body.progress.updatesFound | Should Be 0
        }
    } finally {
        Stop-TestServer -Server $server
    }
}
