param(
    [Parameter(Mandatory=$true)][string]$AppRoot,
    [Parameter(Mandatory=$true)][string]$WowRoot
)
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$server = $null
$hostProc = $null
$webviewDir = Join-Path $AppRoot 'host\bin\FurphyHost.exe.WebView2'
if (Test-Path -LiteralPath $webviewDir) {
    Remove-Item -LiteralPath $webviewDir -Recurse -Force -ErrorAction SilentlyContinue
}
try {
    $server = Start-TestServer -Root $AppRoot -Port 47899 -WowRoot $WowRoot -IdleMinutes 60 -ScriptPath (Join-Path $AppRoot 'addon-server.ps1')
    Write-Host "Server up, pid=$($server.Process.Id)"

    $hostExe = Join-Path $AppRoot 'host\bin\FurphyHost.exe'
    $hostProc = Start-Process -FilePath $hostExe -ArgumentList @('--port','47899','--view','get-new-addons','--tab','curseforge') -PassThru
    Write-Host "Host window up, pid=$($hostProc.Id)"
    Start-Sleep -Seconds 8

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Measure-Furphy.ps1') `
        -Label 'C-window-get-new-addons-cf-no-wow' -DurationSec 60 `
        -ServerLogPath (Join-Path $AppRoot 'server.log') `
        -Notes 'State C: native host window open on Get new addons > CurseForge (real curseforge.com site in the embedded WebView2 pane), no WoW running.'
} finally {
    if ($hostProc -and -not $hostProc.HasExited) { Stop-Process -Id $hostProc.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    Get-Process -Name 'msedgewebview2' -ErrorAction SilentlyContinue | Where-Object {
        (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine -like "*$AppRoot*"
    } | Stop-Process -Force -ErrorAction SilentlyContinue
    Stop-TestServer -Server $server
}
