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
