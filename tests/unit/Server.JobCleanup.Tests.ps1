<#
  Unit tests (Pester 3 syntax): addon-server.ps1's Remove-OldJobFiles, and
  the periodic re-run added for long-run:failed-job-files-only-pruned-at-
  startup.

  Before this round's fix, Remove-OldJobFiles ran exactly once, at server
  startup - fine for a server that gets relaunched often, but this process
  is explicitly meant to stay alive for days/weeks (the idle-exit + tray
  design), and a failed job leaves a .out.failed/.err.failed pair behind on
  every failure with no further cleanup for the life of that session.
  Remove-OldJobFiles itself is unchanged behaviorally by this fix (still a
  single "delete anything older than 1 day" sweep) - what changed is that
  the request loop's own tick now calls it again, gated to at most once an
  hour via $Script:JobCleanupIntervalMinutes/$Script:LastJobFilesPruneTime,
  instead of never again after the one startup call. This file covers the
  function's own deletion logic directly (moved above the dot-source guard
  specifically so a unit test can reach it); the periodic-tick wiring
  itself is a few lines of request-loop glue with no independent branching
  logic worth a second, slower integration-level reproduction.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

function New-JobFile {
    param([string]$Dir, [string]$Name, [int]$AgeHours)
    $path = Join-Path $Dir $Name
    Set-Content -LiteralPath $path -Value 'stub content' -Encoding UTF8
    if ($AgeHours -gt 0) {
        (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddHours(-$AgeHours)
    }
    return $path
}

Describe 'Remove-OldJobFiles' {

    It 'deletes .out/.err/.out.failed/.err.failed files older than 1 day, leaves fresh ones alone' {
        $jobsDir = New-TempRoot -Name 'job-cleanup'
        $Script:JobsDir = $jobsDir

        $staleOut = New-JobFile -Dir $jobsDir -Name '50.out' -AgeHours 30
        $staleErr = New-JobFile -Dir $jobsDir -Name '50.err' -AgeHours 30
        $staleFailedOut = New-JobFile -Dir $jobsDir -Name '99.out.failed' -AgeHours 48
        $staleFailedErr = New-JobFile -Dir $jobsDir -Name '99.err.failed' -AgeHours 48
        $freshOut = New-JobFile -Dir $jobsDir -Name '100.out' -AgeHours 1
        $freshFailedOut = New-JobFile -Dir $jobsDir -Name '101.out.failed' -AgeHours 0

        Remove-OldJobFiles

        (Test-Path -LiteralPath $staleOut) | Should Be $false
        (Test-Path -LiteralPath $staleErr) | Should Be $false
        (Test-Path -LiteralPath $staleFailedOut) | Should Be $false
        (Test-Path -LiteralPath $staleFailedErr) | Should Be $false
        (Test-Path -LiteralPath $freshOut) | Should Be $true
        (Test-Path -LiteralPath $freshFailedOut) | Should Be $true
    }

    It 'a stale .failed pair from a job that failed hours into a long-lived session is gone after a SECOND call, not just the startup one (long-run:failed-job-files-only-pruned-at-startup)' {
        # Direct repro of the finding: the server's own jobs\ folder already
        # had several-days-old .failed pairs sitting there because
        # Remove-OldJobFiles was only ever invoked once, at the process's
        # own startup, and this process had been running far longer than
        # that. Two calls a "session" apart (simulated here as two direct
        # calls, since the periodic re-run is only the request loop calling
        # this identical function again) must both still find and remove
        # anything that has since crossed the 1-day cutoff.
        $jobsDir = New-TempRoot -Name 'job-cleanup-longrun'
        $Script:JobsDir = $jobsDir

        # "startup" pass: nothing stale yet.
        Remove-OldJobFiles

        # A job fails partway through this long-lived session...
        $failedOut = New-JobFile -Dir $jobsDir -Name '77.out.failed' -AgeHours 0
        $failedErr = New-JobFile -Dir $jobsDir -Name '77.err.failed' -AgeHours 0
        # ...and more than a day goes by with the server still up (backdate
        # rather than actually sleeping).
        (Get-Item -LiteralPath $failedOut).LastWriteTime = (Get-Date).AddHours(-26)
        (Get-Item -LiteralPath $failedErr).LastWriteTime = (Get-Date).AddHours(-26)

        # Before this fix, nothing in the running process would ever call
        # Remove-OldJobFiles again - these would sit here for the rest of
        # the process's life. The periodic re-run's only job is to call
        # this exact function again; simulated directly here.
        Remove-OldJobFiles

        (Test-Path -LiteralPath $failedOut) | Should Be $false
        (Test-Path -LiteralPath $failedErr) | Should Be $false
    }

    It 'a missing jobs directory is a silent no-op, never throws' {
        $Script:JobsDir = Join-Path (New-TempRoot -Name 'job-cleanup-missing') 'does-not-exist'
        { Remove-OldJobFiles } | Should Not Throw
    }
}

Remove-TempRoots
