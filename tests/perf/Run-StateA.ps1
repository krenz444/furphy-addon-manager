param(
    [Parameter(Mandatory=$true)][string]$AppRoot,
    [Parameter(Mandatory=$true)][string]$WowRoot
)
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$server = $null
try {
    $server = Start-TestServer -Root $AppRoot -Port 47899 -WowRoot $WowRoot -IdleMinutes 60 -ScriptPath (Join-Path $AppRoot 'addon-server.ps1')
    Write-Host "Server up, pid=$($server.Process.Id)"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Measure-Furphy.ps1') `
        -Label 'A-server-idle-no-wow' -DurationSec 60 `
        -ServerLogPath (Join-Path $AppRoot 'server.log') `
        -Notes 'State A: server running (port 47899), no window, no WoW. Idle baseline - nothing polling it.'
} finally {
    Stop-TestServer -Server $server
}
