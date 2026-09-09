<#
=====================================================================
 tests\host\Host.Tests.ps1

 T3 (host layer): host\FurphyHost.exe's --selftest (main window) and
 --tray-selftest (tray) self-test markers. Both are existing, designed
 features of the exe itself (see FurphyHost.cs's own header comments on
 RunSelftestSequence/WriteSelftestMarker) - this file drives them for
 real against a REAL FurphyHost.exe process and asserts on the JSON
 marker each one writes, never a fake/mocked host.

 Never touches port 47831, the real WoW folder, the real Desktop, or a
 real HKCU Run value outside its own copied test root (the tray test
 registers/unregisters against the REAL HKCU Run key by design - this
 mirrors what the exe itself does with -Enable/-Disable elsewhere - but
 always removes it in a finally block and asserts it is gone afterward,
 same contract as tests\integration\Server.Tray.Tests.ps1's own
 server-side tray test).

 Builds host\bin\FurphyHost.exe first if missing or stale relative to
 host\FurphyHost.cs (build-host.ps1), so this file works on a clean
 checkout with no manual build step.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:HostExePath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'host\bin\FurphyHost.exe'
$Script:HostCsPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'host\FurphyHost.cs'
$Script:HostBinDir = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'host\bin'

function Ensure-HostBuilt {
    <# Compiles host\bin\FurphyHost.exe if missing, or older than FurphyHost.cs. #>
    $needsBuild = $false
    if (-not (Test-Path -LiteralPath $Script:HostExePath -PathType Leaf)) {
        $needsBuild = $true
    } elseif ((Get-Item -LiteralPath $Script:HostCsPath).LastWriteTimeUtc -gt (Get-Item -LiteralPath $Script:HostExePath).LastWriteTimeUtc) {
        $needsBuild = $true
    }
    if ($needsBuild) {
        Write-Host '  (building host\bin\FurphyHost.exe - missing or stale)'
        $buildScript = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'host\build-host.ps1'
        & $buildScript
    }
    return (Test-Path -LiteralPath $Script:HostExePath -PathType Leaf)
}

function Wait-MarkerFile {
    param([string]$Path, [int]$TimeoutSec = 40)

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            # Written via temp-file + File.Move (atomic rename) by the host
            # itself - existence implies a complete write, but give one
            # extra short pause + retry-on-parse-failure belt-and-suspenders
            # in case a reader catches it mid-rename on a slow disk.
            for ($attempt = 0; $attempt -lt 5; $attempt++) {
                try {
                    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
                    return ($raw | ConvertFrom-Json)
                } catch {
                    Start-Sleep -Milliseconds 200
                }
            }
        }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

function Wait-ProcessExit {
    # Timing-budget hardening: was 15s. This is harness teardown slack
    # (message-loop exit / mutex release AFTER the marker is already
    # written), not a product guarantee - 15s left no margin under
    # concurrent-suite CPU contention (reproduced: the "skips the cycle"
    # It failing this exact assertion, line 384). Raised uniformly to 30s.
    param([System.Diagnostics.Process]$Process, [int]$TimeoutSec = 30)

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { if ($Process.HasExited) { return $true } } catch { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Test-RealWowClientRunning {
    <#
      regression-guards:host-minimumsize-floor-no-guard-test's live-window
      assertion (see the "Host MinimumSize DPI floor" Describe below) needs
      to know whether it is safe to actually show a real FurphyHost.exe
      window on THIS machine, independent of any --wow-fake override a test
      process passes to the exe itself (--wow-fake only changes what the
      exe under test believes, never what is really running). Mirrors
      addon-server.ps1's own Test-GameRunning / host\FurphyHost.cs's
      WowDetector.IsRunning name list exactly (KnownWowProcessNames /
      KnownWowNames) - kept as its own tiny, dependency-free check here
      rather than dot-sourcing addon-server.ps1 into this file, since that
      would pull in and evaluate its entire top-level body (guarded against
      starting a real listener, but with no reason to take on that surface
      just for one process-name check).
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

function New-TrayTestLayout {
    <#
      Builds (idempotently - safe to call more than once against the same
      -WowRoot) the production-shaped layout --tray-selftest's own
      auto-start/WoW-root-detection code needs:

        <WowRoot>\_retail_\..._ptr_\      the FLAVORS-SPEC.md section 8
                                          fixture (retail/classic/
                                          classic_era/ptr), copied once
        <WowRoot>\_retail_\AddonSync\     addon-server.ps1/addon-sync.ps1/
                                          ui\/settings.json/host\bin\ -
                                          "AddonSync" is a literal,
                                          case-sensitive-by-convention leaf
                                          name Resolve-EffectiveAddonsPath's
                                          own walk-up looks for (see
                                          addon-server.ps1's
                                          Get-InstalledFlavours doc
                                          comment) - its own parent
                                          (_retail_) must be a known
                                          flavour folder for the walk-up to
                                          fire, which is why the fixture
                                          copy happens at -WowRoot's own
                                          root, one level up.

      settings.json is pre-seeded with port 47899 (never 47831 -
      Get-DefaultSettings' own default) BEFORE addon-server.ps1 ever runs
      (self-started by --tray-selftest's own TryStartServer, which never
      forwards -Port) and showTestRealms explicitly false, so ptr is
      excluded from the update-all-flavours fan-out exactly like a fresh
      real install.

      Returns the AddonSync directory path.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$WowRoot,
        [Parameter(Mandatory = $true)][int]$Port,
        # Round 28: the tray's "Checking addons (N of M)"/"Updating <Name>
        # (k of m)" per-addon tooltip wording (SPEC.md section B) only ever
        # renders when exactly one flavour job exists for the cycle - a
        # genuine multi-flavour cycle keeps the simpler counts-free
        # "Checking..." text, by design (out of scope this round). Passing
        # e.g. @('_retail_') strips every OTHER fixture flavour folder
        # right after the copy, before Get-InstalledFlavours ever sees this
        # root, so a test needing the per-addon wording gets a real
        # single-flavour install instead of the default 3-flavour fixture.
        # $null (the default) keeps every flavour, unchanged from before
        # this parameter existed.
        [string[]]$OnlyFlavours = $null
    )

    if (-not (Test-Path -LiteralPath (Join-Path $WowRoot '_retail_'))) {
        Copy-Fixture -Destination $WowRoot | Out-Null
        if ($OnlyFlavours) {
            foreach ($folder in @('_retail_', '_classic_', '_classic_era_', '_ptr_')) {
                if ($OnlyFlavours -notcontains $folder) {
                    $stripPath = Join-Path $WowRoot $folder
                    if (Test-Path -LiteralPath $stripPath) {
                        Remove-Item -LiteralPath $stripPath -Recurse -Force
                    }
                }
            }
        }
    }

    $addonSyncDir = Join-Path -Path $WowRoot -ChildPath '_retail_\AddonSync'
    if (-not (Test-Path -LiteralPath $addonSyncDir)) {
        New-Item -ItemType Directory -Path $addonSyncDir -Force | Out-Null
    }

    foreach ($pair in @(
        @{ Src = 'addon-server.ps1'; Dst = 'addon-server.ps1' }
        @{ Src = 'addon-sync.ps1'; Dst = 'addon-sync.ps1' }
    )) {
        $dstPath = Join-Path $addonSyncDir $pair.Dst
        if (-not (Test-Path -LiteralPath $dstPath)) {
            Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot $pair.Src) -Destination $dstPath -Force
        }
    }
    $uiDst = Join-Path $addonSyncDir 'ui'
    if (-not (Test-Path -LiteralPath $uiDst)) {
        Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'ui') -Destination $uiDst -Recurse -Force
    }
    $binDst = Join-Path $addonSyncDir 'host\bin'
    if (-not (Test-Path -LiteralPath $binDst)) {
        Copy-Item -LiteralPath $Script:HostBinDir -Destination $binDst -Recurse -Force
    }

    $settingsPath = Join-Path $addonSyncDir 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        $settings = [ordered]@{
            releaseType               = 1
            port                      = $Port
            adFilter                  = $true
            cfFocus                   = $true
            hostWindow                = $null
            hostTheme                 = $null
            backgroundUpdates         = $false
            backgroundIntervalMinutes = 120
            runAtStartup              = $false
            schemaVersion             = 2
            activeFlavour             = 'retail'
            showTestRealms            = $false
        }
        ($settings | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    }

    return $addonSyncDir
}

function Stop-Straggler-FurphyHost {
    <# Hard-kills any FurphyHost.exe whose command line names $MarkerNeedle (a marker path fragment unique to this test run), belt-and-suspenders cleanup. #>
    param([string]$Needle)

    try {
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'FurphyHost.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like ('*' + $Needle + '*') }
        foreach ($p in @($procs)) {
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
    } catch { }
}

function Get-OlderCurseForgeFileId {
    <#
      Round 28: real network lookup (never hardcoded - BigWigs releases
      often enough that a hand-typed file id would go stale within days)
      of a file id for $ProjectId that is genuinely older than whatever
      the CLI's own normal (unpinned) sync would pick as "latest" right
      now - mirrors addon-sync.ps1's own Invoke-CfRequest file-list call
      (same endpoint/query, newest-first) but stops at $BackIndex entries
      back from the newest rather than index 0, so the forced-update test
      below has a real gap for the subsequent unpinned check to close.
    #>
    param(
        [Parameter(Mandatory = $true)][int64]$ProjectId,
        [int]$BackIndex = 15
    )

    $uri = "https://www.curseforge.com/api/v1/mods/$ProjectId/files?pageIndex=0&pageSize=50&sort=dateCreated&sortDescending=true"
    $resp = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ 'Referer' = 'https://www.curseforge.com/'; 'Accept' = 'application/json' } -TimeoutSec 30
    $files = @($resp.data)
    if ($files.Count -lt 2) { throw "Get-OlderCurseForgeFileId: project $ProjectId returned fewer than 2 files" }
    $idx = [Math]::Min($BackIndex, $files.Count - 1)
    return [int64]$files[$idx].id
}

# host:host-cf-navigationstarting-blocks-ui-thread regression coverage.
#
# A minimal, standalone HttpListener stub (own child powershell.exe
# process, same idiom as tests\fixtures\wago-stub\WagoStubServer.ps1) -
# deliberately NOT addon-server.ps1, which this test has no business
# starting or editing: this test targets the HOST's own thread
# behaviour (does a slow /api/state or /api/jobs round trip freeze the
# native window?), not server correctness. It answers GET /selftest.html
# immediately (serving the real host\selftest.html content verbatim so
# the existing --selftest choreography - hello/theme/cf-show/cf-nav -
# still runs unchanged) but deliberately sleeps -DelayMs before answering
# GET /api/state and POST /api/jobs - the two synchronous, timeout-bound
# HTTP calls IsProjectTracked/HandleCurseforgeProtocol make from
# CfWebView_NavigationStarting's own call chain (host\FurphyHost.cs).
$Script:CfDelayStubServerSource = @'
param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][int]$DelayMs,
    [Parameter(Mandatory = $true)][string]$SelftestHtmlPath
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$htmlBytes = [System.Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath $SelftestHtmlPath -Raw -Encoding UTF8))

function Send-StubBytes {
    param($Response, [int]$StatusCode, [string]$ContentType, [byte[]]$Bytes)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $Bytes.Length
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Response.OutputStream.Close()
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()

$shuttingDown = $false
try {
    while (-not $shuttingDown) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        try {
            $path = $request.Url.AbsolutePath
            if ($path -eq '/__control/shutdown') {
                Send-StubBytes -Response $response -StatusCode 200 -ContentType 'application/json' -Bytes ([System.Text.Encoding]::UTF8.GetBytes('{"ok":true}'))
                $shuttingDown = $true
                continue
            }
            if ($path -eq '/selftest.html' -and $request.HttpMethod -eq 'GET') {
                Send-StubBytes -Response $response -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Bytes $htmlBytes
                continue
            }
            if ($path -eq '/api/state' -and $request.HttpMethod -eq 'GET') {
                Start-Sleep -Milliseconds $DelayMs
                Send-StubBytes -Response $response -StatusCode 200 -ContentType 'application/json' -Bytes ([System.Text.Encoding]::UTF8.GetBytes('{"addons":[]}'))
                continue
            }
            if ($path -eq '/api/jobs' -and $request.HttpMethod -eq 'POST') {
                Start-Sleep -Milliseconds $DelayMs
                Send-StubBytes -Response $response -StatusCode 202 -ContentType 'application/json' -Bytes ([System.Text.Encoding]::UTF8.GetBytes('{"jobId":"stub-job-1"}'))
                continue
            }
            Send-StubBytes -Response $response -StatusCode 404 -ContentType 'text/plain' -Bytes ([System.Text.Encoding]::UTF8.GetBytes('not found'))
        } catch {
            try {
                Send-StubBytes -Response $response -StatusCode 500 -ContentType 'text/plain' -Bytes ([System.Text.Encoding]::UTF8.GetBytes('stub error'))
            } catch { }
        }
    }
} finally {
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
}
'@

function Start-CfDelayStubServer {
    <#
      Writes $Script:CfDelayStubServerSource into $Root and launches it as
      its own child powershell.exe process, listening on $Port with each
      of /api/state and /api/jobs delayed by $DelayMs. Waits for
      /selftest.html to answer before returning. Returns a hashtable
      Stop-CfDelayStubServer accepts.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][int]$DelayMs
    )

    $scriptPath = Join-Path -Path $Root -ChildPath 'cf-delay-stub.ps1'
    Set-Content -LiteralPath $scriptPath -Value $Script:CfDelayStubServerSource -Encoding ASCII
    $selftestHtmlPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'host\selftest.html'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '" -Port ' + $Port + ' -DelayMs ' + $DelayMs + ' -SelftestHtmlPath "' + $selftestHtmlPath + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)

    $ready = $false
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri ("http://localhost:{0}/selftest.html" -f $Port) -UseBasicParsing -TimeoutSec 2
            if ($resp.StatusCode -eq 200) { $ready = $true; break }
        } catch { }
        Start-Sleep -Milliseconds 200
    }
    if (-not $ready) {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        throw "Start-CfDelayStubServer: stub on port $Port did not answer /selftest.html in time"
    }

    return @{ Process = $proc; Port = $Port }
}

function Stop-CfDelayStubServer {
    <# Graceful shutdown request first (belt-and-suspenders Kill after). #>
    param($Server)
    if (-not $Server) { return }
    try {
        Invoke-WebRequest -Uri ("http://localhost:{0}/__control/shutdown" -f $Server.Port) -Method Post -UseBasicParsing -TimeoutSec 3 | Out-Null
    } catch { }
    Start-Sleep -Milliseconds 200
    try {
        if ($Server.Process -and -not $Server.Process.HasExited) {
            $Server.Process.Kill()
        }
    } catch { }
}

Describe 'Host --selftest (main window)' -Tags 'Host', 'Network' {
    # T4: tagged 'Network' in addition to 'Host' (T3 left it untagged and
    # flagged this exact choice as open) so tests\run-all.ps1 -NoNetwork /
    # -Quick can skip it - the CF pane genuinely navigates to
    # www.curseforge.com. Every other Host.Tests.ps1 Describe (the two
    # --tray-selftest Its) stays 'Host'-only: fully offline/deterministic.
    It 'writes a marker with init/dpiAware/cf-pane/deep-link fields, real screenshot' {
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $root = New-TempRoot -Name 'host-window-selftest'
        $server = $null
        $hostProc = $null
        $needle = 'winmarker-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $markerPath = Join-Path -Path $root -ChildPath ($needle + '.json')

        try {
            # Start-TestServer copies ui\ + addon-sync.ps1 in and creates a
            # default settings.json (port 47899, never 47831) - see
            # tests\lib\common.ps1. host\selftest.html is copied alongside
            # ui\ so addon-server.ps1's own static-file route serves it at
            # /selftest.html, same origin as the API it will POST /api/jobs
            # against (the exe's own Referer check needs same-origin).
            $server = Start-TestServer -Root $root -Port 47899
            Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'host\selftest.html') -Destination (Join-Path $root 'ui\selftest.html') -Force

            # Run the exe from a COPY of host\bin (never the real build-root
            # copy) so HostFiles.FindUpward's settings.json/VERSION reads
            # land on this test's own throwaway settings.json, never the
            # real one - the host never writes settings.json during
            # --selftest (persist is explicitly suppressed - see
            # FurphyHost.cs's own comment on that), but this keeps every
            # read isolated too, and keeps host.log/capture output inside
            # tests\.tmp\ instead of the real build root.
            Copy-Item -LiteralPath $Script:HostBinDir -Destination (Join-Path $root 'host\bin') -Recurse -Force
            Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'VERSION') -Destination (Join-Path $root 'VERSION') -Force -ErrorAction SilentlyContinue
            $exeCopyPath = Join-Path $root 'host\bin\FurphyHost.exe'

            # Wipe any stale WebView2 user-data folder next to the exe
            # copy before running - defensive, per the task brief (a
            # previous crashed run could leave a locked profile behind).
            $webview2Dir = $exeCopyPath + '.WebView2'
            if (Test-Path -LiteralPath $webview2Dir) {
                Remove-Item -LiteralPath $webview2Dir -Recurse -Force -ErrorAction SilentlyContinue
            }

            $selftestUrl = 'http://localhost:47899/selftest.html'
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exeCopyPath
            $psi.Arguments = '--port 47899 --selftest "' + $markerPath + '" "' + $selftestUrl + '"'
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path -Path $exeCopyPath -Parent
            $hostProc = [System.Diagnostics.Process]::Start($psi)

            # The exe's own selftest timeline writes the marker at ~8s
            # (SelftestTimer, 8000ms interval) - see FurphyHost.cs.
            $marker = Wait-MarkerFile -Path $markerPath -TimeoutSec 40
            $marker | Should Not Be $null

            $marker.init | Should Be $true
            ($marker.dpiAware -is [bool]) | Should Be $true
            $marker.dpiAware | Should Be $true
            $marker.hostReadySent | Should Be $true
            [int]$marker.cfShowCount | Should BeGreaterThan 1
            [int]$marker.cfHideCount | Should BeGreaterThan 0
            $marker.cfPaneVisible | Should Be $true
            [int]$marker.cfStateMessages | Should BeGreaterThan 0
            $marker.cfFocusEnabled | Should Be $true

            # KNOWN FINDING (reproduced 3/3 runs on this machine, real
            # network to www.curseforge.com, not a flaky/environment
            # fluke): EnsureSelftestDeepLinkInjection fires its fake
            # curseforge://install link exactly 2000ms after the CF pane's
            # document is created (host\FurphyHost.cs), which lands almost
            # exactly on top of selftest.html's own cf-hide at t=3000ms
            # (itself ~2000ms after the same cf-show that creates that
            # document) - hiding the pane (_cfWebView.Visible = false)
            # appears to suspend/throttle the pending WebView2 page timer
            # badly enough that it never fires again before the marker is
            # written at t=8000ms, even though the pane is shown again at
            # t=4000ms (host.log shows the second cf-show, but
            # intercepted/jobPostStatus stay empty/null every time). This
            # is pre-existing production code, not something this
            # tests-only step is scoped to fix (same convention as T1's
            # cache/ .gitignore gap and T2's Update-JobStatus gap) - kept
            # as a hard assertion, not softened, so this stays visibly RED
            # until it is either fixed (give the fake link more slack
            # before selftest.html's own hide, or run
            # AddScriptToExecuteOnDocumentCreatedAsync's callback while
            # hidden) or someone deliberately re-scopes this assertion.
            $intercepted = @($marker.intercepted)
            $sawDeepLink = @($intercepted | Where-Object { $_ -match 'curseforge://install' -and $_ -match 'addonId=999999001' }).Count -gt 0
            $sawDeepLink | Should Be $true

            $marker.jobPostStatus | Should Be 202

            # Launch-latency fix (Builder H): StartServerWait polls
            # GET /api/ping (against the real --port, not the selftest
            # page URL) before ever navigating _furphyWebView - the real
            # addon-server.ps1 Start-TestServer started above is already
            # listening before FurphyHost.exe even runs, so this must
            # resolve fast, never anywhere near the 45s timeout budget.
            $marker.serverWaitOutcome | Should Be 'ok'
            [int]$marker.serverWaitMs | Should BeGreaterThan -1
            [int]$marker.serverWaitMs | Should BeLessThan 5000

            $marker.capturePath | Should Not Be $null
            (Test-Path -LiteralPath $marker.capturePath -PathType Leaf) | Should Be $true
            # A real PNG, not an empty/placeholder file.
            (Get-Item -LiteralPath $marker.capturePath).Length | Should BeGreaterThan 100

            Wait-ProcessExit -Process $hostProc | Should Be $true
        } finally {
            if ($hostProc -and -not $hostProc.HasExited) {
                try { $hostProc.Kill() } catch { }
            }
            Stop-Straggler-FurphyHost -Needle $needle
            Stop-TestServer -Server $server
        }
    }

    It 'keeps the UI thread responsive while the CF pane job-post round trip is slow (host-cf-navigationstarting-blocks-ui-thread)' {
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $root = New-TempRoot -Name 'host-window-selftest-uithread'
        $stub = $null
        $hostProc = $null
        $needle = 'uithread-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $markerPath = Join-Path -Path $root -ChildPath ($needle + '.json')
        $port = 47905

        try {
            # Own stub, not addon-server.ps1 - see Start-CfDelayStubServer's
            # own header comment above. 2000ms on EACH of /api/state and
            # /api/jobs: comfortably under IsProjectTracked's own 3000ms
            # GetString timeout and HandleCurseforgeProtocol's 4000ms
            # PostJson timeout (both calls succeed normally - this proves
            # the fix moved them off the UI thread, not that a timeout
            # fallback papered over a still-blocking call), while the
            # ~4000ms combined sequential delay is far larger than the
            # heartbeat bound asserted below.
            $stub = Start-CfDelayStubServer -Root $root -Port $port -DelayMs 2000

            Copy-Item -LiteralPath $Script:HostBinDir -Destination (Join-Path $root 'host\bin') -Recurse -Force
            $exeCopyPath = Join-Path $root 'host\bin\FurphyHost.exe'
            $webview2Dir = $exeCopyPath + '.WebView2'
            if (Test-Path -LiteralPath $webview2Dir) {
                Remove-Item -LiteralPath $webview2Dir -Recurse -Force -ErrorAction SilentlyContinue
            }

            $selftestUrl = "http://localhost:$port/selftest.html"
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exeCopyPath
            $psi.Arguments = '--port ' + $port + ' --selftest "' + $markerPath + '" "' + $selftestUrl + '"'
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path -Path $exeCopyPath -Parent
            $hostProc = [System.Diagnostics.Process]::Start($psi)

            $marker = Wait-MarkerFile -Path $markerPath -TimeoutSec 40
            $marker | Should Not Be $null

            # Sanity: the deep-link path actually ran against the stub (same
            # EnsureSelftestDeepLinkInjection/CfWebView_NavigationStarting
            # mechanism as the It above, real curseforge.com CF-pane
            # navigation with a fake deep link injected into it) - without
            # this, a heartbeat that never saw the slow calls at all would
            # trivially pass the assertion below for the wrong reason.
            # Deliberately NOT also requiring jobPostStatus to equal 202
            # here (the It above already covers that end-to-end shape) -
            # this file's own pre-existing KNOWN FINDING comment documents
            # that EnsureSelftestDeepLinkInjection's fire time against a
            # real curseforge.com navigation is not always the same run to
            # run, so HandleCurseforgeProtocol's two calls (each now
            # deliberately slowed by this test's stub) do not always have
            # time to both finish before the fixed 8s marker write; that
            # timing variance is pre-existing and unrelated to this fix.
            # When a status IS captured it must still be a genuine success,
            # never silently masking a real regression.
            $intercepted = @($marker.intercepted)
            (@($intercepted | Where-Object { $_ -match 'curseforge://install' -and $_ -match 'addonId=999999001' }).Count) | Should BeGreaterThan 0
            if ($null -ne $marker.jobPostStatus) {
                $marker.jobPostStatus | Should Be 202
            }

            # Launch-latency fix (Builder H): this stub's catch-all route
            # answers any unmatched path (including /api/ping) with a
            # plain 404 - PingAnswers treats any real HTTP response as
            # "the listener is up", so StartServerWait resolves on its
            # very first attempt here too, well under this test's own
            # generous timing margins.
            $marker.serverWaitOutcome | Should Be 'ok'
            [int]$marker.serverWaitMs | Should BeLessThan 20000

            # The heartbeat Timer (50ms interval; host:
            # host-cf-navigationstarting-blocks-ui-thread fix's own
            # regression instrumentation, host\FurphyHost.cs
            # SelftestHeartbeatTimer_Tick) can only tick while the UI
            # thread is free to pump messages. 2000ms is generous headroom
            # over normal WinForms/GC jitter (observed well under 500ms in
            # practice) while staying far below the ~4000ms the stub would
            # have blocked this thread for pre-fix (IsProjectTracked's
            # GetString then HandleCurseforgeProtocol's PostJson, run back
            # to back, inline, on this exact thread, both against this
            # test's own deliberately slow stub).
            [int]$marker.uiHeartbeatTicks | Should BeGreaterThan 80
            [double]$marker.uiHeartbeatMaxGapMs | Should BeLessThan 2000

            Wait-ProcessExit -Process $hostProc | Should Be $true
        } finally {
            if ($hostProc -and -not $hostProc.HasExited) {
                try { $hostProc.Kill() } catch { }
            }
            Stop-Straggler-FurphyHost -Needle $needle
            Stop-CfDelayStubServer -Server $stub
        }
    }
}

Describe 'Host --tray-selftest (tray)' -Tags 'Host' {
    $root = New-TempRoot -Name 'host-tray-selftest'
    $wowFakeProc = $null

    It 'runs the cycle normally (never skipped_wow_running) when --wow-fake matches a real running process' {
        # GAME-MODE-SPEC.md section 8 / Host.Tests.ps1:622-665: inverted
        # from the old "skips the cycle with skipped_wow_running" It.
        # RunCycle (host\FurphyHost.cs) no longer gates on
        # WowDetector.IsRunning at all - a background cycle now runs fully
        # while WoW is running, same as when it is not. Kept as its own
        # regression guard (distinct from the "runs a real cycle" It below)
        # specifically because this one deliberately keeps a fake WoW
        # process alive for the WHOLE cycle, proving there is no gate left
        # to trip - not just that one happens not to fire.
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $addonSyncDir = New-TrayTestLayout -WowRoot $root -Port 47899
        $exePath = Join-Path $addonSyncDir 'host\bin\FurphyHost.exe'
        $needle = 'traywow-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $markerPath = Join-Path $addonSyncDir ($needle + '.json')
        $fakeProcessName = 'WowFakeSelftest'
        $fakeExePath = Join-Path $addonSyncDir ($fakeProcessName + '.exe')
        $hostProc = $null

        try {
            # A real, harmless, long-running process under a fake WoW
            # client name - a renamed copy of the in-box timeout.exe,
            # given a long wait so it is still alive for the whole test.
            Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\timeout.exe') -Destination $fakeExePath -Force
            $wowFakeProc = Start-Process -FilePath $fakeExePath -ArgumentList @('/t', '120', '/nobreak') -WindowStyle Hidden -PassThru

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exePath
            $psi.Arguments = '--port 47899 --tray-selftest "' + $markerPath + '" --wow-fake ' + $fakeProcessName
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path -Path $exePath -Parent
            $hostProc = [System.Diagnostics.Process]::Start($psi)

            # Generous budget: unlike the old skip path (which returned
            # almost instantly), a real cycle self-starts addon-server.ps1
            # and fans out a sync job per installed flavour, exactly like
            # the "runs a real cycle" It below.
            $marker = Wait-MarkerFile -Path $markerPath -TimeoutSec 60
            $marker | Should Not Be $null

            $marker.lastResult | Should Not Be 'skipped_wow_running'
            $marker.serverStarted | Should Be $true
            @($marker.flavourJobs).Count | Should BeGreaterThan 0
            [int]$marker.exitCode | Should Be 0
            $marker.mutexHeld | Should Be $true

            Wait-ProcessExit -Process $hostProc | Should Be $true
        } finally {
            if ($hostProc -and -not $hostProc.HasExited) { try { $hostProc.Kill() } catch { } }
            if ($wowFakeProc -and -not $wowFakeProc.HasExited) { try { Stop-Process -Id $wowFakeProc.Id -Force -ErrorAction SilentlyContinue } catch { } }
            Stop-Straggler-FurphyHost -Needle $needle
        }
    }

    It 'runs a real cycle: one flavourJobs entry per installed first-class flavour, icon shown, Run value written then removed and absent afterward' {
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $addonSyncDir = New-TrayTestLayout -WowRoot $root -Port 47899
        $exePath = Join-Path $addonSyncDir 'host\bin\FurphyHost.exe'
        $needle = 'traynorm-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $markerPath = Join-Path $addonSyncDir ($needle + '.json')
        $hostProc = $null
        $keyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        # Round 28 (SPEC.md section K, HARD RULE): --tray-selftest never
        # touches the real "FurphyAddonManager" Run value any more (a live
        # tray/install may own it) - it always registers/unregisters a
        # test-scoped "FurphyAddonManager.Test" value instead, so this is
        # the value name FurphyHost.exe itself actually writes now.
        $valueName = 'FurphyAddonManager.Test'
        $preExisting = Get-ItemProperty -LiteralPath $keyPath -Name $valueName -ErrorAction SilentlyContinue

        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exePath
            # --wow-fake with a name that cannot match a real process:
            # this test's own WoW-running check must never depend on
            # whether the machine running it happens to have a real WoW.exe
            # open (round 28 investigation: a real WoW.exe running on the
            # dev machine reproduces the exact "flavourJobs.Count is 0
            # instead of 3" symptom a prior build step flagged as an
            # unexplained pre-existing failure - RunCycle correctly takes
            # the skipped_wow_running branch and never posts any jobs at
            # all, which is not a product bug, just this test previously
            # having no --wow-fake guard against real game state).
            $psi.Arguments = '--port 47899 --tray-selftest "' + $markerPath + '" --wow-fake NoSuchFurphyHostTestProcess'
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path -Path $exePath -Parent
            $hostProc = [System.Diagnostics.Process]::Start($psi)

            # A real cycle: self-starts addon-server.ps1, fans out one sync
            # job per non-hidden installed flavour against the fixture (zero
            # tracked addons -> fast, fully offline), polls to completion,
            # then the register/unregister startup sequence. Generous
            # timeout - covers server cold-start + 3 sync jobs.
            $marker = Wait-MarkerFile -Path $markerPath -TimeoutSec 60
            $marker | Should Not Be $null

            $marker.iconShown | Should Be $true
            [int]$marker.exitCode | Should Be 0
            $marker.mutexHeld | Should Be $true

            # FLAVORS-SPEC.md section 2.1: retail/classic/classic_era are
            # first-class (ptr is detected but hidden by default -
            # showTestRealms is false in this test's own settings.json).
            $flavourJobs = @($marker.flavourJobs)
            $flavourJobs.Count | Should Be 3
            $flavourIds = @($flavourJobs | ForEach-Object { $_.flavour }) | Sort-Object
            (@($flavourIds) -join ',') | Should Be 'classic,classic_era,retail'

            $expectedRunValue = '"' + $exePath + '" --tray'
            $marker.runValueWritten | Should Be $expectedRunValue
            $marker.runValueRemoved | Should Be $true

            # tray-truth:tray-selftest-startup-click-handler-unexercised -
            # the Start with Windows toggle above used to hit
            # StartupRegistry.Enable/Disable directly, bypassing
            # MenuStartup_Click (host\FurphyHost.cs) entirely, so the
            # settings.json `runAtStartup` write that handler makes
            # (HostFiles.UpdateJsonObject, ~5480-5483) had zero coverage
            # through this marker - a regression reverting that handler to
            # a registry-only write would still show runValueWritten/
            # runValueRemoved above as fine. RunSelftestSequence now routes
            # both toggles through the real click handler and records
            # settings.json's own runAtStartup value right after each one.
            $marker.settingsRunAtStartupAfterEnable | Should Be $true
            $marker.settingsRunAtStartupAfterDisable | Should Be $false

            # Real settings.json check, independent of the marker's own
            # claim - same "don't just trust the marker" spirit as the real
            # registry check further down.
            $settingsPath = Join-Path $addonSyncDir 'settings.json'
            $settingsAfter = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
            [bool]$settingsAfter.runAtStartup | Should Be $false

            # Round 28 (SPEC.md section F/J): --tray-selftest's own
            # ActivateOrLaunch(true) call never actually starts a process
            # (dryRun). Round 30: the tray looks the window up by the
            # PORT-SCOPED title ("Furphy Addon Manager [test 47899]" here,
            # AppConstants.WindowTitleFor), so a real live window titled
            # "Furphy Addon Manager" on 47831 is invisible to it and the
            # only possible outcome is "launch". Before round 30 this
            # assertion failed whenever a live window was open - the test
            # tray had found and pulled the REAL window to the foreground.
            $marker.clickOutcome | Should Be 'launch'

            # Round 28: a genuine 3-flavour cycle has no single-job n-of-N
            # counts to show (SPEC.md section B's own multi-flavour carve-
            # out) - the tooltip history for THIS shape stays the simple,
            # counts-free "Starting the updater..." -> a done_* state, and
            # must never show the old incident's "Updating 34 of 34"-style
            # text for a plain check.
            $tooltipHistory = @($marker.tooltipHistory)
            $tooltipHistory.Count | Should BeGreaterThan 0
            (@($tooltipHistory | Where-Object { $_ -match 'Updating \d+ of \d+' }).Count) | Should Be 0

            # Round 33 regression coverage (round-32 finding #4): the
            # marker.menuItems array Builder H added this round had never
            # been asserted automatically - only verified by hand. Exact
            # order/labels per BuildContextMenu/CollectMenuItemLabels
            # (host\FurphyHost.cs): Open / status line / Check now / sep /
            # Start with Windows / background updates / sep / Uninstall /
            # sep / Quit. The status line (index 1) is intentionally
            # compared against marker.menuStatusText rather than a
            # hardcoded string - RefreshMenuState sets _statusMenuItem.Text
            # from the exact same _coreText the tooltip uses, so this
            # proves that "menu and tooltip must never disagree" invariant
            # instead of pinning today's specific status wording.
            $menuItems = @($marker.menuItems)
            $menuItems.Count | Should Be 10
            $menuItems[0] | Should Be 'Open Furphy Addon Manager'
            $menuItems[1] | Should Be $marker.menuStatusText
            $menuItems[2] | Should Be 'Check for updates now'
            $menuItems[3] | Should Be '-'
            $menuItems[4] | Should Be 'Start with Windows'
            $menuItems[5] | Should Be 'Update addons in the background'
            $menuItems[6] | Should Be '-'
            $menuItems[7] | Should Be 'Uninstall Furphy Addon Manager...'
            $menuItems[8] | Should Be '-'
            $menuItems[9] | Should Be 'Quit'

            # Round 33 regression coverage (round-32 finding #4, second
            # half): marker.uninstallDryRun's shape. This cycle self-starts
            # addon-server.ps1 on 47899 (serverStarted true above) and the
            # fixture's WoW root resolves cleanly, so RunUninstallSequence's
            # real POST /api/uninstall (with {"dryRun":true} - round-32
            # finding #2's fix) reaches a live, idle, reachable server and
            # gets a real 200 back - proving the round-32/round-33 fix
            # actually holds: a dry run against a genuinely live server
            # returns success WITHOUT tearing that server down (serverStarted
            # stays true and Wait-ProcessExit below still succeeds only
            # because the CYCLE finishes and the tray exits on its own, not
            # because the dry-run uninstall call shut anything down).
            $marker.uninstallDryRun | Should Not Be $null
            $marker.uninstallDryRun.route | Should Be 'server'
            $marker.uninstallDryRun.busy | Should Be $false
            [int]$marker.uninstallDryRun.postStatus | Should Be 200
            $marker.uninstallDryRun.networkError | Should Be $false
            # Only meaningful on the 'fallback' route - unset (default)
            # here since the dry-run POST was answered by the server.
            $marker.uninstallDryRun.installScriptFound | Should Be $false
            $marker.uninstallDryRun.wowRootResolved | Should Be $null

            Wait-ProcessExit -Process $hostProc | Should Be $true

            # Real registry check, independent of the marker's own claim.
            $prop = Get-ItemProperty -LiteralPath $keyPath -Name $valueName -ErrorAction SilentlyContinue
            $prop | Should Be $null
        } finally {
            if ($hostProc -and -not $hostProc.HasExited) { try { $hostProc.Kill() } catch { } }
            Stop-Straggler-FurphyHost -Needle $needle
            # Belt-and-suspenders: never leave a Run value behind, and never
            # remove one that predates this test (shouldn't exist on a dev
            # machine, but this test must not be the reason it's gone).
            try {
                $leftover = Get-ItemProperty -LiteralPath $keyPath -Name $valueName -ErrorAction SilentlyContinue
                if ($leftover -and -not $preExisting) {
                    Remove-ItemProperty -LiteralPath $keyPath -Name $valueName -ErrorAction SilentlyContinue
                }
            } catch { }
            # Any orphaned self-started addon-server.ps1 for this cycle.
            try {
                Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -like ('*' + $addonSyncDir + '*addon-server.ps1*') } |
                    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
            } catch { }
        }
    }
}

Describe 'Host --tray-selftest (tray) - single-flavour tooltip/icon/balloon history (Round 28)' -Tags 'Host', 'Network' {
    # Round 28 (SPEC.md section B/J): the per-addon "Checking addons
    # (N of M)"/"Updating <Name> (k of m)" tooltip wording only ever
    # renders for a SINGLE-flavour cycle (a genuine multi-flavour cycle
    # keeps the simpler counts-free text, by design - see the Describe
    # above's own "runs a real cycle" It) - so both Its here build a
    # retail-ONLY root (New-TrayTestLayout -OnlyFlavours '_retail_')
    # rather than reusing the default 3-flavour fixture.
    #
    # DEVIATION FROM SPEC.md's OWN WORDING, found while implementing this:
    # SPEC.md section J describes the "nothing to update" case as
    # "today's existing scratch fixture, zero tracked addons" - but with
    # truly zero addons.json records, addon-sync.ps1's main loop's own
    # Write-ProgressStep('queued', Total=$toSync.Count) writes {total:0}
    # ONCE and the per-addon loop body never runs at all (see addon-
    # sync.ps1 ~line 5064) - so "Checking addons (" (which needs total>0)
    # can NEVER appear for a zero-addon cycle; ComputeCore's own
    # total<=0 branch ("Starting the updater...") is what actually shows
    # instead, the whole time. Confirmed against B2's own manual
    # verification notes (STATE TABLE), which used 2 REAL tracked addons
    # for exactly this reason, not zero. Both Its below follow that same,
    # actually-correct shape (one real tracked addon) rather than the
    # zero-addon text in SPEC.md section J, which does not match the
    # implemented behaviour.
    $projectId = 2382 # BigWigs - retail-compatible, already used by
                       # tests\perf\Setup-Baseline.ps1/Perf.Tests.ps1.

    It 'a real single-flavour check with nothing to update: tooltipHistory shows "Checking addons (" then ends "Everything''s up to date", never "Updating"' {
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $wowRoot = New-TempRoot -Name 'host-tray-single-clean'
        $addonSyncDir = New-TrayTestLayout -WowRoot $wowRoot -Port 47899 -OnlyFlavours @('_retail_')
        $cliPath = Join-Path $addonSyncDir 'addon-sync.ps1'
        $exePath = Join-Path $addonSyncDir 'host\bin\FurphyHost.exe'
        $needle = 'trayclean-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $markerPath = Join-Path $addonSyncDir ($needle + '.json')
        $hostProc = $null

        try {
            # Real network install (latest compatible file) - this addon
            # is then genuinely up to date the moment the cycle checks it
            # again a few seconds later.
            $addResult = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 90 -ArgumentList @(
                '-Add', $projectId, '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot)
            $addResult.ExitCode | Should Be 0
            $addedRow = @($addResult.Json.results) | Where-Object { [string]$_.projectId -eq [string]$projectId }
            @($addedRow).Count | Should Be 1
            $addedRow[0].status | Should Be 'Installed'

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exePath
            $psi.Arguments = '--port 47899 --tray-selftest "' + $markerPath + '" --wow-fake NoSuchFurphyHostTestProcess'
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path -Path $exePath -Parent
            $hostProc = [System.Diagnostics.Process]::Start($psi)

            $marker = Wait-MarkerFile -Path $markerPath -TimeoutSec 60
            $marker | Should Not Be $null
            [int]$marker.exitCode | Should Be 0

            $flavourJobs = @($marker.flavourJobs)
            $flavourJobs.Count | Should Be 1
            $flavourJobs[0].flavour | Should Be 'retail'

            $tooltipHistory = @($marker.tooltipHistory)
            (@($tooltipHistory | Where-Object { $_ -match 'Checking addons \(' }).Count) | Should BeGreaterThan 0
            $tooltipHistory[$tooltipHistory.Count - 1] | Should Match 'Everything.s up to date'
            (@($tooltipHistory | Where-Object { $_ -match 'Updating' }).Count) | Should Be 0

            $marker.balloonShown | Should Be $false
            $marker.clickOutcome | Should Be 'launch'

            Wait-ProcessExit -Process $hostProc | Should Be $true
        } finally {
            if ($hostProc -and -not $hostProc.HasExited) { try { $hostProc.Kill() } catch { } }
            Stop-Straggler-FurphyHost -Needle $needle
            try {
                Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -like ('*' + $addonSyncDir + '*addon-server.ps1*') } |
                    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
            } catch { }
        }
    }

    It 'a real single-flavour forced-update cycle: tooltipHistory shows "Updating <Name> (1 of 1" then ends "Updated 1 addon at", balloon names it' {
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $wowRoot = New-TempRoot -Name 'host-tray-single-update'
        $addonSyncDir = New-TrayTestLayout -WowRoot $wowRoot -Port 47899 -OnlyFlavours @('_retail_')
        $cliPath = Join-Path $addonSyncDir 'addon-sync.ps1'
        $exePath = Join-Path $addonSyncDir 'host\bin\FurphyHost.exe'
        $needle = 'trayupdate-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $markerPath = Join-Path $addonSyncDir ($needle + '.json')
        $hostProc = $null

        try {
            # Install an OLDER real file explicitly (-FileId pins the
            # record to it), then -Unpin so the next, unforced check is
            # free to find and install whatever is actually newest.
            $olderFileId = Get-OlderCurseForgeFileId -ProjectId $projectId -BackIndex 15
            $addResult = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 90 -ArgumentList @(
                '-Add', $projectId, '-FileId', $olderFileId, '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot)
            $addResult.ExitCode | Should Be 0
            $addedRow = @($addResult.Json.results) | Where-Object { [string]$_.projectId -eq [string]$projectId }
            @($addedRow).Count | Should Be 1
            $addedRow[0].status | Should Be 'Installed'
            [int64]$addedRow[0].fileId | Should Be $olderFileId
            $addonName = [string]$addedRow[0].name

            $unpinResult = Invoke-CliJson -ScriptPath $cliPath -TimeoutSec 30 -ArgumentList @(
                '-Unpin', $projectId, '-Flavor', 'retail', '-Json', '-WowRoot', $wowRoot)
            $unpinResult.ExitCode | Should Be 0
            $unpinRow = @($unpinResult.Json.results) | Where-Object { [string]$_.projectId -eq [string]$projectId }
            @($unpinRow).Count | Should Be 1
            $unpinRow[0].status | Should Be 'Unpinned'

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exePath
            $psi.Arguments = '--port 47899 --tray-selftest "' + $markerPath + '" --wow-fake NoSuchFurphyHostTestProcess'
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path -Path $exePath -Parent
            $hostProc = [System.Diagnostics.Process]::Start($psi)

            $marker = Wait-MarkerFile -Path $markerPath -TimeoutSec 60
            $marker | Should Not Be $null
            [int]$marker.exitCode | Should Be 0

            $flavourJobs = @($marker.flavourJobs)
            $flavourJobs.Count | Should Be 1
            $flavourJobs[0].flavour | Should Be 'retail'
            @($flavourJobs[0].updatedNames) -contains $addonName | Should Be $true

            $tooltipHistory = @($marker.tooltipHistory)
            $updatingPattern = 'Updating ' + [regex]::Escape($addonName) + ' \(1 of 1'
            (@($tooltipHistory | Where-Object { $_ -match $updatingPattern }).Count) | Should BeGreaterThan 0
            $tooltipHistory[$tooltipHistory.Count - 1] | Should Match 'Updated 1 addon at'

            $marker.balloonShown | Should Be $true
            [string]$marker.balloonText | Should Match ([regex]::Escape($addonName))
            $marker.clickOutcome | Should Be 'launch'

            Wait-ProcessExit -Process $hostProc | Should Be $true
        } finally {
            if ($hostProc -and -not $hostProc.HasExited) { try { $hostProc.Kill() } catch { } }
            Stop-Straggler-FurphyHost -Needle $needle
            try {
                Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -like ('*' + $addonSyncDir + '*addon-server.ps1*') } |
                    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
            } catch { }
        }
    }
}

Describe 'Host WebView2 runtime missing (failure-modes:webview2-missing-no-fallback)' -Tags 'Host' {
    <#
      failure-modes:webview2-missing-no-fallback - HandleRuntimeMissing
      (host\FurphyHost.cs) now shows a MessageBox before closing, so a real
      launch on a machine with the WebView2 Runtime missing/broken no
      longer looks like total silence to the player (the VBS launcher runs
      the exe fire-and-forget and can never observe its exit code, so the
      dialog is the only place left that CAN tell the player anything).

      That dialog itself cannot be asserted by this unattended suite
      without a second, separate UI-automation click to dismiss it - out
      of scope for this file's existing all-headless conventions, and
      genuinely risky: a broken dismiss would hang this It, and by
      extension any run it's part of, forever on a modal with nothing left
      to click it. What CAN be asserted safely, and is the actual
      regression risk worth automating: the `if (!_options.SelftestActive)`
      guard around that MessageBox really does suppress it during
      --selftest. If that guard were ever lost or inverted, THIS test
      would hang instead of finishing - a clean, fast marker write plus
      process exit here is itself the regression proof.

      Forces the real failure via the same technique CHANGELOG.md's Round
      10 entry already used for manual verification (a host\bin copy with
      WebView2Loader.dll deliberately removed), now automated instead of
      only ever checked by hand.
    #>
    It 'still writes a marker (init:false) and exits with code 3 during --selftest when WebView2Loader.dll is missing, no hang' {
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $port = 47902
        $root = New-TempRoot -Name 'host-runtime-missing'
        $server = $null
        $hostProc = $null
        $needle = 'rtmissing-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $markerPath = Join-Path -Path $root -ChildPath ($needle + '.json')

        try {
            $server = Start-TestServer -Root $root -Port $port

            Copy-Item -LiteralPath $Script:HostBinDir -Destination (Join-Path $root 'host\bin') -Recurse -Force
            $exeCopyPath = Join-Path $root 'host\bin\FurphyHost.exe'
            Remove-Item -LiteralPath (Join-Path $root 'host\bin\WebView2Loader.dll') -Force

            $webview2Dir = $exeCopyPath + '.WebView2'
            if (Test-Path -LiteralPath $webview2Dir) {
                Remove-Item -LiteralPath $webview2Dir -Recurse -Force -ErrorAction SilentlyContinue
            }

            # The test-page URL is never actually reached - HandleRuntimeMissing
            # returns out of MainForm_Load before StartServerWait/navigation
            # ever run - but --selftest's own arg parser requires one.
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exeCopyPath
            $psi.Arguments = '--port ' + $port + ' --selftest "' + $markerPath + '" "http://localhost:' + $port + '/selftest.html"'
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path -Path $exeCopyPath -Parent
            $hostProc = [System.Diagnostics.Process]::Start($psi)

            # Deliberately a tighter budget than the other --selftest Its'
            # 40s: HandleRuntimeMissing fires almost immediately out of
            # MainForm_Load's own EnsureCoreWebView2Async catch, well before
            # the normal ~7-8s selftest timeline even starts. A marker
            # taking anywhere near this budget would itself suggest the
            # MessageBox suppression regressed and something is blocked on
            # a dialog with nothing to click it.
            $marker = Wait-MarkerFile -Path $markerPath -TimeoutSec 20
            $marker | Should Not Be $null
            $marker.init | Should Be $false

            Wait-ProcessExit -Process $hostProc -TimeoutSec 20 | Should Be $true
            $hostProc.ExitCode | Should Be 3
        } finally {
            if ($hostProc -and -not $hostProc.HasExited) { try { $hostProc.Kill() } catch { } }
            Stop-Straggler-FurphyHost -Needle $needle
            Stop-TestServer -Server $server
        }
    }
}

Describe 'Host un-minimize server recovery (long-run:minimize-kills-server-no-recovery)' -Tags 'Host' {
    <#
      long-run:minimize-kills-server-no-recovery - before this fix, nothing
      in MainForm ever re-checked or relaunched addon-server.ps1 once the
      window came back from being minimized (only TrayForm.TryStartServer
      did, and the tray loop is off by default), so once the server was
      gone for any reason the player was stuck on the SPA's permanent
      "Server not reachable" banner forever - with no recovery path short
      of digging up the desktop shortcut and starting over.

      This drives the real recovery mechanism end to end: a real (NOT
      --selftest - CheckServerAndRecoverIfDown is itself guarded off
      during SelftestActive, precisely so a scripted selftest run's
      deterministic timeline is never disturbed by a surprise server
      relaunch) FurphyHost.exe main window against a real addon-server.ps1,
      minimized and restored via a direct ShowWindow P/Invoke - same
      Add-Type-with-DllImport idiom shots\verify-capture.ps1 already uses
      for PrintWindow, no actual desktop interaction needed.

      Rather than waiting out a full -IdleMinutes idle-exit window (which
      depends on exactly how long the SPA webview's own idle poll takes to
      notice - the OTHER half of this same finding, fixed separately by no
      longer fully suspending the SPA webview on minimize), the server is
      killed directly while minimized: CheckServerAndRecoverIfDown does
      not care WHY the ping failed, only that it did, so this exercises
      the exact same recovery code path deterministically and fast instead
      of depending on real-world suspend/idle timing.

      Uses this round's own assigned scratch port (47902) throughout,
      never 47899/47831 - and this session confirmed no real WoW client
      process was running before opening this native window.
    #>
    It 'relaunches addon-server.ps1 after the window is un-minimized if the server died while minimized' {
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        if (-not ('FurphyWindowControl' -as [type])) {
            Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class FurphyWindowControl {
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);
}
'@
        }

        $port = 47902
        $root = New-TempRoot -Name 'host-unminimize-recovery'
        $addonSyncDir = New-TrayTestLayout -WowRoot $root -Port $port
        $exePath = Join-Path $addonSyncDir 'host\bin\FurphyHost.exe'
        $hostLogPath = Join-Path $addonSyncDir 'host.log'
        $server = $null
        $hostProc = $null

        try {
            $server = Start-TestServer -Root $addonSyncDir -Port $port -ScriptPath (Join-Path $addonSyncDir 'addon-server.ps1')

            $webview2Dir = $exePath + '.WebView2'
            if (Test-Path -LiteralPath $webview2Dir) {
                Remove-Item -LiteralPath $webview2Dir -Recurse -Force -ErrorAction SilentlyContinue
            }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exePath
            $psi.Arguments = '--port ' + $port
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path -Path $exePath -Parent
            $hostProc = [System.Diagnostics.Process]::Start($psi)

            $hwnd = [IntPtr]::Zero
            $tries = 0
            while ($hwnd -eq [IntPtr]::Zero -and $tries -lt 40) {
                Start-Sleep -Milliseconds 500
                $hostProc.Refresh()
                $hwnd = $hostProc.MainWindowHandle
                $tries++
            }
            $hwnd | Should Not Be ([IntPtr]::Zero)

            # Minimize - same effect as the player clicking the taskbar
            # icon (fires WM_SIZE, which WinForms turns into
            # MainForm_Resize with WindowState == Minimized). 6 = SW_MINIMIZE.
            [void][FurphyWindowControl]::ShowWindow($hwnd, 6)
            $iconicDeadline = (Get-Date).AddSeconds(10)
            while (-not ([FurphyWindowControl]::IsIconic($hwnd)) -and (Get-Date) -lt $iconicDeadline) {
                Start-Sleep -Milliseconds 200
            }
            [FurphyWindowControl]::IsIconic($hwnd) | Should Be $true

            # Kill the server while minimized - simulates ANY reason it
            # could be gone by the time the player comes back (idle-exit,
            # a crash, the PC having slept through it), which is exactly
            # what CheckServerAndRecoverIfDown must be agnostic to.
            if ($server.Process -and -not $server.Process.HasExited) {
                Stop-Process -Id $server.Process.Id -Force -ErrorAction SilentlyContinue
            }
            $downDeadline = (Get-Date).AddSeconds(10)
            while ((Test-PortOpen -Port $port -TimeoutMs 300) -and (Get-Date) -lt $downDeadline) {
                Start-Sleep -Milliseconds 200
            }
            (Test-PortOpen -Port $port -TimeoutMs 300) | Should Be $false

            # Restore - fires MainForm_Resize's wasMinimized branch, which
            # now calls CheckServerAndRecoverIfDown. 9 = SW_RESTORE.
            [void][FurphyWindowControl]::ShowWindow($hwnd, 9)

            # CheckServerAndRecoverIfDown pings with a 2s timeout on its own
            # background thread, then (on failure) spawns a fresh
            # addon-server.ps1 - generous budget for a real cold start
            # under test-suite load.
            $recoveredDeadline = (Get-Date).AddSeconds(30)
            $recovered = $false
            while ((Get-Date) -lt $recoveredDeadline) {
                try {
                    Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/ping" -Method Get -TimeoutSec 2 | Out-Null
                    $recovered = $true
                    break
                } catch { Start-Sleep -Milliseconds 500 }
            }
            $recovered | Should Be $true

            $hostLog = Get-Content -LiteralPath $hostLogPath -Raw -ErrorAction SilentlyContinue
            $hostLog | Should Not Be $null
            $hostLog | Should Match 'un-minimize: server not responding, attempting restart'
            $hostLog | Should Match 'un-minimize: restart started'
        } finally {
            # Whichever server is listening now (the recovered one, a
            # DIFFERENT process than $server.Process, which was killed on
            # purpose mid-test) - shut it down by port, not by PID.
            try { Invoke-Api -Port $port -Method Post -Path '/api/shutdown' -TimeoutSec 5 | Out-Null } catch { }
            if ($server -and $server.Process -and -not $server.Process.HasExited) {
                try { Stop-Process -Id $server.Process.Id -Force -ErrorAction SilentlyContinue } catch { }
            }
            if ($hostProc -and -not $hostProc.HasExited) { try { $hostProc.Kill() } catch { } }
            try {
                Get-CimInstance -ClassName Win32_Process -Filter "Name = 'FurphyHost.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -like ('*' + $exePath + '*') } |
                    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
            } catch { }
            try {
                Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -like ('*' + $addonSyncDir + '*addon-server.ps1*') } |
                    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
            } catch { }
        }
    }
}

Describe 'Host log rotation (long-run:host-log-no-rotation)' -Tags 'Host' {
    It 'rotates host.log to host.log.1 once it is at/over ~2MB instead of growing unbounded' {
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $port = 47902
        $root = New-TempRoot -Name 'host-log-rotation'
        $server = $null
        $hostProc = $null
        $needle = 'logrotate-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $markerPath = Join-Path -Path $root -ChildPath ($needle + '.json')

        try {
            $server = Start-TestServer -Root $root -Port $port
            Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'host\selftest.html') -Destination (Join-Path $root 'ui\selftest.html') -Force
            Copy-Item -LiteralPath $Script:HostBinDir -Destination (Join-Path $root 'host\bin') -Recurse -Force
            $exeCopyPath = Join-Path $root 'host\bin\FurphyHost.exe'
            $webview2Dir = $exeCopyPath + '.WebView2'
            if (Test-Path -LiteralPath $webview2Dir) {
                Remove-Item -LiteralPath $webview2Dir -Recurse -Force -ErrorAction SilentlyContinue
            }

            # Pre-seed host.log past the 2MB rotation threshold
            # (LogWriter's MaxBytes = 2097152, matching addon-server.ps1's
            # own $Script:LogRotationMaxBytes) BEFORE the exe ever runs, so
            # its very first LogHost call (MainForm_Load's own
            # "starting, port=..." line) is the one that has to rotate.
            $hostLogPath = Join-Path $root 'host.log'
            $seedMarker = 'SEED-' + ('x' * 195)
            $seedLine = $seedMarker + [Environment]::NewLine
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            $sw = New-Object System.IO.StreamWriter($hostLogPath, $false, $utf8NoBom)
            try {
                $target = 2097152 + 5000
                $written = 0
                while ($written -lt $target) {
                    $sw.Write($seedLine)
                    $written += $seedLine.Length
                }
            } finally { $sw.Dispose() }
            $preSize = (Get-Item -LiteralPath $hostLogPath).Length
            $preSize | Should BeGreaterThan 2097152

            $rotatedPath = $hostLogPath + '.1'
            if (Test-Path -LiteralPath $rotatedPath) { Remove-Item -LiteralPath $rotatedPath -Force }

            $selftestUrl = "http://localhost:$port/selftest.html"
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exeCopyPath
            $psi.Arguments = '--port ' + $port + ' --selftest "' + $markerPath + '" "' + $selftestUrl + '"'
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path -Path $exeCopyPath -Parent
            $hostProc = [System.Diagnostics.Process]::Start($psi)

            $marker = Wait-MarkerFile -Path $markerPath -TimeoutSec 40
            $marker | Should Not Be $null
            Wait-ProcessExit -Process $hostProc | Should Be $true

            (Test-Path -LiteralPath $rotatedPath -PathType Leaf) | Should Be $true
            $rotatedContent = Get-Content -LiteralPath $rotatedPath -Raw
            $rotatedContent | Should Match ([regex]::Escape($seedMarker))

            $newContent = Get-Content -LiteralPath $hostLogPath -Raw
            $newContent | Should Not Match ([regex]::Escape($seedMarker))
            $newContent | Should Match ('starting, port=' + $port)
            (Get-Item -LiteralPath $hostLogPath).Length | Should BeLessThan $preSize
        } finally {
            if ($hostProc -and -not $hostProc.HasExited) { try { $hostProc.Kill() } catch { } }
            Stop-Straggler-FurphyHost -Needle $needle
            Stop-TestServer -Server $server
        }
    }
}

Describe 'Host FormatNextCheck DST handling (long-run:tray-next-check-dst-two-day-mislabel)' -Tags 'Host' {
    <#
      long-run:tray-next-check-dst-two-day-mislabel - FormatNextCheck's old
      two-branch "today, else tomorrow" logic assumed the interval being
      clamped 30..1440 minutes meant the LOCAL calendar date of nextRunAtUtc
      could never be more than one day ahead of "today". True for the UTC
      gap itself, false for the local date it lands on: a DST spring-
      forward between now and nextRunAtUtc adds a real wall-clock hour on
      top of that 24h interval, which can push the local date two days out.

      Invoked via reflection against the compiled FurphyHost.exe's private
      3-arg FormatNextCheck(DateTime?, DateTime nowLocal, TimeZoneInfo tz)
      overload (host\FurphyHost.cs) - that overload exists specifically so
      a test can simulate the exact DST transition without touching this
      machine's real system clock/timezone. Loads the assembly directly
      (no process launched, no window shown) via Assembly.LoadFrom, same
      as any other pure-function reflection test.
    #>
    It 'labels a next-check time two calendar days out with a real date, never "tomorrow", across a DST spring-forward' {
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $tz = $null
        try {
            $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time')
        } catch {
            Write-Host '  (skipped: this machine has no "Pacific Standard Time" zone registered)'
            return
        }

        # FormatNextCheck lives on TrayForm (host\FurphyHost.cs) - it is
        # the tray's own "next check" tooltip/menu formatter, not MainForm's.
        $asm = [System.Reflection.Assembly]::LoadFrom($Script:HostExePath)
        $trayFormType = $asm.GetType('Furphy.TrayForm')
        $trayFormType | Should Not Be $null
        $flags = [System.Reflection.BindingFlags]'NonPublic, Static'
        $method = $trayFormType.GetMethod('FormatNextCheck', $flags, $null,
            @([System.Nullable[datetime]], [datetime], [System.TimeZoneInfo]), $null)
        $method | Should Not Be $null

        # 2026-03-08 is the real US spring-forward date (2:00am -> 3:00am).
        # "now" the night before at 23:30 local, interval at its 1440-
        # minute (24h) max: nextRunAtUtc = nowUtc + 24h lands on 2026-03-09
        # 00:30 PDT local wall-clock - two calendar days after "today"
        # (Mar 7), not one, because spring-forward added a real wall-clock
        # hour on top of the 24h UTC interval. Before this fix that was
        # mislabeled "tomorrow 00:30"; after it, a real date - never
        # "tomorrow".
        $nowLocal = [datetime]'2026-03-07T23:30:00'
        $nowUtc = [System.TimeZoneInfo]::ConvertTimeToUtc($nowLocal, $tz)
        $nextRunUtc = $nowUtc.AddMinutes(1440)
        $nextRunLocalCheck = [System.TimeZoneInfo]::ConvertTimeFromUtc($nextRunUtc, $tz)
        # Sanity: confirms this scenario really does cross two local
        # calendar dates before asserting anything about the label -
        # otherwise a wrong repro date would make the rest meaningless.
        ($nextRunLocalCheck.Date - $nowLocal.Date).Days | Should Be 2

        $result = $method.Invoke($null, @([Nullable[datetime]]$nextRunUtc, $nowLocal, $tz))

        $result | Should Not Match 'tomorrow'
        $result | Should Match ([regex]::Escape($nextRunLocalCheck.ToString('HH:mm')))
    }

    It 'still labels an ordinary same-day next-check as plain HH:mm and an ordinary one-day-out check as "tomorrow"' {
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $tz = $null
        try {
            $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time')
        } catch {
            Write-Host '  (skipped: this machine has no "Pacific Standard Time" zone registered)'
            return
        }

        $asm = [System.Reflection.Assembly]::LoadFrom($Script:HostExePath)
        $trayFormType = $asm.GetType('Furphy.TrayForm')
        $flags = [System.Reflection.BindingFlags]'NonPublic, Static'
        $method = $trayFormType.GetMethod('FormatNextCheck', $flags, $null,
            @([System.Nullable[datetime]], [datetime], [System.TimeZoneInfo]), $null)

        # Ordinary same-day case, no DST transition anywhere nearby (June):
        # plain "HH:mm" - regression guard against the day-diff rewrite
        # breaking the ordinary case.
        $nowLocal1 = [datetime]'2026-06-01T10:00:00'
        $nowUtc1 = [System.TimeZoneInfo]::ConvertTimeToUtc($nowLocal1, $tz)
        $result1 = $method.Invoke($null, @([Nullable[datetime]]($nowUtc1.AddMinutes(60)), $nowLocal1, $tz))
        $result1 | Should Be '11:00'

        # Ordinary one-day-out case (no DST transition in the gap): still
        # "tomorrow HH:mm", unchanged from before this fix.
        $nowLocal2 = [datetime]'2026-06-01T23:00:00'
        $nowUtc2 = [System.TimeZoneInfo]::ConvertTimeToUtc($nowLocal2, $tz)
        $result2 = $method.Invoke($null, @([Nullable[datetime]]($nowUtc2.AddMinutes(120)), $nowLocal2, $tz))
        $result2 | Should Be 'tomorrow 01:00'
    }
}

Describe 'Host MinimumSize DPI floor (regression-guards:host-minimumsize-floor-no-guard-test)' -Tags 'Host' {
    <#
      regression-guards:host-minimumsize-floor-no-guard-test - Round 32
      raised MainForm's MinimumSize floor from 900x600 (which pushed every
      Settings toggle switch off the visible right edge with no scroll
      escape) to 1040x660, expressed as a 96-DPI baseline
      (MinimumSizeBaselineAt96Dpi) converted to physical pixels for the
      real DPI in effect by MinimumSizeForDpi(int dpi) - both private
      static members of host\FurphyHost.cs's Furphy.MainForm. Before this
      Describe, the only DPI-related assertion anywhere in this file was
      the --selftest marker's `dpiAware` boolean (a flag saying "the app
      IS DPI-aware", never the actual pixel floor) - a regression that
      shrank the baseline back toward 900x600 would have passed the whole
      suite untouched.
    #>

    It 'pins the 1040x660 96-DPI baseline and MinimumSizeForDpi''s identity/scaling math, via reflection - no window' {
        <#
          Mirrors the FormatNextCheck DST Describe immediately above: pure
          Assembly.LoadFrom + reflection against private static members, no
          window created, no WoW client involved - safe to run
          unconditionally.
        #>
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }

        $asm = [System.Reflection.Assembly]::LoadFrom($Script:HostExePath)
        $mainFormType = $asm.GetType('Furphy.MainForm')
        $mainFormType | Should Not Be $null

        $staticFlags = [System.Reflection.BindingFlags]'NonPublic, Static'

        # Today's exact values - Round 32's fix. A future intentional
        # change to the floor should update this test deliberately (and
        # CHANGELOG.md) rather than the baseline silently drifting back
        # down and this guard staying green.
        $field = $mainFormType.GetField('MinimumSizeBaselineAt96Dpi', $staticFlags)
        $field | Should Not Be $null
        $baseline = $field.GetValue($null)
        [int]$baseline.Width | Should Be 1040
        [int]$baseline.Height | Should Be 660

        $method = $mainFormType.GetMethod('MinimumSizeForDpi', $staticFlags, $null, @([int]), $null)
        $method | Should Not Be $null

        # 96 DPI = 100% scaling - identity conversion, same value back.
        $result96 = $method.Invoke($null, @(96))
        [int]$result96.Width | Should Be ([int]$baseline.Width)
        [int]$result96.Height | Should Be ([int]$baseline.Height)

        # 144 DPI = 150% scaling - proves the scaling math itself, not
        # just the baseline constant (Round 32's actual bug: the baseline
        # was fine, but nothing rescaled it for a >100% display).
        $result144 = $method.Invoke($null, @(144))
        [int]$result144.Width | Should Be ([int][Math]::Ceiling($baseline.Width * 1.5))
        [int]$result144.Height | Should Be ([int][Math]::Ceiling($baseline.Height * 1.5))

        # 120 DPI = 125% scaling - the exact dev-machine scale factor
        # Round 32's own repro/comments call out by name.
        $result120 = $method.Invoke($null, @(120))
        [int]$result120.Width | Should Be ([int][Math]::Ceiling($baseline.Width * 1.25))
        [int]$result120.Height | Should Be ([int][Math]::Ceiling($baseline.Height * 1.25))
    }

    It 'a real, live MainForm window actually carries the floor MinimumSizeForDpi computes for its own detected DPI' {
        <#
          The reflection test above proves the pure function's math; this
          proves the constructor really assigns it (MinimumSize =
          MinimumSizeForDpi(_effectiveDpi), host\FurphyHost.cs, just above
          MainForm_Load) to a genuine on-screen window, closing the gap a
          pure-function test alone cannot. Per this build round's HARD
          RULES, a native FurphyHost.exe window is only ever launched here
          when Test-RealWowClientRunning reports the real game is not
          running on this machine - unlike --wow-fake (which only changes
          what the launched exe itself believes), this check is about not
          popping a real window while someone may be actually playing.
          Uses this fixer's own assigned scratch port (47905), never
          47899/47831.
        #>
        if (-not (Ensure-HostBuilt)) {
            Write-Host '  (skipped: host\bin\FurphyHost.exe could not be built)'
            return
        }
        if (Test-RealWowClientRunning) {
            Write-Host '  (skipped: a real WoW client process is running on this machine - not launching a native FurphyHost.exe window)'
            return
        }

        $root = New-TempRoot -Name 'host-minsize-selftest'
        $server = $null
        $hostProc = $null
        $needle = 'minsize-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $markerPath = Join-Path -Path $root -ChildPath ($needle + '.json')
        $testPort = 47905

        try {
            $server = Start-TestServer -Root $root -Port $testPort
            Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'host\selftest.html') -Destination (Join-Path $root 'ui\selftest.html') -Force

            # Same "run from a copy of host\bin, never the real build-root
            # copy" isolation as the existing --selftest Describe above.
            Copy-Item -LiteralPath $Script:HostBinDir -Destination (Join-Path $root 'host\bin') -Recurse -Force
            Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'VERSION') -Destination (Join-Path $root 'VERSION') -Force -ErrorAction SilentlyContinue
            $exeCopyPath = Join-Path $root 'host\bin\FurphyHost.exe'

            $webview2Dir = $exeCopyPath + '.WebView2'
            if (Test-Path -LiteralPath $webview2Dir) {
                Remove-Item -LiteralPath $webview2Dir -Recurse -Force -ErrorAction SilentlyContinue
            }

            $selftestUrl = 'http://localhost:' + $testPort + '/selftest.html'
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exeCopyPath
            $psi.Arguments = '--port ' + $testPort + ' --selftest "' + $markerPath + '" "' + $selftestUrl + '"'
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path -Path $exeCopyPath -Parent
            $hostProc = [System.Diagnostics.Process]::Start($psi)

            $marker = Wait-MarkerFile -Path $markerPath -TimeoutSec 40
            $marker | Should Not Be $null

            ($marker.dpiAware -is [bool]) | Should Be $true
            [int]$marker.minimumSizeWidth | Should BeGreaterThan 0
            [int]$marker.minimumSizeHeight | Should BeGreaterThan 0

            # Cross-check the live window's actual MinimumSize against the
            # SAME MinimumSizeForDpi function (via reflection, no second
            # window) evaluated at the DPI this live window itself
            # detected (marker.dpi) - proves the constructor assignment
            # matches the formula exactly, not just "some positive size".
            $asm = [System.Reflection.Assembly]::LoadFrom($Script:HostExePath)
            $mainFormType = $asm.GetType('Furphy.MainForm')
            $staticFlags = [System.Reflection.BindingFlags]'NonPublic, Static'
            $method = $mainFormType.GetMethod('MinimumSizeForDpi', $staticFlags, $null, @([int]), $null)
            $expected = $method.Invoke($null, @([int]$marker.dpi))
            [int]$marker.minimumSizeWidth | Should Be ([int]$expected.Width)
            [int]$marker.minimumSizeHeight | Should Be ([int]$expected.Height)

            # Never below the 96-DPI baseline itself, regardless of DPI -
            # the actual "Settings toggles pushed off-edge" regression
            # Round 32 fixed would show up here as a floor below 1040x660.
            [int]$marker.minimumSizeWidth | Should BeGreaterThan 1039
            [int]$marker.minimumSizeHeight | Should BeGreaterThan 659

            Wait-ProcessExit -Process $hostProc | Should Be $true
        } finally {
            if ($hostProc -and -not $hostProc.HasExited) {
                try { $hostProc.Kill() } catch { }
            }
            Stop-Straggler-FurphyHost -Needle $needle
            Stop-TestServer -Server $server
        }
    }
}

Remove-TempRoots
