<#
=====================================================================
 tests\spa\Run-ThemeAudit.ps1

 THEMES-SPEC.md section 6's "all 14 theme screenshots + contrast" full-run
 item. Full-run-only (slow, real msedge process per screenshot) - never
 called from -Quick. Two independent passes against a same-origin COPY of
 ui\ (never the real ui\ folder), served the same way tests\spa\Run-
 SpaHarness.ps1 already does (python http.server, 47890-47897 pool):

   1. tests\spa\theme-audit.html/js, driven headlessly via
      msedge --headless=new --dump-dom (same pattern as Run-SpaHarness.ps1)
      - the live-computed-contrast pass, all 14 themes, one msedge launch.
   2. One msedge --headless=new --screenshot launch PER theme (14 total) of
      My Addons under ?mock=1&theme=<slug>, written to
      tests\theme-screenshots\theme-<slug>.png for a human reviewer - this
      folder is cleared and re-populated at the START of every run (never
      swept by tests\.tmp cleanup, and excluded from deploy.ps1's tests\
      mirror - see TESTING.md).

 Exit code: 0 if every contrast check passed AND all 14 screenshots were
 produced; 1 otherwise.
#>

param(
    [switch]$KeepArtifacts
)

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:VirtualTimeBudgetMs = 30000
$Script:ThemeSlugs = @(
    'vaporwave', 'lofi', 'dark', 'light', 'terminal-green', 'arctic-ice',
    'art-deco-gold', 'alpine-dawn', 'matcha', 'desert-night', 'tokyo-rain',
    'brushed-steel', 'aurora-sky', 'strawberry-cream'
)

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

$results = New-ResultsCollector -Suite 'spa:theme-audit'

$msedgePath = Find-Msedge
if (-not $msedgePath) {
    Add-Result -Collector $results -Name 'msedge.exe found' -Passed $false -Message 'msedge.exe not found on this machine'
    exit (Write-ResultsSummary -Collector $results)
}

$devRoot = New-TempRoot -Name 'theme-audit'
$staticServer = $null
$screenshotDir = Join-Path -Path $Script:FurphyTestsRoot -ChildPath 'theme-screenshots'

try {
    $uiItems = Get-ChildItem -LiteralPath (Join-Path $Script:FurphyBuildRoot 'ui') -Force
    foreach ($item in $uiItems) {
        Copy-Item -LiteralPath $item.FullName -Destination $devRoot -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'theme-audit.html') -Destination (Join-Path $devRoot 'theme-audit.html') -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'theme-audit.js') -Destination (Join-Path $devRoot 'theme-audit.js') -Force

    $port = Get-FreeStaticPort
    $staticServer = Start-StaticServer -Directory $devRoot -Port $port

    # ---- Pass 1: live-computed contrast, all 14 themes, one msedge run ----
    $userDataDir1 = Join-Path $devRoot 'edge-profile-contrast'
    New-Item -ItemType Directory -Path $userDataDir1 -Force | Out-Null
    $dumpPath = Join-Path $devRoot 'dump.html'
    $auditUrl = "http://127.0.0.1:$port/theme-audit.html"

    $edgeArgs = @(
        '--headless=new', '--disable-gpu', '--no-sandbox',
        ('--user-data-dir=' + $userDataDir1), '--no-first-run', '--disable-extensions',
        ('--virtual-time-budget=' + $Script:VirtualTimeBudgetMs), '--dump-dom', $auditUrl
    )
    $stdoutPath = Join-Path $devRoot 'edge.contrast.out.log'
    $stderrPath = Join-Path $devRoot 'edge.contrast.err.log'
    $proc = Start-Process -FilePath $msedgePath -ArgumentList $edgeArgs -PassThru -Wait -NoNewWindow `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if (Test-Path -LiteralPath $stdoutPath) { Copy-Item -LiteralPath $stdoutPath -Destination $dumpPath -Force }
    Add-Result -Collector $results -Name 'contrast pass: msedge --dump-dom exited 0' -Passed ($proc.ExitCode -eq 0) -Message ("exit code " + $proc.ExitCode)

    $dom = if (Test-Path -LiteralPath $dumpPath) { Get-Content -LiteralPath $dumpPath -Raw -Encoding UTF8 } else { '' }
    $resultsJson = $null
    if ($dom -match '<pre id="results">([\s\S]*?)</pre>') {
        $resultsJson = $matches[1] -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&#39;', "'"
    }
    Add-Result -Collector $results -Name 'contrast pass: harness <pre id=results> found in dumped DOM' -Passed (-not [string]::IsNullOrEmpty($resultsJson))

    if ($resultsJson) {
        $parsed = $null
        try { $parsed = $resultsJson | ConvertFrom-Json } catch { }
        Add-Result -Collector $results -Name 'contrast pass: harness results JSON parses' -Passed ($null -ne $parsed) -Message $(if (-not $parsed) { 'ConvertFrom-Json failed' } else { $null })
        if ($parsed) {
            if ($parsed.PSObject.Properties.Name -contains 'harnessError' -and $parsed.harnessError) {
                Add-Result -Collector $results -Name 'contrast pass: harness ran without an uncaught error' -Passed $false -Message ([string]$parsed.harnessError)
            }
            Add-Result -Collector $results -Name 'contrast pass: all 14 themes audited (complete=true)' -Passed ([bool]$parsed.complete) -Message ("themes seen: " + (@($parsed.themes)).Count)

            foreach ($theme in @($parsed.themes)) {
                if ($theme.error) {
                    Add-Result -Collector $results -Name ("theme " + $theme.slug + " :: ran without error") -Passed $false -Message ([string]$theme.error)
                    continue
                }
                foreach ($c in @($theme.tokenShapeChecks)) {
                    Add-Result -Collector $results -Name ($theme.slug + " :: " + $c.name) -Passed ([bool]$c.passed) -Message $c.detail
                }
                foreach ($c in @($theme.contrastChecks)) {
                    $msg = if ($null -ne $c.ratio) { "ratio " + $c.ratio + ":1" } else { $c.detail }
                    Add-Result -Collector $results -Name ($theme.slug + " :: " + $c.name) -Passed ([bool]$c.passed) -Message $msg
                }
            }
        }
    }

    # ---- Pass 2: 14 screenshots, one msedge launch each -------------------
    if (Test-Path -LiteralPath $screenshotDir) { Remove-Item -LiteralPath $screenshotDir -Recurse -Force }
    New-Item -ItemType Directory -Path $screenshotDir -Force | Out-Null

    $shotCount = 0
    foreach ($slug in $Script:ThemeSlugs) {
        $userDataDirN = Join-Path $devRoot ("edge-profile-shot-" + $slug)
        New-Item -ItemType Directory -Path $userDataDirN -Force | Out-Null
        $shotPath = Join-Path $screenshotDir ("theme-" + $slug + ".png")
        $shotUrl = "http://127.0.0.1:$port/index.html?mock=1&theme=$slug&view=my-addons"
        $shotArgs = @(
            '--headless=new', '--disable-gpu', '--no-sandbox',
            ('--user-data-dir=' + $userDataDirN), '--no-first-run', '--disable-extensions',
            '--window-size=1400,900', '--virtual-time-budget=4000',
            ('--screenshot=' + $shotPath), $shotUrl
        )
        $shotProc = Start-Process -FilePath $msedgePath -ArgumentList $shotArgs -PassThru -Wait -NoNewWindow `
            -RedirectStandardOutput (Join-Path $devRoot ("shot-" + $slug + ".out.log")) `
            -RedirectStandardError (Join-Path $devRoot ("shot-" + $slug + ".err.log"))
        $ok = ($shotProc.ExitCode -eq 0) -and (Test-Path -LiteralPath $shotPath -PathType Leaf) -and ((Get-Item -LiteralPath $shotPath).Length -gt 0)
        Add-Result -Collector $results -Name ("screenshot: " + $slug) -Passed $ok -Message $(if (-not $ok) { "exit " + $shotProc.ExitCode + ", expected file at " + $shotPath } else { $null })
        if ($ok) { $shotCount++ }
    }
    Write-Host "  ($shotCount/$($Script:ThemeSlugs.Count) screenshots written to $screenshotDir)"
} finally {
    Stop-StaticServer -Server $staticServer
    if (-not $KeepArtifacts) {
        Remove-TempRoots
    } else {
        Write-Host "Artifacts kept at: $devRoot"
    }
}

exit (Write-ResultsSummary -Collector $results)
