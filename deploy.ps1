# Deploys the built Addon Manager from the scratch build root to the live _retail_\AddonSync folder.
# Never overwrites user state (addons.json, settings.json, state.json, logs, jobs, backups).
param(
    [string]$Source = $PSScriptRoot,
    [string]$Dest = 'C:\Program Files (x86)\World of Warcraft\_retail_\AddonSync',
    [switch]$SkipServerCheck,
    # After a successful deploy, mirror code + docs into this git checkout and commit/push it.
    [string]$RepoPath = 'C:\Users\drops\Documents\furphy-addon-manager',
    [string]$Message = '',
    [switch]$NoPush
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$retail = Split-Path -Path $Dest -Parent
$stamp = (Get-Date).ToString('yyyyMMdd-HHmm')

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
        Invoke-RestMethod -Uri "http://localhost:$port/api/shutdown" -Method Post -TimeoutSec 5 | Out-Null
        "stopped live server on port $port"
        Start-Sleep -Seconds 2
    } catch {
        throw "live server refused shutdown (a job is probably running): $($_.Exception.Message)"
    }
}

# 2. Backup the live folder (code + state) before touching it.
if (Test-Path -LiteralPath $Dest) {
    $zip = Join-Path $retail "AddonSync-backup-$stamp.zip"
    Push-Location $retail
    try { tar -a -c -f $zip --exclude 'AddonSync/jobs' --exclude 'AddonSync/staging' --exclude 'AddonSync/backups' 'AddonSync' } finally { Pop-Location }
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
    try { Invoke-RestMethod -Uri "http://localhost:$port/api/shutdown" -Method Post -TimeoutSec 5 | Out-Null } catch {}
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
            git commit -q -m $Message -m 'Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>' 2>$null | Out-Null
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
