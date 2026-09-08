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
 fake-Wow.exe + server + tray + host-window steady-state window -
 see tests\perf\Perf.Tests.ps1).

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
                 FurphyHost.exe --tray --port 47899 process and toggles the
                 TEST registry value FurphyAddonManager.Test, removing it
                 again in a finally block; the production value is untouched) - independent of -Quick/-NoNetwork.
   -Only <names> Restricts the run to exactly these layer names (any of
                 static/unit/integration/host/spa/fixture-acceptance/
                 perf), overriding the default Quick/full layer
                 selection. Tag exclusions (-NoNetwork/-NoTray/-Quick's
                 implied -NoNetwork) still apply on top of -Only.
   -Json         Prints the final report as compact JSON to stdout
                 instead of the human-readable table (the two report
                 files are always written either way).
   -SweepOnly    Acquires the run-all.lock as usual, runs ONLY the START
                 hygiene sweep (ports/stray-process/HKCU/tests\.tmp -
                 see Invoke-HygieneSweep), prints what it removed/
                 stopped, releases the lock, and exits 0 - no layers run
                 at all, no Pester import, no report files written.
                 Overrides -Only/-Quick/-NoNetwork/-NoTray/-Json (all
                 ignored when passed alongside -SweepOnly). Use this to
                 clean a build root (e.g. after a runaway nested-tree
                 decoy) without paying for a full or -Quick run.

 HYGIENE: every port this run might have touched (47899, 47890-47897) is
 checked and any owning process force-stopped, and tests\.tmp is swept
 to empty, in a top-level `finally` block regardless of outcome. A
 straggler TEST FurphyHost.exe process (test port or non-live exe path)
 or a leftover HKCU FurphyAddonManager.Test value is also checked and
 force-cleaned as a last-resort safety net - the owner's live tray and
 production Run value are never touched - independent of whatever cleanup the failing test itself attempted -
 logged loudly if it had to do anything, since that means some test's
 own `finally` did not run to completion.

 Runaway nested trees: a plain `Remove-Item -Recurse` cannot walk a
 self-nested scratch copy whose paths run far beyond 260 chars (seen for
 real 2026-09-08 - see Copy-FurphyAppFiles's own docstring in
 tests\lib\common.ps1 - 1,777 directory levels, cleaned up by hand with
 `robocopy <empty-dir> <target> /MIR` then Remove-Item on the emptied
 target). Every tests\.tmp entry the sweep removes now goes through
 Remove-DirectoryTreeSafely, which tries plain Remove-Item -Recurse
 first and only falls back to that same robocopy /MIR recipe when it
 fails or a cheap bounded probe finds a descendant path over 240 chars -
 see Remove-DirectoryTreeSafely's own docstring below. It never touches
 anything outside tests\.tmp.

 Orphaned WebView2 children: Stop-Process on a straggler FurphyHost.exe
 above does not cascade to its child msedgewebview2.exe process(es), so
 one can survive its parent host being force-stopped (seen for real with
 a --user-data-dir under tests\.tmp\host-unminimize-recovery-*). The same
 sweep therefore also stops any msedgewebview2.exe whose --user-data-dir
 is a path under THIS build root's tests\.tmp (path-prefix match on the
 normalized full path, case-insensitive) - see Get-StrayTestWebViewProcesses.
 It never touches the live install's own WebView2 children (their
 --user-data-dir is under Program Files, outside tests\.tmp, by
 construction) and it never touches a tests\.tmp\soak-* child while
 Test-SoakActive reports a Soak-Furphy.ps1 run's scratch root is still on
 disk (soak-owned WebView2 children are excluded outright, not just left
 for a human to notice - Soak-Furphy.ps1 stops its own on its own
 graceful teardown; this sweep must never race it).

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
    [switch]$Json,
    [switch]$SweepOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'lib\common.ps1')

$Script:RunAllLockPath = Join-Path $Script:FurphyTmpRoot 'run-all.lock'

function Test-ProcessAlive {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    try { Get-Process -Id $ProcessId -ErrorAction Stop | Out-Null; return $true } catch { return $false }
}

$existingLockOwner = $null
if (Test-Path -LiteralPath $Script:RunAllLockPath) {
    try { $existingLockOwner = [int]((Get-Content -LiteralPath $Script:RunAllLockPath -Raw -ErrorAction Stop).Trim()) } catch { $existingLockOwner = $null }
}
if ($existingLockOwner -and (Test-ProcessAlive -ProcessId $existingLockOwner)) {
    Write-Host "FATAL: another tests\run-all.ps1 (PID $existingLockOwner) already owns tests\.tmp\run-all.lock in this build root - two concurrent full runs collide on port 47899, the 47890-47897 static-server pool, the hygiene sweep, and FurphyHost.exe's per-port tray mutex. Wait for PID $existingLockOwner to finish, or if it is confirmed gone, delete tests\.tmp\run-all.lock and retry." -ForegroundColor Red
    exit 1
}
if (Test-PortOpen -Port 47899 -TimeoutMs 300) {
    Write-Host "FATAL: port 47899 is already LISTENING and no live run-all.ps1 owns tests\.tmp\run-all.lock - refusing to start rather than silently adopting or killing whatever is there. Free port 47899 first, then retry." -ForegroundColor Red
    exit 1
}
[string]$PID | Set-Content -LiteralPath $Script:RunAllLockPath -Encoding Ascii -Force

if (-not $SweepOnly) {
    try {
        Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop -Force
    } catch {
        Write-Host "FATAL: could not load Pester 3.4.0 ($($_.Exception.Message))" -ForegroundColor Red
        exit 1
    }
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

function Test-SoakActive {
    <#
      Detects whether a tests\perf\Soak-Furphy.ps1 run currently owns a
      scratch root under tests\.tmp. Soak-Furphy.ps1 has no separate
      pid/lock file - its own -Root defaults to New-TempRoot -Name 'soak'
      (tests\lib\common.ps1), which creates tests\.tmp\soak-<stamp>-<suffix>,
      and that directory is only ever removed in Soak-Furphy.ps1's OWN
      `finally` teardown (unless -KeepRoot - see its Remove-TempRoots /
      Remove-Item block), alongside its own msedgewebview2.exe children
      (its Stop-Process -Filter '*$Root*' block right before that). So a
      tests\.tmp\soak-* directory still existing on disk IS the soak's
      still-running / not-yet-torn-down marker - the same signal this
      build root's operator uses to know a soak is live.
    #>
    if (-not (Test-Path -LiteralPath $Script:FurphyTmpRoot)) { return $false }
    $soakDirs = @(Get-ChildItem -LiteralPath $Script:FurphyTmpRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'soak-*' })
    return ($soakDirs.Count -gt 0)
}

function Get-CommandLineSwitchValue {
    <#
      Pulls the value of a --name=value (or --name="quoted value") style
      switch out of a raw process command-line string. Returns $null if
      the switch is absent. Chromium/WebView2 processes always use the
      '=' form for --user-data-dir, quoting the value only when it
      contains a space - both are handled here.
    #>
    param([string]$CommandLine, [string]$SwitchName)
    if (-not $CommandLine) { return $null }
    $pattern = [regex]::Escape($SwitchName) + '=(?:"([^"]*)"|(\S+))'
    $m = [regex]::Match($CommandLine, $pattern)
    if (-not $m.Success) { return $null }
    if ($m.Groups[1].Success) { return $m.Groups[1].Value } else { return $m.Groups[2].Value }
}

function Test-PathUnderRoot {
    <#
      Case-insensitive path-prefix test: is $Path (a file/dir path, not
      necessarily existing on disk) equal to or nested under $Root, once
      both are resolved to normalized full paths? Used instead of a
      simple -like/-match string check so trailing slashes, '..' segments,
      and forward/back slash mixing in a process's own command-line value
      cannot slip a path that is NOT really under tests\.tmp past the
      filter (or vice versa).
    #>
    param([string]$Path, [string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    try {
        $pFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $rFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    } catch { return $false }
    return ($pFull.Equals($rFull, [System.StringComparison]::OrdinalIgnoreCase) -or
            $pFull.StartsWith($rFull + '\', [System.StringComparison]::OrdinalIgnoreCase))
}

function Test-PathUnderSoakRoot {
    <#
      True when $Path's FIRST path segment under $TmpRoot itself starts
      with 'soak-' (tests\.tmp\soak-<stamp>-<suffix>\..., any depth) -
      i.e. $Path is inside a Soak-Furphy.ps1 scratch root, not merely
      somewhere that happens to contain the substring 'soak-'. A plain
      Test-PathUnderRoot check against a Join-Path'd '...\tests\.tmp\soak-'
      root would NOT work here: it would require the next character after
      'soak-' to be a literal '\', which is never true for a real
      '...\soak-<stamp>-<suffix>' directory name, so this uses its own
      first-segment comparison instead.
    #>
    param([string]$Path, [string]$TmpRoot)
    if (-not $Path -or -not $TmpRoot) { return $false }
    try {
        $pFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $tFull = [System.IO.Path]::GetFullPath($TmpRoot).TrimEnd('\')
    } catch { return $false }
    if (-not $pFull.StartsWith($tFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    $firstSegment = $pFull.Substring($tFull.Length + 1).Split('\')[0]
    return ($firstSegment -like 'soak-*')
}

function Get-StrayTestWebViewProcesses {
    <#
      msedgewebview2.exe orphans left behind after a straggler TEST
      FurphyHost.exe was force-stopped elsewhere in this sweep -
      Stop-Process does not cascade to children, and one such orphan (its
      --user-data-dir under tests\.tmp\host-unminimize-recovery-*)
      survived a killed test host. Matches ONLY on a --user-data-dir path
      under THIS build root's tests\.tmp ($Script:FurphyTmpRoot, path-
      prefix, case-insensitive - see Test-PathUnderRoot); a process with
      no --user-data-dir, or one outside tests\.tmp entirely (the live
      install's own WebView2 children live under Program Files), is left
      alone. While Test-SoakActive is true, a --user-data-dir under
      tests\.tmp\soak-* is excluded outright (Test-PathUnderSoakRoot),
      regardless of the tests\.tmp match above - a running Soak-Furphy.ps1's
      own WebView2 children must never be touched here; it stops its own
      on its own teardown.
    #>
    $tmpRoot = $Script:FurphyTmpRoot
    $soakActive = Test-SoakActive

    $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue)
    $stray = @()
    foreach ($p in $procs) {
        $udd = Get-CommandLineSwitchValue -CommandLine ([string]$p.CommandLine) -SwitchName '--user-data-dir'
        if (-not $udd) { continue }
        if (-not (Test-PathUnderRoot -Path $udd -Root $tmpRoot)) { continue }
        if ($soakActive -and (Test-PathUnderSoakRoot -Path $udd -TmpRoot $tmpRoot)) { continue }
        $stray += $p
    }
    return $stray
}

function Test-PathTreeExceedsSafeDepth {
    <#
      Cheap, bounded probe for a runaway self-nested tree under $Path:
      returns $true if a descendant path is already over 240 chars (a
      conservative margin under the classic 260-char MAX_PATH limit that
      plain Remove-Item -Recurse cannot walk in PowerShell 5.1 - see the
      2026-09-08 incident: a self-nested scratch copy 1,777 directory
      levels deep, cleaned up by hand with robocopy /MIR), or if the
      enumeration itself throws (a PathTooLongException mid-walk is
      exactly the same signal, just surfaced as an error instead of a
      long string). -Depth is capped at 150: a normal tests\.tmp entry
      never nests anywhere near that deep, and 150 levels of even a
      single-character directory name alone already exceeds 240 chars,
      so a genuine runaway tree is always caught long before the cap -
      this keeps the probe cheap and bounded rather than a full recursive
      walk of a tree that might be enormous.
    #>
    param([string]$Path)
    try {
        $hit = Get-ChildItem -LiteralPath $Path -Recurse -Depth 150 -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -and $_.FullName.Length -gt 240 } |
            Select-Object -First 1
        return ($null -ne $hit)
    } catch {
        return $true
    }
}

function Remove-DirectoryTreeSafely {
    <#
      Removes one tests\.tmp entry (file or directory tree), tolerating a
      runaway self-nested tree that plain Remove-Item -Recurse cannot
      walk in PowerShell 5.1 (paths far beyond 260 chars - see the
      2026-09-08 incident referenced throughout this file and in
      Copy-FurphyAppFiles's own docstring in tests\lib\common.ps1).

      -Path MUST resolve under $Script:FurphyTmpRoot (tests\.tmp) - a
      hard guard, not just a convention: this function's fallback runs
      an external robocopy.exe /MIR against -Path, and that is only ever
      safe to do against a target this sweep already owns under
      tests\.tmp, never against an arbitrary caller-supplied path.

      Strategy:
        1. A plain file (or anything Get-Item can't stat, e.g. mid-
           delete by another process) has no runaway-tree case - a
           single Remove-Item -Force is enough.
        2. For a directory: if Test-PathTreeExceedsSafeDepth says a
           descendant is already too long, skip straight to the
           robocopy fallback (never even attempt Remove-Item -Recurse
           on a tree known to be pathological - it is the thing that
           could not be walked by hand on 2026-09-08). Otherwise try
           Remove-Item -Recurse -Force first (the fast, common case);
           any OTHER failure (locked file, permissions, ...) also falls
           back to robocopy rather than giving up.
        3. Fallback: create an empty scratch directory under
           tests\.tmp, run `robocopy.exe <empty> <target> /MIR /NFL
           /NDL /NJH /NJS /NP /R:1 /W:1` via the call operator (mirroring
           nothing onto the target recursively empties it - robocopy has
           its own long-path handling, unlike Remove-Item -Recurse; exit
           codes 0-7 are success, >=8 is a real failure), then
           Remove-Item both the now-empty target and the scratch mirror
           source.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-PathUnderRoot -Path $Path -Root $Script:FurphyTmpRoot)) {
        throw "Remove-DirectoryTreeSafely refuses a path outside tests\.tmp: $Path"
    }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or -not $item.PSIsContainer) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return
    }

    $tooDeep = Test-PathTreeExceedsSafeDepth -Path $Path
    $removed = $false
    if (-not $tooDeep) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            $removed = $true
        } catch {
            Write-Host "  WARN: Remove-Item -Recurse failed on $Path ($($_.Exception.Message)) - falling back to robocopy /MIR" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  WARN: $Path has a descendant path over 240 chars long - skipping Remove-Item -Recurse, falling back to robocopy /MIR" -ForegroundColor Yellow
    }

    if (-not $removed) {
        $scratchEmpty = Join-Path $Script:FurphyTmpRoot ('sweep-empty-' + [Guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $scratchEmpty -Force -ErrorAction Stop | Out-Null
            & robocopy.exe $scratchEmpty $Path /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
            $roboExit = $LASTEXITCODE
            if ($roboExit -ge 8) {
                throw "robocopy /MIR exit code $roboExit (>=8 is a real failure) mirroring an empty dir onto $Path"
            }
            if (Test-Path -LiteralPath $Path) {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            }
        } finally {
            if (Test-Path -LiteralPath $scratchEmpty) {
                Remove-Item -LiteralPath $scratchEmpty -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
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

    # Round 29 live-safety fix: only TEST trays/windows are stragglers. A test
    # instance is one launched with a test port (--port 4789x) or from a
    # non-live executable path (the build root, tests\.tmp, a scratch copy).
    # The owner's LIVE tray (the exe under the installed AddonSync folder,
    # no test port) must never be stopped by the test runner - it was, twice,
    # before this guard existed.
    #
    # Round 41 refix: the code above used to implement "non-live executable
    # path" as "-notlike '*\Program Files*'", which is not the same claim -
    # it also matches a completely different, legitimate, concurrent
    # FurphyHost.exe belonging to a DIFFERENT build root's own workflow
    # (e.g. a separate measurement setup under its own scratch root), which
    # is neither a straggler of THIS suite nor under Program Files. That
    # collision force-stopped exactly such a process. Narrowed to match the
    # comment's actual claim: a reserved test port, OR command
    # line/executable path actually under THIS build root's own tree
    # (covers both a root-level run and a scratch copy under this root's
    # own tests\.tmp, same as Start-TestServer/Copy-Fixture always place
    # them - see also Measure-Furphy.ps1's own "scope root" substring match
    # for the identical problem solved the same way elsewhere in this
    # suite). A different build root's own non-test FurphyHost.exe is now
    # correctly left alone alongside the real Program Files live tray.
    $allHosts = @(Get-CimInstance Win32_Process -Filter "Name='FurphyHost.exe'" -ErrorAction SilentlyContinue)
    $buildRootLower = $Script:FurphyBuildRoot.TrimEnd('\').ToLowerInvariant()
    $strayHost = @($allHosts | Where-Object {
        $cl = [string]$_.CommandLine; $ep = [string]$_.ExecutablePath
        ($cl -match '--port\s+4789\d') -or
            ([string]$cl).ToLowerInvariant().Contains($buildRootLower) -or
            ([string]$ep).ToLowerInvariant().Contains($buildRootLower)
    })
    $liveHosts = @($allHosts | Where-Object { $strayHost -notcontains $_ })
    if ($strayHost.Count -gt 0) {
        Write-Host "  WARN: $($strayHost.Count) straggler TEST FurphyHost.exe process(es) found - force-stopping" -ForegroundColor Yellow
        foreach ($p in $strayHost) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
    } else {
        Write-Host "  ok: no straggler test FurphyHost.exe process"
    }
    if ($liveHosts.Count -gt 0) { Write-Host "  info: $($liveHosts.Count) live FurphyHost.exe process(es) left alone (not test instances)" }

    # Orphaned WebView2 children of a straggler test host (Stop-Process
    # above does not cascade to them) - see Get-StrayTestWebViewProcesses'
    # own comment. Runs before the tests\.tmp directory sweep below so a
    # process still holding a --user-data-dir open there is gone first.
    $strayWebView = @(Get-StrayTestWebViewProcesses)
    if ($strayWebView.Count -gt 0) {
        Write-Host "  WARN: $($strayWebView.Count) orphaned TEST msedgewebview2.exe process(es) found under tests\.tmp - force-stopping" -ForegroundColor Yellow
        foreach ($p in $strayWebView) {
            Write-Host "    stopping pid $($p.ProcessId)"
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
    } else {
        Write-Host "  ok: no orphaned test msedgewebview2.exe process under tests\.tmp"
    }

    try {
        $runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        # Round 29 live-safety fix: tests only ever write the TEST value name
        # ("FurphyAddonManager.Test", see --tray-selftest). The production
        # value "FurphyAddonManager" belongs to the owner's own "Start with
        # Windows" setting and is never touched here.
        $existingTest = Get-ItemProperty -LiteralPath $runKeyPath -Name 'FurphyAddonManager.Test' -ErrorAction SilentlyContinue
        if ($null -ne $existingTest) {
            Write-Host "  WARN: HKCU Run still carries the TEST value FurphyAddonManager.Test - removing it" -ForegroundColor Yellow
            Remove-ItemProperty -LiteralPath $runKeyPath -Name 'FurphyAddonManager.Test' -ErrorAction SilentlyContinue
        } else {
            Write-Host "  ok: HKCU Run has no test value"
        }
        $prod = Get-ItemProperty -LiteralPath $runKeyPath -Name 'FurphyAddonManager' -ErrorAction SilentlyContinue
        if ($null -ne $prod) { Write-Host "  info: production Start-with-Windows value present - left alone" }
    } catch { }

    if (Test-Path -LiteralPath $Script:FurphyTmpRoot) {
        # Never sweep away THIS run's own run-all.lock, or a second
        # run-all.ps1 started moments later would see no lock and start
        # concurrently anyway - removed explicitly, once, after the run.
        $lockLeafName = Split-Path -Path $Script:RunAllLockPath -Leaf
        # A live Soak-Furphy.ps1 run's own scratch root (tests\.tmp\soak-*)
        # is never swept while Test-SoakActive reports it still on disk -
        # see that function's own docstring and the header comment's
        # "this sweep must never race it" note; Soak-Furphy.ps1 tears its
        # own root (and its own WebView2 children) down itself.
        $soakActiveForSweep = Test-SoakActive
        $allTmpItems = @(Get-ChildItem -LiteralPath $Script:FurphyTmpRoot -Force -ErrorAction SilentlyContinue)
        $sweepItems = @($allTmpItems | Where-Object {
            ($_.Name -ne $lockLeafName) -and
            -not ($soakActiveForSweep -and (Test-PathUnderSoakRoot -Path $_.FullName -TmpRoot $Script:FurphyTmpRoot))
        })
        $skippedSoakCount = if ($soakActiveForSweep) { @($allTmpItems | Where-Object { $_.Name -like 'soak-*' }).Count } else { 0 }
        foreach ($item in $sweepItems) {
            try { Remove-DirectoryTreeSafely -Path $item.FullName } catch {
                Write-Host "  WARN: could not remove $($item.FullName): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        $soakNote = if ($skippedSoakCount -gt 0) { "; $skippedSoakCount soak-* root(s) left alone (soak active)" } else { '' }
        Write-Host "  ok: tests\.tmp swept ($($sweepItems.Count) item(s) found, removed where possible; run-all.lock preserved$soakNote)"
    }
}

# Review fix: run the sweep once BEFORE anything starts, not only in the
# trailing `finally` below - see the header comment's "Review fix" note
# and Start-TestServer's matching pre-flight port check.
Invoke-HygieneSweep -Label 'Hygiene sweep (pre-flight)'

if ($SweepOnly) {
    # -SweepOnly: the sweep above IS the whole run - acquire the lock as
    # usual (already done), run the START sweep (already done, right
    # above - it already printed everything removed/stopped), release
    # the lock, and exit 0. No layers, no Pester, no report files.
    Remove-Item -LiteralPath $Script:RunAllLockPath -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "SweepOnly: hygiene sweep complete, no test layers run." -ForegroundColor Green
    exit 0
}

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
# spa (harness always; the 16-theme screenshot+contrast audit is
# full-run-only - real per-theme msedge launches, not part of Quick's
# <4-minute budget)
# =====================================================================
if ($layersToRun -contains 'spa') {
    $layer = New-LayerReport -Name 'spa'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-ScriptCheck -Layer $layer -Path (Join-Path $Script:FurphyTestsRoot 'spa\Run-SpaHarness.ps1') -DisplayName 'spa: Run-SpaHarness' -TimeoutSec 300
    if (-not $Quick) {
        Invoke-ScriptCheck -Layer $layer -Path (Join-Path $Script:FurphyTestsRoot 'spa\Run-ThemeAudit.ps1') -DisplayName 'spa: Run-ThemeAudit (16 themes, full-only)' -TimeoutSec 300
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
# header comment for the exact timeline). Round 40 added a total-CPU
# assertion to the existing minimized/tray It plus a new It that measures
# the window OPEN and FOCUSED (no minimize) - both are just more Its in
# Perf.Tests.ps1, so Invoke-PesterLayer below picks them up automatically;
# nothing extra to register here.
#
# EXCLUDED FROM THE GATE, ON PURPOSE: tests\perf\Soak-Furphy.ps1 (round 40,
# soak:SOAK-SCOPE-1) is a standalone, non-assertion script meant to run
# unattended for up to 2 hours and produce a CSV + summary for a human to
# read - never a pass/fail check. Invoke-PesterLayer below only ever
# discovers *.Tests.ps1 files (Pester 3.4.0's own -Script directory
# convention - see Invoke-PesterLayer's own comment), and Soak-Furphy.ps1
# is deliberately named to NOT match that pattern, so it is excluded
# automatically, by construction, not by an explicit skip list here. Never
# add a call to it from this file.
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
    try { Remove-Item -LiteralPath $Script:RunAllLockPath -Force -ErrorAction SilentlyContinue } catch { }
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
