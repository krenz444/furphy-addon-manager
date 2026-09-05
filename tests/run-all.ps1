<#
=====================================================================
 tests\run-all.ps1 (T4)

 One entry point for the whole Furphy Addon Manager test suite. Runs
 every layer in order, aggregates a per-check result with durations,
 prints a plain summary table + one-line verdict, writes
 tests\last-report.json and tests\last-report.md, and exits 0 (all
 green) or 1 (any failure) - see TESTING.md for the full layer writeup.

 LAYERS, IN ORDER: static -> unit -> integration -> host -> spa ->
 fixture-acceptance -> perf ("zero impact on gameplay" pass, P3: a real
 fake-Wow.exe + server + tray + host-window steady-state window, plus the
 -Launcher fresh-check budget - see tests\perf\Perf.Tests.ps1).

 PARAMS
   -Quick        Runs static/unit/integration/host/spa only (skips
                 fixture-acceptance and perf entirely - both are real-
                 network-and/or-real-host-build-heavy full run bullets
                 (perf alone needs a ~90s fake-play steady-state window
                 plus a tray first-cycle wait, well over the <4-minute
                 Quick budget on its own), not part of the <4-minute Quick
                 budget) and implies -NoNetwork. Target: under 4 minutes:
                 measured and reported (see the "total quick time" line).
   -NoNetwork    Excludes every test tagged 'Network' (real internet
                 calls: a live CurseForge install, the host --selftest
                 Describe, one freshness 'checking' Describe) without
                 otherwise changing which layers run - usable standalone
                 against a full run too ("everything except network").
   -NoTray       Excludes every test tagged 'Tray' (starts a real
                 FurphyHost.exe --tray process and touches the real HKCU
                 Run value, though always removing it again in a finally
                 block) - independent of -Quick/-NoNetwork.
   -Only <names> Restricts the run to exactly these layer names (any of
                 static/unit/integration/host/spa/fixture-acceptance/
                 perf), overriding the default Quick/full layer
                 selection. Tag exclusions (-NoNetwork/-NoTray/-Quick's
                 implied -NoNetwork) still apply on top of -Only.
   -Json         Prints the final report as compact JSON to stdout
                 instead of the human-readable table (the two report
                 files are always written either way).

 HYGIENE: every port this run might have touched (47899, 47890-47897) is
 checked and any owning process force-stopped, and tests\.tmp is swept
 to empty, in a top-level `finally` block regardless of outcome. A
 straggler FurphyHost.exe process or a leftover HKCU
 FurphyAddonManager Run value (both hard rules: tests must never leave
 either behind) is also checked and force-cleaned as a last-resort safety
 net, independent of whatever cleanup the failing test itself attempted -
 logged loudly if it had to do anything, since that means some test's
 own `finally` did not run to completion.

 Review fix: this same sweep also now runs once at the very START of a
 run (before any layer executes), not only at the end. Start-TestServer
 (tests\lib\common.ps1) refuses to start against a port that is already
 answering, specifically to guard against a stale server left behind by
 an interrupted prior run (a crash/Ctrl+C before its own Stop-TestServer
 ran) being silently adopted as "up" - but that guard only helps if
 run-all.ps1 itself does not walk straight into the same stale state on
 its very first layer. Sweeping first means every run (including the
 deploy.ps1 gate's own `-Quick` invocation) starts from a known-clean
 slate regardless of how the previous invocation on this machine ended.

 KNOWN, NON-BLOCKING FINDINGS: a small explicit allowlist
 ($Script:KnownNonBlockingChecks below) lets a check that is a real,
 already-flagged, separately-tracked finding (not a regression - see
 CHANGELOG.md/ROADMAP.md) still be RECORDED (it still counts in
 Total/FailedCount, still prints in the console/report so it is never
 silently hidden) without flipping that layer's Passed or overallOk -
 otherwise the gate can never go green again on a checked-in, known
 issue that a tests-only step is not authorized to fix (e.g. the repo
 mirror's own .gitignore, which deploy.ps1/the mirror owns, not this
 suite). Add an entry here ONLY for a finding that is already written up
 in CHANGELOG.md/ROADMAP.md as flagged-not-fixed - never to quiet a new
 or unexplained failure.
#>

param(
    [switch]$Quick,
    [switch]$NoNetwork,
    [switch]$NoTray,
    [string[]]$Only,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'lib\common.ps1')

try {
    Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop -Force
} catch {
    Write-Host "FATAL: could not load Pester 3.4.0 ($($_.Exception.Message))" -ForegroundColor Red
    exit 1
}

$Script:AllLayers = @('static', 'unit', 'integration', 'host', 'spa', 'fixture-acceptance', 'perf')
$effectiveNoNetwork = [bool]($Quick -or $NoNetwork)
$effectiveNoTray = [bool]$NoTray

# ---------------------------------------------------------------------
# Known, already-flagged, separately-tracked findings that must never
# block the gate (see the header comment above). Keyed by the exact
# check DisplayName used below. Every entry MUST cite where it is
# tracked outside this file.
#
# P3 perf pass: the one long-standing entry here (the repo mirror's
# .gitignore missing a cache/ pattern, T1/Round 22) is now REMOVED - Eric
# fixed the mirror's .gitignore by hand (it now has a cache/ line) and
# tests\static\Test-GitignoreCoverage.ps1 itself was fixed to read the
# mirror path from deploy.ps1's own -RepoPath default instead of a second
# hand-typed copy (see that file's own header comment) - the check passes
# clean (17/17) again, so this allowlist is empty until a new, genuinely
# already-flagged-elsewhere finding needs it.
# ---------------------------------------------------------------------
$Script:KnownNonBlockingChecks = @{}

$excludeTags = New-Object 'System.Collections.Generic.List[string]'
if ($effectiveNoNetwork) { $excludeTags.Add('Network') }
if ($effectiveNoTray) { $excludeTags.Add('Tray') }

if ($Only -and @($Only).Count -gt 0) {
    $layersToRun = @($Only | ForEach-Object { $_.ToString().ToLowerInvariant() })
    foreach ($l in $layersToRun) {
        if ($Script:AllLayers -notcontains $l) {
            Write-Host "FATAL: -Only names an unknown layer '$l' (known: $($Script:AllLayers -join ', '))" -ForegroundColor Red
            exit 1
        }
    }
} elseif ($Quick) {
    $layersToRun = @('static', 'unit', 'integration', 'host', 'spa')
} else {
    $layersToRun = $Script:AllLayers
}

$runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$layerReports = New-Object 'System.Collections.Generic.List[object]'
$overallOk = $true
$harnessError = $null

function New-LayerReport {
    param([string]$Name)
    return [PSCustomObject]@{
        Name        = $Name
        Skipped     = $false
        SkipReason  = $null
        Passed      = $true
        Total       = 0
        PassedCount = 0
        FailedCount = 0
        DurationSec = 0.0
        Checks      = (New-Object 'System.Collections.Generic.List[object]')
    }
}

function Add-Check {
    <#
      -Known marks a FAILING check as an already-flagged, separately-
      tracked finding (see $Script:KnownNonBlockingChecks) rather than a
      fresh regression: it still gets recorded (Total/FailedCount both
      still increment, it still prints, it still shows in the report) but
      does NOT flip $Layer.Passed/overallOk. A passing check ignores
      -Known entirely - the allowlist only ever suppresses blocking, never
      hides that the check ran.
    #>
    param($Layer, [string]$Name, [bool]$Passed, [string]$Message, [switch]$Known)
    $Layer.Checks.Add([PSCustomObject]@{ Name = $Name; Passed = $Passed; Message = $Message; Known = [bool]$Known })
    $Layer.Total++
    if ($Passed) {
        $Layer.PassedCount++
    } else {
        $Layer.FailedCount++
        if ($Known) {
            Write-Host "  KNOWN (non-blocking, see CHANGELOG/ROADMAP): $Name" -ForegroundColor DarkYellow
        } else {
            $Layer.Passed = $false
        }
    }
}

function Get-SummaryLine {
    <# Pulls the trailing "[suite] N/M passed" line a tests\static\*.ps1 / tests\spa\Run-*.ps1 script prints, per this project's common.ps1 Write-ResultsSummary convention. #>
    param([string]$StdOut)
    $lines = @($StdOut -split "`r?`n")
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match '^\[.+\]\s+\d+/\d+\s+passed\s*$') { return $lines[$i].Trim() }
    }
    return $null
}

function Invoke-ScriptCheck {
    <# Runs one standalone exit-coded .ps1 (tests\static\*.ps1 or tests\spa\Run-*.ps1) as a real child process (never via & - these end in `exit N`, which would tear down run-all.ps1 itself if called in-process) and adds one check to $Layer. #>
    param($Layer, [string]$Path, [string]$DisplayName, [int]$TimeoutSec = 240)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Check -Layer $Layer -Name $DisplayName -Passed $false -Message "script not found: $Path"
        return
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-CliProcess -ScriptPath $Path -ArgumentList @() -TimeoutSec $TimeoutSec
    $sw.Stop()
    Write-Host ""
    Write-Host "== $DisplayName ==" -ForegroundColor Cyan
    if ($r.StdOut) { Write-Host $r.StdOut }
    if ($r.StdErr) { Write-Host $r.StdErr -ForegroundColor DarkYellow }
    $summary = Get-SummaryLine -StdOut $r.StdOut
    $msg = if ($summary) { "$summary (exit $($r.ExitCode), $([math]::Round($sw.Elapsed.TotalSeconds, 1))s)" } else { "exit $($r.ExitCode), $([math]::Round($sw.Elapsed.TotalSeconds, 1))s" }
    if ($r.ExitCode -ne 0) {
        # A script-level check hides its own individual [FAIL] lines from
        # the JSON/Markdown report otherwise (they're only visible in the
        # console output above) - fold them into the message so
        # tests\last-report.md alone is enough to see WHAT failed, not
        # just that something did.
        $failLines = @($r.StdOut -split "`r?`n" | Where-Object { $_ -match '^\s*\[FAIL\]' } | ForEach-Object { $_.Trim() })
        if ($failLines.Count -gt 0) { $msg = $msg + "`n" + ($failLines -join "`n") }
    }
    $isKnown = ($r.ExitCode -ne 0) -and $Script:KnownNonBlockingChecks.ContainsKey($DisplayName)
    if ($isKnown) { $msg = $msg + "`nKNOWN (non-blocking): " + $Script:KnownNonBlockingChecks[$DisplayName] }
    Add-Check -Layer $Layer -Name $DisplayName -Passed ($r.ExitCode -eq 0) -Message $msg -Known:$isKnown
}

function Invoke-PesterLayer {
    <# Runs every *.Tests.ps1 under -Dir via Invoke-Pester -PassThru (in-process - Pester itself never calls exit) and folds every individual It into $Layer's checks. #>
    param($Layer, [string]$Dir, [string[]]$Tag)

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        Add-Check -Layer $Layer -Name "$Dir exists" -Passed $false -Message 'directory not found'
        return
    }
    $hasTests = @(Get-ChildItem -LiteralPath $Dir -Filter '*.Tests.ps1' -File -ErrorAction SilentlyContinue).Count -gt 0
    if (-not $hasTests) {
        Add-Check -Layer $Layer -Name "$Dir has test files" -Passed $false -Message 'no *.Tests.ps1 files found'
        return
    }

    $pesterArgs = @{ Script = $Dir; PassThru = $true }
    if ($Tag -and @($Tag).Count -gt 0) { $pesterArgs['Tag'] = $Tag }
    if ($excludeTags.Count -gt 0) { $pesterArgs['ExcludeTag'] = $excludeTags.ToArray() }

    $result = Invoke-Pester @pesterArgs
    foreach ($t in @($result.TestResult)) {
        $name = ($t.Describe, $t.Context, $t.Name | Where-Object { $_ }) -join ' :: '
        Add-Check -Layer $Layer -Name $name -Passed ([bool]$t.Passed) -Message $(if (-not $t.Passed) { [string]$t.FailureMessage } else { $null })
    }
    $Layer.DurationSec += $result.Time.TotalSeconds
}

function Stop-ProcessOnPort {
    param([int]$Port)
    try {
        $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        foreach ($c in @($conns)) {
            try {
                Write-Host "  WARN: port $Port still held by PID $($c.OwningProcess) - force-stopping it" -ForegroundColor Yellow
                Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
            } catch { }
        }
    } catch { }
}

function Invoke-HygieneSweep {
    <#
      Ports/stray-process/HKCU/tests\.tmp sweep, shared by BOTH a
      pre-flight pass (before any layer runs, so a stale server/process
      left behind by an interrupted prior invocation on this machine can
      never be silently adopted as "up" by the very first layer - see
      Start-TestServer's own matching pre-flight port check in
      tests\lib\common.ps1) and the trailing `finally` pass (the
      original, still-mandatory last-resort safety net). -Label
      distinguishes the two in the console output.
    #>
    param([string]$Label = 'Hygiene sweep')

    Write-Host ""
    Write-Host "== $Label ==" -ForegroundColor Cyan
    foreach ($p in @(47899) + @(47890..47897)) { Stop-ProcessOnPort -Port $p }

    $strayHost = Get-Process -Name 'FurphyHost' -ErrorAction SilentlyContinue
    if ($strayHost) {
        Write-Host "  WARN: $(@($strayHost).Count) straggler FurphyHost.exe process(es) found - force-stopping" -ForegroundColor Yellow
        foreach ($p in @($strayHost)) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
    } else {
        Write-Host "  ok: no straggler FurphyHost.exe process"
    }

    try {
        $runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $existing = Get-ItemProperty -LiteralPath $runKeyPath -Name 'FurphyAddonManager' -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            Write-Host "  WARN: HKCU Run still carries a FurphyAddonManager value - removing it" -ForegroundColor Yellow
            Remove-ItemProperty -LiteralPath $runKeyPath -Name 'FurphyAddonManager' -ErrorAction SilentlyContinue
        } else {
            Write-Host "  ok: HKCU Run has no FurphyAddonManager value"
        }
    } catch { }

    if (Test-Path -LiteralPath $Script:FurphyTmpRoot) {
        $before = @(Get-ChildItem -LiteralPath $Script:FurphyTmpRoot -Force -ErrorAction SilentlyContinue).Count
        Get-ChildItem -LiteralPath $Script:FurphyTmpRoot -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch {
                Write-Host "  WARN: could not remove $($_.FullName): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        Write-Host "  ok: tests\.tmp swept ($before item(s) found, removed where possible)"
    }
}

# Review fix: run the sweep once BEFORE anything starts, not only in the
# trailing `finally` below - see the header comment's "Review fix" note
# and Start-TestServer's matching pre-flight port check.
Invoke-HygieneSweep -Label 'Hygiene sweep (pre-flight)'

# =====================================================================
# Every layer below runs inside one try; an unexpected terminating error
# (a layer script/Invoke-Pester call throwing outright, rather than a
# normal test failure) is caught into a synthetic "harness-error" layer
# instead of aborting before the hygiene sweep - the finally block below
# always runs the port/temp-dir/HKCU sweep regardless of how the try
# exits (normal completion, a caught error, or an uncaught signal).
# =====================================================================
try {

# =====================================================================
# static
# =====================================================================
if ($layersToRun -contains 'static') {
    $layer = New-LayerReport -Name 'static'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $staticDir = Join-Path $Script:FurphyTestsRoot 'static'
    $scripts = @(Get-ChildItem -LiteralPath $staticDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($s in $scripts) {
        Invoke-ScriptCheck -Layer $layer -Path $s.FullName -DisplayName ("static: " + $s.BaseName)
    }
    $sw.Stop()
    $layer.DurationSec = $sw.Elapsed.TotalSeconds
    $layerReports.Add($layer)
}

# =====================================================================
# unit
# =====================================================================
if ($layersToRun -contains 'unit') {
    $layer = New-LayerReport -Name 'unit'
    Invoke-PesterLayer -Layer $layer -Dir (Join-Path $Script:FurphyTestsRoot 'unit')
    $layerReports.Add($layer)
}

# =====================================================================
# integration
# =====================================================================
if ($layersToRun -contains 'integration') {
    $layer = New-LayerReport -Name 'integration'
    Invoke-PesterLayer -Layer $layer -Dir (Join-Path $Script:FurphyTestsRoot 'integration')
    $layerReports.Add($layer)
}

# =====================================================================
# host
# =====================================================================
if ($layersToRun -contains 'host') {
    $layer = New-LayerReport -Name 'host'
    Invoke-PesterLayer -Layer $layer -Dir (Join-Path $Script:FurphyTestsRoot 'host') -Tag @('Host')
    $layerReports.Add($layer)
}

# =====================================================================
# spa (harness always; the 14-theme screenshot+contrast audit is
# full-run-only - real per-theme msedge launches, not part of Quick's
# <4-minute budget)
# =====================================================================
if ($layersToRun -contains 'spa') {
    $layer = New-LayerReport -Name 'spa'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-ScriptCheck -Layer $layer -Path (Join-Path $Script:FurphyTestsRoot 'spa\Run-SpaHarness.ps1') -DisplayName 'spa: Run-SpaHarness'
    if (-not $Quick) {
        Invoke-ScriptCheck -Layer $layer -Path (Join-Path $Script:FurphyTestsRoot 'spa\Run-ThemeAudit.ps1') -DisplayName 'spa: Run-ThemeAudit (14 themes, full-only)' -TimeoutSec 300
    }
    $sw.Stop()
    $layer.DurationSec = $sw.Elapsed.TotalSeconds
    $layerReports.Add($layer)
}

# =====================================================================
# fixture-acceptance (full-run-only by design - see this layer's own
# file header: install.ps1's real host\ rebuild step alone costs real
# seconds per Context)
# =====================================================================
if ($layersToRun -contains 'fixture-acceptance') {
    $layer = New-LayerReport -Name 'fixture-acceptance'
    Invoke-PesterLayer -Layer $layer -Dir (Join-Path $Script:FurphyTestsRoot 'fixture-acceptance')
    $layerReports.Add($layer)
}

# =====================================================================
# perf ("zero impact on gameplay" pass, P3 - full-run-only by design, same
# reason as fixture-acceptance/the theme audit above: a real fake-Wow.exe +
# server + tray + host-window steady-state window costs real wall-clock
# seconds, well over the Quick budget - see tests\perf\Perf.Tests.ps1's own
# header comment for the exact timeline)
# =====================================================================
if ($layersToRun -contains 'perf') {
    $layer = New-LayerReport -Name 'perf'
    Invoke-PesterLayer -Layer $layer -Dir (Join-Path $Script:FurphyTestsRoot 'perf')
    $layerReports.Add($layer)
}

} catch {
    $harnessError = $_.Exception.Message
    Write-Host ""
    Write-Host "FATAL (caught, hygiene sweep still runs): $harnessError" -ForegroundColor Red
    $errLayer = New-LayerReport -Name 'harness-error'
    Add-Check -Layer $errLayer -Name 'run-all.ps1 completed without an uncaught error' -Passed $false -Message $harnessError
    $layerReports.Add($errLayer)
} finally {
    # ---- Hygiene: sweep tests\.tmp, kill anything left on our ports,
    # and clean up a straggler FurphyHost.exe / HKCU Run value as a
    # last-resort safety net - regardless of how the try above exited.
    # (Same sweep also ran once at the very start of this run - see
    # 'Hygiene sweep (pre-flight)' above and the header comment's
    # "Review fix" note.)
    Invoke-HygieneSweep -Label 'Hygiene sweep'
} # end finally

$runStopwatch.Stop()
foreach ($layer in $layerReports) {
    if (-not $layer.Skipped -and -not $layer.Passed) { $overallOk = $false }
}

# =====================================================================
# Report
# =====================================================================
$report = [ordered]@{
    generatedAt      = (Get-Date).ToString('o')
    mode             = if ($Quick) { 'quick' } else { 'full' }
    noNetwork        = $effectiveNoNetwork
    noTray           = $effectiveNoTray
    only             = $Only
    layersRun        = $layersToRun
    totalDurationSec = [math]::Round($runStopwatch.Elapsed.TotalSeconds, 1)
    overallPassed    = $overallOk
    layers           = @($layerReports | ForEach-Object {
            [ordered]@{
                name        = $_.Name
                skipped     = $_.Skipped
                skipReason  = $_.SkipReason
                passed      = $_.Passed
                total       = $_.Total
                passedCount = $_.PassedCount
                failedCount = $_.FailedCount
                durationSec = [math]::Round($_.DurationSec, 1)
                checks      = @($_.Checks | ForEach-Object { [ordered]@{ name = $_.Name; passed = $_.Passed; message = $_.Message; known = $_.Known } })
            }
        })
}

$reportJsonPath = Join-Path $Script:FurphyTestsRoot 'last-report.json'
$reportMdPath = Join-Path $Script:FurphyTestsRoot 'last-report.md'

($report | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $reportJsonPath -Encoding UTF8

$md = New-Object 'System.Collections.Generic.List[string]'
$md.Add('# Furphy Addon Manager - test report')
$md.Add('')
$md.Add("Generated: $($report.generatedAt)  ")
$md.Add("Mode: $($report.mode)  -NoNetwork=$($report.noNetwork)  -NoTray=$($report.noTray)  ")
$md.Add("Total duration: $($report.totalDurationSec)s")
$md.Add('')
$md.Add('| Layer | Status | Passed/Total | Duration (s) |')
$md.Add('|---|---|---|---|')
foreach ($l in $report.layers) {
    $status = if ($l.skipped) { 'SKIPPED' } elseif ($l.passed) { 'PASS' } else { 'FAIL' }
    $md.Add("| $($l.name) | $status | $($l.passedCount)/$($l.total) | $($l.durationSec) |")
}
$md.Add('')
foreach ($l in $report.layers) {
    if ($l.skipped) {
        $md.Add("## $($l.name) - SKIPPED")
        $md.Add($l.skipReason)
        $md.Add('')
        continue
    }
    $failing = @($l.checks | Where-Object { (-not $_.passed) -and (-not $_.known) })
    if ($failing.Count -gt 0) {
        $md.Add("## $($l.name) - failures")
        foreach ($f in $failing) {
            $msgLines = @([string]$f.message -split "`n")
            $md.Add("- **$($f.name)**: $($msgLines[0])")
            for ($i = 1; $i -lt $msgLines.Count; $i++) {
                if ($msgLines[$i]) { $md.Add("  - $($msgLines[$i])") }
            }
        }
        $md.Add('')
    }
    # Known, already-flagged, separately-tracked findings (see
    # $Script:KnownNonBlockingChecks) - recorded for visibility but do NOT
    # count toward this layer's/overall pass-fail, so they get their own
    # section instead of hiding inside "failures".
    $known = @($l.checks | Where-Object { (-not $_.passed) -and $_.known })
    if ($known.Count -gt 0) {
        $md.Add("## $($l.name) - known, non-blocking findings")
        foreach ($f in $known) {
            $msgLines = @([string]$f.message -split "`n")
            $md.Add("- **$($f.name)**: $($msgLines[0])")
            for ($i = 1; $i -lt $msgLines.Count; $i++) {
                if ($msgLines[$i]) { $md.Add("  - $($msgLines[$i])") }
            }
        }
        $md.Add('')
    }
}
$verdict = if ($overallOk) { "ALL LAYERS PASSED ($($report.mode) run, $($report.totalDurationSec)s)" } else { "FAILED - see failures above ($($report.mode) run, $($report.totalDurationSec)s)" }
$md.Add("## Verdict: $verdict")
($md.ToArray() -join "`r`n") | Set-Content -LiteralPath $reportMdPath -Encoding UTF8

if ($Json) {
    ($report | ConvertTo-Json -Depth 8)
} else {
    Write-Host ""
    Write-Host "===================== SUMMARY =====================" -ForegroundColor Cyan
    $fmt = "{0,-20} {1,-8} {2,-14} {3,10}"
    Write-Host ($fmt -f 'Layer', 'Status', 'Passed/Total', 'Duration(s)')
    foreach ($l in $report.layers) {
        $status = if ($l.skipped) { 'SKIP' } elseif ($l.passed) { 'PASS' } else { 'FAIL' }
        $color = if ($l.skipped) { 'DarkGray' } elseif ($l.passed) { 'Green' } else { 'Red' }
        Write-Host ($fmt -f $l.name, $status, "$($l.passedCount)/$($l.total)", $l.durationSec) -ForegroundColor $color
    }
    Write-Host "===================================================="
    Write-Host $verdict -ForegroundColor $(if ($overallOk) { 'Green' } else { 'Red' })
    Write-Host "Report: $reportJsonPath"
    Write-Host "Report: $reportMdPath"
}

if ($overallOk) { exit 0 } else { exit 1 }
