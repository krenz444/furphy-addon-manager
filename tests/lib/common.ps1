<#
=====================================================================
 tests\lib\common.ps1

 Shared test helpers for the Furphy Addon Manager test suite. Dot-source
 this from any test/static script:

     . (Join-Path $PSScriptRoot '..\lib\common.ps1')     # from tests\unit or tests\static
     . (Join-Path $PSScriptRoot 'lib\common.ps1')        # from tests\run-all.ps1

 Everything here is pure Windows PowerShell 5.1, ASCII only, no modules
 beyond what ships in the box (System.Net.Sockets/HttpListener client
 side only - this file never itself hosts a listener).

 CONVENTIONS
   - Every temp root this file creates lives under
     tests\.tmp\<name>-<timestamp>-<pid>\ and is tracked in
     $Script:FurphyTempRoots so Remove-TempRoots can sweep them all at the
     end of a run. Nothing here ever writes outside tests\.tmp\ or a
     caller-supplied path.
   - fixtures\wowroot is never mutated directly - Copy-Fixture always
     copies it into a fresh temp root first.
   - Server helpers default to port 47899 (never 47831, the real app's
     default/production port) per the task brief; static-file servers use
     the 47890-47897 pool via Get-FreeStaticPort.
   - Every Start-* helper has a matching Stop-* helper; callers MUST call
     Stop-* in a finally block so a failed assertion never leaks a
     process.
=====================================================================
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------
# Roots
# ---------------------------------------------------------------------

# tests\lib\common.ps1 -> tests\lib -> tests -> <build root>
$Script:FurphyBuildRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$Script:FurphyTestsRoot = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'tests'
$Script:FurphyTmpRoot = Join-Path -Path $Script:FurphyTestsRoot -ChildPath '.tmp'
$Script:FurphyFixtureWowRoot = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'fixtures\wowroot'

if (-not (Test-Path -LiteralPath $Script:FurphyTmpRoot)) {
    New-Item -ItemType Directory -Path $Script:FurphyTmpRoot -Force | Out-Null
}

$Script:FurphyTempRoots = New-Object 'System.Collections.Generic.List[string]'

function New-TempRoot {
    <#
      Creates a fresh, empty directory under tests\.tmp\ and returns its
      full path. Tracked for Remove-TempRoots. -Name is a short label
      (e.g. "migration", "server") folded into the folder name only for
      readability when debugging a failed run - never relied on for
      uniqueness (a timestamp + random suffix is).
    #>
    param([string]$Name = 'root')

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $suffix = -join ((1..6) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    $safeName = ($Name -replace '[^a-zA-Z0-9_-]', '_')
    $path = Join-Path -Path $Script:FurphyTmpRoot -ChildPath ("{0}-{1}-{2}" -f $safeName, $stamp, $suffix)
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $Script:FurphyTempRoots.Add($path)
    return $path
}

function Remove-TempRoots {
    <#
      Best-effort recursive delete of every root New-TempRoot handed out
      this session. Never throws - a locked file (AV, an orphaned child
      process) is logged to the host and skipped, not fatal to the run.
      Safe to call more than once (a path already gone is a silent no-op).
    #>
    foreach ($p in @($Script:FurphyTempRoots.ToArray())) {
        if (Test-Path -LiteralPath $p) {
            try {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
            } catch {
                Write-Host "WARN: could not remove temp root '$p': $($_.Exception.Message)"
            }
        }
    }
    $Script:FurphyTempRoots.Clear()
}

function Copy-Fixture {
    <#
      Copies the checked-in fixtures\wowroot tree into a fresh location so
      a test can freely mutate/delete flavour folders without ever
      touching the pristine original. -Destination defaults to a new temp
      root (New-TempRoot -Name 'wowroot'). Returns the destination path.
    #>
    param(
        [string]$Destination,
        [string]$SourceSubpath
    )

    if (-not $Destination) {
        $Destination = New-TempRoot -Name 'wowroot'
    }
    $source = $Script:FurphyFixtureWowRoot
    if ($SourceSubpath) {
        $source = Join-Path -Path $source -ChildPath $SourceSubpath
    }
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Copy-Fixture: source not found: $source"
    }
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    # Copy-Item -Recurse's *contents* (trailing \*, so -Path not
    # -LiteralPath - the wildcard needs real expansion here) rather than
    # nesting a copy of the "wowroot" folder itself one level deeper than
    # callers expect. Enumerating with Get-ChildItem first also picks up
    # dotfiles like .build.info, which a bare `\*` glob does on this
    # PowerShell version but is confirmed explicitly here since the whole
    # fixture's correctness hinges on it.
    $items = Get-ChildItem -LiteralPath $source -Force
    foreach ($item in $items) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
    return $Destination
}

function Assert-FixturePristine {
    <#
      Sanity check a caller can run before/after a pass touching a fixture
      COPY, to prove the real checked-in fixture was never touched by
      mistake. Returns $true/$false; does not itself write to the results
      collector (callers pass the bool to Add-Result).
    #>
    $expected = @(
        '.build.info',
        '_classic_\Interface\AddOns\FakeAddon\FakeAddon.toc',
        '_classic_\Interface\AddOns\FakeAddon\FakeAddon_Mists.toc',
        '_classic_\Wow.exe',
        '_classic_era_\Interface\AddOns\MultiFlavourAddon\MultiFlavourAddon.toc',
        '_classic_era_\Interface\AddOns\MultiFlavourAddon\MultiFlavourAddon_Mists.toc',
        '_classic_era_\Interface\AddOns\MultiFlavourAddon\MultiFlavourAddon_Vanilla.toc',
        '_classic_era_\Interface\AddOns\PreExistingEraAddon\PreExistingEraAddon.toc',
        '_classic_era_\Wow.exe',
        '_ptr_\Wow.exe',
        '_retail_\Interface\AddOns\SingleFlavourAddon\SingleFlavourAddon.toc',
        '_retail_\Wow.exe'
    )
    foreach ($rel in $expected) {
        $full = Join-Path -Path $Script:FurphyFixtureWowRoot -ChildPath $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            return $false
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Script:FurphyFixtureWowRoot '_ptr_\Interface\AddOns') -PathType Container)) {
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------
# Ports
# ---------------------------------------------------------------------

function Test-PortOpen {
    param([int]$Port, [string]$HostName = '127.0.0.1', [int]$TimeoutMs = 300)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs)
        if ($ok -and $client.Connected) {
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function ConvertTo-Win32QuotedArg {
    <#
      CommandLineToArgvW-compatible quoting for one command-line argument -
      a small self-contained copy of addon-server.ps1's own
      ConvertTo-SafeProcessArg (kept independent here so common.ps1 never
      needs that script dot-sourced just to build a child-process command
      line - e.g. Invoke-CliProcess/Start-TestServer work whether or not
      the caller has dot-sourced addon-server.ps1 in the same session).
      Used because this environment's [ProcessStartInfo]::ArgumentList is
      $null by default (confirmed live) rather than a ready-to-use
      collection, so .Arguments (one pre-quoted string) is the only option.
    #>
    param([string]$Value)

    if ($null -eq $Value) { $Value = '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
        } elseif ($ch -eq '"') {
            if ($backslashes -gt 0) { [void]$sb.Append('\', ($backslashes * 2 + 1)) } else { [void]$sb.Append('\') }
            [void]$sb.Append('"')
            $backslashes = 0
        } else {
            if ($backslashes -gt 0) { [void]$sb.Append('\', $backslashes); $backslashes = 0 }
            [void]$sb.Append($ch)
        }
    }
    if ($backslashes -gt 0) { [void]$sb.Append('\', ($backslashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-CliProcess {
    <#
      Runs a .ps1 (addon-sync.ps1, typically with -Json) as a REAL child
      process with true OS-level stdout/stderr redirection, then returns
      its exit code and captured output - the only reliable way to get
      both this script's output AND its exit code back.

      IMPORTANT #1, confirmed live while writing this test suite: every
      -Json branch in addon-sync.ps1 prints its payload via `Write-Host
      (ConvertTo-Json ...)`, never Write-Output. `$out = & '...\addon-
      sync.ps1' -Json ...` (PowerShell's own pipeline/success-stream
      capture) THEREFORE CAPTURES NOTHING - $out comes back empty even
      though the JSON visibly prints to the console - because Write-Host
      bypasses the success stream entirely. A real OS-level stdout
      redirect (what this helper does) DOES capture Write-Host output,
      matching addon-server.ps1's own real invocation pattern.

      IMPORTANT #2, also confirmed live: the `Start-Process` CMDLET's
      -PassThru process object never reliably exposes .ExitCode once
      -RedirectStandardOutput/-RedirectStandardError are also used (empty
      even after .WaitForExit()+.Refresh()) - a real, repeatable quirk on
      this machine, not a timing fluke. This helper therefore drives
      [System.Diagnostics.Process] directly via ProcessStartInfo instead
      of the Start-Process cmdlet, reading both streams asynchronously
      BEFORE WaitForExit() (the standard .NET pattern - reading
      synchronously after WaitForExit can deadlock once either stream
      fills its OS pipe buffer), which reports ExitCode correctly.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSec = 60
    )

    $fullArgs = New-Object 'System.Collections.Generic.List[string]'
    $fullArgs.Add('-NoProfile')
    $fullArgs.Add('-ExecutionPolicy')
    $fullArgs.Add('Bypass')
    $fullArgs.Add('-File')
    $fullArgs.Add($ScriptPath)
    foreach ($a in $ArgumentList) { $fullArgs.Add($a) }

    $quotedArgs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in $fullArgs) { $quotedArgs.Add((ConvertTo-Win32QuotedArg -Value $a)) }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ($quotedArgs.ToArray() -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $stdout = ''
    $stderr = ''
    try {
        [void]$proc.Start()
        # True .NET async reads (Task-based, not PowerShell's
        # Register-ObjectEvent) started immediately after Start() and
        # awaited via .Result below - the standard deadlock-safe pattern
        # (reading synchronously only after WaitForExit can deadlock once
        # a stream fills its OS pipe buffer). An earlier
        # Register-ObjectEvent/BeginOutputReadLine version of this helper
        # delivered lines OUT OF ORDER under real JSON-sized output
        # (confirmed live) - PowerShell's own event queue does not
        # guarantee delivery order across two simultaneously-firing
        # streams under load; ReadToEndAsync's Tasks have no such issue
        # since each reads its own stream strictly sequentially.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            throw "Invoke-CliProcess: '$ScriptPath' did not exit within ${TimeoutSec}s"
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $proc.ExitCode
    } finally {
        $proc.Dispose()
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Invoke-CliJson {
    <# Invoke-CliProcess, then parse StdOut as the one JSON document -Json mode promises. Throws with StdOut/StdErr included if it doesn't parse. #>
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSec = 60
    )

    $r = Invoke-CliProcess -ScriptPath $ScriptPath -ArgumentList $ArgumentList -TimeoutSec $TimeoutSec
    try {
        $parsed = $r.StdOut | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Invoke-CliJson: StdOut did not parse as JSON (exit $($r.ExitCode)). StdOut=[$($r.StdOut)] StdErr=[$($r.StdErr)]"
    }
    return [PSCustomObject]@{ ExitCode = $r.ExitCode; Json = $parsed; StdErr = $r.StdErr }
}

function Wait-Port {
    <# Polls until $Port accepts a TCP connect, or -TimeoutSec elapses (returns $false). #>
    param([int]$Port, [string]$HostName = '127.0.0.1', [int]$TimeoutSec = 15)

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-PortOpen -Port $Port -HostName $HostName) {
            return $true
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Get-FreeStaticPort {
    <# Returns the first free port in the static-server pool 47890-47897. Throws if all are busy. #>
    foreach ($p in 47890..47897) {
        if (-not (Test-PortOpen -Port $p -TimeoutMs 150)) {
            return $p
        }
    }
    throw 'Get-FreeStaticPort: no free port in 47890-47897'
}

# ---------------------------------------------------------------------
# Static file server (python -m http.server), for download-progress /
# byte-for-byte fixture tests.
# ---------------------------------------------------------------------

function Start-StaticServer {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [int]$Port
    )

    if (-not $Port) { $Port = Get-FreeStaticPort }
    $proc = Start-Process -FilePath 'python' -ArgumentList @('-m', 'http.server', [string]$Port) `
        -WorkingDirectory $Directory -WindowStyle Hidden -PassThru
    if (-not (Wait-Port -Port $Port -TimeoutSec 10)) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        throw "Start-StaticServer: python http.server did not come up on port $Port"
    }
    return [PSCustomObject]@{ Process = $proc; Port = $Port; Directory = $Directory }
}

function Stop-StaticServer {
    param($Server)

    if (-not $Server) { return }
    try {
        if ($Server.Process -and -not $Server.Process.HasExited) {
            Stop-Process -Id $Server.Process.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {
    }
}

# ---------------------------------------------------------------------
# addon-server.ps1 test instance
# ---------------------------------------------------------------------

function Start-TestServer {
    <#
      Starts addon-server.ps1 (from -ScriptPath, default
      <BuildRoot>\addon-server.ps1) hidden, rooted at -Root, listening on
      -Port (default 47899 per the task brief - never the real 47831).
      Waits for /api/ping to answer before returning. Returns an object
      Stop-TestServer accepts.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [int]$Port = 47899,
        [string]$ScriptPath,
        [int]$IdleMinutes = 5,
        [string]$WowRoot,
        [string[]]$ExtraArgs = @()
    )

    if (-not $ScriptPath) {
        $ScriptPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'addon-server.ps1'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'ui'))) {
        $uiSource = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'ui'
        Copy-Item -LiteralPath $uiSource -Destination (Join-Path $Root 'ui') -Recurse -Force
    }
    # T2 fix (found live): addon-server.ps1's $Script:CliPath is always
    # "<Root>\addon-sync.ps1" (production layout - the CLI sits next to the
    # server) - every job/fast-op endpoint (jobs, scan, files, ignore/unpin,
    # settings-driven flavour resolution, etc.) Start-Process's that exact
    # path. A caller's -Root that holds only ui\ (this helper's own default
    # before this fix) makes every one of those endpoints 500 with a raw
    # ".ps1 to the -File parameter does not exist" .NET exception message
    # instead of doing anything - copy the real CLI alongside ui\ the same
    # way, so any test that starts a job/-Scan/-Files/etc against a
    # Start-TestServer root just works without every caller remembering to
    # do this itself.
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'addon-sync.ps1'))) {
        Copy-Item -LiteralPath (Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'addon-sync.ps1') -Destination (Join-Path $Root 'addon-sync.ps1') -Force
    }

    # Review fix: Start-TestServer used to declare success purely via
    # Wait-Port + a successful GET /api/ping, with no check that the port
    # was free BEFORE spawning - a stale server left behind by an
    # interrupted prior run (a crash/Ctrl+C before its own Stop-TestServer
    # ran) would answer /api/ping itself, so this call would report "up"
    # even though the NEW child's own HttpListener bind had already failed
    # and exited. Every subsequent Invoke-Api call in the test would then
    # silently talk to the WRONG (stale) server's root/state, and
    # Stop-TestServer's later shutdown would kill that unrelated process
    # while this call's own $proc (already exited) looked clean - the test
    # would appear to pass having exercised nothing it thought it was
    # exercising. Fail fast instead: refuse to even try if the port is
    # already answering.
    if (Test-PortOpen -Port $Port -TimeoutMs 300) {
        throw "Start-TestServer: port $Port already in use - stale server from an interrupted prior run? Stop it first (or run tests\run-all.ps1, whose hygiene sweep now also runs at the START of a run, not only in its trailing finally)."
    }

    $argList = New-Object 'System.Collections.Generic.List[string]'
    $argList.Add('-NoProfile')
    $argList.Add('-ExecutionPolicy')
    $argList.Add('Bypass')
    $argList.Add('-File')
    $argList.Add($ScriptPath)
    $argList.Add('-Port'); $argList.Add([string]$Port)
    $argList.Add('-Root'); $argList.Add($Root)
    $argList.Add('-IdleMinutes'); $argList.Add([string]$IdleMinutes)
    if ($WowRoot) { $argList.Add('-WowRoot'); $argList.Add($WowRoot) }
    foreach ($a in $ExtraArgs) { $argList.Add($a) }

    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList.ToArray() -WindowStyle Hidden -PassThru

    $up = $false
    if (Wait-Port -Port $Port -TimeoutSec 15) {
        for ($i = 0; $i -lt 20; $i++) {
            try {
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/ping" -Method Get -TimeoutSec 2 | Out-Null
                $up = $true
                break
            } catch {
                Start-Sleep -Milliseconds 250
            }
        }
    }
    if (-not $up) {
        try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } } catch { }
        throw "Start-TestServer: server on port $Port did not answer /api/ping in time"
    }

    return [PSCustomObject]@{ Process = $proc; Port = $Port; Root = $Root }
}

function Stop-TestServer {
    <#
      Graceful POST /api/shutdown (same-origin header set), falls back to
      Stop-Process -Force if the process is still alive after a short
      grace period. Always safe to call in a finally block, including on
      a $Server that never started.
    #>
    param($Server, [int]$GraceMs = 2000)

    if (-not $Server) { return }
    try {
        Invoke-Api -Port $Server.Port -Method Post -Path '/api/shutdown' | Out-Null
    } catch {
    }
    $deadline = (Get-Date).AddMilliseconds($GraceMs)
    while ((Get-Date) -lt $deadline) {
        if (-not $Server.Process -or $Server.Process.HasExited) { break }
        Start-Sleep -Milliseconds 150
    }
    try {
        if ($Server.Process -and -not $Server.Process.HasExited) {
            Stop-Process -Id $Server.Process.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {
    }
}

# ---------------------------------------------------------------------
# HTTP API calls (Origin header helpers - non-GET requires a same-origin
# Origin/Referer or addon-server.ps1's CSRF guard 403s the request, see
# Test-SameOriginRequest in addon-server.ps1).
# ---------------------------------------------------------------------

function Invoke-Api {
    <#
      Calls the local test server. Always sets a same-origin Origin header
      (http://localhost:<port>) so PUT/POST/DELETE pass
      Test-SameOriginRequest without every call site repeating that
      boilerplate; GET never needs it but sending it anyway is harmless.
      Returns a uniform result object so a caller can assert on error
      responses without a try/catch of their own:
        { Ok; StatusCode; Body; Error }
      -Ok is $true only for a 2xx status. -Body is the parsed JSON (works
      for both success and a JSON error body such as {"error":"..."}).

      T2 FIX (found live while writing tests\integration): this used to call
      Invoke-RestMethod and, on a non-2xx status, read the error body back
      via `$_.Exception.Response.GetResponseStream()`. That comes back EMPTY
      on this machine for every 4xx/5xx response even though the exact same
      bytes are demonstrably still on the wire (confirmed live with a raw
      [System.Net.HttpWebRequest] read of the identical response) - Windows
      PowerShell 5.1's Invoke-RestMethod appears to consume/dispose the
      underlying stream itself while building the exception it throws, so a
      caller's own second read against that same stream reliably gets zero
      bytes. Every test in tests\integration that asserted on an error
      response's Body (a 400's {"error":"..."} shape, in particular) would
      silently see $null instead - not a flaky timing issue, reproduced
      every single time. Driving [System.Net.HttpWebRequest] directly here
      instead sidesteps Invoke-RestMethod's exception handling entirely, so
      the SAME code path (a WebException's Response) is read exactly once,
      immediately, by code this file fully controls.

      Review fix: -ContentType lets a caller override the hardcoded
      "application/json; charset=utf-8" this helper used to always send on
      every non-GET call, with no way to send anything else. Read-Body
      (addon-server.ps1) rejects any Content-Type that does not start with
      "application/json" with a 400 (Round 20's CORS-preflight-avoidance
      fix) - with no override, that code path could never actually be
      exercised by this suite, so a real regression there would go
      unnoticed. Default is unchanged for every existing caller.
    #>
    param(
        [int]$Port = 47899,
        [ValidateSet('Get', 'Post', 'Put', 'Delete')][string]$Method = 'Get',
        [Parameter(Mandatory = $true)][string]$Path,
        $Body,
        [hashtable]$Headers,
        [int]$TimeoutSec = 15,
        [switch]$NoOrigin,
        [string]$ContentType = 'application/json; charset=utf-8'
    )

    $uri = "http://127.0.0.1:$Port$Path"
    $allHeaders = @{}
    if (-not $NoOrigin) {
        $allHeaders['Origin'] = "http://localhost:$Port"
    }
    if ($Headers) {
        foreach ($k in $Headers.Keys) { $allHeaders[$k] = $Headers[$k] }
    }

    $req = [System.Net.HttpWebRequest]::Create($uri)
    $req.Method = $Method.ToString().ToUpperInvariant()
    $req.Timeout = $TimeoutSec * 1000
    $req.KeepAlive = $false
    foreach ($k in $allHeaders.Keys) {
        if ($k -eq 'Origin') { $req.Headers.Set('Origin', $allHeaders[$k]) }
        elseif ($k -eq 'Referer') { $req.Referer = $allHeaders[$k] }
        else { $req.Headers.Set($k, [string]$allHeaders[$k]) }
    }

    if ($Method -ne 'Get') {
        # Round-trip fix (found live): a POST/PUT/DELETE with NO body (e.g.
        # POST /api/tray/start, POST /api/shutdown) still needs an explicit
        # Content-Length: 0 - .NET's HttpWebRequest otherwise sends neither
        # Content-Length nor Transfer-Encoding for a body-less non-GET
        # request, and http.sys (backing this server's HttpListener) 411s
        # ("Length Required") any such request outright, before it ever
        # reaches Invoke-Route at all. Always writing the request stream
        # (even with zero bytes) is what makes .NET emit Content-Length: 0.
        $bytes = [byte[]]@()
        if ($null -ne $Body) {
            $bodyText = $Body
            if ($Body -isnot [string]) {
                $bodyText = (ConvertTo-Json -InputObject $Body -Depth 10 -Compress)
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$bodyText)
        }
        $req.ContentType = $ContentType
        $req.ContentLength = $bytes.Length
        $reqStream = $req.GetRequestStream()
        try {
            if ($bytes.Length -gt 0) { $reqStream.Write($bytes, 0, $bytes.Length) }
        } finally {
            $reqStream.Close()
        }
    }

    $webResp = $null
    $status = 0
    $errorMessage = $null
    try {
        $webResp = $req.GetResponse()
        $status = [int]$webResp.StatusCode
    } catch [System.Net.WebException] {
        $errorMessage = $_.Exception.Message
        if ($_.Exception.Response) {
            $webResp = $_.Exception.Response
            try { $status = [int]$webResp.StatusCode } catch { $status = 0 }
        }
    }

    $text = ''
    if ($webResp) {
        try {
            $stream = $webResp.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $text = $reader.ReadToEnd()
            $reader.Close()
        } catch {
        } finally {
            try { $webResp.Close() } catch { }
        }
    }

    $parsedBody = $null
    if ($text) {
        try { $parsedBody = $text | ConvertFrom-Json } catch { $parsedBody = $text }
    }

    $ok = ($status -ge 200 -and $status -lt 300)
    return [PSCustomObject]@{ Ok = $ok; StatusCode = $status; Body = $parsedBody; Error = $errorMessage }
}

# ---------------------------------------------------------------------
# Win32 command-line round-trip (for ConvertTo-SafeProcessArg tests) -
# parses a quoted argv string the exact way CreateProcess's C runtime
# does, via the real CommandLineToArgvW Win32 API, so the assertion is
# "the real OS parser reads back what we meant" rather than a hand-rolled
# re-implementation that could share the same bug as the code under test.
# ---------------------------------------------------------------------

$Script:FurphyArgvHelperType = $null

function Get-ArgvHelperType {
    if (-not $Script:FurphyArgvHelperType) {
        $src = @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class FurphyArgvHelper
{
    [DllImport("shell32.dll", SetLastError = true)]
    static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string lpCmdLine, out int pNumArgs);

    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr hMem);

    public static string[] Parse(string commandLine)
    {
        int argc;
        IntPtr argv = CommandLineToArgvW(commandLine, out argc);
        if (argv == IntPtr.Zero) { throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
        try
        {
            string[] result = new string[argc];
            for (int i = 0; i < argc; i++)
            {
                IntPtr p = Marshal.ReadIntPtr(argv, i * IntPtr.Size);
                result[i] = Marshal.PtrToStringUni(p);
            }
            return result;
        }
        finally
        {
            LocalFree(argv);
        }
    }
}
'@
        Add-Type -TypeDefinition $src -Language CSharp
        $Script:FurphyArgvHelperType = [FurphyArgvHelper]
    }
    return $Script:FurphyArgvHelperType
}

function ConvertFrom-Win32CommandLine {
    <#
      Parses a full Win32 command line (space-joined, already-quoted
      tokens - exactly the shape Start-Process -ArgumentList produces) via
      CommandLineToArgvW and returns the resulting argv as a string[].
      Used to prove ConvertTo-SafeProcessArg's quoting round-trips: join
      one quoted token to a fake argv0 and confirm argv[1] equals the
      original unquoted value.
    #>
    param([Parameter(Mandatory = $true)][string]$CommandLine)

    $type = Get-ArgvHelperType
    return $type::Parse($CommandLine)
}

# ---------------------------------------------------------------------
# Results collector - used by tests\static\*.ps1 (plain pass/fail checks,
# not Pester). Each static script creates one collector, calls Add-Result
# for every assertion, then Write-ResultsSummary + exits with the
# collector's own exit code.
# ---------------------------------------------------------------------

# ---------------------------------------------------------------------
# Fake HttpListener context - for unit-testing addon-server.ps1 handler
# functions (Handle-Open, Handle-SettingsPut, Test-SameOriginRequest,
# Resolve-RequestFlavour, ...) directly, with no real socket/listener.
#
# The fake Response.OutputStream is a small PSCustomObject with its own
# Write/Close/Flush ScriptMethods backed by a List[byte] buffer, rather
# than a real System.IO.MemoryStream - Send-Json always closes the real
# response stream in a `finally` block (correctly, for the real server),
# which would otherwise make the written bytes unreadable by the test the
# instant the handler under test returns. A plain PSCustomObject sidesteps
# that entirely: Add-Member on it needs no shadowing of any inherited
# .NET method, and the buffer stays readable after "Close" for as long as
# the test needs it.
# ---------------------------------------------------------------------

function New-FakeOutputStream {
    $buf = New-Object 'System.Collections.Generic.List[byte]'
    $stream = [PSCustomObject]@{ Buffer = $buf }
    $stream | Add-Member -MemberType ScriptMethod -Name Write -Value {
        param($bytes, $offset, $count)
        for ($i = 0; $i -lt $count; $i++) { $this.Buffer.Add($bytes[$offset + $i]) }
    }
    $stream | Add-Member -MemberType ScriptMethod -Name Close -Value { }
    $stream | Add-Member -MemberType ScriptMethod -Name Flush -Value { }
    return $stream
}

function New-FakeHttpContext {
    <#
      Builds a fake {Request; Response} pair good enough for every handler
      function in addon-server.ps1 that only touches: Request.HttpMethod,
      .Headers (NameValueCollection), .QueryString (NameValueCollection),
      .HasEntityBody, .ContentType, .InputStream, .Url; and
      Response.StatusCode/.ContentType/.Headers/.ContentLength64/
      .OutputStream/.Close(). -JsonBody is serialized (or used verbatim if
      already a string) as the UTF-8 request body; omit it for a GET/empty
      body. -Query is the raw query string INCLUDING a leading "?" (or
      omit it entirely).
    #>
    param(
        [string]$Method = 'GET',
        [string]$Path = '/',
        [string]$Query = '',
        [hashtable]$Headers,
        $JsonBody,
        [string]$ContentType = 'application/json; charset=utf-8',
        [int]$Port = 47899
    )

    $reqHeaders = New-Object System.Collections.Specialized.NameValueCollection
    if ($Headers) {
        foreach ($k in $Headers.Keys) { $reqHeaders.Add([string]$k, [string]$Headers[$k]) }
    }

    $qs = New-Object System.Collections.Specialized.NameValueCollection
    $trimmedQuery = $Query.TrimStart('?')
    if ($trimmedQuery) {
        foreach ($pair in ($trimmedQuery -split '&')) {
            if (-not $pair) { continue }
            $kv = $pair -split '=', 2
            $key = [System.Uri]::UnescapeDataString($kv[0])
            $val = ''
            if ($kv.Count -gt 1) { $val = [System.Uri]::UnescapeDataString($kv[1]) }
            $qs.Add($key, $val)
        }
    }

    $hasBody = $false
    $inputStream = New-Object System.IO.MemoryStream(, [byte[]]@())
    if ($null -ne $JsonBody) {
        $hasBody = $true
        $bodyText = $JsonBody
        if ($JsonBody -isnot [string]) {
            $bodyText = (ConvertTo-Json -InputObject $JsonBody -Depth 10 -Compress)
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$bodyText)
        $inputStream = New-Object System.IO.MemoryStream(, $bytes)
    }

    $urlText = "http://127.0.0.1:$Port$Path"
    if ($trimmedQuery) { $urlText = "$urlText`?$trimmedQuery" }

    $request = [PSCustomObject]@{
        HttpMethod    = $Method
        Headers       = $reqHeaders
        QueryString   = $qs
        HasEntityBody = $hasBody
        ContentType   = $ContentType
        InputStream   = $inputStream
        Url           = [System.Uri]$urlText
    }

    $response = [PSCustomObject]@{
        StatusCode      = 0
        ContentType     = ''
        Headers         = (New-Object System.Collections.Specialized.NameValueCollection)
        ContentLength64 = [int64]0
        OutputStream    = (New-FakeOutputStream)
    }
    $response | Add-Member -MemberType ScriptMethod -Name Close -Value { }

    return [PSCustomObject]@{ Request = $request; Response = $response }
}

function Get-FakeResponseBody {
    <# Reads back whatever Send-Json wrote to a New-FakeHttpContext's Response, parsed as JSON ($null if nothing was written). #>
    param($Context)

    $bytes = $Context.Response.OutputStream.Buffer.ToArray()
    if ($bytes.Length -eq 0) { return $null }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    return ($text | ConvertFrom-Json)
}

function New-ResultsCollector {
    param([string]$Suite = 'suite')
    return [PSCustomObject]@{
        Suite   = $Suite
        Results = (New-Object 'System.Collections.Generic.List[object]')
    }
}

function Add-Result {
    param(
        [Parameter(Mandatory = $true)]$Collector,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [string]$Message = ''
    )

    $Collector.Results.Add([PSCustomObject]@{ Name = $Name; Passed = $Passed; Message = $Message })
    if ($Passed) {
        Write-Host "  [PASS] $Name"
    } else {
        Write-Host "  [FAIL] $Name - $Message"
    }
}

function Write-ResultsSummary {
    <# Prints a "N/M passed" line and returns the process exit code to use (0 or 1). #>
    param([Parameter(Mandatory = $true)]$Collector)

    $all = $Collector.Results.ToArray()
    $total = $all.Count
    $failed = 0
    foreach ($r in $all) { if (-not $r.Passed) { $failed++ } }
    $passed = $total - $failed
    Write-Host ''
    Write-Host ("[{0}] {1}/{2} passed" -f $Collector.Suite, $passed, $total)
    if ($failed -gt 0) {
        return 1
    }
    return 0
}
