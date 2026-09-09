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

 T4 (tests\run-all.ps1's own round): confirmed tests\ is never packaged,
 by the same construction this comment already documents for flavours\ -
 $rootFiles below never names anything under tests\, and ui\/host\ are
 the only two folders ever recursed into. No change was needed here; this
 line exists so that confirmation is recorded, not just implied.

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

# upgrade-1.1.0:upgrade-1.1.0-package-ships-stray-dev-log fix: an explicit
# file-extension allow-list, mirroring $rootFiles' own allow-list
# philosophy above - the unfiltered Copy-Item -Recurse this used to be
# shipped a stray dev artifact (ui\server47896.log, a leftover Python
# http.server access log from a local test session) straight into the
# public 1.1.0 release with no exclude rule catching it; 1.17.0's zip was
# clean only because ui\ happened to be clean at build time, not because
# anything here stopped it. Walked with Get-ChildItem -Recurse (not
# Copy-Item -Recurse) so each file's extension can be checked before
# staging; relative subfolder structure (needed for ui\icons\*) is
# preserved by re-joining each kept file's path under $uiDst.
$uiSrc = Join-Path -Path $Source -ChildPath 'ui'
$uiDst = Join-Path -Path $stageRoot -ChildPath 'ui'
New-Item -ItemType Directory -Force -Path $uiDst | Out-Null
$uiAllowedExtensions = @('.html', '.js', '.css', '.json', '.svg', '.ico', '.png', '.woff', '.woff2')
$uiSkipped = New-Object 'System.Collections.Generic.List[string]'
if (Test-Path -LiteralPath $uiSrc -PathType Container) {
    Get-ChildItem -LiteralPath $uiSrc -File -Recurse | ForEach-Object {
        $relPath = $_.FullName.Substring($uiSrc.Length).TrimStart('\')
        if ($uiAllowedExtensions -contains $_.Extension.ToLowerInvariant()) {
            $destPath = Join-Path -Path $uiDst -ChildPath $relPath
            $destParent = Split-Path -Path $destPath -Parent
            if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
                New-Item -ItemType Directory -Force -Path $destParent | Out-Null
            }
            Copy-Item -LiteralPath $_.FullName -Destination $destPath -Force
        } else {
            $uiSkipped.Add($relPath)
        }
    }
}
foreach ($f in $uiSkipped) { Write-Host "WARNING: ui\ file not on the packaging allow-list, not shipped: $f" -ForegroundColor Yellow }
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

# APP-UPDATE-SPEC.md sections 11/13 (round 42, 1.22.0: the app updates
# itself): a sha256 sidecar for the VERSIONED zip only - the self-updater
# (Invoke-AppUpdateMaintenance, addon-server.ps1) always downloads a
# release's own tag-versioned asset via its browser_download_url, never
# the floating FurphyAddonManager-latest.zip below, so latest.zip needs
# no sidecar of its own. Format: BARE lowercase hex sha256, nothing else
# - no filename, no trailing newline, ASCII - matching APP-UPDATE-SPEC.md
# section 8.3/11's own literal example exactly.
#
# CONFIRMED against Package A's real, landed code (addon-server.ps1's
# Invoke-AppUpdateMaintenanceCore, the sha256-mismatch branch): it reads
# the downloaded sidecar with
# `(Get-Content -LiteralPath $shaPath -Raw).Trim().ToLowerInvariant()`
# and compares that WHOLE trimmed string, directly, against
# Get-FileHash's own .Hash - never splitting on whitespace, never taking
# "the first token". An earlier draft of this file emitted the standard
# two-column sha256sum shape ("<hash>  <filename>") instead - verified
# LIVE while writing this file to be a real, total-feature-breaking bug
# against Package A's actual comparison (every real download, however
# correct, would read as a mismatch) - fixed here to the bare form before
# 1.22.0 ships. Keep this in sync with
# tests\lib\common.ps1's Start-GitHubReleaseStubServer /
# New-GitHubReleaseFixtureShaSidecar (Package E), whose own default
# -ShaSidecarFormat is 'bare' for the identical reason.
$shaPath = "$zipPath.sha256"
$zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
$zipHash | Set-Content -LiteralPath $shaPath -Encoding Ascii -NoNewline
if (-not (Test-Path -LiteralPath $shaPath -PathType Leaf)) {
    throw "package.ps1: FAILED - sha256 sidecar is missing after build: $shaPath"
}
$sidecarContent = (Get-Content -Raw -LiteralPath $shaPath).Trim().ToLowerInvariant()
if ($sidecarContent -ne $zipHash) {
    throw "package.ps1: FAILED - sha256 sidecar's own hash ($sidecarContent) does not match Get-FileHash of the zip ($zipHash)"
}
Write-Host "Built $shaPath ($zipHash)"

# DISTRIBUTION-SPEC.md fix 8: a second, IDENTICALLY-NAMED-every-release
# asset so GitHub's own stable /releases/latest/download/<name> link (the
# landing page's and README's "Download" button) never goes stale - that
# mechanism only works when the asset filename never changes between
# releases, unlike FurphyAddonManager-<version>.zip above. Made a
# permanent, enforced step here (not a release-checklist line someone can
# forget) by having package.ps1 itself refuse to finish without it -
# see the "fail loudly if either is missing" check right below.
$latestZipPath = Join-Path -Path $DistDir -ChildPath 'FurphyAddonManager-latest.zip'
Copy-Item -LiteralPath $zipPath -Destination $latestZipPath -Force
Write-Host "Built $latestZipPath (byte-identical copy of $zipName)"

if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
    throw "package.ps1: FAILED - the versioned zip is missing after build: $zipPath"
}
if (-not (Test-Path -LiteralPath $latestZipPath -PathType Leaf)) {
    throw "package.ps1: FAILED - FurphyAddonManager-latest.zip is missing after build: $latestZipPath"
}
$versionedBytes = (Get-Item -LiteralPath $zipPath).Length
$latestBytes = (Get-Item -LiteralPath $latestZipPath).Length
if ($versionedBytes -ne $latestBytes) {
    throw "package.ps1: FAILED - FurphyAddonManager-latest.zip ($latestBytes bytes) is not byte-identical to $zipName ($versionedBytes bytes)"
}

Write-Host ''
Write-Host 'Release step (manual, on demand) - ATTACH ALL THREE ASSETS, every release (fix 8 + APP-UPDATE-SPEC.md section 13):'
Write-Host "  gh release create v$version `"$zipPath`" `"$latestZipPath`" `"$shaPath`""
