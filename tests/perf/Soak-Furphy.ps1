<#
=====================================================================
 tests\perf\Soak-Furphy.ps1

 Round 40 fix for QA-FINDINGS-LENSES-3.md's soak:SOAK-SCOPE-1 (MEDIUM):
 the requested 2-hour soak only ran ~5 real minutes before the harness
 force-finalized that session, so no leak/growth signal, no repeated-
 maintenance-cycle signal, and no multi-cycle background-sync signal was
 ever gathered. This is the reusable, repeatable script that gap asked
 for - a plain standalone .ps1 (deliberately NOT named *.Tests.ps1, so
 tests\run-all.ps1's Invoke-PesterLayer, which only ever discovers
 *.Tests.ps1 files under a layer directory, can never pick this up by
 accident - see that file's own "EXCLUDED FROM THE GATE" note next to
 its perf-layer registration). Nothing here is a pass/fail assertion;
 this produces data (CSV + a summary) for a human to read.

 WHAT IT DOES
   Builds its own fully isolated scratch app root (own copy of
   addon-sync.ps1/addon-server.ps1/ui\/host\bin\, own settings.json/
   flavours\retail\addons.json, own port), starts a real addon-server.ps1
   and a real FurphyHost.exe --tray against it, points the CurseForge-
   catalogue and Wago-growth network seams at local stub servers (so a
   multi-hour unattended run makes zero real internet calls other than
   the CurseForge-per-addon check - which does nothing at all here since
   the scratch addons.json starts empty, unless -SeedAddonsJsonPath is
   given), then samples every Furphy-scoped process under ITS OWN
   scratch root (never the whole build root - see Get-SoakRole's own
   comment) every -SampleIntervalMinutes for -Minutes, recording CPU/
   working set/handle count/thread count per process plus server.log/
   host.log/sync.log size, jobs\/cache\ file count and bytes, and
   tray-state.json's raw content (so a human can see whether/when it
   changed - the soak's own multi-cycle background-sync signal).

 LIVE-SAFETY (this build round's hard rules): never touches the live
 install, the live Run value, the live Uninstall key, port 47831, or
 event FurphyAddonManager.TrayStop. Refuses outright to run against
 port 47831 or 47899 (the former is production, the latter is
 tests\run-all.ps1's own reserved port - see that file's own port-47899
 comment). Checks Test-RealWowClientRunning before ever starting a
 native FurphyHost.exe process (tray included) and exits early with a
 clear message instead if a real WoW client is running on this machine,
 exactly like tests\host\Host.Tests.ps1's own live-window test does.
 Prints a read-only production snapshot (Run value / live FurphyHost.exe
 pids / install folder file count / Uninstall key) at start and end,
 purely informational - this script never writes to any of them.

 USAGE
   tests\perf\Soak-Furphy.ps1 -Minutes 120 -Port 47903
   tests\perf\Soak-Furphy.ps1 -Minutes 10 -Port 47904 -SampleIntervalMinutes 2   (quick smoke test)

 PARAMS
   -Minutes                 Total wall-clock duration. Default 120 (the
                             brief's own 2-hour ask).
   -Port                    Scratch addon-server.ps1/tray port. Default
                             47903 (matches this finding's own fixNote).
                             Refuses 47831/47899 outright (see above).
   -SampleIntervalMinutes   Minutes between samples. Default 5 (24
                             samples over a 120-minute run, matching the
                             brief's own "24 samples at 5-min intervals").
   -Root                    Scratch app root. Default a fresh
                             tests\.tmp\soak-... directory (New-TempRoot).
                             Never any path under the live install or the
                             real Desktop.
   -SeedAddonsJsonPath      Optional path to a JSON file to seed
                             flavours\retail\addons.json with (must
                             already be a local file the caller supplies
                             - this script never reads from the live
                             install's own addons.json itself). Default:
                             empty list ('[]'), same as
                             tests\perf\Perf.Tests.ps1's New-PerfAppRoot.
   -OutDir                  Where to write the CSV/summary files.
                             Default tests\perf\soak next to this script.
   -KeepRoot                Don't delete the scratch app root at the end
                             (useful for inspecting host.log/server.log/
                             cache\ by hand after a run).
   -BackgroundIntervalMinutes  Passed straight into settings.json's own
                             backgroundIntervalMinutes. Default 1440
                             (matches live/production) - the maintenance
                             child's own separate ~60-minute interval
                             (round 37 mechanism, unrelated to this
                             setting) is what actually gives a 120-minute
                             run more than one background-refresh sample
                             to observe.
=====================================================================
#>

param(
    [int]$Minutes = 120,
    [int]$Port = 47903,
    [int]$SampleIntervalMinutes = 5,
    [string]$Root,
    [string]$SeedAddonsJsonPath,
    [string]$OutDir,
    [switch]$KeepRoot,
    [int]$BackgroundIntervalMinutes = 1440
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $PSScriptRoot '..\fixtures\wago-stub\WagoStubHelpers.ps1')

# ---------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------

if ($Minutes -le 0) { throw "Soak-Furphy: -Minutes must be positive (got $Minutes)" }
if ($SampleIntervalMinutes -le 0) { throw "Soak-Furphy: -SampleIntervalMinutes must be positive (got $SampleIntervalMinutes)" }
if ($Port -eq 47831) { throw 'Soak-Furphy: refusing to run against port 47831 - that is the real production port, never a test port.' }
if ($Port -eq 47899) { throw 'Soak-Furphy: refusing to run against port 47899 - that port is reserved for tests\run-all.ps1''s own verifier run. Pick a scratch port instead (default 47903).' }

function Test-RealWowClientRunning {
    <#
      Own local copy - see tests\host\Host.Tests.ps1's Test-RealWowClientRunning
      for the full rationale. Mirrors addon-server.ps1's Test-GameRunning /
      host\FurphyHost.cs's WowDetector.IsRunning name list exactly.
    #>
    $names = @('Wow', 'Wow-64', 'WowClassic', 'WowClassicT', 'WowClassicB', 'WowT', 'WowB')
    foreach ($n in $names) {
        try {
            $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
            if ($procs -and @($procs).Count -gt 0) { return $true }
        } catch { }
    }
    return $false
}

if (Test-RealWowClientRunning) {
    Write-Host 'Soak-Furphy: a real WoW client process is running on this machine - refusing to start a native FurphyHost.exe --tray process. Close WoW (or the fake-process-name test hooks used elsewhere in this suite do not apply here, by design - this script measures real idle/background behaviour, not a fake-WoW scenario) and re-run.'
    exit 1
}

$Script:HostBinDir = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'host\bin'
$Script:HostCsPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'host\FurphyHost.cs'
$Script:HostExeSourcePath = Join-Path -Path $Script:HostBinDir -ChildPath 'FurphyHost.exe'

function Ensure-SoakHostBuilt {
    $needsBuild = $false
    if (-not (Test-Path -LiteralPath $Script:HostExeSourcePath -PathType Leaf)) {
        $needsBuild = $true
    } elseif ((Get-Item -LiteralPath $Script:HostCsPath).LastWriteTimeUtc -gt (Get-Item -LiteralPath $Script:HostExeSourcePath).LastWriteTimeUtc) {
        $needsBuild = $true
    }
    if ($needsBuild) {
        Write-Host 'Soak-Furphy: building host\bin\FurphyHost.exe (missing or stale)...'
        & (Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'host\build-host.ps1')
    }
    return (Test-Path -LiteralPath $Script:HostExeSourcePath -PathType Leaf)
}

if (-not (Ensure-SoakHostBuilt)) {
    Write-Host 'Soak-Furphy: host\bin\FurphyHost.exe could not be built - cannot start a --tray process. Aborting.'
    exit 1
}

# ---------------------------------------------------------------------
# Read-only production snapshot (never written to - see header comment)
# ---------------------------------------------------------------------

function Get-ProductionSnapshot {
    $snap = [ordered]@{
        RunValue      = $null
        HostPids      = @()
        InstallFileCount = $null
        UninstallVersion = $null
    }
    try {
        $snap.RunValue = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'FurphyAddonManager' -ErrorAction Stop).FurphyAddonManager
    } catch { }
    try {
        $snap.HostPids = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='FurphyHost.exe'" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessId)
    } catch { }
    try {
        $liveDest = 'C:\Program Files (x86)\World of Warcraft\_retail_\AddonSync'
        if (Test-Path -LiteralPath $liveDest) {
            $snap.InstallFileCount = (Get-ChildItem -LiteralPath $liveDest -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object).Count
        }
    } catch { }
    try {
        $snap.UninstallVersion = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FurphyAddonManager' -ErrorAction Stop).DisplayVersion
    } catch { }
    return [PSCustomObject]$snap
}

function Write-ProductionSnapshot {
    param([string]$Label, $Snap)
    Write-Host "Soak-Furphy: production snapshot ($Label): Run='$($Snap.RunValue)' HostPids=[$($Snap.HostPids -join ',')] InstallFileCount=$($Snap.InstallFileCount) UninstallVersion=$($Snap.UninstallVersion)"
}

$prodBefore = Get-ProductionSnapshot
Write-ProductionSnapshot -Label 'BEFORE' -Snap $prodBefore

# ---------------------------------------------------------------------
# Scratch app root
# ---------------------------------------------------------------------

if (-not $Root) { $Root = New-TempRoot -Name 'soak' }
if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
if (-not $OutDir) { $OutDir = Join-Path -Path $PSScriptRoot -ChildPath 'soak' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

Write-Host "Soak-Furphy: scratch root = $Root"
Write-Host "Soak-Furphy: output dir   = $OutDir"

Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination (Join-Path $Root 'addon-sync.ps1') -Force
Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1') -Destination (Join-Path $Root 'addon-server.ps1') -Force
Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'ui') -Destination (Join-Path $Root 'ui') -Recurse -Force
$binDst = Join-Path $Root 'host\bin'
New-Item -ItemType Directory -Path $binDst -Force | Out-Null
Get-ChildItem -LiteralPath $Script:HostBinDir -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $binDst -Recurse -Force }

New-Item -ItemType Directory -Path (Join-Path $Root 'flavours\retail') -Force | Out-Null
if ($SeedAddonsJsonPath) {
    if (-not (Test-Path -LiteralPath $SeedAddonsJsonPath -PathType Leaf)) {
        throw "Soak-Furphy: -SeedAddonsJsonPath not found: $SeedAddonsJsonPath"
    }
    Copy-Item -LiteralPath $SeedAddonsJsonPath -Destination (Join-Path $Root 'flavours\retail\addons.json') -Force
} else {
    '[]' | Set-Content -LiteralPath (Join-Path $Root 'flavours\retail\addons.json') -Encoding UTF8
}

$settings = [ordered]@{
    releaseType = 1; port = $Port; adFilter = $true; cfFocus = $true
    hostWindow = $null; hostTheme = $null; backgroundUpdates = $true; backgroundIntervalMinutes = $BackgroundIntervalMinutes
    runAtStartup = $false; schemaVersion = 2; activeFlavour = 'retail'; showTestRealms = $false
}
($settings | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $Root 'settings.json') -Encoding UTF8

$hostExe = Join-Path $Root 'host\bin\FurphyHost.exe'
$serverLogPath = Join-Path $Root 'server.log'
$hostLogPath = Join-Path $Root 'host.log'
$syncLogPath = Join-Path $Root 'sync.log'
$trayStatePath = Join-Path $Root 'tray-state.json'
$jobsDir = Join-Path $Root 'jobs'
$cacheDir = Join-Path $Root 'cache'

# ---------------------------------------------------------------------
# Stubs (zero real internet traffic for the whole run other than a
# per-addon CurseForge check, which does nothing here - see header)
# ---------------------------------------------------------------------

$cfStub = $null
$wagoStub = $null
$server = $null
$trayProc = $null

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$csvProcPath = Join-Path -Path $OutDir -ChildPath "soak-processes-$stamp.csv"
$csvSystemPath = Join-Path -Path $OutDir -ChildPath "soak-system-$stamp.csv"
$summaryPath = Join-Path -Path $OutDir -ChildPath "soak-summary-$stamp.md"

$procRows = New-Object 'System.Collections.Generic.List[object]'
$systemRows = New-Object 'System.Collections.Generic.List[object]'
$errors = New-Object 'System.Collections.Generic.List[string]'
$lastTrayState = $null
$trayStateChangeCount = 0
$trayStateChangeLog = New-Object 'System.Collections.Generic.List[string]'
$seenPids = New-Object 'System.Collections.Generic.HashSet[int]'
$vanishedPids = New-Object 'System.Collections.Generic.List[string]'

function Get-SoakRole {
    <#
      Same shape as tests\perf\Measure-Furphy.ps1's Get-FurphyRole, but
      scoped to THIS SCRIPT'S OWN scratch -Root path only (not the whole
      build root) - a 2-hour run can easily overlap other fixers'/the
      verifier's own scratch app roots elsewhere under the shared build
      root's tests\.tmp\, and this script must never sample (or, worse,
      ever be tempted to touch) a process it does not own.
    #>
    param([string]$Name, [string]$CommandLine, [string]$ExecutablePath)

    $cl = if ($CommandLine) { $CommandLine } else { '' }
    $exe = if ($ExecutablePath) { $ExecutablePath } else { '' }
    $clLower = $cl.ToLowerInvariant()
    $exeLower = $exe.ToLowerInvariant()
    $rootLower = $Root.ToLowerInvariant()
    $inRoot = $clLower.Contains($rootLower) -or $exeLower.Contains($rootLower)
    if (-not $inRoot) { return $null }

    switch -Regex ($Name) {
        '^powershell(\.exe)?$' {
            # The round-37 "-MaintenanceOnly child" is a genuinely
            # short-lived (fires, does its cache refresh, exits within
            # ~1s) hidden child of the SAME addon-server.ps1 script the
            # real long-running server also runs from - confirmed live
            # while writing this script: without this branch, its expected
            # exit gets misclassified as role 'server' and trips the
            # vanished-pid WARNING in Invoke-SoakSample, which is meant to
            # catch the real long-running server dying unexpectedly, not
            # this by-design one-shot child.
            if ($clLower -match '[\\"'']addon-server\.ps1' -and $clLower -match '-maintenanceonly') { return 'maintenance-child' }
            if ($clLower -match '[\\"'']addon-server\.ps1') { return 'server' }
            if ($clLower -match '[\\"'']addon-sync\.ps1') { return 'sync-cli-job' }
            return $null
        }
        '^furphyhost(\.exe)?$' {
            if ($clLower -match '(^|\s)--tray(\s|$)') { return 'host-tray' }
            return 'host-window'
        }
        '^msedgewebview2(\.exe)?$' { return 'webview2-child' }
        default { return $null }
    }
}

function Get-DirFileStats {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [PSCustomObject]@{ FileCount = 0; TotalBytes = 0 }
    }
    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue)
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    return [PSCustomObject]@{ FileCount = $files.Count; TotalBytes = [long]$bytes }
}

function Get-FileSizeOrZero {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-Item -LiteralPath $Path).Length }
    return 0
}

function Invoke-SoakSample {
    param([int]$ElapsedMinutes)

    $sampleTimeUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    # --- per-process row ---
    $procs = $null
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='FurphyHost.exe' OR Name='msedgewebview2.exe'" -ErrorAction Stop
    } catch {
        $errors.Add("[$sampleTimeUtc] Get-CimInstance Win32_Process failed: $($_.Exception.Message)")
        $procs = @()
    }

    $thisSamplePids = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($p in @($procs)) {
        $role = Get-SoakRole -Name $p.Name -CommandLine $p.CommandLine -ExecutablePath $p.ExecutablePath
        if (-not $role) { continue }

        [void]$thisSamplePids.Add([int]$p.ProcessId)
        [void]$seenPids.Add([int]$p.ProcessId)

        $cpuSeconds = 0.0
        try {
            $cpu100ns = 0.0
            if ($p.UserModeTime) { $cpu100ns += [double]$p.UserModeTime }
            if ($p.KernelModeTime) { $cpu100ns += [double]$p.KernelModeTime }
            $cpuSeconds = [math]::Round($cpu100ns / 1e7, 3)
        } catch { }

        $handleCount = $null
        $threadCount = $null
        try {
            $liveProc = Get-Process -Id $p.ProcessId -ErrorAction Stop
            $handleCount = $liveProc.HandleCount
            $threadCount = @($liveProc.Threads).Count
        } catch {
            # Process exited between the CIM read above and this Get-Process
            # call - record what we have (CPU/WS from the CIM snapshot),
            # leave handle/thread blank rather than failing the whole sample.
        }

        $procRows.Add([PSCustomObject]@{
            SampleTimeUtc  = $sampleTimeUtc
            ElapsedMinutes = $ElapsedMinutes
            ProcessId      = [int]$p.ProcessId
            Name           = $p.Name
            Role           = $role
            CumulativeCpuSeconds = $cpuSeconds
            WorkingSetBytes = [long]$(if ($p.WorkingSetSize) { $p.WorkingSetSize } else { 0 })
            HandleCount    = $handleCount
            ThreadCount    = $threadCount
        })
    }

    # A pid seen in an earlier sample but absent from this one, while the
    # role it belonged to is still expected to be alive (server/tray were
    # both still running when this sample was taken) - flag it. A single
    # webview2-child cycling is normal; a server/host-tray disappearing is
    # not and is exactly the kind of thing a 2-hour soak exists to catch.
    if ($seenPids.Count -gt 0) {
        $priorRoleByPid = @{}
        foreach ($r in $procRows) { $priorRoleByPid[[int]$r.ProcessId] = $r.Role }
        foreach ($deadPid in @($seenPids)) {
            if (-not $thisSamplePids.Contains($deadPid) -and $priorRoleByPid.ContainsKey($deadPid)) {
                $role = $priorRoleByPid[$deadPid]
                if ($role -eq 'server' -or $role -eq 'host-tray') {
                    $msg = "[$sampleTimeUtc] pid $deadPid (role=$role) was present in an earlier sample and is now GONE"
                    if (-not ($vanishedPids -contains $msg)) {
                        $vanishedPids.Add($msg)
                    }
                }
                [void]$seenPids.Remove($deadPid)
            }
        }
    }

    # --- system row (logs/jobs/cache/tray-state) ---
    $jobStats = Get-DirFileStats -Path $jobsDir
    $cacheStats = Get-DirFileStats -Path $cacheDir
    $trayStateNow = if (Test-Path -LiteralPath $trayStatePath) { Get-Content -LiteralPath $trayStatePath -Raw -ErrorAction SilentlyContinue } else { $null }
    $trayStateChanged = $false
    if ($null -ne $lastTrayState -and $trayStateNow -ne $lastTrayState) {
        $trayStateChanged = $true
        $trayStateChangeCount++
        $trayStateChangeLog.Add("[$sampleTimeUtc] tray-state.json changed")
    }
    $lastTrayState = $trayStateNow

    $systemRows.Add([PSCustomObject]@{
        SampleTimeUtc     = $sampleTimeUtc
        ElapsedMinutes    = $ElapsedMinutes
        ServerLogBytes    = Get-FileSizeOrZero -Path $serverLogPath
        HostLogBytes      = Get-FileSizeOrZero -Path $hostLogPath
        SyncLogBytes      = Get-FileSizeOrZero -Path $syncLogPath
        JobsFileCount     = $jobStats.FileCount
        JobsTotalBytes    = $jobStats.TotalBytes
        CacheFileCount    = $cacheStats.FileCount
        CacheTotalBytes   = $cacheStats.TotalBytes
        TrayStateChanged  = $trayStateChanged
        TrayStatePresent  = ($null -ne $trayStateNow)
    })

    Write-Host ("Soak-Furphy: sample @ {0}min ({1} processes, tray-state {2})" -f $ElapsedMinutes, $thisSamplePids.Count, $(if ($trayStateChanged) { 'CHANGED' } else { 'unchanged' }))
}

try {
    $cfPort = Get-FreeStaticPort
    $cfStub = Start-CfCatalogueStubServer -Port $cfPort
    Write-Host "Soak-Furphy: CF catalogue stub up on $($cfStub.BaseUrl)"

    $wagoPort = Get-FreeStaticPort
    # -DefaultFile is a bare filename resolved against WagoStubHelpers.ps1's
    # own -PagesDir (tests\fixtures\wago-stub\pages\), NOT a path - confirmed
    # live while writing this script (a full path here makes the stub
    # subprocess fail to come up at all, silently, since Start-WagoStubServer
    # only ever surfaces a generic "did not come up in time" from the
    # Wait-Port timeout either way).
    $wagoStub = Start-WagoStubServer -Port $wagoPort -DefaultFile 'default-retail-page1.json'
    Write-Host "Soak-Furphy: Wago stub up on $($wagoStub.BaseUrl)"

    $wowRoot = Copy-Fixture -Destination (New-TempRoot -Name 'soak-wowroot')

    $env:FURPHY_TEST_CF_CATALOGUE_BASEURL = $cfStub.BaseUrl
    $env:FURPHY_TEST_WAGO_BASEURL = $wagoStub.BaseUrl
    try {
        $server = Start-TestServer -Root $Root -Port $Port -WowRoot $wowRoot -IdleMinutes ([Math]::Max(60, $Minutes + 30))
    } finally {
        Remove-Item Env:\FURPHY_TEST_CF_CATALOGUE_BASEURL -ErrorAction SilentlyContinue
        Remove-Item Env:\FURPHY_TEST_WAGO_BASEURL -ErrorAction SilentlyContinue
    }
    Write-Host "Soak-Furphy: server up on port $Port (pid=$($server.Process.Id))"

    $trayProc = Start-Process -FilePath $hostExe -ArgumentList @('--port', [string]$Port, '--tray') -PassThru
    Write-Host "Soak-Furphy: tray up (pid=$($trayProc.Id))"

    $runStart = Get-Date
    $runEnd = $runStart.AddMinutes($Minutes)
    $sampleNum = 0

    Invoke-SoakSample -ElapsedMinutes 0
    $sampleNum++

    while ((Get-Date) -lt $runEnd) {
        $nextSampleAt = $runStart.AddMinutes($sampleNum * $SampleIntervalMinutes)
        $sleepSec = [int]([Math]::Max(1, ($nextSampleAt - (Get-Date)).TotalSeconds))
        $remainingSec = [int]([Math]::Max(0, ($runEnd - (Get-Date)).TotalSeconds))
        if ($remainingSec -le 0) { break }
        $sleepSec = [Math]::Min($sleepSec, $remainingSec)
        if ($sleepSec -gt 0) { Start-Sleep -Seconds $sleepSec }
        if ((Get-Date) -ge $runEnd) {
            Invoke-SoakSample -ElapsedMinutes ([math]::Round(((Get-Date) - $runStart).TotalMinutes, 1))
            break
        }
        Invoke-SoakSample -ElapsedMinutes ([math]::Round(((Get-Date) - $runStart).TotalMinutes, 1))
        $sampleNum++
    }

    $actualMinutes = [math]::Round(((Get-Date) - $runStart).TotalMinutes, 1)

    # --- write CSVs ---
    if ($procRows.Count -gt 0) {
        $procRows | Export-Csv -LiteralPath $csvProcPath -NoTypeInformation -Encoding UTF8
    }
    if ($systemRows.Count -gt 0) {
        $systemRows | Export-Csv -LiteralPath $csvSystemPath -NoTypeInformation -Encoding UTF8
    }

    # --- write summary ---
    $md = New-Object 'System.Collections.Generic.List[string]'
    $md.Add('# Furphy soak run')
    $md.Add('')
    $md.Add("Requested: $Minutes minutes, sampled every $SampleIntervalMinutes minutes. Actual: $actualMinutes minutes, $($systemRows.Count) samples.")
    $md.Add("Scratch root: $Root")
    $md.Add("Port: $Port")
    $md.Add('')
    if ($actualMinutes -lt ($Minutes * 0.95)) {
        $md.Add("**SCOPE CAVEAT: this run ended early ($actualMinutes of $Minutes requested minutes) - treat any growth/leak signal below as partial, not conclusive.**")
        $md.Add('')
    }

    $md.Add('## Per-role CPU/working-set (first sample vs last sample)')
    $md.Add('')
    $md.Add('| Role | First CPU-s | Last CPU-s | CPU-s consumed over run | First WS (MB) | Last WS (MB) | Peak WS (MB) | First handles | Last handles | First threads | Last threads |')
    $md.Add('|---|---|---|---|---|---|---|---|---|---|---|')
    $roles = @($procRows | Select-Object -ExpandProperty Role -Unique)
    foreach ($role in $roles) {
        $rows = @($procRows | Where-Object { $_.Role -eq $role } | Sort-Object SampleTimeUtc)
        if ($rows.Count -eq 0) { continue }
        $first = $rows[0]
        $last = $rows[-1]
        $peakWs = ($rows | Measure-Object -Property WorkingSetBytes -Maximum).Maximum
        $cpuConsumed = [math]::Round(($last.CumulativeCpuSeconds - $first.CumulativeCpuSeconds), 3)
        $md.Add("| $role | $($first.CumulativeCpuSeconds) | $($last.CumulativeCpuSeconds) | $cpuConsumed | $([math]::Round($first.WorkingSetBytes/1MB,2)) | $([math]::Round($last.WorkingSetBytes/1MB,2)) | $([math]::Round($peakWs/1MB,2)) | $($first.HandleCount) | $($last.HandleCount) | $($first.ThreadCount) | $($last.ThreadCount) |")
    }
    $md.Add('')
    $md.Add('A steadily climbing "Last WS" or "Last handles" well past "First" for server/host-tray across a genuinely multi-hour run is the leak signal this soak exists to catch - a single run cannot prove "no leak" on its own, but a clean flat line across several independent runs is good evidence.')
    $md.Add('')

    $md.Add('## Log / jobs / cache growth (first sample vs last sample)')
    $md.Add('')
    if ($systemRows.Count -gt 0) {
        $firstSys = $systemRows[0]
        $lastSys = $systemRows[-1]
        $md.Add('| Metric | First | Last | Growth |')
        $md.Add('|---|---|---|---|')
        $md.Add("| server.log bytes | $($firstSys.ServerLogBytes) | $($lastSys.ServerLogBytes) | $($lastSys.ServerLogBytes - $firstSys.ServerLogBytes) |")
        $md.Add("| host.log bytes | $($firstSys.HostLogBytes) | $($lastSys.HostLogBytes) | $($lastSys.HostLogBytes - $firstSys.HostLogBytes) |")
        $md.Add("| sync.log bytes | $($firstSys.SyncLogBytes) | $($lastSys.SyncLogBytes) | $($lastSys.SyncLogBytes - $firstSys.SyncLogBytes) |")
        $md.Add("| jobs\ file count | $($firstSys.JobsFileCount) | $($lastSys.JobsFileCount) | $($lastSys.JobsFileCount - $firstSys.JobsFileCount) |")
        $md.Add("| jobs\ total bytes | $($firstSys.JobsTotalBytes) | $($lastSys.JobsTotalBytes) | $($lastSys.JobsTotalBytes - $firstSys.JobsTotalBytes) |")
        $md.Add("| cache\ file count | $($firstSys.CacheFileCount) | $($lastSys.CacheFileCount) | $($lastSys.CacheFileCount - $firstSys.CacheFileCount) |")
        $md.Add("| cache\ total bytes | $($firstSys.CacheTotalBytes) | $($lastSys.CacheTotalBytes) | $($lastSys.CacheTotalBytes - $firstSys.CacheTotalBytes) |")
    } else {
        $md.Add('(no samples collected)')
    }
    $md.Add('')

    $md.Add('## tray-state.json transitions (multi-cycle background-sync signal)')
    $md.Add('')
    $md.Add("$trayStateChangeCount change(s) observed across the run.")
    if ($trayStateChangeLog.Count -gt 0) {
        $md.Add('')
        foreach ($line in $trayStateChangeLog) { $md.Add("- $line") }
    }
    $md.Add('')

    $md.Add('## Process-stability notes')
    $md.Add('')
    if ($vanishedPids.Count -eq 0 -and $errors.Count -eq 0) {
        $md.Add('No unexpected server/host-tray process disappearances or sampling errors during this run.')
    } else {
        foreach ($v in $vanishedPids) { $md.Add("- WARNING: $v") }
        foreach ($e in $errors) { $md.Add("- sampling error: $e") }
    }
    $md.Add('')

    $md.Add('## Files')
    $md.Add('')
    $md.Add("Per-process samples: $csvProcPath")
    $md.Add("Per-sample system/log/cache/tray-state: $csvSystemPath")

    ($md -join [Environment]::NewLine) | Set-Content -LiteralPath $summaryPath -Encoding UTF8

    Write-Host ''
    Write-Host "Soak-Furphy: done. $($systemRows.Count) samples over $actualMinutes minutes."
    Write-Host "Soak-Furphy: wrote $csvProcPath"
    Write-Host "Soak-Furphy: wrote $csvSystemPath"
    Write-Host "Soak-Furphy: wrote $summaryPath"
} finally {
    Write-Host 'Soak-Furphy: tearing down...'
    if ($trayProc -and -not $trayProc.HasExited) {
        try { Stop-Process -Id $trayProc.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    Start-Sleep -Milliseconds 500
    try {
        Get-Process -Name 'msedgewebview2' -ErrorAction SilentlyContinue | Where-Object {
            (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like "*$Root*"
        } | Stop-Process -Force -ErrorAction SilentlyContinue
    } catch { }
    Stop-TestServer -Server $server
    Stop-WagoStubServer -Stub $wagoStub
    Stop-StaticServer -Server $cfStub
    if ($cfStub -and $cfStub.Directory -and (Test-Path -LiteralPath $cfStub.Directory)) {
        Remove-Item -LiteralPath $cfStub.Directory -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $KeepRoot) {
        Remove-TempRoots
        if (Test-Path -LiteralPath $Root) {
            Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "Soak-Furphy: -KeepRoot set - scratch root left at $Root"
    }

    $prodAfter = Get-ProductionSnapshot
    Write-ProductionSnapshot -Label 'AFTER' -Snap $prodAfter
    if ($prodAfter.RunValue -ne $prodBefore.RunValue -or $prodAfter.InstallFileCount -ne $prodBefore.InstallFileCount -or $prodAfter.UninstallVersion -ne $prodBefore.UninstallVersion) {
        Write-Host 'Soak-Furphy: WARNING - production snapshot differs before vs after. This script never writes to any of these; investigate what else touched them.'
    }
}
