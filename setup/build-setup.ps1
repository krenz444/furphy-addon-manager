#requires -Version 5.1
<#
=====================================================================
 setup\build-setup.ps1 - builds dist\FurphyAddonManager-Setup-<ver>.exe

 Compiles setup\FurphySetup.cs (the WinForms Setup bootstrapper,
 SETUP-SPEC.md section 4) into an exe using the in-box .NET Framework C#
 compiler (csc.exe) via Add-Type - no Visual Studio required, mirroring
 host\build-host.ps1's own Add-Type/CompilerParameters idiom exactly
 (SETUP-SPEC.md section 6.1). The release zip named by -PayloadZip (or,
 by default, dist\FurphyAddonManager-<Version>.zip) is embedded as a
 manifest resource named FurphyPayload.zip - the byte-for-byte same zip
 package.ps1 already built and integrity-checked earlier in the same
 run, never a second, separately-assembled file list.

 Outputs:
   dist\FurphyAddonManager-Setup-<ver>.exe        (versioned)
   dist\FurphyAddonManager-Setup.exe              (stable-named copy)
   dist\FurphyAddonManager-Setup-<ver>.exe.sha256 (versioned exe only)

 Windows PowerShell 5.1 only. Pure ASCII.

 USAGE: build-setup.ps1 [-Version <ver>] [-DistDir <path>] [-PayloadZip <path>]
=====================================================================
#>
param(
    [string]$Version,
    [string]$DistDir,
    [string]$PayloadZip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Path $PSScriptRoot -Parent
$srcPath = Join-Path -Path $PSScriptRoot -ChildPath 'FurphySetup.cs'
$iconSrc = Join-Path -Path $root -ChildPath 'icon.ico'
$versionPath = Join-Path -Path $root -ChildPath 'VERSION'

if (-not (Test-Path -LiteralPath $srcPath)) {
    throw "setup\build-setup.ps1: source file not found: $srcPath"
}

if (-not $Version) {
    if (-not (Test-Path -LiteralPath $versionPath)) {
        throw "setup\build-setup.ps1: VERSION file not found: $versionPath"
    }
    $Version = ([IO.File]::ReadAllText($versionPath)).Trim()
}
if (-not $Version) {
    throw 'setup\build-setup.ps1: could not resolve a version (VERSION file is empty and -Version was not passed).'
}

if (-not $DistDir) {
    $DistDir = Join-Path -Path $root -ChildPath 'dist'
}
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

if (-not $PayloadZip) {
    $PayloadZip = Join-Path -Path $DistDir -ChildPath ("FurphyAddonManager-$Version.zip")
}
if (-not (Test-Path -LiteralPath $PayloadZip -PathType Leaf)) {
    throw "setup\build-setup.ps1: payload zip not found: $PayloadZip (build it with package.ps1 first, or pass -PayloadZip explicitly)"
}

# Section 6.1's own correction: host\build-host.ps1 does NO manual csc.exe
# path lookup for the compile itself - Add-Type -TypeDefinition/
# -CompilerParameters relies entirely on CSharpCodeProvider/CodeDom to
# find csc.exe on its own, and this script mirrors that exactly below.
# This block is a fail-loud PRE-FLIGHT check only, on the BUILD machine,
# reusing install.ps1's own two candidate paths (the one other place in
# this codebase such a probe already exists) - so a build machine
# silently missing the C# compiler throws a clear error here instead of
# failing inside Add-Type's own exception text.
$cscPath = Join-Path -Path $env:WINDIR -ChildPath 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $cscPath)) {
    $cscPath = Join-Path -Path $env:WINDIR -ChildPath 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $cscPath)) {
    throw "setup\build-setup.ps1: C# compiler (csc.exe) not found under $env:WINDIR\Microsoft.NET - cannot build FurphyAddonManager-Setup.exe on this machine."
}

$versionedExePath = Join-Path -Path $DistDir -ChildPath ("FurphyAddonManager-Setup-$Version.exe")
$stableExePath = Join-Path -Path $DistDir -ChildPath 'FurphyAddonManager-Setup.exe'

# Add-Type keeps a compiled type in the current PowerShell process; running
# this script twice in the same session would otherwise fail with a
# "type already exists" style error on recompilation of the same
# TypeDefinition text, so - exactly like host\build-host.ps1 - the actual
# compile always happens inside a fresh child powershell.exe. The
# __FURPHY_SETUP_VERSION__ token substitution (SETUP-SPEC.md section 4.8)
# happens inside that child, on the raw source text, before Add-Type ever
# sees it.
$compileScript = @'
param($SrcPath, $OutPath, $IconPath, $ResourcePath, $ResourceName, $Version)
$src = Get-Content -LiteralPath $SrcPath -Raw
$src = $src.Replace("__FURPHY_SETUP_VERSION__", $Version)
$cp = New-Object System.CodeDom.Compiler.CompilerParameters
foreach ($r in @("System.dll", "System.Drawing.dll", "System.Windows.Forms.dll", "System.IO.Compression.dll", "System.IO.Compression.FileSystem.dll")) {
    [void]$cp.ReferencedAssemblies.Add($r)
}
$cp.OutputAssembly = $OutPath
$cp.GenerateExecutable = $true
$cp.GenerateInMemory = $false
$cp.TreatWarningsAsErrors = $false
$opts = "/target:winexe"
if ($IconPath -and (Test-Path -LiteralPath $IconPath)) { $opts += " /win32icon:`"$IconPath`"" }
$opts += " /resource:`"$ResourcePath`",$ResourceName"
$cp.CompilerOptions = $opts
Add-Type -TypeDefinition $src -CompilerParameters $cp
'@
$compileScriptPath = Join-Path -Path $env:TEMP -ChildPath ('furphy-build-setup-{0}.ps1' -f ([Guid]::NewGuid().ToString('N')))
Set-Content -LiteralPath $compileScriptPath -Value $compileScript -Encoding ASCII

try {
    # Start-Process joins -ArgumentList with spaces and does not quote, so
    # every path is wrapped in quotes here - the same $q quote-wrapper
    # idiom host\build-host.ps1 already uses, for the identical reason.
    $q = { param($s) '"' + $s + '"' }
    $psArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (& $q $compileScriptPath),
        '-SrcPath', (& $q $srcPath), '-OutPath', (& $q $versionedExePath), '-IconPath', (& $q $iconSrc),
        '-ResourcePath', (& $q $PayloadZip), '-ResourceName', 'FurphyPayload.zip', '-Version', (& $q $Version)
    )
    $outLog = Join-Path -Path $env:TEMP -ChildPath 'furphy-build-setup.out.log'
    $errLog = Join-Path -Path $env:TEMP -ChildPath 'furphy-build-setup.err.log'
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $stdout = Get-Content -LiteralPath $outLog -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content -LiteralPath $errLog -Raw -ErrorAction SilentlyContinue
    if ($stdout) { Write-Host $stdout }
    if ($proc.ExitCode -ne 0) {
        if ($stderr) { Write-Host $stderr }
        throw "setup\build-setup.ps1: compile failed (exit $($proc.ExitCode)). See output above."
    }
    if ($stderr) { Write-Host $stderr }
} finally {
    Remove-Item -LiteralPath $compileScriptPath -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $versionedExePath)) {
    throw "setup\build-setup.ps1: compile reported success but $versionedExePath was not produced."
}

# DISTRIBUTION-SPEC.md-style "second, identically-named asset" pattern
# (already established for FurphyAddonManager-latest.zip, package.ps1)
# applied here so GitHub's own stable /releases/latest/download/<name>
# link never goes stale between releases.
Copy-Item -LiteralPath $versionedExePath -Destination $stableExePath -Force
if (-not (Test-Path -LiteralPath $stableExePath)) {
    throw "setup\build-setup.ps1: FAILED - stable-named copy is missing after build: $stableExePath"
}
$versionedBytes = (Get-Item -LiteralPath $versionedExePath).Length
$stableBytes = (Get-Item -LiteralPath $stableExePath).Length
if ($versionedBytes -ne $stableBytes) {
    throw "setup\build-setup.ps1: FAILED - $stableExePath ($stableBytes bytes) is not byte-identical to the versioned exe ($versionedBytes bytes)"
}

# .sha256 sidecar for the VERSIONED exe only - mirrors package.ps1's own
# established, live-verified rule (section 6.1): bare lowercase hex, no
# filename, no trailing newline, ASCII; sidecar only for the versioned
# asset, since nothing needs to verify the stable-named copy by fixed
# name.
$shaPath = "$versionedExePath.sha256"
$exeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $versionedExePath).Hash.ToLowerInvariant()
$exeHash | Set-Content -LiteralPath $shaPath -Encoding Ascii -NoNewline
if (-not (Test-Path -LiteralPath $shaPath -PathType Leaf)) {
    throw "setup\build-setup.ps1: FAILED - sha256 sidecar is missing after build: $shaPath"
}
$sidecarContent = (Get-Content -Raw -LiteralPath $shaPath).Trim().ToLowerInvariant()
if ($sidecarContent -ne $exeHash) {
    throw "setup\build-setup.ps1: FAILED - sha256 sidecar's own hash ($sidecarContent) does not match Get-FileHash of the exe ($exeHash)"
}

# Section 4.8: prove the __FURPHY_SETUP_VERSION__ token substitution and
# the AssemblyProduct/AssemblyTitle attributes actually landed, not just
# that the compile succeeded - a silently-mangled Assembly* attribute set
# would otherwise still pass every other check in this script.
$versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($versionedExePath)
if ([string]::IsNullOrEmpty($versionInfo.ProductName)) {
    throw "setup\build-setup.ps1: FAILED - built exe has no ProductName (AssemblyProduct did not apply): $versionedExePath"
}
if ([string]::IsNullOrEmpty($versionInfo.FileDescription)) {
    throw "setup\build-setup.ps1: FAILED - built exe has no FileDescription (AssemblyTitle did not apply): $versionedExePath"
}
if ($versionInfo.ProductVersion -notmatch [regex]::Escape($Version)) {
    throw "setup\build-setup.ps1: FAILED - built exe's ProductVersion ('$($versionInfo.ProductVersion)') does not contain the expected version ('$Version'): $versionedExePath"
}

Write-Host "Built $versionedExePath ($exeHash)"
Write-Host "Built $stableExePath (byte-identical copy of FurphyAddonManager-Setup-$Version.exe)"
Write-Host "Built $shaPath"
