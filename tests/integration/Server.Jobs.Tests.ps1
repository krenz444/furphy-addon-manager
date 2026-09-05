<#
=====================================================================
 tests\integration\Server.Jobs.Tests.ps1

 POST /api/jobs validation, argv-safety for a value containing a space,
 per-flavour job concurrency (409 same flavour / 202 different flavours),
 job-status view shape (progress field present), and GET /api/jobs/{id}
 never 404ing for a job that is still current.
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
