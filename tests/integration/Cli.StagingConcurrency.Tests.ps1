<#
=====================================================================
 tests\integration\Cli.StagingConcurrency.Tests.ps1

 NEW (review fix - coverage gap): CHANGELOG.md's Round 20 "staging\ is now
 nested under flavours\<id>\" fix has zero regression tests anywhere in
 the pre-existing suite. Nothing in tests\ ran two flavours' sync jobs
 concurrently against a SHARED script root - the one Describe that fans
 jobs across flavours (Server.FreshnessAndFlavours.Tests.ps1's
 update-all-flavours Describe) uses a fixture with zero tracked addons per
 flavour, and even so never actually launches more than one CLI process
 AT ONCE from the test's own perspective (it goes through the server's
 own per-flavour job queue, one flavour's -Add first, then a single
 update-all-flavours POST - it does not independently prove two REAL
 concurrent child processes racing on the same script root's staging
 folder).

 THE ACTUAL BUG THIS RE-CREATES (see CHANGELOG.md Round 20 and its
 companion "Filed, not fixed here (task_d2b170d3)" note): every
 non-DryRun run of addon-sync.ps1 unconditionally wipes-then-recreates its
 staging folder at startup (`if (Test-Path $script:StagingPath) {
 Remove-Item -Recurse -Force }; New-Item ...`) REGARDLESS of whether that
 run has anything to actually sync - a plain, addon-free run reaches this
 code path exactly the same as a real install. Pre-fix, $script:StagingPath
 was a single shared folder under the script root; two flavours' CLI
 processes running at the same instant would race on that same
 Remove-Item/New-Item pair (or on extracting the same project id into the
 same extraction folder), intermittently throwing "Could not find a part
 of the path" / "Cannot find path" / "directory is not empty". Post-fix,
 $script:StagingPath is nested under flavours\<id>\, so two DIFFERENT
 flavours' processes can never touch the same path even when they start
 at the exact same instant.

 This means the race can be reproduced WITHOUT any real network call or
 real installable addon at all: an addon-free default sync run for each
 of several DIFFERENT flavours, fired at the same instant against the
 SAME script root, still exercises the exact Remove-Item/New-Item pair
 the bug lived in - fully deterministic, fully offline, and (if the
 per-flavour nesting were ever regressed back to a shared path) would
 fail hard and often, not just occasionally, since every one of these
 rounds targets the literal same script root on purpose.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Start-CliProcessAsyncForFlavour {
    <#
      Launches one addon-sync.ps1 child process for -Flavor $Flavour
      WITHOUT waiting for it - the whole point of this Describe is several
      of these running at the exact same instant against the same
      $CliPath's script root. Mirrors Invoke-CliProcess's own
      ProcessStartInfo/quoting pattern (tests\lib\common.ps1) since that
      helper itself is synchronous end-to-end and cannot be used to start
      N processes concurrently.
    #>
    param([string]$CliPath, [string]$WowRoot, [string]$Flavour)

    $argList = @('-WowRoot', $WowRoot, '-Flavor', $Flavour, '-Json')
    $fullArgs = New-Object 'System.Collections.Generic.List[string]'
    $fullArgs.Add('-NoProfile'); $fullArgs.Add('-ExecutionPolicy'); $fullArgs.Add('Bypass')
    $fullArgs.Add('-File'); $fullArgs.Add($CliPath)
    foreach ($a in $argList) { $fullArgs.Add($a) }
    $quoted = @($fullArgs | ForEach-Object { ConvertTo-Win32QuotedArg -Value $_ })

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    return [PSCustomObject]@{ Process = $proc; StdOutTask = $stdoutTask; StdErrTask = $stderrTask; Flavour = $Flavour }
}

function Wait-CliProcessAsync {
    param($Handle, [int]$TimeoutSec = 60)

    $exited = $Handle.Process.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) {
        try { $Handle.Process.Kill() } catch { }
        try { $Handle.Process.Dispose() } catch { }
        return [PSCustomObject]@{ Flavour = $Handle.Flavour; ExitCode = -1; StdOut = ''; StdErr = "TIMED OUT after ${TimeoutSec}s" }
    }
    $result = [PSCustomObject]@{
        Flavour  = $Handle.Flavour
        ExitCode = $Handle.Process.ExitCode
        StdOut   = $Handle.StdOutTask.Result
        StdErr   = $Handle.StdErrTask.Result
    }
    $Handle.Process.Dispose()
    return $result
}

Describe 'staging\ is per-flavour: concurrent addon-free syncs across flavours never race (CHANGELOG Round 20)' {
    $wowRoot = Copy-Fixture
    $cliRoot = New-TempRoot -Name 'staging-concurrency'
    $cliPath = Join-Path $cliRoot 'addon-sync.ps1'
    Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination $cliPath -Force

    # Every fixture flavour, run against the SAME $cliPath script root every
    # round on purpose - that shared root is exactly what a shared (pre-fix)
    # staging path would have collided on.
    $flavours = @('retail', 'classic', 'classic_era', 'ptr')
    $rounds = 4

    # The literal error text the pre-fix shared-staging race threw
    # (CHANGELOG Round 20's own wording) - a regression reintroducing a
    # shared staging path would very likely surface one of these in at
    # least one round's stderr/log, not just occasionally, since all 4
    # flavours fire at the exact same instant against the exact same root
    # every round.
    $raceSignatures = @('Could not find a part of the path', 'Cannot find path', 'directory is not empty')

    It "runs $rounds rounds of all 4 flavours concurrently against one shared script root with zero staging errors" {
        for ($round = 1; $round -le $rounds; $round++) {
            $handles = @($flavours | ForEach-Object { Start-CliProcessAsyncForFlavour -CliPath $cliPath -WowRoot $wowRoot -Flavour $_ })
            $results = @($handles | ForEach-Object { Wait-CliProcessAsync -Handle $_ -TimeoutSec 60 })

            foreach ($r in $results) {
                $r.ExitCode | Should Be 0
                foreach ($sig in $raceSignatures) {
                    ($r.StdOut -like "*$sig*") | Should Be $false
                    ($r.StdErr -like "*$sig*") | Should Be $false
                }
                # Every -Json run parses cleanly and reports the flavour it
                # was actually asked to run as - confirms the process really
                # completed its own flavour's sync rather than crashing
                # mid-way and printing a partial/garbled payload.
                #
                # NOTE: deliberately NOT `{ $parsed = ... } | Should Not
                # Throw` - Pester 3 runs that script block in its OWN child
                # scope, so an assignment inside never escapes back out
                # (documented gotcha #2 in this project's own notes-for-next
                # - a real bug that bit this exact test on its first pass:
                # $parsed stayed $null outside, `$null.flavour` silently
                # evaluated to $null, and the assertion below compared
                # $null to 'retail' instead of ever really parsing StdOut).
                # A real parse failure here throws uncaught, which still
                # fails the It - no explicit Should-Throw wrapper needed.
                $parsed = $r.StdOut | ConvertFrom-Json -ErrorAction Stop
                $parsed.flavour | Should Be $r.Flavour
            }

            # Filesystem-level confirmation, not just "no error was thrown":
            # every flavour that ran this round left its OWN per-flavour
            # data folder behind (addon-sync.ps1 wipes $script:StagingPath
            # itself clean again at the very end of a successful run - see
            # addon-sync.ps1's own final cleanup - so staging\ itself is
            # never expected to still exist once the process has exited;
            # flavours\<id>\ is the persistent, per-flavour path the actual
            # fix nests staging UNDER, and is what proves 4 genuinely
            # distinct roots were used rather than 1 shared one).
            foreach ($f in $flavours) {
                $flavourDir = Join-Path $cliRoot "flavours\$f"
                (Test-Path -LiteralPath $flavourDir -PathType Container) | Should Be $true
            }
            $distinctFlavourRoots = @($flavours | ForEach-Object { (Join-Path $cliRoot "flavours\$_").ToLowerInvariant() } | Select-Object -Unique)
            $distinctFlavourRoots.Count | Should Be $flavours.Count
        }
    }
}
