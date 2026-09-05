param(
    [Parameter(Mandatory=$true)][string]$AppRoot,
    [Parameter(Mandatory=$true)][string]$WowRoot,
    [Parameter(Mandatory=$true)][string]$FakeWowExe
)
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$server = $null
$hostProc = $null
$fakeWow = $null
$webviewDir = Join-Path $AppRoot 'host\bin\FurphyHost.exe.WebView2'
if (Test-Path -LiteralPath $webviewDir) {
    Remove-Item -LiteralPath $webviewDir -Recurse -Force -ErrorAction SilentlyContinue
}
try {
    $server = Start-TestServer -Root $AppRoot -Port 47899 -WowRoot $WowRoot -IdleMinutes 60 -ScriptPath (Join-Path $AppRoot 'addon-server.ps1')
    Write-Host "Server up, pid=$($server.Process.Id)"

    $fakeWow = Start-Process -FilePath $FakeWowExe -ArgumentList @('/t','600','/nobreak') -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    Write-Host "Fake Wow.exe up, pid=$($fakeWow.Id)"

    $hostExe = Join-Path $AppRoot 'host\bin\FurphyHost.exe'
    $hostProc = Start-Process -FilePath $hostExe -ArgumentList @('--port','47899','--view','my-addons') -PassThru
    Write-Host "Host window up, pid=$($hostProc.Id)"
    Start-Sleep -Seconds 8

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Measure-Furphy.ps1') `
        -Label 'D-window-my-addons-fake-wow' -DurationSec 60 `
        -ServerLogPath (Join-Path $AppRoot 'server.log') `
        -Notes 'State D: native host window open on My Addons, FAKE Wow.exe running. The SPA polls /api/state on its fixed interval while the window is open, regardless of WoW.'
} finally {
    if ($hostProc -and -not $hostProc.HasExited) { Stop-Process -Id $hostProc.Id -Force -ErrorAction SilentlyContinue }
    if ($fakeWow -and -not $fakeWow.HasExited) { Stop-Process -Id $fakeWow.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    Get-Process -Name 'msedgewebview2' -ErrorAction SilentlyContinue | Where-Object {
        (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like "*$AppRoot*"
    } | Stop-Process -Force -ErrorAction SilentlyContinue
    Stop-TestServer -Server $server
}
