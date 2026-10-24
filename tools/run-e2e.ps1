[CmdletBinding()]
param(
    [switch]$Quick,
    [switch]$EngineOnly,
    [switch]$UiOnly,
    [switch]$Json
)

$ErrorActionPreference = 'Continue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$SrcTauriDir = Join-Path $RootDir 'src-tauri'
$FrontendDir = Join-Path $RootDir 'frontend'

# 1. Toolchain Auto-Detection
# LLVM-MinGW detection
$llvmBin = "E:\mingw\llvm-mingw-20260908-ucrt-x86_64\bin"
if (Test-Path $llvmBin) {
    if ($env:PATH -notlike "*$llvmBin*") {
        $env:PATH = "$llvmBin;$env:PATH"
    }
    $env:CC = "$llvmBin\clang.exe"
    $env:AR = "$llvmBin\llvm-ar.exe"
    $hasLlvm = $true
} elseif (Get-Command clang.exe -ErrorAction SilentlyContinue) {
    $hasLlvm = $true
} else {
    $hasLlvm = $false
}

# Rust toolchain detection
$rustBin = "E:\rust\.rustup\toolchains\stable-x86_64-pc-windows-gnullvm\bin"
if (Test-Path $rustBin) {
    if ($env:PATH -notlike "*$rustBin*") {
        $env:PATH = "$rustBin;$env:PATH"
    }
    $rustTarget = "x86_64-pc-windows-gnullvm"
} else {
    $rustcCmd = Get-Command rustc -ErrorAction SilentlyContinue
    if ($rustcCmd) {
        $hostTriple = (& rustc -vV | Select-String "host: " | ForEach-Object { ($_ -split ": ")[1].Trim() })
        if ($hostTriple -like "*gnullvm*" -or $hasLlvm) {
            $rustTarget = "x86_64-pc-windows-gnullvm"
        } else {
            $rustTarget = $hostTriple
        }
    } else {
        $rustTarget = "x86_64-pc-windows-gnullvm"
    }
}

# Node.js & Playwright detection
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
$hasNode = [bool]($nodeCmd -and $npmCmd)
$hasPlaywright = $false
if ($hasNode) {
    $playwrightPkg = Join-Path $FrontendDir 'node_modules\@playwright\test'
    if (Test-Path $playwrightPkg) {
        $hasPlaywright = $true
    }
}

# 2. Sandboxing (Live-PC Safety ADR-307)
$sandboxDir = Join-Path $env:TEMP "furphy test wow (e2e_runner_$PID)"
$savedWowRoot = $env:FURPHY_DEV_WOWROOT
$savedLocalAppData = $env:LOCALAPPDATA
$savedPlaywrightPath = $env:PLAYWRIGHT_BROWSERS_PATH
$savedPath = $env:PATH

$suiteResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$overallSuccess = $true

try {
    # Initialize zero-config sandbox (ADR-307: spaces + parentheses)
    New-Item -ItemType Directory -Path $sandboxDir -Force | Out-Null
    $retailAddons = Join-Path $sandboxDir '_retail_\Interface\AddOns'
    New-Item -ItemType Directory -Path $retailAddons -Force | Out-Null
    $retailWtf = Join-Path $sandboxDir '_retail_\WTF\Account'
    New-Item -ItemType Directory -Path $retailWtf -Force | Out-Null

    # Isolate local app data so runner tests never touch user host %LOCALAPPDATA%
    $sandboxData = Join-Path $sandboxDir 'appdata'
    New-Item -ItemType Directory -Path $sandboxData -Force | Out-Null
    $env:LOCALAPPDATA = $sandboxData

    # Maintain Playwright access to pre-installed host browser binaries
    if (-not $env:PLAYWRIGHT_BROWSERS_PATH -and (Test-Path (Join-Path $savedLocalAppData 'ms-playwright'))) {
        $env:PLAYWRIGHT_BROWSERS_PATH = Join-Path $savedLocalAppData 'ms-playwright'
    }

    $env:FURPHY_DEV_WOWROOT = $sandboxDir

    if (-not $Json) {
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "         Furphy v2 E2E Test Runner (Windows)              " -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "Sandbox Root : $sandboxDir" -ForegroundColor DarkGray
        Write-Host "Rust Target  : $rustTarget" -ForegroundColor DarkGray
        Write-Host "MinGW / LLVM : $(if ($hasLlvm) { 'Detected' } else { 'System / None' })" -ForegroundColor DarkGray
        Write-Host "Node.js      : $(if ($hasNode) { 'Available' } else { 'Absent (UI tests will skip)' })" -ForegroundColor DarkGray
        Write-Host "Playwright   : $(if ($hasPlaywright) { 'Available' } else { 'Not Installed' })" -ForegroundColor DarkGray
        Write-Host "Mode         : $(if ($Quick) { 'Quick' } elseif ($EngineOnly) { 'EngineOnly' } elseif ($UiOnly) { 'UiOnly' } else { 'Full' })" -ForegroundColor DarkGray
        Write-Host "----------------------------------------------------------`n" -ForegroundColor DarkGray
    }

    # 3. Rust Engine E2E Tests
    if (-not $UiOnly) {
        Push-Location $SrcTauriDir
        try {
            if ($Quick) {
                # Unit tests
                $unitSw = [System.Diagnostics.Stopwatch]::StartNew()
                if (-not $Json) { Write-Host "Running Rust Unit Tests (cargo test --lib)..." -ForegroundColor Yellow }
                $unitOutput = & cargo test --target $rustTarget --lib 2>&1
                $unitExitCode = $LASTEXITCODE
                $unitSw.Stop()

                $status = if ($unitExitCode -eq 0) { "PASS" } else { "FAIL"; $overallSuccess = $false }
                $suiteResults.Add([PSCustomObject]@{
                    Suite    = "rust_unit_tests"
                    Type     = "Engine"
                    Status   = $status
                    Duration = "$([math]::Round($unitSw.Elapsed.TotalSeconds, 2))s"
                    Error    = if ($unitExitCode -ne 0) { ($unitOutput -join "`n").Trim() } else { $null }
                })

                # Smoke E2E test
                $smokeFile = Get-ChildItem -Path (Join-Path $SrcTauriDir 'tests') -Filter "e2e_*.rs" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($smokeFile) {
                    $smokeName = $smokeFile.BaseName
                    $smokeSw = [System.Diagnostics.Stopwatch]::StartNew()
                    if (-not $Json) { Write-Host "Running Smoke Rust E2E ($smokeName)..." -ForegroundColor Yellow }
                    $smokeOutput = & cargo test --target $rustTarget --test $smokeName 2>&1
                    $smokeExitCode = $LASTEXITCODE
                    $smokeSw.Stop()

                    $status = if ($smokeExitCode -eq 0) { "PASS" } else { "FAIL"; $overallSuccess = $false }
                    $suiteResults.Add([PSCustomObject]@{
                        Suite    = $smokeName
                        Type     = "Engine"
                        Status   = $status
                        Duration = "$([math]::Round($smokeSw.Elapsed.TotalSeconds, 2))s"
                        Error    = if ($smokeExitCode -ne 0) { ($smokeOutput -join "`n").Trim() } else { $null }
                    })
                }
            } else {
                # Run all e2e_*.rs tests
                $e2eFiles = Get-ChildItem -Path (Join-Path $SrcTauriDir 'tests') -Filter "e2e_*.rs" -ErrorAction SilentlyContinue | Sort-Object Name
                if ($e2eFiles.Count -gt 0) {
                    foreach ($testFile in $e2eFiles) {
                        $suiteName = $testFile.BaseName
                        $sw = [System.Diagnostics.Stopwatch]::StartNew()
                        if (-not $Json) { Write-Host "Running Rust E2E Suite: $suiteName..." -ForegroundColor Yellow }

                        $output = & cargo test --target $rustTarget --test $suiteName 2>&1
                        $exitCode = $LASTEXITCODE
                        $sw.Stop()

                        $status = if ($exitCode -eq 0) { "PASS" } else { "FAIL"; $overallSuccess = $false }
                        $suiteResults.Add([PSCustomObject]@{
                            Suite    = $suiteName
                            Type     = "Engine"
                            Status   = $status
                            Duration = "$([math]::Round($sw.Elapsed.TotalSeconds, 2))s"
                            Error    = if ($exitCode -ne 0) { ($output -join "`n").Trim() } else { $null }
                        })
                    }
                } else {
                    # No e2e_*.rs files found directly, run cargo test --test e2e_*
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    if (-not $Json) { Write-Host "Running cargo test --test e2e_*..." -ForegroundColor Yellow }
                    $output = & cargo test --target $rustTarget --test e2e_* 2>&1
                    $exitCode = $LASTEXITCODE
                    $sw.Stop()

                    $status = if ($exitCode -eq 0) { "PASS" } else { "FAIL"; $overallSuccess = $false }
                    $suiteResults.Add([PSCustomObject]@{
                        Suite    = "e2e_all"
                        Type     = "Engine"
                        Status   = $status
                        Duration = "$([math]::Round($sw.Elapsed.TotalSeconds, 2))s"
                        Error    = if ($exitCode -ne 0) { ($output -join "`n").Trim() } else { $null }
                    })
                }
            }
        } finally {
            Pop-Location
        }
    }

    # 4. Playwright UI Tests
    if (-not $EngineOnly) {
        if ($hasNode -and $hasPlaywright) {
            $uiSw = [System.Diagnostics.Stopwatch]::StartNew()
            if (-not $Json) { Write-Host "Running Playwright UI Tests (npm run test:e2e)..." -ForegroundColor Yellow }

            Push-Location $FrontendDir
            try {
                $uiOutput = & npm run test:e2e 2>&1
                $uiExitCode = $LASTEXITCODE
            } finally {
                Pop-Location
            }
            $uiSw.Stop()

            $uiStatus = if ($uiExitCode -eq 0) { "PASS" } else { "FAIL"; $overallSuccess = $false }
            $suiteResults.Add([PSCustomObject]@{
                Suite    = "playwright_ui_tests"
                Type     = "Frontend"
                Status   = $uiStatus
                Duration = "$([math]::Round($uiSw.Elapsed.TotalSeconds, 2))s"
                Error    = if ($uiExitCode -ne 0) { ($uiOutput -join "`n").Trim() } else { $null }
            })
        } else {
            # Graceful degradation when Node or Playwright is absent
            $reason = if (-not $hasNode) { "Node.js not installed on system PATH" } else { "Playwright dependencies not installed" }
            if (-not $Json) { Write-Host "Skipping Playwright UI Tests: $reason" -ForegroundColor DarkYellow }
            $suiteResults.Add([PSCustomObject]@{
                Suite    = "playwright_ui_tests"
                Type     = "Frontend"
                Status   = "SKIPPED"
                Duration = "0.00s"
                Error    = $reason
            })
        }
    }

} finally {
    # Teardown sandbox & restore environment
    if (Test-Path $sandboxDir) {
        Remove-Item -Path $sandboxDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $savedWowRoot) {
        $env:FURPHY_DEV_WOWROOT = $savedWowRoot
    } else {
        Remove-Item env:FURPHY_DEV_WOWROOT -ErrorAction SilentlyContinue
    }
    if ($null -ne $savedLocalAppData) {
        $env:LOCALAPPDATA = $savedLocalAppData
    } else {
        Remove-Item env:LOCALAPPDATA -ErrorAction SilentlyContinue
    }
    if ($null -ne $savedPlaywrightPath) {
        $env:PLAYWRIGHT_BROWSERS_PATH = $savedPlaywrightPath
    } else {
        Remove-Item env:PLAYWRIGHT_BROWSERS_PATH -ErrorAction SilentlyContinue
    }
    $env:PATH = $savedPath
}

# 5. Output Reporting
if ($Json) {
    $summaryJson = [PSCustomObject]@{
        Success = $overallSuccess
        Suites  = $suiteResults
    } | ConvertTo-Json -Depth 4
    Write-Output $summaryJson
} else {
    Write-Host "`n==========================================================" -ForegroundColor Cyan
    Write-Host "                E2E Test Execution Summary                " -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan

    $format = "{0,-25} {1,-10} {2,-10} {3,10}"
    Write-Host ($format -f "Suite", "Type", "Status", "Duration") -ForegroundColor White
    Write-Host "----------------------------------------------------------" -ForegroundColor DarkGray

    foreach ($res in $suiteResults) {
        $color = switch ($res.Status) {
            "PASS"    { [ConsoleColor]::Green }
            "FAIL"    { [ConsoleColor]::Red }
            "SKIPPED" { [ConsoleColor]::Yellow }
            default   { [ConsoleColor]::Gray }
        }
        Write-Host ($format -f $res.Suite, $res.Type, $res.Status, $res.Duration) -ForegroundColor $color
    }

    Write-Host "----------------------------------------------------------" -ForegroundColor DarkGray
    $passCount = @($suiteResults | Where-Object { $_.Status -eq "PASS" }).Count
    $failCount = @($suiteResults | Where-Object { $_.Status -eq "FAIL" }).Count
    $skipCount = @($suiteResults | Where-Object { $_.Status -eq "SKIPPED" }).Count

    Write-Host "Total: $($suiteResults.Count) suites | Passed: $passCount | Failed: $failCount | Skipped: $skipCount"
    if ($overallSuccess) {
        Write-Host "Result: ALL GREEN (0)" -ForegroundColor Green
    } else {
        Write-Host "Result: FAILED ($failCount failed suites)" -ForegroundColor Red
    }
    Write-Host "==========================================================`n" -ForegroundColor Cyan
}

if ($overallSuccess) {
    exit 0
} else {
    exit 1
}
