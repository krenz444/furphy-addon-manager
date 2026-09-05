<#
=====================================================================
 tests\spa\Run-SpaHarness.ps1

 Runs tests\spa\harness.html/harness.js against a same-origin COPY of
 ui\ (never the real ui\ folder) served by a plain python http.server on
 a free port from the 47890-47897 pool, driven headlessly via
 msedge --headless=new --dump-dom with a FRESH --user-data-dir (never
 touches the user's real Edge profile). Parses the harness's own <pre
 id="results"> JSON out of the dumped DOM and converts it to this
 project's common results-collector shape (see tests\lib\common.ps1).

 The harness page itself iterates every ?mock=1&test=1 variant the task
 brief calls for (default, &flavours=3, &host=webview2, &theme=matcha,
 &view=settings) sequentially inside one page load, so this script only
 needs ONE msedge invocation.

 A generous --virtual-time-budget (see the constant below) is used
 instead of the task brief's own suggested 15000 - see this file's own
 comment on that constant for why: the harness's own mock job-progress
 exercise alone needs ~6-9 real seconds by ui\app.js's own design
 (Mock.runProgressJob spreads a job's steps across ~6s regardless of
 target count), and virtual-time-budget must cover EVERY phase's load +
 that wait sequentially, not just one. Verified live: a full run still
 finishes in well under a minute of real wall-clock time (Chromium
 processes virtual time far faster than real-time once no more network
 I/O is outstanding - this is not the same as a real N-millisecond
 sleep).

 Exit code: 0 if every check passed, 1 otherwise (or on any harness-level
 error - a missing msedge, a page that never produced results, etc.).
#>

param(
    [switch]$KeepArtifacts
)

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:VirtualTimeBudgetMs = 60000

function Find-Msedge {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    $cmd = Get-Command 'msedge.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$results = New-ResultsCollector -Suite 'spa:harness'

$msedgePath = Find-Msedge
if (-not $msedgePath) {
    Add-Result -Collector $results -Name 'msedge.exe found' -Passed $false -Message 'msedge.exe not found on this machine'
    exit (Write-ResultsSummary -Collector $results)
}

$devRoot = New-TempRoot -Name 'spa-harness'
$userDataDir = Join-Path $devRoot 'edge-profile'
$staticServer = $null

try {
    # Same-origin copy: ui\ plus the two harness files served alongside it,
    # so /index.html and /harness.html share one origin (required for the
    # harness to read into its own iframe's document/localStorage-free
    # theme check without a cross-origin failure).
    $uiItems = Get-ChildItem -LiteralPath (Join-Path $Script:FurphyBuildRoot 'ui') -Force
    foreach ($item in $uiItems) {
        Copy-Item -LiteralPath $item.FullName -Destination $devRoot -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'harness.html') -Destination (Join-Path $devRoot 'harness.html') -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'harness.js') -Destination (Join-Path $devRoot 'harness.js') -Force

    $port = Get-FreeStaticPort
    $staticServer = Start-StaticServer -Directory $devRoot -Port $port

    New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
    $dumpPath = Join-Path $devRoot 'dump.html'
    $url = "http://127.0.0.1:$port/harness.html"

    $edgeArgs = @(
        '--headless=new',
        '--disable-gpu',
        '--no-sandbox',
        ('--user-data-dir=' + $userDataDir),
        '--no-first-run',
        '--disable-extensions',
        ('--virtual-time-budget=' + $Script:VirtualTimeBudgetMs),
        ('--dump-dom'),
        $url
    )

    $stdoutPath = Join-Path $devRoot 'edge.out.log'
    $stderrPath = Join-Path $devRoot 'edge.err.log'
    $proc = Start-Process -FilePath $msedgePath -ArgumentList $edgeArgs -PassThru -Wait -NoNewWindow `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    if (Test-Path -LiteralPath $stdoutPath) {
        Copy-Item -LiteralPath $stdoutPath -Destination $dumpPath -Force
    }

    Add-Result -Collector $results -Name 'msedge --dump-dom exited 0' -Passed ($proc.ExitCode -eq 0) -Message ("exit code " + $proc.ExitCode)

    $dom = if (Test-Path -LiteralPath $dumpPath) { Get-Content -LiteralPath $dumpPath -Raw -Encoding UTF8 } else { '' }
    Add-Result -Collector $results -Name 'dump-dom produced non-empty output' -Passed ($dom.Length -gt 0)

    $resultsJson = $null
    if ($dom -match '<pre id="results">([\s\S]*?)</pre>') {
        $resultsJson = $matches[1]
        # --dump-dom re-serializes the page as HTML text, so entities the
        # harness's own JSON.stringify never produced (quotes, &, etc. are
        # plain ASCII in JSON) still need the standard HTML unescape pass.
        $resultsJson = $resultsJson -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&#39;', "'"
    }
    Add-Result -Collector $results -Name 'harness <pre id=results> found in dumped DOM' -Passed (-not [string]::IsNullOrEmpty($resultsJson))

    if ($resultsJson) {
        $parsed = $null
        try { $parsed = $resultsJson | ConvertFrom-Json } catch { }
        Add-Result -Collector $results -Name 'harness results JSON parses' -Passed ($null -ne $parsed) -Message $(if (-not $parsed) { 'ConvertFrom-Json failed' } else { $null })

        if ($parsed) {
            if ($parsed.PSObject.Properties.Name -contains 'harnessError' -and $parsed.harnessError) {
                Add-Result -Collector $results -Name 'harness ran without an uncaught error' -Passed $false -Message ([string]$parsed.harnessError)
            }
            Add-Result -Collector $results -Name 'harness reported complete=true (every phase ran)' -Passed ([bool]$parsed.complete)

            foreach ($phase in @($parsed.phases)) {
                foreach ($c in @($phase.checks)) {
                    $name = $phase.name + ' :: ' + $c.name
                    Add-Result -Collector $results -Name $name -Passed ([bool]$c.passed) -Message $c.detail
                }
                if (@($phase.consoleErrors).Count -gt 0) {
                    Add-Result -Collector $results -Name ($phase.name + ' :: no console errors') -Passed $false -Message (($phase.consoleErrors -join ' | '))
                }
            }
        }
    }
} finally {
    Stop-StaticServer -Server $staticServer
    if (-not $KeepArtifacts) {
        Remove-TempRoots
    } else {
        Write-Host "Artifacts kept at: $devRoot"
    }
}

exit (Write-ResultsSummary -Collector $results)
