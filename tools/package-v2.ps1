param(
    [string]$Version,
    [string]$OutputDir,
    # Defaults to target\cargo in this checkout so a release never reuses a binary another
    # worktree left in a shared CARGO_TARGET_DIR.
    [string]$TargetDir
)

$ErrorActionPreference = 'Stop'

# Each of these replaces the rustflags in src-tauri\.cargo\config.toml, including
# +crt-static, and the exe would need libunwind.dll again.
foreach ($name in 'RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS', 'CARGO_BUILD_RUSTFLAGS', 'CARGO_TARGET_X86_64_PC_WINDOWS_GNULLVM_RUSTFLAGS') {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value) { throw "$name is set ('$value'). Clear it and re-run." }
}

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
if (-not $TargetDir) {
    $TargetDir = Join-Path $RootDir 'target\cargo'
}
# cargo runs from src-tauri, so a relative path would land there.
if (-not [IO.Path]::IsPathRooted($TargetDir)) {
    $TargetDir = Join-Path (Get-Location).Path $TargetDir
}
$TargetDir = [IO.Path]::GetFullPath($TargetDir)
$GateScript = Join-Path $ScriptDir 'check-release-binary.ps1'

# The three version strings must agree, or the assets, the exe's own version and the
# updater feed disagree about what was released.
$fileVersion = ([IO.File]::ReadAllText((Join-Path $RootDir 'VERSION'))).Trim()
$cargoVersion = ([regex]::Match([IO.File]::ReadAllText((Join-Path $SrcTauriDir 'Cargo.toml')), '(?m)^version\s*=\s*"([^"]+)"')).Groups[1].Value
$tauriVersion = ([regex]::Match([IO.File]::ReadAllText((Join-Path $SrcTauriDir 'tauri.conf.json')), '"version"\s*:\s*"([^"]+)"')).Groups[1].Value
if (-not $Version) { $Version = $fileVersion }
if ($Version -ne $fileVersion -or $Version -ne $cargoVersion -or $Version -ne $tauriVersion) {
    throw "Version mismatch: -Version '$Version', VERSION '$fileVersion', Cargo.toml '$cargoVersion', tauri.conf.json '$tauriVersion'"
}

Write-Host "=== Building Furphy v2 Release Artifacts (v$Version) ==="
if (Test-Path $OutputDir) {
    Remove-Item -Recurse -Force $OutputDir
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. Build Frontend
Write-Host "1. Building frontend..."
# npm and cargo report progress on stderr. When this script's own stderr is redirected,
# PowerShell 5.1 turns those lines into errors, so native calls run under 'Continue'
# and are judged by their exit codes.
$ErrorActionPreference = 'Continue'
npm --prefix "$FrontendDir" run build
$npmExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($npmExit -ne 0) { throw "Frontend build failed (npm exit $npmExit)" }

# 2. Build Backend Release Binary
# The exe path comes from cargo's own artifact report for THIS build, not a guessed path.
Write-Host "2. Building backend release binary into $TargetDir..."
$targetExe = $null
Push-Location "$SrcTauriDir"
$ErrorActionPreference = 'Continue'
try {
    $cargoOutput = & cargo build --release --target-dir "$TargetDir" --message-format=json-render-diagnostics
    $cargoExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = 'Stop'
    Pop-Location
}
if ($cargoExit -ne 0) { throw "cargo build failed (exit $cargoExit)" }
foreach ($line in $cargoOutput) {
    if (-not $line.StartsWith('{') -or -not $line.Contains('"compiler-artifact"') -or -not $line.Contains('furphy-addon-manager')) { continue }
    $msg = $line | ConvertFrom-Json
    if ($msg.reason -eq 'compiler-artifact' -and $msg.target.name -eq 'furphy-addon-manager' -and $msg.executable) {
        $targetExe = $msg.executable
    }
}
if (-not $targetExe -or -not (Test-Path -LiteralPath $targetExe)) {
    throw "cargo did not report a furphy-addon-manager executable"
}
Write-Host "Built $targetExe"

# 3. Create Versioned Setup Executable
$versionedSetupName = "FurphyAddonManager-Setup-$Version.exe"
$stableSetupName = "FurphyAddonManager-Setup.exe"
$versionedSetupPath = Join-Path $OutputDir $versionedSetupName
$stableSetupPath = Join-Path $OutputDir $stableSetupName

# Copy binary to release Setup exe
Copy-Item -Path $targetExe -Destination $versionedSetupPath -Force
Copy-Item -Path $targetExe -Destination $stableSetupPath -Force

# Gate: the file users download must start on a PC with nothing but Windows.
& $GateScript -ExePath $stableSetupPath -ExpectedVersion $Version

# Copy runtime DLLs to output directory
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

# The v1 updater runs this script from a staging copy in %TEMP%, not from the v1
# folder, so $ScriptDir holds no v1 data. v1 lives in <WowPath>\_retail_\AddonSync.
# Importing from the staging copy imported nothing and still marked the import done,
# so v2 never looked at the real v1 folder again.
function Test-V1Root([string]$Path) {
    if (-not $Path) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path 'settings.json')) -or
        (Test-Path -LiteralPath (Join-Path $Path 'flavours')) -or
        (Test-Path -LiteralPath (Join-Path $Path 'addons.json'))
}
$v1Root = $null
if ($WowPath -and (Test-V1Root (Join-Path $WowPath '_retail_\AddonSync'))) {
    $v1Root = Join-Path $WowPath '_retail_\AddonSync'
} elseif (Test-V1Root $ScriptDir) {
    $v1Root = $ScriptDir
}

try {
    Log-BridgeMessage "Starting v1-to-v2 bridge upgrade..."
    if ($v1Root) { Log-BridgeMessage "v1 data folder: $v1Root" } else { Log-BridgeMessage "No v1 data folder found; v2 will look for one itself." }

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

    $port = 47831
    $settingsFile = $null
    if ($v1Root) { $settingsFile = Join-Path $v1Root "settings.json" }
    if ($settingsFile -and (Test-Path -LiteralPath $settingsFile)) {
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

    $launchArgs = @()
    if ($v1Root) { $launchArgs += @("--import-v1", "`"$v1Root`"") }
    if ($Relaunch -eq 'tray') { $launchArgs += "--tray" }

    if ($launchArgs.Count -gt 0) {
        Start-Process -FilePath $v2Exe -ArgumentList $launchArgs
    } else {
        Start-Process -FilePath $v2Exe
    }
    Log-BridgeMessage "Bridge upgrade complete."
    exit 0
} catch {
    Record-BridgeError $_.Exception.Message
    # Bring v1 back the way it was running: its host lives in host\bin of the v1 folder.
    try {
        if ($v1Root) {
            $v1Host = Join-Path $v1Root "host\bin\FurphyHost.exe"
            if (Test-Path -LiteralPath $v1Host) {
                $hostArgs = @()
                if ($Relaunch -eq 'tray') { $hostArgs = @('--tray') }
                if ($hostArgs.Count -gt 0) {
                    Start-Process -FilePath $v1Host -ArgumentList $hostArgs -WorkingDirectory (Split-Path -Parent $v1Host)
                } else {
                    Start-Process -FilePath $v1Host -WorkingDirectory (Split-Path -Parent $v1Host)
                }
            }
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
        $ErrorActionPreference = 'Continue'
        $signOutput = & $targetExe --sign-file "$versionedSetupPath" 2>$null
        $signExit = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($signExit -eq 0 -and $signOutput) {
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
