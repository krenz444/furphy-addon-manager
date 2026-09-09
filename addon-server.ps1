<#
=====================================================================
 addon-server.ps1

 Local HTTP server for the Furphy Addon Manager. Serves the ui\ single
 page app and a JSON API, runs addon-sync.ps1 as hidden child
 processes for long operations, and proxies the official CurseForge
 Core API when a key is configured in settings.json.

 Windows PowerShell 5.1 only. No modules, no external binaries, pure
 ASCII. System.Net.HttpListener, single-threaded request loop.

 LAYOUT (relative to -Root):
   addon-server.ps1  this script
   addon-sync.ps1    the CLI this script drives
   addons.json       addon records (read-only from here; the CLI owns it)
   settings.json     shared settings (created with defaults if missing)
   state.json        persisted check results and job history (E2:
                       updatesCheckedAt + updateAvailable; Round 3: lastRun +
                       the last 20 job status views), written after every
                       job completes and reloaded at startup
   ui\               static frontend files
   jobs\             per-job stdout/stderr capture files
   sync.log          CLI log (tailed for job progress)
   server.log        this script's own request/error log

 USAGE:
   addon-server.ps1 [-Port <int>] [-Root <path>] [-AddonsPath <path>]
                     [-IdleMinutes <int>] [-OpenBrowser]

   -Port <int>         Listener port. Default: settings.json port, else 47831.
   -Root <path>        Folder holding the files above. Default: $PSScriptRoot.
   -AddonsPath <path>  Forwarded to every CLI call as -AddonsPath. Default:
                        let the CLI auto-detect from its own location.
   -IdleMinutes <int>  Exit after this many minutes with no request. Default 20.
                        0 or negative disables idle exit.
   -OpenBrowser        After starting, launch Edge in app mode pointed at the
                        server (falls back to the default browser).
   -BuildInfoPath <path>  Overrides the .build.info file read for the client
                        build/compat check (E13), computed once at startup.
                        Default: the .build.info next to the resolved AddOns
                        path's game root. Intended for tests - never reads
                        the real WoW folder when given.
   -WowRoot <path>     FLAVORS-SPEC.md CS-F2: overrides multi-flavour
                        detection's WoW root (Get-InstalledFlavours), the same
                        way addon-sync.ps1's own -WowRoot does - used to point
                        this server at the FLAVORS-SPEC.md section 8 synthetic
                        fixture for local dev/test runs. Default: walk up from
                        -Root the same way Resolve-EffectiveAddonsPath already
                        does (parent leaf must be one of the six known
                        flavour folder names) - never touches the real WoW
                        folder unless -Root's own real deployment path leads
                        there, unchanged from today.
   -WowFakeProcessName <name>  P1 perf pass: substitutes the real "is any
                        known WoW client running" process-name probe
                        (Test-GameRunning) with a single caller-supplied
                        process name - the same test-only substitution
                        host\FurphyHost.cs's WowDetector.IsRunning already
                        accepts via --wow-fake. Never used by a real launch;
                        intended for tests only.
   -MaintenanceOnly     Round 37 (server perf pass): runs ONLY the
                        network-capable startup work this script's normal
                        invocation used to do inline before it could accept
                        its first request - Initialize-CfCatalogueIndex's
                        up-to-two live HTTPS GETs and Initialize-
                        WagoGrowthSnapshots' up-to-10-page-per-flavour Wago
                        crawl, each already self-gated on its own 24h/20h
                        freshness check (GAME-MODE-SPEC.md, 2026-09-08: no
                        longer also gated on Test-GameRunning) - then exits.
                        Never binds a listener, never enters the request
                        loop. Spawned periodically as a hidden, BelowNormal-
                        priority child of the real serving process (see
                        Invoke-MaintenanceTick, near the request loop) -
                        never launched directly by a real user action.
   -AppUpdateOnly       APP-UPDATE-SPEC.md section 5/7/11: structural
                        sibling of -MaintenanceOnly just above - runs ONLY
                        Invoke-AppUpdateMaintenance (unconditionally,
                        bypassing that function's own 24h/rate-limit
                        gates - see its own doc comment), then exits.
                        Never binds a listener, never enters the request
                        loop. Spawned on demand by POST
                        /api/app-update/check ("Check now") as a hidden
                        child of the real serving process, so a manual
                        check feels instant instead of waiting for the
                        next hourly -MaintenanceOnly tick (which also
                        runs Invoke-AppUpdateMaintenance, gated, inside
                        its own try/finally). Never launched directly by
                        a real user action.
=====================================================================
#>

param(
    [int]$Port = 0,
    [string]$Root,
    [string]$AddonsPath,
    [int]$IdleMinutes = 20,
    [switch]$OpenBrowser,
    [string]$BuildInfoPath,
    [string]$WowRoot,
    [string]$WowFakeProcessName,
    [switch]$MaintenanceOnly,
    [switch]$AppUpdateOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# WAGO-BROWSE-SPEC.md section 3.7 (prerequisite for Round 32/E29): test-only
# base-URL override surface for the Wago proxy, mirroring addon-sync.ps1's
# own $script:WagoBaseUrl/$env:FURPHY_TEST_WAGO_BASEURL seam exactly (see
# that file's own comment for the full rationale - an integration test
# points this at a local stub server the same way it already does for the
# CLI). Declared here, ABOVE the dot-source guard further down, so
# tests\unit\Server.WagoBaseUrl.Tests.ps1 can dot-source this file and read
# $Script:WagoBaseUrl back without ever reaching the real "start the
# listener" startup body - every real Wago call site below builds its URL
# from this variable instead of a literal host. An empty/whitespace-only
# override is treated the same as unset (falls back to the real host).
# TEST-ONLY: no real user run ever sets FURPHY_TEST_WAGO_BASEURL.
$Script:WagoBaseUrl = 'https://addons.wago.io'
if (-not [string]::IsNullOrWhiteSpace($env:FURPHY_TEST_WAGO_BASEURL)) {
    $Script:WagoBaseUrl = $env:FURPHY_TEST_WAGO_BASEURL.TrimEnd('/')
}

# APP-UPDATE-SPEC.md section 8.1: test-only base-URL override surface for
# the self-updater's GitHub Releases lookup, mirroring $Script:WagoBaseUrl/
# FURPHY_TEST_WAGO_BASEURL exactly (same seam shape, same "declared above
# the dot-source guard so a unit test can read it back without reaching the
# real startup body" reasoning, same "empty/whitespace override falls back
# to the real host" contract). Invoke-AppUpdateMaintenance builds its
# release-lookup URI by appending the fixed
# '/repos/krenz444/furphy-addon-manager/releases/latest' path onto this
# base instead of a literal host - a stub test server only needs to serve
# that one relative path. TEST-ONLY: no real user run ever sets
# FURPHY_TEST_GITHUB_BASEURL - the pinned repo path itself never changes,
# only which host it is requested from (section 9's "pinned repo" note).
$Script:GitHubBaseUrl = 'https://api.github.com'
if (-not [string]::IsNullOrWhiteSpace($env:FURPHY_TEST_GITHUB_BASEURL)) {
    $Script:GitHubBaseUrl = $env:FURPHY_TEST_GITHUB_BASEURL.TrimEnd('/')
}

# Round-1-fixer (verifier finding 1): test-only escape hatch for
# Initialize-WagoGrowthSnapshots' unconditional startup crawl, mirroring
# FURPHY_TEST_WAGO_BASEURL exactly (same seam shape, same "TEST-ONLY, no
# real user run ever sets this" contract). Before this, EVERY fresh
# scratch server started by ANY test - not just Wago-specific ones - paid
# a real, uncapped-in-aggregate crawl against the live addons.wago.io
# site on startup (a genuine live-safety/politeness regression), and that
# crawl could run long enough to block the request loop from accepting
# connections past FurphyHost.cs RunCycle's own ping-wait deadline
# (reproduced 100% at tests\host\Host.Tests.ps1:450). tests\lib\common.ps1's
# Start-TestServer sets this by default for any caller that has not
# itself opted into real Wago-crawl behavior by setting
# FURPHY_TEST_WAGO_BASEURL; host\FurphyHost.cs's TryStartServer sets it on
# the addon-server.ps1 child whenever the host itself was launched in a
# test-only mode (-WowFakeProcessName/-tray-selftest - both already
# documented as never used by a real launch). Checked once here (not
# inside the function) so it reads the same way $Script:WagoBaseUrl does.
$Script:SkipWagoGrowthCrawl = -not [string]::IsNullOrWhiteSpace($env:FURPHY_TEST_SKIP_WAGO_GROWTH)

# first-run-docs:fresh-install-startup-blocks-first-check (Round 36 fixer):
# same seam shape as $Script:SkipWagoGrowthCrawl immediately above, for
# Initialize-CfCatalogueIndex's own unconditional startup fetch. On a
# genuinely fresh install (no cache\cf-catalogue.json yet) that function
# makes up to two sequential live HTTPS GETs (raw.githubusercontent.com),
# each with its own 30s timeout plus a 1s pace-out between them - up to
# ~61s worst case - strictly before the request loop starts accepting
# connections, with no test-mode override until this. TEST-ONLY: no real
# user run ever sets FURPHY_TEST_SKIP_CF_CATALOGUE.
$Script:SkipCfCatalogueFetch = -not [string]::IsNullOrWhiteSpace($env:FURPHY_TEST_SKIP_CF_CATALOGUE)

# Round-fixer (F2 follow-up from the launch round): test-only base-URL
# override for Save-CfCatalogueIndex's two raw.githubusercontent.com
# fetches, mirroring $Script:WagoBaseUrl/FURPHY_TEST_WAGO_BASEURL exactly
# (same seam shape, same "declared above the dot-source guard so a unit
# test can read it back without reaching the real startup body" reasoning,
# same "empty/whitespace override falls back to the real host" contract).
# Before this, the CF catalogue fetch was the one remaining live-network
# call site in this file with no test seam at all - shots\launch\
# Measure-Launch.ps1's own header comment documented working around that
# gap by shadowing the Invoke-WebRequest cmdlet in a wrapper script instead
# of a real override, which this closes. Save-CfCatalogueIndex builds both
# of its URIs by appending a fixed path onto this base instead of a literal
# host, so a stub server only needs to serve those same two relative paths.
# TEST-ONLY: no real user run ever sets FURPHY_TEST_CF_CATALOGUE_BASEURL.
$Script:CfCatalogueBaseUrl = 'https://raw.githubusercontent.com'
if (-not [string]::IsNullOrWhiteSpace($env:FURPHY_TEST_CF_CATALOGUE_BASEURL)) {
    $Script:CfCatalogueBaseUrl = $env:FURPHY_TEST_CF_CATALOGUE_BASEURL.TrimEnd('/')
}

# =====================================================================
# Logging
# =====================================================================

# P1 perf pass (item 4): a server left running for days/weeks (the whole
# point of the background tray) would otherwise grow server.log without
# bound - every request logs at least one line. Capped at ~2MB, rotated to
# a single "<path>.1" (overwritten, never accumulated) so long uptimes never
# turn into unbounded disk writes. Best-effort: a rotation failure (locked
# file, read-only volume) never blocks the log write itself.
$Script:LogRotationMaxBytes = 2097152

function Invoke-LogRotationIfNeeded {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.Length -lt $Script:LogRotationMaxBytes) { return }
        $rotatedPath = "$Path.1"
        try { Remove-Item -LiteralPath $rotatedPath -Force -ErrorAction SilentlyContinue } catch { }
        Move-Item -LiteralPath $Path -Destination $rotatedPath -Force -ErrorAction Stop
    } catch {
        # Rotation must never block logging.
    }
}

function Write-ServerLog {
    param([string]$Message)

    $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $Message
    try {
        Invoke-LogRotationIfNeeded -Path $Script:ServerLogPath
        Add-Content -LiteralPath $Script:ServerLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Logging must never abort a request.
    }
}

# =====================================================================
# Game state (P1 perf pass) - "is any known WoW client running"
# =====================================================================
#
# GAME-MODE-SPEC.md (2026-09-08, Eric's rule verbatim: "addon browsing,
# updates and stuff need to happen while wow is running"): this detection
# signal no longer gates any network or functional work. It exists ONLY to
# (a) drive the SPA/tray's decorative-gating attributes and the
# reload/relog awareness signal (job.reloadNeeded, lastRun.reloadNeeded,
# the tray balloon's fresh check), and (b) gate the surviving CPU-only
# measures kept as defense-in-depth for a resident process: the 15s
# request-loop WaitOne widening, BelowNormal priority/EcoQoS, and the
# decorative theme-animation CSS gating. It does not refuse or delay any
# addon check/update/install, Wago/CurseForge browsing, catalogue refresh,
# enrichment fetch, or self-update check/download/install step.
#
# KnownWowProcessNames MUST be kept byte-identical to host\FurphyHost.cs's
# WowDetector.KnownWowNames (documented as one shared list in SPEC.md's
# addon-server.ps1 section) - two independent lists that quietly drift apart
# is exactly the kind of gap that would let one half of the app treat the
# game as "not running" while the other half correctly does.
$Script:KnownWowProcessNames = @(
    'Wow',
    'Wow-64',
    'WowClassic',
    'WowClassicT',
    'WowClassicB',
    'WowT',
    'WowB'
)

# Evaluated at most once per $Script:GameProbeIntervalSeconds - a
# Get-Process call is cheap but not free, and this server's whole point here
# is to add as close to zero overhead as possible, so a real request burst
# (a dozen /api/state polls in a few seconds from an open SPA tab) pays for
# exactly one live process scan, not one per request.
#
# Round 41b (idle-loop pass): [System.Diagnostics.Process]::GetProcesses()
# walks and disposes every process object on the whole machine (typically
# 150-300+ on a real desktop), not just the ~7 WoW-flavour names it
# compares against - real, measurable per-call CPU, unlike the two
# Get-Date comparisons that make up every OTHER request-loop tick. F1's
# single-scan rewrite already cut this from 7 calls/probe to 1; this
# stays at 30s. Round 41b tried 60s: an independent before/after on a
# quiet machine could not tell the two apart (both ~0.05 CPU-s/min, at
# the 15.625ms scheduler-tick noise floor), so the only measurable
# effect would have been noticing a WoW launch up to 30s later. Not
# worth it. The one contract test (Server.GameState.Tests.ps1) reads
# this var back symbolically rather than hardcoding a number.
$Script:GameProbeIntervalSeconds = 30
$Script:GameRunningCache = $false
$Script:GameRunningCacheAt = [DateTime]::MinValue

function Test-GameRunning {
    <#
      Returns $true if any known WoW client process is running, cached for
      $Script:GameProbeIntervalSeconds so a burst of requests/internal calls
      pays for one process-table scan, not one per call. -WowFakeProcessName
      (module-level $Script:WowFakeProcessNameOverride, set once at startup
      from the -WowFakeProcessName param) substitutes a single caller-chosen
      process name for the whole known-names list, the same test-only
      substitution host\FurphyHost.cs's WowDetector.IsRunning accepts via
      --wow-fake - never used by a real launch.

      F1 (idle-loop perf pass): used to call Get-Process -Name once PER
      known name - seven separate full process-table enumerations every
      30s (one per $Script:KnownWowProcessNames entry), even though at
      most one of them ever matches. [System.Diagnostics.Process]::
      GetProcesses() walks the process table exactly ONCE per probe
      instead; this just compares each returned .ProcessName
      case-insensitively against the (usually 7-entry, or single-entry
      under -WowFakeProcessName) name list already held in memory - same
      7x-or-1x comparisons as before, just against an in-memory array
      instead of re-querying the OS seven times. Every Process object
      GetProcesses() hands back is disposed before this returns (whether
      or not it matched) so this long-lived background-service loop never
      accumulates OS handles across probes.
    #>
    $now = Get-Date
    if (($now - $Script:GameRunningCacheAt).TotalSeconds -lt $Script:GameProbeIntervalSeconds) {
        return $Script:GameRunningCache
    }

    $names = $Script:KnownWowProcessNames
    if ($Script:WowFakeProcessNameOverride) {
        $names = @($Script:WowFakeProcessNameOverride)
    }

    $running = $false
    $procs = [System.Diagnostics.Process]::GetProcesses()
    try {
        foreach ($p in $procs) {
            try {
                $pname = $p.ProcessName
                foreach ($n in $names) {
                    if ([string]::Equals($pname, $n, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $running = $true
                        break
                    }
                }
            } catch {
                # A process can exit between GetProcesses() enumerating it
                # and this reading its .ProcessName; ignore and move on.
            }
            if ($running) { break }
        }
    } finally {
        # Dispose every handle GetProcesses() opened, not just the ones we
        # actually inspected before breaking out early on a match.
        foreach ($p in $procs) {
            try { $p.Dispose() } catch { }
        }
    }

    $Script:GameRunningCache = $running
    $Script:GameRunningCacheAt = $now
    return $running
}

# =====================================================================
# Process priority (P1 perf pass, item 3) - defense in depth
# =====================================================================
#
# Lowers this process's OS scheduling priority and (Windows 10 1709+) opts
# into EcoQoS via SetProcessInformation, so the scheduler/power manager
# treat it as background work rather than something that could compete with
# a foreground game for cycles. GAME-MODE-SPEC.md section 1.2: this is a
# CPU-only, resident-process measure kept for exactly that reason - it
# never stops or delays any addon/browse/update/self-update work, unlike
# the network gates this same P1 pass used to add elsewhere in this file
# (all removed - see GAME-MODE-SPEC.md). Best-effort throughout: a failure
# here (older Windows, a locked-down environment) must never block startup
# or a CLI run.
function Set-FurphyLowPriority {
    try {
        [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
    } catch {
        # Best-effort only.
    }
    try {
        if (-not ('Furphy.PowerThrottling' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Furphy {
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_POWER_THROTTLING_STATE {
        public uint Version;
        public uint ControlMask;
        public uint StateMask;
    }
    public static class PowerThrottling {
        public const int ProcessPowerThrottling = 4;
        public const uint PROCESS_POWER_THROTTLING_CURRENT_VERSION = 1;
        public const uint PROCESS_POWER_THROTTLING_EXECUTION_SPEED = 0x1;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetProcessInformation(IntPtr hProcess, int ProcessInformationClass, ref PROCESS_POWER_THROTTLING_STATE ProcessInformation, uint ProcessInformationSize);

        public static bool EnableEcoQoS() {
            PROCESS_POWER_THROTTLING_STATE state = new PROCESS_POWER_THROTTLING_STATE();
            state.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
            state.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
            state.StateMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
            uint size = (uint)Marshal.SizeOf(typeof(PROCESS_POWER_THROTTLING_STATE));
            return SetProcessInformation(System.Diagnostics.Process.GetCurrentProcess().Handle, ProcessPowerThrottling, ref state, size);
        }
    }
}
'@ -Language CSharp -ErrorAction Stop
        }
        [Furphy.PowerThrottling]::EnableEcoQoS() | Out-Null
    } catch {
        # Best-effort only - older Windows or a blocked API surface must
        # never block startup.
    }
}

# =====================================================================
# HTTP response helpers
# =====================================================================

function Get-MimeType {
    param([string]$Extension)

    $ext = $Extension.ToLowerInvariant()
    switch ($ext) {
        '.html' { return 'text/html; charset=utf-8' }
        '.htm' { return 'text/html; charset=utf-8' }
        '.css' { return 'text/css; charset=utf-8' }
        '.js' { return 'application/javascript; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.svg' { return 'image/svg+xml' }
        '.png' { return 'image/png' }
        '.ico' { return 'image/x-icon' }
        '.woff2' { return 'font/woff2' }
        default { return 'application/octet-stream' }
    }
}

function Send-Json {
    <#
      Writes one JSON response and always closes the response stream.
      -FileName (E4: GET /api/export) additionally sets Content-Disposition
      so the browser offers the response as a download instead of navigating
      to it; omitted (the default) for every other JSON response.
    #>
    param(
        $Context,
        [int]$StatusCode,
        $Body,
        [string]$FileName
    )

    $response = $Context.Response
    try {
        $json = ConvertTo-Json -InputObject $Body -Depth 12 -Compress
        if ($null -eq $json) {
            $json = 'null'
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $response.StatusCode = $StatusCode
        $response.ContentType = 'application/json; charset=utf-8'
        $response.Headers.Set('Cache-Control', 'no-store')
        if ($FileName) {
            $response.Headers.Set('Content-Disposition', "attachment; filename=$FileName")
        }
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Script:LastResponseStatus = $StatusCode
    } catch {
        $Script:LastResponseStatus = $StatusCode
        throw
    } finally {
        try { $response.OutputStream.Close() } catch { }
        try { $response.Close() } catch { }
    }
}

function Send-File {
    <# Serves one static file with the right MIME type; 404s if missing. #>
    param(
        $Context,
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'not found' }
        return
    }

    $response = $Context.Response
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $ext = [System.IO.Path]::GetExtension($Path)
        $mime = Get-MimeType -Extension $ext
        $response.StatusCode = 200
        $response.ContentType = $mime
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Script:LastResponseStatus = 200
    } finally {
        try { $response.OutputStream.Close() } catch { }
        try { $response.Close() } catch { }
    }
}

function Read-Body {
    <# Reads and parses a UTF-8 JSON request body. Returns $null if empty. #>
    param($Context)

    $request = $Context.Request
    if (-not $request.HasEntityBody) {
        return $null
    }

    # Round 20 (adversarial bug pass, security-2): a browser only sends a
    # CORS preflight ahead of a cross-site request whose Content-Type is
    # something other than the three CORS-"simple" values (text/plain,
    # multipart/form-data, application/x-www-form-urlencoded). Requiring
    # exactly application/json here means any cross-site POST/PUT carrying
    # a JSON body now REQUIRES a preflight - which this server never
    # answers with any Access-Control-Allow-* headers, so the browser
    # itself blocks the follow-up request. The SPA (ui/app.js) always sends
    # "application/json; charset=utf-8" for every call with a body, so this
    # is a no-op for every legitimate caller.
    $contentType = $request.ContentType
    if ([string]::IsNullOrEmpty($contentType) -or -not $contentType.ToLowerInvariant().StartsWith('application/json')) {
        throw 'bad request: Content-Type must be application/json'
    }

    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
    try {
        $text = $reader.ReadToEnd()
    } finally {
        $reader.Close()
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "Invalid JSON body: $($_.Exception.Message)"
    }
}

function Get-StaticFilePath {
    <#
      Maps a request path under ui\, blocking traversal outside it.
      Returns $null when the path is unsafe (caller should 404).
    #>
    param([string]$UrlPath)

    $rel = $UrlPath.TrimStart('/')
    if ([string]::IsNullOrEmpty($rel)) {
        $rel = 'index.html'
    }

    if ($rel -match '\.\.' -or $rel -match '^[A-Za-z]:' -or $rel.StartsWith('/') -or $rel.StartsWith('\')) {
        return $null
    }

    $rel = $rel -replace '/', '\'
    $full = Join-Path -Path $Script:UiDir -ChildPath $rel

    $fullResolved = [System.IO.Path]::GetFullPath($full)
    $uiResolved = [System.IO.Path]::GetFullPath($Script:UiDir)
    if (-not $fullResolved.StartsWith($uiResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    return $fullResolved
}

# =====================================================================
# FLAVORS-SPEC.md CS-F2: multi-flavour detection + resolution tables.
# Duplicated verbatim from addon-sync.ps1 (existing established
# duplication pattern - this script never dot-sources the CLI, same as
# Resolve-EffectiveAddonsPath/Get-PresentAddonFolders/Get-MissingDeps/the
# compat-audit functions already are). Any future edit to one of these
# names in addon-sync.ps1 (a new flavour, a new progression row) must be
# mirrored here in the same change set - see that file's own doc comments
# for the full rationale; kept terse here.
# =====================================================================

$Script:FlavourDefs = @(
    [PSCustomObject]@{ Id = 'retail';      Folder = '_retail_';      Label = 'Retail';      Product = 'wow' }
    [PSCustomObject]@{ Id = 'classic';     Folder = '_classic_';     Label = 'Classic';     Product = 'wow_classic' }
    [PSCustomObject]@{ Id = 'classic_era'; Folder = '_classic_era_'; Label = 'Classic Era'; Product = 'wow_classic_era' }
    [PSCustomObject]@{ Id = 'ptr';         Folder = '_ptr_';         Label = 'PTR';          Product = 'wowt' }
    [PSCustomObject]@{ Id = 'xptr';        Folder = '_xptr_';        Label = 'PTR (2)';      Product = 'wowxptr' }
    [PSCustomObject]@{ Id = 'beta';        Folder = '_beta_';        Label = 'Beta';         Product = 'wow_beta' }
)
$Script:FlavourFolderSet = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($fd in $Script:FlavourDefs) { [void]$Script:FlavourFolderSet.Add($fd.Folder) }

$Script:TocEraSelectors = [ordered]@{
    'retail'      = [PSCustomObject]@{ XFlavorTag = 'Mainline'; Suffixes = @('_Mainline', '-Mainline') }
    'classic_era' = [PSCustomObject]@{ XFlavorTag = 'Vanilla';  Suffixes = @('_Vanilla', '_Classic', '-Classic') }
    'tbc'         = [PSCustomObject]@{ XFlavorTag = 'TBC';      Suffixes = @('_TBC', '-BCC') }
    'wrath'       = [PSCustomObject]@{ XFlavorTag = 'Wrath';    Suffixes = @('_Wrath', '-Wrath', '-WOTLKC') }
    'cata'        = [PSCustomObject]@{ XFlavorTag = 'Cata';     Suffixes = @('_Cata') }
    'mists'       = [PSCustomObject]@{ XFlavorTag = 'Mists';    Suffixes = @('_Mists') }
}

function Get-FlavourDef {
    <# Looks up one $Script:FlavourDefs entry by id. $null when unrecognized. #>
    param([Parameter(Mandatory = $true)][string]$Id)

    foreach ($def in $Script:FlavourDefs) {
        if ($def.Id -eq $Id) { return $def }
    }
    return $null
}

function ConvertTo-InterfaceNumber {
    <# "12.1.0.69587" -> 120100 (major*10000 + minor*100 + patch). $null when unparsable. #>
    param([string]$VersionText)

    if (-not $VersionText) { return $null }
    $parts = $VersionText -split '\.'
    if ($parts.Count -lt 3) { return $null }
    $maj = 0
    $min = 0
    $pat = 0
    if ([int]::TryParse($parts[0], [ref]$maj) -and [int]::TryParse($parts[1], [ref]$min) -and [int]::TryParse($parts[2], [ref]$pat)) {
        return ($maj * 10000) + ($min * 100) + $pat
    }
    return $null
}

function Get-BuildInfoRows {
    <# Parses every data row of a pipe-delimited, typed-header .build.info file into {Product; Version} objects. Never throws. #>
    param([string]$BuildInfoPath)

    $rows = New-Object 'System.Collections.Generic.List[object]'
    if (-not $BuildInfoPath -or -not (Test-Path -LiteralPath $BuildInfoPath -PathType Leaf)) {
        Write-Output -NoEnumerate $rows
        return
    }
    $lines = $null
    try {
        $lines = Get-Content -LiteralPath $BuildInfoPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Output -NoEnumerate $rows
        return
    }
    if (-not $lines -or $lines.Count -lt 2) {
        Write-Output -NoEnumerate $rows
        return
    }

    $headerCols = $lines[0] -split '\|'
    $versionIdx = -1
    $productIdx = -1
    for ($i = 0; $i -lt $headerCols.Count; $i++) {
        $colName = ($headerCols[$i] -split '!')[0].Trim()
        if ($colName -eq 'Version') { $versionIdx = $i }
        if ($colName -eq 'Product') { $productIdx = $i }
    }
    if ($versionIdx -lt 0 -or $productIdx -lt 0) {
        Write-Output -NoEnumerate $rows
        return
    }

    for ($r = 1; $r -lt $lines.Count; $r++) {
        $line = $lines[$r]
        if (-not $line -or $line.Trim().Length -eq 0) { continue }
        $cols = $line -split '\|'
        if ($cols.Count -le $productIdx -or $cols.Count -le $versionIdx) { continue }
        $rows.Add([PSCustomObject]@{ Product = $cols[$productIdx].Trim(); Version = $cols[$versionIdx].Trim() })
    }
    Write-Output -NoEnumerate $rows
}

function Resolve-ClassicProgressionTypeId {
    <# FLAVORS-SPEC S2.4's appendable Interface-range -> TypeId/Wago-value/version-prefix table. Falls back to Retail's row. #>
    param($Interface = $null)

    $ranges = @(
        [PSCustomObject]@{ Min = 11500;  Max = 11599;  EraKey = 'classic_era'; EraLabel = 'Classic Era (Vanilla)';   TypeId = 67408; WagoValue = 'classic'; VersionPrefix = '1.15.' }
        [PSCustomObject]@{ Min = 20500;  Max = 20599;  EraKey = 'tbc';         EraLabel = 'Burning Crusade Classic';  TypeId = 73246; WagoValue = 'bc';      VersionPrefix = '2.5.' }
        [PSCustomObject]@{ Min = 30400;  Max = 30699;  EraKey = 'wrath';       EraLabel = 'Wrath Classic';            TypeId = 73713; WagoValue = 'wotlk';   VersionPrefix = '3.4.' }
        [PSCustomObject]@{ Min = 38000;  Max = 38099;  EraKey = 'wrath';       EraLabel = 'Wrath Classic';            TypeId = 73713; WagoValue = 'wotlk';   VersionPrefix = '3.4.' }
        [PSCustomObject]@{ Min = 40400;  Max = 40499;  EraKey = 'cata';        EraLabel = 'Cataclysm Classic';        TypeId = 77522; WagoValue = 'cata';    VersionPrefix = '4.4.' }
        [PSCustomObject]@{ Min = 50500;  Max = 50599;  EraKey = 'mists';       EraLabel = 'Mists Classic';            TypeId = 79434; WagoValue = 'mop';     VersionPrefix = '5.5.' }
        [PSCustomObject]@{ Min = 120000; Max = 129999; EraKey = 'retail';      EraLabel = 'Retail';                   TypeId = 517;   WagoValue = 'retail';  VersionPrefix = '12.' }
    )

    $ival = $null
    if ($null -ne $Interface) {
        try { $ival = [int]$Interface } catch { $ival = $null }
    }

    if ($null -ne $ival -and $ival -ne 0) {
        foreach ($row in $ranges) {
            if (($ival -ge $row.Min) -and ($ival -le $row.Max)) {
                return [PSCustomObject]@{ EraKey = $row.EraKey; EraLabel = $row.EraLabel; TypeId = $row.TypeId; WagoValue = $row.WagoValue; VersionPrefix = $row.VersionPrefix }
            }
        }
        # Security-review fix (mirrors addon-sync.ps1's copy exactly): a
        # REAL, non-zero Interface matching no known range is a future
        # Classic expansion this table doesn't cover yet - NOT the same as
        # a missing/unreadable .build.info. Return the 'unknown' sentinel
        # rather than silently falling through to Retail's TypeId/WagoValue.
        return [PSCustomObject]@{ EraKey = 'unknown'; EraLabel = 'Unrecognized Classic client version'; TypeId = $null; WagoValue = $null; VersionPrefix = $null }
    }
    return [PSCustomObject]@{ EraKey = 'retail'; EraLabel = 'Retail'; TypeId = 517; WagoValue = 'retail'; VersionPrefix = '12.' }
}

function Get-CfFlavourMapping {
    <# Centralizes S4.4 (CurseForge TypeId + gameVersions prefix) and S4.6 (Wago game_version field) for one -Flavor. #>
    param([string]$Flavor = 'retail', $InstalledInterface = $null)

    switch ($Flavor) {
        'retail'      { return [PSCustomObject]@{ TypeId = 517; VersionPrefix = '12.'; WagoField = 'retail'; EraLabel = 'Retail'; EraKey = 'retail' } }
        'classic_era' { return [PSCustomObject]@{ TypeId = 67408; VersionPrefix = '1.15.'; WagoField = 'classic'; EraLabel = 'Classic Era (Vanilla)'; EraKey = 'classic_era' } }
        'classic' {
            $prog = Resolve-ClassicProgressionTypeId -Interface $InstalledInterface
            return [PSCustomObject]@{ TypeId = $prog.TypeId; VersionPrefix = $prog.VersionPrefix; WagoField = $prog.WagoValue; EraLabel = $prog.EraLabel; EraKey = $prog.EraKey }
        }
        default { return [PSCustomObject]@{ TypeId = 517; VersionPrefix = '12.'; WagoField = 'retail'; EraLabel = 'Retail'; EraKey = 'retail' } }
    }
}

function Resolve-CfInstallFlavour {
    <#
      FLAVORS-SPEC.md CS-F3 S5.5: determines which of -InstalledFlavours a
      CurseForge target actually supports, via its gameVersionTypeIds:
        - -FileId given (the embedded-site/Get-New-Addons "Install" button
          and any fileId-carrying deep link already know the exact file) -
          fetches that ONE file's own gameVersionTypeIds.
        - -FileId omitted (a bare add - Select-CfFile will pick the actual
          file per flavour later, inside the CLI) - fetches the project's
          recent files and unions their gameVersionTypeIds, since the
          question here is only "does this project support installed
          flavour X AT ALL", not "which exact file".
      Keyless (no API key - same as every other CurseForge call in this
      file); headers/user-agent mirror Test-DiagCfReachability's own
      duplicated copy of addon-sync.ps1's Invoke-CfRequest (this script
      never dot-sources the CLI).

      Returns {MatchingFlavourIds = string[]; FetchError = <text-or-null>}.
      FetchError set (network/parse failure) means MatchingFlavourIds is
      meaningless and the caller must not treat an empty array as "case 4,
      zero matches" - that failure mode is reported to the caller as a
      distinct job-start error instead.
    #>
    param(
        [Parameter(Mandatory = $true)][int64]$ProjectId,
        $FileId,
        [Parameter(Mandatory = $true)]$InstalledFlavours
    )

    $headers = @{ 'Accept' = 'application/json'; 'Referer' = 'https://www.curseforge.com/' }
    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'

    $typeIdSet = New-Object 'System.Collections.Generic.HashSet[int64]'
    try {
        if ($FileId) {
            $uri = "https://www.curseforge.com/api/v1/mods/$ProjectId/files/$FileId"
            $resp = Invoke-WebRequest -Uri $uri -Headers $headers -UserAgent $userAgent -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            $json = $resp.Content | ConvertFrom-Json
            if ($json -and $json.data -and $json.data.gameVersionTypeIds) {
                foreach ($t in $json.data.gameVersionTypeIds) { [void]$typeIdSet.Add([int64]$t) }
            }
        } else {
            $uri = "https://www.curseforge.com/api/v1/mods/$ProjectId/files?pageIndex=0&pageSize=20&sort=dateCreated&sortDescending=true&removeAlphas=true"
            $resp = Invoke-WebRequest -Uri $uri -Headers $headers -UserAgent $userAgent -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            $json = $resp.Content | ConvertFrom-Json
            if ($json -and $json.data) {
                foreach ($f in $json.data) {
                    if ($f.gameVersionTypeIds) {
                        foreach ($t in $f.gameVersionTypeIds) { [void]$typeIdSet.Add([int64]$t) }
                    }
                }
            }
        }
    } catch {
        return [PSCustomObject]@{ MatchingFlavourIds = @(); FetchError = "Could not check this addon's supported WoW versions: $($_.Exception.Message)" }
    }

    $matching = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in $InstalledFlavours) {
        $mapping = Get-CfFlavourMapping -Flavor $f.id -InstalledInterface $f.clientInterface
        if ($typeIdSet.Contains([int64]$mapping.TypeId)) {
            [void]$matching.Add($f.id)
        }
    }
    return [PSCustomObject]@{ MatchingFlavourIds = $matching.ToArray(); FetchError = $null }
}

function Get-TocXFlavorTag {
    <# Reads a .toc's "## X-Flavor: <Tag>" line, trimmed, or $null. Never throws. #>
    param([Parameter(Mandatory = $true)][string]$TocPath)

    $lines = $null
    try {
        $lines = Get-Content -LiteralPath $TocPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        return $null
    }
    foreach ($line in $lines) {
        if ($line -match '^\s*##\s*X-Flavor\s*:\s*(.+?)\s*$') {
            return $Matches[1].Trim()
        }
    }
    return $null
}

function Resolve-TocEraKey {
    <# Maps -Flavor (+, for 'classic', -InstalledInterface) to one of $Script:TocEraSelectors' keys. #>
    param([string]$Flavor = 'retail', $InstalledInterface = $null)

    switch ($Flavor) {
        'retail'      { return 'retail' }
        'classic_era' { return 'classic_era' }
        'classic' {
            $ival = 0
            if ($null -ne $InstalledInterface) {
                try { $ival = [int]$InstalledInterface } catch { $ival = 0 }
            }
            return (Resolve-ClassicProgressionTypeId -Interface $ival).EraKey
        }
        default { return 'retail' }
    }
}

function Get-InstalledFlavours {
    <#
      FLAVORS-SPEC S2.3: returns the WoW client flavours actually present
      under $WowRoot, in S2.1's fixed order. "Installed" means
      <WowRoot>\<folder>\Interface\AddOns exists. .build.info is
      corroboration only. Never throws. -WowRoot, when given, is used
      as-is (S8's fixture path included); omitted, it is resolved by
      walking up from -ScriptRoot (default $PSScriptRoot) the same way
      Resolve-EffectiveAddonsPath's own walk-up does, generalized from
      "parent leaf must be _retail_" to "parent leaf must be one of S2.1's
      known flavour folder names."
    #>
    param(
        [string]$WowRoot,
        [string]$ScriptRoot = $PSScriptRoot
    )

    $result = New-Object 'System.Collections.Generic.List[object]'

    $resolvedWowRoot = $WowRoot
    if (-not $resolvedWowRoot -or $resolvedWowRoot.Trim().Length -eq 0) {
        if ($ScriptRoot) {
            $leaf = Split-Path -Path $ScriptRoot -Leaf
            $parentDir = Split-Path -Path $ScriptRoot -Parent
            if (($leaf -eq 'AddonSync') -and $parentDir) {
                $parentLeaf = Split-Path -Path $parentDir -Leaf
                if ($Script:FlavourFolderSet.Contains($parentLeaf)) {
                    $resolvedWowRoot = Split-Path -Path $parentDir -Parent
                }
            }
        }
    }

    if (-not $resolvedWowRoot -or -not (Test-Path -LiteralPath $resolvedWowRoot -PathType Container)) {
        Write-Output -NoEnumerate $result
        return
    }

    $buildInfoPath = Join-Path -Path $resolvedWowRoot -ChildPath '.build.info'
    $buildInfoRows = Get-BuildInfoRows -BuildInfoPath $buildInfoPath

    foreach ($def in $Script:FlavourDefs) {
        $folderPath = Join-Path -Path $resolvedWowRoot -ChildPath $def.Folder
        $addonsPath = Join-Path -Path $folderPath -ChildPath 'Interface\AddOns'
        if (-not (Test-Path -LiteralPath $addonsPath -PathType Container)) {
            continue
        }
        $row = $null
        foreach ($r in $buildInfoRows) {
            if ($r.Product -eq $def.Product) { $row = $r; break }
        }
        $clientBuild = $null
        $clientInterface = $null
        if ($row) {
            $clientBuild = $row.Version
            $clientInterface = ConvertTo-InterfaceNumber -VersionText $row.Version
        }
        $result.Add([PSCustomObject]@{
                id               = $def.Id
                folder           = $def.Folder
                label            = $def.Label
                addonsPath       = $addonsPath
                clientBuild      = $clientBuild
                clientInterface  = $clientInterface
                buildInfoRow     = $row
                buildInfoMissing = ($null -eq $row)
            })
    }

    $claimedProducts = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($def in $Script:FlavourDefs) { [void]$claimedProducts.Add($def.Product) }
    try {
        $subDirs = Get-ChildItem -LiteralPath $resolvedWowRoot -Directory -ErrorAction SilentlyContinue
        foreach ($dir in $subDirs) {
            if ($Script:FlavourFolderSet.Contains($dir.Name)) { continue }
            $candidateAddons = Join-Path -Path $dir.FullName -ChildPath 'Interface\AddOns'
            if (-not (Test-Path -LiteralPath $candidateAddons -PathType Container)) { continue }
            $matchRow = $null
            foreach ($r in $buildInfoRows) {
                if (-not $claimedProducts.Contains($r.Product)) { $matchRow = $r; break }
            }
            if ($matchRow) {
                $result.Add([PSCustomObject]@{
                        id               = $matchRow.Product
                        folder           = $dir.Name
                        label            = $matchRow.Product
                        addonsPath       = $candidateAddons
                        clientBuild      = $matchRow.Version
                        clientInterface  = (ConvertTo-InterfaceNumber -VersionText $matchRow.Version)
                        buildInfoRow     = $matchRow
                        buildInfoMissing = $false
                    })
                [void]$claimedProducts.Add($matchRow.Product)
            }
        }
    } catch {
    }

    Write-Output -NoEnumerate $result
}

function Get-MigrationHomeFlavour {
    <# Which flavours\<id>\ subfolder this AddonSync install's own pre-flavour top-level files belong under. Falls back to 'retail'. #>
    param([string]$RootPath)

    try {
        $parentDir = Split-Path -Path $RootPath -Parent
        if ($parentDir) {
            $parentLeaf = Split-Path -Path $parentDir -Leaf
            foreach ($def in $Script:FlavourDefs) {
                if ($def.Folder -eq $parentLeaf) { return $def.Id }
            }
        }
    } catch {
    }
    return 'retail'
}

function Invoke-FlavourMigration {
    <#
      FLAVORS-SPEC S3.3: one-time, idempotent, zero-data-loss migration of a
      pre-flavour install's top-level addons.json/state.json/backups\ into
      flavours\<homeFlavour>\ - duplicated from addon-sync.ps1's identical
      function (logging swapped for Write-ServerLog since this script never
      dot-sources the CLI). Called once at server startup, before any path
      resolution - CS-F1's own notesForNext flagged this file list gap
      explicitly ("a server-only first run would never migrate"); this
      change set closes it by duplicating the call here too, so a server
      that runs before the CLI ever has still migrates the shared folder.
      Never throws - every step is best-effort and logged.
    #>
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $settingsPath = Join-Path -Path $RootPath -ChildPath 'settings.json'
    $schemaVersion = 1
    $settingsObj = $null
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $settingsObj = $raw | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $settingsObj.schemaVersion) {
                    $schemaVersion = [int]$settingsObj.schemaVersion
                }
            }
        } catch {
            Write-ServerLog "Flavour migration: failed to read settings.json, treating as pre-flavour: $($_.Exception.Message)"
        }
    }

    if ($schemaVersion -ge 2) {
        return
    }

    $homeFlavour = Get-MigrationHomeFlavour -RootPath $RootPath
    $flavoursDir = Join-Path -Path $RootPath -ChildPath 'flavours'
    $homeFlavourDir = Join-Path -Path $flavoursDir -ChildPath $homeFlavour
    if (-not (Test-Path -LiteralPath $homeFlavourDir)) {
        New-Item -ItemType Directory -Path $homeFlavourDir -Force | Out-Null
    }

    $addonsJsonPath = Join-Path -Path $RootPath -ChildPath 'addons.json'
    $stateJsonPath = Join-Path -Path $RootPath -ChildPath 'state.json'
    $backupsDirPath = Join-Path -Path $RootPath -ChildPath 'backups'
    $hasAddonsJson = Test-Path -LiteralPath $addonsJsonPath -PathType Leaf
    $hasStateJson = Test-Path -LiteralPath $stateJsonPath -PathType Leaf
    $hasBackupsDir = Test-Path -LiteralPath $backupsDirPath -PathType Container

    $existingBackups = $null
    if (Test-Path -LiteralPath $flavoursDir -PathType Container) {
        $existingBackups = Get-ChildItem -LiteralPath $flavoursDir -Directory -Filter '_migration-backup-*' -ErrorAction SilentlyContinue
    }
    if (($hasAddonsJson -or $hasStateJson -or $hasBackupsDir) -and (-not $existingBackups -or (@($existingBackups)).Count -eq 0)) {
        try {
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $backupDir = Join-Path -Path $flavoursDir -ChildPath ("_migration-backup-{0}" -f $stamp)
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

            if ($hasAddonsJson) {
                Copy-Item -LiteralPath $addonsJsonPath -Destination (Join-Path -Path $backupDir -ChildPath 'addons.json') -Force
            }
            if ($hasStateJson) {
                Copy-Item -LiteralPath $stateJsonPath -Destination (Join-Path -Path $backupDir -ChildPath 'state.json') -Force
            }
            if ($hasBackupsDir) {
                Copy-Item -LiteralPath $backupsDirPath -Destination (Join-Path -Path $backupDir -ChildPath 'backups') -Recurse -Force
            }
            Write-ServerLog "Flavour migration: pre-move backup copied to $backupDir"
        } catch {
            Write-ServerLog "Flavour migration: failed to create pre-move backup: $($_.Exception.Message)"
        }
    }

    $moveOk = $true
    foreach ($name in @('addons.json', 'state.json', 'backups')) {
        $sourcePath = Join-Path -Path $RootPath -ChildPath $name
        $destPath = Join-Path -Path $homeFlavourDir -ChildPath $name
        if (Test-Path -LiteralPath $destPath) {
            continue
        }
        if (Test-Path -LiteralPath $sourcePath) {
            try {
                Move-Item -LiteralPath $sourcePath -Destination $destPath -Force
                Write-ServerLog "Flavour migration: moved $name into $homeFlavourDir"
            } catch {
                $moveOk = $false
                Write-ServerLog "Flavour migration: failed to move $name into $homeFlavourDir : $($_.Exception.Message)"
            }
        }
    }

    if (-not $moveOk) {
        return
    }

    $newSettings = $settingsObj
    if (-not $newSettings) {
        $newSettings = [PSCustomObject]@{}
    }
    if ($newSettings.PSObject.Properties.Match('schemaVersion').Count -gt 0) {
        $newSettings.schemaVersion = 2
    } else {
        $newSettings | Add-Member -MemberType NoteProperty -Name 'schemaVersion' -Value 2
    }
    try {
        $json = ConvertTo-Json -InputObject $newSettings -Depth 10
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $tmpPath = "$settingsPath.tmp"
        [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
        Move-Item -LiteralPath $tmpPath -Destination $settingsPath -Force
        Write-ServerLog 'Flavour migration: schemaVersion set to 2'
    } catch {
        Write-ServerLog "Flavour migration: failed to write schemaVersion to settings.json: $($_.Exception.Message)"
    }
}

# =====================================================================
# FLAVORS-SPEC.md CS-F2: per-request flavour resolution.
#
# This server is a single-threaded HttpListener request loop (see the
# file's own header comment) - exactly one request's handler ever runs at
# a time. That makes it safe for Invoke-Route to resolve one flavour per
# incoming request and stash it in $Script:CurrentFlavour /
# $Script:AddonsJsonPath / $Script:BackupsPath / $Script:ClientBuildInfo
# for the DURATION of that one handler call - every addon-scoped function
# below (Get-AddonRecords, Resolve-EffectiveAddonsPath's own default,
# Handle-Open's 'addons'/'backups' cases, etc.) keeps reading those same
# script-scope variables completely unchanged; only the VALUE they hold
# now varies per request instead of being fixed once at startup. A
# long-running background job (Start-Job's actual CLI child process) is
# unaffected by a LATER request changing this context, because its own
# process argument list (New-CliProcessArgs) is built synchronously,
# once, at the moment the job starts - see that function's own comment.
# =====================================================================

function Get-CurrentInstalledFlavours {
    <#
      Live per-request flavour detection (S8's acceptance bar: "detection is
      live, not cached"). Cheap (a handful of Test-Path calls) - recomputed
      on every request rather than cached at startup, so a flavour that
      appears or disappears mid-session (installing/uninstalling a client)
      is picked up on the very next request.
    #>
    return (Get-InstalledFlavours -WowRoot $Script:WowRootOverride -ScriptRoot $Script:Root)
}

function Get-DefaultFlavourId {
    <#
      FLAVORS-SPEC.md S4.1's default rule, server-side equivalent: 'retail'
      when installed, else the first flavour Get-CurrentInstalledFlavours
      returns, else 'retail' (byte-identical fallback when nothing at all
      can be detected - e.g. a dev checkout with no real WoW folder nearby,
      matching today's single-flavour-only behavior exactly).
    #>
    param($InstalledFlavours)

    foreach ($f in $InstalledFlavours) {
        if ($f.id -eq 'retail') { return 'retail' }
    }
    foreach ($f in $InstalledFlavours) {
        return $f.id
    }
    return 'retail'
}

function Get-QueryFlavour {
    <# Reads ?flavour= (preferred) or ?flavor= (alias, S5.1) from the request, trimmed/lowercased. $null when neither is present. #>
    param($Context)

    $q = $Context.Request.QueryString
    $val = $q['flavour']
    if (-not $val) { $val = $q['flavor'] }
    if (-not $val) { return $null }
    $val = $val.Trim().ToLowerInvariant()
    if ($val.Length -eq 0) { return $null }
    return $val
}

# FLAVORS-SPEC.md S5.1: the small, fixed set of addon-scoped endpoints that
# 400 ("flavour required") when ?flavour= is omitted AND more than one
# flavour is installed. Enumerated once here so the router and this list
# stay the single source of truth, rather than an unenforced per-handler
# convention - a missed call site would otherwise silently serve the wrong
# flavour's data instead of failing loudly in dev. Keyed the same way
# $Script:Routes is (Method + Pattern), so Invoke-Route can match against
# it directly without a second, separately-maintained handler-name list.
#
# POST /api/jobs is deliberately NOT listed here even though it is
# addon-scoped for every OTHER job kind - S5.4's {kind:"update-all-flavours"}
# is a legitimate exception (it targets every installed flavour AT ONCE, by
# definition, so requiring ?flavour= for it would be incoherent) and the
# router cannot see the POST body's own `kind` field before dispatch to
# decide which rule applies. Handle-JobsPost enforces the identical
# "flavour required" 400 itself, for every kind EXCEPT update-all-flavours,
# right after parsing `kind` from the body - see its own comment.
#
# GET /api/state is ALSO deliberately NOT listed here (verification-pass
# fix), even though its addon-list payload is exactly as flavour-scoped as
# every endpoint below it. It is the client's own bootstrap/discovery call:
# a fresh SPA load starts with zero knowledge of which/how-many flavours
# are installed (Store.installedFlavours is []), so it has no correct
# ?flavour= value to send on its very first request - hard-400'ing that
# first call created a permanent chicken-and-egg deadlock on any real (non
# -mock) machine with more than one installed flavour: the client could
# never learn it had multiple flavours because the one call that would
# tell it always failed for omitting a param it did not yet know it needed.
# Falling through to Resolve-RequestFlavour's own settings.activeFlavour-or-
# default fallback (below) resolves this exactly the way principle 5
# already intends for non-flavour-scoped endpoints: a pure UI-continuity
# guess, never load-bearing, and self-correcting immediately - the
# response's own installedFlavours/activeFlavour/flavour fields tell the
# client exactly what flavour it just got, the client adopts that into
# Store.state (see ui/app.js's reloadState), and every SUBSEQUENT call
# (including the next /api/state poll) correctly carries an explicit
# ?flavour= once Store.hasMultipleFlavours() can answer correctly.
$Script:FlavourScopedEndpoints = @(
    @{ Method = 'POST'; Pattern = '^/api/addons/(?<id>[^/]+)/ignore$' }
    @{ Method = 'POST'; Pattern = '^/api/addons/(?<id>[^/]+)/unpin$' }
    @{ Method = 'GET'; Pattern = '^/api/addons/(?<id>[^/]+)/files$' }
    @{ Method = 'GET'; Pattern = '^/api/scan$' }
    @{ Method = 'POST'; Pattern = '^/api/scan/delete$' }
    @{ Method = 'GET'; Pattern = '^/api/export$' }
    @{ Method = 'POST'; Pattern = '^/api/import$' }
    @{ Method = 'GET'; Pattern = '^/api/wago/search$' }
    # Round 32 (WAGO-BROWSE-SPEC.md, Expansion E29): /api/wago/browse is the
    # new name Handle-WagoBrowse answers under too - both entries must stay
    # in sync with $Script:Routes below (the startup self-check catches a
    # mismatch here).
    @{ Method = 'GET'; Pattern = '^/api/wago/browse$' }
)

function Test-FlavourScopedEndpoint {
    param([string]$Method, [string]$Path)

    foreach ($e in $Script:FlavourScopedEndpoints) {
        if ($e.Method -eq $Method -and $Path -match $e.Pattern) { return $true }
    }
    return $false
}

function Resolve-RequestFlavour {
    <#
      S5.1's explicit-query-param addressing, resolved once per request.
      Returns {Ok; Flavor; StatusCode; Error}. Ok=$false means the caller
      must 400 with Error and never dispatch to the matched handler at all.

      - A ?flavour=/?flavor= value not among the CURRENTLY installed
        flavours is always a clean 400 (whether or not the endpoint is in
        $Script:FlavourScopedEndpoints) - never silently coerced to
        something else.
      - Omitted, with <=1 installed flavour: resolves to that one flavour
        (or the S4.1 default when none at all could be detected) - a
        single-flavour machine NEVER needs to send the param, so today's
        UI/scripts/scheduled tasks work completely unchanged (principle 2).
      - Omitted, with >1 installed: a flavour-scoped endpoint 400s
        ("flavour required"); any other endpoint (this now explicitly
        includes GET /api/state - see $Script:FlavourScopedEndpoints' own
        comment for why the client's bootstrap call cannot be in that list)
        falls back to settings.json's activeFlavour (or the S4.1 default)
        as a pure UI-continuity convenience, never load-bearing for a data
        operation (principle 5) - Get-Settings is cheap (a single small
        JSON read).
    #>
    param($Context, [string]$Method, [string]$Path)

    $installed = Get-CurrentInstalledFlavours
    $requested = Get-QueryFlavour -Context $Context

    if ($requested) {
        # Security-review fix: validate the raw query value's SHAPE before
        # anything else (defense in depth) - this is a raw, attacker-
        # controlled string that Set-CurrentFlavourContext later feeds
        # straight into Join-Path to build $Script:AddonsJsonPath/
        # $Script:BackupsPath. Known flavour ids are always lowercase
        # letters/digits/underscore; reject anything else outright rather
        # than letting a path-traversal-shaped value (e.g. "..\..\Windows")
        # reach that Join-Path call at all.
        if ($requested -notmatch '^[a-z0-9_]+$') {
            return [PSCustomObject]@{ Ok = $false; Flavor = $null; StatusCode = 400; Error = "flavour '$requested' is not installed" }
        }

        $isInstalled = $false
        foreach ($f in $installed) {
            if ($f.id -eq $requested) { $isInstalled = $true; break }
        }
        # Security-review fix: this 400 used to be gated on
        # "(@($installed)).Count -gt 0", so a $requested value was let
        # through UNVALIDATED whenever Get-CurrentInstalledFlavours
        # returned zero flavours (a real, reachable state - a bad/dev
        # -WowRoot override, or detection failing to find a real WoW
        # folder) - Set-CurrentFlavourContext would then Join-Path that raw
        # value straight into the addons.json/backups path with zero
        # sanitization. A requested flavour that isn't in the CURRENTLY
        # installed list must always 400, regardless of how many flavours
        # were detected.
        if (-not $isInstalled) {
            return [PSCustomObject]@{ Ok = $false; Flavor = $null; StatusCode = 400; Error = "flavour '$requested' is not installed" }
        }
        return [PSCustomObject]@{ Ok = $true; Flavor = $requested; StatusCode = 200; Error = $null }
    }

    if ((@($installed)).Count -le 1) {
        return [PSCustomObject]@{ Ok = $true; Flavor = (Get-DefaultFlavourId -InstalledFlavours $installed); StatusCode = 200; Error = $null }
    }

    if (Test-FlavourScopedEndpoint -Method $Method -Path $Path) {
        return [PSCustomObject]@{ Ok = $false; Flavor = $null; StatusCode = 400; Error = 'flavour required' }
    }

    $active = $null
    try { $active = (Get-Settings).activeFlavour } catch { $active = $null }
    if ($active) {
        foreach ($f in $installed) {
            if ($f.id -eq $active) { return [PSCustomObject]@{ Ok = $true; Flavor = $active; StatusCode = 200; Error = $null } }
        }
    }
    return [PSCustomObject]@{ Ok = $true; Flavor = (Get-DefaultFlavourId -InstalledFlavours $installed); StatusCode = 200; Error = $null }
}

function Set-CurrentFlavourContext {
    <#
      Stashes the resolved flavour for the request currently in flight (see
      this section's own header comment for why a script-scope variable is
      safe here). $Script:AddonsJsonPath/$Script:BackupsPath move under
      FLAVORS-SPEC.md S3.1's flavours\<id>\ subfolder - only that one
      subfolder is ever created (by New-CliProcessArgs's underlying CLI
      call, or by this function's own on-demand creation just below), never
      every known flavour's. $Script:ClientBuildInfo is re-resolved against
      THIS flavour's own .build.info row so /api/state's clientBuild/
      clientInterface (and Get-AddonCompat's client-side comparison) are
      always that flavour's own values, not always retail's.
    #>
    param([string]$Flavor)

    if (-not $Flavor) { $Flavor = 'retail' }
    $Script:CurrentFlavour = $Flavor

    $flavourDir = Join-Path -Path (Join-Path -Path $Script:Root -ChildPath 'flavours') -ChildPath $Flavor
    $Script:AddonsJsonPath = Join-Path -Path $flavourDir -ChildPath 'addons.json'
    $Script:BackupsPath = Join-Path -Path $flavourDir -ChildPath 'backups'

    $buildInfoPath = $Script:BuildInfoPathOverride
    if (-not $buildInfoPath) {
        $buildInfoPath = Get-DefaultBuildInfoPath -AddonsPathResolved (Resolve-EffectiveAddonsPath -Flavor $Flavor)
    }
    $Script:ClientBuildInfo = Get-ClientBuildInfo -BuildInfoPath $buildInfoPath -Flavor $Flavor
}

function Get-FlavourUpdateAvailable {
    <# The mutable per-flavour {key: {fileId, version}} hashtable for -Flavor, creating an empty one on first touch. #>
    param([string]$Flavor)

    if (-not $Script:UpdateAvailableByFlavour.ContainsKey($Flavor)) {
        $Script:UpdateAvailableByFlavour[$Flavor] = @{}
    }
    return $Script:UpdateAvailableByFlavour[$Flavor]
}

function Get-FlavourLastRun {
    param([string]$Flavor)
    if ($Script:LastRunByFlavour.ContainsKey($Flavor)) { return $Script:LastRunByFlavour[$Flavor] }
    return $null
}

function Get-FlavourUpdatesCheckedAt {
    param([string]$Flavor)
    if ($Script:UpdatesCheckedAtByFlavour.ContainsKey($Flavor)) { return $Script:UpdatesCheckedAtByFlavour[$Flavor] }
    return $null
}

function Get-FlavourLastCheckFailed {
    param([string]$Flavor)
    if ($Script:LastCheckFailedByFlavour.ContainsKey($Flavor)) { return [bool]$Script:LastCheckFailedByFlavour[$Flavor] }
    return $false
}

function Get-FlavourLastCheckError {
    param([string]$Flavor)
    if ($Script:LastCheckErrorByFlavour.ContainsKey($Flavor)) { return $Script:LastCheckErrorByFlavour[$Flavor] }
    return $null
}

function Get-CurrentJobForFlavour {
    <# The single "current" (in-flight) job for -Flavor, or $null - FLAVORS-SPEC.md CS-F2 S5.4's per-flavour Test-JobBusy scoping. #>
    param([string]$Flavor)
    if ($Script:CurrentJobByFlavour.ContainsKey($Flavor)) { return $Script:CurrentJobByFlavour[$Flavor] }
    return $null
}

function Set-CurrentJobForFlavour {
    param([string]$Flavor, $Job)
    if ($null -eq $Job) {
        if ($Script:CurrentJobByFlavour.ContainsKey($Flavor)) { $Script:CurrentJobByFlavour.Remove($Flavor) }
    } else {
        $Script:CurrentJobByFlavour[$Flavor] = $Job
    }
}

function Clear-CurrentJobIfMatches {
    <# Clears the current-job slot for $Job's OWN flavour, but only if it still holds exactly this job (never clobbers a different, later job that may already have started for that same flavour). #>
    param($Job)
    if (-not $Job) { return }
    $existing = Get-CurrentJobForFlavour -Flavor $Job.flavour
    if ($existing -and $existing.id -eq $Job.id) {
        Set-CurrentJobForFlavour -Flavor $Job.flavour -Job $null
    }
}

# =====================================================================
# settings.json
# =====================================================================

function Get-DefaultSettings {
    return [PSCustomObject]@{
        releaseType        = 1
        port               = 47831
        # E19: adFilter is the native host's (host\FurphyHost.exe) CurseForge-
        # tab ad/tracker filter toggle. Originally OFF by default per Eric's
        # explicit decision (SPEC E19); that decision was SUPERSEDED
        # 2026-09-04 by a later explicit Eric request (SPEC E22's "get rid of
        # cookie banner, and the other banner that appears on top, and
        # anything else other than the content, turn on ad block by default")
        # - the default is now ON. Existing installs are unaffected: this
        # only changes what a FRESH settings.json (or one missing the key)
        # gets - Get-Settings only ever falls back to this default when
        # $obj.adFilter is $null, so anyone who already has adFilter written
        # to disk (true or false) keeps that value untouched. hostWindow is
        # the host's last saved window bounds ({x,y,w,h}), written by
        # FurphyHost.cs itself via a direct read-modify-write of
        # settings.json (HostFiles.UpdateJsonObject) - this server only
        # needs to round-trip it through GET/PUT so a Settings PUT from the
        # web UI (releaseType, etc.) never clobbers it.
        adFilter           = $true
        # Round 16 (E22): cfFocus is the native host's CurseForge listing/
        # search "focus view" trim (hide site chrome + the left filter
        # sidebar, keep only the results column) - ON by default per Eric's
        # explicit ask (SPEC E22). Same round-trip pattern as adFilter:
        # read/validated/written the same way, and (as of 2026-09-04) both
        # default ON now.
        cfFocus            = $true
        hostWindow         = $null
        # Round 12 (E19b): the native host's LAST SAVED chrome/title-bar
        # palette - {name, colors:{bg0,bg1,...}} - same round-trip pattern as
        # hostWindow just above (the host writes it directly via
        # HostFiles.UpdateJsonObject, bypassing PUT /api/settings entirely;
        # this server only needs to not lose it on an unrelated settings
        # save). Unlike hostWindow, a PUT through this endpoint DOES validate
        # it - see Test-HostTheme - since unlike hostWindow's host-owned
        # opaque blob, this shape can also be reached by a client sending
        # arbitrary JSON to the API directly.
        hostTheme          = $null
        # Round 18 (tray stage B): the native host's background-updater
        # settings. These three keys are also read directly by
        # host\FurphyHost.cs's own TraySettingsReader (stage A, already
        # shipped) - this server round-trips them through the API/SPA the
        # same way adFilter/cfFocus are round-tripped, with the identical
        # default/clamp values TraySettingsReader already uses so both
        # readers of settings.json always agree. backgroundUpdates OFF by
        # default (Eric never asked for this to run unattended out of the
        # box); backgroundIntervalMinutes defaults to 120 (2 hours), clamped
        # 30..1440 on every write; runAtStartup OFF by default and
        # deliberately independent of backgroundUpdates - see
        # Handle-SettingsPut's comment and SPEC.md's tray section for the
        # "Start with Windows also turns background updates on" rule, which
        # lives in the SPA (ui\app.js), not here.
        backgroundUpdates          = $false
        backgroundIntervalMinutes  = 120
        runAtStartup               = $false
        # APP-UPDATE-SPEC.md section 6: whether a staged, verified app
        # update installs itself automatically the next time doing so is
        # safe (never while a job is running, and - for this automatic
        # path only - never while any Furphy window is open). Default ON
        # - opposite polarity from backgroundUpdates just above (that one
        # defaults OFF), intentional per Eric's brief.
        # Checking for updates always happens either way; this toggle only
        # gates automatic INSTALLING (section 3.5).
        appUpdateAutoInstall       = $true
        # FLAVORS-SPEC.md CS-F2 S3.4: schemaVersion 2 is what
        # Invoke-FlavourMigration stamps once every existing top-level
        # addons.json/state.json/backups\ has landed under flavours\<id>\ -
        # a BRAND NEW install (no pre-existing settings.json at all) never
        # needs migrating, so it starts at 2 directly, never 1. activeFlavour
        # is a UI-continuity default only (S3.4 - "never consulted
        # server-side to decide what a data-mutating request means"), read
        # by Resolve-RequestFlavour's own non-flavour-scoped-endpoint
        # fallback and nowhere else; 'retail' here is just the shape's own
        # default value, not a claim that retail is installed - the actual
        # default flavour for an omitted ?flavour= is always computed live
        # (Get-DefaultFlavourId), never read from this field. showTestRealms
        # (S2.5) is the "Show test realms (PTR/Beta)" toggle, off by default.
        schemaVersion              = 2
        activeFlavour              = 'retail'
        showTestRealms             = $false
    }
}

function Save-Settings {
    param($Settings)

    $json = ConvertTo-Json -InputObject $Settings -Depth 5
    $tmpPath = "$Script:SettingsPath.tmp"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
    Move-Item -LiteralPath $tmpPath -Destination $Script:SettingsPath -Force
}

function Get-Settings {
    <# Reads settings.json, tolerating missing fields; creates it with defaults if absent. #>
    if (-not (Test-Path -LiteralPath $Script:SettingsPath)) {
        $defaults = Get-DefaultSettings
        try { Save-Settings -Settings $defaults } catch { Write-ServerLog "Failed to create settings.json: $($_.Exception.Message)" }
        return $defaults
    }

    try {
        # Get-Content is safe here: $raw is only ever fed into ConvertFrom-Json
        # below, never returned or JSON-serialized itself, so the PSPath/PSDrive/
        # PSProvider note properties Get-Content attaches to the string never reach
        # a response (ConvertFrom-Json's output is a fresh, undecorated object -
        # see Update-JobStatus for the pattern that actually is hazardous).
        $raw = Get-Content -LiteralPath $Script:SettingsPath -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $defaults = Get-DefaultSettings
            Save-Settings -Settings $defaults
            return $defaults
        }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $result = Get-DefaultSettings
        if ($null -ne $obj.releaseType) { $result.releaseType = [int]$obj.releaseType }
        if ($null -ne $obj.port) {
            # security:security-server-settings-port-no-range-check-bricks-
            # launch, defense in depth: settings.json can end up with an
            # out-of-range port from more than just Handle-SettingsPut (a
            # manual hand-edit, an older/corrupted file) - clamp it out on
            # every READ too, same reasoning as the backgroundIntervalMinutes
            # clamp just below, so a bad on-disk value can never round-trip
            # anywhere (including back into the startup port-resolution
            # fallback further down this file) unfiltered.
            $portRead = [int]$obj.port
            if ($portRead -ge 1 -and $portRead -le 65535) { $result.port = $portRead }
        }
        # E19: adFilter/hostWindow - see Get-DefaultSettings. hostWindow is
        # copied through as whatever object shape is on disk (the host owns
        # its contents); this server never inspects x/y/w/h itself.
        if ($null -ne $obj.adFilter) { $result.adFilter = [bool]$obj.adFilter }
        # Round 16 (E22): cfFocus - see Get-DefaultSettings.
        if ($null -ne $obj.cfFocus) { $result.cfFocus = [bool]$obj.cfFocus }
        if ($null -ne $obj.hostWindow) { $result.hostWindow = $obj.hostWindow }
        # Round 12 (E19b): hostTheme is copied through unvalidated on READ,
        # same as hostWindow just above - whatever shape is already on disk
        # (written either by the host directly, or by a prior validated PUT
        # through this server) round-trips as-is. Validation only happens on
        # the WRITE path (Handle-SettingsPut/Test-HostTheme) where it can
        # actually stop a bad value from being saved in the first place.
        if ($null -ne $obj.hostTheme) { $result.hostTheme = $obj.hostTheme }
        # Round 18 (tray stage B): backgroundUpdates/runAtStartup are plain
        # bool coercions, same pattern as adFilter/cfFocus above.
        # backgroundIntervalMinutes is clamped 30..1440 on READ too (not just
        # on the PUT path below) so a value hand-edited into settings.json,
        # or left over from a future build with a wider range, can never
        # reach the tray/SPA unclamped - matches
        # host\FurphyHost.cs's TraySettingsReader, which applies the same
        # clamp on every read for the same reason.
        if ($null -ne $obj.backgroundUpdates) { $result.backgroundUpdates = [bool]$obj.backgroundUpdates }
        if ($null -ne $obj.backgroundIntervalMinutes) {
            $interval = [int]$obj.backgroundIntervalMinutes
            if ($interval -lt 30) { $interval = 30 }
            if ($interval -gt 1440) { $interval = 1440 }
            $result.backgroundIntervalMinutes = $interval
        }
        if ($null -ne $obj.runAtStartup) { $result.runAtStartup = [bool]$obj.runAtStartup }
        # APP-UPDATE-SPEC.md section 6: plain bool coercion, same pattern
        # as backgroundUpdates/runAtStartup just above. No migration step -
        # a pre-1.22.0 settings.json simply lacks the key and this falls
        # through to Get-DefaultSettings' $true default via the same
        # "$null -ne" tolerance every other boolean setting here already
        # uses.
        if ($null -ne $obj.appUpdateAutoInstall) { $result.appUpdateAutoInstall = [bool]$obj.appUpdateAutoInstall }
        # FLAVORS-SPEC.md CS-F2 S3.4: schemaVersion is normally stamped
        # directly by Invoke-FlavourMigration (a raw settings.json read/write,
        # bypassing this function entirely - same reason hostWindow/hostTheme
        # are host-written directly) rather than through Save-Settings, but
        # is still read through here like every other field so GET
        # /api/settings never has to special-case it. activeFlavour/
        # showTestRealms are plain pass-throughs, same pattern as adFilter/
        # cfFocus above.
        if ($null -ne $obj.schemaVersion) { $result.schemaVersion = [int]$obj.schemaVersion }
        if ($null -ne $obj.activeFlavour) { $result.activeFlavour = [string]$obj.activeFlavour }
        if ($null -ne $obj.showTestRealms) { $result.showTestRealms = [bool]$obj.showTestRealms }
        # Round 16 (E22, 2026-09-04, at Eric's explicit request): the
        # CurseForge API key feature is removed entirely. An existing
        # settings.json from before this round may still carry a stored
        # cfApiKey value - $result (built from Get-DefaultSettings, which no
        # longer has that property) never copies it over, so it is already
        # dropped from every in-memory settings object; this just also
        # rewrites the file on disk so it stops sitting there once and for
        # all. The key's value itself is never logged.
        $legacyKeyProp = Get-Member -InputObject $obj -Name 'cfApiKey' -MemberType NoteProperty -ErrorAction SilentlyContinue
        if ($null -ne $legacyKeyProp) {
            try {
                Save-Settings -Settings $result
                Write-ServerLog 'Removed legacy cfApiKey from settings.json (CurseForge key feature removed 2026-09-04).'
            } catch {
                Write-ServerLog "Failed to rewrite settings.json while dropping legacy cfApiKey: $($_.Exception.Message)"
            }
        }
        # Round 34 (2026-09-06, at Eric's explicit request): the "launch WoW"
        # feature (and its "update addons before WoW starts" setting) is
        # removed entirely - the background service already covers updates.
        # Same drop-on-read pattern as the cfApiKey migration just above:
        # $result (built from Get-DefaultSettings, which no longer has this
        # property) never copies a stale autoUpdateOnLaunch value over, so
        # it's already gone from the in-memory object; this just also
        # rewrites the file on disk so it stops sitting there for good.
        $legacyAutoUpdateProp = Get-Member -InputObject $obj -Name 'autoUpdateOnLaunch' -MemberType NoteProperty -ErrorAction SilentlyContinue
        if ($null -ne $legacyAutoUpdateProp) {
            try {
                Save-Settings -Settings $result
                Write-ServerLog 'Removed legacy autoUpdateOnLaunch from settings.json (launch-WoW feature removed 2026-09-06).'
            } catch {
                Write-ServerLog "Failed to rewrite settings.json while dropping legacy autoUpdateOnLaunch: $($_.Exception.Message)"
            }
        }
        return $result
    } catch {
        Write-ServerLog "Failed to read settings.json, using defaults: $($_.Exception.Message)"
        # failure-modes:settingsjson-corruption-silent-reset - a corrupt
        # file used to just fall back to defaults in memory on every single
        # request, forever, with the file itself never repaired: any real
        # choice the user had made that differs from a default (most
        # importantly adFilter/cfFocus, both ON by default) silently
        # reverted with zero indication, and re-triggered this same log
        # line on every subsequent GET. Overwrite the corrupt file with
        # valid defaults on first detection - mirrors the missing/empty-
        # file branches above it, which already do exactly this - so the
        # file self-repairs immediately instead of lingering broken for the
        # life of the install. Best-effort: a failed repair still returns
        # the in-memory defaults either way, matching this function's
        # existing "never let a settings problem break the app" contract.
        $defaults = Get-DefaultSettings
        try {
            Save-Settings -Settings $defaults
        } catch {
            Write-ServerLog "Failed to repair corrupt settings.json: $($_.Exception.Message)"
        }
        return $defaults
    }
}

function Get-SettingsView {
    <# settings.json, as returned by the settings API - no cfApiKey field
       exists any more (Round 16, E22: the CurseForge key feature was
       removed 2026-09-04 at Eric's explicit request). Round 17 removed
       checkAddonVersion the same way (Eric: "WoW's out-of-date warning...
       get rid of this it doesn't do anything") - see Get-DefaultSettings's
       own note and CHANGELOG.md's Round 17 section. #>
    param($Settings)

    return [PSCustomObject]@{
        releaseType        = $Settings.releaseType
        port               = $Script:Port
        addonsPath         = (Resolve-EffectiveAddonsPath)
        wowRoot            = (Get-WowRootPath)
        # E19: pass through unmasked (neither is a secret) - see
        # Get-DefaultSettings.
        adFilter          = $Settings.adFilter
        # Round 16 (E22): pass through unmasked, same as adFilter - not a
        # secret.
        cfFocus           = $Settings.cfFocus
        hostWindow        = $Settings.hostWindow
        # Round 12 (E19b): pass through unmasked, same as hostWindow - not a
        # secret, and the UI never displays it (only the native host reads
        # it, at startup, to paint the right chrome before the page loads).
        hostTheme         = $Settings.hostTheme
        # Round 18 (tray stage B): pass through unmasked, same as adFilter/
        # cfFocus - none of these three are secrets.
        backgroundUpdates         = $Settings.backgroundUpdates
        backgroundIntervalMinutes = $Settings.backgroundIntervalMinutes
        runAtStartup              = $Settings.runAtStartup
        # APP-UPDATE-SPEC.md section 6: pass through unmasked, same as
        # backgroundUpdates/runAtStartup just above - not a secret.
        appUpdateAutoInstall      = $Settings.appUpdateAutoInstall
        # FLAVORS-SPEC.md CS-F2 S3.4/S5.2: pass through unmasked, same as
        # adFilter/cfFocus - none of these are secrets. schemaVersion is
        # informational only (never drives a client decision - S5.2's
        # installedFlavours/addons already carry everything the UI needs);
        # activeFlavour/showTestRealms are the two client-writable ones (see
        # Handle-SettingsPut).
        schemaVersion     = $Settings.schemaVersion
        activeFlavour     = $Settings.activeFlavour
        showTestRealms    = $Settings.showTestRealms
    }
}

function Test-HostTheme {
    <#
      Validates a hostTheme object per SPEC.md's E19b section: { name,
      colors }. name must be a 1-32 char lowercase-alnum-hyphen string;
      colors must be an object with at most 12 keys, every value a
      "#rrggbb" hex string. Returns $true/$false - used only by
      Handle-SettingsPut's write path (Get-Settings's read path above passes
      hostTheme through unvalidated, same as hostWindow, since by the time
      something is sitting in settings.json it already went through this
      check once, either here or - for the native host's own direct writes -
      was produced by the host's own getComputedStyle read of real CSS
      custom properties, not arbitrary input).
    #>
    param($Theme)

    if ($null -eq $Theme) { return $false }

    if ($null -eq $Theme.name) { return $false }
    $name = [string]$Theme.name
    if ($name.Length -lt 1 -or $name.Length -gt 32) { return $false }
    # -cnotmatch (case-SENSITIVE), not the bare -notmatch every other regex
    # check in this file uses - PowerShell's -match/-notmatch are
    # case-INSENSITIVE by default (confirmed live during this round's own
    # verification: "LofiNight" passed a plain -notmatch '^[a-z0-9-]+$'
    # check and got saved to settings.json), which would silently accept
    # any-case names despite the lowercase-only contract documented above
    # and in SPEC.md's E19b section.
    if ($name -cnotmatch '^[a-z0-9-]+$') { return $false }

    if ($null -eq $Theme.colors) { return $false }
    # Counted by hand (not @($Theme.colors.PSObject.Properties).Count) per
    # this file's standing @()-around-an-enumerable caution (see SPEC.md's
    # hard-constraints line) - a plain foreach never hits that class of
    # quirk regardless of the collection's runtime type.
    $colorCount = 0
    foreach ($p in $Theme.colors.PSObject.Properties) {
        $colorCount = $colorCount + 1
        if ($colorCount -gt 12) { return $false }
        $val = [string]$p.Value
        if ($val -notmatch '^#[0-9a-fA-F]{6}$') { return $false }
    }

    return $true
}

# =====================================================================
# addons.json (read-only here; addon-sync.ps1 owns writes)
# =====================================================================

function Get-AddonRecords {
    <#
      Returns a List[object] of addon records. Missing/empty/null file -> empty list.

      E10 fix (self-caught during this expansion's own offline verification):
      all three exit points used to `return $list` directly. A bare `return`
      of a collection goes through the pipeline, which PowerShell enumerates -
      for an EMPTY list that produces zero pipeline objects (the caller gets
      $null instead of an empty list), and for a list with EXACTLY ONE record
      it unwraps to that single record itself (the caller gets a bare
      PSCustomObject, not a list) - the same hazard class SPEC.md's
      List[object]/@() quirk describes, generalized to plain `return` of any
      enumerable. Every call site already in this file happens to use
      `foreach ($r in (Get-AddonRecords))`, which tolerates both cases by
      accident (foreach over $null runs zero times; foreach over a bare
      scalar runs once, treating it as that one item) - so this had no
      observable effect until Test-DiagAddonsJson's `.Count` usage (E10)
      exposed it directly: a tracked-addon count of exactly 1 produced
      "record.Count" as $null (PSCustomObject has no such property), not 1.
      Write-Output -NoEnumerate keeps the real List[object] intact through
      all three returns, matching the fix already applied to
      Get-PresentAddonFolders/Get-MissingDeps (E3) for the identical pattern.
    #>
    $list = New-Object 'System.Collections.Generic.List[object]'

    if (-not (Test-Path -LiteralPath $Script:AddonsJsonPath)) {
        Write-Output -NoEnumerate $list
        return
    }

    # failure-modes:corrupt-addonsjson-total-lockout - Get-Content/
    # ConvertFrom-Json used to run unguarded here: a MALFORMED (not just
    # missing/empty) addons.json - a truncated write, disk-full during
    # save, a manual edit gone wrong - threw straight out of this function,
    # through Invoke-Route's blanket catch, as a generic HTTP 500 with the
    # raw .NET parser exception (including a fragment of the corrupted
    # file's own content) shown verbatim in the SPA's My Addons error box on
    # every single /api/state poll - total, permanent lockout with no
    # recovery path in the UI. Wrapped in try/catch mirroring Get-Settings'
    # own missing/empty/corrupt handling above: a parse failure logs and
    # falls back to the same empty list the missing/empty-file branches
    # above already return, so GET /api/state stays 200 with addons: []
    # instead of ever reaching Invoke-Route's generic 500. The unreadable
    # file is also moved aside (never deleted) to addons.json.corrupt-
    # <timestamp>, mirroring the flavours\_migration-backup-<timestamp>
    # pattern already used elsewhere in this file, so the user's data is
    # preserved on disk for recovery rather than silently discarded or
    # overwritten by the next real write.
    try {
        # Get-Content is safe here: $raw only feeds ConvertFrom-Json below and is
        # never returned/serialized itself, so its PSPath/PSDrive/PSProvider note
        # properties never reach a JSON response (see Update-JobStatus for the
        # pattern that actually hangs Send-Json).
        $raw = Get-Content -LiteralPath $Script:AddonsJsonPath -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Output -NoEnumerate $list
            return
        }

        $tmp = $raw | ConvertFrom-Json -ErrorAction Stop
        $parsed = @($tmp)
        foreach ($item in $parsed) {
            if ($null -ne $item) {
                $list.Add($item)
            }
        }
        Write-Output -NoEnumerate $list
    } catch {
        Write-ServerLog "Failed to read addons.json, showing empty list: $($_.Exception.Message)"
        try {
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $corruptPath = "$Script:AddonsJsonPath.corrupt-$stamp"
            Move-Item -LiteralPath $Script:AddonsJsonPath -Destination $corruptPath -Force -ErrorAction Stop
            Write-ServerLog "Moved unreadable addons.json aside to $corruptPath - your addon folders on disk are untouched; a fresh addons.json will be created on the next real write."
        } catch {
            Write-ServerLog "Failed to move aside corrupt addons.json (left in place): $($_.Exception.Message)"
        }
        $list = New-Object 'System.Collections.Generic.List[object]'
        Write-Output -NoEnumerate $list
        return
    }
}

# =====================================================================
# Path resolution (mirrors addon-sync.ps1 Resolve-AddonsPath, for display)
# =====================================================================

function Resolve-EffectiveAddonsPath {
    <#
      FLAVORS-SPEC.md S4.2/CS-F2: gains -Flavor (default $Script:CurrentFlavour,
      itself defaulting to 'retail' - see Set-CurrentFlavourContext), mirroring
      addon-sync.ps1's identical Resolve-AddonsPath parameterization. The
      -Root-parent walk-up is generalized from "leaf must equal _retail_" to
      "leaf must be one of the six known flavour folder names"
      ($Script:FlavourFolderSet) - this machine's own default call (-Flavor
      omitted -> 'retail') resolves byte-identically to before, since
      _retail_ is one of those six names. $Script:WowRootOverride (-WowRoot),
      when set, is used directly instead of walking up from -Root at all -
      the same fixture-testing override addon-sync.ps1's own -WowRoot gives.
      -AddonsPathOverride (this script's own -AddonsPath) still wins outright
      over everything, unchanged.
    #>
    param([string]$Flavor)

    if ($Script:AddonsPathOverride) {
        return $Script:AddonsPathOverride
    }

    if (-not $Flavor) { $Flavor = $Script:CurrentFlavour }
    if (-not $Flavor) { $Flavor = 'retail' }
    $def = Get-FlavourDef -Id $Flavor
    if (-not $def) { return $null }

    $resolvedWowRoot = $Script:WowRootOverride
    if (-not $resolvedWowRoot -or $resolvedWowRoot.Trim().Length -eq 0) {
        $leaf = Split-Path -Path $Script:Root -Leaf
        $parentDir = Split-Path -Path $Script:Root -Parent
        if (($leaf -eq 'AddonSync') -and $parentDir) {
            $parentLeaf = Split-Path -Path $parentDir -Leaf
            if ($Script:FlavourFolderSet.Contains($parentLeaf)) {
                $resolvedWowRoot = Split-Path -Path $parentDir -Parent
            }
        }
    }

    if (-not $resolvedWowRoot) {
        return $null
    }

    return Join-Path -Path (Join-Path -Path $resolvedWowRoot -ChildPath $def.Folder) -ChildPath 'Interface\AddOns'
}

function Get-WowRootPath {
    <#
      UNCHANGED return semantics from before this change set - despite the
      name, this returns the FLAVOUR's own folder (e.g. <WowRoot>\_retail_),
      one level above Interface\AddOns's parent - NOT the true grandparent
      <WowRoot> (see Get-FlavourWowRootPath below for that). Kept exactly as
      it was (byte-identical for -Flavor 'retail'/omitted, per this feature's
      non-negotiable "zero behavior change at n=1" bar) - Get-SettingsView's
      existing `wowRoot` field must not change shape for a single-flavour
      machine. Now flavour-aware via Resolve-EffectiveAddonsPath's own
      -Flavor param, for future multi-flavour callers.
    #>
    param([string]$Flavor)

    $addonsPath = Resolve-EffectiveAddonsPath -Flavor $Flavor
    if (-not $addonsPath) {
        return $null
    }
    try {
        $interfaceDir = Split-Path -Path $addonsPath -Parent
        $flavourDir = Split-Path -Path $interfaceDir -Parent
        return $flavourDir
    } catch {
        return $null
    }
}

function Get-FlavourWowRootPath {
    <# The true <WowRoot> (three levels above Interface\AddOns - the folder that would contain _retail_/_classic_/etc side by side). $null when unresolvable. #>
    param([string]$Flavor)

    $flavourDir = Get-WowRootPath -Flavor $Flavor
    if (-not $flavourDir) { return $null }
    try {
        return (Split-Path -Path $flavourDir -Parent)
    } catch {
        return $null
    }
}

# E13 (compatibility audit): mirrors addon-sync.ps1's identical function -
# see its own doc comment for why .build.info sits three levels above
# <root>\_retail_\Interface\AddOns.
function Get-DefaultBuildInfoPath {
    param([string]$AddonsPathResolved)

    if (-not $AddonsPathResolved) { return $null }
    try {
        $interfaceDir = Split-Path -Path $AddonsPathResolved -Parent
        if (-not $interfaceDir) { return $null }
        $retailDir = Split-Path -Path $interfaceDir -Parent
        if (-not $retailDir) { return $null }
        $wowRootDir = Split-Path -Path $retailDir -Parent
        if (-not $wowRootDir) { return $null }
        return Join-Path -Path $wowRootDir -ChildPath '.build.info'
    } catch {
        return $null
    }
}

# =====================================================================
# Dependencies (E3) - live missingDeps for /api/state, mirroring
# addon-sync.ps1's Get-AddonsFolderSet/Get-MissingDeps (this script is
# always launched standalone, never dot-sources the CLI, so the small
# amount of logic is duplicated the same way Resolve-EffectiveAddonsPath
# already mirrors Resolve-AddonsPath above).
# =====================================================================

function Get-PresentAddonFolders {
    <#
      Case-insensitive set of every top-level AddOns folder name currently on
      disk (lowercased). Empty set (never throws) when the AddOns path can't
      be resolved or doesn't exist yet. Uses -NoEnumerate: a HashSet is
      IEnumerable, so a bare "return $set" on an EMPTY set would enumerate to
      zero pipeline objects and the caller's assignment would silently
      receive $null instead of the set itself (the same class of hazard the
      List[object] quirk documents, generalized to any enumerable collection
      type) - reproduced directly: Get-MissingDeps's Mandatory PresentFolders
      parameter threw "Cannot bind argument ... because it is null" the
      moment this ran against an unresolvable AddOns path (empty set).
    #>
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    $addonsPath = Resolve-EffectiveAddonsPath
    if ($addonsPath -and (Test-Path -LiteralPath $addonsPath -PathType Container)) {
        $dirs = Get-ChildItem -LiteralPath $addonsPath -Force -Directory -ErrorAction SilentlyContinue
        foreach ($d in $dirs) { [void]$set.Add($d.Name.ToLowerInvariant()) }
    }
    Write-Output -NoEnumerate $set
}

function Get-AddonsFolderSnapshot {
    <#
      Round 37 (server perf pass): one directory listing of the resolved
      AddOns folder, reused for BOTH Handle-State's cache fingerprint
      (Get-HandleStateCacheKey, via .Fingerprint) and, on a cache miss,
      Get-MissingDeps's PresentFolders set (via Get-PresentAddonFoldersFromDirs
      on .Dirs) - so a Handle-State call that misses the cache still only
      lists the AddOns folder once, not the two separate listings a naive
      "compute the fingerprint, then separately call Get-PresentAddonFolders"
      approach would pay for.

      .Fingerprint changes whenever the AddOns folder's own LastWriteTime
      changes, or any immediate child folder is added, removed, renamed, or
      has ITS OWN LastWriteTime change (NTFS bumps a directory's own
      LastWriteTime on any of those - an addon install/remove/update always
      does at least one, a fresh unzip always removes+recreates or at least
      touches its own folder) - enough to invalidate a toc-derived cache
      without ever reading a single addon's own file contents. Returns ""
      (never $null) for .Fingerprint when -AddonsPath can't be resolved or
      doesn't exist - a real fingerprint (which always starts with a Ticks
      value) can never equal that, so an unresolvable AddOns path forces a
      fresh compute on every call, matching this file's behavior before this
      cache existed. .Dirs is always an array (possibly empty), matching
      Get-PresentAddonFolders' own "empty, never throws" contract for the
      same case.
    #>
    param([string]$AddonsPath)

    if (-not $AddonsPath -or -not (Test-Path -LiteralPath $AddonsPath -PathType Container)) {
        return @{ Fingerprint = ''; Dirs = @() }
    }
    $selfTicks = 0
    try {
        $selfTicks = (Get-Item -LiteralPath $AddonsPath -ErrorAction Stop).LastWriteTimeUtc.Ticks
    } catch {
        $selfTicks = 0
    }
    $dirs = @(Get-ChildItem -LiteralPath $AddonsPath -Force -Directory -ErrorAction SilentlyContinue | Sort-Object -Property Name)
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $parts.Add([string]$selfTicks)
    foreach ($d in $dirs) {
        $parts.Add($d.Name.ToLowerInvariant() + ':' + $d.LastWriteTimeUtc.Ticks)
    }
    return @{ Fingerprint = ($parts -join '|'); Dirs = $dirs }
}

function Get-PresentAddonFoldersFromDirs {
    <#
      Same case-insensitive name-set contract as Get-PresentAddonFolders
      above, built from an already-fetched directory listing
      (Get-AddonsFolderSnapshot's own .Dirs) instead of a fresh
      Get-ChildItem - see that function's own doc comment for why. -NoEnumerate
      for the identical empty-HashSet-enumerates-to-$null reason
      Get-PresentAddonFolders documents.
    #>
    param($Dirs)

    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($d in @($Dirs)) { [void]$set.Add($d.Name.ToLowerInvariant()) }
    Write-Output -NoEnumerate $set
}

function Get-MissingDeps {
    <# Entries of $DepNames not present (case-insensitively) in $PresentFolders. #>
    param($DepNames, $PresentFolders)

    $missing = New-Object 'System.Collections.Generic.List[object]'
    foreach ($dep in @($DepNames)) {
        if (-not $dep) { continue }
        if (-not $PresentFolders.Contains(([string]$dep).ToLowerInvariant())) {
            $missing.Add($dep)
        }
    }
    Write-Output -NoEnumerate $missing
}

# =====================================================================
# Compatibility audit (E13) - mirrors addon-sync.ps1's identical functions
# (Split-TocDepList / Get-TocInterfaceValues / Get-PackageTocInterfaces /
# Get-AddonCompat / Get-ClientBuildInfo) - this script never dot-sources the
# CLI, same duplication pattern already used for Resolve-EffectiveAddonsPath/
# Get-PresentAddonFolders/Get-MissingDeps above. See the CLI's own doc
# comments for the full rationale; kept terse here.
# =====================================================================

function Split-TocDepList {
    <# Splits one toc tag's comma- or space-separated value into pieces; blank pieces dropped; tolerates $null/empty. #>
    param([string]$Value)

    $result = New-Object 'System.Collections.Generic.List[object]'
    if (-not $Value) {
        Write-Output -NoEnumerate $result
        return
    }
    $pieces = $null
    if ($Value.IndexOf(',') -ge 0) { $pieces = $Value -split ',' } else { $pieces = $Value -split '\s+' }
    foreach ($piece in $pieces) {
        $trimmed = $piece.Trim()
        if ($trimmed.Length -gt 0) { $result.Add($trimmed) }
    }
    Write-Output -NoEnumerate $result
}

function Get-PrimaryTocFile {
    <#
      Duplicate of addon-sync.ps1's identically-named function (this script
      never dot-sources the CLI) - picks the .toc file one flavour/era
      actually loads for an installed folder, out of however many game-
      flavor variants a package ships in the same folder.

      FLAVORS-SPEC.md S4.5/CS-F2: gains -Flavor (default 'retail') and
      -InstalledInterface (consulted only when -Flavor is 'classic', to
      resolve which rolling-progression era's .toc to prefer, S2.4).
      Selection order, primary signal first:
        1. Any .toc in the folder carrying "## X-Flavor: <Tag>" whose value
           matches the target flavour/era's tag - authoritative wherever
           present, regardless of filename.
        2. The target flavour/era's filename-suffix table
           ($Script:TocEraSelectors), in try-order.
        3. Bare "<FolderName>.toc" - owned by whichever of the three groups
           (Retail / Classic Era / Classic's rolling progression) is the SOLE
           one with no suffixed file present in this folder; bare defaults to
           Retail whenever that is not exactly one group (S4.5's caveat).
        4. First .toc file found (today's last-resort, unchanged).
      Returns a FileInfo, or $null when the folder has no .toc file at all.
      Never throws. Byte-identical to the pre-flavour selection for every
      existing retail call site (-Flavor defaults to 'retail').
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [Parameter(Mandatory = $true)][string]$FolderName,
        [string]$Flavor = 'retail',
        $InstalledInterface = $null
    )

    $tocFiles = Get-ChildItem -LiteralPath $FolderPath -Filter '*.toc' -File -ErrorAction SilentlyContinue
    if (-not $tocFiles) {
        return $null
    }

    $eraKey = Resolve-TocEraKey -Flavor $Flavor -InstalledInterface $InstalledInterface
    $selector = $Script:TocEraSelectors[$eraKey]
    if (-not $selector) {
        # No real selector row for this era (e.g. an unrecognized future
        # Classic-progression Interface range) - do NOT fall back to the
        # Retail selector here, or an unrecognized Classic client would
        # silently prefer a Retail-tagged/suffixed file over the correct
        # Classic one in steps 1-2. Use a selector that can never match so
        # selection falls through to step 3's bare-file group logic (which
        # already folds 'unknown' into the 'classic' group correctly) and
        # then step 4's first-found fallback.
        $selector = [PSCustomObject]@{ XFlavorTag = $null; Suffixes = @() }
    }

    # 1. X-Flavor tag - authoritative wherever present.
    foreach ($t in $tocFiles) {
        $tag = Get-TocXFlavorTag -TocPath $t.FullName
        if ($tag -and ($tag -eq $selector.XFlavorTag)) {
            return $t
        }
    }

    # 2. Filename-suffix table for the target flavour/era. Built with -f
    # rather than "$FolderName_Mainline.toc" - PowerShell would parse the
    # latter as the variable ${FolderName_Mainline} (underscore is a valid
    # identifier character), not $FolderName followed by literal text.
    foreach ($suffix in $selector.Suffixes) {
        $preferredName = '{0}{1}.toc' -f $FolderName, $suffix
        foreach ($t in $tocFiles) {
            if ($t.Name -eq $preferredName) {
                return $t
            }
        }
    }

    # 3. Bare "<FolderName>.toc" - S4.5's caveat, implemented exactly: build
    # the suffix-to-flavour map for the THREE first-class groups (Retail;
    # Classic Era; Classic's rolling progression collapsed into one group),
    # scan which groups have a matching suffixed file present in THIS
    # folder, and only attribute the bare file to a non-retail group when it
    # is the SOLE unclaimed one of the three - else bare always means retail.
    $bareGroupClaimed = @{
        'retail'      = $false
        'classic_era' = $false
        'classic'     = $false
    }
    foreach ($otherKey in $Script:TocEraSelectors.Keys) {
        $group = 'classic'
        if ($otherKey -eq 'retail') { $group = 'retail' }
        elseif ($otherKey -eq 'classic_era') { $group = 'classic_era' }
        $otherSelector = $Script:TocEraSelectors[$otherKey]
        foreach ($suffix in $otherSelector.Suffixes) {
            $otherName = '{0}{1}.toc' -f $FolderName, $suffix
            foreach ($t in $tocFiles) {
                if ($t.Name -eq $otherName) { $bareGroupClaimed[$group] = $true }
            }
        }
    }
    $unclaimedGroups = @($bareGroupClaimed.Keys | Where-Object { -not $bareGroupClaimed[$_] })
    $bareOwnerGroup = 'retail'
    if ($unclaimedGroups.Count -eq 1) {
        $bareOwnerGroup = $unclaimedGroups[0]
    }
    $targetGroup = 'classic'
    if ($eraKey -eq 'retail') { $targetGroup = 'retail' }
    elseif ($eraKey -eq 'classic_era') { $targetGroup = 'classic_era' }
    if ($bareOwnerGroup -eq $targetGroup) {
        $bareName = '{0}.toc' -f $FolderName
        foreach ($t in $tocFiles) {
            if ($t.Name -eq $bareName) {
                return $t
            }
        }
    }

    # 4. First .toc found - today's last-resort, unchanged.
    foreach ($t in $tocFiles) { return $t }
    return $null
}

function Get-TocInterfaceValues {
    <#
      Reads "## Interface:"/"## Interface-Mainline:" from one folder's
      primary .toc (Get-PrimaryTocFile's Mainline-first selection) into
      int64s. Never throws; empty list when unavailable. -AddonsPath is not
      Mandatory (Handle-State can reach here with an unresolvable AddOns
      path, $null - a Mandatory [string] parameter rejects an explicit
      $null argument outright, distinct from simply omitting it, rather
      than degrading gracefully).

      Fix pass: when the chosen file has any "## Interface-Mainline:"
      line(s), those win outright and plain "## Interface:" line(s) in that
      same file are ignored (they describe a different client's build, not
      an additional retail value to union in) - see addon-sync.ps1's
      identical function for the full rationale.
    #>
    param(
        [string]$AddonsPath,
        [Parameter(Mandatory = $true)][string]$FolderName,
        [string]$Flavor = 'retail',
        $InstalledInterface = $null
    )

    $result = New-Object 'System.Collections.Generic.List[object]'
    if (-not $AddonsPath) {
        Write-Output -NoEnumerate $result
        return
    }
    $folderPath = Join-Path -Path $AddonsPath -ChildPath $FolderName
    if (-not (Test-Path -LiteralPath $folderPath)) {
        Write-Output -NoEnumerate $result
        return
    }
    $chosen = Get-PrimaryTocFile -FolderPath $folderPath -FolderName $FolderName -Flavor $Flavor -InstalledInterface $InstalledInterface
    if (-not $chosen) {
        Write-Output -NoEnumerate $result
        return
    }
    $lines = $null
    try {
        $lines = Get-Content -LiteralPath $chosen.FullName -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Output -NoEnumerate $result
        return
    }
    $mainlineValues = New-Object 'System.Collections.Generic.List[object]'
    $plainValues = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in $lines) {
        if (($Flavor -eq 'retail') -and ($line -match '^\s*##\s*Interface-Mainline\s*:\s*(.*)$')) {
            foreach ($piece in (Split-TocDepList -Value $Matches[1])) {
                $ival = [int64]0
                if ([int64]::TryParse($piece, [ref]$ival)) { $mainlineValues.Add([int64]$ival) }
            }
        } elseif ($line -match '^\s*##\s*Interface\s*:\s*(.*)$') {
            foreach ($piece in (Split-TocDepList -Value $Matches[1])) {
                $ival = [int64]0
                if ([int64]::TryParse($piece, [ref]$ival)) { $plainValues.Add([int64]$ival) }
            }
        }
    }
    if ($mainlineValues.Count -gt 0) {
        foreach ($v in $mainlineValues) { $result.Add($v) }
    } else {
        foreach ($v in $plainValues) { $result.Add($v) }
    }
    Write-Output -NoEnumerate $result
}

function Get-PackageTocInterfaces {
    <# Unions Get-TocInterfaceValues across every folder of a record, deduped. #>
    param($AddonsPath, $Folders, [string]$Flavor = 'retail', $InstalledInterface = $null)

    $seen = New-Object 'System.Collections.Generic.HashSet[int64]'
    $result = New-Object 'System.Collections.Generic.List[object]'
    # Plain foreach, not @($Folders) - matches the CLI's identical function
    # exactly (see its own note on the machine's List[object]/@() quirk);
    # $Folders is a JSON-parsed record property here (never a List[object]
    # in practice), but there is no reason to risk it.
    foreach ($folderName in $Folders) {
        foreach ($v in (Get-TocInterfaceValues -AddonsPath $AddonsPath -FolderName $folderName -Flavor $Flavor -InstalledInterface $InstalledInterface)) {
            if ($seen.Add([int64]$v)) { $result.Add([int64]$v) }
        }
    }
    Write-Output -NoEnumerate $result
}

function Get-AddonCompat {
    <# ok / stale-minor / stale / unknown - see addon-sync.ps1's Get-AddonCompat for the full contract. #>
    param($TocInterfaces, $LatestGameVersions, $ClientInterface)

    if (-not $ClientInterface) { return 'unknown' }
    $clientInterfaceInt = [int64]$ClientInterface
    $clientMajor = [int]([math]::Floor($clientInterfaceInt / 10000))
    $clientMinor = [int]([math]::Floor(($clientInterfaceInt % 10000) / 100))
    $clientPatch = [int]($clientInterfaceInt % 100)
    $clientVersionText = "$clientMajor.$clientMinor.$clientPatch"

    $hasEvidence = $false
    $sameMajor = $false

    # Plain foreach, not @($TocInterfaces) - the machine's documented quirk:
    # @() wrapped around a List[object] (TocInterfaces is exactly that, from
    # Get-PackageTocInterfaces) throws "Argument types do not match".
    foreach ($iface in $TocInterfaces) {
        if ($null -eq $iface) { continue }
        $ifaceInt = [int64]0
        if (-not [int64]::TryParse([string]$iface, [ref]$ifaceInt)) { continue }
        $hasEvidence = $true
        if ($ifaceInt -eq $clientInterfaceInt) { return 'ok' }
        $ifaceMajor = [int]([math]::Floor($ifaceInt / 10000))
        if ($ifaceMajor -eq $clientMajor) { $sameMajor = $true }
    }

    foreach ($gv in $LatestGameVersions) {
        if (-not $gv) { continue }
        $gvText = ([string]$gv).Trim()
        if ($gvText.Length -eq 0) { continue }
        $hasEvidence = $true
        if ($gvText -eq $clientVersionText) { return 'ok' }
        $gvParts = $gvText -split '\.'
        if ($gvParts.Count -ge 1) {
            $gvMajor = 0
            if ([int]::TryParse($gvParts[0], [ref]$gvMajor) -and ($gvMajor -eq $clientMajor)) { $sameMajor = $true }
        }
    }

    if (-not $hasEvidence) { return 'unknown' }
    if ($sameMajor) { return 'stale-minor' }
    return 'stale'
}

function Get-ClientBuildInfo {
    <#
      Reads .build.info's row matching -Product (or, when omitted, -Flavor's
      own S2.1 mapping - 'wow' for retail, unchanged from today's hardcode)
      -> {clientBuild; clientInterface}. FLAVORS-SPEC.md S4.3/CS-F2: gains
      -Flavor (default 'retail') and -Product, mirroring addon-sync.ps1's
      identical function. Never throws.
    #>
    param(
        [string]$BuildInfoPath,
        [string]$Flavor = 'retail',
        [string]$Product
    )

    $result = [PSCustomObject]@{ clientBuild = $null; clientInterface = $null }
    if (-not $BuildInfoPath -or -not (Test-Path -LiteralPath $BuildInfoPath -PathType Leaf)) {
        return $result
    }

    $expectedProduct = $Product
    if (-not $expectedProduct) {
        $def = Get-FlavourDef -Id $Flavor
        if ($def) { $expectedProduct = $def.Product } else { $expectedProduct = 'wow' }
    }

    $lines = $null
    try {
        $lines = Get-Content -LiteralPath $BuildInfoPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        return $result
    }
    if (-not $lines -or $lines.Count -lt 2) { return $result }

    $headerCols = $lines[0] -split '\|'
    $versionIdx = -1
    $productIdx = -1
    for ($i = 0; $i -lt $headerCols.Count; $i++) {
        $colName = ($headerCols[$i] -split '!')[0].Trim()
        if ($colName -eq 'Version') { $versionIdx = $i }
        if ($colName -eq 'Product') { $productIdx = $i }
    }
    if ($versionIdx -lt 0 -or $productIdx -lt 0) { return $result }

    for ($r = 1; $r -lt $lines.Count; $r++) {
        $line = $lines[$r]
        if (-not $line -or $line.Trim().Length -eq 0) { continue }
        $cols = $line -split '\|'
        if ($cols.Count -le $productIdx -or $cols.Count -le $versionIdx) { continue }
        if ($cols[$productIdx].Trim() -eq $expectedProduct) {
            $versionText = $cols[$versionIdx].Trim()
            $result.clientBuild = $versionText
            $result.clientInterface = ConvertTo-InterfaceNumber -VersionText $versionText
            break
        }
    }
    return $result
}

# =====================================================================
# Jobs: CLI process management
# =====================================================================

function Remove-OldJobFiles {
    <#
      Deletes job\*.out/*.err (and the .failed copies a failed job leaves
      behind - see the request loop's own tick comment) older than 1 day.
      Called once at startup, and again periodically from the request
      loop's tick (long-run:failed-job-files-only-pruned-at-startup) so a
      server kept alive for days/weeks doesn't accumulate these unbounded.

      Deliberately defined here, ABOVE the dot-source guard further down
      (mirroring $Script:WagoBaseUrl's own placement rationale) so a unit
      test can dot-source this file, point $Script:JobsDir at a scratch
      directory, and call this directly without ever reaching the real
      "start the server" startup body.
    #>
    if (-not (Test-Path -LiteralPath $Script:JobsDir)) { return }
    $cutoff = (Get-Date).AddDays(-1)
    try {
        $files = Get-ChildItem -LiteralPath $Script:JobsDir -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            if ($f.LastWriteTime -lt $cutoff) {
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    } catch { }
}

function New-JobId {
    $Script:JobIdSeq = $Script:JobIdSeq + 1
    return [string]$Script:JobIdSeq
}

function Add-JobToHistory {
    param($Job)

    $Script:Jobs.Add($Job)
    while ($Script:Jobs.Count -gt 20) {
        $Script:Jobs.RemoveAt(0)
    }
}

function Build-CliArgs {
    <# Maps a job kind + params object to addon-sync.ps1 arguments (excluding -Json/-AddonsPath). #>
    param(
        [string]$Kind,
        $Params
    )

    $argsList = New-Object 'System.Collections.Generic.List[object]'
    switch ($Kind) {
        'sync' {
            if ($Params -and $Params.ids -and @($Params.ids).Count -gt 0) {
                # NOTE: addon-sync.ps1 is invoked as a brand-new "powershell.exe
                # -File ..." child process (Start-Process), never in-process. In
                # that external -File invocation mode, Windows PowerShell 5.1's
                # own argument binder does NOT collect multiple space-separated
                # bare tokens into one array-typed parameter the way an
                # in-process call ("& $script -Only 1 2 3") does - only the
                # FIRST token binds to -Only, and any further tokens spill over
                # as positional values for whichever parameter comes next,
                # silently (no error, no log line) instead of being included
                # in the sync. addon-sync.ps1's own -Only/-Add/-Remove/-Unpin/
                # -Ignore/-Unignore parameters are therefore declared
                # [string[]] and re-split on commas internally
                # (ConvertTo-ExpandedStringArray/ConvertTo-ExpandedIdArray) so
                # that a SINGLE comma-joined token like "111,222,333" - which
                # DOES survive -File binding intact as one literal string -
                # works correctly. So multiple ids must be joined into one
                # comma-separated -Only token here, never passed as separate
                # -ArgumentList elements.
                $idStrings = New-Object 'System.Collections.Generic.List[object]'
                foreach ($id in @($Params.ids)) { $idStrings.Add([string]$id) }
                $argsList.Add('-Only')
                $argsList.Add(($idStrings -join ','))
            }
            if ($Params -and $Params.force) {
                $argsList.Add('-Force')
            }
        }
        'check' {
            $argsList.Add('-DryRun')
        }
        'add' {
            # E18: the first-run Welcome dialog's "Adopt all" button (and,
            # equivalently, install.ps1's own bulk adoption of pre-existing
            # untracked folders) posts projectIds - an array of ALREADY
            # fully-formed target tokens (a bare numeric CurseForge id, or a
            # "wago:<slug-or-id>" string; addon-sync.ps1's own -Add
            # classifier tells the two apart) - instead of a single
            # projectId. Same "one comma-joined -Add token" pattern as the
            # 'remove' case's bulk projectIds above (only a single
            # comma-joined token survives -File binding intact - see that
            # case's comment). FileId is meaningless for a multi-target add
            # (which target would it apply to?), so it is only honoured on
            # the single-projectId path below.
            if ($Params -and $Params.projectIds -and @($Params.projectIds).Count -gt 0) {
                $ids = New-Object 'System.Collections.Generic.List[object]'
                foreach ($id in @($Params.projectIds)) { $ids.Add([string]$id) }
                $argsList.Add('-Add')
                $argsList.Add(($ids -join ','))
            } elseif ($Params -and $Params.projectId) {
                $argsList.Add('-Add')
                $argsList.Add([string]$Params.projectId)
                if ($Params.fileId) {
                    $argsList.Add('-FileId')
                    $argsList.Add([string]$Params.fileId)
                }
            } else {
                throw 'projectId or projectIds is required for kind add'
            }
        }
        'remove' {
            # E11 (bulk actions): the My Addons selection bar's "Uninstall
            # selected" posts projectIds (an array, possibly length 1);
            # every existing single-id caller (the per-row kebab menu) still
            # posts the original singular projectId, which keeps working
            # unchanged. Multiple ids are comma-joined into ONE -Remove
            # token here, same reasoning as the 'sync' case above (only a
            # single comma-joined token survives -File binding intact).
            $ids = New-Object 'System.Collections.Generic.List[object]'
            if ($Params -and $Params.projectIds -and @($Params.projectIds).Count -gt 0) {
                foreach ($id in @($Params.projectIds)) { $ids.Add([string]$id) }
            } elseif ($Params -and $Params.projectId) {
                $ids.Add([string]$Params.projectId)
            }
            if ($ids.Count -eq 0) {
                throw 'projectId or projectIds is required for kind remove'
            }
            $argsList.Add('-Remove')
            $argsList.Add(($ids -join ','))
        }
        'install' {
            if (-not ($Params -and $Params.projectId -and $Params.fileId)) {
                throw 'projectId and fileId are required for kind install'
            }
            $argsList.Add('-Only')
            $argsList.Add([string]$Params.projectId)
            $argsList.Add('-FileId')
            $argsList.Add([string]$Params.fileId)
        }
        'rollback' {
            if (-not ($Params -and $Params.projectId)) {
                throw 'projectId is required for kind rollback'
            }
            $argsList.Add('-Rollback')
            $argsList.Add([string]$Params.projectId)
        }
        default {
            throw "Unknown job kind: $Kind"
        }
    }

    Write-Output -NoEnumerate $argsList
}

function ConvertTo-SafeProcessArg {
    <#
      Round 20 (adversarial bug pass, server-1): wraps a single command-line
      argument in double quotes using CommandLineToArgvW-compatible
      backslash/quote escaping, so a value containing a literal space (e.g.
      an attacker-supplied projectId of "1 -Remove 999") can never be
      re-split into extra argv tokens by the child process - Windows
      PowerShell 5.1's Start-Process -ArgumentList joins array elements with
      a bare, unquoted space before handing them to CreateProcess, so an
      un-quoted element containing a space is indistinguishable from two
      separate arguments once it reaches the child. Every element handed to
      New-CliProcessArgs's $psArgs list is now passed through this (not just
      the two or three that used to be hand-quoted for containing paths with
      spaces), closing the same hole for every CLI argument, not just paths.
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

function New-CliProcessArgs {
    <#
      Full powershell.exe argument list for one addon-sync.ps1 invocation.
      -ProgressPath (CS1) is optional and, when supplied, threads straight
      through to addon-sync.ps1's own -ProgressPath param - see Start-Job,
      the only caller that ever passes it (sync/check/add/install job kinds
      per UX-SPEC.md section 4.2; every other caller of this function omits
      it, and addon-sync.ps1 already no-ops cleanly when it is absent).

      FLAVORS-SPEC.md CS-F2: gains -Flavor (default $Script:CurrentFlavour,
      the request currently in flight - see Set-CurrentFlavourContext),
      threaded straight through to addon-sync.ps1's own -Flavor param -
      every CLI invocation this server makes (jobs AND the synchronous
      fast-ops via Invoke-Cli) is now flavour-scoped, matching whichever
      flavour the caller resolved via Resolve-RequestFlavour. Also threads
      -WowRoot when this server was itself pointed at a fixture
      ($Script:WowRootOverride, CS-F2's own -WowRoot) so the CLI child
      process resolves against the SAME fixture, never the real WoW folder.
      -Flavor 'retail' is never sent explicitly (it's the CLI's own
      default) so a single-flavour machine's CLI invocations are
      byte-identical to before this change set.
    #>
    param(
        [System.Collections.Generic.List[object]]$CliArgs,
        [string]$ProgressPath,
        [string]$Flavor
    )

    if (-not $Flavor) { $Flavor = $Script:CurrentFlavour }

    $psArgs = New-Object 'System.Collections.Generic.List[object]'
    $psArgs.Add('-NoProfile')
    $psArgs.Add('-ExecutionPolicy')
    $psArgs.Add('Bypass')
    # Round 20 (adversarial bug pass, server-1): every element below is now
    # quoted via ConvertTo-SafeProcessArg, not just the paths that used to be
    # hand-quoted here - Start-Process joins -ArgumentList elements with a
    # bare, unquoted space, so ANY element containing a space (a path, or an
    # attacker-supplied projectId/fileId flowing through $CliArgs) could
    # otherwise be re-split into extra argv tokens by the child process.
    $psArgs.Add('-File')
    $psArgs.Add((ConvertTo-SafeProcessArg $Script:CliPath))
    foreach ($a in $CliArgs) { $psArgs.Add((ConvertTo-SafeProcessArg ([string]$a))) }
    $psArgs.Add('-Json')
    if ($Script:AddonsPathOverride) {
        $psArgs.Add('-AddonsPath')
        $psArgs.Add((ConvertTo-SafeProcessArg $Script:AddonsPathOverride))
    }
    if ($Flavor -and $Flavor -ne 'retail') {
        $psArgs.Add('-Flavor')
        $psArgs.Add((ConvertTo-SafeProcessArg $Flavor))
    }
    if ($Script:WowRootOverride) {
        $psArgs.Add('-WowRoot')
        $psArgs.Add((ConvertTo-SafeProcessArg $Script:WowRootOverride))
    }
    if ($ProgressPath) {
        $psArgs.Add('-ProgressPath')
        $psArgs.Add((ConvertTo-SafeProcessArg $ProgressPath))
    }
    Write-Output -NoEnumerate $psArgs
}

function Test-JobBusy {
    <#
      True (and, if -Context given, writes a 409 busy response) when a job is
      currently running FOR -Flavor (default $Script:CurrentFlavour - the
      request currently in flight, per Set-CurrentFlavourContext).
      FLAVORS-SPEC.md CS-F2 S5.4: scoped per flavour, not global - a Retail
      sync and a Classic Era sync may run concurrently; two Retail syncs
      still can't (the per-flavour slot Get-CurrentJobForFlavour reads
      already enforces that on its own). Refreshes the current job's state
      first so a job that just finished is not reported busy.
    #>
    param($Context, [string]$Flavor)

    if (-not $Flavor) { $Flavor = $Script:CurrentFlavour }
    if (-not $Flavor) { $Flavor = 'retail' }

    $current = Get-CurrentJobForFlavour -Flavor $Flavor
    if ($current -and $current.state -eq 'running') {
        Update-JobStatus -Job $current | Out-Null
    }
    $current = Get-CurrentJobForFlavour -Flavor $Flavor
    if ($current -and $current.state -eq 'running') {
        if ($Context) {
            Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'busy'; jobId = $current.id }
        }
        return $true
    }
    return $false
}

function Start-Job {
    <#
      Starts one job (spec section 2, "Jobs" table) for the flavour named by
      -Flavor (default $Script:CurrentFlavour, per FLAVORS-SPEC.md CS-F2
      S5.4's job.flavour field). Returns a hashtable:
        Busy  = $true  -> a job is already running for that flavour (Job holds it)
        Error = <text> -> could not start (bad params, process launch failed)
        Job   = <job>  -> started (or, for a job with nothing to do, already finished)
    #>
    param(
        [string]$Kind,
        $Params,
        [string]$Flavor,
        # FLAVORS-SPEC.md CS-F3 S5.5: true only when the CALLER'S request
        # named an explicit ?flavour=/?flavor= (Handle-JobsPost's own
        # Get-QueryFlavour read, threaded through here) - NOT whether
        # -Flavor itself is non-empty, since -Flavor is always resolved to
        # something (the request's default/active flavour) by the time
        # Start-Job is called. An explicit flavour always wins outright, no
        # ambiguity re-check (principle 5); an omitted one is what lets the
        # CurseForge install-flavour resolution below engage at all.
        [bool]$FlavourExplicit = $false
    )

    if (-not $Flavor) { $Flavor = $Script:CurrentFlavour }
    if (-not $Flavor) { $Flavor = 'retail' }

    if (Test-JobBusy -Flavor $Flavor) {
        return @{ Busy = $true; Job = (Get-CurrentJobForFlavour -Flavor $Flavor) }
    }

    # FLAVORS-SPEC.md CS-F3: remembered so the CurseForge install-flavour
    # resolution below (which can reassign $Flavor to the one flavour that
    # actually matches) can re-check Test-JobBusy for the NEW flavour - the
    # busy check just above only ever covered the flavour this request
    # originally defaulted/resolved to.
    $originalRequestFlavor = $Flavor

    $jobId = New-JobId
    $startedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    # E4: import can take anywhere from zero to several addon-sync.ps1
    # invocations chained in sequence (see Build-ImportPlan) rather than the
    # exactly-one-CLI-call shape every kind below assumes, so it is built and
    # started entirely by its own helper instead of falling through to
    # Build-CliArgs/New-CliProcessArgs here.
    if ($Kind -eq 'import') {
        return (Start-ImportJob -JobId $jobId -StartedAt $startedAt -Params $Params -Flavor $Flavor)
    }

    # E12: switch-source (uninstall the tracked addon, then add it fresh from
    # the OTHER source) is, like import, a multi-phase job - see
    # Start-SwitchSourceJob/Complete-SwitchSourcePhase.
    if ($Kind -eq 'switch-source') {
        return (Start-SwitchSourceJob -JobId $jobId -StartedAt $startedAt -Params $Params -Flavor $Flavor)
    }

    # E19: add-by-slug {slug, fileId?} - the native host's CurseForge-tab
    # install-link interception knows only the URL slug, never the numeric
    # projectId, so resolve it here (an in-memory dictionary/linear-scan
    # lookup against the same keyless catalogue index /api/cf/browse and
    # /api/cf/enrich already use - no network call, so this stays
    # synchronous unlike every CLI-backed job kind) and fall through to the
    # ordinary single-projectId 'add' path below. Unlike a bad-request
    # (caught earlier, in Handle-JobsPost, as a 400 before Start-Job is ever
    # called), an unresolvable slug is a valid request that simply has
    # nothing to install - per SPEC that is reported as a "404-style failed
    # job" (a real job, in state 'failed', with a synthetic 404 exitCode)
    # rather than an HTTP-level error, so the host's blind
    # POST-then-switch-tabs flow always gets a jobId whose progress panel
    # then shows the failure normally, same as any other Failed CLI result.
    if ($Kind -eq 'add-by-slug') {
        $slug = $null
        if ($Params -and $Params.slug) { $slug = [string]$Params.slug }
        if (-not $slug) {
            return @{ Busy = $false; Error = 'slug is required for kind add-by-slug' }
        }
        $entry = Get-CfCatalogueEntryBySlug -Slug $slug
        if (-not $entry) {
            $finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $job = [PSCustomObject]@{
                id            = $jobId
                kind          = 'add-by-slug'
                params        = $Params
                state         = 'failed'
                startedAt     = $startedAt
                finishedAt    = $finishedAt
                exitCode      = 404
                log           = New-Object 'System.Collections.Generic.List[object]'
                results       = New-Object 'System.Collections.Generic.List[object]'
                error         = "No CurseForge addon found for slug '$slug' (404)"
                flavour       = $Flavor
                Process       = $null
                OutFile       = $null
                ErrFile       = $null
                SyncLogOffset = 0
            }
            Add-JobToHistory -Job $job
            Save-CheckState
            return @{ Busy = $false; Job = $job }
        }
        $Kind = 'add'
        $Params = Add-Member -InputObject $Params -NotePropertyName 'projectId' -NotePropertyValue $entry.id -Force -PassThru
    }

    # FLAVORS-SPEC.md CS-F3 S5.5: CurseForge install-flavour resolution.
    # Only engages for a genuine, SINGLE-target CurseForge add/install
    # (add-by-slug has already been normalized into 'add' with a resolved
    # numeric projectId by this point) when the caller did NOT name an
    # explicit ?flavour= and more than one flavour is installed - a
    # single-flavour machine can never hit this ambiguity (Get-CfFlavourMapping
    # already resolves correctly at n=1, so the count check below is a
    # no-op there - "invisible at one flavour" preserved), and an explicit
    # ?flavour= (including the picker's own resume POST, case 5 below)
    # always wins outright with no re-check (principle 5). Never engages
    # for a Wago target (source=wago+slug, or an already-tracked Wago
    # addon's projectId of the form "wago:<slug>") - Wago's one flavour is
    # already resolved by the search's own game_version param (S6.4), so
    # there is nothing ambiguous to ask about. A bulk add (projectIds[])
    # never reaches here either - $Params.projectId is only ever set for
    # the single-target path, so a bulk add still 400s upstream in
    # Handle-JobsPost exactly as before this change set (silently guessing
    # a flavour for several addons at once is not this feature's job).
    if (($Kind -eq 'add' -or $Kind -eq 'install') -and (-not $FlavourExplicit) -and $Params -and $Params.projectId) {
        $isWagoTarget = [bool](
            ($Params.source -and (([string]$Params.source).ToLowerInvariant() -eq 'wago') -and $Params.slug) -or
            (([string]$Params.projectId).ToLowerInvariant().StartsWith('wago:'))
        )
        if (-not $isWagoTarget) {
            $installedForResolve = Get-CurrentInstalledFlavours
            if ((@($installedForResolve)).Count -gt 1) {
                $numericProjectId = 0L
                $isNumericProjectId = [int64]::TryParse([string]$Params.projectId, [ref]$numericProjectId)
                if ($isNumericProjectId) {
                    $settingsForResolve = Get-Settings
                    $showTestForResolve = [bool]$settingsForResolve.showTestRealms
                    $visibleFlavoursForResolve = New-Object 'System.Collections.Generic.List[object]'
                    foreach ($f in $installedForResolve) {
                        if ((-not $showTestForResolve) -and (@('ptr', 'xptr', 'beta') -contains $f.id)) { continue }
                        $visibleFlavoursForResolve.Add($f)
                    }
                    $resolveFileId = $null
                    if ($Params.fileId) { $resolveFileId = $Params.fileId }
                    $resolution = Resolve-CfInstallFlavour -ProjectId $numericProjectId -FileId $resolveFileId -InstalledFlavours $visibleFlavoursForResolve

                    if ($resolution.FetchError) {
                        # A gameVersionTypeIds fetch failure (network hiccup, bad
                        # projectId/fileId, CurseForge unreachable) - report exactly
                        # like any other job-start failure; no job created.
                        return @{ Busy = $false; Error = $resolution.FetchError }
                    }

                    $matchIds = @($resolution.MatchingFlavourIds)
                    if ($matchIds.Count -eq 0) {
                        # S5.5 case 4: zero matches - a real job, immediately
                        # failed, the same "404-style failed job" pattern the
                        # add-by-slug unresolved-slug branch above uses (a plain
                        # message, not an HTTP-level error, so the panel that
                        # already shows every other failure shows this one too).
                        $finishedAtZero = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                        $zeroJob = [PSCustomObject]@{
                            id            = $jobId
                            kind          = $Kind
                            params        = $Params
                            state         = 'failed'
                            startedAt     = $startedAt
                            finishedAt    = $finishedAtZero
                            exitCode      = 422
                            log           = New-Object 'System.Collections.Generic.List[object]'
                            results       = New-Object 'System.Collections.Generic.List[object]'
                            error         = "This addon doesn't support your installed WoW versions."
                            flavour       = $null
                            Process       = $null
                            OutFile       = $null
                            ErrFile       = $null
                            SyncLogOffset = 0
                        }
                        Add-JobToHistory -Job $zeroJob
                        Save-CheckState
                        return @{ Busy = $false; Job = $zeroJob }
                    } elseif ($matchIds.Count -eq 1) {
                        # S5.5 case 3: exactly one match - install there
                        # silently, no prompt. Overrides $Flavor to the ONE
                        # matching flavour (which may differ from whatever this
                        # request defaulted to) - the busy re-check just below
                        # this whole block covers the case where that flavour
                        # differs from $originalRequestFlavor.
                        $Flavor = $matchIds[0]
                    } else {
                        # S5.5 case 5: more than one match - create the job in
                        # a new 'awaiting_flavour' state instead of dispatching
                        # to the CLI at all; the SPA's picker (ui/app.js
                        # Components.JobPanel) resumes by re-POSTing the
                        # IDENTICAL body with ?flavour=<chosen> set, which then
                        # carries FlavourExplicit=$true and skips this whole
                        # block outright (case 3's silent path, effectively).
                        $choices = New-Object 'System.Collections.Generic.List[object]'
                        foreach ($mid in $matchIds) {
                            $def = Get-FlavourDef -Id $mid
                            $lbl = $mid
                            if ($def) { $lbl = $def.Label }
                            $choices.Add([PSCustomObject]@{ id = $mid; label = $lbl })
                        }
                        $askJob = [PSCustomObject]@{
                            id            = $jobId
                            kind          = $Kind
                            params        = $Params
                            state         = 'awaiting_flavour'
                            startedAt     = $startedAt
                            finishedAt    = $null
                            exitCode      = $null
                            log           = New-Object 'System.Collections.Generic.List[object]'
                            results       = New-Object 'System.Collections.Generic.List[object]'
                            error         = $null
                            flavour       = $null
                            choices       = $choices.ToArray()
                            Process       = $null
                            OutFile       = $null
                            ErrFile       = $null
                            SyncLogOffset = 0
                        }
                        Add-JobToHistory -Job $askJob
                        Save-CheckState
                        return @{ Busy = $false; Job = $askJob }
                    }
                }
            }
        }
    }

    # A case-3 auto-resolution just above may have reassigned $Flavor to a
    # DIFFERENT flavour than the one Test-JobBusy already checked at the top
    # of this function - re-check the new flavour's own busy slot before
    # dispatching to it. When $Flavor never changed (every other path
    # through this function), this is a no-op re-check of the same flavour
    # already known free.
    if ($Flavor -ne $originalRequestFlavor) {
        if (Test-JobBusy -Flavor $Flavor) {
            return @{ Busy = $true; Job = (Get-CurrentJobForFlavour -Flavor $Flavor) }
        }
    }

    $cliKind = $Kind

    # E12: a NEW Wago add/install (no existing record yet, so no projectId-
    # equivalent key to reuse) is posted as {source:'wago', slug, fileId?}
    # per SPEC rather than a bare projectId. Build-CliArgs's 'add'/'install'
    # cases already just [string]-cast Params.projectId/fileId generically
    # (they always have, even before E12 - see their own comments), so
    # normalizing to the same "wago:<slug>" token addon-sync.ps1's -Add/-Only
    # classifier already accepts lets both cases run completely unchanged
    # below - an ADD/INSTALL targeting an ALREADY-TRACKED Wago addon (e.g.
    # the kebab menu's "Update now"/Versions-tab "Install") instead posts
    # projectId directly as that same "wago:<slug>" string (the addon's own
    # Store.addonKey), which needs no normalization here at all.
    if (($cliKind -eq 'add' -or $cliKind -eq 'install') -and $Params -and $Params.source -and (([string]$Params.source).ToLowerInvariant() -eq 'wago') -and $Params.slug) {
        $Params = Add-Member -InputObject $Params -NotePropertyName 'projectId' -NotePropertyValue ('wago:' + [string]$Params.slug) -Force -PassThru
    }

    try {
        $cliArgs = Build-CliArgs -Kind $cliKind -Params $Params
    } catch {
        return @{ Busy = $false; Error = $_.Exception.Message }
    }

    if (-not (Test-Path -LiteralPath $Script:JobsDir)) {
        New-Item -ItemType Directory -Path $Script:JobsDir -Force | Out-Null
    }

    $outFile = Join-Path -Path $Script:JobsDir -ChildPath "$jobId.out"
    $errFile = Join-Path -Path $Script:JobsDir -ChildPath "$jobId.err"

    $syncLogOffset = 0
    if (Test-Path -LiteralPath $Script:SyncLogPath) {
        $syncLogOffset = (Get-Item -LiteralPath $Script:SyncLogPath).Length
    }

    # CS1: -ProgressPath is threaded only for the job kinds UX-SPEC.md
    # section 4.2 names (sync/check/add/install). remove/rollback and the
    # multi-phase import/switch-source kinds (built by their own Start-*Job
    # helpers, never reaching this single-phase path) get no progress file -
    # Update-JobStatus's read is likewise gated on $Job.ProgressPath being set.
    $progressPath = $null
    if ($cliKind -eq 'sync' -or $cliKind -eq 'check' -or $cliKind -eq 'add' -or $cliKind -eq 'install') {
        $progressPath = Join-Path -Path $Script:JobsDir -ChildPath "$jobId.progress.json"
    }

    $psArgs = New-CliProcessArgs -CliArgs $cliArgs -ProgressPath $progressPath -Flavor $Flavor

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs.ToArray() -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # Force the SafeProcessHandle to materialize now. Without this, reading
        # .ExitCode later (after HasExited) is unreliable on this machine: it can
        # throw "You cannot call a method on a null-valued expression" or silently
        # return $null even though the process actually completed.
        $proc.Handle | Out-Null
    } catch {
        return @{ Busy = $false; Error = "Failed to start CLI process: $($_.Exception.Message)" }
    }

    $job = [PSCustomObject]@{
        id            = $jobId
        kind          = $Kind
        params        = $Params
        state         = 'running'
        startedAt     = $startedAt
        finishedAt    = $null
        exitCode      = $null
        log           = New-Object 'System.Collections.Generic.List[object]'
        results       = New-Object 'System.Collections.Generic.List[object]'
        error         = $null
        # FLAVORS-SPEC.md CS-F2 S5.4: every job carries its own flavour.
        flavour       = $Flavor
        Process       = $proc
        OutFile       = $outFile
        ErrFile       = $errFile
        SyncLogOffset = $syncLogOffset
        # CS1: $null for every job kind that gets no -ProgressPath (see
        # above) - Update-JobStatus's best-effort read no-ops on a falsy
        # ProgressPath exactly like Write-ProgressStep itself does CLI-side.
        ProgressPath  = $progressPath
        # GAME-MODE-SPEC.md section 4.1: captured ONCE, at job-creation
        # time - whether WoW was already running when this job started.
        # addon-sync.ps1 itself has zero game-state awareness, so this can
        # only be captured here, server-side. Feeds Get-JobStatusView's
        # reloadNeeded predicate.
        gameRunningAtStart = (Test-GameRunning)
    }
    Add-JobToHistory -Job $job
    Set-CurrentJobForFlavour -Flavor $Flavor -Job $job
    return @{ Busy = $false; Job = $job }
}

# =====================================================================
# Export / Import (E4)
# =====================================================================

function Build-ImportPlan {
    <#
      Computes the sequence of addon-sync.ps1 invocations ("phases") needed
      to apply an imported addons-export.json body, plus any result rows
      that need no CLI call at all. Returns a hashtable (a single object -
      safe to `return` directly, unlike the List[object]s inside it, which
      the caller must never re-wrap in `@()`): @{ Phases = <List[object] of
      CliArgs Lists>; SkipRows = <List[object] of {status,name,version,
      projectId,fileId,wagoSlug} rows> }.

      E12 fix (Round 9): each entry is identified by a TARGET TOKEN -
      Get-UpdateAvailableKeyForRecord's own duplex key, reused verbatim
      since an import entry (post-Handle-Export fix) carries the exact same
      projectId/source/slug shape a real addon record does: the numeric
      CurseForge project id as a string, or "wago:<slug>" for a Wago-sourced
      entry (identifiable only via source/slug - it has no numeric id at
      all). This token is also exactly what addon-sync.ps1's -Add/-Only/
      -Ignore target classifier already accepts, CurseForge or Wago alike,
      so no further translation is needed before it lands in a phase's
      CliArgs. An entry with neither (foreign/malformed data, or a
      CurseForge row missing even a projectId) is unidentifiable and
      skipped outright, same as before.

      -Add is issued ONCE with every not-yet-present target comma-joined
      (SPEC: "one CLI invocation with all ids" - the exact same
      comma-joined-single-token requirement Build-CliArgs's own 'sync' case
      already documents at length, since addon-sync.ps1 is likewise always
      invoked as a brand-new "-File" child process here, never in-process).
      pinnedFileId then needs its own -Only/-FileId phase PER addon (that
      flag pair only ever targets a single project - addon-sync.ps1 itself
      rejects more than one id alongside -FileId), including one for an
      addon this same plan is also adding: the newest file installs first,
      then this phase reinstalls the pinned one, exactly mirroring the
      roadmap's own two-step wording rather than trying to fold both into
      one -Add -FileId call (which only ever supports a single id, so it
      cannot cover a multi-addon import). An ignoreUpdates flag needs no
      per-addon restriction, so every target that wants it - freshly added
      by this import or already on record - is batched into one trailing
      -Ignore phase. releaseType is captured on export for round-tripping
      but is deliberately NOT applied on import: no CLI flag sets a
      record's per-addon releaseType override directly (SPEC.md's addon-
      sync.ps1 contract has no such param), and inventing a direct
      addons.json write here would break the "the CLI owns writes" rule
      this whole file otherwise holds to.

      An imported addon already present with neither pinnedFileId nor
      ignoreUpdates set needs no CLI call at all - its SkipRow mirrors the
      exact shape addon-sync.ps1's own "-Add: already present" path already
      produces (Name/Version/FileId straight from the EXISTING record, plus
      wagoSlug for a Wago one - the same additive field every other -Json
      result row carries per SPEC), so the job's results read the same as
      they would if the underlying add job itself had done the skipping.
    #>
    param(
        [Parameter(Mandatory = $true)]$ImportAddons,
        [Parameter(Mandatory = $true)][hashtable]$ExistingById
    )

    $phases = New-Object 'System.Collections.Generic.List[object]'
    $skipRows = New-Object 'System.Collections.Generic.List[object]'

    $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    $toAddTargets = New-Object 'System.Collections.Generic.List[object]'
    $pinEntries = New-Object 'System.Collections.Generic.List[object]'
    $ignoreTargets = New-Object 'System.Collections.Generic.List[object]'
    $ignoreSeen = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($entry in @($ImportAddons)) {
        if (-not $entry) { continue }
        $key = Get-UpdateAvailableKeyForRecord -Record $entry
        if (-not $key) { continue }   # neither a numeric projectId nor a wago:<slug> pair - unidentifiable
        if (-not $seenKeys.Add($key)) { continue }   # dedupe within the import file itself

        $existingRecord = $null
        $isNew = $true
        if ($ExistingById.ContainsKey($key)) {
            $existingRecord = $ExistingById[$key]
            $isNew = $false
        }

        $hasPin = $false
        $fid = [int64]0
        if ($null -ne $entry.pinnedFileId) {
            try { $fid = [int64]$entry.pinnedFileId; $hasPin = $true } catch { $hasPin = $false }
        }
        $hasIgnore = [bool]$entry.ignoreUpdates

        if ($isNew) {
            $toAddTargets.Add($key)
        }
        if ($hasPin) {
            $pinEntries.Add([PSCustomObject]@{ Target = $key; FileId = $fid })
        }
        if ($hasIgnore -and $ignoreSeen.Add($key)) {
            $ignoreTargets.Add($key)
        }

        if ((-not $isNew) -and (-not $hasPin) -and (-not $hasIgnore)) {
            $skipWagoSlug = $null
            if ($existingRecord.source -eq 'wago') { $skipWagoSlug = $existingRecord.slug }
            $skipRows.Add([PSCustomObject]@{
                    status    = 'Skipped'
                    name      = $existingRecord.name
                    version   = $existingRecord.version
                    projectId = $existingRecord.projectId
                    fileId    = $existingRecord.fileId
                    wagoSlug  = $skipWagoSlug
                })
        }
    }

    if ($toAddTargets.Count -gt 0) {
        $addArgs = New-Object 'System.Collections.Generic.List[object]'
        $addArgs.Add('-Add')
        $addArgs.Add(($toAddTargets -join ','))
        $phases.Add($addArgs)
    }

    foreach ($pin in $pinEntries) {
        $pinArgs = New-Object 'System.Collections.Generic.List[object]'
        $pinArgs.Add('-Only')
        $pinArgs.Add([string]$pin.Target)
        $pinArgs.Add('-FileId')
        $pinArgs.Add([string]$pin.FileId)
        $phases.Add($pinArgs)
    }

    if ($ignoreTargets.Count -gt 0) {
        $ignoreArgs = New-Object 'System.Collections.Generic.List[object]'
        $ignoreArgs.Add('-Ignore')
        $ignoreArgs.Add(($ignoreTargets -join ','))
        $phases.Add($ignoreArgs)
    }

    return @{ Phases = $phases; SkipRows = $skipRows }
}

function Start-ImportPhase {
    <#
      Launches the next not-yet-run phase of a multi-phase 'import' job
      (see Build-ImportPlan) as a hidden addon-sync.ps1 child process -
      exactly like the single-phase kinds below, since Update-JobStatus's
      sync.log tailing and Process/HasExited polling don't care how many
      phases a job has, only whether $Job.Process is currently running.
      Only the process-launch and phase-advance bookkeeping here is
      import-specific. Returns $true once a process is running, $false on
      failure (the caller fails the whole job).
    #>
    param($Job)

    $Job.PhaseIndex = $Job.PhaseIndex + 1
    $cliArgs = $Job.Phases[$Job.PhaseIndex]

    if (-not (Test-Path -LiteralPath $Script:JobsDir)) {
        New-Item -ItemType Directory -Path $Script:JobsDir -Force | Out-Null
    }
    $outFile = Join-Path -Path $Script:JobsDir -ChildPath "$($Job.id)-$($Job.PhaseIndex).out"
    $errFile = Join-Path -Path $Script:JobsDir -ChildPath "$($Job.id)-$($Job.PhaseIndex).err"

    $psArgs = New-CliProcessArgs -CliArgs $cliArgs -Flavor $Job.flavour

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs.ToArray() -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # See Start-Job: force the SafeProcessHandle to materialize now so
        # that reading .ExitCode later is reliable on this machine.
        $proc.Handle | Out-Null
    } catch {
        Write-ServerLog "Failed to start import phase $($Job.PhaseIndex) for job $($Job.id): $($_.Exception.Message)"
        return $false
    }

    $Job.Process = $proc
    $Job.OutFile = $outFile
    $Job.ErrFile = $errFile
    return $true
}

function Start-ImportJob {
    <#
      Builds and starts (or, when there is nothing at all to do, finishes
      immediately) a multi-phase 'import' job. Split out of Start-Job so
      every single-CLI-invocation job kind there is completely untouched by
      this addition; called only from there, after its own Test-JobBusy
      check has already passed.
    #>
    param(
        [string]$JobId,
        [string]$StartedAt,
        $Params,
        [string]$Flavor
    )

    if (-not $Flavor) { $Flavor = $Script:CurrentFlavour }
    if (-not $Flavor) { $Flavor = 'retail' }

    $importAddons = @()
    if ($Params -and ($null -ne $Params.addons)) { $importAddons = @($Params.addons) }

    # E12 fix (Round 9): keyed the same duplex way Get-UpdateAvailableKeyForRecord
    # already keys $Script:UpdateAvailable - the numeric projectId (as a
    # string) for a CurseForge record, or "wago:<slug>" for a Wago-sourced
    # one (which has no numeric projectId at all and was previously omitted
    # from this map entirely, making every already-tracked Wago addon look
    # brand-new to Build-ImportPlan).
    $existingById = @{}
    foreach ($r in (Get-AddonRecords)) {
        $key = Get-UpdateAvailableKeyForRecord -Record $r
        if ($key) { $existingById[$key] = $r }
    }

    $plan = Build-ImportPlan -ImportAddons $importAddons -ExistingById $existingById

    $job = [PSCustomObject]@{
        id            = $JobId
        kind          = 'import'
        params        = $Params
        state         = 'running'
        startedAt     = $StartedAt
        finishedAt    = $null
        exitCode      = $null
        log           = New-Object 'System.Collections.Generic.List[object]'
        results       = New-Object 'System.Collections.Generic.List[object]'
        error         = $null
        flavour       = $Flavor
        Process       = $null
        OutFile       = $null
        ErrFile       = $null
        SyncLogOffset = 0
        Phases        = $plan.Phases
        PhaseIndex    = -1
        # GAME-MODE-SPEC.md section 4.1: captured before checking whether
        # there is anything to import - correct even on the zero-phases
        # immediate-finish branch just below.
        gameRunningAtStart = (Test-GameRunning)
    }
    foreach ($row in $plan.SkipRows) { $job.results.Add($row) }

    if ($job.Phases.Count -eq 0) {
        # Every imported addon was already present with no pinnedFileId/
        # ignoreUpdates to (re)apply - SkipRows above already covered every
        # row, so there is no CLI process to run at all: finish immediately.
        $job.state = 'done'
        $job.exitCode = 0
        $job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Add-JobToHistory -Job $job
        Apply-JobCompletionSideEffects -Job $job -Parsed ([PSCustomObject]@{ action = 'import' })
        Save-CheckState
        return @{ Busy = $false; Job = $job }
    }

    if (Test-Path -LiteralPath $Script:SyncLogPath) {
        $job.SyncLogOffset = (Get-Item -LiteralPath $Script:SyncLogPath).Length
    }

    Add-JobToHistory -Job $job
    Set-CurrentJobForFlavour -Flavor $Flavor -Job $job

    $started = Start-ImportPhase -Job $job
    if (-not $started) {
        $job.state = 'failed'
        $job.error = 'Failed to start import'
        $job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Set-CurrentJobForFlavour -Flavor $Flavor -Job $null
        Save-CheckState
    }
    return @{ Busy = $false; Job = $job }
}

# =====================================================================
# state.json: persisted check results (E2 - automatic update checks)
# =====================================================================

function Save-CheckState {
    <#
      Persists $Script:UpdatesCheckedAtByFlavour + $Script:UpdateAvailable-
      ByFlavour (E2, made per-flavour by FLAVORS-SPEC.md CS-F2 S5.3) and, as
      of Round 3, $Script:LastRunByFlavour + the last 20 completed jobs
      (shared across every flavour, each carrying its own .flavour field per
      S5.4) to ROOT\state.json, so the "n updates" badge, the My Addons
      "Last run" line (/api/state.lastRun), the rollback tooltip / job
      history (/api/state.job, /api/jobs) all survive a server restart
      instead of resetting to null/empty. Jobs are serialized via
      Get-JobStatusView - plain data (id/kind/params/state/.../log[]/
      results[]/error/flavour), never the raw Job objects, which carry a
      live System.Diagnostics.Process handle that cannot be (and must never
      be) JSON-serialized. Best-effort: a write failure is logged, never
      thrown (must not abort the job-completion path that calls this).

      CS-F2 deliberately keeps ONE state.json at the shared root rather than
      splitting it under flavours\<id>\ the way FLAVORS-SPEC.md S3.1's
      literal file-tree diagram shows addons.json/backups\ - job history is
      one shared, flavour-tagged list by S5.4's own description ("a flavour
      badge... only when more than one flavour installed", implying one
      list, not N), and splitting the freshness bookkeeping too would need a
      materially larger restart-time merge across N per-flavour files for no
      behavioral gain this change set's verify bar calls for. Flagged
      explicitly in this change set's notesForNext for whoever next touches
      this area.
    #>
    $jobViews = New-Object 'System.Collections.Generic.List[object]'
    foreach ($j in $Script:Jobs) {
        $jobViews.Add((Get-JobStatusView -Job $j))
    }

    $body = [PSCustomObject]@{
        updatesCheckedAt   = $Script:UpdatesCheckedAtByFlavour
        updateAvailable    = $Script:UpdateAvailableByFlavour
        lastRun            = $Script:LastRunByFlavour
        jobs               = $jobViews.ToArray()
        # E12: persists the Wago Inertia asset version across a restart, per
        # SPEC's documented "cache the version in state.json" - saves the
        # very first Wago proxy call after a restart the plain-HTML
        # handshake round-trip it would otherwise need to pay again.
        wagoInertiaVersion = $Script:WagoInertiaVersion
    }
    try {
        # -InputObject (not a pipe): piping a single-property object through
        # ConvertTo-Json risks the same single-element unwrap quirk documented
        # for arrays elsewhere in this codebase, and -InputObject sidesteps it.
        $json = ConvertTo-Json -InputObject $body -Depth 8
        $tmpPath = "$Script:StatePath.tmp"
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
        Move-Item -LiteralPath $tmpPath -Destination $Script:StatePath -Force
    } catch {
        Write-ServerLog "Failed to write state.json: $($_.Exception.Message)"
    }
}

function Load-CheckState {
    <#
      Loads updatesCheckedAt/updateAvailable/lastRun/jobs from ROOT\state.json
      at startup into the per-flavour ...ByFlavour dictionaries and
      $Script:Jobs. Tolerates a missing, empty, or corrupt file (leaves the
      caller's already-initialized defaults/empty list in place).

      FLAVORS-SPEC.md CS-F2: also tolerates a PRE-flavour state.json (one
      written before this change set - updatesCheckedAt/updateAvailable/
      lastRun as flat scalars/objects, no per-flavour nesting, jobs with no
      .flavour field) by detecting the old flat shape and adopting it as the
      'retail' flavour's own bucket - a restart right after upgrading to
      this build never loses a pre-existing single-flavour install's
      freshness/job history. A job loaded with no .flavour field at all
      (same pre-upgrade file) defaults to 'retail', matching S4.1's own
      "existing single-flavour behavior, unchanged" bar.

      Round 3: a persisted job can never be reloaded as 'running' - the
      System.Diagnostics.Process behind it belonged to the PREVIOUS server
      instance and is gone the moment this one starts, so any job whose
      saved state is not already 'done'/'failed' (i.e. the server was killed
      mid-job) is forced to 'failed' on load, and every loaded job gets
      Process/OutFile/ErrFile = $null (nothing left to reattach to or clean
      up - Update-JobStatus's own state-!='running' guard means these are
      never touched again for a loaded job anyway). $Script:JobIdSeq is
      advanced past the highest loaded job id so New-JobId can never reissue
      an id a client might already be polling.
    #>
    if (-not (Test-Path -LiteralPath $Script:StatePath)) {
        return
    }
    try {
        # Get-Content is safe here: $raw only feeds ConvertFrom-Json below and is
        # never returned/serialized itself, so its PSPath/PSDrive/PSProvider note
        # properties never reach a JSON response (see Update-JobStatus for the
        # pattern that actually hangs Send-Json).
        $raw = Get-Content -LiteralPath $Script:StatePath -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return
        }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop

        # updatesCheckedAt: new shape is an object keyed by flavour id; the
        # pre-flavour shape was a bare string - a string has no
        # .PSObject.Properties worth iterating (Get-Member would show only
        # String's own members), so this old-shape check is simply "is it a
        # string at all".
        if ($null -ne $obj.updatesCheckedAt) {
            if ($obj.updatesCheckedAt -is [string]) {
                $Script:UpdatesCheckedAtByFlavour = @{ retail = [string]$obj.updatesCheckedAt }
            } else {
                $map = @{}
                foreach ($p in $obj.updatesCheckedAt.PSObject.Properties) {
                    $map[$p.Name] = [string]$p.Value
                }
                $Script:UpdatesCheckedAtByFlavour = $map
            }
        }
        if ($null -ne $obj.updateAvailable) {
            # New shape: {flavour: {key: {fileId, version}}}. Old shape:
            # {key: {fileId, version}} directly - distinguished by whether
            # any top-level property's own value looks like an
            # updateAvailable entry (has a fileId or version member) rather
            # than another nested flavour bucket (which would not).
            $looksOldShape = $false
            foreach ($p in $obj.updateAvailable.PSObject.Properties) {
                if ($null -ne $p.Value -and (($null -ne $p.Value.fileId) -or ($null -ne $p.Value.version))) {
                    $looksOldShape = $true
                }
                break
            }
            if ($looksOldShape) {
                $map = @{}
                foreach ($p in $obj.updateAvailable.PSObject.Properties) {
                    $map[$p.Name] = @{ fileId = $p.Value.fileId; version = $p.Value.version }
                }
                $Script:UpdateAvailableByFlavour = @{ retail = $map }
            } else {
                $outer = @{}
                foreach ($fp in $obj.updateAvailable.PSObject.Properties) {
                    $inner = @{}
                    foreach ($p in $fp.Value.PSObject.Properties) {
                        $inner[$p.Name] = @{ fileId = $p.Value.fileId; version = $p.Value.version }
                    }
                    $outer[$fp.Name] = $inner
                }
                $Script:UpdateAvailableByFlavour = $outer
            }
        }
        if ($null -ne $obj.lastRun) {
            # New shape: {flavour: {timestamp, summary, rows}}. Old shape:
            # {timestamp, summary, rows} directly - distinguished by the
            # presence of a .timestamp member (a per-flavour bucket's OWN
            # entries are further-nested objects, none of which is itself
            # named "timestamp" at this level).
            if ($null -ne $obj.lastRun.timestamp) {
                $Script:LastRunByFlavour = @{ retail = $obj.lastRun }
            } else {
                $map = @{}
                foreach ($p in $obj.lastRun.PSObject.Properties) { $map[$p.Name] = $p.Value }
                $Script:LastRunByFlavour = $map
            }
        }
        if ($null -ne $obj.wagoInertiaVersion) {
            $Script:WagoInertiaVersion = [string]$obj.wagoInertiaVersion
        }
        if ($null -ne $obj.jobs) {
            $loadedJobs = New-Object 'System.Collections.Generic.List[object]'
            $maxId = 0
            foreach ($jv in @($obj.jobs)) {
                $jobState = [string]$jv.state
                if ($jobState -ne 'done' -and $jobState -ne 'failed') {
                    $jobState = 'failed'
                }
                $log = New-Object 'System.Collections.Generic.List[object]'
                foreach ($l in @($jv.log)) { $log.Add([string]$l) }
                $results = New-Object 'System.Collections.Generic.List[object]'
                foreach ($r in @($jv.results)) { $results.Add($r) }

                $jobFlavour = 'retail'
                if ($jv.flavour) { $jobFlavour = [string]$jv.flavour }

                $job = [PSCustomObject]@{
                    id            = [string]$jv.id
                    kind          = $jv.kind
                    params        = $jv.params
                    state         = $jobState
                    startedAt     = $jv.startedAt
                    finishedAt    = $jv.finishedAt
                    exitCode      = $jv.exitCode
                    log           = $log
                    results       = $results
                    error         = $jv.error
                    flavour       = $jobFlavour
                    Process       = $null
                    OutFile       = $null
                    ErrFile       = $null
                    SyncLogOffset = 0
                    # E4: a reloaded job's saved state is never 'running'
                    # (the block above forces that), so Phases/PhaseIndex are
                    # never read for one - present here only so every Job
                    # object in $Script:Jobs carries the same property shape.
                    Phases        = $null
                    PhaseIndex    = 0
                    # GAME-MODE-SPEC.md section 2/4.1 (bug fix): a job
                    # persisted before this field existed has no
                    # gameRunningAtStart key in state.json - $jv.gameRunningAtStart
                    # reads as $null there, and [bool]$null is $false, the
                    # same "no signal, no reload note" behavior a brand-new
                    # job with the field would show if it legitimately
                    # started with WoW closed. Without this line,
                    # Get-JobStatusView's reloadNeeded silently reads a
                    # never-set NoteProperty on every reconstructed job,
                    # so EVERY job that survives a server restart reports
                    # reloadNeeded:false from then on, even one that
                    # genuinely updated an addon while WoW was running.
                    gameRunningAtStart = [bool]$jv.gameRunningAtStart
                }
                $loadedJobs.Add($job)

                $idNum = 0
                if ([int]::TryParse($job.id, [ref]$idNum) -and $idNum -gt $maxId) {
                    $maxId = $idNum
                }
            }
            $Script:Jobs = $loadedJobs
            while ($Script:Jobs.Count -gt 20) {
                $Script:Jobs.RemoveAt(0)
            }
            if ($maxId -gt $Script:JobIdSeq) {
                $Script:JobIdSeq = $maxId
            }
        }
        Write-ServerLog "Loaded state.json: flavours=$($Script:UpdatesCheckedAtByFlavour.Count) jobs=$($Script:Jobs.Count)"
    } catch {
        Write-ServerLog "Failed to read state.json, ignoring: $($_.Exception.Message)"
    }
}

function Get-UpdateAvailableKeyForRecord {
    <#
      E12: the key $Script:UpdateAvailable is keyed by for one addon record -
      the numeric CurseForge project id (unchanged from before E12) when
      present, else "wago:<slug>" for a Wago-sourced record (which has no
      numeric projectId at all). $null when neither is available (should not
      happen for a well-formed record, but never throws).
    #>
    param($Record)

    if ($null -ne $Record.projectId) {
        return [string]$Record.projectId
    }
    if ($Record.source -eq 'wago' -and $Record.slug) {
        return 'wago:' + $Record.slug
    }
    return $null
}

function Get-UpdateAvailableKeyForRow {
    <#
      E12: the same key, derived from a JOB RESULT ROW instead of a full
      record - a row carries `projectId` (unchanged) and, additively,
      `wagoSlug` (see SPEC's addon-sync.ps1 -Json contract) rather than the
      full record shape Get-UpdateAvailableKeyForRecord reads.
    #>
    param($Row)

    if ($Row.projectId) {
        return [string]$Row.projectId
    }
    if ($Row.wagoSlug) {
        return 'wago:' + $Row.wagoSlug
    }
    return $null
}

function Apply-JobCompletionSideEffects {
    <#
      Updates in-memory updateAvailable / lastRun bookkeeping from a
      finished job's parsed output. Does NOT persist state.json itself -
      Update-JobStatus (the sole caller) does that once, after this returns,
      so the save always picks up both this function's updateAvailable/
      lastRun changes AND the job's own final state/results in a single
      write, regardless of whether the job ultimately succeeded or failed.

      CS1 (UX-SPEC.md section 4.2): Update-JobStatus now calls this on BOTH
      of its outcomes, not just success - the failure branch immediately
      below is what runs on the failed call ($Job.state is already 'failed'
      and $Job.error already set by the caller before it calls in). It
      returns before touching updateAvailable/lastRun/UpdatesCheckedAt at
      all, so a failed job's effect here is scoped to exactly the two new
      freshness fields - mirrors how a successful 'check' job already sets
      $Script:UpdatesCheckedAt below, just for the failure side of that same
      "did the freshness picture just change" question. Every successful
      call clears both fields first (a later success after an earlier
      failure must un-stick the freshness headline from check_failed).

      Review fix (post-CS6): the failure branch only records
      LastCheckFailed/LastCheckError for the kinds that actually touch
      CurseForge/Wago (the same 'sync','check','add','install' list
      Get-ComputedFreshness's own 'checking' condition already uses)
      - a failed 'remove'/'rollback'/other job no longer flips the
      app-wide freshness headline to "Couldn't check - Retry", since that
      headline's own Retry action only re-runs a check and has nothing to
      do with an uninstall/rollback failure. Those failures still surface
      through their own job-panel/toast error, unaffected by this gate.

      FLAVORS-SPEC.md CS-F2 S5.3: every field this function touches is now
      keyed by $Job.flavour (defaulting to 'retail' for a pre-CS-F2 job
      object with no such field) instead of one global scalar/hashtable -
      so a Classic Era job's completion never updates Retail's own
      freshness bookkeeping, or vice versa.
    #>
    param($Job, $Parsed)

    $flavor = $Job.flavour
    if (-not $flavor) { $flavor = 'retail' }

    if ($Job.state -eq 'failed') {
        if (@('sync', 'check', 'add', 'install') -contains $Job.kind) {
            $Script:LastCheckFailedByFlavour[$flavor] = $true
            $errMsg = $Job.error
            if (-not $errMsg) { $errMsg = 'Unknown error' }
            $Script:LastCheckErrorByFlavour[$flavor] = $errMsg
        }
        return
    }

    # Round 37 (server perf pass): "invalidated on job completion" - a
    # failed job (handled above, already returned) never changed addons.json
    # or the AddOns folder, so Get-HandleStateCacheKey's own fingerprint
    # would have caught this anyway; this call is what actually matters for
    # a job whose OWN completion is what changed them (install/remove/sync/
    # check/add/rollback/import/switch-source all reach here).
    Clear-StateCache -Flavor $flavor

    $Script:LastCheckFailedByFlavour[$flavor] = $false
    $Script:LastCheckErrorByFlavour[$flavor] = $null

    $action = $null
    if ($Parsed -and $Parsed.action) {
        $action = [string]$Parsed.action
    }

    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $Job.results) { $rows.Add($r) }

    $updateAvailable = Get-FlavourUpdateAvailable -Flavor $flavor

    if ($action -eq 'check') {
        $Script:UpdatesCheckedAtByFlavour[$flavor] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $updateAvailable.Clear()
        foreach ($r in $rows) {
            if ($r.status -eq 'Would-update') {
                # E12: keyed by projectId when present, else "wago:<slug>" -
                # see Get-UpdateAvailableKeyForRow.
                $key = Get-UpdateAvailableKeyForRow -Row $r
                if ($key) {
                    $updateAvailable[$key] = @{ fileId = $r.fileId; version = $r.version }
                }
            }
        }
    } elseif ($action -eq 'sync' -or $action -eq 'add' -or $action -eq 'remove' -or $action -eq 'rollback' -or $action -eq 'import' -or $action -eq 'switch-source') {
        # E1: a completed rollback pins the addon to the restored file, same
        # as an explicit Pin - it has no update pending against that pin
        # until the next check, so any stale "update available" entry for
        # this project needs clearing the same way Updated/Installed/Pinned
        # already do. E4: an import's Updated/Installed/Pinned rows (from
        # its -Add / -Only+-FileId phases) need exactly the same clearing -
        # this branch already keys off $rows (built from the caller's own
        # $Job.results, not $Parsed.action-specific data), so 'import' only
        # needed adding to this condition, nothing else. E12: 'switch-source'
        # (uninstall-then-add-from-the-other-source) joins the same way, for
        # the same reason.
        foreach ($r in $rows) {
            if ($r.status -eq 'Updated' -or $r.status -eq 'Installed' -or $r.status -eq 'Pinned' -or $r.status -eq 'Rolled-back') {
                $key = Get-UpdateAvailableKeyForRow -Row $r
                if ($key -and $updateAvailable.ContainsKey($key)) {
                    $updateAvailable.Remove($key)
                }
            }
        }
    }

    if ($action -ne 'check' -and $action -ne 'files' -and $action -ne 'scan') {
        $counts = @{}
        foreach ($r in $rows) {
            $st = [string]$r.status
            if (-not $counts.ContainsKey($st)) { $counts[$st] = 0 }
            $counts[$st] = $counts[$st] + 1
        }
        $summaryParts = New-Object 'System.Collections.Generic.List[object]'
        foreach ($k in $counts.Keys) {
            $summaryParts.Add("$k`: $($counts[$k])")
        }
        $Script:LastRunByFlavour[$flavor] = [PSCustomObject]@{
            timestamp    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            summary      = ($summaryParts -join '  ')
            rows         = $rows.ToArray()
            # GAME-MODE-SPEC.md section 4.2: same predicate as
            # Get-JobStatusView's reloadNeeded, sourced from the job that
            # just completed - this is what lets the SPA's "Last run" line
            # keep the reload reminder after later unrelated jobs pushed
            # this job out of state.json's 20-entry history.
            reloadNeeded = [bool]($Job.gameRunningAtStart -and (
                $rows | Where-Object {
                    $_.Status -eq 'Installed' -or $_.Status -eq 'Updated' -or $_.Status -eq 'Rolled-back'
                } | Select-Object -First 1
            ))
        }
    }
}

function Complete-ImportPhase {
    <#
      Finalizes one phase of a multi-phase 'import' job once its CLI process
      has exited: merges that phase's results into the job's CUMULATIVE
      $Job.results (never replaced the way a single-phase job's one-shot
      $Job.results assignment does - each phase adds to what earlier phases
      already produced), then either starts the next phase (job stays
      'running') or finalizes the whole job (state done/failed) once every
      phase has run. A single failed phase fails the entire job outright -
      later phases are never attempted - the same all-or-nothing failure
      shape every other job kind already has.

      Called only from Update-JobStatus, once its own tailing/HasExited
      check confirms this job's current phase process has exited; keeping
      this entirely separate from that function's own finalize logic below
      means every other job kind's behavior there is completely untouched
      by import's existence.
    #>
    param($Job)

    $exitCode = $Job.Process.ExitCode

    # Read with ReadAllText, NOT Get-Content - see Update-JobStatus for why
    # (Get-Content's PSPath/PSDrive/PSProvider note properties can hang
    # ConvertTo-Json if the string ever ends up in a response).
    $stdout = ''
    try {
        if (Test-Path -LiteralPath $Job.OutFile) {
            $stdout = [System.IO.File]::ReadAllText($Job.OutFile, [System.Text.Encoding]::UTF8)
        }
    } catch { $stdout = '' }

    $stderr = ''
    try {
        if (Test-Path -LiteralPath $Job.ErrFile) {
            $stderr = [System.IO.File]::ReadAllText($Job.ErrFile, [System.Text.Encoding]::UTF8)
        }
    } catch { $stderr = '' }

    try {
        if (Test-Path -LiteralPath $Job.OutFile) { Remove-Item -LiteralPath $Job.OutFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $Job.ErrFile) { Remove-Item -LiteralPath $Job.ErrFile -Force -ErrorAction SilentlyContinue }
    } catch { }

    $parsed = $null
    $parseError = $null
    if ($stdout -and $stdout.Trim().Length -gt 0) {
        try {
            $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $parseError = $_.Exception.Message
        }
    }

    if ($exitCode -ne 0 -or -not $parsed) {
        $Job.exitCode = $exitCode
        $Job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $Job.state = 'failed'
        $errMsg = $stderr
        if (-not $errMsg -and $parseError) { $errMsg = "Could not parse CLI output as JSON: $parseError" }
        if (-not $errMsg) { $errMsg = "CLI exited with code $exitCode" }
        $Job.error = "Import phase $($Job.PhaseIndex + 1) of $($Job.Phases.Count) failed: $errMsg"
        Clear-CurrentJobIfMatches -Job $Job
        Save-CheckState
        return $Job
    }

    if ($parsed.results) {
        foreach ($r in @($parsed.results)) { $Job.results.Add($r) }
    }

    $hasMorePhases = ($Job.PhaseIndex + 1) -lt $Job.Phases.Count
    if ($hasMorePhases) {
        $started = Start-ImportPhase -Job $Job
        if (-not $started) {
            $Job.exitCode = $exitCode
            $Job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $Job.state = 'failed'
            $Job.error = "Failed to start import phase $($Job.PhaseIndex + 1) of $($Job.Phases.Count)"
            Clear-CurrentJobIfMatches -Job $Job
            Save-CheckState
        }
        return $Job
    }

    $Job.exitCode = 0
    $Job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $Job.state = 'done'
    Apply-JobCompletionSideEffects -Job $Job -Parsed ([PSCustomObject]@{ action = 'import' })

    Clear-CurrentJobIfMatches -Job $Job
    Save-CheckState
    return $Job
}

# =====================================================================
# switch-source (E12): "Reinstall from Wago/CurseForge" - uninstalls the
# tracked addon and adds it fresh from the OTHER source, as one job. Built
# as its own small two-phase job (mirroring Start-ImportJob/Start-ImportPhase/
# Complete-ImportPhase's shape exactly, but kept as a separate, dedicated set
# of functions rather than generalizing those - a switch is always exactly
# two phases, known up front, with no per-addon plan-building step import's
# Build-ImportPlan needs) rather than trying to fold two CLI invocations into
# Build-CliArgs's single-invocation-per-kind contract.
# =====================================================================

function Start-SwitchSourcePhase {
    <# Launches phase 0 (-Remove) or phase 1 (-Add) of a switch-source job. Mirrors Start-ImportPhase. #>
    param($Job)

    $Job.PhaseIndex = $Job.PhaseIndex + 1
    $cliArgs = $Job.Phases[$Job.PhaseIndex]

    if (-not (Test-Path -LiteralPath $Script:JobsDir)) {
        New-Item -ItemType Directory -Path $Script:JobsDir -Force | Out-Null
    }
    $outFile = Join-Path -Path $Script:JobsDir -ChildPath "$($Job.id)-$($Job.PhaseIndex).out"
    $errFile = Join-Path -Path $Script:JobsDir -ChildPath "$($Job.id)-$($Job.PhaseIndex).err"

    $psArgs = New-CliProcessArgs -CliArgs $cliArgs -Flavor $Job.flavour

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs.ToArray() -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $proc.Handle | Out-Null
    } catch {
        Write-ServerLog "Failed to start switch-source phase $($Job.PhaseIndex) for job $($Job.id): $($_.Exception.Message)"
        return $false
    }

    $Job.Process = $proc
    $Job.OutFile = $outFile
    $Job.ErrFile = $errFile
    return $true
}

function Start-SwitchSourceJob {
    <#
      Builds the two-phase plan (-Remove <current>, then -Add <target on the
      other source>) and starts phase 0. Params: {projectId (the addon's
      CURRENT key - a numeric CurseForge id, or the "wago:<slug>" string
      Store.addonKey already uses for a Wago row), toSource ('wago'|
      'curseforge'), toTarget (a numeric CurseForge project id, or a Wago
      slug/id string - NOT pre-prefixed with "wago:", this function adds
      that)}.
    #>
    param(
        [string]$JobId,
        [string]$StartedAt,
        $Params,
        [string]$Flavor
    )

    if (-not $Flavor) { $Flavor = $Script:CurrentFlavour }
    if (-not $Flavor) { $Flavor = 'retail' }

    $currentTarget = [string]$Params.projectId
    $toSource = ([string]$Params.toSource).ToLowerInvariant()
    $toTargetRaw = [string]$Params.toTarget
    $newTarget = if ($toSource -eq 'wago') { 'wago:' + $toTargetRaw } else { $toTargetRaw }

    $removeArgs = New-Object 'System.Collections.Generic.List[object]'
    $removeArgs.Add('-Remove')
    $removeArgs.Add($currentTarget)

    $addArgs = New-Object 'System.Collections.Generic.List[object]'
    $addArgs.Add('-Add')
    $addArgs.Add($newTarget)

    $phases = New-Object 'System.Collections.Generic.List[object]'
    $phases.Add($removeArgs)
    $phases.Add($addArgs)

    $job = [PSCustomObject]@{
        id            = $JobId
        kind          = 'switch-source'
        params        = $Params
        state         = 'running'
        startedAt     = $StartedAt
        finishedAt    = $null
        exitCode      = $null
        log           = New-Object 'System.Collections.Generic.List[object]'
        results       = New-Object 'System.Collections.Generic.List[object]'
        error         = $null
        flavour       = $Flavor
        Process       = $null
        OutFile       = $null
        ErrFile       = $null
        SyncLogOffset = 0
        Phases        = $phases
        PhaseIndex    = -1
        # GAME-MODE-SPEC.md section 4.1: captured once, at job-creation time.
        gameRunningAtStart = (Test-GameRunning)
    }

    if (Test-Path -LiteralPath $Script:SyncLogPath) {
        $job.SyncLogOffset = (Get-Item -LiteralPath $Script:SyncLogPath).Length
    }

    Add-JobToHistory -Job $job
    Set-CurrentJobForFlavour -Flavor $Flavor -Job $job

    $started = Start-SwitchSourcePhase -Job $job
    if (-not $started) {
        $job.state = 'failed'
        $job.error = 'Failed to start switch-source'
        $job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Set-CurrentJobForFlavour -Flavor $Flavor -Job $null
        Save-CheckState
    }
    return @{ Busy = $false; Job = $job }
}

function Complete-SwitchSourcePhase {
    <# Finalizes one phase's exited process; mirrors Complete-ImportPhase. #>
    param($Job)

    $exitCode = $Job.Process.ExitCode

    $stdout = ''
    try {
        if (Test-Path -LiteralPath $Job.OutFile) {
            $stdout = [System.IO.File]::ReadAllText($Job.OutFile, [System.Text.Encoding]::UTF8)
        }
    } catch { $stdout = '' }

    $stderr = ''
    try {
        if (Test-Path -LiteralPath $Job.ErrFile) {
            $stderr = [System.IO.File]::ReadAllText($Job.ErrFile, [System.Text.Encoding]::UTF8)
        }
    } catch { $stderr = '' }

    try {
        if (Test-Path -LiteralPath $Job.OutFile) { Remove-Item -LiteralPath $Job.OutFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $Job.ErrFile) { Remove-Item -LiteralPath $Job.ErrFile -Force -ErrorAction SilentlyContinue }
    } catch { }

    $parsed = $null
    $parseError = $null
    if ($stdout -and $stdout.Trim().Length -gt 0) {
        try {
            $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $parseError = $_.Exception.Message
        }
    }

    if ($exitCode -ne 0 -or -not $parsed) {
        $Job.exitCode = $exitCode
        $Job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $Job.state = 'failed'
        $errMsg = $stderr
        if (-not $errMsg -and $parseError) { $errMsg = "Could not parse CLI output as JSON: $parseError" }
        if (-not $errMsg) { $errMsg = "CLI exited with code $exitCode" }
        $phaseName = if ($Job.PhaseIndex -eq 0) { 'Remove' } else { 'Add' }
        $Job.error = "Switch-source phase $phaseName ($($Job.PhaseIndex + 1) of $($Job.Phases.Count)) failed: $errMsg"
        Clear-CurrentJobIfMatches -Job $Job
        Save-CheckState
        return $Job
    }

    if ($parsed.results) {
        foreach ($r in @($parsed.results)) { $Job.results.Add($r) }
    }

    $hasMorePhases = ($Job.PhaseIndex + 1) -lt $Job.Phases.Count
    if ($hasMorePhases) {
        $started = Start-SwitchSourcePhase -Job $Job
        if (-not $started) {
            $Job.exitCode = $exitCode
            $Job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $Job.state = 'failed'
            $Job.error = "Failed to start switch-source phase $($Job.PhaseIndex + 1) of $($Job.Phases.Count)"
            Clear-CurrentJobIfMatches -Job $Job
            Save-CheckState
        }
        return $Job
    }

    $Job.exitCode = 0
    $Job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $Job.state = 'done'
    Apply-JobCompletionSideEffects -Job $Job -Parsed ([PSCustomObject]@{ action = 'switch-source' })

    Clear-CurrentJobIfMatches -Job $Job
    Save-CheckState
    return $Job
}

function Wait-ProcessOutputDrained {
    <#
      Round 34 (live incident 2026-09-06 21:18, job 119): a "Check now" whose
      CLI exited 0 with a complete 34-addon result was marked FAILED with
      "CLI exited with code 0" and an empty results[]. Start-Process
      -RedirectStandardOutput does NOT hand the child a file handle: the
      PARENT pumps the child's stdout through an asynchronous
      OutputDataReceived handler into a buffered StreamWriter that is only
      flushed and closed on the child's Exited event - which fires AFTER
      Process.HasExited turns true. Every finalize path in this file read
      the .out file on the very poll that first saw HasExited, so a CLI
      that emits its one JSON document right before exiting could be read
      as empty (or truncated) and the job failed although the sync was
      fine. The no-timeout WaitForExit() overload is documented to block
      until that asynchronous output handling has completed; call it once
      the process is known to have exited, then confirm the file has
      content (a short bounded wait, so a child that legitimately printed
      nothing does not stall the poll). Regression test:
      tests\unit\Server.OutputDrain.Tests.ps1.
    #>
    param($Process, [string]$OutFile, [int]$MaxWaitMs = 1500)
    try { if ($null -ne $Process) { $Process.WaitForExit() } } catch { }
    if (-not $OutFile) { return }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($MaxWaitMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $len = 0
        try { if (Test-Path -LiteralPath $OutFile) { $len = (Get-Item -LiteralPath $OutFile).Length } } catch { $len = 0 }
        if ($len -gt 0) { return }
        Start-Sleep -Milliseconds 50
    }
}

function Update-JobStatus {
    <#
      Refreshes one job: while it is still running, tails sync.log since the
      job's last-consumed offset; once the backing process has exited,
      finalizes state/results/error from its output files. Safe to call
      repeatedly.

      Round 3 fix: tailing now only happens while $Job.state is 'running'.
      It used to run unconditionally on every call, including polls of an
      already-finished job (e.g. GET /api/jobs/{id} against an old job id
      after a later job has since run) - since sync.log is shared across
      every CLI invocation, that kept pulling in whatever a NEWER job had
      since appended and attaching it to this OLDER, already-done job's
      log. The state check now sits first, before any tailing happens, so a
      finished job's log is frozen at whatever it held the moment its
      process was found to have exited: the tail below still runs one more
      time on the very poll that discovers HasExited (state is still
      'running' at that point), capturing the CLI's last lines, and then
      state flips to done/failed afterward - every poll after that returns
      immediately here without touching sync.log at all.
    #>
    param($Job)

    if (-not $Job) {
        return $Job
    }

    if ($Job.state -ne 'running' -or -not $Job.Process) {
        return $Job
    }

    try {
        if (Test-Path -LiteralPath $Script:SyncLogPath) {
            $fs = New-Object System.IO.FileStream($Script:SyncLogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                if ($fs.Length -gt $Job.SyncLogOffset) {
                    $fs.Seek($Job.SyncLogOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
                    # Captured before the reader is closed below: closing the
                    # StreamReader also closes $fs (it owns the stream by
                    # default), so $fs.Length is no longer readable afterward.
                    $newLength = $fs.Length
                    $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                    try {
                        $newText = $reader.ReadToEnd()
                    } finally {
                        $reader.Close()
                    }
                    if ($newText) {
                        $lines = $newText -split "`r`n|`n"
                        foreach ($l in $lines) {
                            if ($l.Length -gt 0) { $Job.log.Add($l) }
                        }
                    }
                    # Advance the offset past what was just consumed so a repeated
                    # poll while still running does not re-read and re-append the
                    # same lines every time.
                    $Job.SyncLogOffset = $newLength
                }
            } finally {
                # Already closed via $reader.Close() above when that path ran;
                # closing an already-closed FileStream is a documented no-op,
                # and this still covers the case where $reader was never
                # created (fs.Length was <= SyncLogOffset).
                $fs.Close()
            }
        }
    } catch {
        # tolerate transient read failures while the CLI is still writing
    }

    # CS1: best-effort read of the CLI's progress.json (UX-SPEC.md section
    # 4.2) - same shape/reasoning as the sync.log tail just above: the CLI
    # may be mid-write (Write-ProgressStep's own Move-Item -Force makes each
    # individual write atomic, but nothing stops this read from landing
    # between two writes), so a parse failure here is tolerated exactly like
    # a transient log-read failure is, never surfaced to the caller. Only
    # ever set for a job kind Start-Job actually threaded -ProgressPath for;
    # $Job.ProgressPath is $null (falsy) for every other kind, same guard
    # shape Write-ProgressStep itself uses CLI-side.
    if ($Job.ProgressPath) {
        try {
            if (Test-Path -LiteralPath $Job.ProgressPath) {
                $progressText = [System.IO.File]::ReadAllText($Job.ProgressPath, [System.Text.Encoding]::UTF8)
                if ($progressText -and $progressText.Trim().Length -gt 0) {
                    $progressObj = $progressText | ConvertFrom-Json -ErrorAction Stop
                    Add-Member -InputObject $Job -MemberType NoteProperty -Name 'progress' -Value $progressObj -Force
                }
            }
        } catch {
            # tolerate transient read/parse failures while the CLI is mid-write
        }
    }

    if (-not $Job.Process.HasExited) {
        return $Job
    }

    # Round 34: HasExited is true, but the redirected stdout may still be in
    # flight inside this process's async writer - drain it before ANY of the
    # finalize paths below (single-phase, import, switch-source) read .out.
    Wait-ProcessOutputDrained -Process $Job.Process -OutFile $Job.OutFile

    # E4: an 'import' job's process is one PHASE of a possibly-multi-step
    # sequence (see Build-ImportPlan/Complete-ImportPhase) rather than the
    # whole job, so its own finalize/advance logic is entirely separate from
    # the single-phase logic below, which every other job kind still uses
    # completely unchanged.
    if ($Job.kind -eq 'import') {
        return (Complete-ImportPhase -Job $Job)
    }
    # E12: switch-source is likewise a multi-phase job (see Start-SwitchSourceJob).
    if ($Job.kind -eq 'switch-source') {
        return (Complete-SwitchSourcePhase -Job $Job)
    }

    $exitCode = $Job.Process.ExitCode
    $Job.exitCode = $exitCode
    $Job.finishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    # Read with ReadAllText, NOT Get-Content: Get-Content decorates the returned
    # string with PSPath/PSDrive/PSProvider note properties, and ConvertTo-Json
    # then walks the whole provider object graph (effectively hanging the server)
    # when that string ends up in a response.
    $stdout = ''
    try {
        if (Test-Path -LiteralPath $Job.OutFile) {
            $stdout = [System.IO.File]::ReadAllText($Job.OutFile, [System.Text.Encoding]::UTF8)
        }
    } catch { $stdout = '' }

    $stderr = ''
    try {
        if (Test-Path -LiteralPath $Job.ErrFile) {
            $stderr = [System.IO.File]::ReadAllText($Job.ErrFile, [System.Text.Encoding]::UTF8)
        }
    } catch { $stderr = '' }

    $parsed = $null
    $parseError = $null
    if ($stdout -and $stdout.Trim().Length -gt 0) {
        try {
            $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $parseError = $_.Exception.Message
        }
    }

    if ($exitCode -eq 0 -and $parsed) {
        $Job.results = New-Object 'System.Collections.Generic.List[object]'
        if ($parsed.results) {
            foreach ($r in @($parsed.results)) { $Job.results.Add($r) }
        }
        $Job.state = 'done'

        Apply-JobCompletionSideEffects -Job $Job -Parsed $parsed
    } else {
        $Job.state = 'failed'
        $errMsg = $stderr
        if (-not $errMsg -and $parseError) { $errMsg = "Could not parse CLI output as JSON: $parseError" }
        if (-not $errMsg) { $errMsg = "CLI exited with code $exitCode" }
        $Job.error = $errMsg

        # Round 34: keep the raw output of a failed job for diagnosis (the
        # normal cleanup below deletes .out/.err). Small, and only on failure.
        try {
            if (Test-Path -LiteralPath $Job.OutFile) { Copy-Item -LiteralPath $Job.OutFile -Destination ($Job.OutFile + '.failed') -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $Job.ErrFile) { Copy-Item -LiteralPath $Job.ErrFile -Destination ($Job.ErrFile + '.failed') -Force -ErrorAction SilentlyContinue }
        } catch { }

        # CS1 (UX-SPEC.md section 4.2): mirrors the success branch's own
        # Apply-JobCompletionSideEffects call just above - $Job.state/.error
        # are already set to their final failed values on the lines just
        # above, so the function's failure branch (see its own doc comment)
        # has everything it needs.
        Apply-JobCompletionSideEffects -Job $Job -Parsed $parsed
    }

    try {
        if (Test-Path -LiteralPath $Job.OutFile) { Remove-Item -LiteralPath $Job.OutFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $Job.ErrFile) { Remove-Item -LiteralPath $Job.ErrFile -Force -ErrorAction SilentlyContinue }
    } catch { }

    Clear-CurrentJobIfMatches -Job $Job

    # Round 3: persist lastRun + job history to state.json now that this
    # job's final state/results/error are all set (Apply-JobCompletionSideEffects,
    # above, already updated $Script:LastRun/UpdateAvailable/UpdatesCheckedAt
    # for a successful job, or $Script:LastCheckFailed/LastCheckError for a
    # failed one - see its own updated doc comment). Called once here for
    # BOTH the done and failed outcomes; CS1 changed
    # Apply-JobCompletionSideEffects itself to also run on both outcomes
    # (previously success-only), but this call still needs to stay right
    # here regardless, since it's this Save-CheckState that actually writes
    # either branch's bookkeeping to state.json - without it, a failed job
    # would still vanish from the persisted history on the next restart.
    Save-CheckState

    return $Job
}

function Get-JobStatusView {
    param($Job)

    if (-not $Job) {
        return $null
    }
    return [PSCustomObject]@{
        id         = $Job.id
        kind       = $Job.kind
        params     = $Job.params
        state      = $Job.state
        startedAt  = $Job.startedAt
        finishedAt = $Job.finishedAt
        exitCode   = $Job.exitCode
        log        = $Job.log.ToArray()
        results    = $Job.results.ToArray()
        error      = $Job.error
        # FLAVORS-SPEC.md CS-F2 S5.4: reading a NoteProperty that was never
        # added (a job created before this change set - see Load-CheckState's
        # own back-compat default) is always safe in PowerShell and returns
        # $null; the job-panel/switcher UI (CS-F4) treats a $null flavour the
        # same as 'retail'.
        flavour    = $Job.flavour
        # CS1 (UX-SPEC.md section 4.2): whatever Update-JobStatus's
        # best-effort progress.json read last parsed, or $null - reading a
        # NoteProperty that was never added (a job kind with no
        # -ProgressPath, or one never polled while running) is always safe
        # in PowerShell, unlike writing one.
        progress   = $Job.progress
        # FLAVORS-SPEC.md CS-F3 S5.5 case 5: {id,label} pairs for a job in
        # state 'awaiting_flavour' - $null (safe NoteProperty read) for
        # every other job, exactly like .progress above.
        choices    = $Job.choices
        # GAME-MODE-SPEC.md section 4.1: whether WoW was already running
        # when this job started, captured once at job-creation time (Start-
        # Job/Start-ImportJob/Start-SwitchSourceJob). Exposed here (not just
        # folded into reloadNeeded below) because Save-CheckState persists
        # jobs by serializing THIS object - without this field round-
        # tripping through state.json, Load-CheckState's own
        # gameRunningAtStart reconstruction (the section 2/8 bug fix) would
        # always read $null back after a server restart, silently
        # defeating reloadNeeded for every job that survives one.
        gameRunningAtStart = [bool]$Job.gameRunningAtStart
        # GAME-MODE-SPEC.md section 4.1: true only when WoW was already
        # running when this job STARTED (gameRunningAtStart) AND at least
        # one result row actually wrote to disk (Installed/Updated/
        # Rolled-back - deliberately narrower than the four-value
        # updateAvailable-cleanup set used elsewhere in this file; Pinned/
        # Unpinned/Ignored/Unignored never touch the AddOns folder, and
        # Removed is excluded per Eric's literal "updated or installed"
        # wording, see GAME-MODE-SPEC.md section 7.5). A check-only job's
        # rows are always Would-update/Up-to-date/Failed/Skipped, so this
        # naturally evaluates false without a per-kind allowlist. Drives the
        # SPA toast/note and, via Apply-JobCompletionSideEffects, the
        # persisted lastRun.reloadNeeded slot too.
        reloadNeeded = [bool]($Job.gameRunningAtStart -and (
            $Job.results | Where-Object {
                $_.Status -eq 'Installed' -or $_.Status -eq 'Updated' -or $_.Status -eq 'Rolled-back'
            } | Select-Object -First 1
        ))
    }
}

function Get-CurrentOrLastJobSummary {
    <#
      FLAVORS-SPEC.md CS-F2 S5.4: -Flavor (default $Script:CurrentFlavour)
      scopes both halves of "current OR last job" to that one flavour - the
      in-flight slot (Get-CurrentJobForFlavour) and, when nothing is
      currently running for it, the most recent HISTORY entry that ALSO
      belongs to that flavour (never an unrelated flavour's more-recent
      job) - this is what makes /api/state's per-flavour `job`/freshness
      correct on a multi-flavour machine.
    #>
    param([string]$Flavor)

    if (-not $Flavor) { $Flavor = $Script:CurrentFlavour }
    if (-not $Flavor) { $Flavor = 'retail' }

    $current = Get-CurrentJobForFlavour -Flavor $Flavor
    if ($current) {
        return Get-JobStatusView -Job (Update-JobStatus -Job $current)
    }
    for ($i = $Script:Jobs.Count - 1; $i -ge 0; $i--) {
        $j = $Script:Jobs[$i]
        # FLAVORS-SPEC.md CS-F3: an 'awaiting_flavour' job is, by
        # construction, NOT resolved to any one flavour yet (its own
        # .flavour is $null for exactly that reason) - skipped here rather
        # than falling into the "no .flavour -> defaults to retail"
        # back-compat rule just below, which exists for a pre-CS-F2 job
        # loaded with no .flavour field at all and would otherwise
        # incorrectly attribute this still-ambiguous job to Retail's own
        # "last job" summary.
        if ($j.state -eq 'awaiting_flavour') { continue }
        $jFlavour = $j.flavour
        if (-not $jFlavour) { $jFlavour = 'retail' }
        if ($jFlavour -eq $Flavor) {
            return Get-JobStatusView -Job $j
        }
    }
    return $null
}

function Get-PendingFlavourChoiceJob {
    <#
      Security-review fix: a job in state 'awaiting_flavour' is, by design,
      never attributed to (or surfaced through) any one flavour's own
      /api/state.job field - Get-CurrentOrLastJobSummary explicitly skips
      it (see its own comment) because it does not belong to any flavour
      yet. That left a real gap: curseforge-handler.vbs (invoked by the
      OS-registered curseforge:// protocol handler from the user's regular
      browser, entirely separate from this SPA) POSTs /api/jobs and only
      ever inspects the HTTP status code - never the response body's jobId
      - so when the target addon matches more than one installed flavour
      and the server creates an 'awaiting_flavour' job, NOTHING in this
      codebase ever surfaced it: no picker, no toast, no error, the job
      just sat unresolved forever while the user stared at a Furphy window
      that appeared to do nothing.

      This surfaces that same job machine-wide (regardless of the
      request's own ?flavour=/active flavour) so the SPA's existing
      /api/state polling (ui/app.js reloadState) can discover it and
      render the already-built awaiting_flavour picker (Components.
      JobPanel) no matter which flavour happens to be active. Deliberately
      conservative about WHEN it reports one: only while that job is still
      the very last entry in $Script:Jobs. Resuming it (Actions.
      resumeJobWithFlavour re-POSTs the identical body with an explicit
      ?flavour=, which always creates a BRAND NEW job per Start-Job's own
      comment - there is no "resume this exact job" endpoint) appends a
      newer job right after it, so this stops reporting the old one
      automatically the moment it's acted on (or superseded by any other
      job) - it can never resurface a resolved/abandoned ask indefinitely.
    #>
    if (-not $Script:Jobs -or $Script:Jobs.Count -eq 0) { return $null }
    $last = $Script:Jobs[$Script:Jobs.Count - 1]
    if ($last.state -eq 'awaiting_flavour') {
        return Get-JobStatusView -Job $last
    }
    return $null
}

function Get-ComputedFreshness {
    <#
      CS1 (UX-SPEC.md sections 2.1/4.2): the one freshness enum, computed
      server-side so the client "never derives freshness from other
      fields" per that spec's own rule. One new value each call - never
      cached - from the existing check state plus whichever job is current:
        checking          - a sync/check/add/install job (the kinds that
                             actually touch CurseForge/Wago) is running now.
        check_failed       - the most recent such job ended in $Job.state
                             'failed' (Apply-JobCompletionSideEffects' new
                             failure branch is what sets this).
        not_checked        - nothing has ever completed a check/sync.
        updates_available  - $Script:UpdateAvailable has at least one entry.
        up_to_date          - none of the above.
      -CurrentJobView is the same Get-JobStatusView-shaped object
      Handle-State already computes for its own "job" field - passed in
      rather than recomputed here so a single /api/state call never polls
      the running job's Update-JobStatus twice.

      FLAVORS-SPEC.md CS-F2 S5.3: gains -Flavor (default
      $Script:CurrentFlavour) - every field below is read from that ONE
      flavour's own bucket, so a Retail sync running concurrently with a
      Classic Era job never makes Classic Era's own freshness read
      "checking" (or vice versa).
    #>
    param($CurrentJobView, [string]$Flavor)

    if (-not $Flavor) { $Flavor = $Script:CurrentFlavour }
    if (-not $Flavor) { $Flavor = 'retail' }

    if ($CurrentJobView -and $CurrentJobView.state -eq 'running' -and (@('sync', 'check', 'add', 'install') -contains $CurrentJobView.kind)) {
        return 'checking'
    }
    if (Get-FlavourLastCheckFailed -Flavor $Flavor) {
        return 'check_failed'
    }
    if (-not (Get-FlavourUpdatesCheckedAt -Flavor $Flavor)) {
        return 'not_checked'
    }
    $upd = Get-FlavourUpdateAvailable -Flavor $Flavor
    if ($upd -and $upd.Count -gt 0) {
        return 'updates_available'
    }
    return 'up_to_date'
}

# =====================================================================
# Invoke-Cli: synchronous CLI call, used by the fast/inline operations
# =====================================================================

function Invoke-Cli {
    <# Runs addon-sync.ps1 with the given args, waits (up to TimeoutSec), and returns the parsed -Json output. Throws on failure. #>
    param(
        [string[]]$CliArgs,
        [int]$TimeoutSec = 60
    )

    if (-not (Test-Path -LiteralPath $Script:JobsDir)) {
        New-Item -ItemType Directory -Path $Script:JobsDir -Force | Out-Null
    }

    $token = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path -Path $Script:JobsDir -ChildPath "sync-$token.out"
    $errFile = Join-Path -Path $Script:JobsDir -ChildPath "sync-$token.err"

    $argsList = New-Object 'System.Collections.Generic.List[object]'
    foreach ($a in $CliArgs) { $argsList.Add($a) }
    $psArgs = New-CliProcessArgs -CliArgs $argsList

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs.ToArray() -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # See Start-Job: force the SafeProcessHandle to materialize now so that
        # reading .ExitCode below is reliable.
        $proc.Handle | Out-Null
        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            throw "CLI call timed out after $TimeoutSec seconds"
        }
        # Round 34: the timed WaitForExit returns before the redirected output is flushed.
        Wait-ProcessOutputDrained -Process $proc -OutFile $outFile

        $exitCode = $proc.ExitCode
        # ReadAllText, not Get-Content (see Update-JobStatus): the text may end up in a JSON error response.
        $stdout = ''
        if (Test-Path -LiteralPath $outFile) {
            try { $stdout = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8) } catch { $stdout = '' }
        }
        $stderr = ''
        if (Test-Path -LiteralPath $errFile) {
            try { $stderr = [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8) } catch { $stderr = '' }
        }

        if ($exitCode -ne 0) {
            $msg = $stderr
            if (-not $msg) { $msg = "CLI exited with code $exitCode" }
            throw $msg
        }
        if (-not $stdout -or $stdout.Trim().Length -eq 0) {
            throw 'CLI produced no output'
        }

        try {
            return ($stdout | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            throw "Could not parse CLI output as JSON: $($_.Exception.Message)"
        }
    } finally {
        try { if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue } } catch { }
        try { if (Test-Path -LiteralPath $errFile) { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue } } catch { }
    }
}

# =====================================================================
# Invoke-ProtocolScript: synchronous register-protocol.ps1 call (E19)
# =====================================================================

function Invoke-ProtocolScript {
    <#
      Runs E17's existing, unchanged register-protocol.ps1 (the curseforge://
      handler registration script - see SPEC "register-protocol.ps1") with
      -Json and one of -Status/-Register/-Unregister, waits (up to
      TimeoutSec), and returns the parsed JSON status object. Same
      hidden-child-process / redirected-output / parsed-JSON / quoted-path
      shape as Invoke-Cli above (the space-containing ROOT path is quoted the
      same way); throws on failure or timeout - callers
      (Handle-ProtocolStatus/Register/Unregister) catch and turn that into a
      500, matching every other route handler's contract.
    #>
    param(
        [string]$Switch,
        [int]$TimeoutSec = 30
    )

    if (-not (Test-Path -LiteralPath $Script:JobsDir)) {
        New-Item -ItemType Directory -Path $Script:JobsDir -Force | Out-Null
    }

    $token = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path -Path $Script:JobsDir -ChildPath "protocol-$token.out"
    $errFile = Join-Path -Path $Script:JobsDir -ChildPath "protocol-$token.err"

    $psArgs = New-Object 'System.Collections.Generic.List[object]'
    $psArgs.Add('-NoProfile')
    $psArgs.Add('-ExecutionPolicy')
    $psArgs.Add('Bypass')
    # Start-Process joins -ArgumentList elements with spaces and does NOT
    # quote them, so paths with spaces (C:\Program Files (x86)\... /
    # $Script:Root itself) must be quoted here - same reasoning as
    # New-CliProcessArgs above.
    $psArgs.Add('-File')
    $psArgs.Add('"' + $Script:RegisterProtocolPath + '"')
    $psArgs.Add('-' + $Switch)
    $psArgs.Add('-Json')

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs.ToArray() -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # See Invoke-Cli/Start-Job: force the SafeProcessHandle to
        # materialize now so that reading .ExitCode later is reliable.
        $proc.Handle | Out-Null
        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            throw "register-protocol.ps1 -$Switch timed out after $TimeoutSec seconds"
        }
        # Round 34: the timed WaitForExit returns before the redirected output is flushed.
        Wait-ProcessOutputDrained -Process $proc -OutFile $outFile

        $exitCode = $proc.ExitCode
        $stdout = ''
        if (Test-Path -LiteralPath $outFile) {
            try { $stdout = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8) } catch { $stdout = '' }
        }
        $stderr = ''
        if (Test-Path -LiteralPath $errFile) {
            try { $stderr = [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8) } catch { $stderr = '' }
        }

        if ($exitCode -ne 0) {
            $msg = $stderr
            if (-not $msg) { $msg = "register-protocol.ps1 -$Switch exited with code $exitCode" }
            throw $msg
        }
        if (-not $stdout -or $stdout.Trim().Length -eq 0) {
            throw 'register-protocol.ps1 produced no output'
        }

        try {
            return ($stdout | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            throw "Could not parse register-protocol.ps1 output as JSON: $($_.Exception.Message)"
        }
    } finally {
        try { if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue } } catch { }
        try { if (Test-Path -LiteralPath $errFile) { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue } } catch { }
    }
}

# =====================================================================
# Wago Addons proxy (E12) - keyless. Mirrors addon-sync.ps1's own Wago
# functions closely (same Inertia handshake/pacing/retry shape), duplicated
# here rather than dot-sourced - this script is always launched standalone
# and never dot-sources the CLI, the same pattern already used for
# Resolve-EffectiveAddonsPath/Get-PresentAddonFolders elsewhere in this file.
# Verified facts live in SPEC.md's "Wago Addons access facts" section.
# =====================================================================

function Get-WagoExceptionStatusCode {
    param($ErrorRecord)
    $code = 0
    try {
        if ($ErrorRecord -and $ErrorRecord.Exception -and $ErrorRecord.Exception.Response) {
            $code = [int]$ErrorRecord.Exception.Response.StatusCode
        }
    } catch {
        $code = 0
    }
    return $code
}

function Invoke-WagoHttpRequest {
    <# Server-side counterpart to addon-sync.ps1's Invoke-WagoRequest - same 300ms pacing, same 429/503 retry-once-after-5s. #>
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers
    )

    $mergedHeaders = @{ 'Accept' = 'text/html, application/xhtml+xml' }
    if ($Headers) {
        foreach ($k in $Headers.Keys) { $mergedHeaders[$k] = $Headers[$k] }
    }
    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'

    $maxAttempts = 2
    $attempt = 0
    $lastError = $null
    $result = $null

    while ($attempt -lt $maxAttempts) {
        $attempt++
        $shouldRetry = $false
        $lastError = $null
        try {
            $result = Invoke-WebRequest -Uri $Uri -Headers $mergedHeaders -UserAgent $userAgent -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        } catch {
            $lastError = $_
            $statusCode = Get-WagoExceptionStatusCode -ErrorRecord $_
            if (($statusCode -eq 429 -or $statusCode -eq 503) -and ($attempt -lt $maxAttempts)) {
                Write-ServerLog "HTTP $statusCode from $Uri (Wago) - waiting 5 seconds and retrying"
                $shouldRetry = $true
            }
        }
        Start-Sleep -Milliseconds 300
        if (-not $lastError) { return $result }
        if (-not $shouldRetry) { throw $lastError }
        Start-Sleep -Seconds 5
    }
    if ($lastError) { throw $lastError }
    return $result
}

function Get-WagoInertiaHandshake {
    <# Plain-HTML handshake: reads #app's data-page JSON, returns {version; props}. #>
    param([Parameter(Mandatory = $true)][string]$PageUri)

    $response = Invoke-WagoHttpRequest -Uri $PageUri -Headers @{ 'Accept' = 'text/html, application/xhtml+xml' }
    if (-not $response -or -not $response.Content) {
        throw "Empty response reading Wago page $PageUri"
    }
    if ($response.Content -notmatch 'id="app"[^>]*data-page="([^"]*)"') {
        throw "Could not find #app data-page attribute on Wago page $PageUri"
    }
    $decoded = [System.Net.WebUtility]::HtmlDecode($Matches[1])
    $page = $decoded | ConvertFrom-Json -ErrorAction Stop
    if (-not $page.version) {
        throw "Wago page data-page JSON had no version field ($PageUri)"
    }
    return [PSCustomObject]@{ version = $page.version; props = $page.props }
}

function Invoke-WagoInertiaJson {
    <#
      Fetches one Wago page's props via the X-Inertia XHR protocol.
      $Script:WagoInertiaVersion caches the working version for the life of
      this server process (persisted to/reloaded from state.json - see
      Save-CheckState/Load-CheckState) so only the FIRST Wago request this
      process ever makes pays the plain-HTML handshake; a 409 (version
      changed server-side) refreshes it and retries once, per SPEC.
    #>
    param([Parameter(Mandatory = $true)][string]$PageUri)

    if (-not $Script:WagoInertiaVersion) {
        $handshake = Get-WagoInertiaHandshake -PageUri $PageUri
        $Script:WagoInertiaVersion = $handshake.version
        return $handshake.props
    }

    $headers = @{
        'X-Inertia'         = 'true'
        'X-Inertia-Version' = $Script:WagoInertiaVersion
        'X-Requested-With'  = 'XMLHttpRequest'
        'Accept'            = 'text/html, application/xhtml+xml'
    }

    try {
        $response = Invoke-WagoHttpRequest -Uri $PageUri -Headers $headers
    } catch {
        $statusCode = Get-WagoExceptionStatusCode -ErrorRecord $_
        if ($statusCode -eq 409) {
            Write-ServerLog "Wago Inertia version stale, refreshing ($PageUri)"
            $handshake = Get-WagoInertiaHandshake -PageUri $PageUri
            $Script:WagoInertiaVersion = $handshake.version
            $headers['X-Inertia-Version'] = $Script:WagoInertiaVersion
            $response = Invoke-WagoHttpRequest -Uri $PageUri -Headers $headers
        } else {
            throw
        }
    }

    if (-not $response -or -not $response.Content) {
        throw "Empty response from Wago Inertia request $PageUri"
    }
    $json = $response.Content | ConvertFrom-Json -ErrorAction Stop
    return $json.props
}

function Get-WagoCached {
    <#
      5-minute in-memory cache around Invoke-WagoInertiaJson, keyed by the
      full page URI - its own separate hashtable/cleanup logic, distinct
      from the other on-disk/in-memory caches this server keeps (e.g.
      $Script:CfCatalogueIndex), so a bug in one can't reach another's.

      -AllowLiveFetch (switch, defaults to $true): every call site
      (Handle-WagoBrowse, Handle-WagoCategories, Handle-WagoAddonDetails,
      Handle-WagoAddonReleases, Handle-WagoAddonGallery, Get-WagoAutoMatch,
      Get-CfEnrichmentNoKey) omits it and always allows a live fetch on a
      cold miss now - GAME-MODE-SPEC.md (2026-09-08) removed the one call
      site (Handle-WagoBrowse) that used to pass -AllowLiveFetch:$false
      while WoW was running. The switch itself stays as general-purpose
      plumbing (a fresh, <5-minute cache entry is still served either way
      regardless of live-fetch permission) in case a future caller needs
      it, but nothing in this file passes $false any more.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PageUri,
        [switch]$AllowLiveFetch = $true
    )

    if ($Script:WagoCache.ContainsKey($PageUri)) {
        $entry = $Script:WagoCache[$PageUri]
        $age = (Get-Date) - $entry.Time
        if ($age.TotalSeconds -lt 300) {
            return $entry.Props
        }
        $Script:WagoCache.Remove($PageUri)
    }

    if (-not $AllowLiveFetch) {
        return $null
    }

    $props = Invoke-WagoInertiaJson -PageUri $PageUri

    if ($Script:WagoCache.Count -ge 200) {
        $now = Get-Date
        $staleKeys = New-Object 'System.Collections.Generic.List[object]'
        foreach ($k in $Script:WagoCache.Keys) {
            $age = $now - $Script:WagoCache[$k].Time
            if ($age.TotalSeconds -ge 300) { $staleKeys.Add($k) }
        }
        foreach ($k in $staleKeys) { $Script:WagoCache.Remove($k) }
        if ($Script:WagoCache.Count -ge 200) { $Script:WagoCache.Clear() }
    }
    $Script:WagoCache[$PageUri] = @{ Time = (Get-Date); Props = $props }
    return $props
}

function ConvertFrom-WagoSearchCardHtml {
    <#
      SPEC's verified Wago facts document /?search=... as returning
      props.addons.data[] items that are server-rendered HTML CARD SNIPPETS,
      not plain objects - parsed here with regexes for the addon URL (slug),
      the <h3> title, and a cdn.wago.io thumbnail <img src>, per SPEC's own
      description of what to look for. Never throws: a card whose markup
      doesn't match a given piece just leaves that field $null.

      Fix pass: the thumbnail regex used to require a quoted src="..."
      attribute, but Wago's actual server-rendered card markup emits it
      UNQUOTED on its own line (e.g. "src=https://cdn.wago.io/thumbnails/
      xyz.png") - verified live, every card's thumbnail came back $null.
      Quotes are now optional around the URL, matched non-greedily against
      whitespace/">"/a matching quote so it still stops at the right place
      whichever style a given card uses.

      Round 32 (WAGO-BROWSE-SPEC.md, Expansion E29) widening: four more
      optional, never-throw regex extractions against the SAME card
      fragment - summary (the card's first <p>, the truncated description),
      author, updatedAt (kept as Wago's own raw human date string, e.g.
      "Aug 18, 2026" - deliberately never re-parsed/reformatted here; the
      UI's existing Date-based helpers already handle it, and
      Sort-WagoItemsByUpdated below parses it independently for its own
      page-local re-sort), and downloads (non-digit characters stripped
      before [int]::Parse - defensive against a future thousands-separator,
      though none observed live as of this round). Each of these four is
      independent of the other three original fields and of each other - a
      miss on any one leaves that field $null, same never-throw style as
      slug/name/thumbnail. Confirmed present on every probed game_version/
      category/search combination in WAGO-BROWSE-RESEARCH.md's live
      captures - zero new upstream request needed for any of this.
    #>
    param([string]$Html)

    if (-not $Html) { return $null }
    $slug = $null
    $name = $null
    $thumb = $null
    $author = $null
    $summary = $null
    $updatedAt = $null
    $downloads = $null
    if ($Html -match 'href="https://addons\.wago\.io/addons/([a-z0-9-]+)"') { $slug = $Matches[1] }
    if ($Html -match '<h3[^>]*>([^<]*)</h3>') { $name = [System.Net.WebUtility]::HtmlDecode($Matches[1]).Trim() }
    if ($Html -match 'src=["'']?(https://cdn\.wago\.io/thumbnails/[^"''\s>]+)') { $thumb = $Matches[1] }
    if ($Html -match '<p[^>]*>([^<]*)</p>') { $summary = [System.Net.WebUtility]::HtmlDecode($Matches[1]).Trim() }
    if ($Html -match '<strong>Author:</strong>\s*([^<]*)</span>') { $author = [System.Net.WebUtility]::HtmlDecode($Matches[1]).Trim() }
    if ($Html -match '<strong>Updated:</strong>\s*([^<]*)</span>') { $updatedAt = [System.Net.WebUtility]::HtmlDecode($Matches[1]).Trim() }
    if ($Html -match '<strong>Downloads:</strong>\s*([^<]*)</span>') {
        $digitsOnly = ($Matches[1] -replace '[^0-9]', '')
        if ($digitsOnly) {
            try { $downloads = [int]::Parse($digitsOnly) } catch { $downloads = $null }
        }
    }
    if (-not $slug) { return $null }
    return [PSCustomObject]@{
        slug      = $slug
        name      = $name
        thumbnail = $thumb
        author    = $author
        summary   = $summary
        downloads = $downloads
        updatedAt = $updatedAt
    }
}

function Sort-WagoItemsByUpdated {
    <#
      WAGO-BROWSE-SPEC.md section 3.4: the "Recently updated" sort tab is a
      PAGE-LOCAL re-sort of whichever page Wago's own implicit popularity
      order already returned - NOT a true global recency sort across every
      matching addon (Wago's own sort=updated returns no usable data at
      all, see ConvertFrom-WagoSearchCardHtml's neighbourhood /
      WAGO-BROWSE-RESEARCH.md section 2 - so this fetches the byte-identical
      "popular" URL and only re-orders the up-to-15 items that single page
      already contains). The UI's tooltip copy is written to be true under
      this limitation, not to oversell it - see the spec's section 1/2.3.

      Each item's own updatedAt (Wago's raw "MMM d, yyyy" string, e.g. "Aug
      18, 2026") is parsed via [DateTime]::ParseExact in a try/catch - a
      missing/malformed date is never dropped or thrown on, it just sorts
      LAST ([DateTime]::MinValue). Explicit three-key sort - parsed date
      descending, then downloads descending, then slug ascending - so the
      result never depends on incidental input-array-order stability.

      Returns a plain array (NOT via Write-Output -NoEnumerate) - every
      call site below wraps the call in @(...) instead, which correctly
      preserves array-ness across a 0/1/N-element result AND still
      serializes cleanly through ConvertTo-Json afterward. A -NoEnumerate
      return works for a caller that only ever foreach's the result (this
      file's own Search-CfCatalogue does exactly that), but this function's
      result flows on into Send-Json/ConvertTo-Json - and a -NoEnumerate
      array handed to ConvertTo-Json -InputObject serializes as
      {"value":[...],"Count":N} instead of a plain JSON array, verified
      while building this round.
    #>
    param($Items)

    $decorated = New-Object 'System.Collections.Generic.List[object]'
    foreach ($it in @($Items)) {
        $parsedDate = [DateTime]::MinValue
        if ($it.updatedAt) {
            try {
                $parsedDate = [DateTime]::ParseExact([string]$it.updatedAt, 'MMM d, yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
            } catch {
                $parsedDate = [DateTime]::MinValue
            }
        }
        $dl = 0
        if ($null -ne $it.downloads) {
            try { $dl = [int64]$it.downloads } catch { $dl = 0 }
        }
        $decorated.Add([PSCustomObject]@{ Item = $it; ParsedDate = $parsedDate; Downloads = $dl; Slug = [string]$it.slug })
    }

    $sorted = $decorated | Sort-Object -Property `
        @{ Expression = 'ParsedDate'; Descending = $true }, `
        @{ Expression = 'Downloads'; Descending = $true }, `
        @{ Expression = 'Slug'; Descending = $false }

    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in @($sorted)) { $out.Add($d.Item) }
    return $out.ToArray()
}

function Get-WagoCategoriesFromProps {
    <#
      Maps a fetched page's raw props.allCategories ({id, display_name})
      into the response shape ({id, displayName}) WAGO-BROWSE-SPEC.md
      section 3.2 defines - shared by every branch of Handle-WagoBrowse
      that has a $props object to read from.

      Returns a plain array - see Sort-WagoItemsByUpdated's own doc
      comment just above for why this is NOT returned via Write-Output
      -NoEnumerate; every call site wraps the call in @(...) instead.
    #>
    param($Props)

    $out = New-Object 'System.Collections.Generic.List[object]'
    if ($Props -and $Props.allCategories) {
        foreach ($c in @($Props.allCategories)) {
            $out.Add([PSCustomObject]@{ id = [int]$c.id; displayName = [string]$c.display_name })
        }
    }
    return $out.ToArray()
}

function Handle-WagoBrowse {
    <#
      GET /api/wago/search (legacy alias, unchanged shape - additive fields
      only) and GET /api/wago/browse (new) both dispatch here.
      WAGO-BROWSE-SPEC.md (Round 32, Expansion E29): renamed from
      Handle-WagoSearch and widened from a single implicit "popularity"
      listing into a real four-way category browse:

        - popular  (default; no sort= sent - Wago's own implicit order IS
                    download-count-descending, verified live)
        - name     (forwards sort=name, the one other value Wago's site
                    actually accepts)
        - updated  (a PAGE-LOCAL re-sort of the IDENTICAL popular page via
                    Sort-WagoItemsByUpdated - see that function's own doc
                    comment for why; shares the same Get-WagoCached entry
                    as "popular" for the same q/categoryId/page, so
                    switching between the two costs zero extra live
                    requests)
        - gaining  (Furphy's OWN measurement - a pure on-disk read of the
                    daily download-growth snapshots this server captures,
                    see Initialize-WagoGrowthSnapshots/Get-WagoGrowthRanking
                    below; NEVER forwarded to Wago, and deliberately
                    ignores q/categoryId - see the CONSTRAINT comment on
                    that branch)

      sort is never trusted verbatim: omitted/empty/any unrecognised value
      (including a stale client's old "rising"/"trending" values) resolves
      to "popular" - absorbs an older build exactly the way this endpoint's
      predecessor (Handle-WagoSearch) always has.

      categoryId is forwarded as Wago's own category= ONLY when it matches
      ^[0-9]+$ (hardening over the old verbatim-forward); anything else is
      treated as absent. page is [int]::TryParse'd; non-numeric or <=0
      clamps to 1 (hardening over the old blank-only substitution).

      GAME-MODE-SPEC.md (2026-09-08): Wago browsing/search works fully
      while a WoW client is running, matching Handle-WagoSearch's original
      (pre-"fix") ungated behavior - the WAGO-BROWSE-SPEC.md 3.5
      Test-GameRunning gate this endpoint used to have is removed. All
      three live-fetch sorts (popular/name/updated) always call
      Get-WagoCached with a live fetch allowed; there is no more
      game-running blocked state or gameActive field in the response.
      sort=gaining is a pure disk read and was always answerable
      regardless of game state.
    #>
    param($Context, $RouteMatch)

    $q = $Context.Request.QueryString
    $search = $q['q']
    $categoryIdRaw = $q['categoryId']
    $sortRaw = $q['sort']

    $sortApplied = 'popular'
    if ($sortRaw -eq 'name') { $sortApplied = 'name' }
    elseif ($sortRaw -eq 'updated') { $sortApplied = 'updated' }
    elseif ($sortRaw -eq 'gaining') { $sortApplied = 'gaining' }

    $pageNum = 1
    $pageRaw = $q['page']
    if ($pageRaw) {
        $parsedPage = 0
        if ([int]::TryParse($pageRaw, [ref]$parsedPage) -and $parsedPage -gt 0) { $pageNum = $parsedPage }
    }

    # 3.1: categoryId forwarded ONLY if it matches ^[0-9]+$ - anything else
    # (non-numeric, blank) is treated as absent. Never forwarded at all for
    # sort=gaining (see the CONSTRAINT comment on that branch, 4.8).
    $categoryIdForWago = $null
    if ($categoryIdRaw -and $categoryIdRaw -match '^[0-9]+$') { $categoryIdForWago = $categoryIdRaw }

    # FLAVORS-SPEC.md CS-F2 S4.6/S6.4: game_version is resolved from this
    # request's own flavour (Set-CurrentFlavourContext, via Invoke-Route)
    # instead of the hardcoded 'retail' literal - Get-CfFlavourMapping's
    # WagoField already centralizes the static retail/classic_era values and
    # 'classic''s dynamic per-Interface resolution (S2.4). Byte-identical to
    # today on a Retail-only machine (WagoField resolves to 'retail').
    $wagoMapping = Get-CfFlavourMapping -Flavor $Script:CurrentFlavour -InstalledInterface $Script:ClientBuildInfo.clientInterface
    # multi-client:wago-browse-unknown-classic-era-silently-shows-retail -
    # a Classic client whose Interface falls outside every row of Resolve-
    # ClassicProgressionTypeId's table (a future Classic expansion this
    # build doesn't know about yet) resolves to the EraKey='unknown'
    # sentinel with WagoField=$null. The old `if (-not $wagoGameVersion) {
    # $wagoGameVersion = 'retail' }` fallback below silently substituted
    # Retail's Wago catalog in that case - the exact class of bug
    # addon-sync.ps1's Sync-SingleAddon/Sync-SingleWagoAddon already
    # hard-fail on for the identical sentinel, rather than ever falling
    # back to Retail. Refuse the same way here instead of ever reaching
    # that fallback, so a below-average-tech player on an unrecognized
    # Classic client never sees Retail-only Wago addons in a Classic search
    # with no indication anything is wrong.
    if ($wagoMapping.EraKey -eq 'unknown') {
        Send-Json -Context $Context -StatusCode 422 -Body @{ error = "Furphy doesn't recognize this Classic version yet - update Furphy to browse new addons for it." }
        return
    }
    $wagoGameVersion = $wagoMapping.WagoField
    if (-not $wagoGameVersion) { $wagoGameVersion = 'retail' }

    if ($sortApplied -eq 'gaining') {
        # CONSTRAINT (permanent, not a TODO): sort=gaining ignores q and
        # categoryId entirely and always will under this design - a
        # category- or search-scoped "gaining" would require per-category
        # daily snapshots (~29x today's request budget) and the growth
        # snapshot format never records which category an addon belongs to.
        # Do not silently fake a category label onto this global list. If
        # this is ever wanted for real, it is a new snapshot format and a
        # new crawl budget, not a filter added to this function.
        Send-WagoGainingResponse -Context $Context -GameVersion $wagoGameVersion -Page $pageNum
        return
    }

    $uri = $Script:WagoBaseUrl + '/?game_version=' + [System.Uri]::EscapeDataString($wagoGameVersion) + '&page=' + [System.Uri]::EscapeDataString([string]$pageNum)
    if ($search) { $uri += '&search=' + [System.Uri]::EscapeDataString($search) }
    if ($categoryIdForWago) { $uri += '&category=' + [System.Uri]::EscapeDataString($categoryIdForWago) }
    if ($sortApplied -eq 'name') { $uri += '&sort=name' }
    # sortApplied 'updated' deliberately sends NO sort= at all - section 3.4:
    # Wago's own sort=updated returns no usable listing, so this fetches the
    # IDENTICAL "popular" URL (same cache entry - zero extra live requests
    # switching between the two tabs) and re-sorts the returned page locally
    # via Sort-WagoItemsByUpdated below.

    try {
        $props = Get-WagoCached -PageUri $uri -AllowLiveFetch:$true
    } catch {
        Send-Json -Context $Context -StatusCode 502 -Body @{ error = "Wago request failed: $($_.Exception.Message)" }
        return
    }

    $items = New-Object 'System.Collections.Generic.List[object]'
    $paginator = $props.addons
    if ($paginator -and $paginator.data) {
        foreach ($cardHtml in @($paginator.data)) {
            $card = ConvertFrom-WagoSearchCardHtml -Html ([string]$cardHtml)
            if ($card) { $items.Add($card) }
        }
    }
    $itemsArray = $items.ToArray()
    if ($sortApplied -eq 'updated') {
        # @(...) wrap: Sort-WagoItemsByUpdated returns a plain array (see
        # its own doc comment) - wrapping the CALL in @(...) is what
        # correctly preserves array-ness across the 0/1/N-element cases
        # (a bare, unwrapped function-return of an array flattens a
        # 1-element result to a scalar and a 0-element result to $null -
        # a PowerShell function-return quirk, not specific to this file).
        $itemsArray = @(Sort-WagoItemsByUpdated -Items $itemsArray)
    }

    $body = [PSCustomObject]@{
        items       = $itemsArray
        page        = $(if ($paginator -and $paginator.current_page) { [int]$paginator.current_page } else { $pageNum })
        lastPage    = $(if ($paginator -and $paginator.last_page) { [int]$paginator.last_page } else { 1 })
        total       = $(if ($paginator -and $paginator.total) { [int]$paginator.total } else { $itemsArray.Count })
        sortApplied = $sortApplied
        categories  = @(Get-WagoCategoriesFromProps -Props $props)
    }
    Send-Json -Context $Context -StatusCode 200 -Body $body
}

function Handle-WagoCategories {
    <# GET /api/wago/categories -> props.allCategories from the search page. #>
    param($Context, $RouteMatch)

    try {
        $props = Get-WagoCached -PageUri ($Script:WagoBaseUrl + '/?game_version=retail')
    } catch {
        Send-Json -Context $Context -StatusCode 502 -Body @{ error = "Wago request failed: $($_.Exception.Message)" }
        return
    }
    $cats = @()
    if ($props.allCategories) { $cats = $props.allCategories }
    Send-Json -Context $Context -StatusCode 200 -Body @{ data = $cats }
}

function Handle-WagoAddonDetails {
    <# GET /api/wago/addons/{slug} -> {addon, description, metadata}. #>
    param($Context, $RouteMatch)

    $slug = $RouteMatch['slug']
    try {
        $props = Get-WagoCached -PageUri ($Script:WagoBaseUrl + '/addons/' + [System.Uri]::EscapeDataString($slug))
    } catch {
        Send-Json -Context $Context -StatusCode 502 -Body @{ error = "Wago request failed: $($_.Exception.Message)" }
        return
    }
    if (-not $props -or -not $props.addon) {
        Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'not found' }
        return
    }
    Send-Json -Context $Context -StatusCode 200 -Body @{ addon = $props.addon; description = $props.description; metadata = $props.metadata }
}

function Handle-WagoAddonReleases {
    <# GET /api/wago/addons/{slug}/releases?page= -> the props.releases paginator, as-is. #>
    param($Context, $RouteMatch)

    $slug = $RouteMatch['slug']
    $q = $Context.Request.QueryString
    $page = Get-QueryOrDefault -QueryString $q -Name 'page' -Default '1'
    $uri = $Script:WagoBaseUrl + '/addons/' + [System.Uri]::EscapeDataString($slug) + '/versions?page=' + [System.Uri]::EscapeDataString($page)

    try {
        $props = Get-WagoCached -PageUri $uri
    } catch {
        Send-Json -Context $Context -StatusCode 502 -Body @{ error = "Wago request failed: $($_.Exception.Message)" }
        return
    }
    if (-not $props -or -not $props.releases) {
        Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'not found' }
        return
    }
    Send-Json -Context $Context -StatusCode 200 -Body @{ data = $props.releases }
}

function Handle-WagoAddonGallery {
    <#
      GET /api/wago/addons/{slug}/gallery. SPEC's verified facts leave this
      page's exact prop shape as "inspect and document" (unlike every other
      Wago endpoint here, which SPEC nails down precisely) - relayed as-is
      under a {gallery: <props>} wrapper rather than reshaped into a
      specific documented shape this build cannot verify against the live
      site (no Wago requests were made during this build - see SPEC/
      CHANGELOG's Wago Addons access facts note).
    #>
    param($Context, $RouteMatch)

    $slug = $RouteMatch['slug']
    $uri = $Script:WagoBaseUrl + '/addons/' + [System.Uri]::EscapeDataString($slug) + '/gallery'
    try {
        $props = Get-WagoCached -PageUri $uri
    } catch {
        Send-Json -Context $Context -StatusCode 502 -Body @{ error = "Wago request failed: $($_.Exception.Message)" }
        return
    }
    Send-Json -Context $Context -StatusCode 200 -Body @{ gallery = $props }
}

function Handle-WagoResolve {
    <#
      GET /api/wago/resolve?url=<wago url or slug> -> {slug}. Unlike CF's
      resolve (which needs a search API call to turn a slug into a numeric
      id), a Wago addon's identity already IS its slug - this is pure string
      parsing, no network call, no cache entry.
    #>
    param($Context, $RouteMatch)

    $q = $Context.Request.QueryString
    $raw = $q['url']
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'url required' }
        return
    }
    $value = $raw.Trim()
    $slug = $null
    if ($value -match '(?i)^https?://addons\.wago\.io/addons/([a-z0-9-]+)') {
        $slug = $Matches[1]
    } elseif ($value -match '^[a-zA-Z0-9-]+$') {
        $slug = $value
    }
    if (-not $slug) {
        Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'not found' }
        return
    }
    Send-Json -Context $Context -StatusCode 200 -Body @{ slug = $slug }
}

# =====================================================================
# Wago growth snapshots and "Gaining this week" (Round 32, Expansion E29,
# WAGO-BROWSE-SPEC.md sections 3.2/4). A Furphy-OWN measurement, never a
# Wago-published figure - every place it reaches the UI says so explicitly
# (see the spec's section 1 exact sentences). Captured at most once per
# ~20h per Wago game_version, entirely from data already fetched the SAME
# paced/cached way every other Wago call in this file is; sort=gaining
# itself is a pure on-disk read with zero network/cache interaction.
# =====================================================================

function Get-WagoGrowthSnapshotPath {
    <# <CacheDir>\wago-growth-<gameVersion>.json - one file per Wago game_version actually encountered. #>
    param([Parameter(Mandatory = $true)][string]$GameVersion)
    return (Join-Path -Path $Script:CacheDir -ChildPath ("wago-growth-{0}.json" -f $GameVersion))
}

function Read-WagoGrowthSnapshotFile {
    <#
      Loads/parses one wago-growth-<gameVersion>.json. Returns the parsed
      object, or $null for missing/empty/corrupt/unreadable (never throws) -
      Get-WagoGrowthRanking treats a $null SnapshotData exactly the same as
      "zero snapshot entries." All disk I/O for the growth-ranking feature
      lives in this one function and Save-WagoGrowthSnapshot below, so
      Get-WagoGrowthRanking itself stays a pure, directly unit-testable
      function (construct a snapshot object in memory, no disk needed).
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Save-WagoGrowthSnapshot {
    <#
      Appends one freshly-crawled page-capture as a new snapshot entry to
      <CacheDir>\wago-growth-<gameVersion>.json (atomic write - temp file +
      Move-Item -Force, matching Save-CfCatalogueIndex's own pattern),
      pruning to the most recent 21 entries (roughly three weeks of daily
      captures allowing for gaps). firstCapturedAt is set once, on the
      file's very first write, and never overwritten afterward even as
      older snapshot entries themselves get pruned away.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$GameVersion,
        [Parameter(Mandatory = $true)]$Items,
        [Parameter(Mandatory = $true)][DateTime]$CapturedAtUtc
    )

    $path = Get-WagoGrowthSnapshotPath -GameVersion $GameVersion
    $existing = Read-WagoGrowthSnapshotFile -Path $path

    $capturedAtText = $CapturedAtUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $firstCapturedAt = $capturedAtText
    if ($existing -and $existing.firstCapturedAt) { $firstCapturedAt = [string]$existing.firstCapturedAt }

    $snapshots = New-Object 'System.Collections.Generic.List[object]'
    if ($existing -and $existing.snapshots) {
        foreach ($s in @($existing.snapshots)) { $snapshots.Add($s) }
    }
    $snapshots.Add([PSCustomObject]@{ capturedAt = $capturedAtText; items = $Items })

    # Re-sort defensively by capturedAt before pruning - never trust
    # on-disk array order - then keep only the most recent 21.
    $sorted = @($snapshots | Sort-Object -Property capturedAt)
    if ($sorted.Count -gt 21) {
        $sorted = $sorted[($sorted.Count - 21)..($sorted.Count - 1)]
    }

    $fileBody = [PSCustomObject]@{
        gameVersion     = $GameVersion
        firstCapturedAt = $firstCapturedAt
        snapshots       = $sorted
    }

    try {
        if (-not (Test-Path -LiteralPath $Script:CacheDir)) {
            New-Item -ItemType Directory -Path $Script:CacheDir -Force | Out-Null
        }
        $json = ConvertTo-Json -InputObject $fileBody -Depth 8
        $tmpPath = "$path.tmp"
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
        Move-Item -LiteralPath $tmpPath -Destination $path -Force
    } catch {
        Write-ServerLog "Failed to write Wago growth snapshot for '$GameVersion': $($_.Exception.Message)"
    }
}

function Get-WagoGrowthRanking {
    <#
      WAGO-BROWSE-SPEC.md section 4.6 - the ENTIRE "gaining this week"
      ranking algorithm. Pure function: touches no disk, no network, no
      script-scope state, given an already-parsed snapshot-file object (or
      $null, treated identically to "zero snapshot entries") - directly
      unit-testable by constructing a snapshot object in memory. -NowUtc is
      accepted for a stable, explicit interface (every other timestamp this
      function reasons about is DATA-driven, off the snapshots' own
      capturedAt values, not wall-clock time) but is not itself consulted
      by the steps below.

      1. Missing/corrupt/empty data, or zero snapshot entries -> not ready,
         snapshotCount 0.
      2. latest = the entry with the max capturedAt (re-sorted defensively -
         never trust on-disk array order). An entry whose own capturedAt
         fails to parse is dropped before this step (still counted toward
         snapshotCount below, which reflects the RAW file entry count).
      3. targetAge = latest.capturedAt - 7 days. Search every OTHER
         snapshot in the inclusive window [latest-9d, latest-5d]; pick
         whichever is numerically closest to targetAge, ties broken toward
         the OLDER candidate (deterministic). None found (including "only
         latest exists") -> not ready, but since/snapshotCount ARE
         populated (there IS real data, just not old enough yet).
      4. baseline = the chosen snapshot; build a slug -> downloads
         dictionary from it (first occurrence wins on an intra-snapshot
         duplicate slug - defensive; the crawl itself already de-dupes).
      5. For every latest.items entry also present in baseline (first
         occurrence wins on a duplicate slug in latest too) with
         delta = latest.downloads - baseline.downloads STRICTLY positive:
         keep. Flat, declining, or baseline-absent (a new top-150 entrant
         this week, no honest baseline to compare against) entries are
         EXCLUDED, never shown as "gaining."
      6. Sort qualifying entries: delta descending, then latest-downloads
         descending, then slug ascending - explicit three-key, never
         relying on incidental stability.
      7. Return ready=$true with since/asOf/baselineAsOf/snapshotCount/items.
    #>
    param($SnapshotData, [DateTime]$NowUtc)

    $notReady = [PSCustomObject]@{
        ready         = $false
        since         = $null
        asOf          = $null
        baselineAsOf  = $null
        snapshotCount = 0
        items         = @()
    }

    if (-not $SnapshotData -or -not $SnapshotData.snapshots) { return $notReady }
    $rawSnapshots = @($SnapshotData.snapshots)
    if ($rawSnapshots.Count -eq 0) { return $notReady }

    $totalCount = $rawSnapshots.Count
    $firstCapturedAt = [string]$SnapshotData.firstCapturedAt

    # Parse capturedAt on every entry defensively; an entry whose own
    # capturedAt fails to parse is dropped from ranking consideration but
    # still counted in snapshotCount (the RAW file entry count, per 4.6).
    $parsed = New-Object 'System.Collections.Generic.List[object]'
    $dateStyles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    foreach ($s in $rawSnapshots) {
        try {
            $dt = [DateTime]::Parse([string]$s.capturedAt, [System.Globalization.CultureInfo]::InvariantCulture, $dateStyles)
            $parsed.Add([PSCustomObject]@{ CapturedAt = $dt; Raw = $s })
        } catch {
            # Unparseable capturedAt on this one entry - drop it from
            # ranking consideration, never abort the whole computation.
        }
    }
    if ($parsed.Count -eq 0) {
        $r = $notReady.PSObject.Copy()
        $r.since = $firstCapturedAt
        $r.snapshotCount = $totalCount
        return $r
    }

    # Step 2: latest = max-capturedAt entry, re-sorted defensively.
    $byTime = @($parsed | Sort-Object -Property CapturedAt)
    $latestEntry = $byTime[$byTime.Count - 1]
    $latest = $latestEntry.Raw
    $latestCapturedAt = $latestEntry.CapturedAt

    # Step 3: baseline = closest-to-7-days-back candidate in [-9d, -5d],
    # ties broken toward the OLDER candidate.
    $windowStart = $latestCapturedAt.AddDays(-9)
    $windowEnd = $latestCapturedAt.AddDays(-5)
    $targetAge = $latestCapturedAt.AddDays(-7)

    $bestCandidate = $null
    $bestDistanceSeconds = 0.0
    foreach ($cand in $parsed) {
        if ([object]::ReferenceEquals($cand, $latestEntry)) { continue }
        if ($cand.CapturedAt -lt $windowStart -or $cand.CapturedAt -gt $windowEnd) { continue }
        $distance = [Math]::Abs(($cand.CapturedAt - $targetAge).TotalSeconds)
        if ($null -eq $bestCandidate -or $distance -lt $bestDistanceSeconds -or `
            ($distance -eq $bestDistanceSeconds -and $cand.CapturedAt -lt $bestCandidate.CapturedAt)) {
            $bestCandidate = $cand
            $bestDistanceSeconds = $distance
        }
    }

    if (-not $bestCandidate) {
        return [PSCustomObject]@{
            ready         = $false
            since         = $firstCapturedAt
            asOf          = $null
            baselineAsOf  = $null
            snapshotCount = $totalCount
            items         = @()
        }
    }

    $baseline = $bestCandidate.Raw
    $baselineCapturedAt = $bestCandidate.CapturedAt

    # Step 4: baseline slug -> downloads dictionary (first occurrence wins
    # on an intra-snapshot duplicate slug - defensive).
    $baselineDownloads = @{}
    foreach ($it in @($baseline.items)) {
        if (-not $it.slug) { continue }
        $s = [string]$it.slug
        if ($baselineDownloads.ContainsKey($s)) { continue }
        $baselineDownloads[$s] = [int64]$it.downloads
    }

    # Step 5: qualifying entries (strictly positive delta only), first
    # occurrence wins on a duplicate slug in latest.items too.
    $qualifying = New-Object 'System.Collections.Generic.List[object]'
    $seenLatestSlugs = @{}
    foreach ($it in @($latest.items)) {
        if (-not $it.slug) { continue }
        $slug = [string]$it.slug
        if ($seenLatestSlugs.ContainsKey($slug)) { continue }
        $seenLatestSlugs[$slug] = $true
        if (-not $baselineDownloads.ContainsKey($slug)) { continue }
        $latestDownloads = [int64]$it.downloads
        $delta = $latestDownloads - $baselineDownloads[$slug]
        if ($delta -le 0) { continue }
        $qualifying.Add([PSCustomObject]@{
            slug           = $slug
            name           = [string]$it.name
            thumbnail      = [string]$it.thumbnail
            downloads      = $latestDownloads
            deltaDownloads = $delta
            rank           = $(if ($null -ne $it.rank) { [int]$it.rank } else { $null })
        })
    }

    # Step 6: delta descending, then latest-downloads descending, then slug
    # ascending - explicit three-key, never incidental stability.
    $sortedItems = @($qualifying | Sort-Object -Property `
        @{ Expression = 'deltaDownloads'; Descending = $true }, `
        @{ Expression = 'downloads'; Descending = $true }, `
        @{ Expression = 'slug'; Descending = $false })

    return [PSCustomObject]@{
        ready         = $true
        since         = $firstCapturedAt
        asOf          = [string]$latest.capturedAt
        baselineAsOf  = [string]$baseline.capturedAt
        snapshotCount = $totalCount
        items         = $sortedItems
    }
}

function Send-WagoGainingResponse {
    <#
      sort=gaining's own response path, split out of Handle-WagoBrowse for
      readability - a pure on-disk read (Read-WagoGrowthSnapshotFile +
      Get-WagoGrowthRanking), zero network/cache interaction, always
      answerable regardless of game state (WAGO-BROWSE-SPEC.md 3.5/4).
    #>
    param($Context, [string]$GameVersion, [int]$Page)

    $snapshotPath = Get-WagoGrowthSnapshotPath -GameVersion $GameVersion
    $snapshotData = Read-WagoGrowthSnapshotFile -Path $snapshotPath
    $ranking = Get-WagoGrowthRanking -SnapshotData $snapshotData -NowUtc (Get-Date).ToUniversalTime()

    $allItems = @($ranking.items)
    $pageSize = 15
    $totalCount = $allItems.Count
    $lastPageNum = 1
    if ($totalCount -gt 0) { $lastPageNum = [int][Math]::Ceiling($totalCount / [double]$pageSize) }
    $startIdx = ($Page - 1) * $pageSize
    $pageItems = @()
    if ($startIdx -lt $totalCount) {
        $endIdxExclusive = [Math]::Min($startIdx + $pageSize, $totalCount)
        $pageItems = @($allItems[$startIdx..($endIdxExclusive - 1)])
    }

    # Categories: cache-ONLY lookup (never a live Wago request from this
    # branch - "gaining" is a pure disk read and stays that way). An
    # already-warm cache entry (e.g. from a recent Popular/Name/Updated
    # browse) is used opportunistically; a cold miss just means [] - the
    # category strip is shown disabled/greyed while this tab is active
    # anyway (WAGO-BROWSE-SPEC.md section 2.2/2.4), so an empty list here
    # is a harmless, honest degrade, never a broken control.
    $catsForGaining = @()
    try {
        $catsProps = Get-WagoCached -PageUri ($Script:WagoBaseUrl + '/?game_version=retail') -AllowLiveFetch:$false
        if ($catsProps) { $catsForGaining = @(Get-WagoCategoriesFromProps -Props $catsProps) }
    } catch {
        # Cache-only lookup failing is harmless here - fall through with [].
    }

    $body = [PSCustomObject]@{
        items         = $pageItems
        page          = $Page
        lastPage      = $lastPageNum
        total         = $totalCount
        sortApplied   = 'gaining'
        categories    = $catsForGaining
        ready         = $ranking.ready
        since         = $ranking.since
        asOf          = $ranking.asOf
        baselineAsOf  = $ranking.baselineAsOf
        snapshotCount = $ranking.snapshotCount
    }
    Send-Json -Context $Context -StatusCode 200 -Body $body
}

function Initialize-WagoGrowthSnapshots {
    <#
      WAGO-BROWSE-SPEC.md sections 4.1-4.4/4.7: called once at server
      startup, immediately after Initialize-CfCatalogueIndex and strictly
      before the request loop starts accepting connections (enforced by
      the $Script:AcceptingRequests guard immediately below - see that
      variable's own declaration near the other startup state for the full
      rationale). The only periodic-refresh precedent in this file besides
      that catalogue index; "daily" here means "checked once whenever this
      long-lived process happens to (re)start," not a real timer.

      For every INSTALLED flavour's own Wago game_version (deduped in
      first-seen order - PTR/XPTR/Beta collapse into the already-present
      'retail' entry for free, since their WagoField defaults there),
      crawls up to 10 pages of Wago's own popularity listing (the SAME
      Get-WagoCached/Invoke-WagoHttpRequest path, same pacing, every other
      Wago call in this file uses) and writes/prunes
      <CacheDir>\wago-growth-<gameVersion>.json, gated on a per-file
      20-hour freshness check (that file's own last entry's capturedAt) -
      per-game_version, not global, so one flavour's recent capture never
      blocks a newly-installed sibling's first one. GAME-MODE-SPEC.md
      (2026-09-08): the crawl runs regardless of WoW's process state - the
      Test-GameRunning startup gate and the per-page TOCTOU abort this
      function used to have are both removed; this is Wago's own daily
      background crawl, and per Eric's policy it needs to happen throughout
      a play session same as everything else.

      PARTIAL rule: if zero pages succeeded for a game_version, nothing is
      written (never persist an empty-items snapshot - it would corrupt
      the "closest snapshot" window search and the readiness rule); if 1+
      pages succeeded before a later page failed, the snapshot IS still
      written with whatever was captured.

      Exception-safe by construction (4.3): each game_version's crawl runs
      inside its own try/catch (log-and-continue, matching this file's
      never-throw style elsewhere), and $Script:CurrentFlavour is ALWAYS
      restored to the real default in a `finally` around the whole loop -
      the actual safety net, not the inner catch - so a bug even inside a
      catch handler itself can never leave a non-default flavour stuck in
      $Script:CurrentFlavour for the rest of this process's life.
    #>

    # 4.4 (REQUIRED FIX): turns "must run before the request loop starts
    # accepting connections" from a doc-comment-only invariant into
    # something that fails loudly - a startup crash, impossible to miss in
    # server.log - instead of silently corrupting every flavour-scoped
    # request (not just Wago's) for the rest of this process's life, should
    # a future refactor move this call past that point without updating it.
    if ($Script:AcceptingRequests) {
        throw 'Initialize-WagoGrowthSnapshots must run before the request loop starts accepting connections - a refactor moved this call past that point without updating it.'
    }

    # Round-1-fixer (verifier finding 1): test-mode escape hatch - see
    # $Script:SkipWagoGrowthCrawl's own declaration/comment near the top of
    # this file for the full rationale. Checked first, before anything else,
    # so a test run never pays for even one live Wago request it did not
    # ask for.
    if ($Script:SkipWagoGrowthCrawl) {
        Write-ServerLog 'Wago growth snapshot crawl skipped at startup: FURPHY_TEST_SKIP_WAGO_GROWTH is set (test mode)'
        return
    }

    $crawlStart = Get-Date

    $installedFlavours = Get-CurrentInstalledFlavours

    # 4.7: dedup distinct WagoField values in first-seen order (hard
    # ceiling of 6, collapses to exactly 1 on the overwhelmingly common
    # Retail-only machine).
    $gameVersionsSeen = New-Object 'System.Collections.Generic.List[string]'
    $flavourIdByGameVersion = @{}
    foreach ($f in $installedFlavours) {
        Set-CurrentFlavourContext -Flavor $f.id
        $mapping = Get-CfFlavourMapping -Flavor $Script:CurrentFlavour -InstalledInterface $Script:ClientBuildInfo.clientInterface
        $gv = $mapping.WagoField
        if (-not $gv) { continue }
        if (-not $flavourIdByGameVersion.ContainsKey($gv)) {
            $flavourIdByGameVersion[$gv] = $f.id
            $gameVersionsSeen.Add($gv)
        }
    }

    try {
        foreach ($gv in $gameVersionsSeen) {
            try {
                Set-CurrentFlavourContext -Flavor $flavourIdByGameVersion[$gv]

                # Per-file 20h freshness check.
                $snapshotPath = Get-WagoGrowthSnapshotPath -GameVersion $gv
                $existing = Read-WagoGrowthSnapshotFile -Path $snapshotPath
                if ($existing -and $existing.snapshots -and @($existing.snapshots).Count -gt 0) {
                    $lastRaw = @($existing.snapshots | Sort-Object -Property capturedAt | Select-Object -Last 1)[0]
                    $lastCapturedAt = $null
                    try {
                        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
                        $lastCapturedAt = [DateTime]::Parse([string]$lastRaw.capturedAt, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
                    } catch {
                        $lastCapturedAt = $null
                    }
                    if ($lastCapturedAt) {
                        $ageHours = ((Get-Date).ToUniversalTime() - $lastCapturedAt).TotalHours
                        if ($ageHours -lt 20) {
                            Write-ServerLog "Wago growth snapshot for '$gv' is $([Math]::Round($ageHours, 1))h old - skipping (20h freshness gate)"
                            continue
                        }
                    }
                }

                # Crawl up to 10 pages.
                $capturedItems = New-Object 'System.Collections.Generic.List[object]'
                $seenSlugs = @{}
                $pagesFetched = 0
                for ($p = 1; $p -le 10; $p++) {
                    $pageUri = $Script:WagoBaseUrl + '/?game_version=' + [System.Uri]::EscapeDataString($gv) + '&page=' + $p
                    try {
                        $pageProps = Get-WagoCached -PageUri $pageUri -AllowLiveFetch:$true
                    } catch {
                        Write-ServerLog "Wago growth snapshot page fetch failed for '$gv' page $p (keeping what was already captured this run): $($_.Exception.Message)"
                        break
                    }
                    $pagesFetched++
                    $paginator = $pageProps.addons
                    if (-not $paginator -or -not $paginator.data) { break }
                    $rankBase = ($p - 1) * 15
                    $rankOffset = 0
                    foreach ($cardHtml in @($paginator.data)) {
                        $rankOffset++
                        $card = ConvertFrom-WagoSearchCardHtml -Html ([string]$cardHtml)
                        if (-not $card -or -not $card.slug) { continue }
                        # Defensive de-dup by slug (keep first/lowest-rank
                        # occurrence) - observed live single-digit
                        # download-count drift between near-simultaneous
                        # requests can occasionally shuffle an addon across
                        # a page boundary mid-crawl.
                        if ($seenSlugs.ContainsKey($card.slug)) { continue }
                        $seenSlugs[$card.slug] = $true
                        $capturedItems.Add([PSCustomObject]@{
                            slug      = $card.slug
                            name      = $card.name
                            thumbnail = $card.thumbnail
                            downloads = $(if ($null -ne $card.downloads) { [int64]$card.downloads } else { 0 })
                            rank      = ($rankBase + $rankOffset)
                        })
                    }
                    $currentPage = 1
                    $lastPageOfListing = 1
                    if ($paginator.current_page) { $currentPage = [int]$paginator.current_page }
                    if ($paginator.last_page) { $lastPageOfListing = [int]$paginator.last_page }
                    if ($currentPage -ge $lastPageOfListing) { break }
                }

                if ($capturedItems.Count -eq 0) {
                    # PARTIAL rule (4.3): zero pages succeeded - never
                    # persist an empty-items snapshot.
                    Write-ServerLog "Wago growth snapshot crawl for '$gv' captured nothing this run - not writing a snapshot"
                } else {
                    Save-WagoGrowthSnapshot -GameVersion $gv -Items $capturedItems.ToArray() -CapturedAtUtc (Get-Date).ToUniversalTime()
                    Write-ServerLog "Wago growth snapshot captured for '$gv': $($capturedItems.Count) items across $pagesFetched page(s)"
                }
            } catch {
                Write-ServerLog "Wago growth snapshot crawl failed for game_version '$gv': $($_.Exception.Message)"
            }
        }
    } finally {
        # The ACTUAL safety net (4.3) - always restore, even if something
        # above threw past its own catch (a bug in the catch handler
        # itself, say).
        Set-CurrentFlavourContext -Flavor (Get-DefaultFlavourId -InstalledFlavours $Script:InstalledFlavoursAtStartup)
    }

    # 4.5's mitigation: log elapsed time on every run that actually
    # started (not when gated out entirely at the top) so the added
    # startup cost is measured and visible in server.log, not theorized.
    $elapsedSeconds = ((Get-Date) - $crawlStart).TotalSeconds
    Write-ServerLog "Wago growth snapshot crawl finished in $([Math]::Round($elapsedSeconds, 1))s"
}

# =====================================================================
# Round 37 (server perf pass) - maintenance child scheduling
#
# The real serving process's own startup no longer calls
# Initialize-CfCatalogueIndex/Initialize-WagoGrowthSnapshots at all (see the
# startup section's own "Load ONLY what is on disk" comment, right after
# listener.Start()) - a hidden -MaintenanceOnly child of this same script,
# spawned from the request loop's own tick below, does that instead. Both
# functions above are completely unchanged; only their call site moved.
# =====================================================================

function Test-MaintenanceChildRunning {
    <#
      $Script:MaintenanceLockPath holds the PID of the last -MaintenanceOnly
      child THIS server spawned (written by the -MaintenanceOnly branch
      itself, right after it starts; removed in its own `finally`, whether
      it succeeded or failed). Returns $true only when that PID still
      resolves to a genuinely live process - a lock file left behind by a
      child that crashed or was force-killed before its own `finally` ran is
      treated as stale and removed right here, the same "verify the PID,
      don't just trust the file's existence" pattern
      Clear-StaleTestServerOnPort uses for a stale test server (tests\lib\
      common.ps1). Never throws.
    #>
    if (-not $Script:MaintenanceLockPath -or -not (Test-Path -LiteralPath $Script:MaintenanceLockPath -PathType Leaf)) {
        return $false
    }
    try {
        $pidText = (Get-Content -LiteralPath $Script:MaintenanceLockPath -Raw -ErrorAction Stop).Trim()
        $pidValue = 0
        if ([int]::TryParse($pidText, [ref]$pidValue) -and $pidValue -gt 0) {
            if (Get-Process -Id $pidValue -ErrorAction SilentlyContinue) {
                return $true
            }
        }
    } catch {
        # Falls through to the stale-lock cleanup below.
    }
    try { Remove-Item -LiteralPath $Script:MaintenanceLockPath -Force -ErrorAction SilentlyContinue } catch { }
    return $false
}

function Invoke-MaintenanceTick {
    <#
      Called once per request-loop iteration (the same 2s/15s WaitOne
      cadence Test-GameRunning's own wait timing already runs on - this
      file's only existing "timer tick"). Spawns a hidden, BelowNormal-
      priority -MaintenanceOnly child of THIS SAME SCRIPT at most once every
      $Script:MaintenanceIntervalMinutes, and only when:
        - $Script:LastMaintenanceAttemptAt is at least that old ($null-
          initialized to [DateTime]::MinValue, so the very first tick after
          startup always qualifies - "shortly after startup", per the task
          brief);
        - Test-MaintenanceChildRunning says no such child is already up.
      GAME-MODE-SPEC.md (2026-09-08): this used to also refuse while WoW
      was running (a single master gate disabling catalogue refresh, the
      Wago growth crawl, and the hourly self-update check together
      whenever the game ran) - that gate is dropped. The maintenance child
      now spawns on its normal interval regardless of game state, same as
      every other addon/browse/update path in this file.
      The spawned child is itself already fully self-gated (Initialize-
      CfCatalogueIndex/Initialize-WagoGrowthSnapshots's own 24h/20h
      freshness checks, unchanged) - most attempts do nothing beyond a
      couple of cheap disk/registry reads before exiting, so this hourly
      cadence costs nothing extra on the far more common "nothing was
      actually due" tick, while still comfortably meeting both real
      freshness SLAs well inside their own windows.
      $Script:LastMaintenanceAttemptAt is stamped the moment a child is
      actually SPAWNED, not merely considered - a tick that declined to
      spawn (one already in flight) tries again on the very next tick once
      that condition clears, instead of waiting out the rest of the hour.
      Best-effort throughout, like every startup/maintenance path in this
      file: a failure here must never affect request handling.
    #>

    try {
        if (((Get-Date) - $Script:LastMaintenanceAttemptAt).TotalMinutes -lt $Script:MaintenanceIntervalMinutes) { return }
        if (Test-MaintenanceChildRunning) { return }

        $Script:LastMaintenanceAttemptAt = Get-Date

        # Round-1-fixer: the script's own real path ($Script:ScriptSelfPath,
        # set once at startup - see its own doc comment), NOT
        # "Join-Path $Script:Root 'addon-server.ps1'" - -Root is a per-test
        # DATA directory in tests\lib\common.ps1's Start-TestServer, not
        # necessarily where addon-server.ps1 itself lives (only true, and
        # only by construction, in a real production deployment).
        $scriptPath = $Script:ScriptSelfPath
        $psArgs = New-Object 'System.Collections.Generic.List[object]'
        $psArgs.Add('-NoProfile')
        $psArgs.Add('-ExecutionPolicy')
        $psArgs.Add('Bypass')
        $psArgs.Add('-File')
        $psArgs.Add((ConvertTo-SafeProcessArg $scriptPath))
        $psArgs.Add('-Root')
        $psArgs.Add((ConvertTo-SafeProcessArg $Script:Root))
        $psArgs.Add('-MaintenanceOnly')
        # Thread through the same test-only overrides the real server was
        # started with, so the child resolves the identical
        # flavours/AddOns-path/game-running answer a test expects -
        # mirrors New-CliProcessArgs's own -WowRoot handling for the CLI
        # child. Never set outside a test harness.
        if ($Script:WowRootOverride) {
            $psArgs.Add('-WowRoot')
            $psArgs.Add((ConvertTo-SafeProcessArg $Script:WowRootOverride))
        }
        if ($Script:BuildInfoPathOverride) {
            $psArgs.Add('-BuildInfoPath')
            $psArgs.Add((ConvertTo-SafeProcessArg $Script:BuildInfoPathOverride))
        }
        if ($Script:WowFakeProcessNameOverride) {
            $psArgs.Add('-WowFakeProcessName')
            $psArgs.Add((ConvertTo-SafeProcessArg $Script:WowFakeProcessNameOverride))
        }

        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs.ToArray() -WindowStyle Hidden | Out-Null
            Write-ServerLog 'Maintenance tick: spawned a -MaintenanceOnly child'
        } catch {
            Write-ServerLog "Maintenance tick: failed to spawn -MaintenanceOnly child: $($_.Exception.Message)"
        }
    } catch {
        Write-ServerLog "Maintenance tick failed (request handling unaffected): $($_.Exception.Message)"
    }
}

function Update-CfCatalogueCacheIfChanged {
    <#
      Called once per request-loop iteration, alongside Invoke-MaintenanceTick
      above. A cheap per-tick check for whether cache\cf-catalogue.json's own
      LastWriteTimeUtc has moved since this process last loaded it - true
      after a -MaintenanceOnly child (this server's own, spawned by
      Invoke-MaintenanceTick, or in principle any other process sharing this
      same -Root's cache\ folder) writes a freshly-refreshed catalogue. Only
      THEN pays for the real reload (Load-CfCatalogueIndexFromDisk's JSON
      parse over the whole ~18k-entry index, the same cost Round 26's own
      comment already identified as worth moving off the request-accepting
      path) - never on a tick where nothing changed (the overwhelming
      majority), and never inside a request handler. Best-effort; never
      throws.

      F1 (idle-loop perf pass): the disk stat itself is now throttled to at
      most once every $Script:CfCatalogueCacheStatIntervalSeconds (30s),
      via $Script:CfCatalogueCacheLastStatAt -
      this used to stat the file on literally every 2s request-loop tick
      (~1800 stats/hour) even though the maintenance child that could
      possibly change it runs at most once an HOUR (Invoke-MaintenanceTick's
      own $Script:MaintenanceIntervalMinutes gate). A freshly-written
      catalogue can therefore take up to 30s longer to be picked up by this
      process than before - fine, since the writer itself only ever writes
      at most once an hour, so 30s of extra latency on top of that is
      noise. Also swaps Test-Path + Get-Item (two calls,
      one of which throws-and-is-caught-elsewhere-shaped for a missing file)
      for a single [System.IO.File]::GetLastWriteTimeUtc call, which returns
      1601-01-01T00:00:00Z for a missing file instead of throwing -
      $Script:CfCatalogueCacheLastWriteUtc is seeded with that exact sentinel
      (see its own declaration, near Invoke-MaintenanceTick's script-level
      vars) so the common "catalogue file has never been written on this
      -Root" case (most integration tests, and a genuinely fresh install
      before its first maintenance tick) compares equal immediately and
      returns without ever calling Load-CfCatalogueIndexFromDisk.
    #>
    try {
        $nowStat = Get-Date
        if (($nowStat - $Script:CfCatalogueCacheLastStatAt).TotalSeconds -lt $Script:CfCatalogueCacheStatIntervalSeconds) { return }
        $Script:CfCatalogueCacheLastStatAt = $nowStat

        $writeTimeUtc = [System.IO.File]::GetLastWriteTimeUtc($Script:CfCatalogueCachePath)
        if ($writeTimeUtc -eq $Script:CfCatalogueCacheLastWriteUtc) { return }
        if (Load-CfCatalogueIndexFromDisk) {
            $Script:CfCatalogueCacheLastWriteUtc = $writeTimeUtc
            Write-ServerLog "CurseForge catalogue reloaded from disk cache: $($Script:CfCatalogueIndex.Count) entries, fetched $($Script:CfCatalogueFetchedAt)"
        }
    } catch {
        # Best-effort - a failed reload just keeps serving whatever was
        # already loaded, same as every other best-effort catalogue path.
    }
}

# =====================================================================
# Keyless CurseForge enrichment (E16) - three new, independently-verified,
# purely additive metadata sources for a CurseForge-sourced record when no
# API key is configured: an offline catalogue index (instawow-data, with
# strongbox-catalogue as coverage insurance), a live addon-radar.com mirror
# (paced/cached like the CurseForge-website and Wago proxies above), and
# E12's own Wago Addons integration (a toc-derived cross-id first, then a
# conservative name+author auto-match). None of this can install anything -
# read-only enrichment only, consulted ONLY when no key is configured; the
# key-gated /api/cf/* proxy above is completely untouched, including its
# 409 {error:"no-key"} contract. Verified facts live in SPEC.md's "Keyless
# enrichment sources" section.
# =====================================================================

function Load-CfCatalogueIndexFromDisk {
    <# Loads ROOT\cache\cf-catalogue.json into $Script:CfCatalogueIndex/$Script:CfCatalogueById/$Script:CfCatalogueFetchedAt/$Script:CfCatalogueSource. Returns $true on success, $false if the file is missing/empty/corrupt (never throws). #>
    if (-not (Test-Path -LiteralPath $Script:CfCatalogueCachePath)) { return $false }
    try {
        $raw = Get-Content -LiteralPath $Script:CfCatalogueCachePath -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $entries = New-Object 'System.Collections.Generic.List[object]'
        $byId = @{}
        foreach ($e in @($obj.entries)) {
            $id = [string]$e.id
            if (-not $id) { continue }
            $entries.Add($e)
            $byId[$id] = $e
        }
        $Script:CfCatalogueIndex = $entries.ToArray()
        $Script:CfCatalogueById = $byId
        $Script:CfCatalogueFetchedAt = [string]$obj.fetchedAt
        $Script:CfCatalogueSource = [string]$obj.source
        return $true
    } catch {
        Write-ServerLog "Failed to read cf-catalogue.json cache, ignoring: $($_.Exception.Message)"
        return $false
    }
}

function Save-CfCatalogueIndex {
    <#
      Forces a fresh fetch+merge+write of the CurseForge catalogue index:
      instawow-data's base-catalogue-v8.compact.json (100% coverage, the
      primary source - filtered to source:"curse" entries), then - paced
      >=1s after it, per SPEC's verified facts - strongbox-catalogue's
      curseforge-catalogue.json (54% coverage, frozen since 2022-01-22,
      consulted only as insurance for an id instawow-data might miss;
      instawow-data wins on any id collision). Updates the in-memory index
      and writes ROOT\cache\cf-catalogue.json (temp file + Move-Item,
      matching Save-CheckState's atomic-write pattern). Returns
      @{ ok; fetchedAt; count; source; error }. A strongbox failure is not
      fatal (instawow-data alone already has near-total coverage); an
      instawow-data failure IS fatal to this refresh and leaves whatever
      index was already loaded (possibly empty) untouched.
    #>
    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'
    $byId = @{}
    $source = 'instawow-data'

    try {
        $resp1 = Invoke-WebRequest -Uri ($Script:CfCatalogueBaseUrl + '/layday/instawow-data/data/base-catalogue-v8.compact.json') -UserAgent $userAgent -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $data1 = $resp1.Content | ConvertFrom-Json -ErrorAction Stop
        foreach ($entry in @($data1.entries)) {
            if ([string]$entry.source -ne 'curse') { continue }
            $id = [string]$entry.id
            if (-not $id) { continue }
            $downloads = 0
            if ($entry.download_count) { $downloads = [int64]$entry.download_count }
            $byId[$id] = [PSCustomObject]@{
                id            = $id
                name          = [string]$entry.name
                slug          = [string]$entry.slug
                url           = [string]$entry.url
                downloadCount = $downloads
                lastUpdated   = [string]$entry.last_updated
            }
        }
    } catch {
        Write-ServerLog "CurseForge catalogue refresh: instawow-data fetch failed: $($_.Exception.Message)"
        return @{ ok = $false; fetchedAt = $Script:CfCatalogueFetchedAt; count = $Script:CfCatalogueIndex.Count; source = $Script:CfCatalogueSource; error = $_.Exception.Message }
    }

    Start-Sleep -Milliseconds 1000

    try {
        $resp2 = Invoke-WebRequest -Uri ($Script:CfCatalogueBaseUrl + '/ogri-la/strongbox-catalogue/master/curseforge-catalogue.json') -UserAgent $userAgent -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $data2 = $resp2.Content | ConvertFrom-Json -ErrorAction Stop
        $list2 = $data2.'addon-summary-list'
        foreach ($entry in @($list2)) {
            if ([string]$entry.source -ne 'curseforge') { continue }
            $id = [string]$entry.'source-id'
            if (-not $id) { continue }
            if ($byId.ContainsKey($id)) { continue }   # instawow-data wins on collision
            $slug = $null
            $url = [string]$entry.url
            if ($url -match '/wow/addons/([^/?#]+)') { $slug = $Matches[1] }
            $name = [string]$entry.name
            if (-not $name) { $name = [string]$entry.label }
            $downloads = 0
            if ($entry.'download-count') { $downloads = [int64]$entry.'download-count' }
            $byId[$id] = [PSCustomObject]@{
                id            = $id
                name          = $name
                slug          = $slug
                url           = $url
                downloadCount = $downloads
                lastUpdated   = [string]$entry.'updated-date'
            }
        }
        $source = 'instawow-data+strongbox'
    } catch {
        Write-ServerLog "CurseForge catalogue refresh: strongbox-catalogue fetch failed (continuing with instawow-data only): $($_.Exception.Message)"
    }

    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($k in $byId.Keys) { $entries.Add($byId[$k]) }

    $fetchedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $cacheBody = [PSCustomObject]@{ fetchedAt = $fetchedAt; source = $source; entries = $entries.ToArray() }
    try {
        if (-not (Test-Path -LiteralPath $Script:CacheDir)) {
            New-Item -ItemType Directory -Path $Script:CacheDir -Force | Out-Null
        }
        $json = ConvertTo-Json -InputObject $cacheBody -Depth 6
        $tmpPath = "$Script:CfCatalogueCachePath.tmp"
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
        Move-Item -LiteralPath $tmpPath -Destination $Script:CfCatalogueCachePath -Force
    } catch {
        Write-ServerLog "Failed to write cf-catalogue.json cache: $($_.Exception.Message)"
    }

    $Script:CfCatalogueIndex = $entries.ToArray()
    $Script:CfCatalogueById = $byId
    $Script:CfCatalogueFetchedAt = $fetchedAt
    $Script:CfCatalogueSource = $source

    Write-ServerLog "CurseForge catalogue refreshed: $($entries.Count) entries from $source"
    return @{ ok = $true; fetchedAt = $fetchedAt; count = $entries.Count; source = $source; error = $null }
}

function Initialize-CfCatalogueIndex {
    <#
      Called once at server startup. Loads ROOT\cache\cf-catalogue.json when
      present and fresh (<24h); fetches a new one when missing or stale.
      Best-effort: a fetch failure at startup leaves the index empty (or
      whatever stale copy is already on disk, loaded first as a fallback)
      rather than blocking the server from starting - Search-CfCatalogue/
      Get-CfCatalogueEntry both tolerate an empty index (no matches), which
      just means /api/cf/browse and /api/cf/enrich fall straight through to
      their next fallback (addon-radar / catalogue-only) until a refresh
      succeeds (automatically past the 24h mark, or via Settings >
      Maintenance > "Refresh CurseForge catalogue now").

      Must run before the request loop starts accepting connections - see
      the $Script:AcceptingRequests guard immediately below, a verbatim
      mirror of Initialize-WagoGrowthSnapshots' own guard (WAGO-BROWSE-
      SPEC.md section 4.4), added for the same reason: this was previously
      a doc-comment-only invariant with nothing to catch a future refactor
      that moved this call past that point.
    #>
    # perf-game:lead3 / first-run-docs:cf-catalogue-init-missing-symmetry-
    # guard (Round 36 fixer): symmetry fix - Initialize-WagoGrowthSnapshots
    # already throws loudly if ever called after $Script:AcceptingRequests
    # flips true; this sibling startup routine had no equivalent guard even
    # though it has the identical "must run before the request loop starts
    # accepting connections" requirement. Not a live bug today (the real
    # call site below still runs strictly before that flip), but without
    # this a future refactor that broke that ordering would fail silently -
    # every request would be served against a catalogue mid-(re)build with
    # no loud failure, instead of a startup crash impossible to miss in
    # server.log.
    if ($Script:AcceptingRequests) {
        throw 'Initialize-CfCatalogueIndex must run before the request loop starts accepting connections - a refactor moved this call past that point without updating it.'
    }

    $loaded = Load-CfCatalogueIndexFromDisk
    $stale = $true
    if ($loaded -and $Script:CfCatalogueFetchedAt) {
        try {
            $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
            $fetched = [DateTime]::ParseExact($Script:CfCatalogueFetchedAt, 'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture, $styles)
            $ageHours = ((Get-Date).ToUniversalTime() - $fetched).TotalHours
            $stale = ($ageHours -ge 24)
        } catch {
            $stale = $true
        }
    }
    if ($stale -and $Script:SkipCfCatalogueFetch) {
        # first-run-docs:fresh-install-startup-blocks-first-check (Round 36
        # fixer): test-mode escape hatch - see $Script:SkipCfCatalogueFetch's
        # own declaration/comment near the top of this file. Checked after
        # the disk-cache load above (harmless, no network) but before the
        # live fetch, so a test run still benefits from a real fixture cache
        # if one is present, but never pays for even one live
        # raw.githubusercontent.com request it did not ask for, and the
        # request loop never blocks past a test's own ping-wait deadline
        # waiting on a slow/throttled catalogue fetch.
        Write-ServerLog 'CurseForge catalogue refresh skipped at startup: FURPHY_TEST_SKIP_CF_CATALOGUE is set (test mode)'
    } elseif ($stale) {
        $result = Save-CfCatalogueIndex
        if (-not $result.ok) {
            Write-ServerLog "CurseForge catalogue index unavailable at startup (will retry on next restart or manual refresh): $($result.error)"
        }
    } else {
        Write-ServerLog "CurseForge catalogue loaded from disk cache: $($Script:CfCatalogueIndex.Count) entries, fetched $($Script:CfCatalogueFetchedAt)"
    }
}

function Search-CfCatalogue {
    <# Case-insensitive match against name: exact, then starts-with, then contains - each tier ordered by downloadCount descending. Returns at most $Limit entries. Never throws; empty on no index/no query/no match. #>
    param([string]$Query, [int]$Limit = 30)

    $out = New-Object 'System.Collections.Generic.List[object]'
    if ([string]::IsNullOrWhiteSpace($Query) -or -not $Script:CfCatalogueIndex -or $Script:CfCatalogueIndex.Count -eq 0) {
        return Write-Output -NoEnumerate $out.ToArray()
    }
    $needle = $Query.Trim().ToLowerInvariant()
    $scored = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in $Script:CfCatalogueIndex) {
        if (-not $e.name) { continue }
        $n = ([string]$e.name).ToLowerInvariant()
        $tier = -1
        if ($n -eq $needle) { $tier = 0 }
        elseif ($n.StartsWith($needle)) { $tier = 1 }
        elseif ($n.Contains($needle)) { $tier = 2 }
        if ($tier -ge 0) {
            $scored.Add([PSCustomObject]@{ Tier = $tier; Entry = $e; Downloads = [double]$e.downloadCount })
        }
    }
    $sorted = $scored | Sort-Object -Property Tier, @{ Expression = 'Downloads'; Descending = $true }
    foreach ($s in $sorted) {
        if ($out.Count -ge $Limit) { break }
        $out.Add($s.Entry)
    }
    return Write-Output -NoEnumerate $out.ToArray()
}

function Get-CfCatalogueEntry {
    <# O(1) lookup by CurseForge project id (string or number, compared as a string). $null when not indexed. #>
    param($ProjectId)
    if (-not $ProjectId) { return $null }
    $key = [string]$ProjectId
    if ($Script:CfCatalogueById.ContainsKey($key)) { return $Script:CfCatalogueById[$key] }
    return $null
}

function Get-CfCatalogueEntryBySlug {
    <#
      E19: exact, case-insensitive slug match against the same keyless
      catalogue index /api/cf/browse and Get-CfCatalogueEntry already use -
      the job kind 'add-by-slug' (the native host's CurseForge-tab install-
      link interception, host\FurphyHost.cs HandleSlugInstall) resolves a
      curseforge.com URL slug to a projectId through this before behaving
      like a normal 'add'. Linear scan (a few thousand entries, called at
      most once per add-by-slug job - never per-request, so no separate
      slug index is worth maintaining). $null when not found, the index is
      empty, or Slug is blank.
    #>
    param([string]$Slug)
    if ([string]::IsNullOrWhiteSpace($Slug)) { return $null }
    foreach ($e in $Script:CfCatalogueIndex) {
        if ($e.slug -and ([string]$e.slug).Equals($Slug, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $e
        }
    }
    return $null
}

function ConvertFrom-DevalueJson {
    <#
      addon-radar.com's __data.json responses are SvelteKit's "devalue" wire
      format, not plain JSON: a flat array where a value's fields can be
      integers that are themselves indices back into that SAME array (so a
      repeated/nested value only appears once in the payload). This is a
      purpose-built index-walking decoder.

      VERIFIED LIVE (this build) against both
      https://addon-radar.com/addon/{slug}/__data.json and
      https://addon-radar.com/search/__data.json: the JSON root is NOT the
      flat devalue array itself - it is a SvelteKit envelope object,
      {"type":"data","nodes":[null,{"type":"data","data":[<flat array>]}]}.
      "nodes" holds one entry per matched route segment (an earlier segment
      with no load function contributes $null); the real flat devalue array
      to index into is the "data" array carried by the last node that has
      one (the deepest/most specific route segment - the page itself). This
      function unwraps to that array before resolving any index. If the
      root does not look like that envelope (no PSCustomObject/'nodes', or
      no node carries a 'data' array) it falls back to treating the parsed
      root itself as the flat array, for resilience against a differently-
      shaped payload.

      Beyond the envelope unwrap, the exact field names inside the
      resolved objects were only spot-checked (id/name/slug/etc.) so
      callers (ConvertTo-AddonRadarDetail, Get-AddonRadarSearchRows) still
      treat the result defensively rather than assuming every field is
      present. Given the resolved flat array, this resolves every integer
      field/array-element that IS a valid in-range index into the node it
      points to, recursively, with cycle protection. A field that is
      genuinely just small integer DATA (not a reference) cannot be told
      apart from a real index by shape alone, so a value out of range (or
      inside the wrong array) is always left as literal data rather than
      guessed at.
      Never throws - returns $null on any parse failure or empty input.
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try {
        $parsed = $Text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
    if ($null -eq $parsed) { return $null }

    # Unwrap the SvelteKit {type,nodes:[...]} envelope to the real flat
    # devalue array (the 'data' array of the last node that carries one)
    # before any index resolution - see the function comment above.
    $arr = $null
    if (($parsed -is [System.Management.Automation.PSCustomObject]) -and ($parsed.PSObject.Properties.Name -contains 'nodes') -and $parsed.nodes) {
        foreach ($node in @($parsed.nodes)) {
            if ($node -and ($node.PSObject.Properties.Name -contains 'data') -and ($node.data -is [System.Array])) {
                $arr = @($node.data)
            }
        }
    }
    if (-not $arr) { $arr = @($parsed) }
    if ($arr.Count -eq 0) { return $null }

    $cache = @{}
    $resolving = New-Object 'System.Collections.Generic.HashSet[int]'

    function Resolve-DevalueValue {
        param($Node)
        if ($null -eq $Node) { return $null }
        if ($Node -is [System.Management.Automation.PSCustomObject]) {
            $result = [PSCustomObject]@{}
            foreach ($p in $Node.PSObject.Properties) {
                Add-Member -InputObject $result -NotePropertyName $p.Name -NotePropertyValue (Resolve-DevalueField -Value $p.Value)
            }
            return $result
        }
        if ($Node -is [System.Array]) {
            $out = New-Object 'System.Collections.Generic.List[object]'
            foreach ($item in $Node) { $out.Add((Resolve-DevalueField -Value $item)) }
            return Write-Output -NoEnumerate $out.ToArray()
        }
        return $Node
    }

    function Resolve-DevalueField {
        param($Value)
        # ConvertFrom-Json on Windows PowerShell 5.1 (.NET Framework, not
        # .NET 7+) deserializes a JSON integer as Int32/Int64 and only falls
        # back to Double for a value that overflows Int64 or carries a
        # fractional/exponent part - neither of which is a plausible devalue
        # array index - so only the integer types are ever treated as a
        # reference here; a genuine Double is always literal data.
        if ($Value -is [int] -or $Value -is [long]) {
            $i = [int]$Value
            if ($i -ge 0 -and $i -lt $arr.Count) { return (Resolve-DevalueIndex -Idx $i) }
            return $Value
        }
        return (Resolve-DevalueValue -Node $Value)
    }

    function Resolve-DevalueIndex {
        param([int]$Idx)
        if ($cache.ContainsKey($Idx)) { return $cache[$Idx] }
        if ($Idx -lt 0 -or $Idx -ge $arr.Count) { return $null }
        if ($resolving.Contains($Idx)) { return $null }   # cycle guard
        [void]$resolving.Add($Idx)
        $value = Resolve-DevalueValue -Node $arr[$Idx]
        [void]$resolving.Remove($Idx)
        $cache[$Idx] = $value
        return $value
    }

    return (Resolve-DevalueIndex -Idx 0)
}

function ConvertTo-AddonRadarDetail {
    <#
      Normalizes a devalue-decoded addon-radar.com detail payload into
      {id,name,slug,summary,descriptionHtml,authorName,logoUrl,downloadCount,
      gameVersions,lastUpdated,screenshots}. Round 9: a real captured
      /addon/{slug}/__data.json payload (catalogue-probe\bigwigs-data.json)
      showed the resolved root is a stats wrapper -
      {addon:<detail object>, dailyHistory, hourlyHistory, rankHistory,
      relatedAddons, authorAddons, dataHints} - with every field this
      function reads (id/name/slug/summary/description_html/screenshots/...)
      one level down, under .addon; the un-probed root has none of those
      names, so every real response fell through to the null/"unrecognized
      payload shape" case (confirmed against the diagnostics disk cache,
      cache\addon-radar\bigwigs.json, which held a cached $null detail from
      exactly this miss). .addon is checked first as the now-verified real
      shape; the decoded value itself, then .data, then .props, then
      .result remain as defensive fallbacks for a differently-shaped
      response, still returning $null (a total miss, handled by the caller
      falling through to catalogue-only) rather than guessing wrong. Never
      throws.
    #>
    param($Decoded)

    if ($null -eq $Decoded) { return $null }

    $candidate = $null
    foreach ($probe in @($Decoded.addon, $Decoded, $Decoded.data, $Decoded.props, $Decoded.result)) {
        if (-not $probe) { continue }
        $names = $probe.PSObject.Properties.Name
        if ($names -contains 'slug' -or $names -contains 'id') { $candidate = $probe; break }
    }
    if (-not $candidate) { return $null }

    $shots = New-Object 'System.Collections.Generic.List[object]'
    if ($candidate.screenshots) {
        foreach ($s in @($candidate.screenshots)) {
            $thumb = $s.thumbnail_url
            if (-not $thumb) { $thumb = $s.thumbnailUrl }
            $full = $s.url
            if (-not $full) { $full = $s.image }
            $shots.Add([PSCustomObject]@{ id = $s.id; title = $s.title; description = $s.description; thumbnail = $thumb; url = $full })
        }
    }
    $gameVersions = New-Object 'System.Collections.Generic.List[object]'
    if ($candidate.game_versions) { foreach ($v in @($candidate.game_versions)) { $gameVersions.Add([string]$v) } }

    return [PSCustomObject]@{
        id              = $candidate.id
        name            = $candidate.name
        slug            = $candidate.slug
        summary         = $candidate.summary
        descriptionHtml = $candidate.description_html
        authorName      = $candidate.author_name
        logoUrl         = $candidate.logo_url
        downloadCount   = $candidate.download_count
        gameVersions    = $gameVersions.ToArray()
        lastUpdated     = $candidate.last_updated_at
        screenshots     = $shots.ToArray()
    }
}

function Get-AddonRadarSearchRows {
    <#
      Defensively finds the results array within a devalue-decoded search
      payload - SPEC describes the shape as reachable via the decoded
      root's own .results.data path; a couple of other plausible roots are
      also tried since this build could not verify a live payload (see
      ConvertFrom-DevalueJson's own note). Never throws - empty array on
      any shape it doesn't recognize.
    #>
    param($Decoded)

    $out = New-Object 'System.Collections.Generic.List[object]'
    if ($null -eq $Decoded) { return Write-Output -NoEnumerate $out.ToArray() }

    foreach ($c in @($Decoded.results, $Decoded.data, $Decoded)) {
        if (-not $c) { continue }
        $arr = $null
        if ($c.data) { $arr = $c.data }
        elseif ($c -is [System.Array]) { $arr = $c }
        if ($arr) {
            foreach ($row in @($arr)) {
                if ($row -and ($row.PSObject.Properties.Name -contains 'slug')) { $out.Add($row) }
            }
            if ($out.Count -gt 0) { break }
        }
    }
    return Write-Output -NoEnumerate $out.ToArray()
}

function Invoke-AddonRadarRequest {
    <# Paced (>=600ms between live requests) + retry-once-on-429/503 GET, mirroring Invoke-WagoHttpRequest's shape - same generic Get-WagoExceptionStatusCode helper (despite its Wago-specific name) reused here since both proxies live in this same process/file. #>
    param([Parameter(Mandatory = $true)][string]$Uri)

    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'
    $elapsed = ((Get-Date) - $Script:LastAddonRadarRequestTime).TotalMilliseconds
    if ($elapsed -lt 600) {
        Start-Sleep -Milliseconds ([int](600 - $elapsed))
    }

    $maxAttempts = 2
    $attempt = 0
    $lastError = $null
    $result = $null
    while ($attempt -lt $maxAttempts) {
        $attempt++
        $shouldRetry = $false
        $lastError = $null
        try {
            $result = Invoke-WebRequest -Uri $Uri -Headers @{ 'Accept' = 'application/json' } -UserAgent $userAgent -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        } catch {
            $lastError = $_
            $statusCode = Get-WagoExceptionStatusCode -ErrorRecord $_
            if (($statusCode -eq 429 -or $statusCode -eq 503) -and ($attempt -lt $maxAttempts)) {
                Write-ServerLog "HTTP $statusCode from $Uri (addon-radar) - waiting 5 seconds and retrying"
                $shouldRetry = $true
            }
        }
        $Script:LastAddonRadarRequestTime = Get-Date
        if (-not $lastError) { return $result }
        if (-not $shouldRetry) { throw $lastError }
        Start-Sleep -Seconds 5
    }
    if ($lastError) { throw $lastError }
    return $result
}

function Get-AddonRadarDetail {
    <#
      addon-radar.com's per-addon detail (capability source #3, behind
      Wago, for descriptions/logos/screenshots). Cached both in-memory
      ($Script:AddonRadarCache) and on disk (ROOT\cache\addon-radar\
      <slug>.json) for 24h - checked before any live request, which is what
      keeps live addon-radar traffic bounded to first-time-viewed addons
      rather than growing with catalogue size or repeat views. Returns a
      normalized PSCustomObject (see ConvertTo-AddonRadarDetail) or $null
      (missing/unreachable/undecodable, INCLUDING a definitive miss - which
      is cached too, so a Wago-less/unmatched addon is not re-fetched on
      every drawer open). Never throws.
    #>
    param([Parameter(Mandatory = $true)][string]$Slug)

    $slugKey = $Slug.ToLowerInvariant()
    if ($Script:AddonRadarCache.ContainsKey($slugKey)) {
        $entry = $Script:AddonRadarCache[$slugKey]
        if (((Get-Date) - $entry.Time).TotalHours -lt 24) { return $entry.Detail }
    }

    $diskPath = Join-Path -Path $Script:AddonRadarCacheDir -ChildPath ($slugKey + '.json')
    if (Test-Path -LiteralPath $diskPath) {
        try {
            $raw = Get-Content -LiteralPath $diskPath -Raw -Encoding UTF8 -ErrorAction Stop
            $cached = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($cached.fetchedAt) {
                $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
                $fetched = [DateTime]::ParseExact([string]$cached.fetchedAt, 'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture, $styles)
                if (((Get-Date).ToUniversalTime() - $fetched).TotalHours -lt 24) {
                    $detail = $cached.detail
                    $Script:AddonRadarCache[$slugKey] = @{ Time = (Get-Date); Detail = $detail }
                    return $detail
                }
            }
        } catch {
            # Corrupt/unreadable disk cache entry - fall through to a live fetch.
        }
    }

    $detail = $null
    try {
        $uri = 'https://addon-radar.com/addon/' + [System.Uri]::EscapeDataString($Slug) + '/__data.json'
        $resp = Invoke-AddonRadarRequest -Uri $uri
        $decoded = ConvertFrom-DevalueJson -Text $resp.Content
        $detail = ConvertTo-AddonRadarDetail -Decoded $decoded
    } catch {
        Write-ServerLog "addon-radar detail fetch failed for slug '$Slug': $($_.Exception.Message)"
        $detail = $null
    }

    $Script:AddonRadarCache[$slugKey] = @{ Time = (Get-Date); Detail = $detail }
    try {
        if (-not (Test-Path -LiteralPath $Script:AddonRadarCacheDir)) {
            New-Item -ItemType Directory -Path $Script:AddonRadarCacheDir -Force | Out-Null
        }
        $cacheBody = [PSCustomObject]@{ fetchedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); detail = $detail }
        $json = ConvertTo-Json -InputObject $cacheBody -Depth 8
        $tmpPath = "$diskPath.tmp"
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
        Move-Item -LiteralPath $tmpPath -Destination $diskPath -Force
    } catch {
        Write-ServerLog "Failed to write addon-radar disk cache for slug '$Slug': $($_.Exception.Message)"
    }

    return $detail
}

function Search-AddonRadar {
    <#
      Free-text addon-radar.com search - supplemental to the offline
      catalogue when it returns few/no hits for a query (Handle-CfBrowse's
      own threshold). NOT an id lookup - SPEC's own verified facts warn
      against ever treating result #1 as authoritative for a specific known
      id; this is for free-text discovery only. Cached 24h per lowercased
      query, in-memory only. Never throws - empty array on any failure.
    #>
    param([string]$Query, [int]$Limit = 30)

    $out = New-Object 'System.Collections.Generic.List[object]'
    if ([string]::IsNullOrWhiteSpace($Query)) { return Write-Output -NoEnumerate $out.ToArray() }

    $cacheKey = $Query.Trim().ToLowerInvariant()
    if ($Script:AddonRadarSearchCache.ContainsKey($cacheKey)) {
        $entry = $Script:AddonRadarSearchCache[$cacheKey]
        if (((Get-Date) - $entry.Time).TotalHours -lt 24) {
            foreach ($it in @($entry.Items)) {
                if ($out.Count -ge $Limit) { break }
                $out.Add($it)
            }
            return Write-Output -NoEnumerate $out.ToArray()
        }
    }

    $normalizedItems = New-Object 'System.Collections.Generic.List[object]'
    try {
        $uri = 'https://addon-radar.com/search/__data.json?q=' + [System.Uri]::EscapeDataString($Query)
        $resp = Invoke-AddonRadarRequest -Uri $uri
        $decoded = ConvertFrom-DevalueJson -Text $resp.Content
        $rows = Get-AddonRadarSearchRows -Decoded $decoded
        foreach ($row in $rows) {
            $normalizedItems.Add([PSCustomObject]@{
                id            = $row.id
                name          = $row.name
                slug          = $row.slug
                downloadCount = $row.download_count
                lastUpdated   = $row.last_updated_at
                logoUrl       = $row.logo_url
            })
        }
    } catch {
        Write-ServerLog "addon-radar search failed for '$Query': $($_.Exception.Message)"
    }

    $Script:AddonRadarSearchCache[$cacheKey] = @{ Time = (Get-Date); Items = $normalizedItems.ToArray() }

    foreach ($it in $normalizedItems) {
        if ($out.Count -ge $Limit) { break }
        $out.Add($it)
    }
    return Write-Output -NoEnumerate $out.ToArray()
}

function Get-WagoAutoMatchNormalizedName {
    <# Lowercased, trimmed, with a trailing parenthetical/subtitle stripped (e.g. "BigWigs (Boss Timers & Tools)" -> "bigwigs") so a Wago listing's own subtitle style doesn't defeat an otherwise-exact name match. #>
    param([string]$Value)
    if (-not $Value) { return '' }
    $v = [regex]::Replace($Value, '\s*\([^)]*\)\s*$', '')
    return $v.Trim().ToLowerInvariant()
}

function Get-WagoAutoMatch {
    <#
      A conservative "is this CurseForge-tracked addon also on Wago"
      probe, used only when the record's own toc has no X-Wago-ID tag at
      all (Get-CfEnrichmentNoKey's caller-side guard). Reuses E12's own
      Wago search/detail machinery (Get-WagoCached) rather than duplicating
      it. A candidate is accepted ONLY when its search-card name equals the
      queried name case-insensitively (trailing parenthetical stripped on
      both sides) AND at least one of its detail page's developer names
      equals (or is a substring, either direction, of) the queried author
      case-insensitively - never on name similarity alone, never assuming
      result #1 is the match, per SPEC's verified matching rule. Result
      (including a definitive miss) cached 24h per (game_version,name,author)
      triple - game_version resolves from the CURRENT request's flavour via
      Get-CfFlavourMapping, same as Handle-WagoBrowse.
      Returns @{ slug } or $null. Never throws.
    #>
    param([string]$Name, [string]$Author)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }

    # multi-client:wago-automatch-hardcoded-retail-game-version - this
    # probe used to search Wago's game_version=retail catalog
    # unconditionally, even though $rec (the caller's tracked record) is
    # already resolved from the CURRENT flavour's own addons.json
    # (Get-AddonRecords is flavour-scoped). Under classic/classic_era that
    # meant a CurseForge-tracked addon legitimately listed on Wago under a
    # non-Retail game_version, with no toc X-Wago-ID tag, could never be
    # found - "also on Wago" enrichment silently stayed empty for it, while
    # the identical addon under Retail worked fine. Resolve the same way
    # Handle-WagoBrowse already does instead of hardcoding 'retail' - byte-
    # identical result on a Retail-only/Retail-active machine.
    $wagoMapping = Get-CfFlavourMapping -Flavor $Script:CurrentFlavour -InstalledInterface $Script:ClientBuildInfo.clientInterface
    $wagoGameVersion = $wagoMapping.WagoField
    if (-not $wagoGameVersion) { $wagoGameVersion = 'retail' }

    # Fold the resolved game_version into the cache key too - otherwise a
    # cache entry seeded under one flavour's game_version would wrongly
    # answer a later lookup for the same (name, author) pair under a
    # different flavour.
    $cacheKey = $wagoGameVersion + '|' + $Name.Trim().ToLowerInvariant() + '|' + (([string]$Author).Trim().ToLowerInvariant())
    if ($Script:WagoAutoMatchCache.ContainsKey($cacheKey)) {
        $entry = $Script:WagoAutoMatchCache[$cacheKey]
        if (((Get-Date) - $entry.Time).TotalHours -lt 24) { return $entry.Match }
    }

    $match = $null
    try {
        $uri = $Script:WagoBaseUrl + '/?game_version=' + [System.Uri]::EscapeDataString($wagoGameVersion) + '&search=' + [System.Uri]::EscapeDataString($Name)
        $props = Get-WagoCached -PageUri $uri
        $normName = Get-WagoAutoMatchNormalizedName -Value $Name
        if ($props -and $props.addons -and $props.addons.data) {
            foreach ($cardHtml in @($props.addons.data)) {
                $card = ConvertFrom-WagoSearchCardHtml -Html ([string]$cardHtml)
                if (-not $card -or -not $card.name) { continue }
                if ((Get-WagoAutoMatchNormalizedName -Value $card.name) -ne $normName) { continue }
                try {
                    $detailProps = Get-WagoCached -PageUri ($Script:WagoBaseUrl + '/addons/' + [System.Uri]::EscapeDataString($card.slug))
                    $authorOk = [string]::IsNullOrWhiteSpace($Author)
                    if (-not $authorOk -and $detailProps -and $detailProps.metadata -and $detailProps.metadata.developers) {
                        $authorLower = $Author.ToLowerInvariant()
                        foreach ($dev in @($detailProps.metadata.developers)) {
                            if (-not $dev.name) { continue }
                            $devLower = ([string]$dev.name).ToLowerInvariant()
                            if ($devLower.Contains($authorLower) -or $authorLower.Contains($devLower)) { $authorOk = $true; break }
                        }
                    }
                    if ($authorOk) { $match = [PSCustomObject]@{ slug = $card.slug }; break }
                } catch {
                    # Could not confirm this one candidate's author - try the next, if any.
                }
            }
        }
    } catch {
        Write-ServerLog "Wago auto-match search failed for '$Name': $($_.Exception.Message)"
    }

    $Script:WagoAutoMatchCache[$cacheKey] = @{ Time = (Get-Date); Match = $match }
    return $match
}

function Get-CfEnrichmentNoKey {
    <#
      The keyless fallback chain behind GET /api/cf/enrich/{projectId} -
      the only chain there is, now that Round 16 (E22) removed the
      key-gated official-API path this used to try first: (1) a Wago
      match - the tracked record's own toc-derived wagoId first, else
      (only when there is none at all) a conservative Get-WagoAutoMatch
      probe; (2) addon-radar.com, via the catalogue-resolved slug; (3)
      catalogue-only (or nothing at all, for an id neither catalogue has
      and no Wago match). Never
      throws - every branch already degrades to the next on its own
      failure, and this function's own try/catch around the Wago path
      guards against a live network hiccup there specifically.
    #>
    param([string]$ProjectId)

    $records = Get-AddonRecords
    $rec = $null
    foreach ($r in $records) {
        if ($r.projectId -and ([string]$r.projectId -eq $ProjectId)) { $rec = $r; break }
    }

    $catalogueEntry = Get-CfCatalogueEntry -ProjectId $ProjectId

    # GAME-MODE-SPEC.md (2026-09-08): this used to skip both live-network
    # branches below (Wago-match, addon-radar) while a WoW client was
    # running, falling straight through to the catalogue-only/memory-and-
    # disk-only fallback (step 3). That gate is dropped - per-addon
    # enrichment always attempts a live/cached lookup now, same as every
    # other addon/browse/update path in this file.

    # 1) Wago match.
    $wagoRef = $null
    if ($rec -and $rec.wagoId) {
        $wagoRef = [string]$rec.wagoId
    } elseif ($rec -and $rec.name) {
        $auto = Get-WagoAutoMatch -Name $rec.name -Author $rec.author
        if ($auto) { $wagoRef = $auto.slug }
    }
    if ($wagoRef) {
        try {
            $props = Get-WagoCached -PageUri ($Script:WagoBaseUrl + '/addons/' + [System.Uri]::EscapeDataString($wagoRef))
            if ($props -and $props.addon) {
                $downloadCount = $null
                $lastUpdated = $null
                if ($props.metadata) { $downloadCount = $props.metadata.download_count; $lastUpdated = $props.metadata.last_update }
                return [PSCustomObject]@{
                    source          = 'wago-match'
                    name            = $props.addon.display_name
                    slug            = $props.addon.slug
                    summary         = $props.addon.summary
                    descriptionMarkdown = $props.description
                    logoUrl         = $props.addon.thumbnail_image
                    screenshots     = @()
                    downloadCount   = $downloadCount
                    lastUpdated     = $lastUpdated
                    gameVersions    = @()
                    wagoSlug        = $props.addon.slug
                }
            }
        } catch {
            Write-ServerLog "Wago-match lookup failed for project $ProjectId (ref '$wagoRef'): $($_.Exception.Message)"
        }
    }

    # 2) addon-radar.com, via the catalogue-resolved slug.
    if ($catalogueEntry -and $catalogueEntry.slug) {
        $detail = Get-AddonRadarDetail -Slug ([string]$catalogueEntry.slug)
        if ($detail) {
            return [PSCustomObject]@{
                source          = 'addon-radar'
                name            = $detail.name
                slug            = $detail.slug
                summary         = $detail.summary
                descriptionHtml = $detail.descriptionHtml
                logoUrl         = $detail.logoUrl
                screenshots     = $detail.screenshots
                downloadCount   = $detail.downloadCount
                lastUpdated     = $detail.lastUpdated
                gameVersions    = $detail.gameVersions
            }
        }
    }

    # 3) catalogue-only, or nothing at all.
    $name = $null
    if ($rec -and $rec.name) { $name = $rec.name } elseif ($catalogueEntry -and $catalogueEntry.name) { $name = $catalogueEntry.name }
    $downloadCount = $null
    $lastUpdated = $null
    $slug = $null
    if ($catalogueEntry) { $downloadCount = $catalogueEntry.downloadCount; $lastUpdated = $catalogueEntry.lastUpdated; $slug = $catalogueEntry.slug }
    return [PSCustomObject]@{
        source        = 'catalogue-only'
        name          = $name
        slug          = $slug
        summary       = $null
        downloadCount = $downloadCount
        lastUpdated   = $lastUpdated
        gameVersions  = @()
    }
}

function Handle-CfEnrich {
    <#
      GET /api/cf/enrich/{projectId} - keyless (the only CurseForge fetch
      path there is now, Round 16/E22 having removed the key-gated official-
      API mod/description proxy this used to try first). Walks
      Get-CfEnrichmentNoKey's fallback chain. Response shape:
      {source,name,slug,summary,descriptionHtml?,descriptionMarkdown?,
      logoUrl?,screenshots?[],downloadCount?,lastUpdated?,gameVersions?[],
      wagoSlug?}.
    #>
    param($Context, $RouteMatch)

    $id = $RouteMatch['id']
    $body = Get-CfEnrichmentNoKey -ProjectId $id
    Send-Json -Context $Context -StatusCode 200 -Body $body
}

function Handle-CfBrowse {
    <#
      GET /api/cf/browse?q=&limit= - keyless. Search-CfCatalogue runs
      first, and Search-AddonRadar is additionally consulted only when
      that returns fewer than 5 hits, merging in anything not already
      present by id (SPEC's own documented threshold).
    #>
    param($Context, $RouteMatch)

    $q = $Context.Request.QueryString
    $query = [string]$q['q']
    $limit = 30
    $limitRaw = Get-QueryOrDefault -QueryString $q -Name 'limit' -Default '30'
    $parsedLimit = 0
    if ([int]::TryParse($limitRaw, [ref]$parsedLimit) -and $parsedLimit -gt 0) { $limit = $parsedLimit }

    $items = New-Object 'System.Collections.Generic.List[object]'
    $seenIds = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($e in (Search-CfCatalogue -Query $query -Limit $limit)) {
        $items.Add([PSCustomObject]@{ id = $e.id; name = $e.name; slug = $e.slug; downloadCount = $e.downloadCount; lastUpdated = $e.lastUpdated; source = 'catalogue'; logoUrl = $null })
        [void]$seenIds.Add([string]$e.id)
    }

    if ($items.Count -lt 5 -and -not [string]::IsNullOrWhiteSpace($query)) {
        foreach ($r in (Search-AddonRadar -Query $query -Limit $limit)) {
            $ridStr = [string]$r.id
            if ($seenIds.Contains($ridStr)) { continue }
            $items.Add([PSCustomObject]@{ id = $r.id; name = $r.name; slug = $r.slug; downloadCount = $r.downloadCount; lastUpdated = $r.lastUpdated; source = 'addon-radar'; logoUrl = $r.logoUrl })
            [void]$seenIds.Add($ridStr)
        }
    }

    $body = [PSCustomObject]@{
        items        = $items.ToArray()
        catalogueAge = $Script:CfCatalogueFetchedAt
        total        = $items.Count
    }
    Send-Json -Context $Context -StatusCode 200 -Body $body
}

# Round 17 - removed: Handle-CfCatalogueRefresh (POST
# /api/cf/catalogue/refresh) and the "Refresh the addon list from
# CurseForge" button that was its only caller (Settings > Troubleshooting).
# Save-CfCatalogueIndex itself is unchanged and still called automatically
# at startup/once-per-24h by Initialize-CfCatalogueIndex - only the manual,
# on-demand trigger is gone.

# =====================================================================
# Diagnostics (E10) - GET /api/diagnostics: a fixed battery of quick health
# checks, each returning @{ ok; detail }. Every Test-Diag* function below is
# self-contained (its own try/catch, never throws), so Handle-Diagnostics
# itself needs no try/catch around any individual check - one bad check
# degrades to a single failed row, never a 500 for the whole endpoint.
# =====================================================================

function New-DiagCheckRow {
    param([string]$Name, [hashtable]$Result)
    return [PSCustomObject]@{ name = $Name; ok = [bool]$Result.ok; detail = [string]$Result.detail }
}

function Test-DiagAddonsFolder {
    <#
      AddOns path exists AND is writable - proven by creating and deleting a
      small temp file in it, not just a Test-Path (SPEC/roadmap: "AddOns path
      exists and writable (create+delete temp file)").
    #>
    $addonsPath = Resolve-EffectiveAddonsPath
    if (-not $addonsPath) {
        return @{ ok = $false; detail = 'AddOns path could not be resolved (not running from inside a _retail_\AddonSync install and no -AddonsPath override)' }
    }
    if (-not (Test-Path -LiteralPath $addonsPath -PathType Container)) {
        return @{ ok = $false; detail = "Does not exist: $addonsPath" }
    }
    $probeName = '.addonsync-diag-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
    $probePath = Join-Path -Path $addonsPath -ChildPath $probeName
    try {
        Set-Content -LiteralPath $probePath -Value 'diagnostic probe' -Encoding UTF8 -ErrorAction Stop
        Remove-Item -LiteralPath $probePath -Force -ErrorAction Stop
        return @{ ok = $true; detail = $addonsPath }
    } catch {
        return @{ ok = $false; detail = "Not writable: $($_.Exception.Message)" }
    } finally {
        if (Test-Path -LiteralPath $probePath) { try { Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue } catch { } }
    }
}

function Test-DiagSettingsJson {
    <# settings.json parses. A missing file is fine (Get-Settings creates it with defaults on next use) - only a PRESENT-but-corrupt file fails this check. #>
    if (-not (Test-Path -LiteralPath $Script:SettingsPath)) {
        return @{ ok = $true; detail = 'not yet created (defaults will be used)' }
    }
    try {
        # Get-Content is safe here: $raw only feeds ConvertFrom-Json below and
        # is discarded right after, never returned/serialized itself (see
        # Update-JobStatus for the pattern that actually is hazardous).
        $raw = Get-Content -LiteralPath $Script:SettingsPath -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @{ ok = $true; detail = 'empty (defaults will be used)' }
        }
        $raw | ConvertFrom-Json -ErrorAction Stop | Out-Null
        return @{ ok = $true; detail = 'valid' }
    } catch {
        return @{ ok = $false; detail = $_.Exception.Message }
    }
}

function Test-DiagAddonsJson {
    <# addons.json parses, plus the record count. Get-AddonRecords itself throws uncaught on corrupt JSON (see its own comments) - exactly the failure this check needs to surface. #>
    try {
        $records = Get-AddonRecords
        $count = $records.Count
        $label = '{0} record{1}' -f $count, $(if ($count -eq 1) { '' } else { 's' })
        return @{ ok = $true; detail = $label }
    } catch {
        return @{ ok = $false; detail = $_.Exception.Message }
    }
}

function Test-DiagCfReachability {
    <#
      One keyless CurseForge "files" request for project 1521253
      (BonusRollConfirm - SPEC.md's designated small test project), exactly
      as roadmap item E10 calls for. Headers/user-agent mirror addon-sync.ps1's
      Invoke-CfRequest (this script never dot-sources the CLI, so the few
      lines needed are duplicated here - the same pattern already used for
      Resolve-EffectiveAddonsPath/Get-PresentAddonFolders elsewhere in this
      file). Single attempt, no 403/429 retry: a transient block IS the
      "not reachable right now" signal this check exists to surface, not
      something to paper over with the retry a real sync's Invoke-CfRequest
      performs.
    #>
    $uri = 'https://www.curseforge.com/api/v1/mods/1521253/files?pageIndex=0&pageSize=1&sort=dateCreated&sortDescending=true&removeAlphas=true'
    $headers = @{ 'Accept' = 'application/json'; 'Referer' = 'https://www.curseforge.com/' }
    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'
    try {
        $resp = Invoke-WebRequest -Uri $uri -Headers $headers -UserAgent $userAgent -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        if ([int]$resp.StatusCode -eq 200) {
            return @{ ok = $true; detail = 'Reachable (HTTP 200)' }
        }
        return @{ ok = $false; detail = "HTTP $([int]$resp.StatusCode)" }
    } catch {
        $statusCode = 0
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = 0 }
        if ($statusCode -gt 0) {
            return @{ ok = $false; detail = "HTTP $statusCode" }
        }
        return @{ ok = $false; detail = $_.Exception.Message }
    }
}

function Test-DiagDiskSpace {
    <# Free disk space (GB) on the drive holding the AddOns folder (falls back to -Root's drive if that can't be resolved). Flags red under 1 GB free - not enough headroom for even a small addon download/extract. #>
    $path = Resolve-EffectiveAddonsPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { $path = $Script:Root }
    try {
        $driveRoot = [System.IO.Path]::GetPathRoot($path)
        $info = New-Object System.IO.DriveInfo($driveRoot)
        $freeGb = [math]::Round($info.AvailableFreeSpace / 1GB, 1)
        return @{ ok = ($freeGb -ge 1); detail = "$freeGb GB free on $driveRoot" }
    } catch {
        return @{ ok = $false; detail = $_.Exception.Message }
    }
}

function Test-DiagPowerShellVersion {
    <# This whole app requires Windows PowerShell 5.1 (SPEC.md's hard constraint) - flags red if somehow running under anything older. #>
    $v = $PSVersionTable.PSVersion
    $ok = ($v.Major -gt 5) -or ($v.Major -eq 5 -and $v.Minor -ge 1)
    return @{ ok = $ok; detail = $v.ToString() }
}

function Test-DiagServerUptime {
    param([double]$UptimeSeconds)
    $detail = $null
    if ($UptimeSeconds -lt 60) {
        $detail = "$([math]::Round($UptimeSeconds, 0))s"
    } elseif ($UptimeSeconds -lt 3600) {
        $detail = "$([math]::Floor($UptimeSeconds / 60))m"
    } else {
        $hours = [math]::Floor($UptimeSeconds / 3600)
        $mins = [math]::Floor(($UptimeSeconds % 3600) / 60)
        $detail = "${hours}h ${mins}m"
    }
    return @{ ok = $true; detail = $detail }
}

function Format-DiagTimestamp {
    <#
      Renders one of this script's own ISO-8601 UTC timestamps
      ("yyyy-MM-ddTHH:mm:ssZ", the format every $Script:LastRun.timestamp/
      startedAt/finishedAt already uses) as local-time human text, matching
      the convention every OTHER Test-Diag* check's detail already follows
      within this same endpoint - Server uptime's "2h 3m", CurseForge
      reachability's "Reachable (HTTP 200)" - finished display text, never
      raw data left for the client to reformat. Confirmed against ui\app.js:
      diagRow() renders c.detail verbatim with no date parsing of its own,
      unlike the addons table's Updated column (Utils.relativeTime), so an
      un-formatted ISO string here was the one diagnostics row showing raw
      machine-readable text next to eight rows of finished prose. Falls back
      to the raw input string on any parse failure - never throws, matching
      every Test-Diag* function's own no-throw contract.
    #>
    param([string]$Iso)

    try {
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        $dt = [DateTime]::ParseExact($Iso, 'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        return $dt.ToLocalTime().ToString('MMM d, yyyy, hh:mm tt')
    } catch {
        return $Iso
    }
}

function Test-DiagLastSync {
    <#
      Timestamp of the most recent completed sync, read from last-run.txt's
      own mtime (written by addon-sync.ps1 on every non-DryRun run, whether
      run through this server or manually) - a more universal signal than
      $Script:LastRun, which only ever
      reflects a job run through THIS server instance. Falls back to
      $Script:LastRun.timestamp (in-memory, or reloaded from state.json at
      startup) when last-run.txt is not there yet, then to "never".
    #>
    $lastRunPath = Join-Path -Path $Script:Root -ChildPath 'last-run.txt'
    if (Test-Path -LiteralPath $lastRunPath) {
        try {
            $mtime = (Get-Item -LiteralPath $lastRunPath).LastWriteTimeUtc
            return @{ ok = $true; detail = $mtime.ToLocalTime().ToString('MMM d, yyyy, hh:mm tt') }
        } catch {
            return @{ ok = $false; detail = $_.Exception.Message }
        }
    }
    $lastRun = Get-FlavourLastRun -Flavor $Script:CurrentFlavour
    if ($lastRun -and $lastRun.timestamp) {
        return @{ ok = $true; detail = (Format-DiagTimestamp -Iso ([string]$lastRun.timestamp)) }
    }
    return @{ ok = $true; detail = 'never' }
}

function Test-DiagClientBuild {
    <#
      E13: reports whatever $Script:ClientBuildInfo resolved at startup (from
      .build.info, or -BuildInfoPath's override) - ok:false with an
      explanatory detail when it could not be read, so a missing/unreadable
      .build.info shows up as a visible diagnostic instead of every addon
      silently reporting compat "unknown" with no obvious cause.
    #>
    if ($Script:ClientBuildInfo -and $Script:ClientBuildInfo.clientBuild) {
        return @{ ok = $true; detail = $Script:ClientBuildInfo.clientBuild }
    }
    return @{ ok = $false; detail = 'Could not read .build.info (missing, unreadable, or no "wow" row found)' }
}

function Test-DiagCfCatalogue {
    <#
      E16: the offline CurseForge catalogue index (instawow-data +
      strongbox-catalogue) that /api/cf/browse and /api/cf/enrich fall back
      to when no key is configured. ok:false when never fetched at all
      (fresh install, or every fetch attempt has failed so far) or when the
      on-disk copy is over 48h stale (double the normal 24h refresh window -
      a generous allowance before flagging red, since a single missed daily
      refresh is not itself a problem).
    #>
    if (-not $Script:CfCatalogueFetchedAt) {
        return @{ ok = $false; detail = 'No catalogue cache yet (fetched automatically on first use)' }
    }
    $ageHours = $null
    try {
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        $fetched = [DateTime]::ParseExact($Script:CfCatalogueFetchedAt, 'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        $ageHours = ((Get-Date).ToUniversalTime() - $fetched).TotalHours
    } catch {
        return @{ ok = $false; detail = "Cache timestamp unreadable ($Script:CfCatalogueFetchedAt)" }
    }
    $count = 0
    if ($Script:CfCatalogueIndex) { $count = $Script:CfCatalogueIndex.Count }
    $detail = "$count entries, $([math]::Round($ageHours, 1))h old ($Script:CfCatalogueSource)"
    return @{ ok = ($ageHours -lt 48); detail = $detail }
}

function Test-DiagAddonRadar {
    <#
      E16: one cheap, cached-if-possible addon-radar.com request - the same
      allowance E10 already gives CurseForge's own reachability check.
      "bigwigs" is a real, small, always-present addon-radar slug (SPEC's
      own verified facts were gathered against it) so a cache hit from an
      earlier drawer/browse view is common; a cold cache pays one live
      request, paced/retried exactly like every other Get-AddonRadarDetail
      call.
    #>
    try {
        $detail = Get-AddonRadarDetail -Slug 'bigwigs'
        if ($detail) { return @{ ok = $true; detail = 'Reachable' } }
        return @{ ok = $false; detail = 'No response or unrecognized payload shape' }
    } catch {
        return @{ ok = $false; detail = $_.Exception.Message }
    }
}

function Get-QueryOrDefault {
    param($QueryString, [string]$Name, [string]$Default)

    $v = $QueryString[$Name]
    if ([string]::IsNullOrEmpty($v)) { return $Default }
    return $v
}

function Open-InBrowser {
    param([string]$Url)

    $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
    if (Test-Path -LiteralPath $edgePath) {
        Start-Process -FilePath $edgePath -ArgumentList $Url
    } else {
        Start-Process $Url
    }
}

function Open-CfSideWindow {
    <#
      Round 12 (E19b): the 'cf-window' /api/open target's Edge-app fallback
      path - opens $Url in a chromeless Edge window beside this app, rather
      than a normal browser tab (Open-InBrowser above) or the native host's
      embedded CurseForge tab (which, when present, ui\app.js's
      Host.openCurseForge intercepts before this endpoint is ever reached -
      see SPEC.md's E19b). Same msedge.exe path + Test-Path/Start-Process
      fallback as Open-InBrowser and the $OpenBrowser startup block further
      down this file - there is no registry/App Paths lookup anywhere in
      this codebase (grepped addon-server.ps1, Addon Manager.vbs and
      curseforge-handler.vbs; all three hardcode this same default-install
      path) to reuse instead.
    #>
    param([string]$Url)

    # Adversarial-review fix (round 2): the first fix here only rejected
    # '"'/CR/LF, but Windows PowerShell 5.1's Start-Process -ArgumentList
    # does NOT quote each array element - it joins them with a plain SPACE
    # before CreateProcess sees them, so a literal space in $Url (e.g.
    # "https://www.curseforge.com/x --app=http://evil.example/phish") also
    # splits into extra msedge.exe argv tokens and defeats the
    # curseforge.com-only allowlist, exactly like the quote/CRLF case.
    # Blocklisting characters is fragile (whatever's missed next is the
    # next bypass), so validate structurally instead: parse $Url as an
    # absolute URI and require scheme https + host www.curseforge.com
    # (case-insensitive), then rebuild the msedge.exe argument from the
    # PARSED $parsedUri.AbsoluteUri, never from the raw client string -
    # AbsoluteUri is guaranteed free of spaces/quotes/control characters
    # (Uri encodes them), so it cannot inject additional argv tokens
    # regardless of what the caller sent.
    $parsedUri = $null
    $isValid = [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$parsedUri)
    if (-not $isValid -or
        $parsedUri.Scheme -ne 'https' -or
        -not $parsedUri.Host.Equals('www.curseforge.com', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-ServerLog "Open-CfSideWindow: rejected url that failed structural validation"
        return $false
    }
    $safeUrl = $parsedUri.AbsoluteUri

    $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
    if (Test-Path -LiteralPath $edgePath) {
        Start-Process -FilePath $edgePath -ArgumentList @("--app=$safeUrl", '--window-size=1100,900')
    } else {
        Start-Process $safeUrl
    }
    return $true
}

# =====================================================================
# Route handlers
# =====================================================================

function Handle-Ping {
    param($Context, $RouteMatch)

    $uptime = ((Get-Date) - $Script:StartTime).TotalSeconds
    # E19: $Script:HostKind starts 'edge-app' and flips (stickily - see
    # Invoke-Route's static-file branch) to 'webview2' the moment a GET / or
    # GET /index.html arrives with ?host=webview2, which only
    # host\FurphyHost.cs's Furphy-tab navigation ever sends.
    # P1 perf pass (item 1): cheap, cached signal for a caller (the SPA's
    # poll loop, the native host's window) to gate its own work on, same
    # cache Test-GameRunning already uses server-side.
    Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true; name = $Script:AppName; version = $Script:Version; uptime = [math]::Round($uptime, 1); host = $Script:HostKind; gameRunning = (Test-GameRunning) }
}

function Get-HandleStateCacheKey {
    <#
      Round 37 (server perf pass): the fingerprint Handle-State compares
      against $Script:AddonExtrasCacheByFlavour[$Flavor].Key to decide
      whether its cached tocInterfaces/compat/missingDeps/missingOptionalDeps
      are still good, or need recomputing. Combines:
        - -Flavor itself (a Classic Era cache entry must never be reused for
          Retail, or vice versa);
        - the records file's (addons.json) own LastWriteTimeUtc + Length -
          any job completion, install, remove, ignore/unpin, or hand-edit
          that changes a record's folders/requiredDeps/optionalDeps/
          latestGameVersions changes this too, since all of those rewrite
          the whole file;
        - -AddonsFingerprint (Get-AddonsFolderSnapshot's own .Fingerprint) -
          changes whenever the AddOns folder's own contents change, which
          every install/remove/rescan does;
        - -ClientBuildInfo's clientBuild/clientInterface - a different
          client build changes Get-AddonCompat's own answer for every
          record even when nothing else did.
      Never throws; a missing/unreadable addons.json becomes the fixed
      string "missing"/"error" rather than propagating a real Length/Ticks
      value - still a stable, comparable fingerprint segment either way.
    #>
    param([string]$Flavor, [string]$AddonsFingerprint, $ClientBuildInfo)

    $recordsFp = 'missing'
    if (Test-Path -LiteralPath $Script:AddonsJsonPath -PathType Leaf) {
        try {
            $fi = Get-Item -LiteralPath $Script:AddonsJsonPath -ErrorAction Stop
            $recordsFp = "$($fi.LastWriteTimeUtc.Ticks):$($fi.Length)"
        } catch {
            $recordsFp = 'error'
        }
    }
    $build = [string]$ClientBuildInfo.clientBuild
    $iface = [string]$ClientBuildInfo.clientInterface
    return "$Flavor|$build|$iface|$recordsFp|$AddonsFingerprint"
}

function Clear-StateCache {
    <#
      Round 37 (server perf pass): drops Handle-State's per-flavour toc/
      compat/missingDeps cache. Get-HandleStateCacheKey's own mtime-based
      fingerprint already invalidates on its own for most mutations (every
      install/remove/rescan touches addons.json and/or the AddOns folder,
      both fingerprinted) - this explicit call exists anyway for the one
      class that does NOT: a settings change (part of this feature's own
      required invalidation list) touches neither path at all, so relying
      on the fingerprint alone would silently miss it. Calling this
      unconditionally at every one of this file's own mutation points (job
      completion, settings PUT, orphan-folder removal) is cheap - clearing
      an in-memory hashtable entry - and keeps every call site honest
      without each one having to reason about whether ITS OWN change
      happens to touch a fingerprinted path.
      -Flavor clears just one flavour's entry; omitted clears every
      flavour's (a settings change is machine-wide, not flavour-scoped).
    #>
    param([string]$Flavor)

    if ($Flavor) {
        $Script:AddonExtrasCacheByFlavour.Remove($Flavor)
    } else {
        $Script:AddonExtrasCacheByFlavour = @{}
    }
}

function Handle-State {
    param($Context, $RouteMatch)

    # APP-UPDATE-SPEC.md section 7: Handle-State is the one, verified,
    # "requires a window to be open" call site the "is a window open"
    # signal is stamped from - see Set-AppUpdateWindowOpenAt's own doc
    # comment for why this must NOT be a global per-request hook.
    Set-AppUpdateWindowOpenAt

    $flavor = $Script:CurrentFlavour
    if (-not $flavor) { $flavor = 'retail' }
    $installedFlavours = Get-CurrentInstalledFlavours
    $updateAvailable = Get-FlavourUpdateAvailable -Flavor $flavor

    $records = Get-AddonRecords
    # E13: computed once and shared - each record's own toc parse still
    # happens per addon (on a cache miss - see below), but resolving the
    # AddOns path itself does not.
    $compatAddonsPath = Resolve-EffectiveAddonsPath -Flavor $flavor

    # Round 37 (server perf pass): the expensive part of this loop below
    # (tocInterfaces/compat/missingDeps/missingOptionalDeps - real disk I/O
    # per addon folder, measured at 900-1300ms for 34 addons) is cached
    # per-flavour, keyed on a cheap fingerprint (Get-HandleStateCacheKey)
    # that changes whenever addons.json or the AddOns folder's own contents
    # change - see that function's own doc comment, and
    # Get-AddonsFolderSnapshot's, for exactly what it hashes and why that is
    # enough to invalidate on every install/remove/rescan without reading a
    # single addon's own file contents. Clear-StateCache additionally
    # invalidates explicitly at every mutation point in this file (job
    # completion, settings changes, orphan-folder removal) - see its own
    # doc comment for why that is worth having on top of the fingerprint.
    $folderSnapshot = Get-AddonsFolderSnapshot -AddonsPath $compatAddonsPath
    $cacheKey = Get-HandleStateCacheKey -Flavor $flavor -AddonsFingerprint $folderSnapshot.Fingerprint -ClientBuildInfo $Script:ClientBuildInfo
    $cacheEntry = $Script:AddonExtrasCacheByFlavour[$flavor]
    $cacheHit = [bool]($cacheEntry -and $cacheEntry.Key -eq $cacheKey -and $cacheEntry.Extras -and (@($cacheEntry.Extras)).Count -eq $records.Count)

    $presentFolders = $null
    $freshExtras = $null
    if (-not $cacheHit) {
        # E3: computed once per cache-miss call and shared across every
        # record, rather than re-listing the AddOns directory per addon -
        # built from the SAME directory listing Get-AddonsFolderSnapshot
        # above already did for its own fingerprint, so a cache miss still
        # only lists the AddOns folder once, not twice.
        $presentFolders = Get-PresentAddonFoldersFromDirs -Dirs $folderSnapshot.Dirs
        $freshExtras = New-Object 'System.Collections.Generic.List[object]'
    }

    $addonsOut = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $records.Count; $i++) {
        $r = $records[$i]
        # E12: updateAvailable is keyed by the numeric CurseForge project id
        # (unchanged) OR, for a Wago-sourced record (no numeric projectId at
        # all), by "wago:<slug>" - see Get-UpdateAvailableKeyForRecord.
        # Always computed live (a cheap in-memory dictionary lookup, not
        # disk I/O) - never part of the cached extras below.
        $upd = $null
        $key = Get-UpdateAvailableKeyForRecord -Record $r
        if ($key -and $updateAvailable.ContainsKey($key)) {
            $u = $updateAvailable[$key]
            $upd = [PSCustomObject]@{ fileId = $u.fileId; version = $u.version }
        }
        # Round-1-fixer (perf): built via an [ordered] hashtable plus ONE
        # final [PSCustomObject] cast, instead of one [PSCustomObject]@{}
        # literal followed by ~20+ individual Add-Member calls per record.
        # Add-Member's reflection/PSMemberInfo-adaptation overhead measured
        # as the residual cost keeping warm /api/state at ~188ms for 34
        # addons (25%+ over the round's own <150ms target) even after
        # Round 37's toc/compat cache eliminated the disk-I/O cost this
        # loop used to pay - a hashtable Add()/index-set is a plain
        # dictionary write, and casting a single populated [ordered]
        # hashtable to [PSCustomObject] is one bulk conversion instead of
        # N+6 separate ones. An [ordered] hashtable (not a plain one)
        # preserves the exact same property-insertion order the old
        # per-property Add-Member loop produced, so ConvertTo-Json's output
        # order for /api/state is unchanged.
        $clone = [ordered]@{}
        foreach ($p in $r.PSObject.Properties) {
            $clone[$p.Name] = $p.Value
        }
        $clone['updateAvailable'] = $upd

        if ($cacheHit) {
            $extras = $cacheEntry.Extras[$i]
        } else {
            # E3: requiredDeps/optionalDeps reach this response for free via
            # the generic property clone above (once the CLI starts writing
            # them, same free ride documented for E1's previousFileId/
            # previousVersion); missingDeps/missingOptionalDeps are computed
            # live here instead, since SPEC documents them as "computed
            # live, not stored".
            $missingDeps = Get-MissingDeps -DepNames $r.requiredDeps -PresentFolders $presentFolders
            $missingOptionalDeps = Get-MissingDeps -DepNames $r.optionalDeps -PresentFolders $presentFolders
            # E13: tocInterfaces/compat - never persisted, recomputed on
            # every cache miss the same way they used to on every single
            # call. FLAVORS-SPEC.md CS-F2: -Flavor/-InstalledInterface
            # thread through so a package's toc selection matches THIS
            # flavour's own era.
            $tocIfaces = Get-PackageTocInterfaces -AddonsPath $compatAddonsPath -Folders $r.folders -Flavor $flavor -InstalledInterface $Script:ClientBuildInfo.clientInterface
            $compat = Get-AddonCompat -TocInterfaces $tocIfaces -LatestGameVersions $r.latestGameVersions -ClientInterface $Script:ClientBuildInfo.clientInterface
            $extras = [PSCustomObject]@{
                missingDeps         = $missingDeps.ToArray()
                missingOptionalDeps = $missingOptionalDeps.ToArray()
                tocInterfaces       = $tocIfaces.ToArray()
                compat              = $compat
            }
            $freshExtras.Add($extras)
        }

        $clone['missingDeps'] = $extras.missingDeps
        $clone['missingOptionalDeps'] = $extras.missingOptionalDeps
        $clone['tocInterfaces'] = $extras.tocInterfaces
        $clone['compat'] = $extras.compat
        $addonsOut.Add([PSCustomObject]$clone)
    }

    if (-not $cacheHit) {
        $Script:AddonExtrasCacheByFlavour[$flavor] = @{ Key = $cacheKey; Extras = $freshExtras.ToArray() }
    }

    $settings = Get-Settings
    $currentJobView = Get-CurrentOrLastJobSummary -Flavor $flavor

    # FLAVORS-SPEC.md CS-F2 S5.2: installedFlavours/activeFlavour are the
    # only two fields present regardless of ?flavour= - they describe the
    # MACHINE, not one flavour's data. Built from Get-CurrentInstalledFlavours
    # (live detection) rather than cached, per S8's own "detection is live,
    # not cached" acceptance bar.
    $installedFlavoursOut = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in $installedFlavours) {
        $installedFlavoursOut.Add([PSCustomObject]@{
                id               = $f.id
                label            = $f.label
                addonsPath       = $f.addonsPath
                clientBuild      = $f.clientBuild
                clientInterface  = $f.clientInterface
                buildInfoMissing = $f.buildInfoMissing
            })
    }

    $body = [PSCustomObject]@{
        # S5.2: additive-only fields, present on every response regardless of
        # ?flavour= - a single-flavour machine's payload differs from before
        # this change set ONLY by these three top-level fields, per the
        # feature's own "zero behavior change at n=1" bar.
        installedFlavours = $installedFlavoursOut.ToArray()
        activeFlavour     = $flavor
        flavour           = $flavor
        # Security-review fix (curseforge-handler.vbs gap): a machine-wide,
        # not-yet-flavour-attributed 'awaiting_flavour' job, if one is
        # still outstanding - see Get-PendingFlavourChoiceJob's own comment.
        # $null on every request when none is pending (the common case).
        pendingFlavourChoice = (Get-PendingFlavourChoiceJob)
        addons           = $addonsOut.ToArray()
        settings         = Get-SettingsView -Settings $settings
        lastRun          = (Get-FlavourLastRun -Flavor $flavor)
        job              = $currentJobView
        updatesCheckedAt = (Get-FlavourUpdatesCheckedAt -Flavor $flavor)
        # CS1 (UX-SPEC.md sections 2.1/4.2): the one computed freshness enum
        # (see Get-ComputedFreshness) plus the two raw fields it (and a
        # failed-check Retry flow) read from - lastCheckFailed/lastCheckError
        # persist across polls in-memory only (Apply-JobCompletionSideEffects'
        # failure branch sets them; a later success clears them), so a failed
        # check stays visible after reload instead of being silently
        # overwritten by the old "checked X ago" timestamp. FLAVORS-SPEC.md
        # CS-F2 S5.3: all scoped to THIS flavour only - see Get-ComputedFreshness.
        freshness        = (Get-ComputedFreshness -CurrentJobView $currentJobView -Flavor $flavor)
        lastCheckFailed  = [bool](Get-FlavourLastCheckFailed -Flavor $flavor)
        lastCheckError   = (Get-FlavourLastCheckError -Flavor $flavor)
        # E13: re-resolved per request now (Set-CurrentFlavourContext, called
        # from Invoke-Route before this handler runs) rather than once at
        # server startup - see that function's own doc comment.
        clientBuild      = $Script:ClientBuildInfo.clientBuild
        clientInterface  = $Script:ClientBuildInfo.clientInterface
        # P1 perf pass (item 1): present regardless of ?flavour= (describes
        # the machine, not one flavour's data) - a future UI change can gate
        # its own poll cadence/window visibility on this without a second
        # request to /api/ping.
        gameRunning      = (Test-GameRunning)
        # APP-UPDATE-SPEC.md section 5: folded in next to gameRunning so the
        # SPA's existing 5s/idle poll (App.reloadState) picks up update state
        # on the poll it already makes - no new poll loop. Byte-identical
        # shape to GET /api/app-update/status's own body (Get-AppUpdateStatusObject
        # is the single shared builder for both).
        appUpdate        = (Get-AppUpdateStatusObject -Settings $settings)
    }
    Send-Json -Context $Context -StatusCode 200 -Body $body
}

function Handle-JobsPost {
    param($Context, $RouteMatch)

    $body = $null
    try {
        $body = Read-Body -Context $Context
    } catch {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $_.Exception.Message }
        return
    }
    if (-not $body -or -not $body.kind) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: missing kind' }
        return
    }

    $kind = [string]$body.kind
    $validKinds = @('sync', 'check', 'add', 'remove', 'install', 'rollback', 'switch-source', 'add-by-slug', 'update-all-flavours')
    if (-not ($validKinds -contains $kind)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = "bad request: unknown kind '$kind'" }
        return
    }

    # FLAVORS-SPEC.md S5.1: whether THIS request named an explicit
    # ?flavour=/?flavor= - read once, here, since both the gate below and
    # the Start-Job call at the end of this function need it (Start-Job's
    # own S5.5 CurseForge install-flavour resolution must never engage when
    # the caller already made an explicit choice - see its own comment).
    $flavourGiven = [bool](Get-QueryFlavour -Context $Context)

    # E12: a NEW Wago add (no existing record, so no projectId-equivalent key
    # yet) is posted as {source:'wago', slug} instead of projectId - either
    # is accepted here.
    $hasWagoSourceSlug = [bool]($body.source -and $body.slug)
    # E18: bulk adopt (the Welcome dialog's "Adopt all") posts projectIds
    # (array of already-normalized tokens) instead of a single projectId -
    # same three-way either/or as 'remove' below.
    $hasMultiAdd = $body.projectIds -and (@($body.projectIds).Count -gt 0)

    # FLAVORS-SPEC.md CS-F2 S5.1 (narrowed by CS-F3 S5.5): POST /api/jobs is
    # addon-scoped for every kind EXCEPT update-all-flavours (see
    # $Script:FlavourScopedEndpoints' own comment for why that one kind is
    # excluded from the router-level check) - so this handler enforces the
    # identical "flavour required" 400 itself, here, on a multi-flavour
    # machine that omitted ?flavour=/?flavor=. A request naming an
    # unrecognized/not-installed flavour has already been rejected by
    # Invoke-Route's own Resolve-RequestFlavour call before this handler
    # ever ran, regardless of any of this.
    #
    # CS-F3 carves out one exception: a genuine, SINGLE-target CurseForge
    # add/install/add-by-slug (never a bulk add, never a Wago target) skips
    # this blanket 400 and falls through to Start-Job's own S5.5
    # auto/refuse/ask resolution instead - the protocol handler and the
    # embedded CurseForge site's Install button have no concept of Furphy's
    # flavours at all, so they can never send ?flavour=, and 400ing them
    # outright on a multi-flavour machine would make CurseForge installs
    # simply not work there. A bulk add (projectIds[]) and every Wago
    # add/install still 400 here exactly as before this change set - Wago
    # already names its one flavour through the search's own game_version
    # param (S6.4), and silently guessing a flavour for several addons at
    # once is not this feature's job.
    $bodyHasSingleProjectId = [bool]$body.projectId
    $isSingleCfInstallKind = (
        ($kind -eq 'add' -and $bodyHasSingleProjectId -and (-not $hasMultiAdd)) -or
        ($kind -eq 'install') -or
        ($kind -eq 'add-by-slug')
    )
    $targetsWago = $false
    if ($isSingleCfInstallKind) {
        $bodyProjectIdText = [string]$body.projectId
        $targetsWago = $hasWagoSourceSlug -or ($bodyProjectIdText -and $bodyProjectIdText.ToLowerInvariant().StartsWith('wago:'))
    }
    $skipFlavourGate = ($isSingleCfInstallKind -and (-not $targetsWago))
    if ($kind -ne 'update-all-flavours' -and (-not $skipFlavourGate)) {
        $installedForThisJob = Get-CurrentInstalledFlavours
        if ((@($installedForThisJob)).Count -gt 1 -and (-not $flavourGiven)) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'flavour required' }
            return
        }
    }

    # FLAVORS-SPEC.md CS-F2 S5.4/S5.6: a bulk sync fanning out into one
    # per-flavour 'sync' job (reusing the ordinary per-flavour update-all
    # logic, looped) - what the tray's scheduled tick (S5.6, once built)
    # posts, and what CS-F4's "Update All" button (S6.3) fires. Excludes
    # PTR/XPTR/Beta unless Settings' "Show test realms" (S2.5/S3.4) is on.
    # This kind never uses ?flavour= (it targets every installed flavour at
    # once, by definition) - Resolve-RequestFlavour's own default handling
    # for a non-flavour-scoped POST /api/jobs is irrelevant here since this
    # branch returns before Start-Job's own single-flavour Params dispatch.
    if ($kind -eq 'update-all-flavours') {
        $installedForBulk = Get-CurrentInstalledFlavours
        $bulkSettings = Get-Settings
        $showTestRealms = [bool]$bulkSettings.showTestRealms
        $hiddenIds = @('ptr', 'xptr', 'beta')
        $jobsOut = New-Object 'System.Collections.Generic.List[object]'
        foreach ($f in $installedForBulk) {
            if ((-not $showTestRealms) -and ($hiddenIds -contains $f.id)) { continue }
            $r = Start-Job -Kind 'sync' -Params ([PSCustomObject]@{}) -Flavor $f.id
            if ($r.Busy) {
                $jobsOut.Add([PSCustomObject]@{ flavour = $f.id; jobId = $r.Job.id; busy = $true })
            } elseif ($r.Error) {
                $jobsOut.Add([PSCustomObject]@{ flavour = $f.id; error = $r.Error })
            } else {
                $jobsOut.Add([PSCustomObject]@{ flavour = $f.id; jobId = $r.Job.id })
            }
        }
        Send-Json -Context $Context -StatusCode 202 -Body @{ kind = 'update-all-flavours'; jobs = $jobsOut.ToArray() }
        return
    }

    # E19: the native host's CurseForge-tab install-link interception
    # (host\FurphyHost.cs HandleSlugInstall, for /wow/addons/<slug>/install/
    # <fileId> links, which carry a slug but no numeric projectId) - see
    # Start-Job for slug -> projectId resolution against the same catalogue
    # /api/cf/browse uses.
    if ($kind -eq 'add-by-slug' -and (-not $body.slug)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: slug required' }
        return
    }
    # $hasWagoSourceSlug/$hasMultiAdd were already computed above, alongside
    # the flavour-gate skip decision that also needs them.
    if ($kind -eq 'add' -and (-not $body.projectId) -and (-not $hasWagoSourceSlug) -and (-not $hasMultiAdd)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: projectId or projectIds required' }
        return
    }
    if ($kind -eq 'switch-source') {
        if ((-not $body.projectId) -or (-not $body.toSource) -or (-not $body.toTarget)) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: projectId, toSource and toTarget required' }
            return
        }
        if (([string]$body.toSource).ToLowerInvariant() -notin @('wago', 'curseforge')) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: toSource must be wago or curseforge' }
            return
        }
    }
    if ($kind -eq 'remove') {
        # E11: bulk uninstall posts projectIds (array); the per-row kebab
        # menu still posts a single projectId - either satisfies this check.
        $hasSingle = [bool]$body.projectId
        $hasMulti = $body.projectIds -and (@($body.projectIds).Count -gt 0)
        if (-not $hasSingle -and -not $hasMulti) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: projectId or projectIds required' }
            return
        }
    }
    if ($kind -eq 'install' -and ((-not $body.projectId) -and (-not $hasWagoSourceSlug))) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: projectId required' }
        return
    }
    if ($kind -eq 'install' -and (-not $body.fileId)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: fileId required' }
        return
    }
    if ($kind -eq 'rollback' -and (-not $body.projectId)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: projectId required' }
        return
    }

    $result = Start-Job -Kind $kind -Params $body -FlavourExplicit $flavourGiven
    if ($result.Busy) {
        Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'busy'; jobId = $result.Job.id }
        return
    }
    if ($result.Error) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $result.Error }
        return
    }
    Send-Json -Context $Context -StatusCode 202 -Body @{ jobId = $result.Job.id }
}

function Handle-JobsGetOne {
    param($Context, $RouteMatch)

    $id = $RouteMatch['id']
    $job = $null
    foreach ($j in $Script:Jobs) {
        if ($j.id -eq $id) { $job = $j; break }
    }
    if (-not $job) {
        # Round 20 (adversarial bug pass, server-6): $Script:Jobs is a
        # 20-item rolling history (Add-JobToHistory evicts the oldest entry
        # with no exemption for one still running), so a long-running job's
        # own record can fall out of it while 20+ other jobs complete on
        # other flavours - even though the SAME job object is still reachable
        # via $Script:CurrentJobByFlavour the whole time. Fall back to that
        # (the same source of truth Handle-JobsGetAll/Handle-Shutdown already
        # use) before declaring 404, so the SPA's live-progress poll for a
        # genuinely still-running job never loses it.
        foreach ($cj in @($Script:CurrentJobByFlavour.Values)) {
            if ($cj -and $cj.id -eq $id) { $job = $cj; break }
        }
    }
    if (-not $job) {
        Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'job not found' }
        return
    }
    $job = Update-JobStatus -Job $job
    Send-Json -Context $Context -StatusCode 200 -Body (Get-JobStatusView -Job $job)
}

function Handle-JobsGetAll {
    param($Context, $RouteMatch)

    # FLAVORS-SPEC.md CS-F2 S5.4: this listing is shared across every
    # flavour (each job carries its own .flavour field), so every flavour's
    # currently-running job (not just the request's own resolved flavour)
    # needs a fresh poll before the listing below is built.
    foreach ($cj in @($Script:CurrentJobByFlavour.Values)) {
        if ($cj) { Update-JobStatus -Job $cj | Out-Null }
    }
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($j in $Script:Jobs) {
        $out.Add((Get-JobStatusView -Job $j))
    }
    Send-Json -Context $Context -StatusCode 200 -Body $out.ToArray()
}

function Handle-AddonIgnore {
    param($Context, $RouteMatch)

    if (Test-JobBusy -Context $Context) { return }

    $projectId = $RouteMatch['id']
    $body = $null
    try {
        $body = Read-Body -Context $Context
    } catch {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $_.Exception.Message }
        return
    }
    $ignore = $true
    if ($body -and ($null -ne $body.ignore)) { $ignore = [bool]$body.ignore }

    $flag = '-Ignore'
    if (-not $ignore) { $flag = '-Unignore' }

    $cliArgs = @($flag, $projectId)
    try {
        $parsed = Invoke-Cli -CliArgs $cliArgs -TimeoutSec 60
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        return
    }

    $addonsArr = @()
    if ($parsed -and $parsed.addons) { $addonsArr = @($parsed.addons) }
    Send-Json -Context $Context -StatusCode 200 -Body @{ addons = $addonsArr }
}

function Handle-AddonUnpin {
    param($Context, $RouteMatch)

    if (Test-JobBusy -Context $Context) { return }

    $projectId = $RouteMatch['id']
    $cliArgs = @('-Unpin', $projectId)
    try {
        $parsed = Invoke-Cli -CliArgs $cliArgs -TimeoutSec 60
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        return
    }

    $addonsArr = @()
    if ($parsed -and $parsed.addons) { $addonsArr = @($parsed.addons) }
    Send-Json -Context $Context -StatusCode 200 -Body @{ addons = $addonsArr }
}

function Handle-AddonFiles {
    param($Context, $RouteMatch)

    if (Test-JobBusy -Context $Context) { return }

    $projectId = $RouteMatch['id']
    $cliArgs = @('-Files', $projectId)
    try {
        $parsed = Invoke-Cli -CliArgs $cliArgs -TimeoutSec 60
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        return
    }
    Send-Json -Context $Context -StatusCode 200 -Body $parsed
}

function Handle-ScanGet {
    param($Context, $RouteMatch)

    if (Test-JobBusy -Context $Context) { return }

    $cliArgs = @('-Scan')
    try {
        $parsed = Invoke-Cli -CliArgs $cliArgs -TimeoutSec 60
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        return
    }
    Send-Json -Context $Context -StatusCode 200 -Body $parsed
}

function Handle-ScanDelete {
    param($Context, $RouteMatch)

    if (Test-JobBusy -Context $Context) { return }

    $body = $null
    try {
        $body = Read-Body -Context $Context
    } catch {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $_.Exception.Message }
        return
    }
    if (-not $body -or -not $body.folder) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'folder required' }
        return
    }
    $folder = [string]$body.folder
    if ($folder -match '[\\/]' -or $folder -match '\.\.' -or $folder.Trim().Length -eq 0) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'invalid folder name' }
        return
    }

    $records = Get-AddonRecords
    foreach ($r in $records) {
        if ($r.folders) {
            foreach ($f in $r.folders) {
                if ([string]$f -eq $folder) {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'folder is owned by a tracked addon' }
                    return
                }
            }
        }
    }

    $addonsPath = Resolve-EffectiveAddonsPath
    if (-not $addonsPath) {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = 'AddOns path could not be resolved' }
        return
    }

    $target = Join-Path -Path $addonsPath -ChildPath $folder
    $targetFull = [System.IO.Path]::GetFullPath($target)
    $addonsFull = [System.IO.Path]::GetFullPath($addonsPath)
    if (-not $targetFull.StartsWith($addonsFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'invalid folder path' }
        return
    }

    if (Test-Path -LiteralPath $targetFull -PathType Container) {
        try {
            Remove-Item -LiteralPath $targetFull -Recurse -Force
        } catch {
            Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
            return
        }
    }
    # Round 37 (server perf pass): "invalidated on ... rescan" - the AddOns
    # folder's own fingerprint would already catch this deletion, but see
    # Clear-StateCache's own doc comment for why every mutation point here
    # calls it explicitly anyway.
    Clear-StateCache -Flavor $Script:CurrentFlavour
    Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true }
}

function Handle-Export {
    <# E4: GET /api/export - the whole tracked addon list, portable enough to hand to POST /api/import later or on another machine. #>
    param($Context, $RouteMatch)

    $records = Get-AddonRecords
    $addonsOut = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $records) {
        $addonsOut.Add([PSCustomObject]@{
                projectId     = $r.projectId
                name          = $r.name
                pinnedFileId  = $r.pinnedFileId
                ignoreUpdates = [bool]$r.ignoreUpdates
                releaseType   = $r.releaseType
                # E12 fix (Round 9): additive identification fields. A
                # Wago-sourced record's projectId is always $null - without
                # these, Build-ImportPlan's Get-UpdateAvailableKeyForRecord
                # keying has nothing to identify it by and the addon is
                # silently dropped on import. source/slug are what the key
                # is actually built from; wagoId/curseId round-trip for
                # completeness (both are toc-derived and re-populated by the
                # CLI on the next real sync regardless).
                source        = $r.source
                slug          = $r.slug
                wagoId        = $r.wagoId
                curseId       = $r.curseId
            })
    }
    $body = [PSCustomObject]@{
        format     = 'wow-addon-manager/1'
        exportedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        addons     = $addonsOut.ToArray()
    }
    Send-Json -Context $Context -StatusCode 200 -Body $body -FileName 'addons-export.json'
}

function Handle-Import {
    <#
      E4: POST /api/import - body is the same shape GET /api/export produces
      (format/exportedAt/addons). Starts job kind 'import' (Start-ImportJob);
      the format field is validated here so a wrong/foreign file 400s before
      any job is ever created, per SPEC.
    #>
    param($Context, $RouteMatch)

    $body = $null
    try {
        $body = Read-Body -Context $Context
    } catch {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $_.Exception.Message }
        return
    }
    if (-not $body) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: empty body' }
        return
    }
    if ([string]$body.format -ne 'wow-addon-manager/1') {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: unsupported format' }
        return
    }
    if ($null -eq $body.addons) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: addons required' }
        return
    }

    $result = Start-Job -Kind 'import' -Params $body
    if ($result.Busy) {
        Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'busy'; jobId = $result.Job.id }
        return
    }
    if ($result.Error) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $result.Error }
        return
    }
    Send-Json -Context $Context -StatusCode 202 -Body @{ jobId = $result.Job.id }
}

function Handle-SettingsGet {
    param($Context, $RouteMatch)

    $settings = Get-Settings
    Send-Json -Context $Context -StatusCode 200 -Body (Get-SettingsView -Settings $settings)
}

function ConvertTo-SettingsBool {
    <#
      Round 20 (adversarial bug pass): a bare [bool] cast treats ANY
      non-empty string as truthy, so a JSON STRING "false" (a client bug,
      not a real JSON boolean - the SPA itself always sends a real boolean)
      silently coerced to $true, inverting the caller's intent. This keeps
      the settings API's documented "no invalid boolean, always coerce"
      permissiveness (SPEC.md 556/630 - these fields are never rejected with
      a 400) for every other input shape, while recognizing the common
      falsy-string spellings so "false"/"0"/etc. behave the way any
      reasonable caller would expect instead of flipping the setting on.
    #>
    param($Value)
    if ($Value -is [string]) {
        $trimmed = $Value.Trim().ToLowerInvariant()
        if ($trimmed -eq 'false' -or $trimmed -eq '0' -or $trimmed -eq 'no' -or $trimmed -eq 'off' -or $trimmed -eq '') {
            return $false
        }
    }
    return [bool]$Value
}

function Handle-SettingsPut {
    param($Context, $RouteMatch)

    $body = $null
    try {
        $body = Read-Body -Context $Context
    } catch {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $_.Exception.Message }
        return
    }
    if (-not $body) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'bad request: empty body' }
        return
    }

    $settings = Get-Settings
    if ($null -ne $body.releaseType) {
        # Round 20 (adversarial bug pass, security-4/cli-2/server-4): a
        # non-numeric value (e.g. the string "abc") used to hit the bare
        # [int] cast below unguarded, throwing a FormatException that
        # Invoke-Route's catch-all turned into a raw 500 with the internal
        # .NET exception text as the body - a clean 400 is used instead,
        # matching the out-of-range check just below it.
        $rt = 0
        if (-not [int]::TryParse([string]$body.releaseType, [ref]$rt)) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'releaseType must be a number' }
            return
        }
        if ($rt -lt 1 -or $rt -gt 3) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'releaseType must be 1-3' }
            return
        }
        $settings.releaseType = $rt
    }
    if ($null -ne $body.port) {
        # Round 20: same guarded-cast treatment as releaseType above.
        $p = 0
        if (-not [int]::TryParse([string]$body.port, [ref]$p)) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'port must be a number' }
            return
        }
        # security:security-server-settings-port-no-range-check-bricks-
        # launch - the TryParse guard above only ever ruled out a
        # non-numeric value; a positive but out-of-range value (e.g.
        # 999999) used to sail straight into settings.json. "Addon
        # Manager.vbs" (the real launcher) never passes -Port at all - it
        # relies entirely on this stored value at every future startup - so
        # an out-of-range port written here bricked the app completely on
        # its very next launch: $listener.Start() throws, is logged FATAL,
        # and the process exits with no listener on any port and no
        # on-screen error of any kind. Reject the same way releaseType does
        # just above, instead of ever reaching Save-Settings.
        if ($p -lt 1 -or $p -gt 65535) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'port must be 1-65535' }
            return
        }
        $settings.port = $p
    }
    # E19: adFilter (the CurseForge-tab ad/tracker filter toggle) and
    # hostWindow (the native host's window bounds) - see Get-DefaultSettings.
    # Settings > Browsing's toggle is the normal caller for adFilter;
    # hostWindow is set almost exclusively by FurphyHost.exe writing
    # settings.json directly (HostFiles.UpdateJsonObject, bypassing this
    # endpoint entirely), but is still accepted here for completeness/so a
    # round-trip through the API never loses it.
    if ($null -ne $body.adFilter) {
        $settings.adFilter = ConvertTo-SettingsBool $body.adFilter
    }
    # Round 16 (E22): cfFocus (the CurseForge listing/search focus-view
    # trim toggle) - see Get-DefaultSettings. Settings > Advanced's
    # "Show only search results on CurseForge" toggle is the normal caller,
    # in both the native host and the plain Edge window (unlike adFilter,
    # which only does anything inside the host - cfFocus still saves here so
    # it applies next time the desktop window is used).
    if ($null -ne $body.cfFocus) {
        $settings.cfFocus = ConvertTo-SettingsBool $body.cfFocus
    }
    if ($null -ne $body.hostWindow) {
        $settings.hostWindow = $body.hostWindow
    }
    # Round 12 (E19b): hostTheme (the native host's chrome/title-bar palette,
    # relayed from the page via a postMessage the host then PUTs here the
    # same way it round-trips hostWindow) - VALIDATED unlike hostWindow's
    # total pass-through above, since this shape can also be reached by a
    # client sending arbitrary JSON straight to the API. Rejects (400) and
    # saves nothing else from this request either, rather than silently
    # dropping just the bad field - consistent with releaseType's own
    # out-of-range 400 just above.
    if ($null -ne $body.hostTheme) {
        if (-not (Test-HostTheme -Theme $body.hostTheme)) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'hostTheme invalid: name must be 1-32 chars matching ^[a-z0-9-]+$, colors must be an object of <=12 "#rrggbb" values' }
            return
        }
        $settings.hostTheme = $body.hostTheme
    }
    # Round 18 (tray stage B): backgroundUpdates/runAtStartup save exactly
    # like adFilter/cfFocus above - bool coercion, no rejection possible.
    # backgroundIntervalMinutes is CLAMPED (not rejected with a 400) into
    # 30..1440, matching the "int clamped 30..1440" pattern the task brief
    # calls for and the read-path clamp in Get-Settings above - a client
    # sending 5 or 999999 silently ends up at 30 or 1440 rather than erroring,
    # consistent with there being no invalid integer here, only an
    # out-of-range one. The SPA's own interval <select> only ever offers the
    # five clamp-safe values (60/120/240/480/1440) so this path is a
    # defense-in-depth backstop, not something the normal UI can trigger.
    if ($null -ne $body.backgroundUpdates) {
        $settings.backgroundUpdates = ConvertTo-SettingsBool $body.backgroundUpdates
    }
    if ($null -ne $body.backgroundIntervalMinutes) {
        # Round 20: same guarded-cast treatment as releaseType/port above -
        # a non-numeric value now 400s instead of throwing a raw 500.
        $interval = 0
        if (-not [int]::TryParse([string]$body.backgroundIntervalMinutes, [ref]$interval)) {
            Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'backgroundIntervalMinutes must be a number' }
            return
        }
        if ($interval -lt 30) { $interval = 30 }
        if ($interval -gt 1440) { $interval = 1440 }
        $settings.backgroundIntervalMinutes = $interval
    }
    if ($null -ne $body.runAtStartup) {
        $settings.runAtStartup = ConvertTo-SettingsBool $body.runAtStartup
    }
    # APP-UPDATE-SPEC.md section 6: appUpdateAutoInstall saves exactly like
    # backgroundUpdates/runAtStartup just above - bool coercion, no
    # rejection possible.
    if ($null -ne $body.appUpdateAutoInstall) {
        $settings.appUpdateAutoInstall = ConvertTo-SettingsBool $body.appUpdateAutoInstall
    }
    # FLAVORS-SPEC.md CS-F2 S3.4: activeFlavour is a pure UI-continuity
    # default (S5.1's principle 5 - "never load-bearing for a data
    # operation") - validated against the CURRENTLY installed flavours so a
    # stale/bogus value can never get written, but never rejected as a 400
    # the way releaseType's out-of-range check is, since getting this one
    # wrong only affects which flavour's view loads after a reload, nothing
    # destructive. showTestRealms (S2.5) is a plain bool, same pattern as
    # adFilter/cfFocus. schemaVersion is intentionally NOT accepted here -
    # it is migration-owned (Invoke-FlavourMigration writes it directly) and
    # must never be client-settable.
    if ($null -ne $body.activeFlavour) {
        $candidateFlavour = ([string]$body.activeFlavour).Trim().ToLowerInvariant()
        if ($candidateFlavour.Length -gt 0) {
            $installedForActiveFlavour = Get-CurrentInstalledFlavours
            $isKnownFlavour = $false
            foreach ($f in $installedForActiveFlavour) {
                if ($f.id -eq $candidateFlavour) { $isKnownFlavour = $true; break }
            }
            if ($isKnownFlavour) {
                $settings.activeFlavour = $candidateFlavour
            }
        }
    }
    if ($null -ne $body.showTestRealms) {
        $settings.showTestRealms = ConvertTo-SettingsBool $body.showTestRealms
    }

    try {
        Save-Settings -Settings $settings
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        return
    }
    # Round 37 (server perf pass): "invalidated on ... settings change" -
    # the one case Get-HandleStateCacheKey's own mtime fingerprint does NOT
    # already catch on its own (a settings.json write touches neither
    # addons.json nor the AddOns folder) - see Clear-StateCache's own doc
    # comment. Machine-wide (no -Flavor), since a settings change is never
    # scoped to just one flavour.
    Clear-StateCache
    Send-Json -Context $Context -StatusCode 200 -Body (Get-SettingsView -Settings $settings)
}

# =====================================================================
# Tray + start-with-Windows (Round 18, tray stage B)
#
# Stage A (already shipped, host\FurphyHost.cs) is the actual --tray
# process: a NotifyIcon-only run mode guarded by a per-port
# "FurphyAddonManager.Tray[.<port>]" Mutex, exited by setting a per-port
# "FurphyAddonManager.TrayStop[.<port>]" EventWaitHandle or by
# backgroundUpdates going false (checked every <=60s), writing
# tray-state.json next to settings.json on every cycle. This section is the
# SERVER's half of stage B: start/stop that process, report its state, and
# register/unregister the HKCU Run value - the SPA (ui\app.js) never touches
# the registry or spawns FurphyHost.exe directly, only these endpoints do.
#
# Round 29 (live-safety fix): the stop event name used to be the bare
# literal "FurphyAddonManager.TrayStop" regardless of what port THIS
# addon-server.ps1 instance is listening on - so a test server on, say,
# port 47899 handling POST /api/tray/stop would signal the exact same named
# event a real, live, production --tray (port 47831) is waiting on, and
# silently stop it. Get-TrayStopEventName below computes the name the same
# way host\FurphyHost.cs's TrayProgram.ResolveStopEventName does (from THIS
# server's own $Script:Port, mirroring how a --tray process launched to
# match this server would resolve its own port): the production literal
# only when $Script:Port is really 47831, else a port-suffixed name -
# documented in SPEC.md's tray section.
# =====================================================================

function Get-TrayStopEventName {
    <#
      Same naming rule as host\FurphyHost.cs's TrayProgram.ResolveStopEventName
      (and its ResolveMutexName sibling) - keyed off THIS server's own
      $Script:Port so a stop request handled by a non-production server
      instance can never reach a real, live tray on a different port.
    #>
    if ($Script:Port -eq 47831) { return 'FurphyAddonManager.TrayStop' }
    return ('FurphyAddonManager.TrayStop.' + [string]$Script:Port)
}

function Get-TrayExePath {
    <# host\bin\FurphyHost.exe under the app root - built by host\build-host.ps1. #>
    return Join-Path -Path (Join-Path -Path $Script:Root -ChildPath 'host\bin') -ChildPath 'FurphyHost.exe'
}

function Get-TrayStatePath {
    <# tray-state.json sits next to settings.json - host\FurphyHost.cs's
       TrayForm writes it there (Path.Combine(logDir, "tray-state.json") where
       logDir is settings.json's own directory), so this just mirrors that. #>
    return Join-Path -Path $Script:Root -ChildPath 'tray-state.json'
}

function Test-LooksLikeScratchRun {
    <#
      Round 33 (DISTRIBUTION-SPEC.md section 5.4/"Installed-Apps
      registration refresh at startup"): independent, code-level heuristic
      that -Path looks like a scratch/test root rather than a real
      production install - duplicated VERBATIM from install.ps1's own
      Test-LooksLikeScratchRun, per this codebase's established "every
      shared fact lives in each file that needs it" convention (the same
      reasoning already used for $Script:FlavourDefs/Get-StartupValueName's
      own port-scoping logic). Used only to gate the Installed-Apps
      registry write below - a test server on 47899 already skips it via
      the plain port check, but a hypothetical server started on the
      PRODUCTION port 47831 against a scratch root (never done by this
      round's own tests - see the file's HARD RULES - but defended against
      anyway, exactly like install.ps1 defends the Run-value/Installed-Apps
      removal the same way) must not write into the real user's
      Installed-Apps key either.
    #>
    param([string]$Path)
    if (-not $Path) { return $false }
    $p = $Path.ToLowerInvariant()
    $tempDir = $null
    try { $tempDir = [System.IO.Path]::GetTempPath() } catch { $tempDir = $null }
    if ($tempDir) {
        $tempDir = $tempDir.ToLowerInvariant().TrimEnd('\')
        if ($p.StartsWith($tempDir)) { return $true }
    }
    if ($p -match '\\scratch(\\|$)') { return $true }
    if ($p -match '\\fixtures\\wowroot(\\|$)') { return $true }
    return $false
}

function Get-StartupValueName {
    <#
      Round 29 live-safety: the HKCU Run value name this server reads and
      writes. The production port owns the real "FurphyAddonManager" value;
      any other port (test servers on 47899 etc.) uses the test-scoped
      "FurphyAddonManager.Test" name, so a test can never delete or rewrite
      the owner's own Start-with-Windows entry. The host's tray uses the
      identical rule (TrayForm._startupValueName) and tests
un-all.ps1's
      sweep removes only the test name.
    #>
    if ($Script:Port -eq 47831) { return 'FurphyAddonManager' }
    return 'FurphyAddonManager.Test'
}

function Get-TrayRunValue {
    <#
      The exact HKCU Run value string this app's tray contract uses:
      "<quoted exe path>" --tray (quoted path, one space, --tray). Must stay
      byte-identical to host\FurphyHost.cs's own
      StartupRegistry.BuildRunValue, since either side may write it and both
      sides need to recognize what the other wrote.
    #>
    return '"' + (Get-TrayExePath) + '" --tray'
}

function Read-TrayState {
    <# Parsed tray-state.json, or $null if missing/empty/unreadable - never throws. #>
    $path = Get-TrayStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Test-TrayProcessAlive {
    <#
      True only if $ProcId is a LIVE process that is actually a --tray
      instance of FurphyHost - guards against a stale tray-state.json (left
      behind by a crash or a `taskkill`) reporting "running" just because
      some unrelated process has since reused the same pid.

      A ProcessName match alone is NOT enough here: the tray and the normal
      foreground app window are the exact same executable
      (host\bin\FurphyHost.exe), so a crashed/killed tray's pid can be
      reused by an ordinary (non-tray) launch of that same exe and still
      pass a name-only check. Cross-checking the live process's own command
      line for the "--tray" argument (the exact way Handle-TrayStart itself
      launches it - see Start-Process -ArgumentList '--tray' above) is what
      actually distinguishes the two.
    #>
    param([int]$ProcId)

    if ($ProcId -le 0) { return $false }
    try {
        $proc = Get-Process -Id $ProcId -ErrorAction Stop
        if ($proc.ProcessName -ne 'FurphyHost') { return $false }
    } catch {
        return $false
    }
    try {
        $cim = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = " + $ProcId) -ErrorAction Stop
        if ($null -eq $cim -or [string]::IsNullOrEmpty($cim.CommandLine)) { return $false }
        # Round 29: '--tray' may be followed by '--port <n>' (Handle-TrayStart forwards its port), so match it as a token anywhere, not only at the end.
        return ($cim.CommandLine -match '(^|\s)--tray(\s|$)')
    } catch {
        # Get-CimInstance failing (WMI hiccup, access denied, etc.) should
        # not be treated as "definitely not a tray process" OR "definitely
        # is one" - fall back to the name-only signal rather than blocking
        # every tray status check on a transient WMI error.
        return $true
    }
}

function Test-StartupRegistered {
    <# True only if the HKCU Run value exists AND matches Get-TrayRunValue
       exactly - a value some other tool wrote under the same name, or a
       stale one pointing at a moved exe, correctly reads as "not registered"
       by Furphy's own contract. #>
    try {
        $prop = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name (Get-StartupValueName) -ErrorAction SilentlyContinue
        if ($null -eq $prop) { return $false }
        $valueName = Get-StartupValueName
        return ([string]$prop.PSObject.Properties[$valueName].Value -ceq (Get-TrayRunValue))
    } catch {
        return $false
    }
}

# =====================================================================
# Round 33 (DISTRIBUTION-SPEC.md section 5.4): Installed-Apps registration
# REFRESH at startup - so an already-installed user who just upgraded (ran
# a newer zip's install.ps1, or will next time) still gets a working
# Windows Settings > Apps entry even before that next reinstall, since this
# server itself restarts far more often than install.ps1 ever re-runs.
# Gated to "port 47831 AND not a scratch root" (Update-InstalledAppsRegistration
# below) - never fires for any test server on 47899, and defends the real
# key even in the hypothetical case of a scratch root somehow started on
# the production port (see Test-LooksLikeScratchRun's own comment above).
# =====================================================================

function Get-InstalledAppsSizeKB {
    <# Duplicate of install.ps1's Get-InstallEstimatedSizeKB - see that
       function's own comment for why this never throws. #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if (-not $sum) { return 0 }
        return [int][math]::Round($sum / 1024)
    } catch {
        return 0
    }
}

function Get-InstalledAppsUninstallString {
    <#
      Duplicate of install.ps1's Get-InstallUninstallString (section 5.4's
      "try the server, else copy+launch" one-liner) - kept as its own copy
      here rather than importing install.ps1, per this codebase's
      established convention of never dot-sourcing one script from
      another. Pure string composition; never touches the registry, the
      filesystem or the network itself.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$AppDest,
        [Parameter(Mandatory = $true)][string]$WowRootPath
    )
    $originUrl = "http://localhost:$Port"
    $apiUrl = "http://localhost:$Port/api/uninstall"
    $installPs1 = Join-Path -Path $AppDest -ChildPath 'install.ps1'
    $installPs1Esc = $installPs1.Replace("'", "''")
    $wowRootEsc = $WowRootPath.Replace("'", "''")

    $inner = "try { Invoke-RestMethod -Method Post -Uri '$apiUrl' -TimeoutSec 2 -Headers @{Origin='$originUrl'} } catch { `$t = Join-Path `$env:TEMP ('FurphyUninstall-' + [guid]::NewGuid() + '.ps1'); Copy-Item '$installPs1Esc' `$t; Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',`$t,'-WowPath','$wowRootEsc','-Uninstall' }"

    return 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "' + $inner + '"'
}

function Update-InstalledAppsRegistration {
    <#
      Writes/refreshes HKCU:\...\Uninstall\FurphyAddonManager - ONLY when
      THIS server is running on the real production port (47831) from a
      NON-scratch root (Test-LooksLikeScratchRun). Every other port or a
      scratch root writes NOTHING, so no test server on 47899 can ever
      create or touch this key. Best-effort: any failure is logged and
      swallowed, never blocks startup.
    #>
    if ($Script:Port -ne 47831) { return }
    if (Test-LooksLikeScratchRun -Path $Script:Root) { return }

    try {
        $wowRootPath = Get-FlavourWowRootPath -Flavor 'retail'
        if (-not $wowRootPath) { $wowRootPath = Get-FlavourWowRootPath }
        if (-not $wowRootPath) {
            Write-ServerLog 'Update-InstalledAppsRegistration: could not resolve a WoW root - skipped.'
            return
        }
        $keyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FurphyAddonManager'
        if (-not (Test-Path -LiteralPath $keyPath)) {
            New-Item -Path $keyPath -Force | Out-Null
        }
        $uninstallCmd = Get-InstalledAppsUninstallString -Port $Script:Port -AppDest $Script:Root -WowRootPath $wowRootPath
        Set-ItemProperty -LiteralPath $keyPath -Name 'DisplayName' -Value 'Furphy Addon Manager' -Type String
        Set-ItemProperty -LiteralPath $keyPath -Name 'DisplayVersion' -Value $Script:Version -Type String
        Set-ItemProperty -LiteralPath $keyPath -Name 'Publisher' -Value 'krenz444' -Type String
        Set-ItemProperty -LiteralPath $keyPath -Name 'InstallLocation' -Value $Script:Root -Type String
        Set-ItemProperty -LiteralPath $keyPath -Name 'DisplayIcon' -Value (Join-Path -Path $Script:Root -ChildPath 'icon.ico') -Type String
        Set-ItemProperty -LiteralPath $keyPath -Name 'EstimatedSize' -Value (Get-InstalledAppsSizeKB -Path $Script:Root) -Type DWord
        Set-ItemProperty -LiteralPath $keyPath -Name 'NoModify' -Value 1 -Type DWord
        Set-ItemProperty -LiteralPath $keyPath -Name 'NoRepair' -Value 1 -Type DWord
        Set-ItemProperty -LiteralPath $keyPath -Name 'UninstallString' -Value $uninstallCmd -Type String
        Set-ItemProperty -LiteralPath $keyPath -Name 'QuietUninstallString' -Value $uninstallCmd -Type String
        Write-ServerLog 'Refreshed the Installed-Apps (Windows Settings > Apps) registry entry.'
    } catch {
        Write-ServerLog "Update-InstalledAppsRegistration failed: $($_.Exception.Message)"
    }
}

function Get-TrayStatusView {
    <# GET /api/tray/status body. `running` is true only if tray-state.json
       says running AND that pid is alive AND is actually FurphyHost.exe -
       see Test-TrayProcessAlive. #>
    $state = Read-TrayState
    $running = $false
    if ($null -ne $state -and $null -ne $state.running -and [bool]$state.running -and $null -ne $state.pid) {
        $running = Test-TrayProcessAlive -ProcId ([int]$state.pid)
    }
    return @{
        running           = $running
        state             = $state
        startupRegistered = (Test-StartupRegistered)
    }
}

function Handle-TrayStatus {
    <# GET /api/tray/status #>
    param($Context, $RouteMatch)

    try {
        Send-Json -Context $Context -StatusCode 200 -Body (Get-TrayStatusView)
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
    }
}

function Handle-TrayStart {
    <#
      POST /api/tray/start - Start-Process host\bin\FurphyHost.exe --tray
      (a GUI exe; no window-hiding flag needed). 409 if a live tray already
      holds the job; 501 if the exe was never built.
    #>
    param($Context, $RouteMatch)

    try {
        $status = Get-TrayStatusView
        if ($status.running) {
            Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'tray already running'; state = $status.state }
            return
        }
        $exePath = Get-TrayExePath
        if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
            Send-Json -Context $Context -StatusCode 501 -Body @{ error = 'FurphyHost.exe not found - the native host was not built' }
            return
        }
        $hostBinDir = Split-Path -Path $exePath -Parent
        Start-Process -FilePath $exePath -ArgumentList @('--tray', '--port', [string]$Script:Port) -WorkingDirectory $hostBinDir | Out-Null
        Send-Json -Context $Context -StatusCode 202 -Body @{ ok = $true }
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
    }
}

function Handle-TrayStop {
    <#
      POST /api/tray/stop - signals the per-port
      "FurphyAddonManager.TrayStop[.<port>]" EventWaitHandle (see
      Get-TrayStopEventName) a live --tray process on THIS server's own
      port is waiting on. OpenExisting throws (caught, not a 500) when no
      tray currently holds that name - that is the normal "nothing to stop"
      case, not a server error, so it still returns 200 with ok:false per
      the stage-B contract. Reset() is deliberately not called: the
      contract has the tray exit on this signal, not loop back around
      waiting for another one.

      Round 29 (live-safety fix, HARD RULE): never widen this back to the
      bare literal name - a non-production server instance (any port other
      than 47831) must only ever be able to signal a tray on THAT SAME
      port, never a real, live, production tray on 47831.
    #>
    param($Context, $RouteMatch)

    $ev = $null
    try {
        $ev = [System.Threading.EventWaitHandle]::OpenExisting((Get-TrayStopEventName))
        $ev.Set() | Out-Null
        Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true }
    } catch {
        Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $false; reason = 'not running' }
    } finally {
        if ($null -ne $ev) { try { $ev.Close() } catch { } }
    }
}

function Handle-StartupRegister {
    <#
      POST /api/startup/register - writes HKCU Run "FurphyAddonManager" =
      Get-TrayRunValue and sets runAtStartup=true. Deliberately does NOT
      touch backgroundUpdates here - the "turning Start with Windows on also
      turns background updates on" rule (task brief) is a single-PUT,
      single-toast SPA-side decision (Actions.setRunAtStartup, ui\app.js),
      not something this endpoint imposes on every caller.
    #>
    param($Context, $RouteMatch)

    try {
        $keyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if (-not (Test-Path -LiteralPath $keyPath)) {
            New-Item -Path $keyPath -Force | Out-Null
        }
        Set-ItemProperty -LiteralPath $keyPath -Name (Get-StartupValueName) -Value (Get-TrayRunValue) -Type String

        $settings = Get-Settings
        $settings.runAtStartup = $true
        Save-Settings -Settings $settings

        Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true; settings = (Get-SettingsView -Settings $settings) }
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
    }
}

function Handle-StartupUnregister {
    <# POST /api/startup/unregister - removes the Run value (if present) and sets runAtStartup=false. #>
    param($Context, $RouteMatch)

    try {
        $keyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if (Test-Path -LiteralPath $keyPath) {
            $existing = Get-ItemProperty -LiteralPath $keyPath -Name (Get-StartupValueName) -ErrorAction SilentlyContinue
            if ($null -ne $existing) {
                Remove-ItemProperty -LiteralPath $keyPath -Name (Get-StartupValueName) -ErrorAction SilentlyContinue
            }
        }

        $settings = Get-Settings
        $settings.runAtStartup = $false
        Save-Settings -Settings $settings

        Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true; settings = (Get-SettingsView -Settings $settings) }
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
    }
}

function Handle-StartupStatus {
    <# GET /api/startup/status #>
    param($Context, $RouteMatch)

    try {
        Send-Json -Context $Context -StatusCode 200 -Body @{ registered = (Test-StartupRegistered) }
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
    }
}

# =====================================================================
# curseforge:// protocol handler status (E19; script itself is E17's)
# =====================================================================

function Get-ProtocolStatusObject {
    <#
      Round 37 (server perf pass): GET /api/protocol/status used to spawn a
      whole hidden powershell.exe child (register-protocol.ps1 -Status
      -Json) just to read one registry value and stat one file - measured
      at ~400ms, almost all of it process-start overhead, for what is a
      pure read with no side effects. This is that exact same read/compute
      done IN-PROCESS instead - a byte-for-byte port of register-
      protocol.ps1's own Get-StatusObject (registered/currentHandler/
      handlerPath/handlerExists), reading $Script:CurseforgeProtocolKeyPath
      (real default 'HKCU:\Software\Classes\curseforge' - see that
      variable's own declaration for the test-only override seam) and
      comparing against $Script:CurseforgeHandlerPath, exactly the two
      script-scope values that startup already resolved byte-identically to
      register-protocol.ps1's own defaults. register-protocol.ps1 itself is
      UNCHANGED and still the sole implementation for an actual write -
      Handle-ProtocolRegister/Unregister still spawn it via
      Invoke-ProtocolScript, unaffected by this function's existence. Never
      throws (a missing/inaccessible registry key just means "not
      registered", matching register-protocol.ps1's own Get-CurrentCommand
      try/catch).
    #>
    # Plain string concatenation, matching register-protocol.ps1's own
    # "$keyPath\shell\open\command" exactly - not Join-Path, to avoid any
    # provider-specific normalization surprise on an HKCU: path.
    $cmdPath = "$($Script:CurseforgeProtocolKeyPath)\shell\open\command"
    $current = ''
    try {
        $current = [string](Get-ItemProperty -LiteralPath $cmdPath -ErrorAction Stop).'(default)'
    } catch {
        $current = ''
    }
    $isOurs = ($current -ne '') -and ($current.IndexOf($Script:CurseforgeHandlerPath, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    return [PSCustomObject]@{
        registered     = $isOurs
        currentHandler = $current
        handlerPath    = $Script:CurseforgeHandlerPath
        handlerExists  = (Test-Path -LiteralPath $Script:CurseforgeHandlerPath)
    }
}

function Handle-ProtocolStatus {
    <# GET /api/protocol/status -> Get-ProtocolStatusObject, read entirely in-process (Round 37 - see that function's own doc comment for why this no longer spawns register-protocol.ps1). #>
    param($Context, $RouteMatch)

    try {
        $status = Get-ProtocolStatusObject
        Send-Json -Context $Context -StatusCode 200 -Body $status
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
    }
}

function Handle-ProtocolRegister {
    <# POST /api/protocol/register -> register-protocol.ps1 -Register -Json, then its resulting status. #>
    param($Context, $RouteMatch)

    try {
        $status = Invoke-ProtocolScript -Switch 'Register'
        Send-Json -Context $Context -StatusCode 200 -Body $status
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
    }
}

function Handle-ProtocolUnregister {
    <# POST /api/protocol/unregister -> register-protocol.ps1 -Unregister -Json, then its resulting status. #>
    param($Context, $RouteMatch)

    try {
        $status = Invoke-ProtocolScript -Switch 'Unregister'
        Send-Json -Context $Context -StatusCode 200 -Body $status
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
    }
}

function Handle-Diagnostics {
    <#
      E10: GET /api/diagnostics - runs the fixed battery of Test-Diag* checks
      defined above and returns {checks:[{name,ok,detail}]}. Every check
      function is self-contained and never throws, so nothing here needs (or
      gets) a try/catch of its own.
    #>
    param($Context, $RouteMatch)

    $checks = New-Object 'System.Collections.Generic.List[object]'
    $checks.Add((New-DiagCheckRow -Name 'AddOns folder' -Result (Test-DiagAddonsFolder)))
    $checks.Add((New-DiagCheckRow -Name 'settings.json' -Result (Test-DiagSettingsJson)))
    $checks.Add((New-DiagCheckRow -Name 'addons.json' -Result (Test-DiagAddonsJson)))
    $checks.Add((New-DiagCheckRow -Name 'CurseForge reachability' -Result (Test-DiagCfReachability)))
    $checks.Add((New-DiagCheckRow -Name 'Disk space' -Result (Test-DiagDiskSpace)))
    $checks.Add((New-DiagCheckRow -Name 'PowerShell version' -Result (Test-DiagPowerShellVersion)))
    $checks.Add((New-DiagCheckRow -Name 'Server uptime' -Result (Test-DiagServerUptime -UptimeSeconds ((Get-Date) - $Script:StartTime).TotalSeconds)))
    $checks.Add((New-DiagCheckRow -Name 'Last sync' -Result (Test-DiagLastSync)))
    # E13: the client build $Script:ClientBuildInfo already resolved once at
    # startup (roadmap: "/api/diagnostics includes the client build").
    $checks.Add((New-DiagCheckRow -Name 'WoW client build' -Result (Test-DiagClientBuild)))
    # E16: the two keyless-enrichment checks its own roadmap item calls for.
    $checks.Add((New-DiagCheckRow -Name 'CurseForge catalogue cache' -Result (Test-DiagCfCatalogue)))
    $checks.Add((New-DiagCheckRow -Name 'addon-radar reachability' -Result (Test-DiagAddonRadar)))

    Send-Json -Context $Context -StatusCode 200 -Body @{ checks = $checks.ToArray() }
}

function Handle-Open {
    param($Context, $RouteMatch)

    $body = $null
    try {
        $body = Read-Body -Context $Context
    } catch {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $_.Exception.Message }
        return
    }
    if (-not $body -or -not $body.what) {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'what required' }
        return
    }

    $what = [string]$body.what
    try {
        switch ($what) {
            'log' {
                # Start-Process joins -ArgumentList elements with spaces and does NOT
                # quote them (see New-CliProcessArgs), so paths with spaces/parens
                # (e.g. the production "C:\Program Files (x86)\...\AddonSync" root)
                # must be quoted here or notepad receives a broken multi-arg command line.
                Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $Script:SyncLogPath + '"')
            }
            'serverlog' {
                # Round 5: SPEC.md's Maintenance list (section 3) names three
                # distinct actions - "Open sync log", "Open last run report",
                # "Open server log" - but the documented /api/open `what` enum
                # only ever had one log target ('log', opening sync.log), so
                # "Open server log" had no server-side target to call at all.
                # Same quoting requirement as 'log' above (spaces/parens in ROOT).
                Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $Script:ServerLogPath + '"')
            }
            'wowfolder' {
                # Round 33: Settings > Advanced > Game folders' "World of
                # Warcraft folder" row. That row displays Get-SettingsView's
                # `wowRoot` field, which is Get-WowRootPath - the flavour's
                # own folder (e.g. <WowRoot>\_retail_), NOT the AddOns
                # subfolder - so this opens exactly the path shown beside
                # the button. Until this target existed, ui\app.js wired
                # that row's button to 'folder' below (the AddOns
                # subfolder) and the "AddOns folder" row's button to
                # 'addons' (addons.json in Notepad): neither button opened
                # what its own row promised (the wiring bug Round 32's
                # SETTINGS-SPEC.md section 5, item 4 flagged and left
                # open). Flavour-aware the same way 'folder' is -
                # Resolve-EffectiveAddonsPath reads $Script:CurrentFlavour,
                # stashed per request by Set-CurrentFlavourContext from
                # ?flavour=.
                $wowFolder = Get-WowRootPath
                if ($wowFolder -and (Test-Path -LiteralPath $wowFolder -PathType Container)) {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $wowFolder + '"')
                } else {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'World of Warcraft folder not found' }
                    return
                }
            }
            'folder' {
                # The AddOns folder (Interface\AddOns) in Explorer. As of
                # round 33 this backs Settings > Advanced > Game folders'
                # "AddOns folder" row (single flavour) and every per-flavour
                # row (multi-flavour - ?flavour=<id> picks which one; the
                # UI used to send the flavour in the POST body, which
                # nothing here ever read).
                $addonsPath = Resolve-EffectiveAddonsPath
                if ($addonsPath -and (Test-Path -LiteralPath $addonsPath)) {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $addonsPath + '"')
                } else {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'AddOns folder not found' }
                    return
                }
            }
            'addons' {
                # The request flavour's addons.json in Notepad - a
                # troubleshooting target. Round 33 moved it off the Game
                # folders "AddOns folder" row (whose label promised the
                # folder, not this file) to Settings > Advanced > Backup &
                # troubleshooting's "Open addon list file" button, per
                # UX-SPEC.md 1.3 (demote, don't delete). Unchanged here.
                if (Test-Path -LiteralPath $Script:AddonsJsonPath) {
                    Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $Script:AddonsJsonPath + '"')
                } else {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'addons.json not found' }
                    return
                }
            }
            'curseforge' {
                $url = $null
                # Round 5: slug/projectId are POST-body-supplied strings, and
                # Open-InBrowser hands the finished URL to Start-Process
                # -ArgumentList as ONE unquoted string - a slug containing a
                # literal quote+space could break out of that single argument
                # and inject extra msedge.exe command-line switches, not just
                # "break URL parsing". EscapeDataString percent-encodes
                # quotes/spaces/slashes/etc., closing that off for what
                # is meant to be a single opaque path segment; well-formed
                # slugs/ids (lowercase-alnum-hyphen / digits) round-trip
                # unchanged.
                if ($body.slug) {
                    $url = 'https://www.curseforge.com/wow/addons/' + [System.Uri]::EscapeDataString([string]$body.slug)
                } elseif ($body.projectId) {
                    $url = 'https://www.curseforge.com/projects/' + [System.Uri]::EscapeDataString([string]$body.projectId)
                }
                if (-not $url) {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'slug or projectId required' }
                    return
                }
                Open-InBrowser -Url $url
            }
            'lastrun' {
                $lastRunPath = Join-Path -Path $Script:Root -ChildPath 'last-run.txt'
                if (Test-Path -LiteralPath $lastRunPath) {
                    Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $lastRunPath + '"')
                } else {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'last-run.txt not found' }
                    return
                }
            }
            'backups' {
                # E7: Settings > Maintenance > "Open backups folder". The folder is
                # entirely owned by this app (populated by the rollback expansion, if
                # present) rather than something external whose absence is an error
                # condition, so - unlike 'folder'/'addons'/'lastrun' above - a missing
                # backups\ is created on the spot instead of failing the request.
                # FLAVORS-SPEC.md CS-F2: backups\ moved under
                # flavours\<flavour>\ (S3.1/S3.5) - $Script:BackupsPath is
                # already scoped to the request's own resolved flavour by
                # Set-CurrentFlavourContext.
                $backupsPath = $Script:BackupsPath
                if (-not (Test-Path -LiteralPath $backupsPath)) {
                    try {
                        New-Item -ItemType Directory -Path $backupsPath -Force | Out-Null
                    } catch {
                        Send-Json -Context $Context -StatusCode 500 -Body @{ error = "Could not create backups folder: $($_.Exception.Message)" }
                        return
                    }
                }
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $backupsPath + '"')
            }
            'logs' {
                # CS4 (UX-SPEC.md 6.2): Settings > Advanced > Troubleshooting's
                # single "Open logs folder" button, replacing the four
                # separate "Open sync log / Open last run report / Open
                # server log / Open backups folder" buttons. Rather than pick
                # one of those four files, this opens the app's own root
                # folder in Explorer - sync.log, server.log, last-run.txt and
                # backups\ all already live there side by side. Allow-listed
                # to exactly $Script:Root (no user-suppliable path here at
                # all, unlike 'url'/'curseforge' below). Created first if
                # somehow missing - mirrors 'backups' above, the app owns
                # this directory outright.
                if (-not (Test-Path -LiteralPath $Script:Root)) {
                    try {
                        New-Item -ItemType Directory -Path $Script:Root -Force | Out-Null
                    } catch {
                        Send-Json -Context $Context -StatusCode 500 -Body @{ error = "Could not create app folder: $($_.Exception.Message)" }
                        return
                    }
                }
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Script:Root + '"')
            }
            'url' {
                # E3: drawer's "Search CurseForge" button for a missing dependency,
                # used only when no API key is configured (a keyed session switches
                # to Browse client-side instead). Restricted to the addon
                # marketplaces and GitHub host this app ever links to (APP-UPDATE-
                # SPEC.md section 3.1 added github.com for the "What's new" release-
                # notes link), so this endpoint can never be used to open an
                # arbitrary URL in the user's default browser.
                #
                # Round 20 (adversarial bug pass, server-3): a plain
                # StartsWith prefix check on the raw string is not enough -
                # Open-InBrowser hands the whole string to Start-Process
                # -ArgumentList as ONE unquoted argument, and Windows
                # PowerShell 5.1 does not quote/escape it, so a URL like
                # "https://www.curseforge.com/x --app=http://evil/phish"
                # passes the StartsWith check yet still smuggles an extra
                # msedge.exe command-line switch past the allowlist. Validate
                # structurally instead (same pattern Open-CfSideWindow
                # already uses): parse as an absolute URI and require an
                # exact scheme+host match, then pass only the reparsed
                # AbsoluteUri onward - it is guaranteed free of spaces/quotes/
                # control characters, so it cannot inject extra argv tokens
                # regardless of what the caller sent.
                $url = $null
                if ($body.url) { $url = [string]$body.url }
                if (-not $url) {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'url required' }
                    return
                }
                $parsedOpenUrl = $null
                $isValidOpenUrl = [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$parsedOpenUrl)
                # APP-UPDATE-SPEC.md section 3.1: github.com added as a third
                # allowed host so #link-app-update-whatsnew/#banner-app-update-
                # whatsnew can open a release's own html_url
                # (github.com/krenz444/furphy-addon-manager/releases/tag/...)
                # the exact same way Actions.openOnWago already opens an
                # addons.wago.io URL - never a hand-built link, always the
                # release JSON's own html_url (persisted in app-update.json).
                $allowedOpenHosts = @('www.curseforge.com', 'addons.wago.io', 'github.com')
                $allowed = $false
                if ($isValidOpenUrl -and $parsedOpenUrl.Scheme -eq 'https') {
                    foreach ($allowedHost in $allowedOpenHosts) {
                        if ($parsedOpenUrl.Host.Equals($allowedHost, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $allowed = $true
                            break
                        }
                    }
                }
                if (-not $allowed) {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'url must start with https://www.curseforge.com/, https://addons.wago.io/, or https://github.com/' }
                    return
                }
                Open-InBrowser -Url $parsedOpenUrl.AbsoluteUri
            }
            'cf-window' {
                # Round 12 (E19b): the UI has posted this 'what' since round
                # 9 (Browse's "Search on CurseForge.com" box,
                # Actions.searchCurseForgeWebsite) but this server had no
                # case for it at all until now - every call landed on the
                # 'default: unknown what' branch below and toasted "Couldn't
                # open that: unknown what: cf-window". This is the
                # Edge-app-fallback path only: when running inside the
                # native host, ui\app.js's Host.openCurseForge intercepts
                # before this endpoint is ever called and routes into the
                # host's own embedded CurseForge tab instead (see the
                # 'open-curseforge' postMessage in SPEC.md's E19b section).
                # Narrower allowlist than 'url' above: curseforge.com ONLY,
                # not also wago.io - opening a side window for Wago never
                # made sense (Wago has no in-app tab to feed either).
                $url = $null
                if ($body.url) { $url = [string]$body.url }
                if (-not $url) {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'url required' }
                    return
                }
                if (-not $url.StartsWith('https://www.curseforge.com/', [System.StringComparison]::OrdinalIgnoreCase)) {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'url must start with https://www.curseforge.com/' }
                    return
                }
                if (-not (Open-CfSideWindow -Url $url)) {
                    Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'url contains invalid characters' }
                    return
                }
            }
            default {
                Send-Json -Context $Context -StatusCode 400 -Body @{ error = "unknown what: $what" }
                return
            }
        }
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        return
    }

    Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true }
}

function Handle-Uninstall {
    <#
      POST /api/uninstall (DISTRIBUTION-SPEC.md section 3.4/5.3): shaped
      almost exactly like Handle-Shutdown just below - reuses that same
      $Script:CurrentJobByFlavour busy-check loop rather than a second copy
      of it (the FLAVORS-SPEC.md CS-F2 S5.4 rule: refuse while ANY flavour
      has a job running, not just the request's own resolved flavour).
      Origin-header CSRF is already enforced by Invoke-Route for every
      non-GET route before this handler ever runs (Test-SameOriginRequest),
      matching /api/shutdown/settings/startup/*.

      Steps (section 5.3's invariant - this IS the one place the busy-check
      actually lives; every other trigger relies on "no server reachable
      implies no job can be running" instead of re-checking):
        1. Busy -> 409 plain-language body, nothing else happens (this
           check runs REGARDLESS of dryRun - it is a read, not a side
           effect, and a selftest run needs the same busy-routing answer a
           real caller would get).
        2. Copy $Script:Root\install.ps1 to a fresh GUID-suffixed %TEMP%
           path (fix 2 is what makes this file exist to copy at all).
        3. Launch that copy detached, hidden, with -WowPath <resolved
           wowRoot> -Uninstall. -NoShortcuts/-NoProtocol are never sent by
           the real UI (Actions.uninstallApp posts no body) - they exist
           ONLY so this round's own tests can request them, exactly as
           every other -Uninstall exercised in this codebase's test suite
           already requires (never touch the real Desktop/protocol
           registration from an automated run).

           Round 33 defect fix: install.ps1 -Uninstall now shows a plain-
           language WinForms MessageBox at the end by default (this whole
           process runs -WindowStyle Hidden, so that box is otherwise the
           ONLY visible sign a real user gets that their uninstall
           finished, or finished with leftovers). {"quiet":true} in the
           body forwards -Quiet to the spawned copy, suppressing it - the
           real UI never sends this (a real uninstall from Settings must
           show the result), it exists ONLY so this codebase's own
           automated tests can request it, same shape as noShortcuts/
           noProtocol above, so a detached unattended test run never
           blocks forever on MessageBox.Show waiting for a click that will
           never come.
        4. Respond 200 {"ok":true} once the copy is launched.
        5. $Script:ShuttingDown = $true right after responding - the
           existing main loop already polls this and exits, freeing the
           port, exactly like Handle-Shutdown.

      dryRun (round 33 fix for the round-32 "uninstall dry run is not
      actually dry" finding): when the request body carries
      {"dryRun":true} (FurphyHost.cs's RunUninstallSequence sends this on
      every --tray-selftest run and nowhere else), this handler still runs
      the busy-check and the WoW-root resolution above - so the caller
      gets the exact same routing answer (200/409/500) a real call would
      get - but returns BEFORE step 2 (the Copy-Item), so no temp script
      is ever written, no process is ever launched, and
      $Script:ShuttingDown is never set. A dry run can therefore never
      tear down a live server, no matter what fixture reaches it.
    #>
    param($Context, $RouteMatch)

    $anyRunning = $false
    foreach ($cj in @($Script:CurrentJobByFlavour.Values)) {
        if ($cj) {
            $refreshed = Update-JobStatus -Job $cj
            if ($refreshed -and $refreshed.state -eq 'running') { $anyRunning = $true }
        }
    }
    if ($anyRunning) {
        Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'Furphy is updating an addon right now. Try again in a minute.' }
        return
    }

    $noShortcuts = $false
    $noProtocol = $false
    $dryRun = $false
    # Round 33 defect fix (item 3): install.ps1 -Uninstall now shows a
    # plain-language WinForms MessageBox at the end by default (so a real
    # user running this exact route - Settings' own uninstall button -
    # actually sees the outcome, since this whole script runs -WindowStyle
    # Hidden and every Write-Warn2 line would otherwise be invisible). The
    # real UI (Actions.uninstallApp) never sends this field, so a real
    # uninstall still shows the box; only this codebase's own automated
    # tests set it true, exactly like noShortcuts/noProtocol/dryRun above,
    # so a detached, unattended test run never blocks forever on
    # MessageBox.Show waiting for a click that will never come.
    $quiet = $false
    try {
        $body = Read-Body -Context $Context
        if ($body) {
            # security:security-server-uninstall-bool-coercion-lies - a
            # bare [bool] cast treats ANY non-empty string as truthy (a
            # JSON STRING "false" silently becomes $true), the exact
            # hazard Round 20's ConvertTo-SettingsBool was introduced for -
            # every other boolean settings field in this file already goes
            # through it, but this Round-33-added handler was still using
            # the bare cast. For dryRun this let a stringified "false"
            # silently route a REAL uninstall request into the no-op dry-
            # run branch (server still answers 200 {"ok":true}, nothing
            # happens); for quiet specifically the same mistake silently
            # suppresses the WinForms completion MessageBox that is,
            # per this handler's own doc comment above, the ONLY visible
            # sign a real user gets that their uninstall finished, since
            # the whole process runs -WindowStyle Hidden.
            if ($body.PSObject.Properties.Match('noShortcuts').Count -gt 0) { $noShortcuts = ConvertTo-SettingsBool $body.noShortcuts }
            if ($body.PSObject.Properties.Match('noProtocol').Count -gt 0) { $noProtocol = ConvertTo-SettingsBool $body.noProtocol }
            if ($body.PSObject.Properties.Match('dryRun').Count -gt 0) { $dryRun = ConvertTo-SettingsBool $body.dryRun }
            if ($body.PSObject.Properties.Match('quiet').Count -gt 0) { $quiet = ConvertTo-SettingsBool $body.quiet }
        }
    } catch {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $_.Exception.Message }
        return
    }

    $wowRootPath = Get-FlavourWowRootPath -Flavor 'retail'
    if (-not $wowRootPath) { $wowRootPath = Get-FlavourWowRootPath }
    if (-not $wowRootPath) {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = 'Could not resolve the WoW folder for this install.' }
        return
    }

    if ($dryRun) {
        # Routing proven (not busy, WoW root resolves) - stop here. No
        # Copy-Item, no Start-Process, no $Script:ShuttingDown: this
        # request must be a no-op on the server's own state no matter
        # which fixture or port it lands on.
        Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true; dryRun = $true }
        return
    }

    $tempCopy = Join-Path -Path $env:TEMP -ChildPath ('FurphyUninstall-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        Copy-Item -LiteralPath (Join-Path -Path $Script:Root -ChildPath 'install.ps1') -Destination $tempCopy -Force
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = "Could not prepare the uninstaller: $($_.Exception.Message)" }
        return
    }

    try {
        $psArgs = New-Object 'System.Collections.Generic.List[string]'
        $psArgs.Add('-NoProfile'); $psArgs.Add('-ExecutionPolicy'); $psArgs.Add('Bypass')
        $psArgs.Add('-File'); $psArgs.Add((ConvertTo-SafeProcessArg $tempCopy))
        $psArgs.Add('-WowPath'); $psArgs.Add((ConvertTo-SafeProcessArg $wowRootPath))
        $psArgs.Add('-Uninstall')
        if ($noShortcuts) { $psArgs.Add('-NoShortcuts') }
        if ($noProtocol) { $psArgs.Add('-NoProtocol') }
        if ($quiet) { $psArgs.Add('-Quiet') }
        Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs.ToArray() -WindowStyle Hidden | Out-Null
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = "Could not launch the uninstaller: $($_.Exception.Message)" }
        return
    }

    Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true }
    $Script:ShuttingDown = $true
}

function Handle-Shutdown {
    param($Context, $RouteMatch)

    # FLAVORS-SPEC.md CS-F2 S5.4: refuse shutdown while ANY flavour has a job
    # running, not just the request's own resolved flavour - a background
    # Classic Era sync must still block a shutdown triggered from a Retail
    # browser tab.
    $anyRunning = $false
    foreach ($cj in @($Script:CurrentJobByFlavour.Values)) {
        if ($cj) {
            $refreshed = Update-JobStatus -Job $cj
            if ($refreshed -and $refreshed.state -eq 'running') { $anyRunning = $true }
        }
    }
    if ($anyRunning) {
        Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'busy: a job is running' }
        return
    }
    Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true }
    $Script:ShuttingDown = $true
}

# =====================================================================
# APP-UPDATE-SPEC.md - self-updater (Package A: state machine, settings,
# GitHub pipeline). $Script:AppUpdatePath (set alongside $Script:SettingsPath
# in the startup section below) is app-update.json - sibling of settings.json/
# state.json, operational state rather than a user setting, so it gets its
# own file rather than being folded into either (section 4).
# =====================================================================

function Get-DefaultAppUpdateState {
    <# APP-UPDATE-SPEC.md section 4: the shape of app-update.json, and what
       a MISSING file is read as - state "idle", currentVersion mirroring
       $Script:Version, everything else $null. rateLimitedUntil is this
       implementation's own addition (Eric's Q2 decision: honour GitHub's
       Retry-After/X-RateLimit-Reset on a 403/429 before the next AUTOMATIC
       check, capped at 6 hours) - purely additive, never read by
       install.ps1's own direct writes (section 8.6), so Package B's shape
       expectations for this file are unaffected. testDryRunCommandLine is
       TEST-ONLY (FURPHY_TEST_APPUPDATE_DRYRUN, see Handle-AppUpdateInstall)
       - declared here rather than added ad hoc via dot-assignment because
       Windows PowerShell 5.1's [PSCustomObject] (unlike PS7+) throws
       "the property ... cannot be found on this object" on an attempt to
       set a property that was not present at construction time; confirmed
       live while verifying this round. #>
    return [PSCustomObject]@{
        state                  = 'idle'
        currentVersion         = $Script:Version
        latestVersion          = $null
        releaseTag             = $null
        releaseUrl             = $null
        assetUrl               = $null
        shaAssetUrl            = $null
        checkedAt              = $null
        downloadedAt           = $null
        stagedPath             = $null
        installAttemptedAt     = $null
        installedAt            = $null
        lastError              = $null
        lastErrorAt            = $null
        deferredReason         = $null
        windowOpenAt           = $null
        rateLimitedUntil       = $null
        testDryRunCommandLine  = $null
    }
}

function Save-AppUpdateState {
    <# Atomic tmp+Move-Item write, byte-for-byte mirroring Save-Settings
       (addon-server.ps1:1390-1397) - app-update.json gets the exact same
       crash-safety treatment even though it is operational state, not a
       user setting. install.ps1 -Upgrade's own rollback path (section 8.6)
       writes this same file directly via plain file I/O when it runs
       (outside this process entirely) - this server always re-reads it
       fresh on its next access, so the two writers never need to
       coordinate beyond "atomic write, one file". #>
    param($State)

    $json = ConvertTo-Json -InputObject $State -Depth 5
    $tmpPath = "$Script:AppUpdatePath.tmp"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmpPath, $json, $encoding)
    Move-Item -LiteralPath $tmpPath -Destination $Script:AppUpdatePath -Force
}

function Get-AppUpdateState {
    <# Reads app-update.json, tolerating a missing or corrupt file (section
       4's "no migration needed" contract) - unlike Get-Settings this never
       rewrites the file on a mere read: there is no user-authored content
       here to repair/preserve, so a missing/corrupt file is just re-derived
       from defaults every time, and the next real state change writes it
       via Save-AppUpdateState anyway. currentVersion is always overridden
       to the LIVE $Script:Version on the way out, regardless of whatever
       value is on disk - section 4 describes this field as "mirrors
       $Script:Version", i.e. a live fact, not a stored one; this keeps it
       correct even immediately after an in-place upgrade re-launch, before
       anything in this process has rewritten the file. #>
    $defaults = Get-DefaultAppUpdateState
    if (-not (Test-Path -LiteralPath $Script:AppUpdatePath -PathType Leaf)) {
        return $defaults
    }
    try {
        $raw = Get-Content -LiteralPath $Script:AppUpdatePath -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $defaults }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $result = Get-DefaultAppUpdateState
        foreach ($p in $result.PSObject.Properties) {
            $name = $p.Name
            $val = $obj.$name
            if ($null -ne $val) { $result.$name = $val }
        }
        $result.currentVersion = $Script:Version
        return $result
    } catch {
        Write-ServerLog "Failed to read app-update.json, using defaults: $($_.Exception.Message)"
        return $defaults
    }
}

function Get-AppUpdateVersionFromTag {
    <# Strips a leading "v"/"V" from a GitHub release tag_name (e.g.
       "v1.23.0" -> "1.23.0"), case-insensitively - GitHub's own tag
       convention. Never itself validates the result as a real version;
       Test-AppUpdateVersionNewer's [System.Version] parse is what actually
       validates it (APP-UPDATE-SPEC.md section 8.4: "case-insensitive,
       leading 'v' stripped"). #>
    param([string]$Tag)

    if ([string]::IsNullOrWhiteSpace($Tag)) { return '' }
    $t = $Tag.Trim()
    if ($t.Length -gt 0 -and ($t.Substring(0, 1) -eq 'v' -or $t.Substring(0, 1) -eq 'V')) {
        return $t.Substring(1)
    }
    return $t
}

function Test-AppUpdateVersionNewer {
    <# Returns $true only when $Candidate is STRICTLY newer than $Current,
       using [System.Version] compare - the exact idiom install.ps1's own
       downgrade guard already uses (install.ps1:1562: "1.9.0" must not sort
       ahead of "1.10.0", which a plain string compare would get wrong),
       reused verbatim rather than reimplemented (APP-UPDATE-SPEC.md section
       8.2). Never throws: a malformed version string on either side is
       treated as "not newer" rather than raising - Server.
       AppUpdateVersionCompare.Tests.ps1 (section 12) exercises this
       directly against equal/older/malformed inputs. #>
    param([string]$Current, [string]$Candidate)

    if ([string]::IsNullOrWhiteSpace($Current) -or [string]::IsNullOrWhiteSpace($Candidate)) { return $false }
    $currentParsed = $null
    $candidateParsed = $null
    if (-not [System.Version]::TryParse($Current.Trim(), [ref]$currentParsed)) { return $false }
    if (-not [System.Version]::TryParse($Candidate.Trim(), [ref]$candidateParsed)) { return $false }
    return ($candidateParsed.CompareTo($currentParsed) -gt 0)
}

function Get-AppUpdateAssetsFromRelease {
    <# APP-UPDATE-SPEC.md section 8.2: given one GitHub releases/latest (or
       releases/tags/<tag>) response object, returns the exact-name-matched
       zip + .sha256 sidecar - "FurphyAddonManager-<tag-without-v>.zip" and
       that name + ".sha256" - or $null if either is missing. Exact name
       match only, NEVER "first .zip found" - Server.AppUpdateReleaseParse.
       Tests.ps1 (section 12) exercises a release with extra unrelated
       assets present to prove this. Every URL comes from the asset's OWN
       browser_download_url, never hand-built (section 8.2's own note),
       so a test's FURPHY_TEST_GITHUB_BASEURL stub can point assets anywhere
       it likes, including back at itself. #>
    param($Release)

    if ($null -eq $Release -or [string]::IsNullOrWhiteSpace([string]$Release.tag_name)) { return $null }
    $version = Get-AppUpdateVersionFromTag -Tag ([string]$Release.tag_name)
    if ($version.Length -eq 0) { return $null }
    $zipName = "FurphyAddonManager-$version.zip"
    $shaName = "$zipName.sha256"

    $zipUrl = $null
    $shaUrl = $null
    foreach ($asset in @($Release.assets)) {
        if (-not $asset) { continue }
        $assetName = [string]$asset.name
        if ($assetName -eq $zipName) {
            $zipUrl = [string]$asset.browser_download_url
        } elseif ($assetName -eq $shaName) {
            $shaUrl = [string]$asset.browser_download_url
        }
    }
    if (-not $zipUrl -or -not $shaUrl) { return $null }

    $releaseUrl = $null
    if ($Release.html_url) { $releaseUrl = [string]$Release.html_url }
    return [PSCustomObject]@{
        ZipUrl     = $zipUrl
        ShaUrl     = $shaUrl
        Version    = $version
        Tag        = [string]$Release.tag_name
        ReleaseUrl = $releaseUrl
    }
}

function Get-AppUpdateDateTimeStyles {
    <# The exact DateTimeStyles this file's other ParseExact call sites
       already use for a 'yyyy-MM-ddTHH:mm:ssZ' stamp (e.g. Test-DiagLastSync's
       neighbor at line ~6740) - AssumeUniversal + AdjustToUniversal, so a
       parsed value round-trips as UTC regardless of the local machine's own
       time zone. Factored into one place since app-update.json now has four
       separate stamps that all need parsing back (installAttemptedAt,
       checkedAt, windowOpenAt, rateLimitedUntil). #>
    return ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
}

function ConvertTo-AppUpdateUtcDateTime {
    <# Parses one of app-update.json's ISO 8601 UTC stamps back into a
       [DateTime] using the shared styles above; returns $null (never
       throws) on a missing/unparseable value - every caller treats that the
       same way "no timestamp yet" would be treated. #>
    param([string]$Iso)

    if ([string]::IsNullOrWhiteSpace($Iso)) { return $null }
    try {
        return [DateTime]::ParseExact($Iso, 'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture, (Get-AppUpdateDateTimeStyles))
    } catch {
        return $null
    }
}

function Get-AppUpdateStatusObject {
    <# APP-UPDATE-SPEC.md section 5: the FIXED shape shared verbatim by GET
       /api/app-update/status's own body and Handle-State's `appUpdate`
       fold-in - built fresh from app-update.json + settings.
       appUpdateAutoInstall on every call, so the two callers can never
       drift apart. `windowOpen` is the only field computed live (section
       7): (Get-Date) - windowOpenAt < 15 seconds, comfortably above the
       SPA's own 5s poll interval so a genuinely open window is never
       misread as closed. #>
    param($Settings)

    $state = Get-AppUpdateState
    $windowOpen = $false
    $openedAt = ConvertTo-AppUpdateUtcDateTime -Iso ([string]$state.windowOpenAt)
    if ($openedAt) {
        $windowOpen = (((Get-Date).ToUniversalTime() - $openedAt).TotalSeconds -lt 15)
    }

    return [PSCustomObject]@{
        state          = $state.state
        currentVersion = $state.currentVersion
        latestVersion  = $state.latestVersion
        releaseTag     = $state.releaseTag
        releaseUrl     = $state.releaseUrl
        checkedAt      = $state.checkedAt
        downloadedAt   = $state.downloadedAt
        installedAt    = $state.installedAt
        lastError      = $state.lastError
        autoInstall    = [bool]$Settings.appUpdateAutoInstall
        deferredReason = $state.deferredReason
        windowOpen     = $windowOpen
    }
}

function Set-AppUpdateWindowOpenAt {
    <# APP-UPDATE-SPEC.md section 7: stamps app-update.json's windowOpenAt to
       "now" - called from Handle-State ONLY (verified there to be reached
       only by the SPA's own poll and MainForm's protocol-link handler, both
       of which require a window to be open), NEVER from a global per-
       request hook, which is exactly the self-poisoning shape section 7
       calls out and rejects (the tray's own PingUrl/JobsUrl/JobUrl traffic,
       and this signal's own status-poll reader, would otherwise keep
       re-arming it). Best-effort and silent: a failed write here must never
       affect /api/state's own response - Handle-State's normal body is
       unaffected either way. #>
    try {
        $state = Get-AppUpdateState
        $state.windowOpenAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Save-AppUpdateState -State $state
    } catch {
        Write-ServerLog "App-update: failed to stamp windowOpenAt: $($_.Exception.Message)"
    }
}

function Test-AppUpdateChildRunning {
    <# Same best-effort PID-liveness contract as Test-MaintenanceChildRunning
       just above (this is a distinct lock, $Script:AppUpdateLockPath - see
       its own declaration for why the app-update pipeline needs a SEPARATE
       one rather than sharing $Script:MaintenanceLockPath). Never throws;
       a stale lock (a crashed prior child) is cleaned up right here, same
       "verify the PID, don't just trust the file's existence" pattern.

       REFIX (this round): the lock file used to hold ONLY the PID as bare
       text - a live-but-UNRELATED process later reusing that exact PID
       (Windows recycles PIDs; not rare on a long-lived machine) would read
       back as "still running" FOREVER, since nothing ever re-validates
       WHOSE process it actually is. Confirmed live while verifying this
       round as the mechanism that can turn the stuck-"checking" race
       (Invoke-AppUpdateMaintenance's own doc comment) from "self-heals
       once the real owner finishes" into "wedged until someone manually
       deletes app-update-maintenance.lock" - once Test-AppUpdateChildRunning
       is permanently wrong, EVERY future caller (the hourly -MaintenanceOnly
       tick AND every "Check now" click) is blocked from ever entering
       Invoke-AppUpdateMaintenanceCore again, so fix (c)'s stuck-checking/
       downloading watchdog just below in Invoke-AppUpdateMaintenanceCore
       never even gets a chance to run either. Fixed by writing (and now
       requiring) "<pid>:<processStartTimeUtcTicks>" instead of a bare PID
       (Invoke-AppUpdateMaintenance's own lock-write, just below) - a live
       process with a matching PID but a DIFFERENT start time is exactly
       the recycled-PID case, and is now treated the same as a dead PID:
       stale, lock deleted, caller proceeds. A live process whose StartTime
       cannot even be READ (e.g. access denied) is treated the same way -
       unverifiable is not the same as verified, and the whole point of
       this fix is to stop trusting a lock we cannot actually confirm. #>
    if (-not $Script:AppUpdateLockPath -or -not (Test-Path -LiteralPath $Script:AppUpdateLockPath -PathType Leaf)) {
        return $false
    }
    try {
        $lockText = (Get-Content -LiteralPath $Script:AppUpdateLockPath -Raw -ErrorAction Stop).Trim()
        $parts = $lockText -split ':', 2
        $pidValue = 0
        $lockStartTicks = 0L
        if ($parts.Count -eq 2 -and [int]::TryParse($parts[0], [ref]$pidValue) -and $pidValue -gt 0 -and [long]::TryParse($parts[1], [ref]$lockStartTicks) -and $lockStartTicks -gt 0) {
            $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
            if ($proc) {
                try {
                    if ($proc.StartTime.ToUniversalTime().Ticks -eq $lockStartTicks) {
                        return $true
                    }
                } catch {
                    # StartTime unreadable for this PID (e.g. access denied,
                    # or the process exited between Get-Process and here) -
                    # cannot confirm ownership, so don't assume it - falls
                    # through to the stale-lock cleanup below, same as a
                    # dead or mismatched PID.
                }
            }
        }
    } catch {
        # Falls through to the stale-lock cleanup below.
    }
    try { Remove-Item -LiteralPath $Script:AppUpdateLockPath -Force -ErrorAction SilentlyContinue } catch { }
    return $false
}

function Invoke-AppUpdateMaintenance {
    <# Thin, lock-acquiring wrapper around Invoke-AppUpdateMaintenanceCore
       (the real pipeline, just below) - closes a real race confirmed live
       while verifying this round: the very first -MaintenanceOnly tick
       after startup "always qualifies" and now itself calls this function
       unconditionally, gated only by ITS OWN 24h/rate-limit checks (which a
       brand-new app-update.json's null checkedAt never blocks) - a "Check
       now" click landing in that same narrow startup window would
       otherwise spawn a SECOND, fully concurrent -AppUpdateOnly child
       racing the first over the exact same release-lookup/download/extract
       work, including two concurrent downloads to the identical
       cache\app-update\*.zip path. Skips entirely (does nothing, not even
       the watchdog) when another app-update child already holds the lock -
       the other instance's own tick already covers this one.

       The lock file is written as "<ownPid>:<ownProcessStartTimeUtcTicks>",
       not a bare PID - see Test-AppUpdateChildRunning's own doc comment
       (this round's REFIX) for why the second field exists: it is what
       lets a future reader tell a genuinely-live child of ours apart from
       an unrelated process that later happens to reuse the same PID. #>
    param([switch]$Force)

    if (Test-AppUpdateChildRunning) { return }
    $lockAcquired = $false
    try {
        if (-not (Test-Path -LiteralPath $Script:CacheDir)) { New-Item -ItemType Directory -Path $Script:CacheDir -Force | Out-Null }
        $ownStartTicks = 0L
        try { $ownStartTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks } catch { $ownStartTicks = 0L }
        [System.IO.File]::WriteAllText($Script:AppUpdateLockPath, "$PID`:$ownStartTicks")
        $lockAcquired = $true
    } catch {
        # Best-effort, matching Test-MaintenanceChildRunning's own lock -
        # a failed lock write never blocks the real work below.
    }
    if ($lockAcquired) {
        # Round 42.1: make the on-disk state agree with the lock the moment
        # it is held. Handle-AppUpdateCheck's "already running" branch
        # (Test-AppUpdateChildRunning true) deliberately writes nothing, so
        # a caller polling GET /api/app-update/status in the short gap
        # between this lock acquisition and Invoke-AppUpdateMaintenanceCore's
        # own state="checking" write still saw a stale "idle" and stopped
        # waiting too early (the rate-limit integration test caught this
        # once under the full gate). Every exit of the Core rewrites the
        # file, and the stuck-checking watchdog covers a child that dies,
        # so this can never strand a "checking". Never downgrade an
        # in-flight download, a staged "ready" or an install.
        try {
            $inflight = Get-AppUpdateState
            if (@('idle', 'available', 'error') -contains [string]$inflight.state) {
                $inflight.state = 'checking'
                Save-AppUpdateState -State $inflight
            }
        } catch { }
    }
    try {
        Invoke-AppUpdateMaintenanceCore -Force:$Force
    } finally {
        if ($lockAcquired) { try { Remove-Item -LiteralPath $Script:AppUpdateLockPath -Force -ErrorAction SilentlyContinue } catch { } }
    }
}

function Remove-AppUpdateStaleStaging {
    <# APP-UPDATE-SPEC.md section 8.8, failure-with-rollback branch:
       "keep the staged folder and downloaded assets around for one more
       tick in case the failure was transient ... only delete them once a
       SUBSEQUENT check confirms the same tag is still not newer, or a
       fresh newer tag supersedes them." A leftover extraction folder
       (%TEMP%\FurphyUpdate-<tag>-<guid>) can outlive the app-update.json
       "error" state that install.ps1's own Invoke-InstallRollbackAndRelaunchOld
       writes (section 8.6) - that write is a read-merge-write
       (Set-InstallAppUpdateJsonFields, install.ps1) that only ever
       touches state/lastError/lastErrorAt, so the PRE-EXISTING
       `stagedPath` value (pointing at the now-abandoned staged folder)
       survives untouched on disk. Nothing in install.ps1 ever revisits
       that folder again - the "one more tick" / "subsequent check"
       language in the spec places that job on the periodic maintenance
       pipeline instead, so it belongs here, not in install.ps1.

       Called only from the three points below where THIS SAME function
       call has just fully completed a check and reached one of the two
       spec-named outcomes (idle: "still not newer"; ready with a new
       $stagingRoot: "a fresh newer tag supersedes them") - never from a
       mid-check failure branch (rate limit, lookup failure, download
       failure, integrity failure, extraction failure, tag mismatch),
       since none of those "confirm" anything about a DIFFERENT, earlier
       leftover - they leave it for yet another tick, exactly as the
       "in case the failure was transient" reasoning intends. Best-effort
       and silent: a leftover temp folder that fails to delete is disk
       clutter, never a reason to fail an otherwise-successful check. #>
    param(
        [string]$StaleStagedPath,
        [string]$KeepPath
    )
    if (-not $StaleStagedPath) { return }
    if ($KeepPath -and [string]::Equals($StaleStagedPath, $KeepPath, [System.StringComparison]::OrdinalIgnoreCase)) { return }
    try {
        if (Test-Path -LiteralPath $StaleStagedPath) {
            Remove-Item -LiteralPath $StaleStagedPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-ServerLog "App-update: removed leftover staged folder from a prior failed/abandoned install attempt ($StaleStagedPath)"
        }
    } catch {
        # Best-effort only - see doc comment above.
    }
}

function Invoke-AppUpdateMaintenanceCore {
    <# APP-UPDATE-SPEC.md sections 4, 7, 8.1-8.4: the self-updater's own
       check/download/verify/stage pipeline against $Script:GitHubBaseUrl.
       Called from Invoke-AppUpdateMaintenance ONLY (the lock-acquiring
       wrapper just above) - from inside the existing -MaintenanceOnly
       try/finally (section 7 - self-gated below, respects the
       24h-since-last-check and rate-limit-backoff windows) AND from the
       new -AppUpdateOnly early-exit branch (-Force:$true - "Check now"
       bypasses both gates so a manual click feels instant, per section 7).

       Every exit point below writes app-update.json via Save-AppUpdateState
       and returns - this function never throws back into its caller (both
       call sites already wrap it in their own try/catch as an extra net,
       matching this file's "maintenance work never breaks the app"
       contract, but this stays true to that on its own too).

       Section 4's stuck-"installing" watchdog runs FIRST, unconditionally,
       on every call regardless of -Force - a hung install must clear on the
       very next tick of EITHER path, not just the automatic one.

       REFIX (this round) - a second watchdog, structurally identical to
       the "installing" one, runs immediately after it for a stuck
       "checking"/"downloading" state: >10 minutes for "checking", >60
       minutes for "downloading", both measured off app-update.json's OWN
       LastWriteTimeUtc (see this block's own comment just below for why
       the FILE's mtime, not a `state` field, is the right anchor here -
       the cleanest rule found in this pass, and the one that survives a
       real regression this round's own verifying caught: an earlier
       version of this fix stamped `checkedAt` from Handle-AppUpdateCheck
       too, which then falsely satisfied the 24h-since-last-check gate a
       few lines below for a COMPLETELY UNRELATED unforced caller - the
       periodic maintenance tick - racing to look at the same file before
       any real GitHub lookup had happened, silently folding a
       never-actually-checked "checking" straight back to "idle". mtime
       carries no such second meaning anywhere else in this file, so nothing
       else can be confused by an earlier write bumping it).

       Needed because "checking"/"downloading" can be left with no live
       owner in a way "installing" cannot: Handle-AppUpdateInstall spawns
       install.ps1 directly and nothing else in this file ever writes
       "installing", but "checking" is ALSO written synchronously by
       Handle-AppUpdateCheck itself (section 5), in the calling HTTP
       request, before the -AppUpdateOnly child it spawns has done
       anything at all - if that child then loses the
       Test-AppUpdateChildRunning race (another app-update child already
       holds $Script:AppUpdateLockPath) it returns having never reached
       THIS function, per that gate's own doc comment, leaving
       Handle-AppUpdateCheck's "checking" write with no one left to
       resolve it. The two REAL owners (a genuinely in-flight check/
       download in THIS SAME call, or a resumed one via the `$resuming`
       branch below) are unaffected by this watchdog: every write to
       app-update.json (Handle-AppUpdateCheck's own, and every one this
       function itself makes) goes through Save-AppUpdateState's atomic
       tmp+Move-Item, which bumps the file's real mtime every time - so
       this watchdog only ever fires on a leftover that NOTHING has
       written to in over 10/60 real minutes - by definition abandoned,
       since a live owner reaching this same function would already have
       moved it on with a fresh write of its own. #>
    param([switch]$Force)

    $nowUtc = (Get-Date).ToUniversalTime()
    $nowIso = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $state = Get-AppUpdateState
    # Section 8.8 cleanup gap fix: a settled "error" state can carry a
    # leftover `stagedPath` from an install attempt install.ps1 rolled
    # back from (see Remove-AppUpdateStaleStaging's own doc comment) -
    # captured HERE, before anything below mutates $state, so the THREE
    # confirmed-outcome call sites downstream can delete it once this
    # same call has actually confirmed one of the spec's two conditions.
    # Deliberately keyed off `stagedPath` alone, NOT `state -eq 'error'` -
    # confirmed live while verifying this round: Handle-AppUpdateCheck
    # (section 5) writes state="checking" to app-update.json SYNCHRONOUSLY,
    # in the calling HTTP request, before it ever spawns the
    # -AppUpdateOnly child that runs THIS function - so by the time this
    # child's own Get-AppUpdateState just above runs, an on-disk "error"
    # from install.ps1's own rollback has ALREADY been overwritten to
    # "checking" and would never be seen here. `stagedPath` is only ever
    # WRITTEN in one place in this whole file (the "ready" assignment
    # near the bottom of this function) - so ANY state other than the two
    # that legitimately still need it ("ready" itself, and "installing",
    # which reads it to build install.ps1's own command line) can only be
    # carrying a stale leftover, regardless of which transient state
    # happens to be sitting on disk when this particular call started.
    $staleStagedPath = $null
    if ($state.stagedPath -and $state.state -ne 'ready' -and $state.state -ne 'installing') {
        $staleStagedPath = [string]$state.stagedPath
    }
    # Failure-modes table (section 10): several failure branches below must
    # leave `state` UNCHANGED from what it was before this call. NOTE this
    # is deliberately NOT simply "whatever $state.state reads as right
    # now" - Handle-AppUpdateCheck (section 5) itself writes state="checking"
    # to disk SYNCHRONOUSLY, in the calling request, before ever spawning
    # the -AppUpdateOnly child that runs this function - so by the time
    # this function's own Get-AppUpdateState above runs, that transient
    # marker may already be sitting on disk with nothing real behind it
    # yet. Confirmed live while verifying this round: without the
    # 'checking'/'downloading' normalization below, a 403 response
    # "restored" state to 'checking' itself, leaving the status line stuck
    # on "Checking for updates..." forever - worse than the bug this
    # restore logic exists to fix. $preLookupState (used by the two
    # rate-limit/24h-freshness early-return gates AND the release-lookup
    # failure branches just below) collapses any such transient
    # leftover down to 'idle'; $preDownloadState (captured fresh,
    # immediately before the download step flips state to "downloading",
    # long after this function's own writes are the only thing touching
    # the file) is never subject to this hazard and is used for the
    # download-failure branch instead.
    if ($state.state -eq 'installing') {
        $stuck = $true
        $attemptedAt = ConvertTo-AppUpdateUtcDateTime -Iso ([string]$state.installAttemptedAt)
        if ($attemptedAt -and (($nowUtc - $attemptedAt).TotalMinutes -lt 5)) { $stuck = $false }
        if ($stuck) {
            $state.state = 'error'
            $state.lastError = 'the last update attempt did not finish - try Check now again.'
            $state.lastErrorAt = $nowIso
            try { Save-AppUpdateState -State $state } catch { Write-ServerLog "App-update watchdog: failed to write app-update.json: $($_.Exception.Message)" }
            Write-ServerLog 'App-update: stuck "installing" state cleared by watchdog'
        }
        return
    }

    if ($state.state -eq 'checking' -or $state.state -eq 'downloading') {
        # REFIX (this round): mirrors the "installing" watchdog just above -
        # runs FIRST, unconditionally, before the 24h/rate-limit gates and
        # the `$resuming` logic below get a chance to touch `state` at all
        # (both of those, on a leftover "checking"/"downloading", would at
        # best silently fold it back to "idle" with no explanation, and at
        # worst - the 24h gate specifically - leave it sitting for up to a
        # full day since `checkedAt` is left untouched by that gate; see
        # this function's own doc comment above).
        #
        # app-update.json's own on-disk LastWriteTimeUtc is the age anchor
        # for BOTH states, deliberately NOT `checkedAt` (a field this same
        # function's own 24h-since-last-check gate a few lines below also
        # reads, for a DIFFERENT purpose - "did we already make a real
        # GitHub call recently" - confirmed live while verifying this
        # round: stamping `checkedAt` from anywhere OTHER than a genuine
        # lookup attempt, even just to give this watchdog something to
        # measure, falsely satisfies THAT gate for any other unforced
        # caller that reads it before a real lookup has actually happened,
        # silently swallowing the check instead of performing it). The
        # file's own mtime needs no such care: EVERY write this pipeline
        # ever makes to app-update.json goes through Save-AppUpdateState's
        # atomic tmp+Move-Item, which bumps it - by construction, "how long
        # since anything last touched this file" is exactly "how long has
        # THIS on-disk checking/downloading marker gone unresolved",
        # nothing more.
        $stuck = $true
        $fileWriteAnchor = $null
        try {
            if (Test-Path -LiteralPath $Script:AppUpdatePath -PathType Leaf) {
                $fileWriteAnchor = (Get-Item -LiteralPath $Script:AppUpdatePath).LastWriteTimeUtc
            }
        } catch { $fileWriteAnchor = $null }
        $stuckThresholdMinutes = if ($state.state -eq 'checking') { 10 } else { 60 }
        if ($fileWriteAnchor -and (($nowUtc - $fileWriteAnchor).TotalMinutes -lt $stuckThresholdMinutes)) { $stuck = $false }
        if ($stuck) {
            $staleState = $state.state
            $state.state = 'error'
            $state.lastError = 'the last update check did not finish - try Check now again.'
            $state.lastErrorAt = $nowIso
            try { Save-AppUpdateState -State $state } catch { Write-ServerLog "App-update watchdog: failed to write app-update.json: $($_.Exception.Message)" }
            Write-ServerLog "App-update: stuck `"$staleState`" state cleared by watchdog"
            return
        }
        # Not stuck yet - fall through to the normal pipeline below, which
        # already handles both cases correctly on its own: a fresh-enough
        # "checking" is folded into `$preLookupState` and re-checked (or
        # normalized to idle by the 24h/rate-limit gates, same as before
        # this round), and a fresh-enough "downloading" is picked up by the
        # `$resuming` branch and retried.
    }

    if ($state.state -eq 'ready') {
        # Already staged, waiting for Install now/the tray's own eligible
        # cycle - nothing to check or download while a verified build sits
        # ready. Prevents re-fetching/re-downloading on every hourly tick
        # for as long as the user leaves an update sitting uninstalled.
        return
    }

    $resuming = (@('available', 'downloading') -contains $state.state)
    if (-not $resuming) {
        # Real settled states reaching this branch are only ever 'idle' or
        # 'error' ('ready'/'installing' already returned above; 'available'/
        # 'downloading' are the $resuming branch) - anything else (i.e. a
        # stale 'checking' Handle-AppUpdateCheck itself just wrote) is
        # normalized to 'idle', per this function's own top-of-file note.
        $preLookupState = $state.state
        if ($preLookupState -ne 'idle' -and $preLookupState -ne 'error') { $preLookupState = 'idle' }
        if (-not $Force) {
            # REFIX (verifier pass 1, finding 1): these two gates used to
            # `return` bare, discarding the $preLookupState normalization
            # computed just above. Handle-AppUpdateCheck (section 5) writes
            # state="checking" to disk SYNCHRONOUSLY, in the calling HTTP
            # request, before it ever spawns the -AppUpdateOnly child that
            # runs this function - so an unforced -MaintenanceOnly tick that
            # loses the Test-AppUpdateChildRunning race can observe that
            # transient "checking" marker here and, without this write,
            # exit through one of these two gates having done nothing at
            # all: the marker is then never resolved (checkedAt is also
            # left untouched by these gates, so the next hourly tick hits
            # the identical 24h/rate-limit gate again), leaving the status
            # line stuck on "Checking for updates..." forever. Mirrors every
            # other early-exit branch in this function, which already
            # restores state before returning.
            $limitedUntil = ConvertTo-AppUpdateUtcDateTime -Iso ([string]$state.rateLimitedUntil)
            if ($limitedUntil -and $nowUtc -lt $limitedUntil) {
                if ($state.state -ne $preLookupState) {
                    $state.state = $preLookupState
                    try { Save-AppUpdateState -State $state } catch { }
                }
                return
            }
            $checkedAt = ConvertTo-AppUpdateUtcDateTime -Iso ([string]$state.checkedAt)
            if ($checkedAt -and (($nowUtc - $checkedAt).TotalHours -lt 24)) {
                if ($state.state -ne $preLookupState) {
                    $state.state = $preLookupState
                    try { Save-AppUpdateState -State $state } catch { }
                }
                return
            }
        }

        # 8.1: release lookup.
        $userAgent = 'FurphyAddonManager/' + $Script:Version
        $releaseUri = $Script:GitHubBaseUrl + '/repos/krenz444/furphy-addon-manager/releases/latest'
        $state.state = 'checking'
        $state.checkedAt = $nowIso
        try { Save-AppUpdateState -State $state } catch { }

        $release = $null
        try {
            $resp = Invoke-WebRequest -Uri $releaseUri -Headers @{ 'User-Agent' = $userAgent; 'Accept' = 'application/vnd.github+json' } -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            $release = $resp.Content | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $statusCode = 0
            try { if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode } } catch { $statusCode = 0 }
            if ($statusCode -eq 403 -or $statusCode -eq 429) {
                # Eric's Q2 decision: honour Retry-After (seconds) or
                # X-RateLimit-Reset (unix epoch seconds) - Retry-After
                # preferred when present - capped at 6 hours, floored at 60s
                # so a header parse quirk can never produce a near-zero
                # backoff that just re-hits the limit next tick. No auth
                # token (unauthenticated 60/hr cap, section 8.1) - `state`
                # is left exactly as it was (never regressed to idle on a
                # failed re-check).
                $backoffSeconds = 3600
                try {
                    $retryAfterHeader = $_.Exception.Response.Headers['Retry-After']
                    $resetHeader = $_.Exception.Response.Headers['X-RateLimit-Reset']
                    if ($retryAfterHeader) {
                        $ras = 0
                        if ([int]::TryParse([string]$retryAfterHeader, [ref]$ras) -and $ras -gt 0) { $backoffSeconds = $ras }
                    } elseif ($resetHeader) {
                        $resetEpoch = 0L
                        if ([long]::TryParse([string]$resetHeader, [ref]$resetEpoch) -and $resetEpoch -gt 0) {
                            $resetAt = [DateTimeOffset]::FromUnixTimeSeconds($resetEpoch).UtcDateTime
                            $backoffSeconds = [Math]::Max(0, ($resetAt - $nowUtc).TotalSeconds)
                        }
                    }
                } catch { }
                if ($backoffSeconds -gt 21600) { $backoffSeconds = 21600 }
                if ($backoffSeconds -lt 60) { $backoffSeconds = 60 }
                $state.state = $preLookupState
                $state.rateLimitedUntil = $nowUtc.AddSeconds($backoffSeconds).ToString('yyyy-MM-ddTHH:mm:ssZ')
                $state.lastError = 'GitHub rate limit reached - try again later.'
                $state.lastErrorAt = $nowIso
                try { Save-AppUpdateState -State $state } catch { }
                Write-ServerLog "App-update check rate-limited by GitHub, will retry on the next tick (backoff $([int]$backoffSeconds)s)"
                return
            }
            $state.state = $preLookupState
            $state.lastError = "Couldn't check for updates - try again later."
            $state.lastErrorAt = $nowIso
            try { Save-AppUpdateState -State $state } catch { }
            Write-ServerLog "App-update check failed: $($_.Exception.Message)"
            return
        }
        $state.rateLimitedUntil = $null

        # 8.2: asset selection + version compare.
        $assets = Get-AppUpdateAssetsFromRelease -Release $release
        if (-not $assets) {
            $state.state = 'error'
            $state.lastError = "Couldn't check for updates - try again later."
            $state.lastErrorAt = $nowIso
            try { Save-AppUpdateState -State $state } catch { }
            Write-ServerLog "App-update check: release $([string]$release.tag_name) is missing the expected zip/.sha256 asset"
            return
        }
        if (-not (Test-AppUpdateVersionNewer -Current $Script:Version -Candidate $assets.Version)) {
            # Section 8.8: this check just confirmed the latest tag is
            # still not newer - any leftover staged folder from a prior
            # failed/rolled-back install is now settled-stale, per spec.
            Remove-AppUpdateStaleStaging -StaleStagedPath $staleStagedPath
            $state.state = 'idle'
            $state.stagedPath = $null
            $state.lastError = $null
            $state.lastErrorAt = $null
            try { Save-AppUpdateState -State $state } catch { }
            Write-ServerLog 'App-update check: already on the latest version'
            return
        }

        $state.state = 'available'
        $state.latestVersion = $assets.Version
        $state.releaseTag = $assets.Tag
        $state.releaseUrl = $assets.ReleaseUrl
        $state.assetUrl = $assets.ZipUrl
        $state.shaAssetUrl = $assets.ShaUrl
        try { Save-AppUpdateState -State $state } catch { }
    } else {
        # Resuming an incomplete prior run (section 7: "resumes rather than
        # re-checking") - reuse the release info already persisted from the
        # earlier successful lookup instead of spending another GitHub API
        # call on it.
        $assets = [PSCustomObject]@{
            ZipUrl     = $state.assetUrl
            ShaUrl     = $state.shaAssetUrl
            Version    = $state.latestVersion
            Tag        = $state.releaseTag
            ReleaseUrl = $state.releaseUrl
        }
        if (-not $assets.ZipUrl -or -not $assets.ShaUrl -or -not $assets.Version) {
            # Persisted state is incomplete somehow (hand-edited file, a
            # partial write) - fall back to idle rather than trying to
            # download with missing URLs.
            $state.state = 'idle'
            try { Save-AppUpdateState -State $state } catch { }
            Write-ServerLog 'App-update: resumable state was missing required fields, reset to idle'
            return
        }
    }

    $userAgent = 'FurphyAddonManager/' + $Script:Version

    # 8.3: download + integrity. $preDownloadState is captured FRESH here
    # (never the function-entry $state.state / $preLookupState above) -
    # by this point in the function, $state.state is either 'available'
    # (this SAME call just set it, a few lines above) or 'downloading'
    # (the $resuming branch, reusing an earlier successful lookup) - both
    # are real, current, non-stale facts this process itself just
    # established or read, unlike $preLookupState's own hazard above.
    $preDownloadState = $state.state
    $cacheDir = Join-Path -Path $Script:CacheDir -ChildPath 'app-update'
    try {
        if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
    } catch {
        $state.state = $preDownloadState
        $state.lastError = "Couldn't check for updates - try again later."
        $state.lastErrorAt = $nowIso
        try { Save-AppUpdateState -State $state } catch { }
        Write-ServerLog "App-update download failed: $($_.Exception.Message)"
        return
    }
    $zipPath = Join-Path -Path $cacheDir -ChildPath ("FurphyAddonManager-$($assets.Version).zip")
    $shaPath = "$zipPath.sha256"
    $state.state = 'downloading'
    try { Save-AppUpdateState -State $state } catch { }
    try {
        Invoke-WebRequest -Uri $assets.ZipUrl -Headers @{ 'User-Agent' = $userAgent } -UseBasicParsing -TimeoutSec 120 -OutFile $zipPath -ErrorAction Stop
        Invoke-WebRequest -Uri $assets.ShaUrl -Headers @{ 'User-Agent' = $userAgent } -UseBasicParsing -TimeoutSec 30 -OutFile $shaPath -ErrorAction Stop
    } catch {
        try { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath $shaPath -Force -ErrorAction SilentlyContinue } catch { }
        # Failure-modes table: "state stays as before" the download attempt
        # - restores to $preDownloadState (see its own capture above), never
        # left stuck at the transient "downloading" marker.
        $state.state = $preDownloadState
        $state.lastError = "download failed"
        $state.lastErrorAt = $nowIso
        try { Save-AppUpdateState -State $state } catch { }
        Write-ServerLog "App-update download failed: $($_.Exception.Message)"
        return
    }

    $shaExpected = $null
    try { $shaExpected = (Get-Content -LiteralPath $shaPath -Raw -ErrorAction Stop).Trim().ToLowerInvariant() } catch { $shaExpected = $null }
    $shaActual = $null
    try { $shaActual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath -ErrorAction Stop).Hash.ToLowerInvariant() } catch { $shaActual = $null }
    if (-not $shaExpected -or -not $shaActual -or $shaExpected -ne $shaActual) {
        try { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath $shaPath -Force -ErrorAction SilentlyContinue } catch { }
        $state.state = 'error'
        $state.lastError = 'integrity check failed'
        $state.lastErrorAt = $nowIso
        try { Save-AppUpdateState -State $state } catch { }
        Write-ServerLog "App-update integrity check FAILED for $($assets.Tag) - sha256 mismatch, discarding download"
        return
    }

    # 8.4: staged extraction (OUTSIDE $appDest, per the fixed decision) +
    # VERSION check.
    $stagingRoot = Join-Path -Path $env:TEMP -ChildPath ("FurphyUpdate-$($assets.Tag)-" + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $stagingRoot -Force -ErrorAction Stop
    } catch {
        try { Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath $shaPath -Force -ErrorAction SilentlyContinue } catch { }
        $state.state = 'error'
        $state.lastError = "Couldn't finish updating - kept your current version ($($Script:Version))."
        $state.lastErrorAt = $nowIso
        try { Save-AppUpdateState -State $state } catch { }
        Write-ServerLog "App-update extraction failed: $($_.Exception.Message)"
        return
    }

    $versionFilePath = Join-Path -Path $stagingRoot -ChildPath 'VERSION'
    $packageVersion = $null
    try { $packageVersion = [IO.File]::ReadAllText($versionFilePath).Trim() } catch { $packageVersion = $null }
    $tagVersion = Get-AppUpdateVersionFromTag -Tag $assets.Tag
    if (-not $packageVersion -or -not [string]::Equals($packageVersion, $tagVersion, [System.StringComparison]::OrdinalIgnoreCase)) {
        try { Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath $shaPath -Force -ErrorAction SilentlyContinue } catch { }
        $state.state = 'error'
        $state.lastError = "downloaded package's VERSION did not match the release"
        $state.lastErrorAt = $nowIso
        try { Save-AppUpdateState -State $state } catch { }
        Write-ServerLog "App-update package VERSION ($packageVersion) did not match release tag ($($assets.Tag)) - discarding"
        return
    }
    if (-not (Test-AppUpdateVersionNewer -Current $Script:Version -Candidate $packageVersion)) {
        try { Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath $shaPath -Force -ErrorAction SilentlyContinue } catch { }
        # Section 8.8: this check just confirmed the (re-resolved) tag is
        # still not newer - any leftover staged folder from a prior
        # failed/rolled-back install is now settled-stale, per spec.
        Remove-AppUpdateStaleStaging -StaleStagedPath $staleStagedPath
        $state.state = 'idle'
        $state.stagedPath = $null
        $state.lastError = $null
        $state.lastErrorAt = $null
        try { Save-AppUpdateState -State $state } catch { }
        Write-ServerLog 'App-update refused: staged version is not newer than the running version'
        return
    }

    # Section 8.8: a freshly-staged, verified-newer build now supersedes
    # any leftover staged folder from a prior failed/rolled-back install.
    Remove-AppUpdateStaleStaging -StaleStagedPath $staleStagedPath -KeepPath $stagingRoot
    $state.state = 'ready'
    $state.stagedPath = $stagingRoot
    $state.downloadedAt = $nowIso
    $state.lastError = $null
    $state.lastErrorAt = $null
    try { Save-AppUpdateState -State $state } catch { }
    try { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue } catch { }
    try { Remove-Item -LiteralPath $shaPath -Force -ErrorAction SilentlyContinue } catch { }
    Write-ServerLog "App-update: staged $($assets.Tag), ready to install"
}

function Handle-AppUpdateStatus {
    <# GET /api/app-update/status (APP-UPDATE-SPEC.md section 5). No CSRF
       (GET, read-only). #>
    param($Context, $RouteMatch)

    Send-Json -Context $Context -StatusCode 200 -Body (Get-AppUpdateStatusObject -Settings (Get-Settings))
}

function Handle-AppUpdateCheck {
    <# POST /api/app-update/check (APP-UPDATE-SPEC.md section 5) - "Check
       now" and any future caller. CSRF required (inherited automatically
       from Invoke-Route's Test-SameOriginRequest gate, like every other
       non-GET route in this file - no new CSRF code needed here).

       REFIX (this round, rule (b) of the stuck-"checking" fix): the
       idempotent dedup check below used to be state-based only (section
       5's own wording: "if state is already checking or downloading").
       Confirmed live while verifying this round: that leaves a gap right
       at server startup - the first -MaintenanceOnly tick's own unforced
       app-update check (Invoke-AppUpdateMaintenance's doc comment) can
       already hold $Script:AppUpdateLockPath while `state` on disk is
       STILL "idle" (it hasn't reached its own `state.state = 'checking'`
       write yet). A "Check now" landing in that exact window reads
       "idle", so the state-based check alone lets it through: THIS
       request then writes state="checking" itself and spawns a SECOND
       -AppUpdateOnly child, which loses the Test-AppUpdateChildRunning
       race inside Invoke-AppUpdateMaintenance and returns before ever
       reaching Invoke-AppUpdateMaintenanceCore - so the "checking" THIS
       request just wrote has no live owner left to resolve it (the
       watchdog in Invoke-AppUpdateMaintenanceCore is this round's
       backstop for exactly that, but the fix here is to not create the
       problem in the first place). Fixed by ALSO checking
       Test-AppUpdateChildRunning: the rule this function now follows is
       "only write state=checking when this same call is also the one
       about to spawn the child that owns resolving it" - if another
       app-update child (found via the lock, not just via `state`) is
       already running, this request changes nothing and just reports
       the current status, exactly like the state-based case already did.
       A child that later exits on that SAME dedup gate inside
       Invoke-AppUpdateMaintenance therefore never had a "checking" write
       attributed to it in the first place - there is nothing for it to
       leave behind uncleared.

       Deliberately does NOT also stamp `checkedAt` on this write (an
       earlier version of this fix did, to give Invoke-AppUpdateMaintenanceCore's
       stuck-checking/downloading watchdog - fix (c) - something fresh to
       measure) - confirmed live while verifying this round that doing so
       backfires: `checkedAt` is also what that same function's own
       24h-since-last-check gate reads, and stamping it here, before any
       real GitHub lookup has happened, falsely tells the NEXT unforced
       caller to read it (typically the periodic maintenance tick, racing
       this same request) "we already checked within 24h", silently
       folding its own attempt back to idle instead of letting it actually
       run. The watchdog anchors on app-update.json's own on-disk
       LastWriteTimeUtc instead (see its own doc comment) - this write's
       Save-AppUpdateState call already bumps that for free, so nothing
       extra is needed here. #>
    param($Context, $RouteMatch)

    $state = Get-AppUpdateState
    if ($state.state -eq 'checking' -or $state.state -eq 'downloading' -or (Test-AppUpdateChildRunning)) {
        # Idempotent - no double-spawn, mirroring Test-MaintenanceChildRunning's
        # own re-entrancy guard (addon-server.ps1's maintenance-child section).
        # The Test-AppUpdateChildRunning half is this round's own addition -
        # see this function's doc comment above for the race it closes.
        Send-Json -Context $Context -StatusCode 200 -Body (Get-AppUpdateStatusObject -Settings (Get-Settings))
        return
    }

    $state.state = 'checking'
    try {
        Save-AppUpdateState -State $state
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        return
    }

    try {
        # Hidden, detached -AppUpdateOnly child of THIS SAME SCRIPT - exact
        # ConvertTo-SafeProcessArg-quoted List[object]+Start-Process idiom
        # Invoke-MaintenanceTick already uses for its own -MaintenanceOnly
        # child, threading through the same test-only overrides so this
        # child resolves the identical game-running/root answer a test
        # expects.
        $psArgs = New-Object 'System.Collections.Generic.List[object]'
        $psArgs.Add('-NoProfile')
        $psArgs.Add('-ExecutionPolicy')
        $psArgs.Add('Bypass')
        $psArgs.Add('-File')
        $psArgs.Add((ConvertTo-SafeProcessArg $Script:ScriptSelfPath))
        $psArgs.Add('-Root')
        $psArgs.Add((ConvertTo-SafeProcessArg $Script:Root))
        $psArgs.Add('-AppUpdateOnly')
        if ($Script:WowRootOverride) {
            $psArgs.Add('-WowRoot')
            $psArgs.Add((ConvertTo-SafeProcessArg $Script:WowRootOverride))
        }
        if ($Script:BuildInfoPathOverride) {
            $psArgs.Add('-BuildInfoPath')
            $psArgs.Add((ConvertTo-SafeProcessArg $Script:BuildInfoPathOverride))
        }
        if ($Script:WowFakeProcessNameOverride) {
            $psArgs.Add('-WowFakeProcessName')
            $psArgs.Add((ConvertTo-SafeProcessArg $Script:WowFakeProcessNameOverride))
        }
        Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs.ToArray() -WindowStyle Hidden | Out-Null
        Write-ServerLog 'App-update check: spawned a -AppUpdateOnly child'
    } catch {
        Write-ServerLog "App-update check: failed to spawn -AppUpdateOnly child: $($_.Exception.Message)"
    }

    Send-Json -Context $Context -StatusCode 202 -Body @{ ok = $true; state = 'checking' }
}

function Handle-AppUpdateInstall {
    <# POST /api/app-update/install (APP-UPDATE-SPEC.md section 5) -
       "Install now" and the tray's own silent trigger, both funnelled
       through this ONE handler; the two callers differ only in the
       `relaunch` value they pass. CSRF required (inherited automatically). #>
    param($Context, $RouteMatch)

    $body = $null
    try {
        $body = Read-Body -Context $Context
    } catch {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = $_.Exception.Message }
        return
    }
    # REFIX (verifier pass 1, finding 4): section 5's contract is exactly
    # {"relaunch":"window"|"tray"} - the two real callers (SPA "Install now"/
    # the in-window banner, and the tray's own silent trigger) always send
    # one of those two literal strings. Anything else (missing, malformed, a
    # typo, or install.ps1's own TEST-ONLY "none" value, which is a CLI-only
    # concept for install.ps1 and never reachable through this HTTP route -
    # see tests\fixture-acceptance\AppUpdate.SilentUpgrade.Tests.ps1's own
    # header note) used to silently fall through to the 'window' default,
    # which is the RISKIER of the two real actions to take on unrecognized
    # input. 400 here instead of guessing.
    $relaunchRaw = $null
    if ($body) { $relaunchRaw = [string]$body.relaunch }
    if ($relaunchRaw -ne 'window' -and $relaunchRaw -ne 'tray') {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = "relaunch must be 'window' or 'tray'" }
        return
    }
    $relaunch = $relaunchRaw

    $state = Get-AppUpdateState
    if ($state.state -ne 'ready') {
        Send-Json -Context $Context -StatusCode 400 -Body @{ error = 'nothing staged to install' }
        return
    }

    # Same $Script:CurrentJobByFlavour busy-check loop Handle-Shutdown/
    # Handle-Uninstall already run - reused, not duplicated (section 5).
    $anyRunning = $false
    foreach ($cj in @($Script:CurrentJobByFlavour.Values)) {
        if ($cj) {
            $refreshed = Update-JobStatus -Job $cj
            if ($refreshed -and $refreshed.state -eq 'running') { $anyRunning = $true }
        }
    }
    if ($anyRunning) {
        $state.deferredReason = 'job-running'
        try { Save-AppUpdateState -State $state } catch { }
        Send-Json -Context $Context -StatusCode 409 -Body @{ error = 'busy: a job is running' }
        return
    }

    $wowRootPath = Get-FlavourWowRootPath -Flavor 'retail'
    if (-not $wowRootPath) { $wowRootPath = Get-FlavourWowRootPath }
    if (-not $wowRootPath) {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = 'Could not resolve the WoW folder for this install.' }
        return
    }

    $state.deferredReason = $null
    $state.state = 'installing'
    $state.installAttemptedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    try {
        Save-AppUpdateState -State $state
    } catch {
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        return
    }

    # Exact command line from section 5/8.5 - the fixed interface Package B
    # (install.ps1) builds against. Launched from the STAGED extraction
    # (never $Script:Root's own install.ps1) - this is what makes "runs from
    # OUTSIDE the app folder" and "detached from the server process it
    # replaces" true by construction.
    $psArgs = New-Object 'System.Collections.Generic.List[string]'
    $psArgs.Add('-NoProfile')
    $psArgs.Add('-ExecutionPolicy'); $psArgs.Add('Bypass')
    $psArgs.Add('-WindowStyle'); $psArgs.Add('Hidden')
    $psArgs.Add('-File'); $psArgs.Add((ConvertTo-SafeProcessArg (Join-Path -Path $state.stagedPath -ChildPath 'install.ps1')))
    $psArgs.Add('-WowPath'); $psArgs.Add((ConvertTo-SafeProcessArg $wowRootPath))
    $psArgs.Add('-Upgrade')
    $psArgs.Add('-Relaunch'); $psArgs.Add($relaunch)
    $psArgs.Add('-Console')
    $psArgs.Add('-Quiet')

    if (-not [string]::IsNullOrWhiteSpace($env:FURPHY_TEST_APPUPDATE_DRYRUN)) {
        # TEST-ONLY (never set outside a test harness, same contract as
        # every other FURPHY_TEST_* seam in this file): install.ps1 is
        # Package B's own file, under active parallel development, and this
        # build root's hard live-safety rules forbid running the host/tray/
        # window layers a real -Upgrade would relaunch - so this records the
        # fully-constructed command line into app-update.json instead of
        # spawning anything, letting a test assert on its exact shape
        # without ever invoking install.ps1.
        $state.testDryRunCommandLine = ($psArgs.ToArray() -join ' ')
        try { Save-AppUpdateState -State $state } catch { }
        Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true }
        return
    }

    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs.ToArray() -WindowStyle Hidden | Out-Null
    } catch {
        $state.state = 'error'
        $state.lastError = "Couldn't finish updating - kept your current version ($($Script:Version))."
        $state.lastErrorAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        try { Save-AppUpdateState -State $state } catch { }
        Send-Json -Context $Context -StatusCode 500 -Body @{ error = "Could not launch the installer: $($_.Exception.Message)" }
        return
    }

    Send-Json -Context $Context -StatusCode 200 -Body @{ ok = $true }
    $Script:ShuttingDown = $true
}

# =====================================================================
# Route table and dispatcher
# =====================================================================

$Script:Routes = @(
    @{ Method = 'GET'; Pattern = '^/api/ping$'; Handler = 'Handle-Ping' }
    @{ Method = 'GET'; Pattern = '^/api/state$'; Handler = 'Handle-State' }
    @{ Method = 'POST'; Pattern = '^/api/jobs$'; Handler = 'Handle-JobsPost' }
    @{ Method = 'GET'; Pattern = '^/api/jobs/(?<id>[^/]+)$'; Handler = 'Handle-JobsGetOne' }
    @{ Method = 'GET'; Pattern = '^/api/jobs$'; Handler = 'Handle-JobsGetAll' }
    @{ Method = 'POST'; Pattern = '^/api/addons/(?<id>[^/]+)/ignore$'; Handler = 'Handle-AddonIgnore' }
    @{ Method = 'POST'; Pattern = '^/api/addons/(?<id>[^/]+)/unpin$'; Handler = 'Handle-AddonUnpin' }
    @{ Method = 'GET'; Pattern = '^/api/addons/(?<id>[^/]+)/files$'; Handler = 'Handle-AddonFiles' }
    @{ Method = 'GET'; Pattern = '^/api/scan$'; Handler = 'Handle-ScanGet' }
    @{ Method = 'POST'; Pattern = '^/api/scan/delete$'; Handler = 'Handle-ScanDelete' }
    @{ Method = 'GET'; Pattern = '^/api/export$'; Handler = 'Handle-Export' }
    @{ Method = 'POST'; Pattern = '^/api/import$'; Handler = 'Handle-Import' }
    @{ Method = 'GET'; Pattern = '^/api/settings$'; Handler = 'Handle-SettingsGet' }
    @{ Method = 'PUT'; Pattern = '^/api/settings$'; Handler = 'Handle-SettingsPut' }
    # E19 (script itself is E17's, unchanged)
    @{ Method = 'GET'; Pattern = '^/api/protocol/status$'; Handler = 'Handle-ProtocolStatus' }
    @{ Method = 'POST'; Pattern = '^/api/protocol/register$'; Handler = 'Handle-ProtocolRegister' }
    @{ Method = 'POST'; Pattern = '^/api/protocol/unregister$'; Handler = 'Handle-ProtocolUnregister' }
    # Round 18 (tray stage B)
    @{ Method = 'GET'; Pattern = '^/api/tray/status$'; Handler = 'Handle-TrayStatus' }
    @{ Method = 'POST'; Pattern = '^/api/tray/start$'; Handler = 'Handle-TrayStart' }
    @{ Method = 'POST'; Pattern = '^/api/tray/stop$'; Handler = 'Handle-TrayStop' }
    @{ Method = 'POST'; Pattern = '^/api/startup/register$'; Handler = 'Handle-StartupRegister' }
    @{ Method = 'POST'; Pattern = '^/api/startup/unregister$'; Handler = 'Handle-StartupUnregister' }
    @{ Method = 'GET'; Pattern = '^/api/startup/status$'; Handler = 'Handle-StartupStatus' }
    @{ Method = 'GET'; Pattern = '^/api/diagnostics$'; Handler = 'Handle-Diagnostics' }
    # Round 16 (E22): the only CurseForge routes left, both keyless - every
    # key-gated /api/cf/* route (search/categories/mods/description/files/
    # changelog/resolve) was removed with the key feature itself. Round 17
    # removed the third, POST /api/cf/catalogue/refresh, with the manual
    # "Refresh the addon list from CurseForge" button that was its only
    # caller - the catalogue still refreshes itself automatically.
    @{ Method = 'GET'; Pattern = '^/api/cf/browse$'; Handler = 'Handle-CfBrowse' }
    @{ Method = 'GET'; Pattern = '^/api/cf/enrich/(?<id>[^/]+)$'; Handler = 'Handle-CfEnrich' }
    # Round 32 (WAGO-BROWSE-SPEC.md, Expansion E29): Handle-WagoSearch was
    # renamed Handle-WagoBrowse and widened into a real category/sort
    # browse - both route patterns dispatch to the SAME renamed handler so
    # /api/wago/search keeps answering exactly as before (additive fields
    # only) for any existing caller/mock fixture.
    @{ Method = 'GET'; Pattern = '^/api/wago/search$'; Handler = 'Handle-WagoBrowse' }
    @{ Method = 'GET'; Pattern = '^/api/wago/browse$'; Handler = 'Handle-WagoBrowse' }
    @{ Method = 'GET'; Pattern = '^/api/wago/categories$'; Handler = 'Handle-WagoCategories' }
    @{ Method = 'GET'; Pattern = '^/api/wago/resolve$'; Handler = 'Handle-WagoResolve' }
    @{ Method = 'GET'; Pattern = '^/api/wago/addons/(?<slug>[^/]+)/releases$'; Handler = 'Handle-WagoAddonReleases' }
    @{ Method = 'GET'; Pattern = '^/api/wago/addons/(?<slug>[^/]+)/gallery$'; Handler = 'Handle-WagoAddonGallery' }
    @{ Method = 'GET'; Pattern = '^/api/wago/addons/(?<slug>[^/]+)$'; Handler = 'Handle-WagoAddonDetails' }
    @{ Method = 'POST'; Pattern = '^/api/open$'; Handler = 'Handle-Open' }
    @{ Method = 'POST'; Pattern = '^/api/shutdown$'; Handler = 'Handle-Shutdown' }
    # Round 33 (DISTRIBUTION-SPEC.md section 3.4)
    @{ Method = 'POST'; Pattern = '^/api/uninstall$'; Handler = 'Handle-Uninstall' }
    # APP-UPDATE-SPEC.md section 5. Deliberately NOT added to
    # $Script:FlavourScopedEndpoints (that section's own flavour-routing
    # note) - none of the three handlers ever reads $Script:CurrentFlavourContext.
    @{ Method = 'GET'; Pattern = '^/api/app-update/status$'; Handler = 'Handle-AppUpdateStatus' }
    @{ Method = 'POST'; Pattern = '^/api/app-update/check$'; Handler = 'Handle-AppUpdateCheck' }
    @{ Method = 'POST'; Pattern = '^/api/app-update/install$'; Handler = 'Handle-AppUpdateInstall' }
)

function Test-SameOriginRequest {
    <#
      Round 20 (adversarial bug pass, security-2): CSRF guard for every
      state-changing (non-GET/HEAD) request. Modern browsers send an
      Origin header on such requests even when same-origin (falls back to
      Referer if Origin is somehow absent, e.g. an older client) - this
      requires it to resolve to this server's own http://localhost:<port>
      or http://127.0.0.1:<port> origin, so a page loaded from any other
      site cannot drive a state-changing endpoint (including a bare
      auto-submitting HTML form, which sends no body at all and so never
      goes through Read-Body's Content-Type check). The SPA's own
      same-origin fetch() calls always carry a matching Origin header, so
      this is a no-op for every legitimate caller.
    #>
    param($Context)

    $request = $Context.Request
    $candidate = $request.Headers['Origin']
    if ([string]::IsNullOrEmpty($candidate)) { $candidate = $request.Headers['Referer'] }
    if ([string]::IsNullOrEmpty($candidate)) { return $false }

    $parsedOrigin = $null
    if (-not [System.Uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref]$parsedOrigin)) { return $false }
    if ($parsedOrigin.Scheme -ne 'http') { return $false }
    if ($parsedOrigin.Port -ne $Script:Port) { return $false }
    $originHost = $parsedOrigin.Host.ToLowerInvariant()
    return ($originHost -eq 'localhost' -or $originHost -eq '127.0.0.1')
}

function Invoke-Route {
    <# Dispatches one request; never throws (every path returns a JSON response and always closes it). #>
    param($Context)

    $request = $Context.Request
    $method = $request.HttpMethod.ToUpperInvariant()
    $path = $request.Url.AbsolutePath

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $Script:LastResponseStatus = $null

    try {
        $matchedHandler = $null
        $routeMatch = @{}
        foreach ($route in $Script:Routes) {
            if ($route.Method -ne $method) { continue }
            if ($path -match $route.Pattern) {
                $matchedHandler = $route.Handler
                foreach ($key in $Matches.Keys) {
                    if ($key -ne '0') { $routeMatch[$key] = $Matches[$key] }
                }
                break
            }
        }

        if ($matchedHandler) {
            # Round 20 (adversarial bug pass, security-2): every matched
            # route past this point can change state (every GET route is
            # read-only) - gate non-GET/HEAD methods on Test-SameOriginRequest
            # before the handler ever runs, so no CSRF/foreign-origin request
            # reaches a state-changing endpoint regardless of what it sends.
            if ($method -ne 'GET' -and $method -ne 'HEAD' -and -not (Test-SameOriginRequest -Context $Context)) {
                Send-Json -Context $Context -StatusCode 403 -Body @{ error = 'forbidden: origin not allowed' }
            } else {
            # FLAVORS-SPEC.md CS-F2 S5.1: resolve this ONE request's flavour
            # before the handler ever runs, and stash it script-scope for the
            # handler to read (see that section's own header comment for why
            # this is safe on a single-threaded request loop). A resolution
            # failure (missing ?flavour= on a flavour-scoped endpoint while
            # >1 flavour is installed, or an unrecognized/not-installed
            # value) 400s here and never reaches the handler at all.
            $flavourResult = Resolve-RequestFlavour -Context $Context -Method $method -Path $path
            if (-not $flavourResult.Ok) {
                Send-Json -Context $Context -StatusCode $flavourResult.StatusCode -Body @{ error = $flavourResult.Error }
            } else {
                Set-CurrentFlavourContext -Flavor $flavourResult.Flavor
                & $matchedHandler $Context $routeMatch
            }
            }
        } elseif ($method -eq 'GET' -and (-not $path.StartsWith('/api/'))) {
            # E19: the native host (host\FurphyHost.cs) navigates its Furphy
            # tab to "http://localhost:<port>/?host=webview2" on first load;
            # the Edge --app window (Addon Manager.vbs's fallback) never adds
            # that query param. Sticky by design - once set, $Script:HostKind
            # stays 'webview2' for the life of the process (a later plain GET
            # / with no query, e.g. a manual reload, must not revert it) -
            # /api/ping (Handle-Ping) reports whichever value this settled on.
            if (($path -eq '/' -or $path -eq '/index.html') -and $request.QueryString['host'] -eq 'webview2') {
                $Script:HostKind = 'webview2'
            }
            $filePath = Get-StaticFilePath -UrlPath $path
            if (-not $filePath) {
                Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'not found' }
            } else {
                Send-File -Context $Context -Path $filePath
            }
        } else {
            Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'not found' }
        }
    } catch {
        try {
            Send-Json -Context $Context -StatusCode 500 -Body @{ error = $_.Exception.Message }
        } catch {
            $Script:LastResponseStatus = 500
        }
        Write-ServerLog "ERROR $method $path : $($_.Exception.Message)"
    }

    $sw.Stop()
    $statusForLog = $Script:LastResponseStatus
    if ($null -eq $statusForLog) { $statusForLog = 0 }
    Write-ServerLog "$method $path $statusForLog $($sw.ElapsedMilliseconds)ms"
}

# =====================================================================
# Dot-source guard (TESTING.md hook #1)
#
# Everything above this point (functions + static script-scope tables) is
# safe to define unconditionally - none of it has a side effect. Everything
# below is the real "run the server" body: it touches disk, binds an
# HttpListener socket, and blocks in the request loop. A normal invocation
# (`.\addon-server.ps1 ...` / `powershell.exe -File addon-server.ps1 ...`)
# must run it exactly as before - this guard only short-circuits when the
# script is DOT-SOURCED (". .\addon-server.ps1" or ". $path"), which is how
# tests\unit\*.Tests.ps1 loads these functions into Pester's scope without
# starting a real listener. $MyInvocation.InvocationName is the literal
# string "." when dot-sourced; the $MyInvocation.Line check is a fallback
# for hosts that report InvocationName differently.
# =====================================================================

$script:FurphyDotSourced = ($MyInvocation.InvocationName -eq '.') -or ($MyInvocation.Line -match '^\s*\.\s')
if ($script:FurphyDotSourced) {
    return
}

# =====================================================================
# Startup
# =====================================================================

if (-not $Root) {
    $Root = $PSScriptRoot
    if (-not $Root) { $Root = Split-Path -Path $MyInvocation.MyCommand.Path -Parent }
}

$Script:Root = $Root
# Round-1-fixer (WagoBrowse crawl integration-test root cause, not merely
# a timing/sync issue as first triaged): the ACTUAL path of THIS running
# script - deliberately NOT "Join-Path $Script:Root 'addon-server.ps1'"
# (what Invoke-MaintenanceTick used to build below). Those two are only
# guaranteed identical when -Root is omitted (defaults to $PSScriptRoot,
# above) or, when passed explicitly, happens to equal the script's own
# folder - true in every real production deployment (addon-server.ps1
# always lives directly inside the install root it is given as -Root),
# but NOT true for tests\lib\common.ps1's Start-TestServer, which
# deliberately runs the ONE shared build-root addon-server.ps1 against a
# throwaway scratch -Root that holds only per-test DATA (ui\/addons.json/
# cache\ etc, never a copy of the script itself - see Start-TestServer's
# own "T2 fix" comment for $Script:CliPath hitting this identical
# landmine for addon-sync.ps1 previously). Get-CurrentInstalledFlavours'
# own -ScriptRoot default already reads $Script:Root the old (now
# fixed-elsewhere) way for an unrelated purpose (locating flavours\) -
# untouched here, since THAT one path is a real, intentional data lookup,
# not "where is this script's own .ps1 file".
# Before this fix: Invoke-MaintenanceTick's spawned -MaintenanceOnly
# child's -File argument pointed at a nonexistent
# "<scratch-root>\addon-server.ps1", so the child process failed
# powershell.exe's own -File argument validation and exited immediately,
# before writing a single server.log line - confirmed live (repro script,
# 2026-09-08): the real server logged "Maintenance tick: spawned a
# -MaintenanceOnly child" and then nothing else, ever, while running the
# exact same -MaintenanceOnly invocation directly (bypassing Start-Process)
# against the script's REAL path completed the crawl correctly in ~4s.
# Zero live behavior change: $Script:ScriptSelfPath is byte-identical to
# the old "Join-Path $Script:Root 'addon-server.ps1'" value on every real
# deployment, where -Root IS the script's own folder.
$Script:ScriptSelfPath = $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($Script:ScriptSelfPath)) {
    $Script:ScriptSelfPath = Join-Path -Path $Script:Root -ChildPath 'addon-server.ps1'
}
$Script:UiDir = Join-Path -Path $Script:Root -ChildPath 'ui'
$Script:JobsDir = Join-Path -Path $Script:Root -ChildPath 'jobs'
$Script:SettingsPath = Join-Path -Path $Script:Root -ChildPath 'settings.json'
# APP-UPDATE-SPEC.md section 4: sibling of settings.json/state.json - the
# self-updater's own operational state, never a user setting.
$Script:AppUpdatePath = Join-Path -Path $Script:Root -ChildPath 'app-update.json'
$Script:StatePath = Join-Path -Path $Script:Root -ChildPath 'state.json'
$Script:AddonsJsonPath = Join-Path -Path $Script:Root -ChildPath 'addons.json'
$Script:ServerLogPath = Join-Path -Path $Script:Root -ChildPath 'server.log'

# FLAVORS-SPEC.md CS-F2 S5.1: startup self-check - every entry in
# $Script:FlavourScopedEndpoints (defined above, alongside $Script:Routes)
# must match a REAL registered route, so a typo'd Method/Pattern here (or a
# route renamed/removed without updating this list) fails loudly at startup
# instead of silently never 400ing a flavour-scoped call. Logged (now that
# $Script:ServerLogPath is finally set), not thrown - a startup log line a
# developer will actually see beats a hard crash for what is fundamentally a
# dev-time consistency check, not a user-facing failure mode.
foreach ($fse in $Script:FlavourScopedEndpoints) {
    $matched = $false
    foreach ($route in $Script:Routes) {
        if ($route.Method -eq $fse.Method -and $route.Pattern -eq $fse.Pattern) { $matched = $true; break }
    }
    if (-not $matched) {
        Write-ServerLog "STARTUP SELF-CHECK FAILED: FlavourScopedEndpoints entry '$($fse.Method) $($fse.Pattern)' matches no registered route in `$Script:Routes"
    }
}

$Script:SyncLogPath = Join-Path -Path $Script:Root -ChildPath 'sync.log'
$Script:CliPath = Join-Path -Path $Script:Root -ChildPath 'addon-sync.ps1'
# E19 (script itself is E17's, unchanged) - Invoke-ProtocolScript's target
# (register/unregister only, as of Round 37 - see Get-ProtocolStatusObject).
$Script:RegisterProtocolPath = Join-Path -Path $Script:Root -ChildPath 'register-protocol.ps1'
# Round 37 (server perf pass): register-protocol.ps1's own default
# -HandlerPath is "Join-Path $PSScriptRoot 'curseforge-handler.vbs'" - since
# Invoke-ProtocolScript always runs it with -File "$Script:RegisterProtocolPath"
# and no -HandlerPath override, $PSScriptRoot there is exactly $Script:Root,
# so this is byte-identical to what that script would resolve on its own.
$Script:CurseforgeHandlerPath = Join-Path -Path $Script:Root -ChildPath 'curseforge-handler.vbs'
# Test-only override seam for Get-ProtocolStatusObject's own registry read
# below (mirrors register-protocol.ps1's own -KeyPath test hook,
# tests\unit\RegisterProtocol.Tests.ps1) - overridden ONLY by a unit test
# that dot-sources this file (tests\unit\Server.ProtocolStatus.Tests.ps1),
# never by a real run, which always reads the one real per-user key.
$Script:CurseforgeProtocolKeyPath = 'HKCU:\Software\Classes\curseforge'
# E16: on-disk caches for the keyless CurseForge enrichment sources - the
# catalogue index (refreshed at most once/24h) and per-slug addon-radar.com
# detail pages (cached 24h each). Both directories are created lazily by
# their own writers (Save-CfCatalogueIndex / Get-AddonRadarDetail), the same
# "app owns this folder, create on first use" pattern already used for
# backups\ (E7's Handle-Open 'backups' case).
$Script:CacheDir = Join-Path -Path $Script:Root -ChildPath 'cache'
$Script:CfCatalogueCachePath = Join-Path -Path $Script:CacheDir -ChildPath 'cf-catalogue.json'
$Script:AddonRadarCacheDir = Join-Path -Path $Script:CacheDir -ChildPath 'addon-radar'
# Round 37 (server perf pass): the maintenance child's single-instance lock
# (its own PID, written/removed by the -MaintenanceOnly branch itself) - see
# Test-MaintenanceChildRunning/Invoke-MaintenanceTick, both near the request
# loop below.
$Script:MaintenanceLockPath = Join-Path -Path $Script:CacheDir -ChildPath 'maintenance.lock'
# APP-UPDATE-SPEC.md section 7: a second, SEPARATE lock for
# Invoke-AppUpdateMaintenance specifically - the very first
# -MaintenanceOnly tick after startup "always qualifies" (LastMaintenanceAttemptAt
# starts at MinValue) and now itself calls Invoke-AppUpdateMaintenance
# unconditionally (gated only by ITS OWN 24h/rate-limit checks, which a
# brand-new app-update.json's null checkedAt never blocks) - a "Check now"
# click landing in that same narrow startup window would otherwise spawn a
# SECOND, fully concurrent -AppUpdateOnly child racing the first over the
# exact same release-lookup/download/extract work (confirmed live while
# verifying this round: both children reached the same terminal state
# harmlessly on a deterministic stub, but two real concurrent downloads to
# the identical cache\app-update\*.zip path is a genuine corruption risk
# this closes). Same best-effort PID-liveness contract as
# Test-MaintenanceChildRunning/$Script:MaintenanceLockPath just above (not
# a true atomic mutex - matches this file's own established standard of
# care for this class of guard).
$Script:AppUpdateLockPath = Join-Path -Path $Script:CacheDir -ChildPath 'app-update-maintenance.lock'
$Script:AddonsPathOverride = $AddonsPath
$Script:IdleMinutes = $IdleMinutes
# GAME-MODE-SPEC.md (2026-09-08): this used to shorten the idle-exit window
# from the normal 20 minutes to 5 while a WoW client was running, on the
# theory that nothing should be polling this server during gameplay. That
# assumption is exactly what Eric's policy overturns - legitimate work
# (browsing, checks, updates, the hourly maintenance tick) now happens
# throughout a play session, so a quiet gap of a few minutes between
# requests no longer means "this server is stuck, tear it down." Dropped:
# $Script:IdleMinutesNormal is the only idle-exit window now, regardless of
# game state.
$Script:IdleMinutesNormal = $IdleMinutes
$Script:BuildInfoPathOverride = $BuildInfoPath
# Test-only substitution for Test-GameRunning (see its own doc comment) -
# set here, as early as possible, so it is already in effect before any
# later call to Test-GameRunning (job creation, /api/ping, /api/state, the
# request loop's own probe). Never set outside a test harness passing
# -WowFakeProcessName explicitly.
$Script:WowFakeProcessNameOverride = $WowFakeProcessName
# FLAVORS-SPEC.md CS-F2: overrides Get-InstalledFlavours'/Resolve-
# EffectiveAddonsPath's own WoW-root detection (S8's fixture path), the same
# way addon-sync.ps1's own -WowRoot does.
$Script:WowRootOverride = $WowRoot
$Script:AppName = 'Furphy Addon Manager'
# E18: the shipped version lives in one place - ROOT\VERSION (a bare string,
# e.g. "1.0.0") - so package.ps1's zip name and this server's own /api/ping
# report can never drift apart. Falls back to the last-known default when the
# file is missing (a dev checkout that predates E18) or unreadable.
$Script:Version = '1.23.0'
$Script:VersionPath = Join-Path -Path $Script:Root -ChildPath 'VERSION'
if (Test-Path -LiteralPath $Script:VersionPath) {
    try {
        $verText = [IO.File]::ReadAllText($Script:VersionPath).Trim()
        if ($verText.Length -gt 0) { $Script:Version = $verText }
    } catch {
        # Keep the fallback above; this must never block startup.
    }
}
$Script:StartTime = Get-Date
$Script:ShuttingDown = $false
$Script:LastResponseStatus = $null

$Script:Jobs = New-Object 'System.Collections.Generic.List[object]'
$Script:JobIdSeq = 0
# FLAVORS-SPEC.md CS-F2 S5.4: Test-JobBusy's single-job-at-a-time guard
# becomes PER-FLAVOUR scoped (a Retail sync and a Classic Era sync may run
# concurrently; two Retail syncs still can't) - $Script:CurrentJob (a single
# scalar) becomes a dictionary keyed by flavour id. $Script:Jobs (the shared
# rolling 20-job HISTORY, above) stays ONE list across every flavour, each
# job object now carrying its own .flavour field (S5.4) - only the "is a
# job currently running FOR THIS FLAVOUR" tracking is split out.
$Script:CurrentJobByFlavour = @{}
# FLAVORS-SPEC.md CS-F2 S5.3: freshness is computed "exactly the way today's
# single headline is, once per flavour" - so the bookkeeping that headline
# reads from becomes per-flavour too (keyed by flavour id), rather than one
# global scalar/hashtable shared across every flavour's addons.json.
$Script:UpdateAvailableByFlavour = @{}
$Script:LastRunByFlavour = @{}
$Script:UpdatesCheckedAtByFlavour = @{}
# CS1 (UX-SPEC.md section 4.2): in-memory only, never persisted to
# state.json (Save-CheckState is intentionally untouched by this pass) - a
# server restart forgets a stale failure, which is the right default: the
# freshness headline should reflect "have we actually seen a failure since
# this server came up", not resurrect one from a previous run. Per-flavour
# for the same S5.3 reason as the three dictionaries just above.
$Script:LastCheckFailedByFlavour = @{}
$Script:LastCheckErrorByFlavour = @{}
# Round 37 (server perf pass): Handle-State's per-flavour cache of the
# expensive per-record computations (tocInterfaces/compat/missingDeps/
# missingOptionalDeps) - see Get-HandleStateCacheKey/Get-AddonsFolderSnapshot/
# Clear-StateCache's own doc comments, all defined alongside Handle-State
# itself. In-memory only (never persisted) - a server restart recomputing
# once, cold, is the correct/only sane behavior, same as every other
# in-memory-only cache in this file.
$Script:AddonExtrasCacheByFlavour = @{}
# WAGO-BROWSE-SPEC.md section 4.4 (REQUIRED FIX, judge's data-review finding
# 2): makes "everything that mutates $Script:CurrentFlavour/
# $Script:ClientBuildInfo during startup, before the request loop's first
# BeginGetContext, is safe" a SELF-ENFORCING invariant instead of a
# doc-comment-only one. Flips to $true as the very first statement inside
# the request loop's own try block, right after BeginGetContext is first
# called (see that call site's own comment) - Initialize-WagoGrowthSnapshots
# throws immediately if it is ever called while this is already $true.
$Script:AcceptingRequests = $false
$Script:LastRequestTime = Get-Date
# E19: see Invoke-Route's static-file branch / Handle-Ping - flips to
# 'webview2' the first time the native host's Furphy tab loads.
$Script:HostKind = 'edge-app'
# E12: Wago Addons proxy state - WagoCache is a 5-minute response cache
# with a size-gated cleanup pattern; WagoInertiaVersion
# caches the site's Inertia asset version for the life of the process (and
# is persisted to/reloaded from state.json per SPEC's "cache the version in
# state.json" instruction, since this server, unlike the per-run CLI, stays
# up for a long time and would otherwise pay the plain-HTML handshake on
# every single Wago request).
$Script:WagoCache = @{}
$Script:WagoInertiaVersion = $null

# E16: keyless CurseForge enrichment state. CfCatalogueIndex/CfCatalogueById/
# CfCatalogueFetchedAt/CfCatalogueSource are populated by Initialize-
# CfCatalogueIndex below (disk cache load, or a fresh fetch when missing/
# stale); AddonRadarCache/AddonRadarSearchCache/WagoAutoMatchCache are
# in-memory 24h caches (the first also backed by an on-disk per-slug cache -
# see Get-AddonRadarDetail); LastAddonRadarRequestTime paces live
# addon-radar.com requests the same way LastRequestTime-style throttles are
# already used for Wago/CurseForge above.
$Script:CfCatalogueIndex = @()
$Script:CfCatalogueById = @{}
$Script:CfCatalogueFetchedAt = $null
$Script:CfCatalogueSource = $null
$Script:AddonRadarCache = @{}
$Script:AddonRadarSearchCache = @{}
$Script:WagoAutoMatchCache = @{}
$Script:LastAddonRadarRequestTime = [DateTime]::MinValue

# Round 37 (server perf pass): the serving process no longer fetches the
# CurseForge catalogue or crawls Wago growth itself (see the startup
# section's own comment, and Invoke-MaintenanceTick near the request loop) -
# a periodically-spawned hidden -MaintenanceOnly child does that instead,
# entirely off this process's own request-handling path.
#   MaintenanceIntervalMinutes: how often the request loop's own tick even
#     CONSIDERS spawning a child - not how often real network work happens
#     (each network-capable function is still separately, internally gated
#     on its own 24h/20h freshness check, unchanged - most attempts at this
#     cadence find nothing due and exit almost immediately).
#   LastMaintenanceAttemptAt: starts at [DateTime]::MinValue so the very
#     first request-loop tick after startup already qualifies ("shortly
#     after startup", per the task brief) - stamped the moment a child is
#     actually SPAWNED, not merely considered, so a tick that skipped
#     spawning (one already in flight) retries on the very next tick once
#     that condition clears instead of waiting out the full interval.
#   CfCatalogueCacheLastWriteUtc: the cache file's own LastWriteTimeUtc as
#     of this process's last successful load of it (startup, or the most
#     recent Update-CfCatalogueCacheIfChanged reload) - lets that per-tick
#     check stay a single cheap file stat on every tick that did NOT change
#     anything, which is nearly all of them. Seeded with the exact sentinel
#     [System.IO.File]::GetLastWriteTimeUtc returns for a MISSING file
#     (1601-01-01T00:00:00Z, i.e. [DateTime]::FromFileTimeUtc(0)) rather
#     than [DateTime]::MinValue, so a -Root whose cache\cf-catalogue.json
#     has never been written (most integration tests; a fresh install
#     before its first maintenance tick) compares equal on the very first
#     stat instead of always mismatching.
#   CfCatalogueCacheLastStatAt / CfCatalogueCacheStatIntervalSeconds (F1,
#     idle-loop perf pass; 30s - see Update-CfCatalogueCacheIfChanged's
#     own doc comment) - throttles that per-tick file stat itself, since a stat
#     this infrequent is still plenty fresh given the writer's own
#     at-most-hourly cadence.
$Script:MaintenanceIntervalMinutes = 60
$Script:LastMaintenanceAttemptAt = [DateTime]::MinValue
$Script:CfCatalogueCacheLastWriteUtc = [DateTime]::FromFileTimeUtc(0)
$Script:CfCatalogueCacheLastStatAt = [DateTime]::MinValue
$Script:CfCatalogueCacheStatIntervalSeconds = 30

# long-run:failed-job-files-only-pruned-at-startup: Remove-OldJobFiles (near
# the request loop below) used to run exactly once, at startup - fine for a
# server that gets relaunched often, but this process is explicitly meant to
# stay alive for days/weeks (the whole point of the idle-exit + tray
# design), and a failed job leaves a .out.failed/.err.failed pair behind on
# every failure. Re-run it periodically from the request loop's own tick,
# same "at most once an hour" cadence as the maintenance-child spawn check
# just above - LastJobFilesPruneTime is stamped right after the real
# startup call (see that call site) so the first re-run doesn't happen
# again within seconds of it.
$Script:JobCleanupIntervalMinutes = 60
$Script:LastJobFilesPruneTime = [DateTime]::MinValue

# =====================================================================
# Round 37 (server perf pass): -MaintenanceOnly early exit
#
# A hidden, periodically-spawned child of this SAME script (see
# Invoke-MaintenanceTick, near the request loop below) that does exactly
# the network-capable work the real serving process's own startup used to
# do inline, strictly before it could accept its first request:
# Initialize-CfCatalogueIndex's up-to-two live HTTPS GETs and Initialize-
# WagoGrowthSnapshots' up-to-10-page-per-flavour Wago crawl. Both functions
# are self-gated on their own 24h/20h freshness checks (GAME-MODE-SPEC.md,
# 2026-09-08: the Test-GameRunning gate both used to also have is removed -
# the crawl runs regardless of game state now); only WHERE they are called
# from has moved. This branch never binds a
# listener, never enters the request loop, and never sets
# $Script:AcceptingRequests true (it stays at its $false default the whole
# time) - so both functions' own "must run before the request loop starts
# accepting connections" guards trivially never fire here.
#
# Deliberately does its OWN minimal preamble (flavour migration + a
# default-flavour context, mirroring the two real preamble steps just below
# that this branch actually needs) rather than falling through into the
# general preamble - Load-CheckState (job/check history), port resolution,
# Update-InstalledAppsRegistration (a registry write - must never happen on
# every ~hourly maintenance tick, only once at real server startup) and
# Remove-OldJobFiles are all real-server-only concerns this branch has no
# business touching.
# =====================================================================
if ($MaintenanceOnly) {
    Set-FurphyLowPriority
    try {
        Invoke-FlavourMigration -RootPath $Script:Root
    } catch {
        Write-ServerLog "Maintenance child: flavour migration failed: $($_.Exception.Message)"
    }
    $Script:InstalledFlavoursAtStartup = Get-CurrentInstalledFlavours
    Set-CurrentFlavourContext -Flavor (Get-DefaultFlavourId -InstalledFlavours $Script:InstalledFlavoursAtStartup)

    Write-ServerLog "Maintenance child started (pid $PID)"
    try {
        # F1 (follow-up from the launch round): on a genuinely fresh
        # install, ROOT\cache\ does not exist yet the first time this
        # child runs (nothing has ever written to it) - WriteAllText has no
        # implicit "create the parent directory" behavior, so this used to
        # throw immediately and the child limped on with no lock file at
        # all ("continuing anyway" below), never actually protecting the
        # section below from a second concurrent child. Create the
        # directory first, same guarded pattern already used at the two
        # other CacheDir call sites in this file (Get-WagoGrowthSnapshotPath's
        # caller / Save-CfCatalogueIndex).
        if (-not (Test-Path -LiteralPath $Script:CacheDir)) {
            New-Item -ItemType Directory -Path $Script:CacheDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($Script:MaintenanceLockPath, [string]$PID)
    } catch {
        Write-ServerLog "Maintenance child: could not write lock file, continuing anyway: $($_.Exception.Message)"
    }
    try {
        try {
            Initialize-CfCatalogueIndex
        } catch {
            Write-ServerLog "Maintenance child: CurseForge catalogue refresh failed: $($_.Exception.Message)"
        }
        try {
            Initialize-WagoGrowthSnapshots
        } catch {
            Write-ServerLog "Maintenance child: Wago growth snapshot crawl failed: $($_.Exception.Message)"
        }
        try {
            # APP-UPDATE-SPEC.md section 7: one more call inside the SAME
            # try/finally the two above already sit in - self-gated on its
            # own 24h-since-last-check/rate-limit-backoff windows (see
            # Invoke-AppUpdateMaintenance's own doc comment), so this hourly
            # tick costs nothing extra beyond a cheap disk read + timestamp
            # comparison on the overwhelming majority of ticks where nothing
            # is actually due. Never -Force here - only the -AppUpdateOnly
            # branch below bypasses those gates.
            Invoke-AppUpdateMaintenance
        } catch {
            Write-ServerLog "Maintenance child: app-update check failed: $($_.Exception.Message)"
        }
    } finally {
        try { Remove-Item -LiteralPath $Script:MaintenanceLockPath -Force -ErrorAction SilentlyContinue } catch { }
    }
    Write-ServerLog 'Maintenance child finished'
    return
}

# =====================================================================
# APP-UPDATE-SPEC.md section 5/7/11: -AppUpdateOnly early exit.
#
# Structural sibling of the -MaintenanceOnly branch just above, spawned on
# demand by POST /api/app-update/check (Handle-AppUpdateCheck) so a manual
# "Check now" click feels instant rather than waiting for the next hourly
# -MaintenanceOnly tick. Runs ONLY Invoke-AppUpdateMaintenance, with -Force
# so it unconditionally bypasses that function's own 24h-since-last-check
# and rate-limit-backoff gates (section 7: "bypasses the 24h gate and spawns
# ... immediately"). Never binds a listener, never enters the request loop,
# and - unlike -MaintenanceOnly - needs no flavour migration/context at all:
# app-update.json is machine-wide, never per-flavour.
# =====================================================================
if ($AppUpdateOnly) {
    Set-FurphyLowPriority
    Write-ServerLog "App-update child started (pid $PID)"
    try {
        Invoke-AppUpdateMaintenance -Force
    } catch {
        Write-ServerLog "App-update child failed: $($_.Exception.Message)"
    }
    Write-ServerLog 'App-update child finished'
    return
}

# FLAVORS-SPEC.md CS-F2 S3.3: runs once, before any addons.json/state.json/
# backups\ path is resolved - moves a pre-flavour install's top-level files
# into flavours\<homeFlavour>\ (copy-first, idempotent - see the function's
# own doc comment). CS-F1's own notesForNext flagged this file explicitly
# ("a server-only first run would never migrate") - this closes that gap by
# duplicating the same call addon-sync.ps1's Main makes. Never throws on its
# own (see its doc comment) - wrapped anyway as an extra safety net, per
# that same note, since nothing here may ever block startup.
try {
    Invoke-FlavourMigration -RootPath $Script:Root
} catch {
    Write-ServerLog "Flavour migration failed: $($_.Exception.Message)"
}

# FLAVORS-SPEC.md CS-F2: Invoke-FlavourMigration (shared, duplicated
# verbatim from addon-sync.ps1 per the established pattern - see that
# function's own doc comment) moves a pre-flavour install's top-level
# state.json into flavours\<homeFlavour>\ along with addons.json/backups\,
# per S3.1's literal file-tree diagram. This server deliberately keeps
# state.json at the SHARED root instead (see Save-CheckState's own doc
# comment for why) - so on an upgrade from a pre-CS-F2 install, the
# just-migrated flavours\<home>\state.json is adopted back up as the shared
# root's state.json, exactly once (guarded on the shared file not already
# existing), before Load-CheckState ever reads it - otherwise an existing
# user's lastRun/updatesCheckedAt/job history would silently vanish behind
# a file this server's own Load-CheckState never looks at. Never touches
# the pre-move backup Invoke-FlavourMigration already made.
if (-not (Test-Path -LiteralPath $Script:StatePath)) {
    $homeFlavourForState = Get-MigrationHomeFlavour -RootPath $Script:Root
    $migratedStatePath = Join-Path -Path (Join-Path -Path (Join-Path -Path $Script:Root -ChildPath 'flavours') -ChildPath $homeFlavourForState) -ChildPath 'state.json'
    if (Test-Path -LiteralPath $migratedStatePath -PathType Leaf) {
        try {
            Move-Item -LiteralPath $migratedStatePath -Destination $Script:StatePath -Force
            Write-ServerLog "Flavour migration: adopted migrated flavours\$homeFlavourForState\state.json as the shared state.json"
        } catch {
            Write-ServerLog "Flavour migration: failed to adopt migrated state.json: $($_.Exception.Message)"
        }
    }
}

# FLAVORS-SPEC.md CS-F2: seeds $Script:CurrentFlavour/$Script:AddonsJsonPath/
# $Script:BackupsPath/$Script:ClientBuildInfo with the S4.1 default flavour
# (retail when installed, else the first detected, else 'retail') before the
# first request ever arrives - every later request re-resolves and
# re-stashes its OWN flavour via Invoke-Route/Set-CurrentFlavourContext (see
# that function's own doc comment), so this seed only matters for whatever
# runs between here and the first request (Load-CheckState's per-flavour
# state.json read, immediately below). $Script:ClientBuildInfo itself is
# still resolved fresh per request thereafter, not cached across the
# process's lifetime the way the old single-flavour code path was - E13's
# "server restart required to pick up a changed .build.info" tradeoff no
# longer applies once multiple flavours exist, since a request for a
# DIFFERENT flavour must never return the STARTUP flavour's stale build info.
$Script:InstalledFlavoursAtStartup = Get-CurrentInstalledFlavours
Set-CurrentFlavourContext -Flavor (Get-DefaultFlavourId -InstalledFlavours $Script:InstalledFlavoursAtStartup)

# E2/Round 3: reload the last check results, last run summary, and job
# history (if any) so the "n updates" badge, the My Addons "Last run" line,
# and the rollback tooltip / job list all survive a server restart instead
# of going blank until the next check/job.
Load-CheckState

# E16: loads (or, when missing/stale, fetches) the offline CurseForge
# catalogue index that /api/cf/browse and /api/cf/enrich fall back to when
# no key is configured. Best-effort - see the function's own doc comment;
# a failure here never blocks the server from starting.
# Round 26 (hardening, item 1): this call used to run HERE, before the
# HttpListener ever binds - Load-CfCatalogueIndexFromDisk's synchronous
# ConvertFrom-Json over a ~18k-entry cf-catalogue.json cache measurably
# delays every cold start behind a plain-JSON parse that has nothing to do
# with the listener itself. Moved below $listener.Start() (bind first, load
# lazily after "Listening on ..." is logged) - see that call site's own
# comment for the full before/after measurement. Still runs before the
# request-accept loop starts (Search-CfCatalogue/Get-CfCatalogueEntry are
# only ever called from within a request handler, never during startup
# itself), so no behavior changes - only the wall-clock ordering relative to
# the listener's own bind does.

if (-not (Test-Path -LiteralPath $Script:Root)) {
    throw "Root path does not exist: $Script:Root"
}
if (-not (Test-Path -LiteralPath $Script:JobsDir)) {
    New-Item -ItemType Directory -Path $Script:JobsDir -Force | Out-Null
}

if (-not $Port -or $Port -le 0) {
    $settingsForPort = Get-Settings
    # security:security-server-settings-port-no-range-check-bricks-launch,
    # last line of defense: Get-Settings' own read path already clamps a
    # bad on-disk port back to the 47831 default (see its own comment), so
    # this `-le 65535` half is now unreachable through the normal Get-
    # Settings path - kept anyway as a second, independent guard directly
    # at the one place that actually feeds $listener.Start(), so a future
    # change to Get-Settings (or any other future caller of this same
    # fallback) can never again reintroduce a silent FATAL-exit-with-no-
    # listener-and-no-onscreen-error bricking, the exact failure this
    # finding reproduced end-to-end.
    if ($settingsForPort.port -and $settingsForPort.port -gt 0 -and $settingsForPort.port -le 65535) {
        $Port = $settingsForPort.port
    } else {
        $Port = 47831
    }
}
$Script:Port = $Port

# Round 33 (DISTRIBUTION-SPEC.md section 5.4): best-effort Installed-Apps
# refresh, gated entirely inside Update-InstalledAppsRegistration itself
# (production port + non-scratch root only) - see that function's own
# comment. Placed here, immediately after $Script:Port is finally known and
# after Set-CurrentFlavourContext/Load-CheckState above have already run
# (Get-FlavourWowRootPath needs $Script:CurrentFlavour), and before the
# HttpListener binds - registry I/O is cheap and this must never race a
# client's very first request.
Update-InstalledAppsRegistration

Remove-OldJobFiles
# Stamped here (not left at the [DateTime]::MinValue declared above) so the
# request loop's own periodic re-run doesn't fire again within seconds of
# this real startup pass - the next one is due ~$Script:JobCleanupIntervalMinutes later.
$Script:LastJobFilesPruneTime = Get-Date

# P1 perf pass (item 3), kept per GAME-MODE-SPEC.md section 1.2 (a CPU-only
# measure, not a network/functional gate): lower this process's own
# scheduling priority/QoS regardless of whether a game is running right
# now, since a resident server (the tray keeps it alive across the whole
# session) should never compete for cycles even during the brief window
# before Test-GameRunning's first probe.
Set-FurphyLowPriority

Write-ServerLog "Starting addon-server on port $Script:Port, root $Script:Root"

$listener = New-Object System.Net.HttpListener
# Round 20 (adversarial bug pass, security-1): a bare "localhost" prefix
# does not actually restrict http.sys to the loopback interface - it binds
# 0.0.0.0/[::] and dispatches purely on the request's Host header text,
# so any LAN client could reach this API by spoofing "Host: localhost"
# against the machine's real IP. An IP-literal prefix (127.0.0.1) makes
# http.sys bind and dispatch strictly on the loopback interface itself,
# closing that off. $appUrl below (used only to launch a local browser)
# is unaffected and deliberately left as "localhost".
$prefix = "http://127.0.0.1:$Script:Port/"
$listener.Prefixes.Add($prefix)
# Round 20 follow-up: Windows resolves "localhost" to the IPv6 loopback
# (::1) FIRST, so with only the 127.0.0.1 prefix every client that says
# "localhost" (the SPA, the host window, the tray, the handler, deploy.ps1)
# paid a refused-IPv6-connect fallback of 1-2 s per connection and health
# checks with short timeouts failed outright. Listen on the IPv6 loopback
# literal as well - still strictly loopback, the LAN stays closed. If the
# stack has no IPv6 the extra prefix is simply skipped.
$prefix6 = "http://[::1]:$Script:Port/"
try {
    if ([System.Net.Sockets.Socket]::OSSupportsIPv6) { $listener.Prefixes.Add($prefix6) }
} catch {
    Write-ServerLog "IPv6 loopback prefix not added: $($_.Exception.Message)"
}

try {
    $listener.Start()
} catch {
    # server:seed5-dual-launcher-startup-race / lead5 / F2 / fresh-install-
    # shared-port-conflict (Round 36 fixer): 'Addon Manager.vbs' and the
    # tray's own TryStartServer each independently ping /api/ping and, only
    # if it doesn't answer, spawn a brand-new hidden addon-server.ps1 with
    # no lock between the two launch paths. When both fire in the same
    # narrow window the loser's Start() throws this exact, well-known
    # HttpListenerException (port already bound by the winner) - completely
    # harmless, the winner keeps serving unaffected - but logging it under a
    # "FATAL:" prefix reads like a real crash to anyone triaging server.log.
    # Special-case just this one known-benign message; every other bind
    # failure (permission denied, port reserved by an unrelated app, etc.)
    # keeps the original FATAL wording unchanged so a genuine problem is
    # never downgraded or hidden. `throw` is unchanged in both branches -
    # this instance must still exit immediately either way; only the log
    # line's wording/severity changes.
    if ($_.Exception.Message -match 'conflicts with an existing registration') {
        Write-ServerLog "Another Furphy Addon Manager server is already running on port $Script:Port - this instance is exiting (harmless: can happen if the Addon Manager and its background tray both tried to start the server at the same moment)."
    } else {
        Write-ServerLog "FATAL: could not start listener on $prefix : $($_.Exception.Message)"
    }
    throw
}

Write-ServerLog "Listening on $(($listener.Prefixes | ForEach-Object { $_ }) -join ' and ')"

# Round 37 (server perf pass): the listener is bound and already queuing any
# incoming connection (a test's Wait-Port/TCP-connect succeeds against
# http.sys's own accept queue immediately) - this now loads ONLY what is
# already on disk (Load-CfCatalogueIndexFromDisk - a JSON parse, but never a
# network call) and never fetches. The network-capable refresh
# (Initialize-CfCatalogueIndex, and Initialize-WagoGrowthSnapshots' Wago
# crawl - both UNCHANGED, just no longer called from here) now happens
# entirely inside a periodically-spawned hidden -MaintenanceOnly child (see
# Invoke-MaintenanceTick, called from the request loop below) - so a target
# server never blocks its first /api/ping on either one, on ANY start
# (fresh install, stale cache, or warm cache all take the same fast disk-
# only path here). Still best-effort - a failure never blocks startup.
if (Load-CfCatalogueIndexFromDisk) {
    Write-ServerLog "CurseForge catalogue loaded from disk cache: $($Script:CfCatalogueIndex.Count) entries, fetched $($Script:CfCatalogueFetchedAt)"
} else {
    Write-ServerLog 'CurseForge catalogue cache not present yet - the next maintenance tick will fetch one'
}
try {
    if (Test-Path -LiteralPath $Script:CfCatalogueCachePath -PathType Leaf) {
        $Script:CfCatalogueCacheLastWriteUtc = (Get-Item -LiteralPath $Script:CfCatalogueCachePath -ErrorAction Stop).LastWriteTimeUtc
    }
} catch {
    # Best-effort - worst case, the first request-loop tick's own
    # Update-CfCatalogueCacheIfChanged reloads it again; never fatal.
}

if ($OpenBrowser) {
    $edgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
    $appUrl = "http://localhost:$Script:Port/"
    try {
        if (Test-Path -LiteralPath $edgePath) {
            Start-Process -FilePath $edgePath -ArgumentList @("--app=$appUrl", '--window-size=1320,900')
        } else {
            Start-Process $appUrl
        }
    } catch {
        Write-ServerLog "Failed to open browser: $($_.Exception.Message)"
    }
}

$Script:LastRequestTime = Get-Date

try {
    $pending = $listener.BeginGetContext($null, $null)
    # WAGO-BROWSE-SPEC.md section 4.4: the request loop is now officially
    # "accepting connections" - Initialize-WagoGrowthSnapshots (and any
    # future startup routine that mutates $Script:CurrentFlavour the same
    # transient way) must never run after this point.
    $Script:AcceptingRequests = $true
    while ($true) {
        if ($Script:ShuttingDown) { break }

        # P1 perf pass (item 2), kept per GAME-MODE-SPEC.md section 1.2:
        # while a WoW client is running, wait longer between wake-ups (15s
        # instead of the normal-mode wait) - WaitOne still returns the
        # instant a real request arrives (this only bounds how often the
        # idle loop wakes up with nothing to do), so this has zero effect
        # on request latency and only reduces how often an otherwise-idle
        # process wakes the thread at all during a play session.
        # GAME-MODE-SPEC.md section 1.3/4.4: this used to also shorten the
        # idle-exit window itself (5 minutes instead of the normal
        # -IdleMinutes) - dropped. Legitimate work (browsing, checks,
        # updates, the hourly maintenance tick) now happens throughout a
        # play session, so a quiet gap between requests no longer means
        # "this server is stuck, tear it down." $idleLimit stays
        # $Script:IdleMinutesNormal regardless of game state.
        #
        # F1 (idle-loop perf pass): the normal-mode wait was 2000ms; raised
        # to 5000ms since nothing in tests\ depends on a sub-5s reaction to
        # something happening between requests - checked specifically:
        # Server.MaintenanceTick.Tests.ps1's 20s Wait-ForLogLine window for
        # "Maintenance child started" is unaffected because
        # Update-CfCatalogueCacheIfChanged/Invoke-MaintenanceTick above are
        # both called BEFORE this WaitOne, so the very first tick after the
        # listener starts accepting connections spawns the maintenance
        # child immediately - not gated by $waitMs at all; there is no
        # Idle*/GameMode*.Tests.ps1 (grepped tests\integration\ and
        # tests\unit\ - neither exists) and the one idle-exit check that
        # does exist compares against -IdleMinutes in whole MINUTES, never
        # seconds; and no test polls server.log with a sub-5s timeout tied
        # to this loop's cadence (grepped for TimeoutSec 1-4 and for
        # literal "2000"/"2s cadence" mentions - none found). Request
        # latency is unaffected either way: WaitOne returns the instant a
        # request arrives regardless of $waitMs.
        #
        # Round 41b's refix pass briefly widened this to 10000ms (and the
        # probe/stat intervals to 60s); the independent before/after could
        # not measure any difference, so those were reverted - see the
        # comment right below.
        # touch Test-GameRunning/Update-CfCatalogueCacheIfChanged's own
        # cost (both are independently interval-gated at 30s, well above
        # the tick rate). Round 41b also tried 10000ms here together with
        # 60s probe/stat intervals; an independent before/after on a quiet
        # machine measured no difference (~0.05 CPU-s/min either way), so
        # the tick stays at 5000ms - the idle-exit check and the
        # maintenance spawn check still run every 5s, and WaitOne returns
        # the instant a request arrives regardless.
        $gameRunningNow = Test-GameRunning
        $waitMs = 5000
        $idleLimit = $Script:IdleMinutesNormal
        if ($gameRunningNow) {
            $waitMs = 15000
        }

        # Round 37 (server perf pass): this loop's own wake-up cadence is
        # the only "timer tick" this file has - both calls are cheap and
        # best-effort on every tick that has nothing to do (nearly all of
        # them), and MUST NEVER block a pending request: Update-
        # CfCatalogueCacheIfChanged is a single file stat unless the cache
        # actually changed underneath this process; Invoke-MaintenanceTick's
        # own interval/lock-file guards make it a real no-op on every tick
        # except roughly once an hour. long-run:failed-job-
        # files-only-pruned-at-startup: Remove-OldJobFiles gets the same
        # "at most once an hour" treatment here - a plain directory
        # listing/delete with no network dependency, so unlike the two
        # calls above there is no per-call internal gate of its own; this
        # tick-level check IS the gate.
        Update-CfCatalogueCacheIfChanged
        Invoke-MaintenanceTick
        if (((Get-Date) - $Script:LastJobFilesPruneTime).TotalMinutes -ge $Script:JobCleanupIntervalMinutes) {
            Remove-OldJobFiles
            $Script:LastJobFilesPruneTime = Get-Date
        }

        $signaled = $pending.AsyncWaitHandle.WaitOne($waitMs)
        if (-not $signaled) {
            if ($idleLimit -gt 0) {
                $idleSpan = (Get-Date) - $Script:LastRequestTime
                if ($idleSpan.TotalMinutes -ge $idleLimit) {
                    # Round 20 (adversarial bug pass, server-2): unlike
                    # Handle-Shutdown (the explicit POST /api/shutdown),
                    # this idle-exit path used to only look at wall-clock
                    # time, never at whether a job was still running - a
                    # long sync left unattended past -IdleMinutes could get
                    # the whole server (and the listener) torn down out
                    # from under it, orphaning the CLI child process with
                    # no owner. Mirror Handle-Shutdown's own check: skip
                    # this idle break (re-checked every 2s regardless) while
                    # any flavour still has a job running.
                    $anyJobRunning = $false
                    foreach ($cj in @($Script:CurrentJobByFlavour.Values)) {
                        if ($cj) {
                            $refreshedJob = Update-JobStatus -Job $cj
                            if ($refreshedJob -and $refreshedJob.state -eq 'running') { $anyJobRunning = $true }
                        }
                    }
                    if (-not $anyJobRunning) {
                        Write-ServerLog "Idle for $idleLimit minutes - shutting down"
                        break
                    }
                }
            }
            continue
        }

        $context = $null
        try {
            $context = $listener.EndGetContext($pending)
        } catch {
            Write-ServerLog "EndGetContext failed: $($_.Exception.Message)"
            $pending = $listener.BeginGetContext($null, $null)
            continue
        }

        $Script:LastRequestTime = Get-Date

        try {
            Invoke-Route -Context $context
        } catch {
            Write-ServerLog "FATAL request handler error: $($_.Exception.Message)"
            try { $context.Response.Close() } catch { }
        }

        if ($Script:ShuttingDown) { break }
        $pending = $listener.BeginGetContext($null, $null)
    }
} finally {
    Write-ServerLog 'Stopping listener'
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
    Write-ServerLog 'Server stopped'
}
