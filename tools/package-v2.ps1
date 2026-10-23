param(
    [string]$Version = "2.0.0",
    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'

# Toolchain paths on Gizmo
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

if (-not $OutputDir) {
    $OutputDir = Join-Path $RootDir 'target\release-assets'
}

Write-Host "=== Building Furphy v2 Release Artifacts (v$Version) ==="
if (Test-Path $OutputDir) {
    Remove-Item -Recurse -Force $OutputDir
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. Build Frontend
Write-Host "1. Building frontend..."
npm --prefix "$FrontendDir" run build

# 2. Build Backend Release Binary
Write-Host "2. Building backend release binary..."
Push-Location "$SrcTauriDir"
try {
    cargo build --release
} finally {
    Pop-Location
}

$targetExe = "E:\rust\target\x86_64-pc-windows-gnullvm\release\furphy-addon-manager.exe"
if (-not (Test-Path $targetExe)) {
    $targetExe = Join-Path $SrcTauriDir "target\release\furphy-addon-manager.exe"
}
if (-not (Test-Path $targetExe)) {
    throw "Built binary not found at $targetExe"
}

# 3. Create Versioned Setup Executable
$versionedSetupName = "FurphyAddonManager-Setup-$Version.exe"
$stableSetupName = "FurphyAddonManager-Setup.exe"
$versionedSetupPath = Join-Path $OutputDir $versionedSetupName
$stableSetupPath = Join-Path $OutputDir $stableSetupName

# Copy binary to release Setup exe
Copy-Item -Path $targetExe -Destination $versionedSetupPath -Force
Copy-Item -Path $targetExe -Destination $stableSetupPath -Force

# Copy runtime DLLs to output directory
$llvmBin = "E:\mingw\llvm-mingw-20260908-ucrt-x86_64\bin"
if (Test-Path "$llvmBin\libunwind.dll") {
    Copy-Item -Path "$llvmBin\libunwind.dll" -Destination (Join-Path $OutputDir "libunwind.dll") -Force
}
$targetReleaseDir = Split-Path -Parent $targetExe
if (Test-Path (Join-Path $targetReleaseDir "WebView2Loader.dll")) {
    Copy-Item -Path (Join-Path $targetReleaseDir "WebView2Loader.dll") -Destination (Join-Path $OutputDir "WebView2Loader.dll") -Force
}

# Generate SHA256 for Setup (bare lowercase hex per DISTRIBUTION-SPEC.md)
$setupHash = (Get-FileHash -Path $versionedSetupPath -Algorithm SHA256).Hash.ToLowerInvariant()
$setupHash | Set-Content -LiteralPath "$versionedSetupPath.sha256" -Encoding Ascii -NoNewline
$setupHash | Set-Content -LiteralPath "$stableSetupPath.sha256" -Encoding Ascii -NoNewline
Write-Host "Created $versionedSetupName (SHA256: $setupHash)"

# 4. Generate Bridge Package
$bridgeDir = Join-Path $OutputDir "bridge-staging"
New-Item -ItemType Directory -Path $bridgeDir -Force | Out-Null

# Write VERSION
Set-Content -Path (Join-Path $bridgeDir "VERSION") -Value $Version -NoNewline

# Copy Setup and .sha256 into bridge package
Copy-Item -Path $versionedSetupPath -Destination (Join-Path $bridgeDir $versionedSetupName) -Force
Copy-Item -Path "$versionedSetupPath.sha256" -Destination (Join-Path $bridgeDir "$versionedSetupName.sha256") -Force
if (Test-Path "$llvmBin\libunwind.dll") {
    Copy-Item -Path "$llvmBin\libunwind.dll" -Destination (Join-Path $bridgeDir "libunwind.dll") -Force
}
if (Test-Path (Join-Path $targetReleaseDir "WebView2Loader.dll")) {
    Copy-Item -Path (Join-Path $targetReleaseDir "WebView2Loader.dll") -Destination (Join-Path $bridgeDir "WebView2Loader.dll") -Force
}

# Create Bridge install.ps1
$bridgeInstallPs1 = @'
param(
    [switch]$Upgrade,
    [ValidateSet('window', 'tray')]
    [string]$Relaunch = 'window',
    [string]$WowPath,
    [switch]$NoProtocol,
    [switch]$SkipAdopt
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Log-BridgeMessage($msg) {
    Write-Host "[Furphy Bridge] $msg"
    $logFile = Join-Path $ScriptDir "app-update.log"
    try {
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Add-Content -Path $logFile -Value "[$timestamp] $msg" -ErrorAction SilentlyContinue
    } catch {}
}

function Record-BridgeError($errorMsg) {
    Log-BridgeMessage "ERROR: $errorMsg"
    $stateFile = Join-Path $ScriptDir "app-update.json"
    $state = @{
        status = "failed"
        error = $errorMsg
        timestamp = (Get-Date).ToString("o")
    }
    try {
        $state | ConvertTo-Json | Set-Content -Path $stateFile -Force
    } catch {}
}

try {
    Log-BridgeMessage "Starting v1-to-v2 bridge upgrade..."

    $setupExe = Get-ChildItem -Path $ScriptDir -Filter "FurphyAddonManager-Setup*.exe" | Select-Object -First 1
    if (-not $setupExe) {
        throw "Could not find bundled FurphyAddonManager-Setup*.exe in bridge package"
    }

    $shaFile = "$($setupExe.FullName).sha256"
    if (Test-Path $shaFile) {
        $expectedSha = (Get-Content -LiteralPath $shaFile -Raw).Trim().ToLowerInvariant()
        if ($expectedSha.Contains(" ")) {
            $expectedSha = $expectedSha.Split(" ")[0]
        }
        $actualSha = (Get-FileHash -Path $setupExe.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expectedSha -ne $actualSha) {
            throw "Checksum mismatch for $($setupExe.Name): expected $expectedSha, got $actualSha"
        }
        Log-BridgeMessage "Verified installer SHA256 successfully."
    }

    # Stop v1
    Log-BridgeMessage "Stopping running v1..."
    try {
        $stopEvent = [System.Threading.EventWaitHandle]::OpenExisting("FurphyAddonManager.TrayStop")
        $stopEvent.Set() | Out-Null
        $stopEvent.Dispose()
    } catch {}

    $settingsFile = Join-Path $ScriptDir "settings.json"
    $port = 47831
    if (Test-Path $settingsFile) {
        try {
            $settingsJson = Get-Content $settingsFile -Raw | ConvertFrom-Json
            if ($settingsJson.port) { $port = $settingsJson.port }
        } catch {}
    }
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/shutdown" -Method Post -Headers @{ Origin = "http://localhost:$port" } -TimeoutSec 2 | Out-Null
    } catch {}

    # Run v2 Setup silently
    Log-BridgeMessage "Running v2 Setup silently..."
    $proc = Start-Process -FilePath $setupExe.FullName -ArgumentList @('/S') -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "v2 Setup failed with exit code $($proc.ExitCode)"
    }

    # Launch v2 with import flag
    $localAppData = [System.Environment]::GetFolderPath('LocalApplicationData')
    $v2Exe = Join-Path $localAppData "Programs\Furphy Addon Manager\Furphy Addon Manager.exe"
    if (-not (Test-Path $v2Exe)) {
        if (Test-Path $setupExe.FullName) {
            $v2Exe = $setupExe.FullName
        } else {
            throw "Could not locate v2 executable after setup at $v2Exe"
        }
    }

    $launchArgs = @("--import-v1", "`"$ScriptDir`"")
    if ($Relaunch -eq 'tray') { $launchArgs += "--tray" }

    Start-Process -FilePath $v2Exe -ArgumentList $launchArgs
    Log-BridgeMessage "Bridge upgrade complete."
    exit 0
} catch {
    Record-BridgeError $_.Exception.Message
    try {
        $v1Exe = Join-Path $ScriptDir "FurphyAddonManager.exe"
        if (Test-Path $v1Exe) {
            Start-Process -FilePath $v1Exe
        }
    } catch {}
    exit 1
}
'@

Set-Content -Path (Join-Path $bridgeDir "install.ps1") -Value $bridgeInstallPs1

# Zip bridge package
$versionedBridgeZipName = "FurphyAddonManager-$Version.zip"
$stableBridgeZipName = "FurphyAddonManager-latest.zip"
$versionedBridgeZipPath = Join-Path $OutputDir $versionedBridgeZipName
$stableBridgeZipPath = Join-Path $OutputDir $stableBridgeZipName

Write-Host "Creating bridge zip $versionedBridgeZipName..."
Compress-Archive -Path "$bridgeDir\*" -DestinationPath $versionedBridgeZipPath -Force
Copy-Item -Path $versionedBridgeZipPath -Destination $stableBridgeZipPath -Force

# Generate SHA256 for Bridge Zip (bare lowercase hex per DISTRIBUTION-SPEC.md)
$bridgeHash = (Get-FileHash -Path $versionedBridgeZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$bridgeHash | Set-Content -LiteralPath "$versionedBridgeZipPath.sha256" -Encoding Ascii -NoNewline
$bridgeHash | Set-Content -LiteralPath "$stableBridgeZipPath.sha256" -Encoding Ascii -NoNewline
Write-Host "Created $versionedBridgeZipName (SHA256: $bridgeHash)"

# Remove bridge-staging dir
Remove-Item -Recurse -Force $bridgeDir

# 5. Generate latest.json for Tauri Updater Feed
$signature = ""
if ($env:TAURI_SIGNING_PRIVATE_KEY) {
    Write-Host "TAURI_SIGNING_PRIVATE_KEY present in environment per ADR-313."
    try {
        $signOutput = & $targetExe --sign-file "$versionedSetupPath" 2>&1
        if ($LASTEXITCODE -eq 0 -and $signOutput) {
            $signature = $signOutput.ToString().Trim()
            Write-Host "Generated Ed25519 signature for $versionedSetupName"
        } else {
            Write-Host "Warning: Could not generate signature: $signOutput"
        }
    } catch {
        Write-Host "Warning: Failed invoking binary to sign: $_"
    }
} else {
    Write-Host "Notice: TAURI_SIGNING_PRIVATE_KEY not set in shell; signing skipped per ADR-313 custody rules."
}

$latestJson = @{
    version = $Version
    notes = "Furphy Addon Manager v$Version release featuring Tauri 2 architecture, Svelte 5 UI, and SQLite storage."
    pub_date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    platforms = @{
        "windows-x86_64" = @{
            signature = $signature
            url = "https://github.com/krenz444/furphy-addon-manager/releases/download/v$Version/$versionedSetupName"
            sha256 = $setupHash
        }
    }
} | ConvertTo-Json -Depth 5

Set-Content -Path (Join-Path $OutputDir "latest.json") -Value $latestJson
Write-Host "Created latest.json updater feed."

Write-Host "=== Release Packaging Complete ==="
Get-ChildItem -Path $OutputDir | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
