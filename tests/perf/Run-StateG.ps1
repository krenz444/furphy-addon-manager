param(
    [Parameter(Mandatory=$true)][string]$AppRoot,
    [Parameter(Mandatory=$true)][string]$WowRoot
)
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

# G: the launch chain's updater portion - update-addons-and-launch.cmd's
# only Furphy-owned line is:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File addon-sync.ps1 -Launcher -Quiet
# (see install.ps1's own $cmdLaunchLine) - followed by a Battle.net
# start, which this bench never runs (real WoW). settings.json already
# has autoUpdateOnLaunch:true so this exercises the real sync path, not
# the "skip, no network" early-exit.

$measureJob = Start-Job -ScriptBlock {
    param($ScriptDir, $LogPath)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir 'Measure-Furphy.ps1') `
        -Label 'G-launcher-network' -DurationSec 20 `
        -Notes 'State G (happy path): addon-sync.ps1 -Launcher -Flavor retail, network available - the exact command update-addons-and-launch.cmd runs before starting WoW via Battle.net.'
} -ArgumentList $PSScriptRoot

Start-Sleep -Milliseconds 300
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$cliPath = Join-Path $AppRoot 'addon-sync.ps1'
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cliPath -Launcher -Flavor retail -WowRoot $WowRoot -Json -Quiet 2>&1
$sw.Stop()
Write-Host "addon-sync.ps1 -Launcher exit=$LASTEXITCODE elapsed=$($sw.Elapsed.TotalSeconds)s"
Write-Host ($out | Out-String)

Receive-Job -Job $measureJob -Wait -AutoRemoveJob | Write-Host

Write-Host ''
Write-Host '=== Network-blocked cap check ==='
Write-Host 'addon-sync.ps1 has no -Proxy/-Timeout override and does not honor HTTP_PROXY/HTTPS_PROXY (Invoke-WebRequest/HttpWebRequest calls at lines ~344/443/446/698/701 all hardcode -TimeoutSec 30, no proxy parameter) - there is no hosts-file-free way to force the CurseForge host unreachable that this script itself exposes. Per the task brief, this cap does not exist yet - only the happy path above was measured.'
