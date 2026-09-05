param(
    [Parameter(Mandatory=$true)][string]$AppRoot,
    [Parameter(Mandatory=$true)][string]$WowRoot,
    [Parameter(Mandatory=$true)][string]$FakeWowExe
)
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$server = $null
$fakeWow = $null
try {
    $server = Start-TestServer -Root $AppRoot -Port 47899 -WowRoot $WowRoot -IdleMinutes 60 -ScriptPath (Join-Path $AppRoot 'addon-server.ps1')
    Write-Host "Server up, pid=$($server.Process.Id)"

    $fakeWow = Start-Process -FilePath $FakeWowExe -ArgumentList @('/t','600','/nobreak') -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    Write-Host "Fake Wow.exe up, pid=$($fakeWow.Id), name=$($fakeWow.ProcessName)"

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Measure-Furphy.ps1') `
        -Label 'B-server-fake-wow' -DurationSec 60 `
        -ServerLogPath (Join-Path $AppRoot 'server.log') `
        -Notes 'State B: server running (port 47899), no window, FAKE Wow.exe running. Nothing should touch the server or the addon files while this runs.'
} finally {
    if ($fakeWow -and -not $fakeWow.HasExited) { Stop-Process -Id $fakeWow.Id -Force -ErrorAction SilentlyContinue }
    Stop-TestServer -Server $server
}
