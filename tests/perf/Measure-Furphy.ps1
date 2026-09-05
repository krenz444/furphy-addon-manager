<#
=====================================================================
 tests\perf\Measure-Furphy.ps1

 P0 performance bench for Eric's "zero impact on gameplay" pass. Samples
 every live Furphy process every -SampleIntervalSec (default 2s) for
 -DurationSec (default 60s) and reports, per process: CPU seconds
 consumed over the window, peak/average working set, disk IO bytes,
 and the count of new outbound TCP connections it opened - plus the
 server's own request count in the same window, read from its
 server.log. Writes tests\perf\bench\<Label>-<stamp>.json and .md.

 This script only OBSERVES - it starts nothing itself. The caller is
 responsible for getting the app into the state to be measured (server
 up or not, a window open on a given view, a fake WoW process running,
 a sync job posted, etc.) before calling this, and for tearing
 everything down afterward.

 WHAT COUNTS AS A "FURPHY PROCESS" (scoped to avoid picking up an
 unrelated powershell.exe/FurphyHost.exe/msedgewebview2.exe elsewhere
 on the machine):
   - powershell.exe whose command line names addon-server.ps1 or
     addon-sync.ps1 AND whose command line contains this build root's
     own path (covers both a root-level run and a copy under
     tests\.tmp\..., which Start-TestServer/Copy-Fixture always place
     under the build root).
   - FurphyHost.exe whose command line or executable path contains the
     build root's path.
   - msedgewebview2.exe whose command line contains the build root's
     path (the default WebView2 profile folder is
     "<exeDir>\FurphyHost.exe.WebView2", always a subfolder of wherever
     FurphyHost.exe itself was copied to, so this same build-root
     substring check also scopes the WebView2 child processes without
     needing to know the exact profile path up front).

 USAGE
   tests\perf\Measure-Furphy.ps1 -Label A-server-idle-no-wow
   tests\perf\Measure-Furphy.ps1 -Label F-sync-job -DurationSec 45 `
       -ServerLogPath C:\path\to\test-root\server.log -Notes "..."

 PARAMS
   -Label              Short, filename-safe state label (e.g. "A",
                        "B-fake-wow"). Required.
   -DurationSec         How long to sample. Default 60.
   -SampleIntervalSec   Seconds between samples. Default 2.
   -ServerLogPath       Path to the test server's server.log. When
                         given, lines timestamped inside the sampling
                         window matching "<ts> METHOD /path ..." are
                         counted as the server's own request count for
                         the window.
   -OutDir              Where to write <Label>-<stamp>.json/.md.
                         Default tests\perf\bench next to this script.
   -Notes               Free-text context folded into the JSON/MD
                         (what state this run represents).
   -Quiet               Suppress the one-line-per-sample progress dot.
=====================================================================
#>

param(
    [Parameter(Mandatory = $true)][string]$Label,
    [int]$DurationSec = 60,
    [int]$SampleIntervalSec = 2,
    [string]$ServerLogPath,
    [string]$OutDir,
    [string]$Notes,
    [switch]$Quiet
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# tests\perf\Measure-Furphy.ps1 -> tests\perf -> tests -> <build root>
$Script:BuildRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$Script:BuildRootLower = $Script:BuildRoot.ToLowerInvariant()

if (-not $OutDir) {
    $OutDir = Join-Path -Path $PSScriptRoot -ChildPath 'bench'
}
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

function ConvertTo-DoubleOrZero {
    param($Value)
    if ($null -eq $Value) { return 0.0 }
    try { return [double]$Value } catch { return 0.0 }
}

function Get-FurphyRole {
    <#
      Classifies one Win32_Process row as a Furphy process this bench
      cares about, or returns $null (excluded). See header comment for
      the exact scoping rule.
    #>
    param([string]$Name, [string]$CommandLine, [string]$ExecutablePath)

    $cl = if ($CommandLine) { $CommandLine } else { '' }
    $exe = if ($ExecutablePath) { $ExecutablePath } else { '' }
    $clLower = $cl.ToLowerInvariant()
    $exeLower = $exe.ToLowerInvariant()
    $inRoot = $clLower.Contains($Script:BuildRootLower) -or $exeLower.Contains($Script:BuildRootLower)
    if (-not $inRoot) { return $null }

    # Self-exclusion: this bench script's own -Notes text sometimes names
    # "addon-server.ps1"/"addon-sync.ps1" in plain prose (no preceding path
    # separator) - never let that free text misclassify Measure-Furphy.ps1
    # itself (or its Setup-Baseline/Run-State* callers) as a server/CLI row.
    if ($clLower -match '(measure-furphy|setup-baseline|run-state[a-z]?)\.ps1') { return $null }

    switch -Regex ($Name) {
        '^powershell(\.exe)?$' {
            # Require a real path/file-boundary before the name (a backslash,
            # a quote, or start-of-string) so this only matches the actual
            # -File target, never free text elsewhere on the command line.
            if ($clLower -match '[\\"'']addon-server\.ps1') { return 'server' }
            if ($clLower -match '[\\"'']addon-sync\.ps1') {
                if ($clLower -match '(^|\s)-launcher(\s|$)') { return 'sync-cli-launcher' }
                return 'sync-cli-job'
            }
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

function Get-FurphySnapshot {
    <#
      One point-in-time read of every matching process's cumulative
      CPU time (100ns units, UserModeTime+KernelModeTime - the same
      units TotalProcessorTime is built from), working set, and
      cumulative IO transfer bytes.
    #>
    $procs = $null
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='FurphyHost.exe' OR Name='msedgewebview2.exe'" -ErrorAction Stop
    } catch {
        return @()
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($procs)) {
        $role = Get-FurphyRole -Name $p.Name -CommandLine $p.CommandLine -ExecutablePath $p.ExecutablePath
        if (-not $role) { continue }
        $cpu100ns = (ConvertTo-DoubleOrZero $p.UserModeTime) + (ConvertTo-DoubleOrZero $p.KernelModeTime)
        $out.Add([PSCustomObject]@{
            ProcessId  = [int]$p.ProcessId
            Name       = $p.Name
            Role       = $role
            CommandLine = [string]$p.CommandLine
            Cpu100ns   = $cpu100ns
            WorkingSet = ConvertTo-DoubleOrZero $p.WorkingSetSize
            ReadBytes  = ConvertTo-DoubleOrZero $p.ReadTransferCount
            WriteBytes = ConvertTo-DoubleOrZero $p.WriteTransferCount
        })
    }
    return $out
}

# ---------------------------------------------------------------------
# Sampling loop
# ---------------------------------------------------------------------

$ledger = @{}
$seenConnKeys = New-Object 'System.Collections.Generic.HashSet[string]'
$sampleCount = 0

$windowStartUtc = (Get-Date).ToUniversalTime()
$windowStart = Get-Date
$endTime = $windowStart.AddSeconds($DurationSec)

if (-not $Quiet) {
    Write-Host "Measure-Furphy: label='$Label' duration=${DurationSec}s interval=${SampleIntervalSec}s -> $OutDir"
}

while ((Get-Date) -lt $endTime) {
    $tickStart = Get-Date
    $snap = Get-FurphySnapshot
    $sampleCount++

    $pidsThisTick = New-Object 'System.Collections.Generic.List[int]'
    foreach ($p in $snap) {
        $pidsThisTick.Add($p.ProcessId)
        if (-not $ledger.ContainsKey($p.ProcessId)) {
            $ledger[$p.ProcessId] = [PSCustomObject]@{
                ProcessId      = $p.ProcessId
                Name           = $p.Name
                Role           = $p.Role
                CommandLine    = $p.CommandLine
                FirstCpu100ns  = $p.Cpu100ns
                LastCpu100ns   = $p.Cpu100ns
                FirstReadBytes = $p.ReadBytes
                LastReadBytes  = $p.ReadBytes
                FirstWriteBytes = $p.WriteBytes
                LastWriteBytes  = $p.WriteBytes
                WsSamples      = New-Object 'System.Collections.Generic.List[double]'
                SampleCount    = 0
                NewTcpConnections = 0
                FirstSeen      = $tickStart
                LastSeen       = $tickStart
            }
        }
        $rec = $ledger[$p.ProcessId]
        $rec.LastCpu100ns = $p.Cpu100ns
        $rec.LastReadBytes = $p.ReadBytes
        $rec.LastWriteBytes = $p.WriteBytes
        $rec.WsSamples.Add($p.WorkingSet)
        $rec.SampleCount++
        $rec.LastSeen = $tickStart
    }

    if ($pidsThisTick.Count -gt 0) {
        $conns = $null
        try {
            $conns = Get-NetTCPConnection -OwningProcess $pidsThisTick.ToArray() -ErrorAction Stop
        } catch {
            $conns = @()
        }
        foreach ($c in @($conns)) {
            if ($c.State -eq 'Listen') { continue }
            $key = "$($c.OwningProcess)|$($c.LocalPort)|$($c.RemoteAddress)|$($c.RemotePort)"
            if (-not $seenConnKeys.Contains($key)) {
                [void]$seenConnKeys.Add($key)
                if ($ledger.ContainsKey([int]$c.OwningProcess)) {
                    $ledger[[int]$c.OwningProcess].NewTcpConnections++
                }
            }
        }
    }

    $elapsedMs = ((Get-Date) - $tickStart).TotalMilliseconds
    $sleepMs = [int]([Math]::Max(0, ($SampleIntervalSec * 1000) - $elapsedMs))
    if ((Get-Date).AddMilliseconds($sleepMs) -lt $endTime -or $sleepMs -le 0) {
        if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
    } else {
        # Last slice would overshoot the window - sleep only what's left.
        $remainMs = [int]($endTime - (Get-Date)).TotalMilliseconds
        if ($remainMs -gt 0) { Start-Sleep -Milliseconds $remainMs }
    }
}

$actualEnd = Get-Date

# ---------------------------------------------------------------------
# Server request count from server.log (optional)
# ---------------------------------------------------------------------

$requestCount = $null
if ($ServerLogPath) {
    if (Test-Path -LiteralPath $ServerLogPath) {
        $requestCount = 0
        $logLines = @()
        try { $logLines = Get-Content -LiteralPath $ServerLogPath -ErrorAction Stop } catch { $logLines = @() }
        foreach ($line in $logLines) {
            if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+(GET|POST|PUT|DELETE)\s') {
                $ts = $null
                try { $ts = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } catch { $ts = $null }
                if ($ts -and $ts -ge $windowStart -and $ts -le $actualEnd) {
                    $requestCount++
                }
            }
        }
    } else {
        $requestCount = $null
    }
}

# ---------------------------------------------------------------------
# Build per-process result rows
# ---------------------------------------------------------------------

$rows = New-Object 'System.Collections.Generic.List[object]'
foreach ($rec in $ledger.Values) {
    $cpuSeconds = ($rec.LastCpu100ns - $rec.FirstCpu100ns) / 1e7
    $ioReadBytes = $rec.LastReadBytes - $rec.FirstReadBytes
    $ioWriteBytes = $rec.LastWriteBytes - $rec.FirstWriteBytes
    $peakWs = 0.0
    $avgWs = 0.0
    if ($rec.WsSamples.Count -gt 0) {
        $peakWs = ($rec.WsSamples | Measure-Object -Maximum).Maximum
        $avgWs = ($rec.WsSamples | Measure-Object -Average).Average
    }
    $rows.Add([PSCustomObject]@{
        ProcessId          = $rec.ProcessId
        Name               = $rec.Name
        Role               = $rec.Role
        SampleCount        = $rec.SampleCount
        CpuSeconds         = [math]::Round($cpuSeconds, 3)
        PeakWorkingSetBytes = [long]$peakWs
        AvgWorkingSetBytes  = [long]$avgWs
        IOReadBytes        = [long]([Math]::Max(0, $ioReadBytes))
        IOWriteBytes       = [long]([Math]::Max(0, $ioWriteBytes))
        NewTcpConnections  = $rec.NewTcpConnections
        CommandLine        = $rec.CommandLine
    })
}
$rowsSorted = @($rows | Sort-Object Role, ProcessId)

$totalCpu = ($rowsSorted | Measure-Object -Property CpuSeconds -Sum).Sum
if (-not $totalCpu) { $totalCpu = 0 }
$totalReadBytes = ($rowsSorted | Measure-Object -Property IOReadBytes -Sum).Sum
if (-not $totalReadBytes) { $totalReadBytes = 0 }
$totalWriteBytes = ($rowsSorted | Measure-Object -Property IOWriteBytes -Sum).Sum
if (-not $totalWriteBytes) { $totalWriteBytes = 0 }
$totalNewTcp = ($rowsSorted | Measure-Object -Property NewTcpConnections -Sum).Sum
if (-not $totalNewTcp) { $totalNewTcp = 0 }
$peakWsTotal = 0
if ($rowsSorted.Count -gt 0) { $peakWsTotal = ($rowsSorted | Measure-Object -Property PeakWorkingSetBytes -Maximum).Maximum }

$result = [PSCustomObject]@{
    Label            = $Label
    Notes            = $Notes
    DurationSec      = $DurationSec
    SampleIntervalSec = $SampleIntervalSec
    SampleCount      = $sampleCount
    WindowStartUtc   = $windowStartUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    WindowStart      = $windowStart.ToString('yyyy-MM-dd HH:mm:ss')
    WindowEnd        = $actualEnd.ToString('yyyy-MM-dd HH:mm:ss')
    ActualDurationSec = [math]::Round(($actualEnd - $windowStart).TotalSeconds, 1)
    ServerLogPath    = $ServerLogPath
    RequestCountInWindow = $requestCount
    ProcessCount     = $rowsSorted.Count
    TotalCpuSeconds  = [math]::Round($totalCpu, 3)
    TotalIOReadBytes = $totalReadBytes
    TotalIOWriteBytes = $totalWriteBytes
    TotalNewTcpConnections = $totalNewTcp
    PeakWorkingSetBytesAnyProcess = $peakWsTotal
    Processes        = $rowsSorted
}

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$safeLabel = ($Label -replace '[^a-zA-Z0-9_-]', '_')
$jsonPath = Join-Path -Path $OutDir -ChildPath "$safeLabel-$stamp.json"
$mdPath = Join-Path -Path $OutDir -ChildPath "$safeLabel-$stamp.md"

$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

function Format-MB {
    param([double]$Bytes)
    return [math]::Round($Bytes / 1MB, 2)
}

$mdLines = New-Object 'System.Collections.Generic.List[string]'
$mdLines.Add("# Perf sample: $Label")
$mdLines.Add('')
if ($Notes) {
    $mdLines.Add($Notes)
    $mdLines.Add('')
}
$mdLines.Add("Window: $($result.WindowStart) -> $($result.WindowEnd) ($($result.ActualDurationSec)s actual, $($result.SampleCount) samples at ${SampleIntervalSec}s)")
if ($null -ne $requestCount) {
    $mdLines.Add("Server requests in window (from $ServerLogPath): $requestCount")
} elseif ($ServerLogPath) {
    $mdLines.Add("Server requests in window: server.log not found at $ServerLogPath")
}
$mdLines.Add('')
$mdLines.Add('| Role | PID | Name | Samples | CPU sec | Peak WS (MB) | Avg WS (MB) | IO read (MB) | IO write (MB) | New TCP conns |')
$mdLines.Add('|---|---|---|---|---|---|---|---|---|---|')
foreach ($r in $rowsSorted) {
    $mdLines.Add("| $($r.Role) | $($r.ProcessId) | $($r.Name) | $($r.SampleCount) | $($r.CpuSeconds) | $(Format-MB $r.PeakWorkingSetBytes) | $(Format-MB $r.AvgWorkingSetBytes) | $(Format-MB $r.IOReadBytes) | $(Format-MB $r.IOWriteBytes) | $($r.NewTcpConnections) |")
}
if ($rowsSorted.Count -eq 0) {
    $mdLines.Add('| (none - no matching Furphy process was resident during this window) | | | | | | | | | |')
}
$mdLines.Add("| **TOTAL** | | | | **$([math]::Round($totalCpu,3))** | | | **$(Format-MB $totalReadBytes)** | **$(Format-MB $totalWriteBytes)** | **$totalNewTcp** |")
$mdLines.Add('')
$mdLines.Add("JSON: $jsonPath")

Set-Content -LiteralPath $mdPath -Value ($mdLines -join [Environment]::NewLine) -Encoding UTF8

if (-not $Quiet) {
    Write-Host "Measure-Furphy: wrote $jsonPath"
    Write-Host "Measure-Furphy: wrote $mdPath"
    $rowsSorted | Format-Table Role, ProcessId, Name, CpuSeconds, @{n='PeakWS(MB)'; e={Format-MB $_.PeakWorkingSetBytes}}, NewTcpConnections -AutoSize | Out-String | Write-Host
}

return $result
