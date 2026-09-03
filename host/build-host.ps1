#requires -Version 5.1
<#
.SYNOPSIS
    Compiles FurphyHost.cs into host\bin\FurphyHost.exe using the
    in-box .NET Framework C# compiler (csc.exe) via Add-Type - no
    Visual Studio required. See ROADMAP.md "E19 - verified toolchain
    facts" for the recipe this follows.

.PARAMETER Clean
    Removes host\bin before doing anything else (or instead of
    building, if that is all that was asked for).
#>
param(
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$binDir = Join-Path -Path $root -ChildPath 'bin'
$libDir = Join-Path -Path $root -ChildPath 'lib'
$srcPath = Join-Path -Path $root -ChildPath 'FurphyHost.cs'
$outPath = Join-Path -Path $binDir -ChildPath 'FurphyHost.exe'
$iconSrc = Join-Path -Path (Split-Path -Path $root -Parent) -ChildPath 'icon.ico'

if ($Clean) {
    if (Test-Path -LiteralPath $binDir) {
        Remove-Item -LiteralPath $binDir -Recurse -Force
        Write-Host "Removed $binDir"
    } else {
        Write-Host "$binDir does not exist - nothing to clean"
    }
    return
}

if (-not (Test-Path -LiteralPath $srcPath)) {
    throw "Source file not found: $srcPath"
}

$coreDll = Join-Path -Path $libDir -ChildPath 'Microsoft.Web.WebView2.Core.dll'
$winformsDll = Join-Path -Path $libDir -ChildPath 'Microsoft.Web.WebView2.WinForms.dll'
$loaderDll = Join-Path -Path $libDir -ChildPath 'WebView2Loader.dll'
foreach ($needed in @($coreDll, $winformsDll, $loaderDll)) {
    if (-not (Test-Path -LiteralPath $needed)) {
        throw "Missing required SDK file: $needed"
    }
}

if (-not (Test-Path -LiteralPath $binDir)) {
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
}

# Add-Type keeps a compiled type in the current PowerShell process; running
# this script twice in the same session would otherwise fail with a
# "type already exists" style error on recompilation of the same
# TypeDefinition text, so always spin up a fresh child powershell.exe to
# do the actual compile.
$compileScript = @'
param($SrcPath, $OutPath, $CoreDll, $WinformsDll)
$src = Get-Content -LiteralPath $SrcPath -Raw
Add-Type -TypeDefinition $src `
    -ReferencedAssemblies @(
        'System.dll',
        'System.Drawing.dll',
        'System.Windows.Forms.dll',
        $CoreDll,
        $WinformsDll
    ) `
    -OutputAssembly $OutPath `
    -OutputType WindowsApplication `
    -IgnoreWarnings
'@
$compileScriptPath = Join-Path -Path $env:TEMP -ChildPath ('furphy-build-host-{0}.ps1' -f ([Guid]::NewGuid().ToString('N')))
Set-Content -LiteralPath $compileScriptPath -Value $compileScript -Encoding ASCII

try {
    $psArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $compileScriptPath,
        '-SrcPath', $srcPath, '-OutPath', $outPath, '-CoreDll', $coreDll, '-WinformsDll', $winformsDll
    )
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $env:TEMP 'furphy-build-host.out.log') `
        -RedirectStandardError (Join-Path $env:TEMP 'furphy-build-host.err.log')
    $stdout = Get-Content -LiteralPath (Join-Path $env:TEMP 'furphy-build-host.out.log') -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content -LiteralPath (Join-Path $env:TEMP 'furphy-build-host.err.log') -Raw -ErrorAction SilentlyContinue
    if ($stdout) { Write-Host $stdout }
    if ($proc.ExitCode -ne 0) {
        if ($stderr) { Write-Host $stderr }
        throw "Compile failed (exit $($proc.ExitCode)). See output above."
    }
    if ($stderr) { Write-Host $stderr }
} finally {
    Remove-Item -LiteralPath $compileScriptPath -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $outPath)) {
    throw "Compile reported success but $outPath was not produced."
}

Copy-Item -LiteralPath $coreDll -Destination $binDir -Force
Copy-Item -LiteralPath $winformsDll -Destination $binDir -Force
Copy-Item -LiteralPath $loaderDll -Destination $binDir -Force

if (Test-Path -LiteralPath $iconSrc) {
    Copy-Item -LiteralPath $iconSrc -Destination $binDir -Force
} else {
    Write-Warning "icon.ico not found at $iconSrc - FurphyHost.exe will run without a window icon."
}

Write-Host "Built: $outPath"
