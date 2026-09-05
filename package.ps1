<#
=====================================================================
 package.ps1 - builds dist\FurphyAddonManager-<version>.zip (E18)

 Zips exactly the files a fresh install needs (installer, app code, ui\,
 icon, docs) - nothing from a build/dev checkout: no addons.json,
 settings.json, state.json, logs, backups\, cache\, jobs\, staging\,
 probe folders, or workflow/test scripts. <version> comes from the
 VERSION file in the repo root (created by this build if missing,
 starting at 1.0.0) and is the same value addon-server.ps1's /api/ping
 reports, so the two never drift apart.

 FLAVORS-SPEC S3.1: this build root's own flavours\ folder (each
 installed flavour's addons.json/state.json/backups\ - state, exactly
 like the top-level addons.json/settings.json/state.json/backups\ this
 comment already calls out) is likewise never packaged. This already
 holds by construction, not by an added exclude: $rootFiles below is an
 explicit allow-list of individual files, and nothing in this script
 recursively copies $Source's own root - only ui\ and host\ (each their
 own named, non-state source folder) are ever recursed into. A future
 editor adding a generic "copy everything else from $Source" step must
 not do so without excluding flavours\ explicitly.

 Windows PowerShell 5.1 only. Pure ASCII.

 USAGE: package.ps1 [-Source <path>] [-DistDir <path>]
=====================================================================
#>
param(
    [string]$Source = $PSScriptRoot,
    [string]$DistDir = (Join-Path -Path $PSScriptRoot -ChildPath 'dist')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$versionPath = Join-Path -Path $Source -ChildPath 'VERSION'
if (-not (Test-Path -LiteralPath $versionPath)) {
    '1.0.0' | Set-Content -LiteralPath $versionPath -Encoding Ascii
}
$version = ([IO.File]::ReadAllText($versionPath)).Trim()
if (-not $version) { $version = '1.0.0' }

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

$stageRoot = Join-Path -Path $DistDir -ChildPath ('_stage-' + $version)
if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null

# Exactly what a fresh install needs - an explicit allow-list, not an
# exclude-list, so "no state files in the zip" holds by construction
# rather than by remembering every state/log/scratch path to exclude.
$rootFiles = @(
    'install.ps1',
    'Install Furphy.cmd',
    'addon-sync.ps1',
    'addon-server.ps1',
    'Addon Manager.vbs',
    'curseforge-handler.vbs',
    'register-protocol.ps1',
    'icon.ico',
    'VERSION',
    'README.md',
    'README.txt',
    'CHANGELOG.md'
)
$copied = New-Object 'System.Collections.Generic.List[string]'
$missing = New-Object 'System.Collections.Generic.List[string]'
foreach ($f in $rootFiles) {
    $s = Join-Path -Path $Source -ChildPath $f
    if (Test-Path -LiteralPath $s -PathType Leaf) {
        Copy-Item -LiteralPath $s -Destination (Join-Path -Path $stageRoot -ChildPath $f) -Force
        $copied.Add($f)
    } else {
        $missing.Add($f)
    }
}

$uiSrc = Join-Path -Path $Source -ChildPath 'ui'
$uiDst = Join-Path -Path $stageRoot -ChildPath 'ui'
New-Item -ItemType Directory -Force -Path $uiDst | Out-Null
Copy-Item -Path (Join-Path -Path $uiSrc -ChildPath '*') -Destination $uiDst -Recurse -Force
$uiCount = (Get-ChildItem -LiteralPath $uiDst -File -Recurse | Measure-Object).Count

# Native host (E19): sources + SDK assemblies + the prebuilt exe. install.ps1 rebuilds the exe when csc.exe
# exists, so the sources matter as much as bin\. Never the WebView2 runtime cache (bin\*.WebView2) or pkg\.
$hostSrc = Join-Path -Path $Source -ChildPath 'host'
$hostCount = 0
if (Test-Path -LiteralPath $hostSrc -PathType Container) {
    $hostDst = Join-Path -Path $stageRoot -ChildPath 'host'
    New-Item -ItemType Directory -Force -Path $hostDst, (Join-Path $hostDst 'lib'), (Join-Path $hostDst 'bin') | Out-Null
    foreach ($f in @('FurphyHost.cs', 'build-host.ps1', 'adfilter-hosts.txt', 'selftest.html')) {
        $s = Join-Path -Path $hostSrc -ChildPath $f
        if (Test-Path -LiteralPath $s -PathType Leaf) { Copy-Item -LiteralPath $s -Destination (Join-Path $hostDst $f) -Force }
    }
    Get-ChildItem -LiteralPath (Join-Path $hostSrc 'lib') -File -Filter '*.dll' -ErrorAction SilentlyContinue | Copy-Item -Destination (Join-Path $hostDst 'lib') -Force
    Get-ChildItem -LiteralPath (Join-Path $hostSrc 'bin') -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.dll', '.ico' } | Copy-Item -Destination (Join-Path $hostDst 'bin') -Force
    $hostCount = (Get-ChildItem -LiteralPath $hostDst -File -Recurse | Measure-Object).Count
}
foreach ($f in $missing) { Write-Host "WARNING: expected file missing, not packaged: $f" -ForegroundColor Yellow }
Write-Host "Staged $($copied.Count) root files, ui\ ($uiCount files) and host\ ($hostCount files) into $stageRoot"

$zipName = "FurphyAddonManager-$version.zip"
$zipPath = Join-Path -Path $DistDir -ChildPath $zipName
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

Push-Location $stageRoot
try {
    Compress-Archive -Path '.\*' -DestinationPath $zipPath -Force
} finally {
    Pop-Location
}
Remove-Item -LiteralPath $stageRoot -Recurse -Force

$sizeKb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB)
Write-Host "Built $zipPath ($sizeKb KB)"
Write-Host ''
Write-Host 'Release step (manual, on demand):'
Write-Host "  gh release create v$version `"$zipPath`""
