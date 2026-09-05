# Deploys the built Addon Manager from the scratch build root to the live _retail_\AddonSync folder.
# Never overwrites user state (addons.json, settings.json, state.json, logs, jobs, backups) -
# FLAVORS-SPEC S3.1's flavours\<id>\ subfolder (each installed flavour's own addons.json/
# state.json/backups\) is state by the exact same rule: step 3 below only ever copies a fixed
# code-file list plus ui\/host\, so flavours\ (never in that list) is never touched, deleted or
# overwritten by a deploy - same as addons.json/settings.json/state.json/backups\ always were.
param(
    [string]$Source = $PSScriptRoot,
    [string]$Dest = 'C:\Program Files (x86)\World of Warcraft\_retail_\AddonSync',
    [switch]$SkipServerCheck,
    # After a successful deploy, mirror code + docs into this git checkout and commit/push it.
    [string]$RepoPath = 'C:\Users\drops\Documents\furphy-addon-manager',
    [string]$Message = '',
    [switch]$NoPush,
    # T4: skip the tests\run-all.ps1 -Quick gate below (step 0). Off by
    # default - a deploy normally REFUSES to proceed on a red gate. Every
    # use of this switch prints a loud warning (see step 0) so a skipped
    # gate is never silent in the console transcript.
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$retail = Split-Path -Path $Dest -Parent
$stamp = (Get-Date).ToString('yyyyMMdd-HHmm')

# 0. Test gate: tests\run-all.ps1 -Quick must pass before touching the live
# folder at all - step 1 below is the first thing that reaches outside this
# build root. -SkipTests overrides (loud warning, never silent).
$testsRunner = Join-Path -Path $Source -ChildPath 'tests\run-all.ps1'
if ($SkipTests) {
    Write-Host ''
    Write-Host '########################################################' -ForegroundColor Red
    Write-Host '# WARNING: -SkipTests was passed - tests\run-all.ps1 -Quick' -ForegroundColor Red
    Write-Host '# was NOT run before this deploy. Proceeding unverified.' -ForegroundColor Red
    Write-Host '########################################################' -ForegroundColor Red
    Write-Host ''
} elseif (Test-Path -LiteralPath $testsRunner -PathType Leaf) {
    Write-Host ''
    Write-Host '== Running tests\run-all.ps1 -Quick (deploy gate) ==' -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $testsRunner -Quick
    if ($LASTEXITCODE -ne 0) {
        $reportPath = Join-Path -Path $Source -ChildPath 'tests\last-report.md'
        Write-Host ''
        Write-Host "DEPLOY ABORTED: tests\run-all.ps1 -Quick failed (exit $LASTEXITCODE)." -ForegroundColor Red
        Write-Host "See: $reportPath" -ForegroundColor Red
        Write-Host 'Pass -SkipTests to deploy anyway (loud warning, not recommended).' -ForegroundColor Red
        exit 1
    }
    Write-Host '== Quick test gate passed =='
} else {
    Write-Host "WARNING: tests\run-all.ps1 not found at $testsRunner - skipping the test gate (nothing to run)." -ForegroundColor Yellow
}

function Get-LivePort {
    $p = 47831
    $sp = Join-Path $Dest 'settings.json'
    if (Test-Path -LiteralPath $sp) {
        try { $s = Get-Content -LiteralPath $sp -Raw | ConvertFrom-Json; if ($s.port) { $p = [int]$s.port } } catch {}
    }
    return $p
}

# 1. Refuse to deploy while a job is running; stop a running live server.
$port = Get-LivePort
$alive = $false
try { $null = Invoke-RestMethod -Uri "http://localhost:$port/api/ping" -TimeoutSec 2; $alive = $true } catch {}
if ($alive) {
    try {
        Invoke-RestMethod -Uri "http://localhost:$port/api/shutdown" -Method Post -Headers @{ Origin = "http://localhost:$port" } -TimeoutSec 5 | Out-Null
        "stopped live server on port $port"
        Start-Sleep -Seconds 2
    } catch {
        throw "live server refused shutdown (a job is probably running): $($_.Exception.Message)"
    }
}

# 2. Backup the live folder (code + state) before touching it.
# FLAVORS-SPEC S3.1: per-flavour addons.json/state.json now live under
# flavours\<id>\ - they're included in this backup same as the top-level
# ones used to be. Their own re-downloadable backups\<id>\<id>.zip
# folders (flavours\<id>\backups\) and the migration's own
# flavours\_migration-backup-<stamp>\ safety copy are excluded, same
# reasoning as the pre-existing top-level 'AddonSync/backups' exclude
# (regenerable, would otherwise bloat every single deploy's backup zip).
# Verified live (scratchpad\tar-exclude-test, deleted after): these two
# glob patterns exclude flavours/*/backups and flavours/_migration-
# backup-* while still keeping every flavour's own addons.json/state.json.
if (Test-Path -LiteralPath $Dest) {
    $zip = Join-Path $retail "AddonSync-backup-$stamp.zip"
    Push-Location $retail
    try { tar -a -c -f $zip --exclude 'AddonSync/jobs' --exclude 'AddonSync/staging' --exclude 'AddonSync/backups' --exclude 'AddonSync/flavours/*/backups' --exclude 'AddonSync/flavours/_migration-backup-*' 'AddonSync' } finally { Pop-Location }
    "backup: $zip ($([math]::Round((Get-Item $zip).Length/1KB)) KB)"
}

# 3. Copy code files (mirror ui\, never state files).
New-Item -ItemType Directory -Force -Path $Dest, (Join-Path $Dest 'ui'), (Join-Path $Dest 'jobs') | Out-Null
$codeFiles = @('addon-sync.ps1', 'addon-server.ps1', 'Addon Manager.vbs', 'curseforge-handler.vbs', 'register-protocol.ps1', 'README.txt', 'CHANGELOG.md', 'icon.ico', 'VERSION')
foreach ($f in $codeFiles) {
    $s = Join-Path $Source $f
    if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination (Join-Path $Dest $f) -Force; "copied $f" }
}
$uiSrc = Join-Path $Source 'ui'
$uiDst = Join-Path $Dest 'ui'
Get-ChildItem -LiteralPath $uiDst -File -Recurse | Remove-Item -Force
Copy-Item -Path (Join-Path $uiSrc '*') -Destination $uiDst -Recurse -Force
"copied ui\ ($((Get-ChildItem -LiteralPath $uiDst -File -Recurse | Measure-Object).Count) files)"

# 3b. Native host (E19): mirror host\ sources, SDK assemblies and the built exe (never the WebView2 runtime cache).
$hostSrc = Join-Path $Source 'host'
if (Test-Path -LiteralPath $hostSrc) {
    $hostDst = Join-Path $Dest 'host'
    New-Item -ItemType Directory -Force -Path $hostDst, (Join-Path $hostDst 'lib'), (Join-Path $hostDst 'bin') | Out-Null
    foreach ($f in @('FurphyHost.cs', 'build-host.ps1', 'adfilter-hosts.txt', 'selftest.html')) { $s = Join-Path $hostSrc $f; if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination (Join-Path $hostDst $f) -Force } }
    Get-ChildItem -LiteralPath (Join-Path $hostSrc 'lib') -File | Copy-Item -Destination (Join-Path $hostDst 'lib') -Force
    Get-ChildItem -LiteralPath (Join-Path $hostSrc 'bin') -File -Include '*.exe', '*.dll', '*.ico' -Recurse -Depth 0 -ErrorAction SilentlyContinue | Where-Object { $_.DirectoryName -eq (Join-Path $hostSrc 'bin') } | Copy-Item -Destination (Join-Path $hostDst 'bin') -Force
    "copied host\ ($((Get-ChildItem -LiteralPath $hostDst -File -Recurse | Measure-Object).Count) files)"
}
# 4. Ensure settings.json exists (never overwrite an existing one).
$settings = Join-Path $Dest 'settings.json'
if (-not (Test-Path -LiteralPath $settings)) {
    '{ "releaseType": 1, "autoUpdateOnLaunch": true, "port": 47831 }' | Set-Content -LiteralPath $settings -Encoding Ascii
    "created default settings.json"
}

# 5. Verify: parse checks, CLI status, server round-trip.
foreach ($f in 'addon-sync.ps1', 'addon-server.ps1') {
    $errs = $null
    [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath (Join-Path $Dest $f)), [ref]$errs) | Out-Null
    if ($errs -and $errs.Count -gt 0) { throw "parse errors in $f : $($errs[0].Message)" }
    "parse ok: $f"
}
$statusJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dest 'addon-sync.ps1') -Status -Json
$status = $statusJson | ConvertFrom-Json
"cli status ok: $(@($status.addons).Count) addons tracked"

if (-not $SkipServerCheck) {
    $port = Get-LivePort
    $proc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $Dest 'addon-server.ps1') + '"'), '-IdleMinutes', '2' -WindowStyle Hidden -PassThru
    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        try { $null = Invoke-RestMethod -Uri "http://localhost:$port/api/ping" -TimeoutSec 2; $ok = $true; break } catch {}
    }
    if (-not $ok) { throw 'live server did not answer /api/ping within 15 s' }
    $state = Invoke-RestMethod -Uri "http://localhost:$port/api/state" -TimeoutSec 10
    "server ok on port $port : state has $(@($state.addons).Count) addons, adFilter=$($state.settings.adFilter), cfFocus=$($state.settings.cfFocus)"
    $html = Invoke-WebRequest -Uri "http://localhost:$port/" -UseBasicParsing -TimeoutSec 10
    "ui ok: $($html.StatusCode), $($html.Content.Length) bytes"
    try { Invoke-RestMethod -Uri "http://localhost:$port/api/shutdown" -Method Post -Headers @{ Origin = "http://localhost:$port" } -TimeoutSec 5 | Out-Null } catch {}
    Start-Sleep -Seconds 1
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    "server shut down cleanly"
}
"DEPLOY OK $stamp"

# 6. Mirror into the git repo and push (keeps github.com/krenz444/furphy-addon-manager current).
if ((-not $NoPush) -and $RepoPath -and (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))) {
    foreach ($f in @('addon-sync.ps1', 'addon-server.ps1', 'Addon Manager.vbs', 'README.txt', 'CHANGELOG.md', 'deploy.ps1', 'iterate.workflow.js', 'icon.ico', 'make-icon.ps1', 'curseforge-handler.vbs', 'register-protocol.ps1', 'install.ps1', 'package.ps1', 'VERSION', 'Install Furphy.cmd', 'README.md', 'NEXT-FIXES.md')) {
        $s = Join-Path $Source $f
        if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination (Join-Path $RepoPath $f) -Force }
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $RepoPath 'ui'), (Join-Path $RepoPath 'docs'), (Join-Path $RepoPath 'launcher') | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $RepoPath 'ui') -File | Remove-Item -Force
    Copy-Item -Path (Join-Path $uiSrc '*') -Destination (Join-Path $RepoPath 'ui') -Recurse -Force
    foreach ($f in @('SPEC.md', 'ROADMAP.md', 'OVERNIGHT-REPORT.md', 'UX-SPEC.md')) {
        $s = Join-Path $Source $f
        if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination (Join-Path $RepoPath "docs\$f") -Force }
    }
    foreach ($f in @('update-addons-and-launch.cmd', 'Launch WoW (Updated).vbs')) {
        $s = Join-Path $retail $f
        if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination (Join-Path $RepoPath "launcher\$f") -Force }
    }
    # host\ sources + SDK assemblies for the repo (bin is a build output, pkg is the ignored nupkg)
    $rh = Join-Path $RepoPath 'host'
    New-Item -ItemType Directory -Force -Path $rh, (Join-Path $rh 'lib') | Out-Null
    foreach ($f in @('FurphyHost.cs', 'build-host.ps1', 'adfilter-hosts.txt', 'selftest.html')) { $s = Join-Path $Source "host\$f"; if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination (Join-Path $rh $f) -Force } }
    Get-ChildItem -LiteralPath (Join-Path $Source 'host\lib') -File -ErrorAction SilentlyContinue | Copy-Item -Destination (Join-Path $rh 'lib') -Force

    # T4: mirror tests\ SOURCES only - never tests\.tmp (scratch, cleaned
    # after every run), tests\last-report.json/.md (this build root's own
    # generated output, re-created by the next run-all.ps1 call), or
    # tests\theme-screenshots (Run-ThemeAudit.ps1's own generated PNGs,
    # cleared and re-populated at the start of every full run). Mirrors the
    # same clear-then-copy pattern this script already uses for ui\ above.
    $testsSrc = Join-Path $Source 'tests'
    if (Test-Path -LiteralPath $testsSrc -PathType Container) {
        $testsDst = Join-Path $RepoPath 'tests'
        if (Test-Path -LiteralPath $testsDst) { Remove-Item -LiteralPath $testsDst -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $testsDst | Out-Null
        $testsExclude = @('.tmp', 'last-report.json', 'last-report.md', 'theme-screenshots')
        Get-ChildItem -LiteralPath $testsSrc -Force | Where-Object { $testsExclude -notcontains $_.Name } | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $testsDst -Recurse -Force
        }
        "copied tests\ ($((Get-ChildItem -LiteralPath $testsDst -File -Recurse | Measure-Object).Count) files, sources only)"
    }

    Push-Location $RepoPath
    # git writes progress to stderr; under $ErrorActionPreference = 'Stop' PowerShell 5.1 would turn
    # that into a terminating error, so relax it for this block and rely on exit codes instead.
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        git add -A 2>$null | Out-Null
        $pending = git status --porcelain 2>$null
        if ($pending) {
            if (-not $Message) { $Message = "Deploy $stamp" }
            git commit -q -m $Message -m 'Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>' 2>$null | Out-Null
            $null = cmd /c 'git push --quiet 2>&1'
            if ($LASTEXITCODE -eq 0) { "repo: committed and pushed ($((git rev-parse --short HEAD)))" } else { "repo: committed, but push FAILED (exit $LASTEXITCODE) - run 'git push' in $RepoPath" }
        } else {
            "repo: nothing changed"
        }
    } finally {
        $ErrorActionPreference = $savedEap
        Pop-Location
    }
}
