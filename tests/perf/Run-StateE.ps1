param(
    [Parameter(Mandatory=$true)][string]$AppRoot,
    [Parameter(Mandatory=$true)][string]$WowRoot,
    [Parameter(Mandatory=$true)][string]$FakeWowExe
)
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$trayProc = $null
$fakeWow = $null

$settingsPath = Join-Path $AppRoot 'settings.json'
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$settings.backgroundUpdates = $true
$settings.backgroundIntervalMinutes = 30
$settings | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8

$trayStatePath = Join-Path $AppRoot 'tray-state.json'
if (Test-Path -LiteralPath $trayStatePath) { Remove-Item -LiteralPath $trayStatePath -Force }
$hostLogPath = Join-Path $AppRoot 'host.log'
if (Test-Path -LiteralPath $hostLogPath) { Remove-Item -LiteralPath $hostLogPath -Force }

try {
    $fakeWow = Start-Process -FilePath $FakeWowExe -ArgumentList @('/t','600','/nobreak') -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    Write-Host "Fake Wow.exe up, pid=$($fakeWow.Id)"

    $hostExe = Join-Path $AppRoot 'host\bin\FurphyHost.exe'
    $trayProc = Start-Process -FilePath $hostExe -ArgumentList @('--port','47899','--tray') -PassThru
    Write-Host "Tray up, pid=$($trayProc.Id)"

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Measure-Furphy.ps1') `
        -Label 'E-tray-fake-wow-3min' -DurationSec 180 `
        -ServerLogPath (Join-Path $AppRoot 'server.log') `
        -Notes 'State E: --tray running (backgroundUpdates true, interval 30), FAKE Wow.exe already running for the whole 3-minute window. First cycle fires at t=90s, sees WoW running, and must skip without ever starting/pinging the server. No addon-server.ps1/CLI process should appear here at all.'

    Write-Host '--- host.log tail ---'
    if (Test-Path -LiteralPath $hostLogPath) { Get-Content -LiteralPath $hostLogPath -Tail 20 | Write-Host }
    Write-Host '--- tray-state.json ---'
    if (Test-Path -LiteralPath $trayStatePath) { Get-Content -LiteralPath $trayStatePath -Raw | Write-Host }
} finally {
    if ($fakeWow -and -not $fakeWow.HasExited) { Stop-Process -Id $fakeWow.Id -Force -ErrorAction SilentlyContinue }
    if ($trayProc -and -not $trayProc.HasExited) { Stop-Process -Id $trayProc.Id -Force -ErrorAction SilentlyContinue }
    # Just in case the tray itself started a server (it should not have, in
    # this scenario - WoW is running the whole time) - sweep it too.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine -like "*$AppRoot*addon-server.ps1*"
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $settings.backgroundUpdates = $false
    $settings | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
}
