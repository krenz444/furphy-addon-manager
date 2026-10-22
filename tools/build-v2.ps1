param(
    [switch]$Release,
    [switch]$Dev
)

$ErrorActionPreference = 'Stop'

# Ensure Rust gnullvm and MinGW/LLVM toolchains are available
$rustBin = "E:\rust\.rustup\toolchains\stable-x86_64-pc-windows-gnullvm\bin"
if (Test-Path $rustBin) {
    if ($env:PATH -notlike "*$rustBin*") {
        $env:PATH = "$rustBin;$env:PATH"
    }
}

$llvmBin = "E:\mingw\llvm-mingw-20260908-ucrt-x86_64\bin"
if (Test-Path $llvmBin) {
    if ($env:PATH -notlike "*$llvmBin*") {
        $env:PATH = "$llvmBin;$env:PATH"
    }
    $env:CC = "$llvmBin\clang.exe"
    $env:AR = "$llvmBin\llvm-ar.exe"
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$FrontendDir = Join-Path $RootDir 'frontend'
$SrcTauriDir = Join-Path $RootDir 'src-tauri'

Write-Host "Building Furphy v2 frontend..."
npm --prefix "$FrontendDir" run build

Write-Host "Building Furphy v2 backend..."
$cargoArgs = @('build')
if ($Release) {
    $cargoArgs += '--release'
}

Push-Location "$SrcTauriDir"
try {
    cargo @cargoArgs
} finally {
    Pop-Location
}

Write-Host "Furphy v2 build complete."
