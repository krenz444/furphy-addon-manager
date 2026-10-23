param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CargoArgs
)

$ErrorActionPreference = 'Stop'

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
$SrcTauriDir = Join-Path $RootDir 'src-tauri'

Push-Location "$SrcTauriDir"
try {
    cargo test --target x86_64-pc-windows-gnullvm @CargoArgs
} finally {
    Pop-Location
}
