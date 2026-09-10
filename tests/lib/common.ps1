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

function Copy-FurphyAppFiles {
    <#
      Copies exactly the four things a scratch app root needs to run
      addon-server.ps1/FurphyHost.exe against - addon-sync.ps1,
      addon-server.ps1, the ui\ folder, and host\bin\* (into
      <Destination>\host\bin) - and nothing else: never tests\, never
      .git, never a runtime cache\/jobs\/flavours\ folder. -Source
      defaults to $Script:FurphyBuildRoot; -Destination is required and
      is validated before anything is copied.

      2026-09-08 incident this replaces: a measurement agent hand-built
      a scratch app root under tests\.tmp and threw in its own
      'Copy-Item ... tests -Recurse'; because the destination lived
      INSIDE tests\.tmp (itself under tests\), that copy recursed into
      itself until Windows' path-length limit stopped it - 756 MB,
      11,263 files, 1,777 directory levels deep, cleaned up by hand with
      robocopy. This helper exists so no caller ever hand-rolls that
      copy again - it copies a fixed, narrow file list and validates
      -Destination/-Source before touching disk.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$Source
    )

    if (-not $Source) { $Source = $Script:FurphyBuildRoot }

    # Normalize lexically (neither path need exist yet - GetFullPath
    # collapses '..' segments without touching disk) so a dot-segment
    # trick like '...\tests\.tmp\x\..\..\..' can't disguise a
    # build-root-escaping destination as a legitimate tests\.tmp root.
    $fullSource = [System.IO.Path]::GetFullPath($Source)
    $fullDest = [System.IO.Path]::GetFullPath($Destination)
    $fullBuildRoot = [System.IO.Path]::GetFullPath($Script:FurphyBuildRoot)
    $fullTmpRoot = [System.IO.Path]::GetFullPath((Join-Path $Script:FurphyBuildRoot 'tests\.tmp'))

    $destWithSep = $fullDest.TrimEnd('\') + '\'
    $tmpRootWithSep = $fullTmpRoot.TrimEnd('\') + '\'
    $buildRootWithSep = $fullBuildRoot.TrimEnd('\') + '\'
    $sourceWithSep = $fullSource.TrimEnd('\') + '\'

    $destUnderTmpRoot = $destWithSep.ToLowerInvariant().StartsWith($tmpRootWithSep.ToLowerInvariant())
    $destInsideBuildRoot = $destWithSep.ToLowerInvariant().StartsWith($buildRootWithSep.ToLowerInvariant())

    if ((-not $destUnderTmpRoot) -and $destInsideBuildRoot) {
        throw "Copy-FurphyAppFiles: -Destination '$Destination' (resolves to '$fullDest') is inside the build root ('$fullBuildRoot') but not under tests\.tmp ('$fullTmpRoot') - refusing a nested-copy target. Use New-TempRoot to get a safe scratch root."
    }

    if ($sourceWithSep.ToLowerInvariant().StartsWith($destWithSep.ToLowerInvariant())) {
        throw "Copy-FurphyAppFiles: -Source '$Source' (resolves to '$fullSource') is inside -Destination '$Destination' (resolves to '$fullDest') - refusing, this is the 2026-09-08 incident shape in reverse."
    }

    if (-not (Test-Path -LiteralPath $fullDest)) {
        New-Item -ItemType Directory -Path $fullDest -Force | Out-Null
    }

    $syncSrc = Join-Path -Path $fullSource -ChildPath 'addon-sync.ps1'
    $serverSrc = Join-Path -Path $fullSource -ChildPath 'addon-server.ps1'
    $uiSrc = Join-Path -Path $fullSource -ChildPath 'ui'
    $hostBinSrc = Join-Path -Path $fullSource -ChildPath 'host\bin'

    foreach ($p in @($syncSrc, $serverSrc, $uiSrc, $hostBinSrc)) {
        if (-not (Test-Path -LiteralPath $p)) {
            throw "Copy-FurphyAppFiles: expected source item not found: $p"
        }
    }

    Copy-Item -LiteralPath $syncSrc -Destination (Join-Path -Path $fullDest -ChildPath 'addon-sync.ps1') -Force
    Copy-Item -LiteralPath $serverSrc -Destination (Join-Path -Path $fullDest -ChildPath 'addon-server.ps1') -Force
    Copy-Item -LiteralPath $uiSrc -Destination (Join-Path -Path $fullDest -ChildPath 'ui') -Recurse -Force

    $binDst = Join-Path -Path $fullDest -ChildPath 'host\bin'
    New-Item -ItemType Directory -Path $binDst -Force | Out-Null
    Get-ChildItem -LiteralPath $hostBinSrc -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $binDst -Recurse -Force
    }

    return $fullDest
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

function Get-TreeFingerprint {
    <#
      ADOPT-SPEC.md section 6.1/6.2: a deterministic, order-independent
      "did anything under -Path change" snapshot - one "<relative
      path>|<sha256 of file content>" string per file, sorted by relative
      path, plus the literal marker '<absent>' when -Path does not exist at
      all (so a caller comparing before/after also catches "the whole
      folder got deleted", not only "a file inside it changed"). Recurse +
      -File only (never records directory entries themselves - a folder
      being created/removed with no files in it would otherwise be
      invisible either way, which is fine: Furphy never creates an EMPTY
      folder as a meaningful side effect of anything this suite tests
      against this helper). Used by the tree-hash invariant test
      (installer-level, Install.NoAddonDataChange.Tests.ps1) and the
      CLI-level zero-filesystem-writes checks in Cli.Adopt.Tests.ps1 /
      Cli.AdoptFreshness.Tests.ps1 - the exact same fingerprint shape so a
      caller can diff two calls' output directly with Compare-Object or a
      plain array equality check.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return , @('<absent>')
    }
    $lines = Get-ChildItem -LiteralPath $Path -Recurse -File -Force |
        Sort-Object -Property FullName |
        ForEach-Object {
            $rel = $_.FullName.Substring($Path.Length).TrimStart('\')
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            "$rel|$hash"
        }
    return , @($lines)
}

function Read-JsonRecordsFile {
    <#
      Reads a JSON array file (addons.json, a -Json results/addons array,
      etc.) back as a real, flat PowerShell array - safe to index, filter,
      and (unlike a value straight out of ConvertFrom-Json) safe to
      PROPERTY-ASSIGN into an element of.

      The trap this works around, found live while writing
      Cli.AdoptFreshness.Tests.ps1: `ConvertFrom-Json` always writes its
      parsed result to the pipeline as ONE atomic object (never enumerated
      element-by-element), even when that result is itself an array. So
      `@(Get-Content ... -Raw | ConvertFrom-Json)` in a SINGLE statement
      does not do what it looks like it does for a JSON array with more
      than zero elements - `@()` wraps that one atomic array-shaped object
      into an OUTER one-element array, leaving a genuinely NESTED array
      ($result[0] is itself an array, not the first record) whenever the
      source JSON has one or more top-level elements. Confirmed live:
      member GET still silently "works" on the nested shape (PowerShell's
      member-enumeration reads a property across every element of an
      array), which is exactly why this can pass every read-only
      assertion in one test file and then throw "The property 'x' cannot
      be found on this object" the moment another file tries to
      PROPERTY-SET on what it assumed was a single record (array
      member-set is not supported the way member-get is).

      The fix is to let ConvertFrom-Json's result land in a plain
      variable FIRST (a separate statement - the value is then already
      realized, not an in-flight pipeline object) and wrap THAT in `@()`
      - never chain `@(... | ConvertFrom-Json)` as one expression again
      anywhere in this suite.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return , @()
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return , @()
    }
    $parsed = $raw | ConvertFrom-Json
    return , @($parsed)
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
        [int]$TimeoutSec = 60,
        # Round 26 (hardening, item 2): extra environment variables for
        # THIS child process only - never touches the test-runner's own
        # process environment, so a caller setting FURPHY_TEST_CF_BASEURL/
        # FURPHY_TEST_WAGO_BASEURL here cannot leak into any other test.
        [hashtable]$EnvironmentOverrides = @{}
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
    foreach ($key in $EnvironmentOverrides.Keys) {
        $psi.EnvironmentVariables[$key] = [string]$EnvironmentOverrides[$key]
    }

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
        [int]$TimeoutSec = 60,
        [hashtable]$EnvironmentOverrides = @{}
    )

    $r = Invoke-CliProcess -ScriptPath $ScriptPath -ArgumentList $ArgumentList -TimeoutSec $TimeoutSec -EnvironmentOverrides $EnvironmentOverrides
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
# CurseForge catalogue stub (F2 follow-up, launch-round): a real, local
# stand-in for the two raw.githubusercontent.com files addon-server.ps1's
# Save-CfCatalogueIndex fetches, now that $Script:CfCatalogueBaseUrl/
# FURPHY_TEST_CF_CATALOGUE_BASEURL gives that fetch a real override seam
# (mirrors $Script:WagoBaseUrl/FURPHY_TEST_WAGO_BASEURL exactly - see that
# variable's own doc comment in addon-server.ps1). Before this seam
# existed, the only way to make this fetch deterministic without touching
# the real internet was shots\launch\Start-ScratchServer.ps1's own trick of
# defining a same-named `Invoke-WebRequest` FUNCTION to shadow the cmdlet -
# fragile (relies on PowerShell's function-before-cmdlet scope resolution)
# and not reusable by an actual Pester test. This is just Start-StaticServer
# above, pointed at a temp directory laid out with the same two relative
# paths Save-CfCatalogueIndex requests
# (layday\instawow-data\data\base-catalogue-v8.compact.json and
# ogri-la\strongbox-catalogue\master\curseforge-catalogue.json) - a plain
# python http.server serves real files at real URLs, so nothing in
# addon-server.ps1 needs to know it isn't talking to the real GitHub host.
# ---------------------------------------------------------------------

function Start-CfCatalogueStubServer {
    <#
      Starts a Start-StaticServer instance seeded with a minimal-but-real-
      shaped instawow-data base-catalogue-v8.compact.json and strongbox-
      catalogue curseforge-catalogue.json, laid out under the same
      layday/... and ogri-la/... relative paths
      $Script:CfCatalogueBaseUrl + '/<path>' resolves to in addon-server.ps1.
      The seam is an environment variable, same as FURPHY_TEST_WAGO_BASEURL -
      set $env:FURPHY_TEST_CF_CATALOGUE_BASEURL = $stub.BaseUrl before
      spawning the server child (Start-Process inherits the current
      process's environment), matching exactly how existing tests already
      point $env:FURPHY_TEST_WAGO_BASEURL at tests\fixtures\wago-stub.

      -InstawowEntries / -StrongboxEntries: optional arrays of hashtables
      to seed each payload's `entries` / `addon-summary-list` with (default:
      one real-shaped, source:"curse"/"curseforge" entry each) - lets a
      caller build a specific merge/collision/id-only-in-one-source
      scenario without hand-writing the JSON shape every time.

      Returns the same shape Start-StaticServer does (Process/Port/
      Directory), plus BaseUrl - stop with Stop-StaticServer (same
      contract), then best-effort Remove-Item -Recurse the returned
      .Directory since this creates a fresh temp folder per call.
    #>
    param(
        [int]$Port,
        [array]$InstawowEntries = @(
            @{ id = '1'; name = 'StubCatalogueAddon'; slug = 'stubcatalogueaddon'; url = 'https://www.curseforge.com/wow/addons/stubcatalogueaddon'; source = 'curse'; download_count = 1000; last_updated = '2026-01-01T00:00:00Z' }
        ),
        [array]$StrongboxEntries = @()
    )

    $dir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('furphy-cf-catalogue-stub-' + [Guid]::NewGuid().ToString('N'))
    $instawowDir = Join-Path -Path $dir -ChildPath 'layday\instawow-data\data'
    $strongboxDir = Join-Path -Path $dir -ChildPath 'ogri-la\strongbox-catalogue\master'
    New-Item -ItemType Directory -Path $instawowDir -Force | Out-Null
    New-Item -ItemType Directory -Path $strongboxDir -Force | Out-Null

    # PS 5.1's `Set-Content -Encoding UTF8` always writes a BOM - harmless
    # for most files, but Save-CfCatalogueIndex's own ConvertFrom-Json
    # (the old JavaScriptSerializer-backed cmdlet on this PS version)
    # rejects a BOM-prefixed body outright ("Invalid JSON primitive")
    # rather than skipping it - confirmed live while writing this helper.
    # addon-server.ps1 itself already works around this exact gotcha
    # everywhere it writes JSON (its own `New-Object
    # System.Text.UTF8Encoding($false)` pattern) - mirrored here so a
    # Start-StaticServer response is byte-for-byte parseable the same way
    # a real raw.githubusercontent.com response is.
    $noBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $instawowDir 'base-catalogue-v8.compact.json'), (@{ entries = $InstawowEntries } | ConvertTo-Json -Depth 6), $noBom)
    [System.IO.File]::WriteAllText((Join-Path $strongboxDir 'curseforge-catalogue.json'), (@{ 'addon-summary-list' = $StrongboxEntries } | ConvertTo-Json -Depth 6), $noBom)

    $server = Start-StaticServer -Directory $dir -Port $Port
    $server | Add-Member -NotePropertyName BaseUrl -NotePropertyValue ('http://127.0.0.1:{0}' -f $server.Port) -PassThru
}

# ---------------------------------------------------------------------
# GitHub Releases API stub (Round 42 / APP-UPDATE-SPEC.md sections 12/13):
# a real, local stand-in for https://api.github.com's own
# /repos/krenz444/furphy-addon-manager/releases/latest, plus each
# release asset's own browser_download_url, now that $Script:GitHubBaseUrl/
# FURPHY_TEST_GITHUB_BASEURL gives that fetch a real override seam (mirrors
# $Script:WagoBaseUrl/FURPHY_TEST_WAGO_BASEURL exactly). The actual
# HttpListener lives in a separate real subprocess,
# tests\fixtures\github-release-stub\GitHubReleaseStubServer.ps1 (same
# shape as tests\fixtures\wago-stub\WagoStubServer.ps1) - this section is
# just the wrapper that builds the fixture files a scenario needs, writes
# the manifest that process reads, and starts/stops it.
#
# SHA256 SIDECAR FORMAT, CONFIRMED against Package A's real, landed code
# (addon-server.ps1's Invoke-AppUpdateMaintenanceCore): the integrity
# check reads the downloaded sidecar with
# `(Get-Content -Raw $shaPath).Trim().ToLowerInvariant()` and compares
# that WHOLE trimmed string directly against Get-FileHash's own .Hash -
# never splitting on whitespace, never taking "the first token". This
# stub therefore defaults to the BARE format (-ShaSidecarFormat 'bare')
# - a lone lowercase hex hash, nothing else - matching both
# APP-UPDATE-SPEC.md section 8.3/11's own literal example AND
# package.ps1's own Round 42 output exactly. An earlier draft of both
# this stub and package.ps1 used the two-column "sha256sum" shape
# instead; verified LIVE while writing this file to be a real,
# total-feature-breaking mismatch against Package A's actual comparison
# and fixed in both places before 1.22.0 shipped. Pass
# -ShaSidecarFormat 'sha256sum' only if Invoke-AppUpdateMaintenance's own
# comparison is ever changed to tolerate that shape - do not flip this
# default without re-checking that function's real code first.
# ---------------------------------------------------------------------

function New-GitHubReleaseFixtureZip {
    <#
      Builds a zip at -DestinationZipPath. Either -SourceDir (a folder
      whose CONTENTS are zipped - e.g. a complete scratch app tree built
      the same way Install.Downgrade.Tests.ps1's own
      New-StaleInstallerSource / Copy-FurphyAppFiles do, for a
      fixture-acceptance-grade "real app zip") or -Entries (a hashtable
      of relative-path -> string content, for a lightweight unit/
      integration-level zip that just needs a VERSION file and nothing
      else) - never both. -VersionOverride, if given, writes/overwrites
      a top-level VERSION file with that exact content AFTER staging
      -SourceDir's own copy (so a caller can start from a real app tree
      and still force a specific, possibly-wrong VERSION for a negative
      test) - for -Entries callers, just put the desired content directly
      in $Entries['VERSION'] instead.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DestinationZipPath,
        [string]$SourceDir,
        [hashtable]$Entries,
        [string]$VersionOverride
    )

    if ($SourceDir -and $Entries) {
        throw 'New-GitHubReleaseFixtureZip: pass -SourceDir or -Entries, never both'
    }

    $stageDir = New-TempRoot -Name 'github-release-zip-stage'
    if ($SourceDir) {
        if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
            throw "New-GitHubReleaseFixtureZip: -SourceDir not found: $SourceDir"
        }
        Get-ChildItem -LiteralPath $SourceDir -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $stageDir -Recurse -Force
        }
    } elseif ($Entries) {
        foreach ($rel in $Entries.Keys) {
            $dest = Join-Path -Path $stageDir -ChildPath $rel
            $destParent = Split-Path -Path $dest -Parent
            if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
                New-Item -ItemType Directory -Path $destParent -Force | Out-Null
            }
            [System.IO.File]::WriteAllText($dest, [string]$Entries[$rel], (New-Object System.Text.UTF8Encoding($false)))
        }
    } else {
        # Bare minimum default: a zip that is just a VERSION file - enough
        # for every unit/integration case that only cares whether the
        # downloaded package's VERSION matches the release tag, without
        # needing a caller to spell out -Entries every time.
        [System.IO.File]::WriteAllText((Join-Path $stageDir 'VERSION'), '0.0.0', (New-Object System.Text.UTF8Encoding($false)))
    }

    if ($VersionOverride) {
        [System.IO.File]::WriteAllText((Join-Path $stageDir 'VERSION'), $VersionOverride, (New-Object System.Text.UTF8Encoding($false)))
    }

    if (Test-Path -LiteralPath $DestinationZipPath) { Remove-Item -LiteralPath $DestinationZipPath -Force }
    $destDir = Split-Path -Path $DestinationZipPath -Parent
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Push-Location $stageDir
    try {
        Compress-Archive -Path '.\*' -DestinationPath $DestinationZipPath -Force
    } finally {
        Pop-Location
    }
    return $DestinationZipPath
}

function New-GitHubReleaseFixtureShaSidecar {
    <#
      Writes -DestinationShaPath from the REAL sha256 of -ZipPath (never
      the caller's own claim of what it should be), in either 'bare'
      (default - just the lowercase hex, no filename, no newline -
      matches APP-UPDATE-SPEC.md section 8.3/11's own literal example
      AND package.ps1's own Round 42 output AND Package A's real,
      landed whole-trimmed-string comparison in
      Invoke-AppUpdateMaintenanceCore) or the 'sha256sum' format
      ("<lowercasehex>  <zip file name>", two spaces, no trailing
      newline - the standard shape, NOT what this codebase's own
      integrity check actually parses; kept only for a future caller
      whose comparison logic is changed to tolerate it). -Tamper flips
      the sidecar's last hex character so the
      file it describes no longer matches - deliberately still a
      same-length, hex-looking string (a "the bytes changed in transit"
      shape), not a garbage string, since that is the realistic failure
      this knob exists to simulate (APP-UPDATE-SPEC.md section 12's
      "a TAMPERED sha256 (fixture with a deliberately wrong hash)").
      Returns the REAL hash (even when -Tamper is set) so a caller can
      assert against it directly.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$DestinationShaPath,
        [ValidateSet('sha256sum', 'bare')][string]$Format = 'bare',
        [switch]$Tamper
    )

    $realHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ZipPath).Hash.ToLowerInvariant()
    $writtenHash = $realHash
    if ($Tamper) {
        $lastChar = $writtenHash.Substring($writtenHash.Length - 1, 1)
        $flipped = if ($lastChar -eq '0') { '1' } else { '0' }
        $writtenHash = $writtenHash.Substring(0, $writtenHash.Length - 1) + $flipped
    }
    $content = $writtenHash
    if ($Format -eq 'sha256sum') {
        $content = '{0}  {1}' -f $writtenHash, (Split-Path -Path $ZipPath -Leaf)
    }
    [System.IO.File]::WriteAllText($DestinationShaPath, $content, (New-Object System.Text.UTF8Encoding($false)))
    return $realHash
}

function New-GitHubZipballFixtureZip {
    <#
      Round 47 (GITHUB-SOURCE-SPEC.md 7.2/3.6.2/3.6.3). Builds a raw
      GitHub-zipball-shaped zip at -DestinationZipPath: ONE top-level
      directory named "<Owner>-<RepoName>-<ShaSuffix>" (matching a real
      GitHub zipball's own wrapper-directory shape), so
      ConvertTo-NormalizedGithubZip's own wrapper-detection logic can be
      exercised end to end against a real, network-shaped fixture, not
      just the unit test's hand-built zips.

      -RootToc: the wrapper directory's OWN root holds the .toc file
        directly (the "root-.toc" case - decision 1's own "the folder is
        named after the repo" branch). Default (off): the wrapper
        directory holds ONE subfolder (named -FolderName, default =
        -RepoName) which itself holds the .toc (the normal, subfolder
        case) - both of 7.1's zipball-normalization scenarios get a real
        fixture this way, selected by this one switch.
      -TocVersion: the "## Version: ..." line written into the .toc
        (default 'v1') - set this to the release's own tag text so a
        caller can assert the installed addon's version matches.

      Returns -DestinationZipPath.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DestinationZipPath,
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$RepoName,
        [Parameter(Mandatory = $true)][string]$ShaSuffix,
        [switch]$RootToc,
        [string]$FolderName,
        [string]$TocVersion = 'v1'
    )

    if (-not $FolderName) { $FolderName = $RepoName }

    $stageDir = New-TempRoot -Name 'github-zipball-stage'
    $wrapperName = "$Owner-$RepoName-$ShaSuffix"
    $wrapperDir = Join-Path -Path $stageDir -ChildPath $wrapperName
    New-Item -ItemType Directory -Path $wrapperDir -Force | Out-Null

    $tocText = "## Interface: 110000`r`n## Title: $FolderName`r`n## Version: $TocVersion`r`n"
    if ($RootToc) {
        [System.IO.File]::WriteAllText((Join-Path $wrapperDir "$RepoName.toc"), $tocText, (New-Object System.Text.UTF8Encoding($false)))
    } else {
        $subDir = Join-Path -Path $wrapperDir -ChildPath $FolderName
        New-Item -ItemType Directory -Path $subDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $subDir "$FolderName.toc"), $tocText, (New-Object System.Text.UTF8Encoding($false)))
    }

    if (Test-Path -LiteralPath $DestinationZipPath) { Remove-Item -LiteralPath $DestinationZipPath -Force }
    $destDir = Split-Path -Path $DestinationZipPath -Parent
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Push-Location $stageDir
    try {
        Compress-Archive -Path '.\*' -DestinationPath $DestinationZipPath -Force
    } finally {
        Pop-Location
    }
    return $DestinationZipPath
}

function Start-GitHubReleaseStubServer {
    <#
      Starts the real GitHubReleaseStubServer.ps1 subprocess, after
      building whatever fixture zip/.sha256/extra-asset files this
      scenario needs. Set $env:FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl
      before spawning the real addon-server.ps1 child under test (exactly
      how existing tests already point FURPHY_TEST_WAGO_BASEURL at the
      Wago stub) - Start-Process inherits the current process's
      environment, so this reaches a spawned -AppUpdateOnly/
      -MaintenanceOnly child the same way. For a CLI-only test
      (addon-sync.ps1 directly, GITHUB-SOURCE-SPEC.md section 3), pass the
      same base URL via Invoke-CliProcess/-CliJson's own
      -EnvironmentOverrides instead - no server involved at all.

      -TagName: the release's tag_name (e.g. 'v1.23.0'; keep the leading
        'v', matching a real GitHub tag - the zip/sha asset names below
        always strip it, per APP-UPDATE-SPEC.md section 8.2).
      -ReleaseStatus / -RetryAfterSeconds / -RateLimitResetEpochSeconds:
        the rate-limit knob (section 8.1/16 Q2) - set -ReleaseStatus 403
        (or 429) plus one or both of the other two to exercise the
        Retry-After/X-RateLimit-Reset backoff path; 0 (the default) omits
        that header entirely.
      -RequireUserAgent: defaults $true (matches the real API - section
        8.1's "the GitHub API rejects requests with none"); the
        /releases/latest route 403s any request with no User-Agent
        header at all when this is set.
      -ZipSourceDir / -ZipEntries / -ZipVersionOverride: forwarded to
        New-GitHubReleaseFixtureZip (see that function's own doc comment)
        - the "wrong VERSION inside the zip" knob is just
        -ZipVersionOverride set to something other than the tag.
      -ShaSidecarFormat / -TamperSha256: forwarded to
        New-GitHubReleaseFixtureShaSidecar - the "TAMPERED sha256" knob.
      -OmitZipAsset / -OmitShaAsset: the release JSON's own assets[]
        array simply omits that entry (the "release missing the zip or
        .sha256 asset" case, section 12) - the underlying file is still
        built and still downloadable by its real name, since nothing
        under test should ever request an asset it was never told about.
      -ExtraAssets: array of @{name; content} hashtables - extra,
        unrelated assets listed (and downloadable) alongside the real
        pair, for the "release with EXTRA unrelated assets present" case
        (section 12's "must still pick the right two by exact name").

      Round 47 (GITHUB-SOURCE-SPEC.md 7.2) additions, all optional, all
      defaulting to today's exact self-update-fixture behavior:
      -Owner / -RepoName: which /repos/<owner>/<repoName>/releases/latest
        path the stub answers on - default 'krenz444'/
        'furphy-addon-manager' (the original hardcoded self-update path,
        so an existing caller that never sets these is unaffected).
      -RequireToken / -ExpectedToken: the private-repo simulation
        (GITHUB-SOURCE-SPEC.md 3.5) - when -RequireToken is set, the
        releases/latest, asset-by-id, and zipball routes all 404 unless
        the request's "Authorization: Bearer <token>" header matches
        -ExpectedToken exactly (missing OR wrong token -> the SAME 404,
        matching real GitHub's own behavior).
      -ZipballAvailable / -ZipballRootToc / -ZipballShaSuffix /
        -ZipballFolderName: the "no .zip asset, fall back to the
        zipball" path (3.6.2/3.6.3) - -ZipballAvailable adds
        zipball_url to the release JSON and serves a real
        New-GitHubZipballFixtureZip-built zip from the new zipball
        route; -ZipballRootToc selects that fixture's root-.toc layout
        instead of the default subfolder layout (see that function's own
        doc comment for both shapes).

      Returns {Process; Port; BaseUrl; ManifestPath; Owner; RepoName;
      TagName; ZipPath; ShaPath; ZipAssetName; ShaAssetName; ZipHash;
      ZipballFilePath} - stop with Stop-GitHubReleaseStubServer. Every
      file this creates lives under a New-TempRoot folder, so plain
      Remove-TempRoots at the end of a test file cleans it up same as
      everything else.
    #>
    param(
        [int]$Port,
        [string]$TagName = 'v1.23.0',
        [string]$HtmlUrl,
        [int]$ReleaseStatus = 200,
        [int]$RetryAfterSeconds = 0,
        [long]$RateLimitResetEpochSeconds = 0,
        [bool]$RequireUserAgent = $true,
        [string]$ZipSourceDir,
        [hashtable]$ZipEntries,
        [string]$ZipVersionOverride,
        [ValidateSet('sha256sum', 'bare')][string]$ShaSidecarFormat = 'bare',
        [switch]$TamperSha256,
        [switch]$OmitZipAsset,
        [switch]$OmitShaAsset,
        [array]$ExtraAssets = @(),
        [string]$Owner = 'krenz444',
        [string]$RepoName = 'furphy-addon-manager',
        [bool]$RequireToken = $false,
        [string]$ExpectedToken,
        [bool]$ZipballAvailable = $false,
        [switch]$ZipballRootToc,
        [string]$ZipballShaSuffix = 'a1b2c3d',
        [string]$ZipballFolderName
    )

    if (-not $Port) { $Port = Get-FreeStaticPort }
    if (-not $HtmlUrl) { $HtmlUrl = "https://github.com/$Owner/$RepoName/releases/tag/$TagName" }

    $tagNoV = $TagName.TrimStart('v', 'V')
    $zipName = "FurphyAddonManager-$tagNoV.zip"
    $shaName = "$zipName.sha256"

    $assetsDir = New-TempRoot -Name 'github-release-assets'
    $zipPath = Join-Path -Path $assetsDir -ChildPath $zipName
    $shaPath = Join-Path -Path $assetsDir -ChildPath $shaName

    New-GitHubReleaseFixtureZip -DestinationZipPath $zipPath -SourceDir $ZipSourceDir -Entries $ZipEntries -VersionOverride $ZipVersionOverride | Out-Null
    $realHash = New-GitHubReleaseFixtureShaSidecar -ZipPath $zipPath -DestinationShaPath $shaPath -Format $ShaSidecarFormat -Tamper:$TamperSha256

    $releaseAssets = New-Object 'System.Collections.Generic.List[object]'
    $downloadableAssets = New-Object 'System.Collections.Generic.List[object]'
    if (-not $OmitZipAsset) { $releaseAssets.Add([PSCustomObject]@{ name = $zipName }) }
    if (-not $OmitShaAsset) { $releaseAssets.Add([PSCustomObject]@{ name = $shaName }) }
    $downloadableAssets.Add([PSCustomObject]@{ name = $zipName; filePath = $zipPath })
    $downloadableAssets.Add([PSCustomObject]@{ name = $shaName; filePath = $shaPath })

    foreach ($extra in @($ExtraAssets)) {
        $extraName = [string]$extra.name
        $extraPath = Join-Path -Path $assetsDir -ChildPath $extraName
        # Round 47 addition: -ExtraAssets originally only ever wrote text
        # content (the self-update fixture's own "extra unrelated asset"
        # cases are all plain text). GITHUB-SOURCE-SPEC.md 7.1's
        # CLI.GithubAssetSelect.Tests.ps1 needs a SECOND, real, installable
        # zip asset (bytes, not text) alongside the main one to prove asset
        # selection prefers a repo-name match over an earlier-listed
        # non-matching asset - so a byte-array .content now writes the raw
        # bytes verbatim instead of being stringified first. Every existing
        # caller still passes a plain string and is unaffected.
        #
        # Checks BOTH [byte[]] and "a [byte]-only [object[]]" - confirmed
        # LIVE while writing this: a helper function that returns a
        # [byte[]] via the pipeline (`return [System.IO.File]::ReadAllBytes(...)`,
        # never `,` -prefixed or `Write-Output -NoEnumerate`) has that
        # array UNROLLED element-by-element onto the pipeline and
        # RE-COLLECTED by the caller as a generic System.Object[] - the
        # classic PS 5.1 "a function's own return silently unwraps an
        # array" trap. A caller building -ExtraAssets content from exactly
        # such a helper (easy to get wrong, hard to notice - the byte
        # VALUES survive perfectly, only the array's own CLR type changes)
        # would otherwise silently fall into the text branch below and
        # write "80 75 3 4 32 0 ..." (each byte's decimal text, space
        # -joined) instead of the real bytes - a corrupt file that is
        # still fully downloadable, just not a valid zip anymore.
        $isByteArray = ($extra.content -is [byte[]]) -or (($extra.content -is [array]) -and ($extra.content.Count -gt 0) -and ($extra.content[0] -is [byte]))
        if ($isByteArray) {
            [System.IO.File]::WriteAllBytes($extraPath, [byte[]]$extra.content)
        } else {
            [System.IO.File]::WriteAllText($extraPath, [string]$extra.content, (New-Object System.Text.UTF8Encoding($false)))
        }
        $releaseAssets.Add([PSCustomObject]@{ name = $extraName })
        $downloadableAssets.Add([PSCustomObject]@{ name = $extraName; filePath = $extraPath })
    }

    # Round 47 (7.2): the zipball fixture is built HERE (never by the stub
    # script itself, same "wrapper builds files, dumb server just serves
    # them" split as every other asset above) only when a caller opts in.
    $zipballFilePath = $null
    if ($ZipballAvailable) {
        $zipballFilePath = Join-Path -Path $assetsDir -ChildPath 'zipball.zip'
        New-GitHubZipballFixtureZip -DestinationZipPath $zipballFilePath -Owner $Owner -RepoName $RepoName -ShaSuffix $ZipballShaSuffix -RootToc:$ZipballRootToc -FolderName $ZipballFolderName -TocVersion $TagName | Out-Null
    }

    $manifest = [PSCustomObject]@{
        tagName                    = $TagName
        htmlUrl                    = $HtmlUrl
        owner                      = $Owner
        repoName                   = $RepoName
        requireToken               = $RequireToken
        expectedToken              = $ExpectedToken
        zipballAvailable           = $ZipballAvailable
        zipballFilePath            = $zipballFilePath
        releaseStatus              = $ReleaseStatus
        retryAfterSeconds          = $(if ($RetryAfterSeconds -gt 0) { $RetryAfterSeconds } else { $null })
        rateLimitResetEpochSeconds = $(if ($RateLimitResetEpochSeconds -gt 0) { $RateLimitResetEpochSeconds } else { $null })
        requireUserAgent           = $RequireUserAgent
        releaseAssets              = @($releaseAssets.ToArray())
        downloadableAssets         = @($downloadableAssets.ToArray())
    }
    $manifestDir = New-TempRoot -Name 'github-release-manifest'
    $manifestPath = Join-Path -Path $manifestDir -ChildPath 'manifest.json'
    ($manifest | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $scriptPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'tests\fixtures\github-release-stub\GitHubReleaseStubServer.ps1'
    $argList = New-Object 'System.Collections.Generic.List[string]'
    $argList.Add('-NoProfile')
    $argList.Add('-ExecutionPolicy')
    $argList.Add('Bypass')
    $argList.Add('-File')
    $argList.Add($scriptPath)
    $argList.Add('-Port'); $argList.Add([string]$Port)
    $argList.Add('-ManifestPath'); $argList.Add($manifestPath)

    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList.ToArray() -WindowStyle Hidden -PassThru

    if (-not (Wait-Port -Port $Port -TimeoutSec 15)) {
        try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } } catch { }
        throw "Start-GitHubReleaseStubServer: stub did not come up on port $Port within 15s"
    }

    return [PSCustomObject]@{
        Process         = $proc
        Port            = $Port
        BaseUrl         = "http://127.0.0.1:$Port"
        ManifestPath    = $manifestPath
        Owner           = $Owner
        RepoName        = $RepoName
        TagName         = $TagName
        ZipPath         = $zipPath
        ShaPath         = $shaPath
        ZipAssetName    = $zipName
        ShaAssetName    = $shaName
        ZipHash         = $realHash
        ZipballFilePath = $zipballFilePath
    }
}

function Stop-GitHubReleaseStubServer {
    <# Graceful POST /__control/shutdown, falls back to Stop-Process -Force. Always safe on a $Stub that never started. #>
    param($Stub)
    if (-not $Stub) { return }
    try {
        $req = [System.Net.HttpWebRequest]::Create("$($Stub.BaseUrl)/__control/shutdown")
        $req.Method = 'POST'
        $req.Timeout = 2000
        $req.ContentLength = 0
        $req.GetRequestStream().Close()
        $req.GetResponse().Close()
    } catch {
    }
    Start-Sleep -Milliseconds 150
    try {
        if ($Stub.Process -and -not $Stub.Process.HasExited) {
            Stop-Process -Id $Stub.Process.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {
    }
}

function Get-GitHubReleaseStubRequests {
    <# The stub's own request log (array of {method,path,timeUtc,hasUserAgent}), oldest first - always a real array, same `,@()` unwrap-guard as Get-WagoStubRequests. #>
    param($Stub)
    try {
        $resp = Invoke-RestMethod -Uri "$($Stub.BaseUrl)/__control/requests" -Method Get -TimeoutSec 5
        return , @($resp)
    } catch {
        throw "Get-GitHubReleaseStubRequests: could not reach stub control endpoint: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------
# App-update %TEMP% litter (this round's own fixer task): every real,
# end-to-end exercise of the self-updater - a scratch addon-server.ps1
# actually staging a release under $env:TEMP\FurphyUpdate-<tag>-<guid>
# (section 8.4), or a real install.ps1 -Upgrade run creating its own
# $env:TEMP\FurphyRollback-<hash> backup (section 8.6) - leaves a REAL
# folder behind under the real, shared %TEMP% that nothing in either
# pipeline's own normal success path deletes on its own (see
# Remove-AppUpdateStaleStaging's doc comment in addon-server.ps1 for why
# a staged folder is deliberately kept around by the PRODUCT itself for
# "one more tick" before a maintenance pass reclaims it - fine in
# production, but a test suite that runs this pipeline dozens of times a
# day must not just let all of them pile up forever). Found live: dozens
# of leftover FurphyUpdate-v88.*/v99.* and FurphyRollback-* folders under
# %TEMP% from earlier rounds' own runs of this exact test suite.
#
# -CreatedAfterUtc is mandatory and is never defaulted to "now" here on
# purpose - every caller must capture its OWN cutoff (plain
# `(Get-Date).ToUniversalTime()`) at the very top of its file/Describe,
# BEFORE anything that could stage a release or run -Upgrade, and pass
# that same value back in here. This is what keeps both functions safe
# to point at a broad prefix like "FurphyUpdate-" or "FurphyRollback-"
# without ever touching a folder some OTHER process (a real production
# install of this same app on this same machine, or another fixer's own
# concurrently-running test session on this same shared box) created
# before this run started, or is still in the middle of creating - see
# AppUpdate.SilentUpgrade.Tests.ps1's own "Targeted cleanup ONLY" comment
# for the exact same reasoning applied to a single deterministic path;
# this is that same guard generalized to a whole prefix.
# ---------------------------------------------------------------------

function Get-AppUpdateTempLitterFolders {
    <#
      Lists every %TEMP%\<Prefix>* directory whose own CreationTimeUtc is
      at or after -CreatedAfterUtc. Read-only - never deletes anything;
      exposed separately from Remove-AppUpdateTempLitter so a test can
      ASSERT on the exact list (e.g. "at most one FurphyRollback- folder
      exists for this dest", "no FurphyUpdate- folder survives this run")
      rather than only being able to sweep it away. Never throws - an
      unreadable %TEMP% (never expected in practice) or a folder that
      disappears mid-enumeration (a benign race with something else
      cleaning up concurrently) is simply not counted, and returns an
      empty array rather than a $null single value even when nothing
      matches.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][datetime]$CreatedAfterUtc
    )
    $tempPath = [System.IO.Path]::GetTempPath()
    $candidates = @()
    try {
        $candidates = Get-ChildItem -LiteralPath $tempPath -Directory -Filter ($Prefix + '*') -Force -ErrorAction SilentlyContinue
    } catch {
        $candidates = @()
    }
    $matches = New-Object 'System.Collections.Generic.List[string]'
    foreach ($dir in @($candidates)) {
        try {
            if ($dir.CreationTimeUtc -ge $CreatedAfterUtc) { $matches.Add($dir.FullName) }
        } catch {
            # Gone or inaccessible between enumeration and this read - skip.
        }
    }
    return , @($matches.ToArray())
}

function Remove-AppUpdateTempLitter {
    <#
      Best-effort recursive delete of every folder
      Get-AppUpdateTempLitterFolders finds for -Prefix / -CreatedAfterUtc
      (see that function's own doc comment for the exact same safety
      contract - never a folder older than -CreatedAfterUtc). Call once
      per prefix ("FurphyUpdate-" / "FurphyRollback-", or a more specific
      "FurphyUpdate-<exact tag>-" when a caller already knows its own
      exact release tag and wants a narrower, even-more-collision-proof
      match) in an AfterAll/finally, after recording -CreatedAfterUtc at
      the very start of the test file/Describe. Never throws - a locked
      folder (AV, an orphaned child process still holding a handle) is
      logged to the host and skipped, not fatal to the run, same contract
      as Remove-TempRoots. Returns the count actually removed.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][datetime]$CreatedAfterUtc
    )
    $removed = 0
    # Deliberately NOT `@(Get-AppUpdateTempLitterFolders ...)` here - that
    # function already returns via the `, @(...)` idiom (a single pipeline
    # object that IS the array, guarding against PowerShell collapsing an
    # empty array to $null on return - see its own doc comment). Wrapping
    # the CALL SITE in a second @() double-wraps it into a 1-element array
    # whose single element is the (possibly empty) inner array - found
    # live while verifying this file: with zero matches, $full then became
    # that inner EMPTY ARRAY itself rather than never looping at all,
    # and Test-Path -LiteralPath $full failed to bind ("...because it is
    # an empty array"). A bare `foreach ($full in (Get-Foo))` already
    # iterates a comma-wrapped function's elements correctly, empty or
    # not - no extra @() needed or wanted here.
    foreach ($full in (Get-AppUpdateTempLitterFolders -Prefix $Prefix -CreatedAfterUtc $CreatedAfterUtc)) {
        try {
            if (Test-Path -LiteralPath $full) {
                Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
                $removed++
            }
        } catch {
            Write-Host "WARN: could not remove app-update temp litter '$full': $($_.Exception.Message)"
        }
    }
    return $removed
}

function Get-UninstallTempLitterFiles {
    <#
      Lists every %TEMP%\FurphyUninstall-*.ps1 / %TEMP%\FurphyUninstall-*.log
      file whose own CreationTimeUtc is at or after -CreatedAfterUtc - the
      same scoped-cleanup contract as Get-AppUpdateTempLitterFolders (that
      function's own doc comment), adapted for FILES rather than
      directories. GAME-MODE-SPEC.md-round test hygiene fix (260 leftover
      copies found on the dev machine): install.ps1's own -Uninstall
      self-delete (novice:NOVICE-3) removes its %TEMP% .ps1 copy on a
      clean run, and its paired .log is deliberately never auto-deleted by
      the product either way - but a test that only cleans up inline,
      after its own last assertion, leaves BOTH behind the instant an
      earlier assertion in the same It throws first. Read-only - never
      deletes anything; exposed separately from
      Remove-UninstallTempLitterFiles so a test can assert on the exact
      list, same reasoning as the App-Update sibling.
    #>
    param(
        [Parameter(Mandatory = $true)][datetime]$CreatedAfterUtc
    )
    $tempPath = [System.IO.Path]::GetTempPath()
    $candidates = @()
    try {
        $candidates = Get-ChildItem -LiteralPath $tempPath -File -Filter 'FurphyUninstall-*' -Force -ErrorAction SilentlyContinue
    } catch {
        $candidates = @()
    }
    $matches = New-Object 'System.Collections.Generic.List[string]'
    foreach ($f in @($candidates)) {
        try {
            if (($f.Extension -eq '.ps1' -or $f.Extension -eq '.log') -and $f.CreationTimeUtc -ge $CreatedAfterUtc) {
                $matches.Add($f.FullName)
            }
        } catch {
            # Gone or inaccessible between enumeration and this read - skip.
        }
    }
    return , @($matches.ToArray())
}

function Remove-UninstallTempLitterFiles {
    <#
      Best-effort delete of every file Get-UninstallTempLitterFiles finds
      for -CreatedAfterUtc. Call once per test FILE in an AfterAll, after
      recording -CreatedAfterUtc at the very top of that file (mirrors
      Server.AppUpdate.Tests.ps1's own $Script:LitterCutoffUtc pattern) -
      this way every It in the file is covered by ONE sweep that always
      runs, regardless of which assertion (if any) threw first, instead
      of each It trying to clean up only its own exact new file via a
      before/after set difference that a mid-It failure skips entirely.
      Never throws - a locked file (the just-exited install.ps1 process
      may still briefly hold its own script/log file open) is logged to
      the host and skipped, not fatal to the run, same contract as
      Remove-AppUpdateTempLitter. Returns the count actually removed.
    #>
    param(
        [Parameter(Mandatory = $true)][datetime]$CreatedAfterUtc
    )
    $removed = 0
    foreach ($full in (Get-UninstallTempLitterFiles -CreatedAfterUtc $CreatedAfterUtc)) {
        try {
            if (Test-Path -LiteralPath $full) {
                Remove-Item -LiteralPath $full -Force -ErrorAction Stop
                $removed++
            }
        } catch {
            Write-Host "WARN: could not remove uninstall temp litter '$full': $($_.Exception.Message)"
        }
    }
    return $removed
}

# ---------------------------------------------------------------------
# Black-hole TCP listener (Round 26 hardening, item 2): accepts a real TCP
# connection and never reads or responds - used to prove addon-sync.ps1's
# FURPHY_TEST_CF_BASEURL/FURPHY_TEST_WAGO_BASEURL override actually reaches
# the real HTTP call sites, and that a caller's own -TimeoutSec is what
# actually bounds a real run even when every network call would otherwise
# hang forever waiting on a connection that never answers.
# ---------------------------------------------------------------------

function Start-BlackHoleListener {
    <#
      Starts a plain System.Net.Sockets.TcpListener on -Port and returns it
      immediately - deliberately NEVER calls AcceptTcpClient/reads/writes.
      A real TCP connect against this port still succeeds (the OS completes
      the handshake and queues the connection in the listen backlog the
      moment Start() is called, with no application-level accept needed for
      that), but no HTTP request sent over it ever gets a response - the
      client's own request timeout is what eventually ends the call. Stop
      with Stop-BlackHoleListener.
    #>
    param([int]$Port)

    $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    if (-not (Test-PortOpen -Port $Port -TimeoutMs 2000)) {
        try { $listener.Stop() } catch { }
        throw "Start-BlackHoleListener: port $Port did not come up"
    }
    return $listener
}

function Stop-BlackHoleListener {
    param($Listener)
    if (-not $Listener) { return }
    try { $Listener.Stop() } catch { }
}

# ---------------------------------------------------------------------
# addon-server.ps1 test instance
# ---------------------------------------------------------------------

function Get-FurphyProcessCommandLine {
    <#
      Round 26 (hardening, item 1): returns the full command line of a live
      process id via Win32_Process (Get-Process alone exposes no command
      line), or $null if the process is gone/inaccessible. Used to tell a
      genuine straggler addon-server.ps1 (ours - safe to force-stop) apart
      from some unrelated process that just happens to be squatting on the
      test port (never ours - must not be touched).
    #>
    param([int]$ProcessId)
    try {
        $wp = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
        if ($wp) { return [string]$wp.CommandLine }
    } catch {
    }
    return $null
}

function Clear-StaleTestServerOnPort {
    <#
      Round 26 (hardening, item 1): if -Port is already answering a TCP
      connect, look for the OWNING process and force-stop it ONLY when its
      own command line clearly identifies it as one of ours (an
      addon-server.ps1 invocation - matches this same pattern regardless of
      which -Root/-Port a prior interrupted run used). A port held by
      anything else (some unrelated process, or a process Win32_Process
      could not be queried for) is left alone and Start-TestServer still
      throws, same as before this fix - this only removes the one class of
      stale-server false failure a crashed/Ctrl+C'd prior test run leaves
      behind, never a blind "kill whatever is on the port".
      Returns $true if the port was busy but is now confirmed free (or was
      never busy to begin with), $false if it is still busy with something
      this function declined to touch.
    #>
    param([int]$Port)

    if (-not (Test-PortOpen -Port $Port -TimeoutMs 300)) { return $true }

    $killedAny = $false
    try {
        $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        foreach ($c in @($conns)) {
            $cmdLine = Get-FurphyProcessCommandLine -ProcessId $c.OwningProcess
            if ($cmdLine -and $cmdLine -match 'addon-server\.ps1') {
                Write-Host "  Start-TestServer: port $Port held by a straggler addon-server.ps1 (PID $($c.OwningProcess)) from an interrupted prior run - force-stopping it. Command line: $cmdLine" -ForegroundColor Yellow
                try { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue } catch { }
                $killedAny = $true
            }
        }
    } catch {
        # Get-NetTCPConnection unavailable/failed - fall through to the
        # plain re-check below; Start-TestServer still throws its own clear
        # error if the port is genuinely still busy.
    }

    if ($killedAny) {
        # Give the OS a moment to actually release the socket.
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline) {
            if (-not (Test-PortOpen -Port $Port -TimeoutMs 300)) { return $true }
            Start-Sleep -Milliseconds 200
        }
    }

    return -not (Test-PortOpen -Port $Port -TimeoutMs 300)
}

function Get-LastLogLines {
    <# Returns the last -Lines of -Path as a single newline-joined string, or a one-line "no log" note. Never throws. #>
    param([string]$Path, [int]$Lines = 20)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return "(no log at $Path)" }
        $tail = Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop
        if (-not $tail) { return "(log at $Path is empty)" }
        return ($tail -join "`n")
    } catch {
        return "(could not read log at $Path : $($_.Exception.Message))"
    }
}

function Start-TestServer {
    <#
      Starts addon-server.ps1 (from -ScriptPath, default
      <BuildRoot>\addon-server.ps1) hidden, rooted at -Root, listening on
      -Port (default 47899 per the task brief - never the real 47831).
      Waits for /api/ping to answer before returning. Returns an object
      Stop-TestServer accepts.

      Round 26 (hardening, item 1): three reliability fixes to the readiness
      wait, made after a full-suite run showed
      "server on port 47899 did not answer /api/ping in time" fail once and
      pass on rerun (real flakiness under combined load - headless Edge,
      the perf layer, and many server starts contending for CPU/disk at
      once can push a real cold start past the old, tight budget):
        1. A stale port is no longer an automatic hard failure - see
           Clear-StaleTestServerOnPort above, called before the port-busy
           check below even throws.
        2. The /api/ping wait now backs off (200ms up to a 2s ceiling,
           doubling) instead of a fixed 250ms poll, and the combined
           Wait-Port + ping-retry budget is 60 seconds (was effectively
           ~20s: a 15s Wait-Port timeout plus 20 fixed 250ms-spaced
           attempts) - long enough to absorb a genuinely slow cold start
           instead of just a slightly-larger fixed one.
        3. A timeout failure now includes the server's own last 20
           server.log lines (Get-LastLogLines) in the thrown message, so a
           real failure (a startup exception, a bind failure, a hung
           migration) is diagnosable from the test output directly instead
           of needing a separate manual repro.
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
    if (-not (Clear-StaleTestServerOnPort -Port $Port)) {
        throw "Start-TestServer: port $Port already in use by something that is NOT one of our own addon-server.ps1 processes - refusing to touch it. Stop whatever owns port $Port first (or run tests\run-all.ps1, whose hygiene sweep now also runs at the START of a run, not only in its trailing finally)."
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

    # Round-1-fixer (verifier findings 1 and 4): almost every caller of this
    # helper has zero interest in Wago at all, yet
    # Initialize-WagoGrowthSnapshots used to run an unconditional, real
    # crawl against the live addons.wago.io on every fresh server startup -
    # a genuine live-safety/politeness regression paid independently by
    # ~86 integration tests, and (via a related host-side path) the root
    # cause of a 100%-reproducible tests\host\Host.Tests.ps1:450 failure.
    # Skip that crawl by default for this spawned child UNLESS the caller
    # has itself already opted into real Wago-crawl behavior by pointing
    # FURPHY_TEST_WAGO_BASEURL at a local stub before calling this function
    # (exactly what the Wago-specific integration Describes in
    # tests\integration\Server.WagoBrowse.Tests.ps1 do around their own
    # Start-TestServer call) or by setting the skip var itself for some
    # other reason. The env var is set only long enough for Start-Process
    # to inherit it into the child's own environment block, then restored
    # to its exact prior value (not merely removed) so it can never leak
    # into any later Start-Process call in this same test session.
    $originalSkipGrowthEnv = $env:FURPHY_TEST_SKIP_WAGO_GROWTH
    $skipGrowthEnvChanged = $false
    if ([string]::IsNullOrWhiteSpace($env:FURPHY_TEST_WAGO_BASEURL) -and [string]::IsNullOrWhiteSpace($env:FURPHY_TEST_SKIP_WAGO_GROWTH)) {
        $env:FURPHY_TEST_SKIP_WAGO_GROWTH = '1'
        $skipGrowthEnvChanged = $true
    }

    # Round-36-fixer follow-up (verifier finding, non-blocking): the exact
    # same live-safety/politeness gap as FURPHY_TEST_SKIP_WAGO_GROWTH above,
    # just for the CurseForge catalogue instead of the Wago growth crawl -
    # Initialize-CfCatalogueIndex already honors FURPHY_TEST_SKIP_CF_CATALOGUE
    # (addon-server.ps1's own $Script:SkipCfCatalogueFetch), but nothing here
    # ever set it, so every one of this helper's ~many callers across the
    # integration layer paid for a real, live CurseForge catalogue fetch
    # (raw.githubusercontent.com via instawow-data/strongbox) on every fresh
    # server startup. Same opt-out contract as the Wago case: skip by default
    # UNLESS the caller has already pointed FURPHY_TEST_CF_BASEURL at a local
    # stub (a real CF-catalogue Describe wants the genuine fetch path against
    # its own stub) or set the skip var itself for some other reason. Same
    # inherit-then-restore-exact-prior-value handling as the Wago var, so it
    # can never leak into a later Start-Process call in this same session.
    $originalSkipCfCatalogueEnv = $env:FURPHY_TEST_SKIP_CF_CATALOGUE
    $skipCfCatalogueEnvChanged = $false
    if ([string]::IsNullOrWhiteSpace($env:FURPHY_TEST_CF_BASEURL) -and [string]::IsNullOrWhiteSpace($env:FURPHY_TEST_SKIP_CF_CATALOGUE)) {
        $env:FURPHY_TEST_SKIP_CF_CATALOGUE = '1'
        $skipCfCatalogueEnvChanged = $true
    }

    # Round 42 (APP-UPDATE-SPEC.md, Package E): the EXACT same live-safety/
    # politeness gap as the two guards above, for the new self-updater's
    # own GitHub Releases check - confirmed LIVE while writing this
    # round's own integration tests: Invoke-MaintenanceTick's very first
    # "-MaintenanceOnly" tick after startup "always qualifies" (its own
    # doc comment), and now unconditionally also runs
    # Invoke-AppUpdateMaintenance - so EVERY caller of Start-TestServer,
    # not just this round's own new tests, was making one real,
    # unauthenticated GET to the real api.github.com
    # (/repos/krenz444/furphy-addon-manager/releases/latest) on every
    # single fresh server startup, well before a caller's own
    # $env:FURPHY_TEST_GITHUB_BASEURL = $stub.BaseUrl assignment (made
    # AFTER Start-TestServer returns, in every existing call-site
    # convention this file documents) has any chance to take effect -
    # a direct violation of this build's own standing "never touch the
    # real GitHub from any script or test" rule, hit by this suite's
    # OWN tooling rather than by any test's authored intent. Unlike the
    # Wago/CF cases, Package A's app-update pipeline exposes no
    # dedicated FURPHY_TEST_SKIP_* flag of its own to gate on (there is
    # nothing to "skip" independently of the base-URL seam itself) - so
    # the fix here defaults $env:FURPHY_TEST_GITHUB_BASEURL itself to a
    # guaranteed-closed loopback port (an immediate, fast connection
    # refusal, never a slow timeout) UNLESS the caller has already
    # pointed it at a real local stub before calling this function -
    # same opt-out contract, same inherit-then-restore-exact-prior-value
    # handling, so it can never leak into a later Start-Process call in
    # this same session.
    $originalGitHubBaseUrlEnv = $env:FURPHY_TEST_GITHUB_BASEURL
    $githubBaseUrlEnvChanged = $false
    if ([string]::IsNullOrWhiteSpace($env:FURPHY_TEST_GITHUB_BASEURL)) {
        $env:FURPHY_TEST_GITHUB_BASEURL = 'http://127.0.0.1:1'
        $githubBaseUrlEnvChanged = $true
    }
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList.ToArray() -WindowStyle Hidden -PassThru
    } finally {
        if ($skipGrowthEnvChanged) {
            if ($null -eq $originalSkipGrowthEnv) {
                Remove-Item Env:\FURPHY_TEST_SKIP_WAGO_GROWTH -ErrorAction SilentlyContinue
            } else {
                $env:FURPHY_TEST_SKIP_WAGO_GROWTH = $originalSkipGrowthEnv
            }
        }
        if ($skipCfCatalogueEnvChanged) {
            if ($null -eq $originalSkipCfCatalogueEnv) {
                Remove-Item Env:\FURPHY_TEST_SKIP_CF_CATALOGUE -ErrorAction SilentlyContinue
            } else {
                $env:FURPHY_TEST_SKIP_CF_CATALOGUE = $originalSkipCfCatalogueEnv
            }
        }
        if ($githubBaseUrlEnvChanged) {
            if ($null -eq $originalGitHubBaseUrlEnv) {
                Remove-Item Env:\FURPHY_TEST_GITHUB_BASEURL -ErrorAction SilentlyContinue
            } else {
                $env:FURPHY_TEST_GITHUB_BASEURL = $originalGitHubBaseUrlEnv
            }
        }
    }

    # Round 26 (hardening, item 1): one 60-second overall budget covering
    # both the TCP-level wait AND the ping-retry wait (was a fixed ~15s +
    # ~20*0.25s split that could time out well before a genuinely slow
    # cold start under heavy combined-suite load finished). Backs off
    # 200ms -> 2s (doubling, capped) between attempts instead of a fixed
    # 250ms poll, so a slow start does not burn the whole budget on
    # excessive short-interval retries.
    $overallDeadline = (Get-Date).AddSeconds(60)
    $portReady = $false
    while ((Get-Date) -lt $overallDeadline) {
        if (Test-PortOpen -Port $Port -TimeoutMs 300) { $portReady = $true; break }
        Start-Sleep -Milliseconds 200
    }

    $up = $false
    if ($portReady) {
        $backoffMs = 200
        while ((Get-Date) -lt $overallDeadline) {
            try {
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/ping" -Method Get -TimeoutSec 2 | Out-Null
                $up = $true
                break
            } catch {
                Start-Sleep -Milliseconds $backoffMs
                $backoffMs = [Math]::Min($backoffMs * 2, 2000)
            }
        }
    }
    if (-not $up) {
        try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } } catch { }
        $logPath = Join-Path -Path $Root -ChildPath 'server.log'
        $tail = Get-LastLogLines -Path $logPath -Lines 20
        throw "Start-TestServer: server on port $Port did not answer /api/ping in time (60s budget exhausted, portReady=$portReady). Last lines of $logPath :`n$tail"
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

function Wait-ProcessReallyGone {
    <#
      Polls until -ProcessId no longer resolves to a live process (Get-
      Process returns nothing), or -TimeoutSec elapses. Stop-Process
      -Force (TerminateProcess) is not synchronous - a caller that moves
      on immediately can still observe the process as alive for a short
      window. Any cleanup that hands off shared OS state to the next
      test/Describe (a per-port named Mutex, a shared HKCU value, a
      shared port, or a shared live-tray-pid snapshot) must wait here
      first, not assume Stop-Process's own return means "gone".
    #>
    param([int]$ProcessId, [int]$TimeoutSec = 5)
    if ($ProcessId -le 0) { return $true }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return -not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
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
    # RawText (Round 47 addition): the exact response body text, before
    # ConvertFrom-Json - lets a caller assert a literal substring (e.g. "this
    # secret string never appears in the raw wire response") without
    # relying on a parsed-then-reserialized round-trip to preserve it
    # faithfully. Purely additive - every existing caller reads only
    # Ok/StatusCode/Body/Error and is unaffected.
    return [PSCustomObject]@{ Ok = $ok; StatusCode = $status; Body = $parsedBody; Error = $errorMessage; RawText = $text }
}

function Invoke-ApiConcurrentPair {
    <#
      Fires two GET calls against the local test server TRULY
      concurrently - both requests actually in flight on the wire at
      once, via HttpWebRequest's async GetResponseAsync, never two
      sequential Invoke-Api calls one after the other (that would never
      put both on the wire at the same time: the second call's own TCP
      connect wouldn't even begin until the first call's response had
      been fully read). Returns @{ A; B }, each in Invoke-Api's own {Ok;
      StatusCode; Body; Error} shape plus CompletedAtUtc, so a caller can
      see which of the two the server actually finished first.

      Used by regression tests proving two DIFFERENT concurrent requests
      never cross-contaminate each other's response body regardless of
      which one the server happens to finish first (see
      tests\integration\Server.WagoBrowse.Tests.ps1's "distinct search
      queries never cross-contaminate" Describe, the regression guard for
      regression-guards:wago-search-stale-response-no-guard-test /
      ui\app.js's fetchWago wagoFetchSeq guard). Note addon-server.ps1's
      own request loop is fully sequential (one EndGetContext ->
      Invoke-Route -> BeginGetContext at a time - see that loop's own
      comment near the bottom of addon-server.ps1), so this helper cannot
      force a genuine "later response overtakes an earlier one" the way a
      slow real upstream occasionally can in production; what firing both
      requests concurrently here DOES prove, deterministically, is that
      neither response is corrupted by the other being in flight at the
      same time - the necessary condition for any client-side "ignore the
      stale one" sequence guard to be safe (if a shared/mutable bit of
      server state ever bled between two concurrently-handled requests,
      this is what would catch it).

      Only ever used for GET (no body, no CSRF Origin requirement to
      satisfy beyond the harmless same-origin header every Invoke-Api
      call already sends) - not a general Invoke-Api replacement.
    #>
    param(
        [int]$Port = 47899,
        [Parameter(Mandatory = $true)][string]$PathA,
        [Parameter(Mandatory = $true)][string]$PathB,
        [int]$TimeoutSec = 30
    )

    function New-FurphyAsyncGetRequest {
        param([int]$P, [string]$Path)
        $uri = "http://127.0.0.1:$P$Path"
        $req = [System.Net.HttpWebRequest]::Create($uri)
        $req.Method = 'GET'
        $req.KeepAlive = $false
        $req.Timeout = $TimeoutSec * 1000
        $req.Headers.Set('Origin', "http://localhost:$P")
        return $req
    }

    function Receive-FurphyAsyncGetResult {
        param($Request, $Task)
        $status = 0
        $errorMessage = $null
        $webResp = $null
        try {
            if (-not $Task.Wait($TimeoutSec * 1000)) {
                throw "request to $($Request.RequestUri) did not complete within ${TimeoutSec}s"
            }
            $webResp = $Task.Result
            $status = [int]$webResp.StatusCode
        } catch {
            $inner = $_.Exception
            if ($inner -is [System.AggregateException] -and $inner.InnerException) { $inner = $inner.InnerException }
            if ($inner -is [System.Net.WebException] -and $inner.Response) {
                $webResp = $inner.Response
                try { $status = [int]$webResp.StatusCode } catch { $status = 0 }
            } else {
                $errorMessage = $inner.Message
            }
        }
        $completedAt = (Get-Date).ToUniversalTime()
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
        return [PSCustomObject]@{ Ok = $ok; StatusCode = $status; Body = $parsedBody; Error = $errorMessage; CompletedAtUtc = $completedAt }
    }

    $reqA = New-FurphyAsyncGetRequest -P $Port -Path $PathA
    $reqB = New-FurphyAsyncGetRequest -P $Port -Path $PathB
    # Both async calls started back-to-back with nothing awaited in
    # between - THIS is what actually puts both requests on the wire at
    # once. Whichever order this function later reads the two Task
    # results back in has no bearing on which one the server itself
    # serviced first.
    $taskA = $reqA.GetResponseAsync()
    $taskB = $reqB.GetResponseAsync()

    $resultA = Receive-FurphyAsyncGetResult -Request $reqA -Task $taskA
    $resultB = Receive-FurphyAsyncGetResult -Request $reqB -Task $taskB

    return [PSCustomObject]@{ A = $resultA; B = $resultB }
}

# ---------------------------------------------------------------------
# Bitmap inspection (verify-capture.ps1's PrintWindow-corruption guard -
# installer-dpi:verify-capture-printwindow-pw2-corrupts-installer-window).
# Pure, unit-testable pixel math with no window/process/HDC involvement,
# kept here (rather than only inline in shots\verify-capture.ps1) so a
# static/unit test can exercise it directly against a synthetic Bitmap.
# ---------------------------------------------------------------------

function Get-CaptureCorruptionFraction {
    <#
      Scans -Bitmap and returns the fraction (0.0-1.0) of sampled pixels
      that look like a PrintWindow(hwnd, hdc, 2)/PW_RENDERFULLCONTENT
      capture failed to actually paint into - either signature observed
      live, on two different machines, of the SAME underlying defect
      (installer-dpi:verify-capture-printwindow-pw2-corrupts-installer-
      window):
        1. Fully OPAQUE, near-black (alpha=255, R/G/B all <
           -BlackThreshold, default 10) - the finding's own originally
           reported repro: large solid-black bottom/left bands on that
           machine, where the real on-screen window has none.
        2. NOT fully opaque at all (alpha < 255 - in practice this GDI+
           path only ever produces exactly alpha=0, never a partial
           value, so this is effectively "still showing the freshly-
           allocated Bitmap's own default pixels, never touched by
           PrintWindow") - confirmed independently live on a SECOND
           machine while building this fix: an otherwise-normal WinForms
           form's nFlags=2 capture came back ~36% fully transparent
           (large bottom/right regions, the New-Object
           System.Drawing.Bitmap default), with only ~4% actually opaque-
           black - a real capture this size/shape would have read as
           "fine" under signature 1 alone despite being ~40% garbage.
           Both are the same root cause (PrintWindow silently declining
           to paint part of the surface under nFlags=2) with a
           machine/GPU/driver-dependent visual result, so both must
           count.

      Sampled on a -Stride grid (every Nth pixel on both axes, default 4)
      rather than every pixel - fast enough even against a large window
      capture (FurphyHost.exe's main window, say), and the corruption
      this guards against paints in large contiguous bands, never
      isolated stray pixels, so a sparse grid finds it exactly as
      reliably as an exhaustive per-pixel scan while running in a small
      fraction of the time Bitmap.GetPixel's well-known per-call overhead
      would otherwise cost on every pixel of a real window-sized capture.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Drawing.Bitmap]$Bitmap,
        [int]$BlackThreshold = 10,
        [int]$Stride = 4
    )

    $w = $Bitmap.Width
    $h = $Bitmap.Height
    if ($w -le 0 -or $h -le 0) { return 0.0 }
    if ($Stride -lt 1) { $Stride = 1 }

    $sampled = 0
    $bad = 0
    for ($y = 0; $y -lt $h; $y += $Stride) {
        for ($x = 0; $x -lt $w; $x += $Stride) {
            $px = $Bitmap.GetPixel($x, $y)
            $sampled++
            if ($px.A -lt 255) {
                $bad++
            } elseif ($px.R -lt $BlackThreshold -and $px.G -lt $BlackThreshold -and $px.B -lt $BlackThreshold) {
                $bad++
            }
        }
    }
    if ($sampled -eq 0) { return 0.0 }
    return ([double]$bad / [double]$sampled)
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
